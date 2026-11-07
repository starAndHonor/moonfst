#!/usr/bin/env python3
"""Plot benchmark.py summary.json; optional dependency: matplotlib.

Usage: python3 scripts/plot_benchmark.py [results_directory]
Writes comparison.png and comparison.svg alongside the input summary.json.
This command never builds binaries or runs a benchmark.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SHAPES = ("shared", "random")
METRICS = (
    ("build", "Build"),
    ("lookup_hit", "Lookup (hit)"),
    ("lookup_miss", "Lookup (miss)"),
    ("stream_owned", "Stream (owned)"),
    ("prefix_owned", "32 prefixes (owned)"),
    ("union_owned", "Union (owned)"),
)


def select_ratios(summary):
    """Select complete shared/random panels at the largest recorded N."""
    if not isinstance(summary, dict) or summary.get("schema") != 1:
        raise ValueError("summary.json must use benchmark summary schema 1")
    rows = summary.get("rows")
    if not isinstance(rows, list) or not rows:
        raise ValueError("summary.json must contain a nonempty rows array")
    for row in rows:
        if not isinstance(row, dict) or type(row.get("n")) is not int or row["n"] < 1:
            raise ValueError("each summary row must contain a positive integer n")
    largest_n = max(row["n"] for row in rows)
    panels = {}
    for shape in SHAPES:
        selected = {}
        for row in rows:
            if row.get("shape") == shape and row["n"] == largest_n:
                name = row.get("metric")
                if name in selected:
                    raise ValueError(f"duplicate {shape}/{largest_n}/{name} row")
                selected[name] = row
        ratios = []
        for name, _ in METRICS:
            if name not in selected:
                raise ValueError(f"missing {shape}/{largest_n}/{name} row")
            row = selected[name]
            times = []
            for engine in ("moonbit", "rust"):
                stats = row.get(engine)
                median = stats.get("median_us") if isinstance(stats, dict) else None
                if type(median) not in (int, float) or not math.isfinite(median) or median <= 0:
                    raise ValueError(f"{shape}/{name}/{engine}: median_us must be finite and positive")
                times.append(median)
            ratio = times[0] / times[1]
            if not math.isfinite(ratio) or ratio <= 0:
                raise ValueError(f"{shape}/{name}: invalid time ratio")
            recorded = row.get("moonbit_over_rust")
            if recorded is not None and (
                type(recorded) not in (int, float)
                or not math.isfinite(recorded)
                or not math.isclose(ratio, recorded, rel_tol=1e-12)
            ):
                raise ValueError(f"{shape}/{name}: ratio disagrees with median_us fields")
            ratios.append(ratio)
        panels[shape] = ratios
    return largest_n, panels


def draw(directory, n, panels):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.ticker import FixedLocator, FuncFormatter, NullFormatter
    except ImportError as error:
        raise RuntimeError(
            "optional plotting dependency is missing; install with: python3 -m pip install matplotlib"
        ) from error

    matplotlib.rcParams.update({
        "font.family": "DejaVu Sans",
        "font.size": 10,
        "axes.titlesize": 12,
        "axes.labelsize": 10,
        "svg.fonttype": "none",
        "svg.hashsalt": "moonfst-benchmark-comparison",
    })
    ratios = [ratio for panel in panels.values() for ratio in panel]
    left = min(1.0, min(ratios)) / 1.55
    right = max(1.0, max(ratios)) * 1.7
    # Familiar 1/2/5 ticks work across both sub-unity and large ratios.
    ticks = []
    for exponent in range(math.floor(math.log10(left)), math.ceil(math.log10(right)) + 1):
        for multiplier in (1, 2, 5):
            tick = multiplier * 10.0 ** exponent
            if left <= tick <= right:
                ticks.append(tick)

    fig, axes = plt.subplots(1, 2, figsize=(13.2, 5.6), sharex=True)
    for axis, shape in zip(axes, SHAPES):
        values = panels[shape]
        # Bars extend from the parity line to the measured ratio. A log axis
        # has no zero origin, so starting bars at zero would be misleading.
        axis.barh(
            range(len(METRICS)),
            [abs(value - 1.0) for value in values],
            left=[min(value, 1.0) for value in values],
            height=0.56,
            color=["#2563a6" if value >= 1 else "#15856c" for value in values],
            zorder=3,
        )
        axis.scatter(values, range(len(METRICS)), s=20, color="#17324d", zorder=4)
        axis.axvline(1.0, color="#222222", linewidth=1.5, linestyle="--", zorder=2)
        for position, value in enumerate(values):
            axis.annotate(
                f"{value:.2f}x", (value, position),
                xytext=(7, 0), textcoords="offset points",
                ha="left", va="center",
                fontweight="bold", color="#17324d",
            )
        axis.set_xscale("log")
        axis.set_xlim(left, right)
        axis.set_yticks(range(len(METRICS)), [label for _, label in METRICS])
        axis.set_ylim(len(METRICS) - 0.4, -0.8)
        axis.xaxis.set_major_locator(FixedLocator(ticks))
        axis.xaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:g}x"))
        axis.xaxis.set_minor_formatter(NullFormatter())
        axis.grid(axis="x", which="major", color="#d6dce3", linewidth=0.7, zorder=0)
        axis.tick_params(axis="both", length=0, pad=7)
        for spine in axis.spines.values():
            spine.set_visible(False)
        axis.set_title(f"{shape.capitalize()} keys | N = {n:,}", pad=14, fontweight="bold")
        axis.set_xlabel("MoonBit / Rust median elapsed time (log scale)", labelpad=11)
        axis.text(
            1.0, -0.55, "Rust = 1x", ha="center", va="center", fontsize=9,
            color="#444444", bbox={"facecolor": "white", "edgecolor": "none", "pad": 2},
        )
    fig.suptitle("MoonBit vs Rust fst", x=0.5, y=0.97, fontsize=18, fontweight="bold")
    fig.text(
        0.5, 0.895,
        "Largest measured input size | Lower is better; values above 1x mean MoonBit takes longer",
        ha="center", fontsize=10, color="#4b5563",
    )
    fig.text(
        0.5, 0.025,
        "Ratio of sample medians, not the median of paired ratios. Each implementation queries its own FST.",
        ha="center", fontsize=9, color="#4b5563",
    )
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.17, top=0.80, wspace=0.55)
    paths = [directory / "comparison.png", directory / "comparison.svg"]
    fig.savefig(paths[0], dpi=180, facecolor="white")
    fig.savefig(paths[1], facecolor="white", metadata={"Date": None})
    plt.close(fig)
    return paths


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory", nargs="?", type=Path,
        default=ROOT / "benchmarks/results/latest",
        help="directory containing summary.json (default: benchmarks/results/latest)",
    )
    args = parser.parse_args(argv)
    directory = args.directory.resolve()
    summary = json.loads((directory / "summary.json").read_text())
    n, panels = select_ratios(summary)
    for path in draw(directory, n, panels):
        print(path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(f"plot_benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
