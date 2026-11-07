#!/usr/bin/env python3
"""Count actual get() decoding work in an isolated, instrumented MoonFST copy.

No elapsed times are collected or reported. Production and benchmark sources
are copied, never edited. Use --sizes 100 for a small correctness smoke.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "oracle/target/query-cost-counts"
SNAPSHOT = WORK / "module"
FIELDS = (
    "read_nodes", "implicit_nodes", "single_nodes", "multi_nodes",
    "decoded_transitions", "indexed_nodes", "index_validation_slots",
    "index_expected_init_slots", "index_expected_fill_writes",
)

COUNTERS = '''///|
let query_cost_counters : Array[UInt64] = Array::make(9, 0UL)

///|
pub fn query_cost_reset() -> Unit {
  for i in 0..<9 {
    query_cost_counters[i] = 0UL
  }
}

///|
pub fn query_cost_snapshot() -> Array[String] {
  query_cost_counters.map(value => value.to_string())
}

'''

MAIN = '''///|
fn counter_json(values : Array[String]) -> Json {
  @json.to_json(values)
}

///|
fn run_counts() -> Json raise {
  let config = read_config()
  let dataset = make_dataset(config)
  assert_eq(config.samples, 1)
  assert_eq(config.warmups, 0)
  assert_eq(dataset.b.length(), config.n)
  assert_eq(dataset.all.length(), config.n + config.n / 2)
  assert_eq(dataset.ranges.length(), 32)
  let bytes = build(dataset.a)
  let index = @fst.Fst::from_bytes(bytes)
  assert_eq(index.stream().collect(), dataset.a)
  let mut expected_sum = 0UL
  for entry in dataset.a {
    expected_sum = expected_sum + entry.value
  }
  @codec.query_cost_reset()
  let hit = lookup_hit(index, dataset.a)
  let hit_counters = @codec.query_cost_snapshot()
  assert_eq(hit, expected_sum)
  @codec.query_cost_reset()
  let miss = lookup_miss(index, dataset.misses)
  let miss_counters = @codec.query_cost_snapshot()
  assert_eq(miss, 0UL)
  Json::object({
    "schema": @json.to_json(1),
    "n": @json.to_json(config.n),
    "shape": Json::string(config.shape),
    "dataset_hash": Json::string(checksum_entries(dataset.a).to_string()),
    "fst_bytes": @json.to_json(bytes.length()),
    "input_key_bytes": Json::string(dataset.input_key_bytes.to_string()),
    "prefix_record_count": @json.to_json(dataset.prefix_expected.length()),
    "hit_checksum": Json::string(hit.to_string()),
    "miss_checksum": Json::string(miss.to_string()),
    "hit": counter_json(hit_counters),
    "miss": counter_json(miss_counters),
  })
}

///|
fn main {
  let report = run_counts() catch { error => abort(error.to_string()) }
  println(report.stringify())
}
'''


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise RuntimeError(f"instrumentation anchor changed: {before!r}")
    return text.replace(before, after, 1)


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    if SNAPSHOT.exists():
        shutil.rmtree(SNAPSHOT)
    SNAPSHOT.mkdir()
    hashes = {}
    for relative in (Path("."), Path("codec"), Path("automaton")):
        destination = SNAPSHOT / relative
        destination.mkdir(parents=True, exist_ok=True)
        for source in sorted((ROOT / relative).iterdir()):
            if not source.is_file():
                continue
            if source.name in {"moon.mod", "moon.pkg"} or (
                source.suffix == ".mbt" and not source.name.endswith("test.mbt")
            ):
                target = destination / source.name
                shutil.copy2(source, target)
                hashes[str(source.relative_to(ROOT))] = hashlib.sha256(source.read_bytes()).hexdigest()

    decode = SNAPSHOT / "codec/decode.mbt"
    source = decode.read_text()
    source = replace_once(source,
        "  let (input, input_size) = state_input(data, address, state)",
        "  query_cost_counters[2] = query_cost_counters[2] + 1UL\n"
        "  query_cost_counters[4] = query_cost_counters[4] + 1UL\n"
        "  let (input, input_size) = state_input(data, address, state)")
    source = replace_once(source,
        "  let expected = Array::make(256, 255)",
        "  query_cost_counters[5] = query_cost_counters[5] + 1UL\n"
        "  query_cost_counters[6] = query_cost_counters[6] + 256UL\n"
        "  query_cost_counters[7] = query_cost_counters[7] + 256UL\n"
        "  query_cost_counters[8] = query_cost_counters[8] + transitions.length().to_uint64()\n"
        "  let expected = Array::make(256, 255)")
    source = replace_once(source,
        "  let sizes_at = address - count_size - 1\n",
        "  query_cost_counters[3] = query_cost_counters[3] + 1UL\n"
        "  query_cost_counters[4] = query_cost_counters[4] + ntrans.to_uint64()\n"
        "  let sizes_at = address - count_size - 1\n")
    source = replace_once(source,
        "  if address == 0 {\n",
        "  if address == 0 {\n"
        "    query_cost_counters[1] = query_cost_counters[1] + 1UL\n")
    source = replace_once(source,
        "  decode_node(data, header, address).node\n",
        "  query_cost_counters[0] = query_cost_counters[0] + 1UL\n"
        "  decode_node(data, header, address).node\n")
    decode.write_text(source)
    (SNAPSHOT / "codec/query_cost_counters.mbt").write_text(COUNTERS)

    # Reuse exactly the current benchmark's generator, key/value checksum,
    # builder, and sorted lookup loops, excluding all timing/benchmark code.
    original = (ROOT / "benchmarks/runner/main.mbt").read_text()
    prefix = original.split("///|\nfn prefix_owned(", 1)
    if len(prefix) != 2:
        raise RuntimeError("benchmark generator anchor changed")
    runner = SNAPSHOT / "query_cost_runner"
    runner.mkdir()
    (runner / "main.mbt").write_text(prefix[0] + MAIN)
    (runner / "moon.pkg").write_text('''import {
  "starAndHonor/fst",
  "starAndHonor/fst/codec",
  "moonbitlang/core/env",
  "moonbitlang/core/json",
  "moonbitlang/core/string",
}

pkgtype(kind: "executable")
''')
    (WORK / "source-sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")


def invoke(args, **kwargs):
    result = subprocess.run(args, cwd=SNAPSHOT, text=True, capture_output=True, **kwargs)
    if result.returncode:
        print(result.stdout, end="", file=sys.stderr)
        print(result.stderr, end="", file=sys.stderr)
        result.check_returncode()
    return result


def decode_counts(raw, n):
    if len(raw) != len(FIELDS) or not all(isinstance(value, str) and value.isdigit() for value in raw):
        raise ValueError("bad counter output")
    counts = dict(zip(FIELDS, map(int, raw)))
    assert counts["read_nodes"] == sum(counts[field] for field in ("implicit_nodes", "single_nodes", "multi_nodes"))
    assert counts["index_validation_slots"] == counts["indexed_nodes"] * 256
    assert counts["index_expected_init_slots"] == counts["index_validation_slots"]
    return {"totals": counts, "per_lookup": {field: value / n for field, value in counts.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=[100_000])
    parser.add_argument("--shapes", choices=["shared", "random"], nargs="+", default=["shared", "random"])
    parser.add_argument("--prepare-only", action="store_true", help="copy/instrument/build without running queries")
    args = parser.parse_args()
    if any(n < 2 or n % 2 for n in args.sizes):
        parser.error("sizes must be even integers >= 2")
    prepare()
    build = ["moon", "build", "query_cost_runner", "--target", "native", "--release", "--deny-warn"]
    print("Building isolated counter runner (not a timing benchmark).", flush=True)
    result = invoke(build)
    (WORK / "build.log").write_text(result.stdout + result.stderr)
    if args.prepare_only:
        return
    import benchmark  # Same-directory independent Python reference generator.
    reports = []
    executable = SNAPSHOT / "_build/native/release/build/query_cost_runner/query_cost_runner.exe"
    for n in args.sizes:
        for shape in args.shapes:
            print(f"Counting {shape} n={n} ...", flush=True)
            environment = dict(os.environ, MOONFST_BENCH_N=str(n), MOONFST_BENCH_SHAPE=shape,
                               MOONFST_BENCH_SAMPLES="1", MOONFST_BENCH_WARMUPS="0")
            output = invoke([str(executable)], env=environment)
            raw = json.loads(output.stdout)
            expected = benchmark.reference(n, shape)
            assert raw["dataset_hash"] == expected["dataset_hash"]
            assert raw["input_key_bytes"] == str(expected["input_key_bytes"])
            assert raw["prefix_record_count"] == expected["expected"]["prefix_owned"][1]
            assert raw["hit_checksum"] == expected["expected"]["lookup_hit"][0]
            assert raw["miss_checksum"] == "0"
            assert raw["n"] == n and raw["shape"] == shape
            report = {key: value for key, value in raw.items() if key not in {"hit", "miss"}}
            report.update({"hit": decode_counts(raw["hit"], n), "miss": decode_counts(raw["miss"], n)})
            reports.append(report)
            (WORK / f"{shape}-{n}.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, separators=(",", ":")), flush=True)
    (WORK / "latest.json").write_text(json.dumps({"schema": 1, "kind": "structural-counts-only", "cases": reports}, indent=2) + "\n")


if __name__ == "__main__":
    main()
