#!/usr/bin/env python3
"""Report physical source lines, separating MoonBit implementation, tests and generated code.

This is an auditable size measurement, not a claim that every line is necessary.
Rust oracle, Python scripts, fixtures, integration harness and generated tables
never contribute to the production MoonBit total.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {".git", ".moon", ".mooncakes", ".repos", "_build", "target", ".venv", "node_modules", "__pycache__"}


def code_lines(source: str) -> int:
    """Strip line/block comments while retaining string literals and line structure."""
    lines_with_code = set()
    index, line, depth = 0, 1, 0
    quote = None
    while index < len(source):
        char = source[index]
        following = source[index:index + 2]
        if char == "\n":
            line += 1
        if depth:
            if following == "/*":
                depth += 1
                index += 2
            elif following == "*/":
                depth -= 1
                index += 2
            else:
                index += 1
            continue
        if quote is not None:
            if not char.isspace():
                lines_with_code.add(line)
            if char == "\\":
                if index + 1 < len(source) and source[index + 1] == "\n":
                    line += 1
                index += 2
                continue
            if char == quote:
                quote = None
            index += 1
            continue
        if following == "//":
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
            continue
        if following == "/*":
            depth = 1
            index += 2
            continue
        if char in {'"', "'"}:
            quote = char
        if not char.isspace():
            lines_with_code.add(line)
        index += 1
    return len(lines_with_code)


def classify(path: Path, source: str) -> str:
    relative = path.relative_to(ROOT)
    if path.suffix != ".mbt":
        return "tooling_non_moonbit"
    if "generated" in path.name or "@generated" in source[:1000] or "DO NOT EDIT" in source[:1000]:
        return "generated_moonbit"
    if relative.parts[0] in {"oracle", "scripts", "fixtures", "integration"}:
        return "integration_moonbit"
    if (path.name.endswith(("_test.mbt", "_wbtest.mbt", "_bench.mbt", "_bench_test.mbt"))
            or any(part in {"tests", "test", "testing", "testdata", "fuzz", "fuzzing"} for part in relative.parts[:-1])):
        return "test_moonbit"
    if relative.parts[0] in {"examples", "demo", "demos", "bench", "benchmarks"}:
        return "example_moonbit"
    return "production_moonbit"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--minimum-production", type=int, default=0,
                        help="Fail if non-generated production MoonBit code is below this count.")
    args = parser.parse_args()
    rows = []
    totals = defaultdict(lambda: {"files": 0, "physical_lines": 0, "code_lines": 0})
    paths = []
    for directory, subdirectories, filenames in os.walk(ROOT):
        subdirectories[:] = [name for name in subdirectories if name not in IGNORED]
        for filename in filenames:
            path = Path(directory) / filename
            if path.suffix in {".mbt", ".rs", ".py", ".c", ".h", ".js", ".mjs", ".sh"} and not path.is_symlink():
                paths.append(path)
    for path in sorted(paths):
        source = path.read_text(encoding="utf-8")
        group = classify(path, source)
        count = code_lines(source)
        physical = len(source.splitlines())
        rows.append({"path": str(path.relative_to(ROOT)), "category": group,
                     "physical_lines": physical, "code_lines": count})
        totals[group]["files"] += 1
        totals[group]["physical_lines"] += physical
        totals[group]["code_lines"] += count
    report = {"method": "Physical nonblank, noncomment lines; category exclusions are explicit.",
              "totals": dict(totals), "files": rows}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for group, total in sorted(totals.items()):
            print(f"{group:24} {total['files']:3} files {total['code_lines']:6} code lines "
                  f"({total['physical_lines']} physical)")
        print("Production excludes tests, generated code, examples, integration and non-MoonBit tooling.")
    production = totals["production_moonbit"]["code_lines"]
    if production < args.minimum_production:
        print(f"Production threshold failed: {production} < {args.minimum_production}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
