#!/usr/bin/env python3
"""Fetch a pinned real dictionary and prepare a language-neutral workload."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import urllib.request

try:
    from . import benchmark
except ImportError:
    import benchmark

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "benchmarks/corpora/jieba.json"
MAGIC = b"MFSTW001"
DATA_SEED = 0xC0FFEE
QUERY_SEED = 0x12345678
METRICS = ("build", "lookup_hit", "lookup_miss", "lookup_mixed", "stream_owned", "union_owned")


def shuffled_indices(length, seed):
    """Specified u32 LCG Fisher-Yates, independent of Python random versions."""
    result = list(range(length))
    state = seed
    for i in range(length - 1, 0, -1):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        j = state % (i + 1)
        result[i], result[j] = result[j], result[i]
    return result


def parse_dictionary(raw):
    words = {}
    duplicates = 0
    for line_number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        fields = line.split()
        if len(fields) != 3:
            raise ValueError(f"dictionary line {line_number}: expected word frequency POS")
        word, frequency, _ = fields
        key, value = word.encode("utf-8"), int(frequency)
        if not key or not 0 <= value <= benchmark.MASK:
            raise ValueError(f"dictionary line {line_number}: invalid key/frequency")
        if key in words:
            duplicates += 1
            if words[key] != value:
                raise ValueError(f"dictionary line {line_number}: conflicting duplicate")
        words[key] = value
    return sorted(words.items()), duplicates


def fetch_dictionary(cache):
    manifest = json.loads(MANIFEST.read_text())
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(manifest["url"], timeout=60) as response:
            raw = response.read()
        if len(raw) != manifest["bytes"] or hashlib.sha256(raw).hexdigest() != manifest["sha256"]:
            raise ValueError("download does not match the pinned corpus SHA256")
        cache.write_bytes(raw)
    raw = cache.read_bytes()
    if len(raw) != manifest["bytes"] or hashlib.sha256(raw).hexdigest() != manifest["sha256"]:
        raise ValueError(f"cached corpus differs from manifest: {cache}")
    entries, duplicates = parse_dictionary(raw)
    return entries, dict(manifest, unique_entries=len(entries), duplicate_lines=duplicates)


def encode_workload(entries, n):
    if n < 2 or n % 2 or 3 * n // 2 > len(entries):
        raise ValueError("n must be positive/even with at least 3*n/2 unique corpus entries")
    total = 3 * n // 2
    selected = [entries[i] for i in shuffled_indices(len(entries), DATA_SEED)[:total]]
    result = bytearray(MAGIC + struct.pack("<II", n, total))
    for key, value in selected:
        result.extend(struct.pack("<IQ", len(key), value))
        result.extend(key)
    return bytes(result)


def decode_workload(raw):
    if len(raw) < 16 or raw[:8] != MAGIC:
        raise ValueError("invalid workload header")
    n, total = struct.unpack_from("<II", raw, 8)
    if n < 2 or n % 2 or total != 3 * n // 2:
        raise ValueError("invalid workload sizes")
    entries, offset = [], 16
    for _ in range(total):
        if offset + 12 > len(raw):
            raise ValueError("truncated workload record")
        length, value = struct.unpack_from("<IQ", raw, offset)
        offset += 12
        if offset + length > len(raw):
            raise ValueError("truncated workload key")
        key = bytes(raw[offset:offset + length])
        # FF near misses must be absent; dictionary keys are valid UTF-8.
        key.decode("utf-8")
        entries.append((key, value))
        offset += length
    if offset != len(raw) or len({key for key, _ in entries}) != total:
        raise ValueError("trailing bytes or duplicate workload keys")
    return n, entries


def reference(raw, order, query_seed=QUERY_SEED):
    if order not in ("sorted", "shuffled") or not 0 <= query_seed <= 0xFFFFFFFF:
        raise ValueError("invalid query configuration")
    n, selected = decode_workload(raw)
    a, b, union = sorted(selected[:n]), sorted(selected[n // 2:]), sorted(selected)
    indices = list(range(n)) if order == "sorted" else shuffled_indices(n, query_seed)
    queries = [a[i] for i in indices]
    dataset_hash = benchmark.records_hash(a)
    union_hash = benchmark.records_hash(union)
    return {
        "n": n, "total": len(selected), "order": order, "query_seed": query_seed,
        "order_hash": benchmark.records_hash(queries),
        "dataset_hash": dataset_hash, "union_hash": union_hash,
        "b_hash": benchmark.records_hash(b),
        "workload_sha256": hashlib.sha256(raw).hexdigest(),
        "input_key_bytes": sum(len(key) for key, _ in a),
        "expected": {
            "lookup_hit": [str(sum(v for _, v in queries) & benchmark.MASK), n],
            "lookup_miss": ["0", 0],
            "lookup_mixed": [str(sum(v for _, v in queries[::2]) & benchmark.MASK), n // 2],
            "stream_owned": [dataset_hash, n],
            "union_owned": [union_hash, len(selected)],
        },
    }


def prepare(n, cache, destination):
    entries, metadata = fetch_dictionary(cache)
    raw = encode_workload(entries, n)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and destination.read_bytes() != raw:
        raise ValueError(f"refusing to overwrite a different workload: {destination}")
    destination.write_bytes(raw)
    provenance = dict(corpus=metadata, data_seed=DATA_SEED,
                      format="MFSTW001", workload_sha256=hashlib.sha256(raw).hexdigest(),
                      n=n, total=3*n//2, bytes=len(raw))
    Path(str(destination)+".json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2)+"\n")
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n", type=int, default=100000)
    parser.add_argument("--cache", type=Path, default=ROOT / "benchmarks/data/jieba-dict.txt")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    destination = args.output or ROOT / f"benchmarks/data/jieba-{args.n}.bin"
    print(json.dumps(prepare(args.n, args.cache, destination), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
