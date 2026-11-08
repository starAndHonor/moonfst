#!/usr/bin/env python3
"""Isolated Linux gprof diagnosis of the stream_owned collect callback.

Uses the already-built generated C, never rebuilds or modifies MoonBit source.
Only collect invoked by the stream_owned benchmark callback is sampled;
initial correctness, prefix collection, other metrics and result hashing are
excluded. Instrumented elapsed times are not benchmark results.
"""
from __future__ import annotations

import argparse
import bisect
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys

import benchmark

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "_build/native/release/build"


def functions(source):
    pattern = re.compile(r"(?m)^static (struct moonbit_result_\d+) (\w+)\([^;]*?\n\) \{")
    for match in pattern.finditer(source):
        start, depth, end = match.end(), 1, match.end()
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        yield match, end, source[start:end - 1]


def wrap_returns(body, return_type, after):
    # Evaluate a returned function call before disabling its profiling scope.
    # A plain 'moncontrol(0); return collect(...)' would disable too early.
    returns = 0
    def replace(match):
        nonlocal returns
        returns += 1
        return "{ " + return_type + " moonfst_profile_return = " + match.group(1) + "; " + after + " return moonfst_profile_return; }"
    result = re.sub(r"\breturn\s+([^;]+);", replace, body)
    if not returns:
        raise ValueError("instrumented generated function has no return")
    return result


def instrument(source):
    candidates = list(functions(source))
    collectors = [(match, end, body) for match, end, body in candidates
                  if match.group(2).endswith("Stream7collect")]
    callbacks = [(match, end, body) for match, end, body in candidates
                 if "benchmarks6runner3runC" in match.group(2)
                 and re.search(r"\b\w+Stream7collect\(", body)]
    if len(collectors) != 1 or len(callbacks) != 1:
        raise ValueError(f"expected one collect and one measured callback, got {len(collectors)}/{len(callbacks)}")
    edits = []
    match, end, body = callbacks[0]
    body = "\n  moonfst_profile_requested = 1;\n" + wrap_returns(
        body, match.group(1), "moonfst_profile_requested = 0;",
    )
    edits.append((match.end(), end - 1, body))
    match, end, body = collectors[0]
    body = "\n  int moonfst_profile_collect = moonfst_profile_requested;\n" + \
           "  if (moonfst_profile_collect) { ++moonfst_profile_collect_calls; moncontrol(1); }\n" + \
           wrap_returns(body, match.group(1), "if (moonfst_profile_collect) moncontrol(0);")
    edits.append((match.end(), end - 1, body))
    for first, last, replacement in sorted(edits, reverse=True):
        source = source[:first] + replacement + source[last:]
    main = "int main(int argc, char** argv) {"
    if source.count(main) != 1:
        raise ValueError("expected generated native C main")
    source = source.replace(main, main + "\n  moncontrol(0);", 1)
    # Count the scoped collections independently: collect's own mcount runs
    # before moncontrol(1), so its gprof entry count can be zero legitimately.
    last_return = source.rfind("return 0;")
    source = source[:last_return] + \
        'fprintf(stderr, "MOONFST_PROFILE_COLLECT_CALLS=%llu\\n", moonfst_profile_collect_calls);\n  ' + \
        source[last_return:]
    preamble = "#include <stdio.h>\nextern void moncontrol(int);\n" \
               "static int moonfst_profile_requested;\n" \
               "static unsigned long long moonfst_profile_collect_calls;\n"
    return preamble + source, {"collect": collectors[0][0].group(2), "callback": callbacks[0][0].group(2)}


def call(command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, text=True, capture_output=True, **kwargs)


def address_mapping(gmon, symbol_report):
    """Resolve Linux ELF64 LE gmon PCs using sized symbols, including clones.

    The native record layout is defined by sys/gmon_out.h. In particular,
    histogram entries are uint16 and call-arc counts are uint32. Matching a
    sized .part/.isra symbol prevents gprof's nearest-global-name attribution.
    """
    symbols = []
    for line in symbol_report.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in "tTwW":
            symbols.append((int(parts[0], 16), int(parts[1], 16), parts[3]))
    symbols.sort()
    starts = [symbol[0] for symbol in symbols]

    def resolve(pc):
        index = bisect.bisect_right(starts, pc) - 1
        if index >= 0:
            start, size, name = symbols[index]
            if pc < start + size:
                return name, hex(pc - start)
        return "<unmapped>", hex(pc)

    data = gmon.read_bytes()
    if data[:8] != b"gmon\x01\x00\x00\x00":
        raise ValueError("address mapping requires GNU gmon version 1, little endian")
    offset, arcs, sites, histogram = 20, [], [], Counter()
    rates = set()
    while offset < len(data):
        tag = data[offset]
        offset += 1
        if tag == 0:
            low, high, count, rate, _, _ = struct.unpack_from("<QQII15sc", data, offset)
            offset += 40
            end = offset + count * 2
            if high <= low or not count or end > len(data):
                raise ValueError("invalid native gmon histogram")
            rates.add(rate)
            for index, (ticks,) in enumerate(struct.iter_unpack("<H", data[offset:end])):
                if ticks:
                    # A bin covers a small address interval, not an exact PC.
                    pc = int(low + (high - low) * (index + 0.5) / count)
                    name, within = resolve(pc)
                    histogram[name] += ticks
                    sites.append({"pc": hex(pc), "symbol": name, "offset": within, "ticks": ticks})
            offset = end
        elif tag == 1:
            caller, callee, count = struct.unpack_from("<QQI", data, offset)
            offset += 20
            arcs.append({"caller": resolve(caller)[0], "callee": resolve(callee)[0],
                         "calls": count, "caller_pc": hex(caller), "callee_pc": hex(callee)})
        else:
            raise ValueError(f"unsupported native gmon tag {tag}")
    if len(rates) != 1:
        raise ValueError("expected one compatible histogram sampling rate")
    return {"ticks": sum(histogram.values()), "sample_rate": rates.pop(),
            "histogram_by_exact_symbol": [{"symbol": name, "ticks": ticks}
                                           for name, ticks in histogram.most_common()],
            "call_arcs": arcs, "sample_sites": sorted(sites, key=lambda site: -site["ticks"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shapes", choices=["shared", "random"], nargs="+", default=["shared", "random"])
    parser.add_argument("--n", type=int, default=100000)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.n < 2 or args.n % 2 or args.samples < 1 or len(set(args.shapes)) != len(args.shapes):
        parser.error("n must be even and >= 2; samples positive; shapes unique")
    if not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0):
        parser.error("a permitted Linux CPU is required")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = args.output.resolve() if args.output else ROOT / "artifacts/profiles/stream-analysis" / stamp
    output.mkdir(parents=True, exist_ok=False)
    work = ROOT / "oracle/target/stream-profile" / stamp
    work.mkdir(parents=True, exist_ok=False)
    original = BUILD / "benchmarks/runner/runner.c"
    original_bytes = original.read_bytes()
    source, names = instrument(original_bytes.decode())
    profile_c = work / "profile.c"
    profile_c.write_text(source)
    moon_home = Path(os.environ.get("MOON_HOME", Path.home() / ".moon"))
    obj, executable = work / "profile.o", work / "profile.exe"
    commands = [
        ["cc", "-o", obj, "-I" + str(moon_home / "include"), "-c", "-fwrapv",
         "-fno-strict-aliasing", "-ffp-contract=off", "-O2",
         "-DMOONBIT_ALLOCATOR=MOONBIT_ALLOCATOR_MIMALLOC", "-pg", "-g", profile_c],
        ["cc", "-o", executable, "-O2", "-pg", moon_home / "lib/libmoonbitrun.o",
         obj, BUILD / "libruntime.a", "-lm", moon_home / "lib/libbacktrace.a"],
    ]
    for command in commands:
        print("Compiling independent profiling C copy.", flush=True)
        call(command)
    symbol_report = call(["nm", "-n", "-S", "--defined-only", executable]).stdout
    (output / "symbols.txt").write_text(symbol_report)
    (output / "readelf-symbols.txt").write_text(call(["readelf", "-Ws", executable]).stdout)
    if executable.read_bytes()[:6] != b"\x7fELF\x02\x01":
        raise ValueError("raw gmon address mapping currently supports ELF64 little endian")
    resolved_profiles = {}
    for shape in args.shapes:
        directory = work / shape
        directory.mkdir()
        env = dict(os.environ, MOONFST_BENCH_N=str(args.n), MOONFST_BENCH_SHAPE=shape,
                   MOONFST_BENCH_SAMPLES=str(args.samples), MOONFST_BENCH_WARMUPS="0")
        print(f"Profiling {shape} stream_owned collect only; timings are diagnostic.", flush=True)
        run = call([executable], cwd=directory, env=env,
                   preexec_fn=lambda: os.sched_setaffinity(0, {args.cpu}))
        payload = json.loads(run.stdout)
        benchmark.validate(payload, benchmark.reference(args.n, shape), "moonbit", args.samples, 0)
        count = re.search(r"MOONFST_PROFILE_COLLECT_CALLS=(\d+)", run.stderr)
        if not count or int(count.group(1)) != args.samples:
            raise ValueError("profiling callback scope did not collect the expected number of batches")
        gmon = directory / "gmon.out"
        resolved_profiles[shape] = address_mapping(gmon, symbol_report)
        (output / f"gprof-{shape}.txt").write_text(call(["gprof", "-b", executable, gmon]).stdout)
        (output / f"gprof-{shape}-lines.txt").write_text(call(["gprof", "-b", "-l", executable, gmon]).stdout)
        (output / f"gprof-{shape}-flat.txt").write_text(call(["gprof", "-b", "-p", executable, gmon]).stdout)
        (output / f"gprof-{shape}-flat-lines.txt").write_text(call(["gprof", "-b", "-p", "-l", executable, gmon]).stdout)
        (output / f"checksums-{shape}.json").write_text(json.dumps({
            "diagnostic_only": True, "dataset_hash": payload["dataset_hash"],
            "metrics": [{key: metric[key] for key in ("name", "checksum", "result_count")} for metric in payload["metrics"]],
        }, indent=2) + "\n")
    (output / "raw-address-mapping.json").write_text(json.dumps(resolved_profiles, indent=2) + "\n")
    # Save exact machine-code views for the traversal functions and GCC clones.
    names_to_disassemble = []
    for line in symbol_report.splitlines():
        name = line.split()[-1]
        if any(marker in name for marker in ("Stream4next", "Stream7collect", "traversal__node", "Array4push")):
            names_to_disassemble.append(name)
    chunks = [call(["objdump", "-d", "--no-show-raw-insn", "--disassemble=" + name, executable]).stdout
              for name in names_to_disassemble]
    (output / "traversal-disassembly.txt").write_text("\n".join(chunks))
    metadata = {
        "kind": "instrumented-stream-sampling-diagnostic", "n": args.n, "shapes": args.shapes,
        "collect_batches_per_shape": args.samples, "expected_records_per_shape": args.samples * args.n,
        "cpu": args.cpu, "correctness": "all benchmark checks and callback counts passed",
        "source_c_sha256": hashlib.sha256(original_bytes).hexdigest(), "source_c": str(original),
        "instrumented_c": str(profile_c), "symbols": names,
        "commands": [[str(value) for value in command] for command in commands],
        "scope": "Only full-range collect invoked from measured stream_owned callback; excludes startup, construction, initial correctness, prefix_owned, other metrics, hashing, and output destruction.",
        "limitations": "-pg changes execution. Prebuilt runtime/allocator have no mcount call counts, but static code may appear in the histogram; shared-library code is omitted. GCC clones may be misnamed by gprof; inspect line-resolved reports, symbol address/size and disassembly. Fractions are not an elapsed-time decomposition of uninstrumented execution. collect's own mcount precedes enabling profiling; exact batch count is separately checked.",
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(output, flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"profile_stream: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or "", file=sys.stderr)
            print(error.stderr or "", file=sys.stderr)
        raise SystemExit(1)
