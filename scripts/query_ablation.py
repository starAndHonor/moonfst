#!/usr/bin/env python3
"""Prepare isolated query diagnostics; run timing only with explicit --run.

These are diagnostic prototypes, not production optimizations. The direct
lookup prototype relies on complete validation before querying and deliberately
does not repeat complete node/index validation on each lookup. Production files
and the official benchmark runner are never modified.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys

import benchmark

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "oracle/target/query-ablation"
VARIANTS = ("baseline", "skip_index_validation", "direct_lookup")
METRICS = ("lookup_hit", "lookup_miss")
WARNING = (
    "Diagnostic prototype only; not a production optimization. Full load-time "
    "verification is retained. Direct lookup does not repeat complete node/index "
    "validation for every query. This experiment is not malformed-input validation."
)

# This source is installed only inside the disposable direct_lookup module.
DIRECT_LOOKUP = r'''///|
/// DIAGNOSTIC PROTOTYPE. The caller must already have run full verify(data).
/// This does not replace read_node or its malformed-input validation contract.
/// Locate one compressed transition at a time; never materialize a Node array.
pub fn diagnostic_lookup(
  data : Bytes,
  header : Header,
  key : Bytes,
) -> UInt64? raise CodecError {
  let mut address = header.root
  let mut output = 0UL
  let mut position = 0
  while true {
    if address == 0 {
      return if position == key.length() { Some(output) } else { None }
    }
    let state = data[address].to_int()
    if (state & 128) != 0 {
      if position == key.length() {
        return None
      }
      let (input, input_size) = state_input(data, address, state)
      if key[position] != input {
        return None
      }
      if (state & 64) != 0 {
        address = address - input_size - 1
      } else {
        let sizes_at = address - input_size - 1
        let sizes = data[sizes_at].to_int()
        let tsize = sizes >> 4
        let osize = sizes & 15
        let start = sizes_at - tsize - osize
        output = checked_add(output, unpack(data, start, osize), "diagnostic output overflow")
        address = decode_delta(data, start + osize, tsize, start)
      }
      position = position + 1
      continue
    }
    let inline_count = state & 63
    let count_size = if inline_count == 0 { 1 } else { 0 }
    let ntrans = if inline_count == 0 {
      let count = data[address - 1].to_int()
      if count == 1 { 256 } else { count }
    } else {
      inline_count
    }
    let sizes_at = address - count_size - 1
    let sizes = data[sizes_at].to_int()
    let tsize = sizes >> 4
    let osize = sizes & 15
    let is_final = (state & 64) != 0
    let index_size = if header.version >= 2UL && ntrans > 32 { 256 } else { 0 }
    let inputs_end = sizes_at - index_size
    let deltas_end = inputs_end - ntrans
    let outputs_end = deltas_end - ntrans * tsize
    let start = outputs_end - ntrans * osize - (if is_final { osize } else { 0 })
    if position == key.length() {
      return if is_final {
        Some(checked_add(output, unpack(data, start, osize), "diagnostic final output overflow"))
      } else {
        None
      }
    }
    let input = key[position]
    let selected = if index_size != 0 {
      let index = data[inputs_end + input.to_int()].to_int()
      if index >= ntrans { return None }
      index
    } else {
      let mut lower = 0
      let mut upper = ntrans
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if data[inputs_end - middle - 1] < input {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      if lower >= ntrans || data[inputs_end - lower - 1] != input {
        return None
      }
      lower
    }
    output = checked_add(
      output,
      unpack(data, outputs_end - (selected + 1) * osize, osize),
      "diagnostic output overflow",
    )
    address = decode_delta(data, deltas_end - (selected + 1) * tsize, tsize, start)
    position = position + 1
  } nobreak {
    None
  }
}
'''

LOOKUP_GET = '''pub fn Fst::get(self : Fst, key : Bytes) -> UInt64? raise FstError {
  @codec.diagnostic_lookup(self.data, self.header, key) catch {
    error => raise InvalidFormat(@debug.to_string(error))
  }
}'''

ONLY_METRICS = '''let metrics = [
    measure(
      config,
      "lookup_hit",
      () => lookup_hit(a, dataset.a),
      sum => (sum, n),
      (expected_sum, n),
    ),
    measure(
      config,
      "lookup_miss",
      () => lookup_miss(a, dataset.misses),
      found => (found, found),
      (0UL, 0UL),
    ),
  ]'''


def function_span(source, name):
    """Find the body of these known repository functions without editing others."""
    marker = f"fn {name}("
    start = source.index(marker)
    if source[start - 4:start] == "pub ":
        start -= 4
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return start, body, end


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise ValueError(f"source changed: expected one occurrence of {before!r}")
    return source.replace(before, after)


def edit_runner(source, variant):
    start, _, end = function_span(source, "describe_entries")
    source = source[:start] + source[end:]
    first = source.index("let metrics = [")
    last = source.index("\n  Json::object({", first)
    source = source[:first] + ONLY_METRICS + source[last:]
    source = replace_once(
        source, '"engine": Json::string("moonbit"),',
        '"engine": Json::string("moonbit"),\n'
        f'    "variant": Json::string("{variant}"),\n'
        '    "diagnostic_prototype": Json::boolean(true),\n'
        f'    "warning": Json::string({json.dumps(WARNING)}),',
    )
    before = "  let n = config.n.to_uint64()\n"
    check_only = '''  if @env.get_env_var("MOONFST_ABLATION_VERIFY_ONLY") is Some("1") {
    return Json::object({
      "correctness_only": Json::boolean(true),
      "variant": Json::string("VARIANT"),
      "shape": Json::string(config.shape),
      "n": @json.to_json(config.n),
      "dataset_hash": Json::string(checksum_entries(dataset.a).to_string()),
      "diagnostic_prototype": Json::boolean(true),
    })
  }
'''.replace("VARIANT", variant)
    return replace_once(source, before, check_only + before)


def skip_repeated_validation(source):
    start, body, end = function_span(source, "decode_any")
    signature = source[start:body]
    signature = replace_once(signature, "  state : Int32,\n", "  state : Int32,\n  check_index : Bool,\n")
    function = signature + source[body:end].replace(
        "if index_size != 0 {", "if index_size != 0 && check_index {"
    )
    source = source[:start] + function + source[end:]
    start, body, end = function_span(source, "decode_node")
    signature = source[start:body]
    signature = replace_once(signature, "  address : Int32,\n", "  address : Int32,\n  check_index~ : Bool = true,\n")
    function = signature + source[body:end].replace(
        "decode_any(data, header, address, state)",
        "decode_any(data, header, address, state, check_index)",
    )
    source = source[:start] + function + source[end:]
    return replace_once(
        source, "  decode_node(data, header, address).node",
        "  // Diagnostic ablation: verify() retains the default check_index=true.\n"
        "  decode_node(data, header, address, check_index=false).node",
    )


def byte_literal(value):
    return 'b"' + ''.join(f"\\x{byte:02x}" for byte in value) + '"'


def fixture_tests():
    """Test deterministic hits/misses from every committed upstream fixture."""
    manifest = json.loads((ROOT / "fixtures/manifest.json").read_text())
    chunks = []
    for case in manifest["cases"]:
        expected = json.loads((ROOT / "fixtures" / case["expected_file"]).read_text())
        data = (ROOT / "fixtures" / case["data_file"]).read_bytes()
        entries = [(bytes.fromhex(key), int(value)) for key, value in expected["entries"]]
        wanted = dict(entries)
        probes = {b"", b"\0", b"\xff", b"missing"}
        # Keep generated compiler text segments bounded on the 6000-key cases.
        # All records are tested for fixtures with <=256 keys; otherwise sample
        # evenly across the complete key range, including both endpoints.
        if len(entries) <= 256:
            selected = entries
        else:
            selected = [entries[i * (len(entries) - 1) // 255] for i in range(256)]
        probes.update(key for key, _ in selected)
        probes.update(key + b"\xfe" for key, _ in selected)
        # Long embedded fixture bytes are split into small literal segments.
        literals = [byte_literal(data[i:i + 256]) for i in range(0, len(data), 256)]
        chunks += [f'///|\ntest "upstream {case["name"]} lookup diagnostic" {{',
                   "  let data = " + " +\n    ".join(literals),
                   "  let index = Fst::from_bytes(data)"]
        for key in sorted(probes):
            value = f"Some({wanted[key]}UL)" if key in wanted else "None"
            chunks.append(f"  assert_eq(index.get({byte_literal(key)}), {value})")
        chunks.append("}\n")
    return "\n".join(chunks)


def run_command(args, *, cwd, **kwargs):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True, **kwargs)


def source_files():
    paths = [ROOT / "moon.mod", ROOT / "moon.pkg", ROOT / "README.md", ROOT / "LICENSE"]
    for path in ROOT.glob("*.mbt"):
        if not path.name.endswith(("_test.mbt", "_wbtest.mbt")):
            paths.append(path)
    for package in ("codec", "automaton", "benchmarks/runner"):
        paths.append(ROOT / package / "moon.pkg")
        for path in (ROOT / package).glob("*.mbt"):
            if not path.name.endswith(("_test.mbt", "_wbtest.mbt")):
                paths.append(path)
    return sorted(paths)


def prepare():
    current = (ROOT / "fst.mbt").read_text()
    start, _, end = function_span(current, "Fst::get")
    if "packed_lookup" in current[start:end]:
        raise ValueError(
            "This historical ablation requires the pre-optimization decoder-based get. "
            "Production now uses packed_lookup; use scripts/benchmark.py to measure it. "
            "Existing diagnostic snapshots and reports have not been overwritten."
        )
    WORK.mkdir(parents=True, exist_ok=True)
    files = source_files()
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
    tests = fixture_tests()
    for variant in VARIANTS:
        directory = WORK / variant
        directory.mkdir(exist_ok=True)
        # Recreate only source files, preserving potentially expensive build caches.
        for path in files:
            target = directory / path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        runner = directory / "benchmarks/runner/main.mbt"
        runner.write_text(edit_runner(runner.read_text(), variant))
        if variant == "skip_index_validation":
            decoder = directory / "codec/decode.mbt"
            decoder.write_text(skip_repeated_validation(decoder.read_text()))
        elif variant == "direct_lookup":
            (directory / "codec/diagnostic_lookup.mbt").write_text(DIRECT_LOOKUP)
            fst = directory / "fst.mbt"
            source = fst.read_text()
            start, _, end = function_span(source, "Fst::get")
            fst.write_text(source[:start] + LOOKUP_GET + source[end:])
        (directory / "query_ablation_wbtest.mbt").write_text(tests)
        (directory / "DIAGNOSTIC_ONLY.md").write_text(f"# {variant}\n\n{WARNING}\n")
        print(f"prepare/build: {variant}", flush=True)
        log = []
        for command in (
            ["moon", "fmt"],
            ["moon", "build", "benchmarks/runner", "--target", "native", "--release", "--deny-warn"],
            ["moon", "test", "query_ablation_wbtest.mbt", "--target", "native", "--release", "--deny-warn"],
        ):
            result = run_command(command, cwd=directory)
            log.append("$ " + " ".join(command) + "\n" + result.stdout + result.stderr)
        # Small dataset correctness only: the runner returns before any timers.
        binary = directory / "_build/native/release/build/benchmarks/runner/runner.exe"
        for shape in ("shared", "random"):
            env = dict(os.environ, MOONFST_BENCH_N="100", MOONFST_BENCH_SHAPE=shape,
                       MOONFST_ABLATION_VERIFY_ONLY="1")
            result = run_command([str(binary)], cwd=directory, env=env)
            payload = json.loads(result.stdout)
            assert payload["correctness_only"] is True
            assert payload["dataset_hash"] == benchmark.reference(100, shape)["dataset_hash"]
            log.append(f"correctness_only {shape}: {result.stdout.strip()}")
        (directory / "build.log").write_text("\n".join(log) + "\n")
        print(f"ready: {variant}; fixture and untimed dataset checks passed", flush=True)
    (WORK / "source_fingerprint.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (WORK / "README.md").write_text(
        "# Query ablation diagnostic prototypes\n\n" + WARNING + "\n\n"
        "- baseline: unchanged production query implementation.\n"
        "- skip_index_validation: full load-time verify; skip only repeated "
        "256-byte index consistency validation during read_node.\n"
        "- direct_lookup: full load-time verify; inspect compressed node metadata "
        "and only the target edge, without full transition-array decoding.\n\n"
        "Run only after coordinating an idle measurement window:\n"
        "`python3 scripts/query_ablation.py --run --skip-build`\n\n"
        "Default timing: N=100000, both shapes, three rotated process rounds, "
        "7 samples and 2 warmups per process, CPU 2.\n"
    )


def run_timings(args):
    if not hasattr(os, "sched_getaffinity") or 2 not in os.sched_getaffinity(0):
        raise ValueError("CPU 2 must be available for this diagnostic experiment")
    reports = []
    metadata = {
        "warning": WARNING, "cpu": 2, "rounds": 3,
        "samples_per_process": 7, "warmups_per_process": 2,
        "binary_sha256": {
            variant: hashlib.sha256((WORK / variant / "_build/native/release/build/benchmarks/runner/runner.exe").read_bytes()).hexdigest()
            for variant in VARIANTS
        },
    }
    (WORK / "summary.json").unlink(missing_ok=True)
    (WORK / "raw.json").write_text(json.dumps({**metadata, "complete": False, "runs": []}, indent=2) + "\n")
    expectations = {shape: benchmark.reference(args.n, shape) for shape in ("shared", "random")}
    for round_index in range(3):
        for shape_index, shape in enumerate(("shared", "random")):
            expected = expectations[shape]
            offset = (round_index + shape_index) % len(VARIANTS)
            order = VARIANTS[offset:] + VARIANTS[:offset]
            for variant in order:
                directory = WORK / variant
                binary = directory / "_build/native/release/build/benchmarks/runner/runner.exe"
                env = dict(os.environ, MOONFST_BENCH_N=str(args.n), MOONFST_BENCH_SHAPE=shape,
                           MOONFST_BENCH_SAMPLES="7", MOONFST_BENCH_WARMUPS="2")
                env.pop("MOONFST_ABLATION_VERIFY_ONLY", None)
                print(f"timing round {round_index+1}/3: {variant} {shape} n={args.n} CPU=2", flush=True)
                result = run_command([str(binary)], cwd=directory, env=env,
                                     preexec_fn=lambda: os.sched_setaffinity(0, {2}))
                payload = json.loads(result.stdout)
                assert payload["variant"] == variant and payload["n"] == args.n
                assert payload["shape"] == shape and payload["samples"] == 7 and payload["warmups"] == 2
                assert payload["dataset_hash"] == expected["dataset_hash"]
                assert [metric["name"] for metric in payload["metrics"]] == list(METRICS)
                for metric in payload["metrics"]:
                    assert [metric["checksum"], metric["result_count"]] == expected["expected"][metric["name"]]
                    assert len(metric["samples_us"]) == 7
                    assert all(type(time) in (int, float) and math.isfinite(time) and time > 0
                               for time in metric["samples_us"])
                reports.append({"round": round_index + 1, "payload": payload, "stderr": result.stderr})
                (WORK / "raw.json").write_text(json.dumps({
                    **metadata, "complete": False, "runs": reports,
                }, indent=2) + "\n")
    rows = []
    for shape in ("shared", "random"):
        for variant in VARIANTS:
            selected = [run["payload"] for run in reports
                        if run["payload"]["shape"] == shape and run["payload"]["variant"] == variant]
            payload = selected[0]
            for metric in payload["metrics"]:
                times = [time for run in selected for item in run["metrics"]
                         if item["name"] == metric["name"] for time in item["samples_us"]]
                rows.append({"shape": payload["shape"], "variant": payload["variant"],
                             "n": args.n, "metric": metric["name"],
                             **benchmark.statistics_us(times),
                             "checksum": metric["checksum"], "result_count": metric["result_count"]})
    baseline = {(row["shape"], row["metric"]): row["median_us"] for row in rows if row["variant"] == "baseline"}
    for row in rows:
        before = baseline[(row["shape"], row["metric"])]
        row["baseline_over_variant"] = before / row["median_us"]
        row["time_reduction_vs_baseline"] = 1.0 - row["median_us"] / before
    (WORK / "raw.json").write_text(json.dumps({
        **metadata, "complete": True, "runs": reports,
    }, indent=2) + "\n")
    (WORK / "summary.json").write_text(json.dumps({**metadata, "rows": rows}, indent=2) + "\n")
    for row in rows:
        print(f"{row['shape']:6} {row['variant']:22} {row['metric']:11} {row['median_us']:12.3f} us")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="explicitly run CPU-2 timing after preparation")
    parser.add_argument("--skip-build", action="store_true", help="reuse already prepared diagnostic binaries")
    parser.add_argument("--n", type=int, default=100000)
    args = parser.parse_args()
    if args.n < 2 or args.n % 2 or args.n > 1431655764:
        parser.error("n must be even, >= 2 and <= 1431655764")
    if not args.skip_build:
        prepare()
    if args.run:
        run_timings(args)
    else:
        print("Prepared only; no benchmark timing run. Use --run after coordination.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, AssertionError, subprocess.CalledProcessError) as error:
        print(f"query_ablation: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or "", file=sys.stderr)
            print(error.stderr or "", file=sys.stderr)
        raise SystemExit(1)
