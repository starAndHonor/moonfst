#!/usr/bin/env python3
"""Read stored fixtures with Rust; independently check records and query semantics."""
from __future__ import annotations

import hashlib

from oracle_common import Oracle, build_request, load_cases


def main() -> None:
    manifest, cases = load_cases()
    query_count = 0
    with Oracle() as oracle:
        assert oracle.request({"op": "version"}) == manifest["reference"]
        for case, expected, data in cases:
            name = case["name"]
            assert hashlib.sha256(data).hexdigest() == case["sha256"], name
            assert len(data) == case["bytes"], name
            records = expected["entries"]
            assert records == sorted(records, key=lambda pair: bytes.fromhex(pair[0])), name
            probes = ["", "00", "ff", "00010203", "ffffffffffffffff"]
            if records:
                probes += [records[0][0], records[len(records) // 2][0], records[-1][0]]
            dictionary = dict(records)
            prefix = bytes.fromhex(records[len(records) // 2][0])[:2] if records else b"\0"
            request = {
                "op": "read", "bytes_hex": data.hex(), "lookups": probes,
                "prefix": prefix.hex(), "range": {"ge": "00", "lt": "ff"},
            }
            response = oracle.request(request)
            assert response["entries"] == records, name
            assert response["len"] == case["length"] == len(records), name
            assert response["lookups"] == [[probe, dictionary.get(probe)] for probe in probes], name
            assert response["range"] == [pair for pair in records if b"\0" <= bytes.fromhex(pair[0]) < b"\xff"], name
            assert response["prefix"] == [pair for pair in records if bytes.fromhex(pair[0]).startswith(prefix)], name
            query_count += 3
            rebuilt = oracle.request(build_request(case["kind"], records))
            assert rebuilt["bytes_hex"] == data.hex(), name
            # Header-independent body corruption must fail the upstream checksum.
            corrupted = bytearray(data)
            corrupted[len(corrupted) // 2] ^= 0x40
            assert oracle.request({"op": "read", "bytes_hex": corrupted.hex()}, expect_ok=False)["ok"] is False, name
            assert oracle.request({"op": "read", "bytes_hex": data[:-1].hex()}, expect_ok=False)["ok"] is False, name
        assert oracle.request({"op": "read", "bytes_hex": "00"}, expect_ok=False)["ok"] is False
        assert oracle.request({"op": "version"})["ok"] is True
    print(f"Rust oracle verified {len(cases)} fixtures, {query_count} lookup/range/prefix checks, "
          f"{len(cases) * 2 + 1} invalid byte streams, and exact rebuilds")


if __name__ == "__main__":
    main()
