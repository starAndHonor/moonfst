# Rust reference oracle

This executable is test tooling, not a dependency of the MoonBit library.
It uses the unmodified crates.io package `fst = "=0.4.7"`; `Cargo.lock` also
fixes the support dependencies. The corresponding upstream source revision is
`fbd5992376f176c35af2644d74efad58f5656e5c` at
[BurntSushi/fst](https://github.com/BurntSushi/fst/tree/fbd5992376f176c35af2644d74efad58f5656e5c).

```sh
cargo test --locked --manifest-path oracle/Cargo.toml
cargo build --locked --release --manifest-path oracle/Cargo.toml
```

The process reads one JSON object per stdin line and writes one JSON object per
stdout line. Every key and binary file is hexadecimal text. Every `u64` value,
including `0`, is a decimal **string**, preventing JavaScript/JSON-number
precision loss. Inputs are never silently sorted or deduplicated.

```json
{"op":"version"}
{"op":"build","kind":"set","keys":["","00","61","ff"]}
{"op":"build","kind":"map","entries":[["","18446744073709551615"],["00","0"],["61","4294967296"]]}
```

A successful build returns `ok`, `bytes_hex`, `entries`, `len` and `fst_type`.
For a set, returned entry values are all `"0"`. `len` is an ordinary JSON
number because it represents the finite input record count, not an FST output.
Both upstream high-level builders use FST type 0; set and map have the same
binary representation when all outputs are zero.

To read a binary file, use its complete hex encoding:

```json
{"op":"read","bytes_hex":"...","lookups":["","00","ff"],"range":{"ge":"00","lt":"ff"},"prefix":"61"}
```

`read` always returns all ordered `entries`, `len` and `fst_type`. Optional
fields add independent query results:

- `lookups`: `[hex_key, decimal_string_or_null]` pairs, preserving request order.
- `range`: ordered entries selected by `ge`, `gt`, `le` and/or `lt` byte bounds.
- `prefix`: ordered entries whose raw-byte key begins with the given prefix.

Reads verify the upstream CRC32C checksum before traversing the graph. Setting
`"verify_checksum": false` is available for diagnosing a failed checksum; it
is not used by the interoperability acceptance checks. Upstream documents
that arbitrary corrupt graph data can panic. The wrapper catches ordinary
Rust panics and responds with `{"ok":false,"error":"..."}`; it does not turn
the upstream decoder into a hardened production parser.

Use `scripts/generate_fixtures.py --check`, `scripts/verify_oracle.py` and
`scripts/interop.py` from the repository root for the reproducible tests.
These files and this Rust source do not contribute to production MoonBit LOC.
