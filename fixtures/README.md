# Fixed upstream binary fixtures

The `.fst` files were emitted by the exact crates.io `fst 0.4.7` reference
builder. Their associated `.expected.json` files contain ordered
`[hex_key, decimal_u64_string]` records. They include no inferred Unicode
normalization or text-only ordering: all keys are arbitrary byte strings.

`manifest.json` records the reference version and upstream revision, file
sizes, SHA-256 hashes, record counts and each case's purpose. Random data uses
the specified SplitMix64 algorithm with seed `6d6f6f6e66737407`, rather than
Python's version-dependent random implementation. No timestamps enter the
generated artifacts.

The 19 cases cover:

- Empty sets/maps and the distinct empty key, including a maximum-u64 value.
- Shared prefixes and suffixes, final nodes with children and nonmonotonic outputs.
- NUL, invalid UTF-8, valid non-ASCII text and `0xff` keys.
- Exactly 256 root transitions, with both zero and nonzero output variants.
- Every unsigned output byte-width boundary, `2^63` and `2^64-1`.
- Long byte keys up to 4,098 bytes and long single-transition paths.
- Fixed-seed varied-length maps and sets.
- 6,000-key maps and sets with binaries larger than 64 KiB, exercising large
  node addresses and dense transition indexes.

```sh
python3 scripts/generate_fixtures.py          # Regenerate committed artifacts.
python3 scripts/generate_fixtures.py --check  # Require exact byte reproduction.
python3 scripts/verify_oracle.py              # Rust reads, queries and corrupt inputs.
python3 scripts/interop.py --target native   # Both binary interoperability directions.
```

The generator validates that each Rust-built FST enumerates exactly the input
records. The verifier separately checks SHA-256, lookup results, a bounded range,
a byte prefix, corrupted/truncated inputs and deterministic rebuilds. The
MoonBit interop harness then reads these bytes with the public MoonBit API,
builds FSTs from the input records in MoonBit, and has Rust decode those outputs.
Graph encodings may differ while representing the same records; byte-for-byte
identity between different builders is not required.
