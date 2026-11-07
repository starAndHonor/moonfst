# Real dictionary provenance

`jieba.json` pins the upstream Jieba repository revision, download URL, exact
byte length and SHA256 of `jieba/dict.txt`. The original MIT notice is preserved
in `JIEBA-LICENSE.txt` (Sun Junyi, 2013). The corpus is development data, not a
runtime dependency or a bundled Mooncakes artifact.

`python3 scripts/prepare_workload.py --n 100000` downloads only that pinned file
to ignored `benchmarks/data/`, checks its digest before parsing and writes a
deterministic `MFSTW001` workload. Existing cached bytes with a different digest
are rejected, not silently reused. The original has 349,046 records and 349,045
unique UTF-8 words: the identical duplicate `B超 3 n` is coalesced; conflicting
duplicates would be rejected. Real frequency values are retained, POS tags are
discarded, and keys are neither normalized nor case-folded.

The unique dictionary is first sorted by UTF-8 bytes, then permuted using
Fisher–Yates with a specified wrapping 32-bit LCG and seed `0x00c0ffee`. Select
the first `3*N/2` entries: A is the first N, B begins at N/2. Sort each map before
construction. This avoids using a contiguous alphabetic slice and gives two
N-record maps with N/2 overlapping keys carrying the same value.

The wire layout is `MFSTW001`, little-endian u32 N, u32 total, then total records
of u32 byte length, u64 frequency and key bytes. Query shuffling is separate,
default seed `0x12345678`; sorted and shuffled modes use the same maps.
For each Fisher–Yates position i descending from length-1 to 1, update
`state = state*1664525+1013904223 mod 2^32`, choose `j=state mod (i+1)`, and swap.
This fixed workload generator is deterministic, not a claim of perfectly
uniform statistical sampling (modulo reduction has a small bias).

Missing-key requests append the invalid UTF-8 byte FF to a real word. The
mixed workload alternates a hit and a miss in the selected query order.
It models a controlled 50% hit workload, not observed production traffic.
All input hashes, expected output hashes and query order hashes are computed
independently by Python and checked against both language runners.
