#!/usr/bin/env python3
"""Linux gprof diagnosis of lookup_hit, using a separate generated-C copy.

Build the normal benchmark first. Adds -pg only to a disposable C object;
moncontrol enables sampling only inside lookup_hit. Instrumented elapsed times
are NOT benchmark results. Prebuilt runtime/allocator objects lack call counts,
but their static executable code can appear in the sampling histogram.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "_build/native/release/build"
WORK = ROOT / "oracle/target/query-profile"


def instrument(source):
    pattern = r"static struct moonbit_result_\d+ \w+lookup__hit\([^;]*?\) \{"
    matches = list(re.finditer(pattern, source))
    if len(matches) != 1:
        raise ValueError("expected exactly one generated lookup_hit definition")
    start = matches[0].end()
    level, end = 1, start
    while level:
        level += (source[end] == "{") - (source[end] == "}")
        end += 1
    body = source[start:end - 1]
    if "return " not in body:
        raise ValueError("missing lookup_hit return")
    body = "\n  moncontrol(1);\n" + re.sub(r"\breturn ", "moncontrol(0); return ", body)
    source = source[:start] + body + source[end - 1:]
    main = "int main(int argc, char** argv) {"
    if source.count(main) != 1:
        raise ValueError("missing generated C main")
    source = source.replace(main, main + "\n  moncontrol(0);", 1)
    return "extern void moncontrol(int);\n" + source


def call(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, text=True, capture_output=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shape", choices=["shared", "random"], default="random")
    parser.add_argument("--n", type=int, default=100000)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/profiles/query-analysis")
    args = parser.parse_args()
    if args.n < 2 or args.n % 2 or args.samples < 1:
        parser.error("n must be even and >= 2; samples must be positive")
    if not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0):
        parser.error("a permitted Linux CPU is required")
    WORK.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    original = BUILD / "benchmarks/runner/runner.c"
    source = WORK / "profile.c"
    source.write_text(instrument(original.read_text()))
    moon_home = Path(os.environ.get("MOON_HOME", Path.home() / ".moon"))
    obj, executable = WORK / "profile.o", WORK / "profile.exe"
    commands = [
        ["cc", "-o", obj, "-I" + str(moon_home / "include"), "-c", "-fwrapv",
         "-fno-strict-aliasing", "-ffp-contract=off", "-O2",
         "-DMOONBIT_ALLOCATOR=MOONBIT_ALLOCATOR_MIMALLOC", "-pg", "-g", source],
        ["cc", "-o", executable, "-O2", "-pg", moon_home / "lib/libmoonbitrun.o",
         obj, BUILD / "libruntime.a", "-lm", moon_home / "lib/libbacktrace.a"],
    ]
    for command in commands:
        print("Compiling independent profiling binary.", flush=True)
        call(command)
    run_directory = WORK / args.shape
    run_directory.mkdir(exist_ok=True)
    gmon = run_directory / "gmon.out"
    if gmon.exists():
        gmon.unlink()
    env = dict(os.environ, MOONFST_BENCH_N=str(args.n), MOONFST_BENCH_SHAPE=args.shape,
               MOONFST_BENCH_SAMPLES=str(args.samples), MOONFST_BENCH_WARMUPS="0")
    print("Profiling only lookup_hit; instrumented timings will not be reported.", flush=True)
    run = call([executable], cwd=run_directory, env=env,
               preexec_fn=lambda: os.sched_setaffinity(0, {args.cpu}))
    import benchmark
    payload = json.loads(run.stdout)
    benchmark.validate(payload, benchmark.reference(args.n, args.shape), "moonbit", args.samples, 0)
    report = call(["gprof", "-b", executable, gmon])
    flat_path = args.output / f"gprof-{args.shape}.txt"
    flat_path.write_text(report.stdout)
    # Optimized GCC clones such as Array.push.isra.0 can be misattributed to
    # adjacent symbols by plain gprof. Resolve source lines as a second view.
    line_report = call(["gprof", "-b", "-l", executable, gmon])
    (args.output / f"gprof-{args.shape}-lines.txt").write_text(line_report.stdout)
    metadata = {
        "kind": "instrumented-sampling-diagnostic", "shape": args.shape, "n": args.n,
        "hit_batches": args.samples, "cpu": args.cpu, "correctness": "all benchmark checks passed",
        "source_c_sha256": hashlib.sha256(original.read_bytes()).hexdigest(),
        "commands": [[str(value) for value in command] for command in commands],
        "scope": "moncontrol enabled only inside lookup_hit; startup/build/other operations excluded",
        "limitations": "Application C rebuilt with -pg; instrumentation perturbs execution. "
                      "Prebuilt runtime/allocator not instrumented for call counts. "
                      "gprof histogram excludes shared-library code. Sample fractions are diagnostic, "
                      "not a decomposition of uninstrumented benchmark elapsed time. "
                      "Plain gprof may misname optimized clones; use the line-resolved report "
                      "and verify symbols with readelf/objdump before attributing costs.",
    }
    (args.output / f"gprof-{args.shape}.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(flat_path)


if __name__ == "__main__":
    main()
