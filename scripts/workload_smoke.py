#!/usr/bin/env python3
"""Offline correctness check of both workload runners and all memory phases."""
import argparse
import struct

import benchmark
import prepare_workload as workload
import workload_benchmark as runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    out = benchmark.ROOT/"oracle/target/validation/workload-smoke"
    out.mkdir(parents=True, exist_ok=True)
    runner.build(out, args.skip_build)
    entries = [("月".encode(), 2), (b"moon", 7), (b"bit", 11),
               ("月兔".encode(), 13), ("中文".encode(), 17), ("🙂".encode(), 19)]
    raw = workload.MAGIC+struct.pack("<II", 4, 6)+b"".join(struct.pack("<IQ", len(k), v)+k for k, v in entries)
    path = out/"tiny.bin"
    path.write_bytes(raw)
    results = []
    sizes = {}
    for engine in runner.ENGINES:
        fst = out/f"{engine}.fst"
        for order in ("sorted", "shuffled"):
            expected = workload.reference(raw, order)
            env = runner.clean_environment(MOONFST_WORKLOAD_MODE="timing", MOONFST_WORKLOAD_INPUT=str(path),
                       MOONFST_WORKLOAD_SAMPLES="2", MOONFST_WORKLOAD_WARMUPS="1",
                       MOONFST_WORKLOAD_ORDER=order, MOONFST_WORKLOAD_QUERY_SEED=str(workload.QUERY_SEED),
                       MOONFST_WORKLOAD_WRITE_FST=str(fst))
            payload, _ = runner.invoke(engine, env, None)
            runner.validate_timing(payload, expected, engine, 2, 1)
            sizes[engine] = payload["fst_bytes"]
            results.append(payload)
        for mode in runner.MEMORY_MODES:
            env = runner.clean_environment(MOONFST_WORKLOAD_MODE=mode, MOONFST_WORKLOAD_INPUT=str(path),
                       MOONFST_WORKLOAD_N="4", MOONFST_WORKLOAD_FST_PATH=str(fst))
            payload, _ = runner.invoke(engine, env, None)
            runner.validate_memory(payload, expected, engine, mode, sizes[engine])
            results.append(payload)
    if (out/"moonbit.fst").read_bytes() != (out/"rust.fst").read_bytes():
        raise ValueError("tiny encoded files differ")
    benchmark.write_json(out/"results.json", results)
    print("Offline workload smoke: two query orders, all memory phases, both engines and exact encoding passed.")


if __name__ == "__main__":
    main()
