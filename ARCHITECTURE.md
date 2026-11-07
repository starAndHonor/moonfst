# Architecture

## Scope and reference

This is a MoonBit port of the core byte-set/map model, sorted construction,
compact graph format, streaming operations and automaton interfaces of
[`BurntSushi/fst` 0.4.7](https://github.com/BurntSushi/fst/tree/fbd5992376f176c35af2644d74efad58f5656e5c).
The reference revision is `fbd5992376f176c35af2644d74efad58f5656e5c`.
The public API follows MoonBit ownership, errors, byte arrays and iterators;
it does not reproduce Rust's type signatures or platform adapters.

The library runs without foreign-language bindings. Filesystem access, memory
mapping, parallel construction and the upstream CLI are outside the current
runtime API. The Rust oracle is acceptance tooling only.

## Package boundaries

| Area | Responsibility |
|---|---|
| `codec/` | Header/footer, packed integers, node encoding and decoding, common input labels, CRC32C, reachable-graph validation |
| `builder.mbt` | Sorted incremental construction, output factoring, bounded equivalent-node registry |
| `fst.mbt`, `packed.mbt`, `set.mbt`, `map.mbt`, `types.mbt` | Validated immutable bytes, lookup, string adapters, collection construction and inspection |
| `stream.mbt`, `traversal.mbt` | Iterative lexicographic traversal, byte ranges and automaton pruning |
| `reverse.mbt` | Descending traversal wrappers and reverse index pagination |
| `source.mbt` | External ascending sources, order validation, lazy filter/value-map/window adapters and folds |
| `operations.mbt` | Heap-based multiway operations with source-preserving values and explicit reductions |
| `index.mbt` | Optional rank/select and suffix-summary cache, reversible cursors; MoonBit extensions |
| `search_index.mbt` | Bounded FST/automaton product counts, matching rank/select and pagination |
| `value_statistics.mbt` | Subtree value summaries, interval aggregation and best-first top-value queries |
| `automaton/` | Composable byte matchers, explicit DFA construction, Unicode Levenshtein lowering |
| `oracle/`, `fixtures/`, `integration/`, `scripts/` | Reproducible reference and differential checks; outside the production library |

## Graph and output model

An FST is a deterministic acyclic graph whose edge labels are bytes. Each node
contains at most one edge for each byte; edges are stored in ascending unsigned
byte order. A final node accepts the path reaching it, including an empty path.
Final nodes may also have children.

Each edge and final node carries an unsigned 64-bit output. A map value is the
sum of outputs on the accepted path plus the final output. A set uses zero
outputs. Nodes are equivalent only when their final flags, final outputs,
ordered edge labels, edge outputs and destination addresses all agree.

The zero address represents the implicit final, zero-output, childless node.
Stored edges point backward to already compiled nodes. This ordering permits
bottom-up verification and suffix-count calculation without recursive graph
walks or expansion of all accepted keys.

## Sorted construction

`Builder` retains the unfinished path of the preceding key. An insertion finds
the common prefix, pushes differing map-output factors downward, compiles the
old suffix deepest first, and appends the new suffix. The unsigned minimum is
the common output factor; no signed conversion is used.

A signature registry reuses equivalent compiled nodes. Its configurable total
capacity is split into two-way buckets, with the more recently used node first;
an odd capacity gives the final bucket one slot. The default 20,000 slots match
the upstream 10,000-by-2 registry. A fingerprint selects a bucket, but a hit still
requires equality of every final flag, output, ordered label and target.
Eviction affects compression, not the represented language or values. A bounded
registry does not claim global minimality.

Lookup compares the unfinished node directly, without allocating a signature.
Only a miss copies independent packed UInt64 words into the selected slot; an
evicted slot can reuse its word buffer when the length matches. Active slots
never share a mutable word buffer. Occupied slots, rather than bucket count,
are reported as `registry_entries`. Completed unfinished-node buffers are
recycled in a pool bounded by the maximum key length; that pool shares no
mutable transition storage with registry signatures.

Unfinished `BuildNode` objects are mutable references allocated only when the
maximum path depth grows. Each live object belongs to the stack or spare pool;
in-place updates avoid copying a value record for each common-prefix byte.
Transitions and registry slots remain value types. The pool stores unfinished
workspace, not an additional full graph or per-key lookup cache.

Construction is incremental with respect to input keys, but serialized output
remains in an in-memory buffer. It is not a constant-memory disk writer.
Convenience constructors sort a copy of unsorted input; the sorted builder does
not need to materialize the full key list. Sets coalesce consecutive duplicate
keys; maps reject duplicates unless a convenience constructor resolves them
with an explicit policy first.

## Codec and validation

The writer emits format version 3: little-endian metadata and packed outputs,
specialized one-transition and multi-transition nodes, backward address deltas,
and masked CRC32C. Decoding recognizes the supported older headers as well.
The fixed interop oracle targets version 3 from Rust fst 0.4.7.

`Fst::from_bytes` performs validation before returning an immutable handle:

1. Check metadata, version-dependent footer boundaries and root location.
2. Verify the version 3 checksum.
3. Decode every reachable node iteratively, validating packed widths, address
   bounds, backward targets, edge ordering and transition indexes.
4. Sort reachable addresses and reject overlapping node byte ranges.
5. Calculate accepted suffix counts and maximum accepted path outputs bottom
   up; reject arithmetic overflow or a footer count inconsistent with the graph.

This is validation of the complete **reachable graph**, not an assertion that
every byte outside reachable node records has a unique canonical encoding.
Decoding never trusts a checksum as a substitute for graph checks.

The validated object retains its complete immutable `Bytes`, with no per-key
answer cache or extra full-graph lookup index. Exact lookup reads only the
selected transition from the compressed bytes. Nodes with an encoded byte
index use it directly; small unindexed nodes compare eight labels per word,
and large legacy v1 nodes use binary search. Unary labels stay in scalar
locals rather than an allocated tuple.

Private packed readers use unaligned little-endian 64-bit reads and masks.
All their callers operate on a fully validated FST. Packed widths are 0..8,
field offsets lie in the node region, and even v1/v2 files retain at least 16
footer bytes after that region, so an eight-byte read of a short field or label
tail remains within the original Bytes. Width zero returns before reading;
label matches outside the logical count are rejected. This invariant must be
preserved by every future Fst constructor. Public codec decoding still checks
untrusted input independently and public inspection returns owned arrays.
Supported addresses fit positive MoonBit `Int32` values.

## Streams and operations

A stream keeps an explicit stack of compressed-node cursors, accumulated
outputs, the next edge index, and the automaton state for that path. Cursors
and stack frames are immutable value types stored directly in the stack array;
visiting a node does not allocate a decoded transition array or a heap frame.
Nonfinal unary chains advance a local cursor, persisting a frame only for a
branch or a yielded key. A private boolean advance operation lets bulk
consumers avoid allocating an Option for every result; count and skip also
avoid copying keys that they never return. Public next still returns an owned
key snapshot. Only returned keys become owned byte copies. Shared graph nodes
can therefore be visited under different prefixes and different matcher states.
In forward mode, final keys are yielded before child edges, producing
byte-lexicographic order. Reverse mode visits edges from largest to smallest
and yields the final key after its descendants. Automata still consume bytes
from the start of each key; only complete-key emission order changes.
`ReverseStream` exposes this mode through a separate public type and does not
implement the ascending `EntrySource` contract. Neither mode collects a full
forward result to reverse it.

Range bounds prune impossible prefixes. Each frame carries its byte-prefix
ordering against each bound, updating it with one byte per edge instead of
rescanning or copying the full path. Complete-key acceptance resolves equal
prefixes by length and inclusion/exclusion. Automaton `can_match` prunes before
a child cursor is opened. EOF is applied once when a final key is considered; its
substituted state does not replace the path state used to traverse longer keys.
User-supplied automata retain all transition and EOF calls. The ordinary
`stream` and `reverse` constructors, which internally select the universal
matcher, skip its per-edge virtual calls. General searches do not infer this
shortcut from an arbitrary matcher or its `will_always_match` promise.

Multiway operations retain one head per input stream in a binary heap. Equal
keys are grouped with values ordered by source number. Difference subtracts
every source after the first; multiway symmetric difference retains odd source
cardinality. Reductions choose a value policy explicitly and check summed
outputs for overflow. Supplying a stream transfers its iteration ownership by
convention; concurrently consuming that same stream is unsupported.

`EntrySource` abstracts ascending, unique-key input independently of FST storage.
`ArraySource` copies and validates sorted records; its set constructor also
coalesces consecutive duplicates. Applications may implement the trait for
external readers. `CheckedSource` validates each observed key against its
predecessor and permanently closes after an order violation or reader error.
`merge_sources` wraps every source in this validator before putting its head
into the heap. Initialization and iteration errors close every owned input;
they never leave an operation resumable with a missing heap head.

`merge(Fst[])` creates independent concrete streams from already validated
graphs, so it advances them directly without repeating external-source order
checks or boxing each entry through a trait adapter. `MergeStream::new` and
`merge_sources` retain the checked path for caller-provided streams. Both paths
produce independently owned keys and value groups that remain valid after the
merge advances or closes; the source-number ordering is identical.

For exactly two fresh FST streams, the merge compares their current mutable
key buffers directly. It copies one key only when returning a result, before
advancing the matching input streams. Equal keys produce source 0 then source
1 in a new value array. This avoids a heap and discarded duplicate head copies
without exposing borrowed buffers. Other source counts retain the heap. Small
heap groups construct their first one or two values without an intermediate
array expansion. Materializing reductions close all inputs if a value policy,
callback or builder fails.

Filtering and value mapping preserve the input key order. Windowing skips a
bounded prefix and returns at most its limit; constructing an adapter performs
no reads, including for a zero limit. The checked/filter/map/window adapters
close their input on EOF or error, and repeated closure does not call the input
again. A callback failure in a filter or value mapper also closes its chain.
Consumers that stop early should close explicitly. General folds and builder
extension consume the supplied source without claiming automatic resource
ownership; callers retain responsibility for their callback or insertion errors.

## Optional indexes and cursors

`FstIndex` decodes unique nodes and stores cumulative counts of accepted suffix
paths and value summaries. A shared suffix is counted once and reused for every
incoming edge. Graph construction takes `O(V log V + E)` time and `O(V + E)` auxiliary
space. Rank and prefix counts follow a key path with binary search on each
node's edges. Select follows cumulative counts to the requested ordinal.
Forward and reverse pagination locate their first key by ordinal and
then open a bounded lazy traversal. The base FST does not require this cache.

Value summaries store count, minimum, maximum and optional sum for the suffix
language. Prepending an edge output shifts both extrema and adds
`output * count` to the sum. All individual path values have already passed
validation; only an aggregate sum can exceed `UInt64`, represented by `None`
instead of wrapping. An empty summary has zero count, no extrema and sum zero.
Key-range, prefix and ordinal-range queries combine cached summaries for whole
covered subtrees and descend only through partial coverage. `top` maintains a
heap of candidate subtrees ordered by their attainable maximum and expands
the most promising candidate first. Terminal records compete in the same
heap, giving descending values and byte-lexical tie breaks. A query can still
need a large frontier, depending on the graph, value distribution and range.

`SearchIndex` builds an iterative product traversal keyed by
`(node_address, automaton_state)`. Counts are accumulated in ascending node
address order, so all descendants are available before a parent. The product
can be much larger than the FST: `max_states` caps visited product states and
fails with `ResourceLimit` before returning a partial index. Matching count,
rank/select, prefix/range counts and pagination use these counts without
materializing the complete matching key list.

When `will_always_match` holds, construction substitutes the base FST suffix
count and skips the descendant product graph. Rank/select/prefix traversal
carries an inherited universal flag, because a correct conservative matcher
need not repeat the same promise in each child state. Descendant counts and
terminal acceptance then use that inherited promise rather than looking for
cache entries that were intentionally never built. State identities and
pruning promises must remain stable for the index's entire lifetime. Ordinary
search streams retain their per-edge checks; this promise-based shortcut is
specific to the optional index.

`Cursor` stores decoded nodes for a current path. It can advance, rewind, seek,
reset, and fork an independent position. A batch advance rolls back on a
missing edge; failed seek restores the previous path. Accumulated edge output
is distinct from the final map value returned at an accepted key.

## Automata

The public trait uses stable integer state IDs. `-1` is the rejecting sink.
`can_match` must never reject a state with an accepting continuation;
`will_always_match` may only promise that every continuation accepts. These
methods may be conservative rather than complete. EOF substitution is optional
and applied only once at a full-key boundary.

Basic matchers use direct position/count state encodings. Boolean combinations
encode the product of component states arithmetically, including component
sinks. Construction checks state limits before multiplication can overflow.
Complement operates over all byte strings; complementing a Unicode matcher can
therefore accept invalid UTF-8 strings that the inner matcher rejects.
`starts_with` observes acceptance at every prefix boundary, including the
inner matcher's EOF behavior, and then enters an absorbing state.

An explicit DFA builder checks state references and deterministic edge ranges.
`build` snapshots its tables. Reverse reachability computes exact live states;
reverse propagation from EOF rejection or missing edges identifies states that
cannot promise universal suffix acceptance, including cyclic graphs.

### Unicode Levenshtein

The distance recurrence operates on Unicode scalar values. It caps each DP cell
at `distance + 1`; rows whose minimum exceeds the bound are rejecting sinks.
Distinct scalars appearing in the query form symbol classes, plus one class for
all other scalars. Equal capped rows are interned during construction to form a
finite scalar DFA.

A second finite machine validates UTF-8 and classifies completed scalars. It
tracks only query-trie prefix identity, remaining continuation count and the
next-byte range. Generic unmatched prefixes share states. Special lead-byte
ranges exclude overlong sequences, surrogates and values beyond U+10FFFF.
An unfinished scalar cannot accept at EOF.

The runtime state is the arithmetic product of a scalar-DFA state and a UTF-8
classifier state. Byte transitions allocate no new states and do not grow a
search-dependent cache. Constructor state and DP-cell budgets fail explicitly
with `AutomatonError`; they never return a partly built matcher that silently
loses results. No normalization, case folding, grapheme-distance or primitive
transposition edit is performed.

## Verification strategy

MoonBit tests cover byte/unsigned boundaries, validation, construction and query
properties. Automaton tests compare against independent scalar dynamic
programming and strict UTF-8 decoding, check malformed encodings, and validate
EOF/Boolean composition and pruning promises. Source tests inject order
violations, reader failures and callback failures, checking permanent closure
and exactly-once propagation to the external reader. Separate public-API tests
run FST searches against direct matcher execution across shared paths and ranges.

The pinned Rust oracle creates fixed version 3 binaries and reads MoonBit-built
binaries back. Complete ordered records, exact u64 values, lookups, ranges and
prefixes are compared. Equivalent graph encodings need not have identical
bytes; deterministic regeneration by the same Rust builder is checked
separately. Seeded random cases supplement the fixed fixtures.

Rust sources, Python tools, test sources, fixtures and generated fixture
embeddings are excluded from production MoonBit source counts.
