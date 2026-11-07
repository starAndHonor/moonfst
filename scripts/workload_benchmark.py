#!/usr/bin/env python3
"""Real-dictionary latency and isolated Linux RSS measurements against Rust fst."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import sys

try:
    from . import benchmark, prepare_workload as workload
except ImportError:
    import benchmark
    import prepare_workload as workload

ROOT = benchmark.ROOT
ENGINES = benchmark.ENGINES
BINARIES = {
    "moonbit": ROOT / "_build/native/release/build/benchmarks/workload/workload.exe",
    "rust": ROOT / "oracle/target/release/fst_workload",
}
MOON_BUILD = ["moon", "build", "benchmarks/workload", "--target", "native", "--release", "--deny-warn"]
RUST_BUILD = ["cargo", "build", "--locked", "--release", "--manifest-path", "oracle/Cargo.toml", "--bin", "fst_workload"]
MEMORY_MODES = ("memory-baseline", "memory-build", "memory-load", "memory-union")


def clean_environment(**overrides):
    return {key: value for key, value in os.environ.items() if not key.startswith("MOONFST_WORKLOAD_")} | overrides


def validate_timing(payload, expected, engine, samples, warmups):
    if not isinstance(payload, dict):
        raise ValueError("timing payload must be an object")
    fields = {"schema": 1, "engine": engine, "mode": "timing", "samples": samples, "warmups": warmups}
    fields.update({key: expected[key] for key in (
        "n", "total", "order", "query_seed", "order_hash", "dataset_hash", "b_hash", "union_hash", "input_key_bytes",
    )})
    for key, value in fields.items():
        if type(payload.get(key)) is not type(value) or payload.get(key) != value:
            raise ValueError(f"{engine}: invalid {key}: {payload.get(key)!r}, expected {value!r}")
    size = payload.get("fst_bytes")
    if type(size) is not int or size <= 0:
        raise ValueError("invalid FST size")
    metrics = payload.get("metrics")
    if not isinstance(metrics, list) or not all(isinstance(m, dict) for m in metrics):
        raise ValueError("invalid metrics")
    if [m.get("name") for m in metrics] != list(workload.METRICS):
        raise ValueError("missing, duplicate or reordered metrics")
    for metric in metrics:
        expected_pair = [str(size), expected["n"]] if metric["name"] == "build" else expected["expected"][metric["name"]]
        if (type(metric.get("checksum")) is not str or type(metric.get("result_count")) is not int
                or [metric.get("checksum"), metric.get("result_count")] != expected_pair):
            raise ValueError(f"{engine}: {metric['name']} checksum/count mismatch")
        times = metric.get("samples_us")
        if not isinstance(times, list) or len(times) != samples or not all(
            type(value) in (int, float) and math.isfinite(value) and value > 0 for value in times
        ):
            raise ValueError("invalid timing values")


def validate_memory(payload, expected, engine, mode, size):
    if not isinstance(payload, dict):
        raise ValueError("memory payload must be an object")
    checksum, count = (expected["union_hash"], expected["total"]) if mode == "memory-union" else (expected["dataset_hash"], expected["n"])
    fields = {"schema": 1, "engine": engine, "mode": mode, "n": expected["n"], "memory_source": "proc-self-status",
              "checksum": checksum, "result_count": count,
              "fst_bytes": 0 if mode == "memory-baseline" else size}
    for key, value in fields.items():
        if type(payload.get(key)) is not type(value) or payload.get(key) != value:
            raise ValueError(f"{engine}/{mode}: invalid {key}: {payload.get(key)!r} != {value!r}")
    for key in ("baseline_rss_kib", "after_rss_kib", "peak_rss_kib", "baseline_peak_rss_kib",
                "validation_after_rss_kib", "validation_peak_rss_kib"):
        if type(payload.get(key)) is not int or payload[key] <= 0:
            raise ValueError(f"invalid Linux RSS: {key}")
    # RSS and HWM are read separately; preserve observations without assuming
    # they are one atomic snapshot of the kernel's process counters.
    if payload["peak_rss_kib"] < payload["baseline_peak_rss_kib"]:
        raise ValueError("process peak RSS decreased")
    if payload["validation_peak_rss_kib"] < payload["peak_rss_kib"]:
        raise ValueError("validation peak RSS decreased")


def build(output, skip):
    logs = []
    core = Path(os.environ.get("MOON_HOME", str(Path.home()/".moon"))) / "lib/core"
    commands = [["moon", "-C", str(core), "bundle", "--target", "native", "--warn-list", "-a", "--quiet"], MOON_BUILD, RUST_BUILD]
    if not skip:
        for command in commands:
            print("build:", shlex.join(command), flush=True)
            result = benchmark.command(command)
            logs.append("$ "+shlex.join(command)+"\n"+result.stdout+result.stderr)
    for path in BINARIES.values():
        if not path.is_file():
            raise FileNotFoundError(path)
    (output/"build.log").write_text("\n".join(logs) if not skip else "Explicit --skip-build; caller must ensure source matches binaries.\n")
    plan = benchmark.command(MOON_BUILD + ["--dry-run"])
    (output/"moon-build-plan.txt").write_text(plan.stdout+plan.stderr)
    return commands


def invoke(engine, env, cpu):
    def pin():
        os.sched_setaffinity(0, {cpu})
    result = benchmark.command([str(BINARIES[engine])], env=env,
                               preexec_fn=pin if cpu is not None else None)
    return json.loads(result.stdout), result.stderr


def summarize(raw):
    rows = []
    for case in raw["datasets"]:
        selected = [run["payload"] for run in raw["runs"]
                    if run["payload"]["n"] == case["n"] and run["payload"]["order"] == case["order"]]
        for name in workload.METRICS:
            row = {"n": case["n"], "order": case["order"], "metric": name}
            for engine in ENGINES:
                reports = [r for r in selected if r["engine"] == engine]
                sizes = {r["fst_bytes"] for r in reports}
                if len(sizes) != 1:
                    raise ValueError("nondeterministic encoded size")
                times = [t for r in reports for metric in r["metrics"] if metric["name"] == name for t in metric["samples_us"]]
                row[engine] = dict(benchmark.statistics_us(times), fst_bytes=sizes.pop())
            row["moonbit_over_rust"] = row["moonbit"]["median_us"] / row["rust"]["median_us"]
            rows.append(row)
    memory_rows = []
    for n in raw["config"]["sizes"]:
        for mode in MEMORY_MODES:
            row = {"n": n, "mode": mode}
            for engine in ENGINES:
                reports = [r["payload"] for r in raw["memory_runs"]
                           if r["payload"]["n"] == n and r["payload"]["engine"] == engine and r["payload"]["mode"] == mode]
                row[engine] = {key: statistics.median(r[key] for r in reports) for key in (
                    "baseline_rss_kib", "after_rss_kib", "peak_rss_kib", "baseline_peak_rss_kib",
                )}
                row[engine]["sample_count"] = len(reports)
            memory_rows.append(row)
    return rows, memory_rows


def report(output, raw):
    rows, memory_rows = summarize(raw)
    benchmark.write_json(output/"summary.json", {"schema": 1, "timing": rows, "memory": memory_rows})
    cfg = raw["config"]
    lines = ["# 真实中文词典、查询顺序与内存基准", "",
             f"完成时间（UTC）：{raw['finished_at']}。两个实现、所有预热/采样的校验通过。",
             "", "数据：固定版本 Jieba 中文词典，保留真实词频；349,045 个唯一词条，去除一条相同重复记录。",
             "从按 UTF-8 字节排序的完整词典做固定种子 Fisher–Yates 抽样；A/B 各 N 条、重叠 N/2。",
             "每个实现使用自己构建的 FST；两边导出文件另作逐字节比较，详见 raw.json 的 encoding_checks。",
             "", f"native release，CPU {cfg['cpu']}；每项 {cfg['rounds']} 轮 × {cfg['samples']} 次采样，每轮预热 {cfg['warmups']} 次。",
             "sorted/shuffled 只改变查询顺序。mixed 请求按该顺序交替命中/近似未命中，命中率 50%。",
             "每词一次请求，未命中键为完整 UTF-8 词条后追加 FF；查询没有按词频加权，也不是实际查询日志。",
             "时间为中位数（P25–P75），单位 ms；倍数 MoonBit/Rust，小于 1 表示 MoonBit 更快。", "",
             "| N | 查询顺序 | 操作 | MoonBit ms | Rust ms | 倍数 |", "|---:|---|---|---:|---:|---:|"]
    def cell(s):
        return f"{s['median_us']/1000:.3f} ({s['p25_us']/1000:.3f}–{s['p75_us']/1000:.3f})"
    for row in rows:
        lines.append(f"| {row['n']:,} | {row['order']} | {row['metric']} | {cell(row['moonbit'])} | {cell(row['rust'])} | {row['moonbit_over_rust']:.3f}× |")
    lines += ["", "## 编码大小", "", "| N | MoonBit B | Rust B | 逐字节相同 |", "|---:|---:|---:|---|"]
    for check in raw["encoding_checks"]:
        lines.append(f"| {check['n']:,} | {check['moonbit_bytes']:,} | {check['rust_bytes']:,} | {check['identical']} |")
    lines += ["", "## 独立进程内存（KiB）", "",
              f"每项 {cfg['memory_rounds']} 个全新进程，表格为中位数。RSS 为进程驻留集，不是精确堆分配量。",
              "before/after 在操作边界采集 /proc/self/status 的 VmRSS；peak 为截至操作结束的 VmHWM 高水位。",
              "baseline 构造并持有输入记录；build 持有输入与新编码；union 持有输入、两个已验证 FST 与拥有所有权的结果。",
              "load 使用预先导出的 FST，进程中不生成词典或构建 FST；before 已包含读入的编码。",
              "Rust load 为打开/CRC，MoonBit load 还做完整可达图验证，工作量不同。",
              "采集后再验证内容；保留 baseline_peak 和验证后快照于 raw.json。高水位可能由前期准备产生，不能当作操作净分配。", "",
              "| N | 操作 | Moon before | Moon after | Moon peak | Rust before | Rust after | Rust peak |",
              "|---:|---|---:|---:|---:|---:|---:|---:|"]
    for row in memory_rows:
        values = [row[e][k] for e in ENGINES for k in ("baseline_rss_kib", "after_rss_kib", "peak_rss_kib")]
        lines.append(f"| {row['n']:,} | {row['mode']} | "+" | ".join(f"{v:,.0f}" for v in values)+" |")
    lines += ["", "## 解释范围", "", "- 本次增加真实词典和打乱查询；仍是单机 native 内存热运行，不声称冷缓存、磁盘吞吐或其他后端性能。",
              "- 全新进程用于区分内存阶段，不等于操作系统冷缓存。内存采样与计时进程分开。",
              "- C 辅助代码仅服务开发工具的文件 I/O 和 Linux RSS；发布的 FST 运行库仍为纯 MoonBit。",
              "- 输入、排序、查询准备、完整校验、结果 hash 和最终结果销毁不计入计时。两边遍历/并集都返回拥有 key 的记录。",
              "- 语料版本、SHA256、抽样种子、查询顺序 hash、源码/二进制指纹、原始样本见 [raw.json](raw.json)。",
              "- 语料来源与 MIT 版权见仓库 benchmarks/corpora/；RSS 总量包含语言运行时、分配器保留和输入表示差异。", ""]
    temporary = output/"REPORT.md.tmp"
    temporary.write_text("\n".join(lines))
    temporary.replace(output/"REPORT.md")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", nargs="+", type=int, default=[10000, 100000, 200000])
    parser.add_argument("--orders", nargs="+", choices=["sorted", "shuffled"], default=["sorted", "shuffled"])
    parser.add_argument("--query-seed", type=int, default=workload.QUERY_SEED)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--memory-rounds", type=int, default=3)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if (any(n < 2 or n % 2 for n in args.sizes) or len(set(args.sizes)) != len(args.sizes)
            or len(set(args.orders)) != len(args.orders) or min(args.samples, args.rounds, args.memory_rounds) < 1
            or args.warmups < 0 or not 0 <= args.query_seed <= 0xFFFFFFFF):
        parser.error("invalid sizes, duplicate cases, samples/rounds, warmups or query seed")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any((output/name).exists() for name in ("raw.json", "summary.json", "REPORT.md")):
        raise ValueError("choose a fresh output directory")
    cpu = benchmark.choose_cpu(args.cpu, False)
    commands = build(output, args.skip_build)
    cache = ROOT / "benchmarks/data"
    exports = cache / "exports" / (output.name+"-"+hashlib.sha256(str(output).encode()).hexdigest()[:12])
    exports.mkdir(parents=True, exist_ok=True)
    raw = {"schema": 1, "started_at": benchmark.stamp(), "finished_at": None, "complete": False,
           "config": dict(sizes=args.sizes, orders=args.orders, query_seed=args.query_seed,
                          samples=args.samples, warmups=args.warmups, rounds=args.rounds,
                          memory_rounds=args.memory_rounds, cpu=cpu, build_commands=commands,
                          invocation=[sys.executable, *sys.argv]),
           "environment": benchmark.environment(cpu, BINARIES), "corpora": [], "datasets": [],
           "runs": [], "memory_runs": [], "encoding_checks": []}
    for n in args.sizes:
        path = cache/f"jieba-{n}.bin"
        raw["corpora"].append(workload.prepare(n, cache/"jieba-dict.txt", path))
        for order in args.orders:
            raw["datasets"].append(workload.reference(path.read_bytes(), order, args.query_seed))
    def save():
        temporary = output/"raw.json.tmp"
        benchmark.write_json(temporary, raw)
        temporary.replace(output/"raw.json")
    save()
    for round_index in range(args.rounds):
        for case_index, expected in enumerate(raw["datasets"]):
            engines = ENGINES if (round_index+case_index) % 2 == 0 else tuple(reversed(ENGINES))
            for engine in engines:
                print(f"timing {round_index+1}/{args.rounds}: n={expected['n']} {expected['order']} {engine}", flush=True)
                env = clean_environment(MOONFST_WORKLOAD_INPUT=str(cache/f"jieba-{expected['n']}.bin"),
                           MOONFST_WORKLOAD_MODE="timing", MOONFST_WORKLOAD_ORDER=expected["order"],
                           MOONFST_WORKLOAD_QUERY_SEED=str(args.query_seed), MOONFST_WORKLOAD_SAMPLES=str(args.samples),
                           MOONFST_WORKLOAD_WARMUPS=str(args.warmups),
                           MOONFST_WORKLOAD_WRITE_FST=str(exports/f"{expected['n']}-{engine}.fst"))
                payload, stderr = invoke(engine, env, cpu)
                validate_timing(payload, expected, engine, args.samples, args.warmups)
                raw["runs"].append(dict(round=round_index+1, payload=payload, stderr=stderr))
                save()
    for n in args.sizes:
        encoded = {engine: (exports/f"{n}-{engine}.fst").read_bytes() for engine in ENGINES}
        for engine in ENGINES:
            reported_sizes = {run["payload"]["fst_bytes"] for run in raw["runs"]
                              if run["payload"]["n"] == n and run["payload"]["engine"] == engine}
            if reported_sizes != {len(encoded[engine])}:
                raise ValueError("exported FST length differs from timing runs")
        raw["encoding_checks"].append(dict(n=n, identical=encoded["moonbit"] == encoded["rust"],
            moonbit_bytes=len(encoded["moonbit"]), rust_bytes=len(encoded["rust"]),
            sha256={engine: hashlib.sha256(data).hexdigest() for engine, data in encoded.items()}))
        expected = next(case for case in raw["datasets"] if case["n"] == n)
        for iteration in range(args.memory_rounds):
            for mode_index, mode in enumerate(MEMORY_MODES):
                engines = ENGINES if (iteration+mode_index) % 2 == 0 else tuple(reversed(ENGINES))
                for engine in engines:
                    print(f"memory {iteration+1}/{args.memory_rounds}: n={n} {mode} {engine}", flush=True)
                    env = clean_environment(MOONFST_WORKLOAD_INPUT=str(cache/f"jieba-{n}.bin"),
                               MOONFST_WORKLOAD_MODE=mode, MOONFST_WORKLOAD_N=str(n),
                               MOONFST_WORKLOAD_FST_PATH=str(exports/f"{n}-{engine}.fst"))
                    payload, stderr = invoke(engine, env, cpu)
                    validate_memory(payload, expected, engine, mode, len(encoded[engine]))
                    raw["memory_runs"].append(dict(round=iteration+1, payload=payload, stderr=stderr))
                    save()
    raw["finished_at"], raw["complete"] = benchmark.stamp(), True
    save()
    report(output, raw)
    print(f"Validated report: {output/'REPORT.md'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"workload benchmark: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or "", file=sys.stderr)
            print(error.stderr or "", file=sys.stderr)
        raise SystemExit(1)
