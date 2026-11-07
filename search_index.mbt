///|
/// An optional index over the product of an FST and a byte automaton.
/// It counts accepted suffixes without materializing matching keys. Its memory
/// bound is explicit because a product graph can exceed the size of the FST.
pub struct SearchIndex {
  priv index : FstIndex
  priv matcher : &@automaton.Automaton
  priv counts : Map[(Int32, Int32), UInt64]
}

///|
/// Build an automaton/FST product using iterative traversal. State identities
/// and pruning promises must stay stable for the lifetime of the returned index.
pub fn FstIndex::search_index(
  self : FstIndex,
  matcher : &@automaton.Automaton,
  max_states~ : Int32 = 1000000,
) -> SearchIndex raise FstError {
  if max_states <= 0 {
    raise InvalidArgument("product state limit must be positive")
  }
  let seen : Map[(Int32, Int32), Bool] = Map([])
  let order : Array[(Int32, Int32)] = []
  let counts : Map[(Int32, Int32), UInt64] = Map([])
  let pending = [(self.fst.header.root, matcher.start())]
  while pending.pop() is Some(pair) {
    if seen.contains(pair) || !matcher.can_match(pair.1) {
      continue
    }
    if seen.length() >= max_states {
      raise ResourceLimit("FST/automaton product exceeds max_states")
    }
    seen[pair] = true
    let indexed = self.nodes[pair.0]
    if matcher.will_always_match(pair.1) {
      counts[pair] = indexed.count
      continue
    }
    order.push(pair)
    for edge in indexed.node.transitions {
      let state = matcher.accept(pair.1, edge.input)
      if matcher.can_match(state) {
        pending.push((edge.addr, state))
      }
    }
  }
  // Every stored target has a smaller address, including the implicit final
  // state at zero. Different automaton states at the same address are unrelated.
  order.sort_by(fn(a, b) { a.0.compare(b.0) })
  for pair in order {
    let node = self.nodes[pair.0].node
    let terminal = matcher.accept_eof(pair.1).unwrap_or(pair.1)
    let mut count = if node.is_final && matcher.is_match(terminal) {
      1UL
    } else {
      0UL
    }
    for edge in node.transitions {
      let state = matcher.accept(pair.1, edge.input)
      count = checked_add(count, counts.get((edge.addr, state)).unwrap_or(0UL))
    }
    counts[pair] = count
  }
  { index: self, matcher, counts, }
}

///|
fn SearchIndex::suffix_count(
  self : SearchIndex,
  address : Int32,
  state : Int32,
  universal~ : Bool = false,
) -> UInt64 {
  if universal || self.matcher.will_always_match(state) {
    self.index.nodes[address].count
  } else if !self.matcher.can_match(state) {
    0UL
  } else {
    self.counts.get((address, state)).unwrap_or(0UL)
  }
}

///|
fn SearchIndex::accepts_final(
  self : SearchIndex,
  node : @codec.Node,
  state : Int32,
  universal~ : Bool = false,
) -> Bool {
  node.is_final &&
  (
    universal ||
    self.matcher.is_match(self.matcher.accept_eof(state).unwrap_or(state))
  )
}

///|
/// Count of matching keys, with no output array or key expansion.
pub fn SearchIndex::len(self : SearchIndex) -> UInt64 {
  self.suffix_count(self.index.fst.header.root, self.matcher.start())
}

///|
pub fn SearchIndex::is_empty(self : SearchIndex) -> Bool {
  self.len() == 0UL
}

///|
/// Actual stored product count entries. Always-matching suffixes are shortcut
/// entries and do not require copies of their entire descendant subgraph.
pub fn SearchIndex::cached_states(self : SearchIndex) -> Int32 {
  self.counts.length()
}

///|
/// Select the nth matching key in byte-lexicographic order.
pub fn SearchIndex::select(self : SearchIndex, ordinal : UInt64) -> Entry? {
  if ordinal >= self.len() {
    return None
  }
  let mut node = self.index.nodes[self.index.fst.header.root].node
  let mut state = self.matcher.start()
  let mut universal = self.matcher.will_always_match(state)
  let mut remaining = ordinal
  let mut output = 0UL
  let key = []
  while true {
    if self.accepts_final(node, state, universal~) {
      if remaining == 0UL {
        return Some({
          key: Bytes::from_array(key),
          value: output + node.final_output,
        })
      }
      remaining = remaining - 1UL
    }
    let mut target : (@codec.Transition, Int32)? = None
    for edge in node.transitions {
      let next = self.matcher.accept(state, edge.input)
      let count = self.suffix_count(edge.addr, next, universal~)
      if remaining < count {
        target = Some((edge, next))
        break
      }
      remaining = remaining - count
    }
    match target {
      None => return None
      Some((edge, next)) => {
        key.push(edge.input)
        output = output + edge.output
        state = next
        universal = universal || self.matcher.will_always_match(next)
        node = self.index.nodes[edge.addr].node
      }
    }
  } nobreak {
    None
  }
}

///|
/// Number of matching keys strictly less than query, and whether query itself
/// is both stored in the FST and accepted by the automaton.
pub fn SearchIndex::rank(self : SearchIndex, query : Bytes) -> (UInt64, Bool) {
  let mut node = self.index.nodes[self.index.fst.header.root].node
  let mut state = self.matcher.start()
  let mut universal = self.matcher.will_always_match(state)
  let mut count = 0UL
  for input in query {
    if self.accepts_final(node, state, universal~) {
      count = count + 1UL
    }
    let mut target : (@codec.Transition, Int32)? = None
    for edge in node.transitions {
      if edge.input > input {
        break
      }
      let next = self.matcher.accept(state, edge.input)
      if edge.input == input {
        target = Some((edge, next))
        break
      }
      count = count + self.suffix_count(edge.addr, next, universal~)
    }
    match target {
      None => return (count, false)
      Some((edge, next)) => {
        if !universal && !self.matcher.can_match(next) {
          return (count, false)
        }
        node = self.index.nodes[edge.addr].node
        state = next
        universal = universal || self.matcher.will_always_match(next)
      }
    }
  }
  (count, self.accepts_final(node, state, universal~))
}

///|
pub fn SearchIndex::prefix_count(self : SearchIndex, prefix : Bytes) -> UInt64 {
  let mut address = self.index.fst.header.root
  let mut state = self.matcher.start()
  let mut universal = self.matcher.will_always_match(state)
  for input in prefix {
    match find_transition(self.index.nodes[address].node, input) {
      None => return 0UL
      Some(edge) => {
        address = edge.addr
        state = self.matcher.accept(state, input)
        universal = universal || self.matcher.will_always_match(state)
        if !universal && !self.matcher.can_match(state) {
          return 0UL
        }
      }
    }
  }
  self.suffix_count(address, state, universal~)
}

///|
pub fn SearchIndex::range_ranks(
  self : SearchIndex,
  range : KeyRange,
) -> (UInt64, UInt64) {
  let lower = match range.lower {
    Unbounded => 0UL
    Included(key) => self.rank(key).0
    Excluded(key) => {
      let (rank, found) = self.rank(key)
      rank + (if found { 1UL } else { 0UL })
    }
  }
  let upper = match range.upper {
    Unbounded => self.len()
    Excluded(key) => self.rank(key).0
    Included(key) => {
      let (rank, found) = self.rank(key)
      rank + (if found { 1UL } else { 0UL })
    }
  }
  (lower, if upper < lower { lower } else { upper })
}

///|
pub fn SearchIndex::range_count(self : SearchIndex, range : KeyRange) -> UInt64 {
  let (lower, upper) = self.range_ranks(range)
  upper - lower
}

///|
pub fn SearchIndex::page(
  self : SearchIndex,
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
      self.index.fst
      .search(self.matcher, range={
        lower: Included(first.key),
        upper: range.upper,
      })
      .take(limit)
  }
}

///|
/// Return a lazy traversal using the same predicate, without consuming this
/// reusable index. A page or traversal never changes cached state counts.
pub fn SearchIndex::stream(
  self : SearchIndex,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.index.fst.search(self.matcher, range~)
}
