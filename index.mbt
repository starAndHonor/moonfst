///|
/// Per-node cumulative path counts. Counts refer to accepted suffixes, so a
/// shared node is stored once even when many prefixes reach it.
priv struct IndexNode {
  node : @codec.Node
  cumulative : Array[UInt64]
  count : UInt64
  summary : ValueStatistics
}

///|
/// Optional in-memory index for rank/select. Construction costs O(V log V + E)
/// time and O(V + E) space; the compact FST itself does not require this cache.
pub struct FstIndex {
  priv fst : Fst
  priv nodes : Map[Int32, IndexNode]
}

///|
/// Build suffix counts without enumerating accepted strings or using recursion.
pub fn Fst::index(self : Fst) -> FstIndex raise FstError {
  let decoded : Map[Int32, @codec.Node] = Map([])
  let addresses = []
  let pending = [self.header.root]
  while pending.pop() is Some(address) {
    if decoded.contains(address) {
      continue
    }
    let node = read_node(self, address)
    decoded[address] = node
    addresses.push(address)
    for edge in node.transitions {
      pending.push(edge.addr)
    }
  }
  addresses.sort()
  let nodes : Map[Int32, IndexNode] = Map([])
  for address in addresses {
    let node = decoded[address]
    let cumulative = [if node.is_final { 1UL } else { 0UL }]
    let mut count = cumulative[0]
    let mut summary = if node.is_final {
      value_singleton(node.final_output)
    } else {
      empty_value_statistics()
    }
    for edge in node.transitions {
      count = checked_add(count, nodes[edge.addr].count)
      cumulative.push(count)
      summary = combine_value_statistics(
        summary,
        shift_value_statistics(nodes[edge.addr].summary, edge.output),
      )
    }
    nodes[address] = { node, cumulative, count, summary, }
  }
  { fst: self, nodes, }
}

///|
pub fn FstIndex::as_fst(self : FstIndex) -> Fst {
  self.fst
}

///|
pub fn FstIndex::len(self : FstIndex) -> UInt64 {
  self.nodes[self.fst.header.root].count
}

///|
pub fn FstIndex::cached_nodes(self : FstIndex) -> Int32 {
  self.nodes.length()
}

///|
/// Locate a transition or its insertion position by its byte label.
fn transition_position(node : @codec.Node, input : Byte) -> Int32 {
  let mut lower = 0
  let mut upper = node.transitions.length()
  while lower < upper {
    let middle = lower + (upper - lower) / 2
    if node.transitions[middle].input < input {
      lower = middle + 1
    } else {
      upper = middle
    }
  }
  lower
}

///|
/// Returns (number of keys strictly less than key, whether key exists).
/// Missing keys have a useful insertion rank as in a sorted array.
pub fn FstIndex::rank(self : FstIndex, key : Bytes) -> (UInt64, Bool) {
  let mut indexed = self.nodes[self.fst.header.root]
  let mut rank = 0UL
  for byte in key {
    let position = transition_position(indexed.node, byte)
    rank = rank + indexed.cumulative[position]
    if position >= indexed.node.transitions.length() ||
      indexed.node.transitions[position].input != byte {
      return (rank, false)
    }
    indexed = self.nodes[indexed.node.transitions[position].addr]
  }
  (rank, indexed.node.is_final)
}

///|
pub fn FstIndex::rank_str(self : FstIndex, key : String) -> (UInt64, Bool) {
  self.rank(string_bytes(key))
}

///|
/// Zero-based order statistic. Selecting len or larger returns None.
pub fn FstIndex::select(self : FstIndex, ordinal : UInt64) -> Entry? {
  if ordinal >= self.len() {
    return None
  }
  let mut indexed = self.nodes[self.fst.header.root]
  let mut remaining = ordinal
  let mut output = 0UL
  let key = []
  while true {
    if indexed.node.is_final && remaining == 0UL {
      return Some({
        key: Bytes::from_array(key),
        value: output + indexed.node.final_output,
      })
    }
    // Find the first cumulative endpoint strictly above remaining.
    let mut lower = 0
    let mut upper = indexed.node.transitions.length()
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if indexed.cumulative[middle + 1] <= remaining {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let edge = indexed.node.transitions[lower]
    remaining = remaining - indexed.cumulative[lower]
    output = output + edge.output
    key.push(edge.input)
    indexed = self.nodes[edge.addr]
  } nobreak {
    None
  }
}

///|
/// Number of keys starting with prefix. This takes O(prefix length * log
/// fanout), even when the subtree represents millions of keys.
pub fn FstIndex::prefix_count(self : FstIndex, prefix : Bytes) -> UInt64 {
  let mut indexed = self.nodes[self.fst.header.root]
  for byte in prefix {
    let position = transition_position(indexed.node, byte)
    if position >= indexed.node.transitions.length() ||
      indexed.node.transitions[position].input != byte {
      return 0UL
    }
    indexed = self.nodes[indexed.node.transitions[position].addr]
  }
  indexed.count
}

///|
pub fn FstIndex::prefix_count_str(self : FstIndex, prefix : String) -> UInt64 {
  self.prefix_count(string_bytes(prefix))
}

///|
/// Smallest key >= query.
pub fn FstIndex::lower_bound(self : FstIndex, query : Bytes) -> Entry? {
  self.select(self.rank(query).0)
}

///|
/// Smallest key > query.
pub fn FstIndex::upper_bound(self : FstIndex, query : Bytes) -> Entry? {
  let (rank, exists) = self.rank(query)
  self.select(rank + (if exists { 1UL } else { 0UL }))
}

///|
/// Greatest key <= query.
pub fn FstIndex::floor(self : FstIndex, query : Bytes) -> Entry? {
  let (rank, exists) = self.rank(query)
  if exists {
    self.select(rank)
  } else if rank > 0UL {
    self.select(rank - 1UL)
  } else {
    None
  }
}

///|
/// Greatest key < query.
pub fn FstIndex::predecessor(self : FstIndex, query : Bytes) -> Entry? {
  let (rank, _) = self.rank(query)
  if rank == 0UL {
    None
  } else {
    self.select(rank - 1UL)
  }
}

///|
/// Convert a byte range into a half-open ordinal interval. Reversed or
/// contradictory bounds produce an empty interval at the lower endpoint.
pub fn FstIndex::range_ranks(
  self : FstIndex,
  range : KeyRange,
) -> (UInt64, UInt64) {
  let lower = match range.lower {
    Unbounded => 0UL
    Included(key) => self.rank(key).0
    Excluded(key) => {
      let (rank, exists) = self.rank(key)
      rank + (if exists { 1UL } else { 0UL })
    }
  }
  let upper = match range.upper {
    Unbounded => self.len()
    Excluded(key) => self.rank(key).0
    Included(key) => {
      let (rank, exists) = self.rank(key)
      rank + (if exists { 1UL } else { 0UL })
    }
  }
  (lower, if upper < lower { lower } else { upper })
}

///|
pub fn FstIndex::range_count(self : FstIndex, range : KeyRange) -> UInt64 {
  let (lower, upper) = self.range_ranks(range)
  upper - lower
}

///|
/// Jump to a page without consuming its preceding keys. Offset is relative
/// to the selected range; a zero limit and an out-of-range offset are empty.
pub fn FstIndex::page(
  self : FstIndex,
  offset : UInt64,
  limit : Int32,
  range~ : KeyRange = KeyRange::all(),
) -> Array[Entry] raise FstError {
  if limit < 0 {
    raise InvalidArgument("page limit must be nonnegative")
  }
  let (lower, upper) = self.range_ranks(range)
  if limit == 0 || offset >= upper - lower {
    return []
  }
  match self.select(lower + offset) {
    None => []
    Some(first) =>
      self.fst
      .stream(range={ lower: Included(first.key), upper: range.upper, })
      .take(limit)
  }
}

///|
/// Produce a rank interval for every key under a prefix.
pub fn FstIndex::prefix_ranks(
  self : FstIndex,
  prefix : Bytes,
) -> (UInt64, UInt64) {
  let lower = self.rank(prefix).0
  (lower, lower + self.prefix_count(prefix))
}

///|
/// A decoded byte cursor, useful for custom tokenization and automata.
/// Advancing one cursor never mutates the immutable FST or another cursor.
pub struct Cursor {
  priv fst : Fst
  priv frames : Array[CursorFrame]
  priv key : Array[Byte]
}

///|
priv struct CursorFrame {
  node : @codec.Node
  output : UInt64
}

///|
pub fn Fst::cursor(self : Fst) -> Cursor raise FstError {
  {
    fst: self,
    frames: [{ node: read_node(self, self.header.root), output: 0UL, }],
    key: [],
  }
}

///|
pub fn Cursor::depth(self : Cursor) -> Int32 {
  self.key.length()
}

///|
/// Advance if this byte has an outgoing transition. A failed advance leaves
/// the cursor exactly where it was, which permits alternative token attempts.
pub fn Cursor::advance(self : Cursor, byte : Byte) -> Bool raise FstError {
  let frame = self.frames[self.frames.length() - 1]
  match find_transition(frame.node, byte) {
    None => false
    Some(edge) => {
      let child = read_node(self.fst, edge.addr)
      self.frames.push({ node: child, output: frame.output + edge.output, })
      self.key.push(byte)
      true
    }
  }
}

///|
/// Advance the entire suffix atomically; on failure the starting position is
/// restored. Bytes before the failed byte are not left consumed.
pub fn Cursor::advance_bytes(
  self : Cursor,
  suffix : Bytes,
) -> Bool raise FstError {
  let original = self.depth()
  for byte in suffix {
    if !self.advance(byte) {
      self.truncate(original)
      return false
    }
  }
  true
}

///|
/// Rewind one byte. The root cannot be rewound.
pub fn Cursor::back(self : Cursor) -> Bool {
  if self.key.is_empty() {
    return false
  }
  ignore(self.frames.pop())
  ignore(self.key.pop())
  true
}

///|
pub fn Cursor::reset(self : Cursor) -> Unit {
  self.frames.truncate(1)
  self.key.clear()
}

///|
/// Keep a prefix of the current path; requesting a deeper or negative depth
/// is an error rather than silently changing the requested position.
pub fn Cursor::truncate(self : Cursor, depth : Int32) -> Unit raise FstError {
  if depth < 0 || depth > self.depth() {
    raise InvalidArgument("cursor truncation depth is outside the current path")
  }
  self.frames.truncate(depth + 1)
  self.key.truncate(depth)
}

///|
/// Seek from the root. Failure restores the previous position.
pub fn Cursor::seek(self : Cursor, key : Bytes) -> Bool raise FstError {
  let checkpoint = self.frames.copy()
  let previous = self.key.copy()
  self.reset()
  if self.advance_bytes(key) {
    true
  } else {
    self.frames.clear()
    for frame in checkpoint {
      self.frames.push(frame)
    }
    self.key.clear()
    for byte in previous {
      self.key.push(byte)
    }
    false
  }
}

///|
/// Duplicate cursor position and path; future movement is independent.
pub fn Cursor::fork(self : Cursor) -> Cursor {
  { fst: self.fst, frames: self.frames.copy(), key: self.key.copy(), }
}

///|
pub fn Cursor::key(self : Cursor) -> Bytes {
  Bytes::from_array(self.key)
}

///|
/// Output accumulated on transitions; it excludes a final-state output.
pub fn Cursor::output_prefix(self : Cursor) -> UInt64 {
  self.frames[self.frames.length() - 1].output
}

///|
/// The full map value if the current prefix is an accepted key.
pub fn Cursor::value(self : Cursor) -> UInt64? {
  let frame = self.frames[self.frames.length() - 1]
  if frame.node.is_final {
    Some(frame.output + frame.node.final_output)
  } else {
    None
  }
}

///|
/// Return an owned snapshot so callers cannot modify the cursor's nodes.
pub fn Cursor::transitions(self : Cursor) -> Array[@codec.Transition] {
  self.frames[self.frames.length() - 1].node.transitions.copy()
}

///|
pub fn Cursor::address(self : Cursor) -> Int32 {
  self.frames[self.frames.length() - 1].node.address
}

///|
/// Iterate the accepted extensions of the current cursor prefix.
pub fn Cursor::completions(self : Cursor) -> Stream raise FstError {
  self.fst.prefix(self.key())
}
