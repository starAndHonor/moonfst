#!/usr/bin/env python3
"""Build, validate and compare MoonBit native release with pinned Rust fst."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shlex
import statistics
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
ENGINES = ("moonbit", "rust")
NAMES = ("build", "lookup_hit", "lookup_miss", "stream_owned", "prefix_owned", "union_owned")
SEED = 0xC0FFEE
MASK = (1 << 64) - 1
BINARIES = {
    "moonbit": ROOT / "_build/native/release/build/benchmarks/runner/runner.exe",
    "rust": ROOT / "oracle/target/release/fst_bench",
}
MOON_BUILD = ["moon", "build", "src/benchmarks/runner", "--target", "native", "--release", "--deny-warn"]
RUST_BUILD = ["cargo", "build", "--locked", "--release", "--manifest-path", "oracle/Cargo.toml", "--bin", "fst_bench"]


def stamp():
    return datetime.now(timezone.utc).isoformat()


def command(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=True, **kwargs)


def record_bytes(entry):
    key, value = entry
    return key + struct.pack("<IQ", len(key), value)


def records_hash(entries):
    value = 14695981039346656037
    for entry in entries:
        for byte in record_bytes(entry):
            value = ((value ^ byte) * 1099511628211) & MASK
    return str(value)


def reference(n, shape):
    """Independent generator: never trusts either runner's expected checksums."""
    state, all_entries = SEED, []
    for i in range(n + n // 2):
        if shape == "shared":
            key = b"catalog/" + bytes([i % 64]) + b"/item/" + f"{i:08x}".encode() + b"/meta"
        else:
            key_bytes = bytearray()
            for _ in range(12):
                state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
                key_bytes.append(state >> 24)
            key = bytes(key_bytes) + i.to_bytes(4, "big")
        value = (i << 32) | ((i * 2654435761) & 0xFFFFFFFF)
        all_entries.append((key, value))
    a = sorted(all_entries[:n])
    b = sorted(all_entries[n // 2:])
    union = sorted(all_entries)
    assert len(set(key for key, _ in union)) == len(union)
    if shape == "shared":
        prefix = [entry for entry in a if entry[0][8] < 32]
    else:
        prefix = [entry for entry in a if entry[0][0] < 32]
    digest = hashlib.sha256()
    for entry in a:
        digest.update(record_bytes(entry))
    dataset_hash = records_hash(a)
    return {
        "shape": shape, "n": n, "seed": SEED,
        "dataset_hash": dataset_hash,
        "dataset_sha256": digest.hexdigest(),
        "b_hash": records_hash(b),
        "input_key_bytes": sum(len(key) for key, _ in a),
        "expected": {
            "lookup_hit": [str(sum(value for _, value in a) & MASK), n],
            "lookup_miss": ["0", 0],
            "stream_owned": [dataset_hash, n],
            "prefix_owned": [records_hash(prefix), len(prefix)],
            "union_owned": [records_hash(union), len(union)],
        },
    }


def validate(payload, expected, engine, samples, warmups):
    if not isinstance(payload, dict):
        raise ValueError(f"{engine}: payload must be an object")
    for key, value in {
        "schema": 1, "engine": engine, "shape": expected["shape"],
        "n": expected["n"], "seed": SEED, "samples": samples, "warmups": warmups,
        "dataset_hash": expected["dataset_hash"], "input_key_bytes": expected["input_key_bytes"],
    }.items():
        if type(payload.get(key)) is not type(value) or payload.get(key) != value:
            raise ValueError(f"{engine}: {key}: {payload.get(key)!r} != {value!r}")
    size = payload.get("fst_bytes")
    if type(size) is not int or size <= 0:
        raise ValueError(f"{engine}: invalid FST length")
    metrics = payload.get("metrics", [])
    if not isinstance(metrics, list) or not all(isinstance(item, dict) for item in metrics):
        raise ValueError(f"{engine}: metrics must be an array of objects")
    if [item.get("name") for item in metrics] != list(NAMES):
        raise ValueError(f"{engine}: missing, duplicate or reordered metrics")
    for metric in metrics:
        name = metric["name"]
        target = [str(size), expected["n"]] if name == "build" else expected["expected"][name]
        if (type(metric.get("checksum")) is not str or type(metric.get("result_count")) is not int
                or [metric.get("checksum"), metric.get("result_count")] != target):
            raise ValueError(f"{engine}/{name}: checksum or count mismatch")
        times = metric.get("samples_us")
        if not isinstance(times, list) or len(times) != samples or not all(
            type(t) in (int, float) and math.isfinite(t) and t > 0 for t in times
        ):
            raise ValueError(f"{engine}/{name}: invalid timing samples")


def quantile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def statistics_us(values):
    return {
        "sample_count": len(values), "median_us": statistics.median(values),
        "p25_us": quantile(values, .25), "p75_us": quantile(values, .75),
        "p95_us": quantile(values, .95), "min_us": min(values), "max_us": max(values),
    }


def read_optional(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def choose_cpu(requested, disabled):
    if disabled:
        return None
    if not hasattr(os, "sched_getaffinity"):
        if requested is not None:
            raise ValueError("--cpu requires OS CPU affinity support")
        return None
    allowed = sorted(os.sched_getaffinity(0))
    if requested is not None:
        if requested not in allowed:
            raise ValueError(f"CPU {requested} not in allowed affinity {allowed}")
        return requested
    # On hybrid CPUs prefer the fastest core class, then a stable CPU number.
    def frequency(cpu):
        value = read_optional(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/cpuinfo_max_freq")
        return int(value) if value and value.isdigit() else 0
    return max(allowed, key=lambda cpu: (frequency(cpu), -cpu))


def version(args):
    try:
        result = command(args)
        return (result.stdout + result.stderr).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return f"unavailable: {error}"


def fingerprint():
    files = []
    for directory, dirs, names in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in {
            "_build", "target", ".git", ".mooncakes", "__pycache__", "results", "artifacts",
        })
        for name in sorted(names):
            path = Path(directory) / name
            if path.suffix in {".mbt", ".mbti", ".rs", ".py", ".c", ".h", ".mod", ".pkg"} or name in {"Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "toolchain.json", ".moonignore", ".gitignore", "ci.yml"}:
                files.append(path)
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
    return {"sha256": hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(), "files": hashes}


def environment(cpu, binaries=None):
    info = read_optional("/proc/cpuinfo") or ""
    model = next((line.split(":", 1)[1].strip() for line in info.splitlines() if line.startswith("model name")), platform.processor())
    cpu_path = f"/sys/devices/system/cpu/cpu{cpu}"
    return {
        "platform": platform.platform(), "machine": platform.machine(), "cpu_model": model,
        "selected_cpu": cpu,
        "allowed_cpus": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "cpu_max_khz": read_optional(f"{cpu_path}/cpufreq/cpuinfo_max_freq"),
        "cpu_governor": read_optional(f"{cpu_path}/cpufreq/scaling_governor"),
        "cpu_thread_siblings": read_optional(f"{cpu_path}/topology/thread_siblings_list"),
        "moon": version(["moon", "version", "--all"]),
        "rustc": version(["rustc", "-vV"]), "cargo": version(["cargo", "--version"]),
        "cc": version([os.environ.get("CC", "cc"), "--version"]),
        "python": sys.version,
        "compile_environment": {name: os.environ[name] for name in (
            "CC", "CFLAGS", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_PROFILE_RELEASE_OPT_LEVEL",
            "CARGO_PROFILE_RELEASE_LTO", "MOON_CC", "MOON_CFLAGS",
        ) if name in os.environ},
        "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in (binaries or BINARIES).items()},
        "source": fingerprint(),
        "note": "Single pinned CPU; OS frequency/boost and other system workloads are not controlled.",
    }


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def build(output, skip):
    commands = [MOON_BUILD, RUST_BUILD]
    log = []
    if not skip:
        core = Path(os.environ.get("MOON_HOME", str(Path.home() / ".moon"))) / "lib/core"
        commands = [["moon", "-C", str(core), "bundle", "--target", "native", "--warn-list", "-a", "--quiet"]] + commands
        for args in commands:
            print("build:", shlex.join(args), flush=True)
            result = command(args)
            log.append("$ " + shlex.join(args) + "\n" + result.stdout + result.stderr)
    else:
        log.append("Build skipped explicitly; caller is responsible for fresh release binaries.\n")
    for binary in BINARIES.values():
        if not binary.is_file():
            raise FileNotFoundError(binary)
    (output / "build.log").write_text("\n".join(log))
    # Captures actual MoonBit C backend compiler, allocator and optimization flags.
    result = command(MOON_BUILD + ["--dry-run"])
    (output / "moon-build-plan.txt").write_text(result.stdout + result.stderr)
    return commands


def summarize(raw):
    rows = []
    for expected in raw["datasets"]:
        shape, n = expected["shape"], expected["n"]
        runs = [run for run in raw["runs"] if run["payload"]["shape"] == shape and run["payload"]["n"] == n]
        for name in NAMES:
            by_engine = {}
            for engine in ENGINES:
                selected = [run["payload"] for run in runs if run["payload"]["engine"] == engine]
                sizes = {run["fst_bytes"] for run in selected}
                if len(sizes) != 1:
                    raise ValueError(f"{shape}/{n}/{engine}: nondeterministic FST length across runs")
                metrics = [next(m for m in run["metrics"] if m["name"] == name) for run in selected]
                values = [t for metric in metrics for t in metric["samples_us"]]
                stats = statistics_us(values)
                units = n if name in {"build", "lookup_hit", "lookup_miss"} else metrics[0]["result_count"]
                stats.update({
                    "checksum": metrics[0]["checksum"], "result_count": metrics[0]["result_count"],
                    "work_units": units, "units_per_second": units * 1_000_000 / stats["median_us"],
                    "fst_bytes": sizes.pop(),
                    "bytes_per_input_record": selected[0]["fst_bytes"] / n,
                })
                by_engine[engine] = stats
            rows.append({
                "shape": shape, "n": n, "metric": name, **by_engine,
                "moonbit_over_rust": by_engine["moonbit"]["median_us"] / by_engine["rust"]["median_us"],
            })
    return rows


def report(output, raw, rows):
    metadata = raw["environment"]
    config = raw["config"]
    lines = [
        "# MoonBit / Rust fst 基准实测",
        "",
        f"完成时间（UTC）：{raw['finished_at']}。数据正确性：所有进程、预热和计时样本通过校验。",
        "",
        f"机器：{metadata['cpu_model']}；CPU {metadata['selected_cpu']}；{metadata['platform']}。",
        f"MoonBit：{next((line for line in metadata['moon'].splitlines() if line.startswith('moonc ')), metadata['moon'].splitlines()[0])}；Rust：{metadata['rustc'].splitlines()[0]}。",
        "",
        f"两边均为 native release；每项 {config['rounds']} 个独立进程，每进程预热 "
        f"{config['warmups']} 次、采样 {config['samples']} 次，合计 "
        f"{config['rounds'] * config['samples']} 个样本。表格报告批次中位数，单位 ms；"
        "括号为 P25–P75。倍数是 MoonBit / Rust，越低越好；大于 1 表示 MoonBit 耗时更长。",
        "",
        "| 数据 | 条数 | 操作 | MoonBit ms（P25–P75） | Rust ms（P25–P75） | 耗时倍数 |",
        "|---|---:|---|---:|---:|---:|",
    ]
    def cell(stats):
        return f"{stats['median_us']/1000:.3f} ({stats['p25_us']/1000:.3f}–{stats['p75_us']/1000:.3f})"
    for row in rows:
        lines.append(f"| {row['shape']} | {row['n']:,} | {row['metric']} | {cell(row['moonbit'])} | {cell(row['rust'])} | {row['moonbit_over_rust']:.2f}× |")
    lines += [
        "", "## 编码文件大小", "",
        "原始载荷仅计 key 字节与每条 8 字节 value，不包括对象、长度或指针开销。",
        "",
        "| 数据 | 条数 | 原始载荷 B | MoonBit FST B | Rust FST B | 大小倍数 |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for expected in raw["datasets"]:
        row = next(row for row in rows if row["metric"] == "build" and row["n"] == expected["n"] and row["shape"] == expected["shape"])
        moon, rust = row["moonbit"]["fst_bytes"], row["rust"]["fst_bytes"]
        lines.append(f"| {row['shape']} | {row['n']:,} | {expected['input_key_bytes'] + 8*row['n']:,} | {moon:,} | {rust:,} | {moon/rust:.3f}× |")
    lines += [
        "", "## 解释边界", "",
        "- 每个实现查询自己构建的 FST；编码布局、节点缓存、分配器和 API 开销均属于比较对象。这是两个库实现的比较。",
        "- 输入生成、排序、装载验证、文件 IO、结果 hash 和最终输出销毁不计时。lookup 的消费累加计时。",
        "- 遍历、前缀和并集均物化拥有 key 的记录；未拿 Rust 借用 key 流与 MoonBit 独立 key 直接比较。",
        "- lookup 按排序键批量执行；miss 在现有 key 后追加 FF，是近似未命中。prefix 为 32 个范围批次。union 的两张表各 N 条，重叠 N/2。",
        "- 这是固定种子合成数据与热运行测量，未测真实语料、冷缓存、磁盘吞吐或峰值 RSS。CPU 未迁移，但频率、温度和其他系统负载未锁定。",
        "- P25/P75/P95 使用线性插值；样本离散程度不是置信区间。吞吐量见 summary.csv，prefix/union 按输出记录计，lookup 按请求计。",
        "",
        f"完整方法见 [benchmarks/README.md]({os.path.relpath(ROOT / 'benchmarks/README.md', output)})。"
        "原始样本和环境见 [raw.json](raw.json)，汇总见 [summary.json](summary.json) / [summary.csv](summary.csv)，"
        "实际 C 后端编译参数见 [moon-build-plan.txt](moon-build-plan.txt)。",
        "",
    ]
    (output / "REPORT.md").write_text("\n".join(lines))
    write_json(output / "summary.json", {"schema": 1, "rows": rows})
    with (output / "summary.csv").open("w", newline="") as handle:
        fields = ["shape", "n", "metric", "engine", "sample_count", "median_us", "p25_us", "p75_us", "p95_us", "min_us", "max_us", "units_per_second", "work_units", "result_count", "checksum", "fst_bytes", "bytes_per_input_record", "moonbit_over_rust"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            for engine in ENGINES:
                writer.writerow({key: row[key] for key in ("shape", "n", "metric", "moonbit_over_rust")} | {"engine": engine} | row[engine])


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1000, 10000, 100000])
    parser.add_argument("--shapes", choices=["shared", "random"], nargs="+", default=["shared", "random"])
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--no-affinity", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/benchmarks" / datetime.now(timezone.utc).strftime("synthetic-%Y%m%dT%H%M%S%fZ"))
    args = parser.parse_args(argv)
    if any(n < 2 or n % 2 or n > 1431655764 for n in args.sizes):
        parser.error("sizes must be even, >= 2 and <= 1431655764")
    if len(set(args.sizes)) != len(args.sizes) or len(set(args.shapes)) != len(args.shapes):
        parser.error("sizes/shapes must not contain duplicates")
    if args.samples < 1 or args.warmups < 0 or args.rounds < 1:
        parser.error("samples/rounds must be positive; warmups must be nonnegative")
    if args.samples + args.warmups > 2147483647:
        parser.error("samples + warmups must fit MoonBit Int32")
    if args.cpu is not None and args.no_affinity:
        parser.error("--cpu and --no-affinity are mutually exclusive")
    return args


def main(argv=None):
    args = parse_args(argv)
    output = args.output.resolve()
    # Prevent stale successful reports from surviving a failed rerun.
    output.mkdir(parents=True, exist_ok=True)
    for name in ("raw.json", "summary.json", "summary.csv", "REPORT.md"):
        if (output / name).exists():
            raise ValueError(f"{output / name} already exists; choose a new --output directory")
    cpu = choose_cpu(args.cpu, args.no_affinity)
    started = stamp()
    commands = build(output, args.skip_build)
    raw = {
        "schema": 1, "started_at": started, "finished_at": None, "complete": False,
        "config": {"sizes": args.sizes, "shapes": args.shapes, "samples": args.samples,
                   "warmups": args.warmups, "rounds": args.rounds, "cpu": cpu,
                   "skip_build": args.skip_build, "build_commands": commands,
                   "invocation": [sys.executable, *sys.argv]},
        "environment": environment(cpu), "datasets": [], "runs": [],
    }
    for n in args.sizes:
        for shape in args.shapes:
            print(f"reference: {shape} n={n}", flush=True)
            raw["datasets"].append(reference(n, shape))
    write_json(output / "raw.json", raw)
    for round_index in range(args.rounds):
        for case_index, expected in enumerate(raw["datasets"]):
            order = ENGINES if (round_index + case_index) % 2 == 0 else tuple(reversed(ENGINES))
            for engine in order:
                print(f"round {round_index+1}/{args.rounds}: {expected['shape']} n={expected['n']} {engine}", flush=True)
                env = dict(os.environ, MOONFST_BENCH_N=str(expected["n"]),
                           MOONFST_BENCH_SHAPE=expected["shape"], MOONFST_BENCH_SAMPLES=str(args.samples),
                           MOONFST_BENCH_WARMUPS=str(args.warmups))
                def pin():
                    if cpu is not None:
                        os.sched_setaffinity(0, {cpu})
                before = time.monotonic()
                result = command([str(BINARIES[engine])], env=env,
                                 preexec_fn=pin if cpu is not None else None)
                payload = json.loads(result.stdout)
                validate(payload, expected, engine, args.samples, args.warmups)
                raw["runs"].append({"round": round_index + 1, "wall_seconds": time.monotonic() - before,
                                    "payload": payload, "stderr": result.stderr})
                write_json(output / "raw.json", raw)
    rows = summarize(raw)
    raw["finished_at"], raw["complete"] = stamp(), True
    report(output, raw, rows)
    write_json(output / "raw.json", raw)
    print(f"All checks passed; report: {output / 'REPORT.md'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"benchmark: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or "", file=sys.stderr)
            print(error.stderr or "", file=sys.stderr)
        raise SystemExit(1)
