#!/usr/bin/env python3
"""Generate exact fst 0.4.7 binary fixtures, or verify committed copies with --check."""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

from oracle_common import ROOT, Oracle, build_request, json_bytes

SEED = 0x6D6F6F6E66737407
MASK64 = (1 << 64) - 1


class SplitMix64:
    """Specified arithmetic, independent of Python's random module implementation."""

    def __init__(self, seed: int):
        self.state = seed

    def word(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def bytes(self, length: int) -> bytes:
        output = bytearray()
        while len(output) < length:
            output.extend(self.word().to_bytes(8, "little"))
        return bytes(output[:length])


def entries(pairs: list[tuple[bytes, int]]) -> list[list[str]]:
    # Strict unsigned-byte lexicographic order is part of the fixture contract.
    pairs = sorted(pairs)
    assert len({key for key, _ in pairs}) == len(pairs)
    return [[key.hex(), str(value)] for key, value in pairs]


def cases() -> list[tuple[str, str, list[list[str]], str]]:
    rng = SplitMix64(SEED)
    output = []

    def add_set(name: str, keys: list[bytes], why: str) -> None:
        output.append((name, "set", entries([(key, 0) for key in keys]), why))

    def add_map(name: str, pairs: list[tuple[bytes, int]], why: str) -> None:
        output.append((name, "map", entries(pairs), why))

    add_set("set_empty", [], "No accepted key; distinct from a set containing the empty key.")
    add_set("set_empty_key", [b""], "Empty key and the implicit empty-final state.")
    add_map("map_empty", [], "Empty map and a zero-key checksum-bearing file.")
    add_map("map_empty_key_max", [(b"", MASK64)], "Empty-key final output uses the full u64 domain.")

    text = [b"a", b"ab", b"aba", b"abandon", b"b", b"ba", b"banana", b"band", b"zoo"]
    add_set("set_ascii", text, "Shared prefix, final nodes with children, and unsorted-length keys.")
    add_map("map_ascii", [(key, value) for key, value in zip(text, [7, 3, 17, 0, 22, 5, 999, 0, 101])],
            "Nonmonotonic map outputs exercise output factoring.")

    raw_keys = [b"", b"\0", b"\0\0", b"\0\xff", b"\x01", b"a\0b", b"a\xff", b"\x7f", b"\x80",
                b"\xc0\xaf", "月亮".encode(), b"\xed\xa0\x80", b"\xff", b"\xff\0", b"\xff\xff"]
    add_set("set_raw_bytes", raw_keys, "NUL, invalid UTF-8, non-ASCII UTF-8 and 0xff are ordinary key bytes.")
    add_map("map_raw_bytes", [(key, rng.word()) for key in raw_keys], "Arbitrary-byte keys and random full-width outputs.")

    all_bytes = [bytes([value]) for value in range(256)]
    add_set("set_all_256", all_bytes, "A state has exactly 256 outgoing transitions, including 0 and 255.")
    add_map("map_all_256", [(key, value * 65537) for value, key in enumerate(all_bytes)],
            "Full 256-way branch with distinct outputs and transition-index encoding.")

    widths = [0, 1, 127, 128, 255, 256, 65535, 65536, (1 << 24) - 1, 1 << 24,
              (1 << 32) - 1, 1 << 32, (1 << 48) - 1, 1 << 48, (1 << 56) - 1,
              1 << 56, (1 << 63) - 1, 1 << 63, MASK64]
    add_map("map_u64_boundaries", [(bytes([index]), value) for index, value in enumerate(widths)]
            + [(b"z", MASK64), (b"za", 0), (b"zb", MASK64 - 1)],
            "Every output byte-width boundary, high-bit values, maximum u64 and descending outputs.")

    prefix_keys = [f"namespace/{group:03d}/item/{item:03d}/common-suffix".encode()
                   for group in range(24) for item in range(48)]
    add_set("set_shared_affixes", prefix_keys, "Repeated prefixes and suffixes permit suffix-state sharing.")
    add_map("map_shared_affixes", [(key, index % 48) for index, key in enumerate(prefix_keys)],
            "Repeated weighted suffixes and output normalization across many prefixes.")

    long = bytes(range(256)) * 16
    add_set("set_long_keys", [b"", b"a", b"a" + long, b"a" + long + b"\0", b"a" + long + b"\xff", b"b"],
            "4098-byte keys, long single-transition chains and final-prefix keys.")
    add_map("map_long_keys", [(b"", 99), (b"a" + long, 0), (b"a" + long + b"\0", MASK64),
                              (b"a" + long + b"\xff", 7), (b"b", 3)],
            "Long chains with differing outputs, zero output and a full-width leaf output.")

    def random_keys(count: int, min_length: int, extra_length: int) -> list[bytes]:
        found = set()
        while len(found) < count:
            found.add(rng.bytes(min_length + rng.word() % extra_length))
        return sorted(found)

    add_set("set_seeded_random", random_keys(512, 1, 31), "Fixed-seed byte keys with varied lengths and branching.")
    add_map("map_seeded_random", [(key, rng.word()) for key in random_keys(512, 1, 31)],
            "Fixed-seed random map spans the complete unsigned output range.")
    add_set("set_large_index", random_keys(6000, 16, 16),
            "Large node addresses and indexed high-fanout states; binary exceeds 64 KiB.")
    add_map("map_large_index", [(key, rng.word()) for key in random_keys(6000, 16, 16)],
            "Large weighted graph, node offsets beyond 64 KiB and nontrivial transition indexes.")
    return output


def check_or_write(path: Path, content: bytes, check: bool) -> bool:
    if check:
        if not path.exists() or path.read_bytes() != content:
            print(f"fixture drift: {path.relative_to(ROOT)}", file=sys.stderr)
            return False
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Regenerate in memory and require exact committed bytes.")
    options = parser.parse_args()
    results = []
    success = True
    with Oracle() as oracle:
        reference = oracle.request({"op": "version"})
        for name, kind, expected_entries, purpose in cases():
            built = oracle.request(build_request(kind, expected_entries))
            if built["entries"] != expected_entries:
                raise AssertionError(f"upstream build differs from input: {name}")
            data = bytes.fromhex(built["bytes_hex"])
            if name.endswith("large_index"):
                assert len(data) > 65536, (name, len(data))
            expected = {"kind": kind, "entries": expected_entries}
            success &= check_or_write(ROOT / "fixtures" / f"{name}.fst", data, options.check)
            success &= check_or_write(ROOT / "fixtures" / f"{name}.expected.json", json_bytes(expected), options.check)
            results.append({
                "name": name,
                "kind": kind,
                "data_file": f"{name}.fst",
                "expected_file": f"{name}.expected.json",
                "length": len(expected_entries),
                "bytes": len(data),
                "max_key_bytes": max((len(bytes.fromhex(key)) for key, _ in expected_entries), default=0),
                "sha256": hashlib.sha256(data).hexdigest(),
                "purpose": purpose,
            })
    manifest = {
        "format": "moonfst-reference-fixtures-v1",
        "reference": reference,
        "generator": "scripts/generate_fixtures.py",
        "prng": "SplitMix64, modulo-2^64 arithmetic, little-endian bytes",
        "seed_hex": f"{SEED:016x}",
        "cases": results,
    }
    success &= check_or_write(ROOT / "fixtures" / "manifest.json", json_bytes(manifest), options.check)
    print(f"{'Verified' if options.check else 'Generated'} {len(results)} Rust fixtures, "
          f"{sum(case['length'] for case in results)} keys, {sum(case['bytes'] for case in results)} binary bytes")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
