// SPDX-License-Identifier: MIT
// The bounded edit-distance recurrence follows fst 0.4.7. UTF-8 lowering is
// implemented here with finite scalar-equivalence classes, rather than a
// mutable per-search DP cache.

///|
priv struct Utf8TrieNode {
  edges : Map[Byte, Int32]
  mut symbol : Int32
}

///|
#derive(Eq, Hash)
priv struct DecodeState {
  node : Int32
  remaining : Int32
  lower : Int32
  upper : Int32
}

///|
priv enum DecodeStep {
  Invalid
  Pending(DecodeState)
  Scalar(Int32)
}

///|
priv struct ScalarClassifier {
  // -1: invalid; <= -2: complete scalar, symbol = -entry-2;
  // >= 0: a pending decoder state. State zero is the boundary between scalars.
  steps : Array[Array[Int32]]
}

///|
priv struct LevenMachine {
  rows : Array[Array[Int32]]
  transitions : Array[Array[Int32]]
  classifier : ScalarClassifier
  distance : Int32
  query_length : Int32
  alphabet_size : Int32
  work : Int32
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct LevenshteinStats {
  scalar_states : Int32
  utf8_states : Int32
  alphabet_classes : Int32
  query_scalars : Int32
  dp_cells : Int32
}

///|
pub fn Matcher::levenshtein_stats(self : Matcher) -> LevenshteinStats? {
  match self.kind {
    Levenshtein(machine) =>
      Some({
        scalar_states: machine.rows.length(),
        utf8_states: machine.classifier.steps.length(),
        alphabet_classes: machine.alphabet_size,
        query_scalars: machine.query_length,
        dp_cells: machine.work,
      })
    _ => None
  }
}

///|
fn trie_next(nodes : Array[Utf8TrieNode], node : Int32, byte : Byte) -> Int32 {
  if node < 0 {
    -1
  } else {
    nodes[node].edges.get(byte).unwrap_or(-1)
  }
}

///|
fn trie_symbol(nodes : Array[Utf8TrieNode], node : Int32) -> Int32 {
  if node < 0 {
    0
  } else {
    nodes[node].symbol
  }
}

///|
fn decode_step(
  trie : Array[Utf8TrieNode],
  state : DecodeState,
  byte : Byte,
) -> DecodeStep {
  let value = byte.to_int()
  if state.remaining > 0 {
    if value < state.lower || value > state.upper {
      return Invalid
    }
    let node = trie_next(trie, state.node, byte)
    if state.remaining == 1 {
      return Scalar(trie_symbol(trie, node))
    }
    return Pending({
      node,
      remaining: state.remaining - 1,
      lower: 0x80,
      upper: 0xbf,
    })
  }
  let node = trie_next(trie, 0, byte)
  if value <= 0x7f {
    Scalar(trie_symbol(trie, node))
  } else if value >= 0xc2 && value <= 0xdf {
    Pending({ node, remaining: 1, lower: 0x80, upper: 0xbf, })
  } else if value == 0xe0 {
    // Exclude overlong three-byte encodings.
    Pending({ node, remaining: 2, lower: 0xa0, upper: 0xbf, })
  } else if value == 0xed {
    // UTF-16 surrogate code points are not Unicode scalar values.
    Pending({ node, remaining: 2, lower: 0x80, upper: 0x9f, })
  } else if value >= 0xe1 && value <= 0xef {
    Pending({ node, remaining: 2, lower: 0x80, upper: 0xbf, })
  } else if value == 0xf0 {
    Pending({ node, remaining: 3, lower: 0x90, upper: 0xbf, })
  } else if value >= 0xf1 && value <= 0xf3 {
    Pending({ node, remaining: 3, lower: 0x80, upper: 0xbf, })
  } else if value == 0xf4 {
    // U+10FFFF is the highest legal scalar value.
    Pending({ node, remaining: 3, lower: 0x80, upper: 0x8f, })
  } else {
    Invalid
  }
}

///|
fn build_classifier(
  trie : Array[Utf8TrieNode],
  limit : Int32,
) -> ScalarClassifier raise AutomatonError {
  let initial = DecodeState::{ node: 0, remaining: 0, lower: 0, upper: 0, }
  let states = [initial]
  let ids : Map[DecodeState, Int32] = Map([])
  ids[initial] = 0
  let table : Array[Array[Int32]] = []
  let mut cursor = 0
  while cursor < states.length() {
    let state = states[cursor]
    let edges = Array::make(256, -1)
    for value in 0..<256 {
      match decode_step(trie, state, value.to_byte()) {
        Invalid => ()
        Scalar(symbol) => edges[value] = -symbol - 2
        Pending(next) => {
          let id = match ids.get(next) {
            Some(id) => id
            None => {
              if states.length() >= limit {
                raise StateLimit(limit~)
              }
              let id = states.length()
              states.push(next)
              ids[next] = id
              id
            }
          }
          edges[value] = id
        }
      }
    }
    table.push(edges)
    cursor = cursor + 1
  }
  { steps: table, }
}

///|
fn next_distance_row(
  previous : Array[Int32],
  query : Array[Int32],
  symbol : Int32,
  cap : Int32,
) -> Array[Int32] {
  let row = Array::make(previous.length(), cap)
  row[0] = (previous[0] + 1).min(cap)
  for position in 0..<query.length() {
    let substitution = previous[position] +
      (if query[position] == symbol { 0 } else { 1 })
    let insertion = previous[position + 1] + 1
    let deletion = row[position] + 1
    row[position + 1] = substitution.min(insertion).min(deletion).min(cap)
  }
  row
}

///|
fn row_can_match(row : Array[Int32], distance : Int32) -> Bool {
  for value in row {
    if value <= distance {
      return true
    }
  }
  false
}

///|
/// Matches valid UTF-8 keys within a Unicode-scalar Levenshtein distance.
/// Insertions, deletions and substitutions cost one; transposition is not a
/// primitive edit. No normalization or case folding is performed.
///
/// Construction eagerly builds a finite scalar DFA and a strict UTF-8
/// classifier. Equal query scalars share a symbol and every other scalar is
/// equivalent, so runtime accepts bytes without allocating or caching states.
/// `max_states` bounds the full product of these two machines. `max_work`
/// bounds the number of DP cells evaluated during construction. Exceeding
/// either limit returns a typed error before a partial matcher can escape.
pub fn levenshtein(
  query : String,
  distance : Int32,
  max_states~ : Int32 = 10000,
  max_work~ : Int32 = 10000000,
) -> Matcher raise AutomatonError {
  if distance < 0 || distance >= 1000000 {
    raise InvalidArgument("edit distance must be between 0 and 999999")
  }
  if max_states <= 0 || max_states > default_state_limit || max_work <= 0 {
    raise InvalidArgument("invalid Levenshtein state or work limit")
  }
  let chars = query.to_array()
  if chars.length() >= max_work {
    raise WorkLimit(limit=max_work)
  }
  if chars.length() >= max_states {
    raise StateLimit(limit=max_states)
  }
  let symbols : Map[Char, Int32] = Map([])
  let query_symbols : Array[Int32] = []
  let trie : Array[Utf8TrieNode] = [{ edges: Map([]), symbol: 0, }]
  for char in chars {
    let point = char.to_int()
    if (point >= 0xd800 && point <= 0xdfff) || point > 0x10ffff {
      raise InvalidArgument("query contains a non-scalar Unicode code point")
    }
    let symbol = match symbols.get(char) {
      Some(symbol) => symbol
      None => {
        let symbol = symbols.length() + 1
        symbols[char] = symbol
        let bytes = @utf8.encode(char.to_string())
        let mut node = 0
        for byte in bytes {
          match trie[node].edges.get(byte) {
            Some(next) => node = next
            None => {
              let next = trie.length()
              if next >= max_states {
                raise StateLimit(limit=max_states)
              }
              trie.push({ edges: Map([]), symbol: 0, })
              trie[node].edges[byte] = next
              node = next
            }
          }
        }
        trie[node].symbol = symbol
        symbol
      }
    }
    query_symbols.push(symbol)
  }
  let classifier = build_classifier(trie, max_states)
  let width = classifier.steps.length()
  let row_limit = max_states / width
  if row_limit == 0 {
    raise StateLimit(limit=max_states)
  }
  let cap = distance + 1
  let initial = Array::makei(chars.length() + 1, fn(i) { i.min(cap) })
  let rows : Array[Array[Int32]] = [initial]
  let ids : Map[Array[Int32], Int32] = Map([])
  ids[initial] = 0
  let transitions : Array[Array[Int32]] = []
  let alphabet_size = symbols.length() + 1
  let mut work = 0
  let mut cursor = 0
  while cursor < rows.length() {
    let edges = Array::make(alphabet_size, -1)
    for symbol in 0..<alphabet_size {
      let cost = chars.length() + 1
      if cost > max_work - work {
        raise WorkLimit(limit=max_work)
      }
      work = work + cost
      let next = next_distance_row(rows[cursor], query_symbols, symbol, cap)
      if row_can_match(next, distance) {
        let id = match ids.get(next) {
          Some(id) => id
          None => {
            if rows.length() >= row_limit {
              raise StateLimit(limit=max_states)
            }
            let id = rows.length()
            rows.push(next)
            ids[next] = id
            id
          }
        }
        edges[symbol] = id
      }
    }
    transitions.push(edges)
    cursor = cursor + 1
  }
  let state_count = rows.length() * width
  {
    kind: Levenshtein({
      rows,
      transitions,
      classifier,
      distance,
      query_length: chars.length(),
      alphabet_size,
      work,
    }),
    states: state_count,
  }
}

///|
fn LevenMachine::step(self : LevenMachine, state : Int32, byte : Byte) -> Int32 {
  let width = self.classifier.steps.length()
  let row = state / width
  let decoder = state % width
  let edge = self.classifier.steps[decoder][byte.to_int()]
  if edge == -1 {
    -1
  } else if edge >= 0 {
    row * width + edge
  } else {
    let symbol = -edge - 2
    let next_row = self.transitions[row][symbol]
    if next_row < 0 {
      -1
    } else {
      next_row * width
    }
  }
}

///|
fn LevenMachine::matches(self : LevenMachine, state : Int32) -> Bool {
  let width = self.classifier.steps.length()
  state % width == 0 &&
  self.rows[state / width][self.query_length] <= self.distance
}
