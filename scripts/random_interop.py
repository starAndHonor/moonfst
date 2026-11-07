#!/usr/bin/env python3
"""Fixed-seed structured/random differential testing against Rust fst 0.4.7.

This supplements the committed fixtures without adding generated records to
the repository. Counterexamples report their reproducible case name and seed.
"""
from __future__ import annotations

import argparse
from typing import Any

from generate_fixtures import MASK64, SplitMix64, entries
from interop import embedded_cases, run_moon, verify_report
from oracle_common import Oracle, build_request

DEFAULT_SEED = 0x4653544449464631
SIZES = [0, 1, 2, 4, 7, 16, 31, 32, 63, 64, 127, 128, 255, 256, 257, 384]


def random_records(rng: SplitMix64, number: int) -> list[list[str]]:
    count = SIZES[number % len(SIZES)]
    shape = (number // len(SIZES) + number) % 6
    prefix = rng.bytes(256) if shape == 5 else b""
    keys = set()
    serial = 0
    while len(keys) < count:
        if shape == 0:
            key = rng.bytes(rng.word() % 49)
        elif shape == 1:
            key = f"namespace/{rng.word() % 8:02d}/".encode() + rng.bytes(rng.word() % 12)
        elif shape == 2:
            key = serial.to_bytes(2, "little")
        elif shape == 3:
            key = rng.bytes(1 + rng.word() % 12) + b"/identical-suffix"
        elif shape == 4:
            key = bytes([serial % 2]) + b"x" * (serial // 2)
        else:
            key = prefix + rng.bytes(1 + rng.word() % 12)
        keys.add(key)
        serial += 1
    ordered = sorted(keys)
    values = []
    value_shape = (number // 2) % 5
    for index, key in enumerate(ordered):
        if number % 2 == 0 or value_shape == 0:
            value = 0
        elif value_shape == 1:
            value = MASK64
        elif value_shape == 2:
            value = index % 7
        elif value_shape == 3:
            value = MASK64 - index * 65537
        else:
            value = rng.word()
        values.append((key, value))
    return entries(values)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=lambda text: int(text, 0), default=DEFAULT_SEED)
    parser.add_argument("--cases", type=int, default=64)
    parser.add_argument("--target", action="append", choices=["native", "js", "wasm-gc", "wasm"])
    args = parser.parse_args()
    if not 1 <= args.cases <= 512:
        parser.error("--cases must be between 1 and 512")
    if not 0 <= args.seed <= MASK64:
        parser.error("--seed must fit in an unsigned 64-bit integer")
    rng = SplitMix64(args.seed)
    cases: list[tuple[dict[str, Any], dict[str, Any], bytes]] = []
    with Oracle() as oracle:
        for number in range(args.cases):
            kind = "set" if number % 2 == 0 else "map"
            name = f"random_{args.seed:016x}_{number:03d}_{kind}"
            records = random_records(rng, number)
            built = oracle.request(build_request(kind, records))
            assert built["entries"] == records, name
            cases.append(({"name": name, "kind": kind}, {"entries": records}, bytes.fromhex(built["bytes_hex"])))
        with embedded_cases(cases):
            for target in args.target or ["native"]:
                reports = run_moon(target)
                by_name = {report["name"]: report for report in reports}
                assert len(reports) == len(by_name) == len(cases), f"{target}: missing or repeated cases"
                for case, expected, _ in cases:
                    verify_report(case, expected, by_name[case["name"]], oracle)
                print(f"{target}: {len(cases)} structured/random cases, "
                      f"{sum(len(expected['entries']) for _, expected, _ in cases)} records, "
                      f"seed 0x{args.seed:016x}; both binary directions and query results agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
