// SPDX-License-Identifier: MIT

///|
priv struct DfaMachine {
  initial : Int32
  transitions : Array[Array[Int32]]
  accepting : Array[Bool]
  eof : Array[Int32?]
  live : Array[Bool]
  universal : Array[Bool]
}

///|
/// Builds a deterministic byte automaton. Missing edges go to the rejecting
/// sink. Build takes a snapshot, so later builder edits cannot alter searches.
pub struct DfaBuilder {
  priv transitions : Array[Array[Int32]]
  priv accepting : Array[Bool]
  priv eof : Array[Int32?]
  priv mut initial : Int32
  priv limit : Int32
}

///|
pub fn DfaBuilder::new(
  max_states~ : Int32 = 4096,
) -> DfaBuilder raise AutomatonError {
  if max_states <= 0 || max_states > default_state_limit {
    raise InvalidArgument("DFA limit must be between 1 and 1000000")
  }
  { transitions: [], accepting: [], eof: [], initial: 0, limit: max_states, }
}

///|
pub fn DfaBuilder::state_count(self : DfaBuilder) -> Int32 {
  self.transitions.length()
}

///|
pub fn DfaBuilder::add_state(
  self : DfaBuilder,
  accepting : Bool,
) -> Int32 raise AutomatonError {
  let state = self.transitions.length()
  if state >= self.limit {
    raise StateLimit(limit=self.limit)
  }
  self.transitions.push(Array::make(256, -1))
  self.accepting.push(accepting)
  self.eof.push(None)
  state
}

///|
fn DfaBuilder::check(
  self : DfaBuilder,
  state : Int32,
) -> Unit raise AutomatonError {
  if state < 0 || state >= self.transitions.length() {
    raise InvalidState(state)
  }
}

///|
pub fn DfaBuilder::set_start(
  self : DfaBuilder,
  state : Int32,
) -> Unit raise AutomatonError {
  self.check(state)
  self.initial = state
}

///|
pub fn DfaBuilder::set_match(
  self : DfaBuilder,
  state : Int32,
  accepting : Bool,
) -> Unit raise AutomatonError {
  self.check(state)
  self.accepting[state] = accepting
}

///|
/// Adds a deterministic edge. Existing edges are rejected instead of silently
/// replacing a previous rule. A failed range insertion makes no edits.
pub fn DfaBuilder::add_transition(
  self : DfaBuilder,
  from : Int32,
  byte : Byte,
  to : Int32,
) -> Unit raise AutomatonError {
  self.add_range(from, byte, byte, to)
}

///|
pub fn DfaBuilder::add_range(
  self : DfaBuilder,
  from : Int32,
  lower : Byte,
  upper : Byte,
  to : Int32,
) -> Unit raise AutomatonError {
  self.check(from)
  self.check(to)
  let lo = lower.to_int()
  let hi = upper.to_int()
  if lo > hi {
    raise InvalidArgument("transition range lower bound exceeds upper bound")
  }
  for byte = lo; byte <= hi; byte = byte + 1 {
    if self.transitions[from][byte] != -1 {
      raise DuplicateTransition(state=from, byte~)
    }
  }
  for byte = lo; byte <= hi; byte = byte + 1 {
    self.transitions[from][byte] = to
  }
}

///|
pub fn DfaBuilder::remove_transition(
  self : DfaBuilder,
  from : Int32,
  byte : Byte,
) -> Unit raise AutomatonError {
  self.check(from)
  self.transitions[from][byte.to_int()] = -1
}

///|
/// EOF is a single substitution, not an epsilon closure. None keeps the
/// current state. This supports constructs whose acceptance depends on EOF.
pub fn DfaBuilder::set_eof(
  self : DfaBuilder,
  from : Int32,
  to : Int32?,
) -> Unit raise AutomatonError {
  self.check(from)
  if to is Some(target) {
    self.check(target)
  }
  self.eof[from] = to
}

///|
/// Computes exact liveness and universal-suffix properties using reverse
/// reachability. These are fixed points, including for cyclic automata.
fn classify_dfa(
  transitions : Array[Array[Int32]],
  accepting : Array[Bool],
  eof : Array[Int32?],
) -> (Array[Bool], Array[Bool]) {
  let n = transitions.length()
  let reverse : Array[Array[Int32]] = Array::makei(n, _ => [])
  let live = Array::make(n, false)
  let bad = Array::make(n, false)
  let live_queue : Array[Int32] = []
  let bad_queue : Array[Int32] = []
  for state in 0..<n {
    let end_state = eof[state].unwrap_or(state)
    if accepting[end_state] {
      live[state] = true
      live_queue.push(state)
    } else {
      bad[state] = true
      bad_queue.push(state)
    }
    for target in transitions[state] {
      if target >= 0 {
        reverse[target].push(state)
      } else if !bad[state] {
        bad[state] = true
        bad_queue.push(state)
      }
    }
  }
  let mut cursor = 0
  while cursor < live_queue.length() {
    let state = live_queue[cursor]
    cursor = cursor + 1
    for previous in reverse[state] {
      if !live[previous] {
        live[previous] = true
        live_queue.push(previous)
      }
    }
  }
  cursor = 0
  while cursor < bad_queue.length() {
    let state = bad_queue[cursor]
    cursor = cursor + 1
    for previous in reverse[state] {
      if !bad[previous] {
        bad[previous] = true
        bad_queue.push(previous)
      }
    }
  }
  (live, bad.map(fn(value) { !value }))
}

///|
pub fn DfaBuilder::build(self : DfaBuilder) -> Matcher raise AutomatonError {
  self.check(self.initial)
  let transitions = self.transitions.map(fn(row) { row.copy() })
  let accepting = self.accepting.copy()
  let eof = self.eof.copy()
  let (live, universal) = classify_dfa(transitions, accepting, eof)
  let machine = DfaMachine::{
    initial: self.initial,
    transitions,
    accepting,
    eof,
    live,
    universal,
  }
  { kind: Explicit(machine), states: transitions.length(), }
}

///|
/// Imports a dense DFA table. Each row must have exactly 256 destinations;
/// -1 denotes an absent edge. Input arrays are copied and fully validated.
pub fn dfa_from_table(
  initial : Int32,
  transitions : Array[Array[Int32]],
  accepting : Array[Bool],
  eof? : Array[Int32?],
  max_states~ : Int32 = 4096,
) -> Matcher raise AutomatonError {
  let count = transitions.length()
  if max_states <= 0 || max_states > default_state_limit {
    raise InvalidArgument("DFA limit must be between 1 and 1000000")
  }
  if count > max_states {
    raise StateLimit(limit=max_states)
  }
  if count == 0 || initial < 0 || initial >= count {
    raise InvalidState(initial)
  }
  if accepting.length() != count {
    raise InvalidArgument(
      "DFA acceptance table length differs from state count",
    )
  }
  let ends = match eof {
    None => Array::make(count, None)
    Some(values) => {
      if values.length() != count {
        raise InvalidArgument("DFA EOF table length differs from state count")
      }
      values.copy()
    }
  }
  for state in 0..<count {
    let row = transitions[state]
    if row.length() != 256 {
      raise InvalidArgument(
        "DFA transition row must contain exactly 256 entries",
      )
    }
    for target in row {
      if target < -1 || target >= count {
        raise InvalidState(target)
      }
    }
    if ends[state] is Some(target) {
      if target < 0 || target >= count {
        raise InvalidState(target)
      }
    }
  }
  let table = transitions.map(fn(row) { row.copy() })
  let accepting = accepting.copy()
  let (live, universal) = classify_dfa(table, accepting, ends)
  {
    kind: Explicit({
      initial,
      transitions: table,
      accepting,
      eof: ends,
      live,
      universal,
    }),
    states: count,
  }
}
