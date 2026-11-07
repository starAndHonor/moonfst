# Stream.collect diagnosis on frozen v4 C

This is an instrumented diagnosis, not a performance benchmark. It uses the
existing native release generated C captured by SHA-256 in `metadata.json`,
compiled as an independent `-O2 -pg -g` object. Production source and the formal
runner were not changed. The root agent subsequently changed Stream.next; these
addresses and findings describe the captured v4 implementation only.

Each shape used N=100,000, CPU 2 and 30 complete full-range stream collections.
Sampling was enabled inside collect only when invoked by the measured
stream_owned callback. Construction, prefix collections, result hashing and
final result destruction were excluded. All formal runner correctness checks
passed, and an independent scope counter confirmed exactly 30 collections.

## Actual call counts

`raw-address-mapping.json` decodes the GNU gmon arc records and matches each
callee PC against the full sized ELF symbol table, including GCC `.part` and
`.isra` clones. Counts across all 30 collections are:

| Callee | shared | random |
| --- | ---: | ---: |
| Stream.next | 3,000,030 | 3,000,030 |
| traversal_node | 18,822,000 | 40,533,120 |
| Bytes.from_array | 3,000,000 | 3,000,000 |
| Array[Frame].push | 3,804,480 | 3,901,950 |
| Array[Entry].push | 3,000,000 | 3,000,000 |
| Array[Entry].realloc | 450 | 450 |
| Byte-buffer resize/realloc | 90 / 90 | 60 / 60 |

The parser thus runs 627,400 times per shared collection and 1,351,104 times
per random collection. Frame pushes are much less frequent than parser calls:
v4 already replaces non-final unary frames in their current stack slot, but
still materializes and writes the replacement frame for every unary edge.

Plain gprof incorrectly names some clone counts and samples as
CheckedSource.close, debug formatting, a builder callback or Fst.stream.inner.
There are no such high-frequency calls in the scoped operation. In particular,
the reported 40.5 million close calls are traversal_node.part.0 calls, and the
3,000,030 stream-constructor calls are Stream.next.part.0 calls.

## Samples and machine code

At 100 Hz, the captured histogram contains only 41 shared ticks and 80 random
ticks. Exact symbol-range mapping assigns 40 shared ticks and 73 random ticks
to Stream.next.part.0; another four random ticks fall in traversal_node.part.0.
The remaining few ticks cannot establish a separate allocator bottleneck.
Prebuilt runtime and allocator objects are not mcount-instrumented, so their
allocation call counts are unavailable even though their static text can be
sampled.

The 72-byte child-frame replacement block at `0x3ee17..0x3ee55` contains 13 of
41 shared ticks and 29 of 80 random ticks. Disassembly shows scalar/SIMD loads
from temporary records followed by four 16-byte `movups` stores plus an 8-byte
store to the frame array. The high-frequency work is present despite Frame
and TraversalNode being value types: they avoid heap boxes, but whole-record
copying still happens on each traversed unary edge.

The `traversal.mbt:21 @3ed23` source-line group is easy to misread. Its 13 random
ticks have actual histogram-bin centers near `0x3ed46`, at register restoration
after the nonzero-address parser call. The line group covers the address test,
parser call, return restoration and the separate zero-address default-record
branch. It is not evidence that copying the implicit terminal record dominates.

Histogram bin centers are approximate sampled PCs; interrupts and line-table
grouping prevent assigning a precise cost to an individual instruction.
`-pg` also changes call overhead. These fractions must not be interpreted as
an elapsed-time decomposition of the uninstrumented library.

## Targeted next change and review

The evidence supports keeping a unary cursor local until a yield, branch or
exhaustion rather than saving/reloading its complete frame at every byte.
It does not support another broad set of speculative representation changes.
The root agent implemented the local-cursor inner loop after this capture.
A read-only review found no persistence, reverse-final ordering, EOF or prune
regression: unary nodes being collapsed have no pending sibling or final key;
yield saves the updated cursor; a branch saves its advanced parent before
pushing the child; exhaustion restores the saved ancestor key length; reverse
final keys remain deferred until all children are exhausted.

The GNU record layout is documented by the
[GNU gprof file-format manual](https://sourceware.org/binutils/docs/gprof/File-Format.html)
and the system `sys/gmon_out.h`. The parser in `scripts/profile_stream.py`
currently accepts GNU gmon version 1 on little-endian ELF64 only.
