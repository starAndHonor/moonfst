// Copyright 2026 moonfst contributors.
// SPDX-License-Identifier: MIT
// Automaton semantics follow BurntSushi/fst 0.4.7 (MIT OR Unlicense).

///|
/// A deterministic byte automaton. State -1 is the rejecting sink.
/// Implementations must keep state identities stable throughout a traversal.
/// `can_match` and `will_always_match` are conservative pruning promises.
/// `accept_eof` optionally substitutes the state when a key ends.
pub(open) trait Automaton {
  fn start(Self) -> Int32
  fn accept(Self, Int32, Byte) -> Int32
  fn is_match(Self, Int32) -> Bool
  fn can_match(Self, Int32) -> Bool
  fn will_always_match(Self, Int32) -> Bool
  fn accept_eof(Self, Int32) -> Int32?
}

///|
#derive(Eq, @debug.Debug)
pub(all) suberror AutomatonError {
  InvalidArgument(String)
  StateLimit(limit~ : Int32)
  WorkLimit(limit~ : Int32)
  InvalidState(Int32)
  DuplicateTransition(state~ : Int32, byte~ : Int32)
}

///|
/// Immutable, shareable automata. All transition state is carried by the Int32
/// supplied by the caller; a matcher never builds caches during a search.
pub struct Matcher {
  priv kind : Kind
  priv states : Int32
}

///|
priv enum Kind {
  All
  Empty
  Literal(Bytes, Bool)
  Subsequent(Bytes)
  OneByte(Int32, Int32)
  Length(Int32, Int32?)
  Either(Matcher, Matcher)
  Both(Matcher, Matcher)
  Not(Matcher)
  Beginning(Matcher)
  Explicit(DfaMachine)
  Levenshtein(LevenMachine)
}

///|
/// Maximum number of representable states for composed matchers.
/// Constructors reject a product before its Int32 state encoding can overflow.
pub let default_state_limit : Int32 = 1000000

///|
pub fn always() -> Matcher {
  { kind: All, states: 1, }
}

///|
pub fn never() -> Matcher {
  { kind: Empty, states: 0, }
}

///|
pub fn exact_bytes(pattern : Bytes) -> Matcher {
  { kind: Literal(pattern, false), states: pattern.length() + 1, }
}

///|
/// Exact UTF-8 byte matching; no normalization or case folding is applied.
pub fn exact(pattern : String) -> Matcher {
  exact_bytes(@utf8.encode(pattern))
}

///|
pub fn prefix_bytes(pattern : Bytes) -> Matcher {
  { kind: Literal(pattern, true), states: pattern.length() + 1, }
}

///|
pub fn prefix(pattern : String) -> Matcher {
  prefix_bytes(@utf8.encode(pattern))
}

///|
/// Matches a byte subsequence, preserving order but permitting gaps.
pub fn subsequence_bytes(pattern : Bytes) -> Matcher {
  { kind: Subsequent(pattern), states: pattern.length() + 1, }
}

///|
/// Subsequence matching follows fst's byte semantics, including for UTF-8.
pub fn subsequence(pattern : String) -> Matcher {
  subsequence_bytes(@utf8.encode(pattern))
}

///|
/// Accepts exactly one byte in the inclusive range.
pub fn byte_range(lower : Byte, upper : Byte) -> Matcher raise AutomatonError {
  if lower > upper {
    raise InvalidArgument("byte range lower bound exceeds upper bound")
  }
  { kind: OneByte(lower.to_int(), upper.to_int()), states: 2, }
}

///|
/// Constrains byte length. An absent maximum accepts all lengths >= minimum.
pub fn byte_length(
  minimum : Int32,
  maximum? : Int32,
  max_states~ : Int32 = default_state_limit,
) -> Matcher raise AutomatonError {
  if minimum < 0 || max_states <= 0 {
    raise InvalidArgument("length must be nonnegative and state limit positive")
  }
  let last = match maximum {
    Some(n) => {
      if n < minimum {
        raise InvalidArgument("maximum length is smaller than minimum length")
      }
      n
    }
    None => minimum
  }
  if last >= max_states {
    raise StateLimit(limit=max_states)
  }
  { kind: Length(minimum, maximum), states: last + 1, }
}

///|
fn product_size(
  left : Matcher,
  right : Matcher,
  limit : Int32,
) -> Int32 raise AutomatonError {
  if limit <= 0 {
    raise InvalidArgument("state limit must be positive")
  }
  // One extra component value represents each child's rejecting sink.
  if left.states >= limit || right.states >= limit {
    raise StateLimit(limit~)
  }
  let a = left.states + 1
  let b = right.states + 1
  if a > limit / b {
    raise StateLimit(limit~)
  }
  a * b
}

///|
pub fn union(
  left : Matcher,
  right : Matcher,
  max_states~ : Int32 = default_state_limit,
) -> Matcher raise AutomatonError {
  { kind: Either(left, right), states: product_size(left, right, max_states), }
}

///|
pub fn intersection(
  left : Matcher,
  right : Matcher,
  max_states~ : Int32 = default_state_limit,
) -> Matcher raise AutomatonError {
  { kind: Both(left, right), states: product_size(left, right, max_states), }
}

///|
pub fn complement(
  inner : Matcher,
  max_states~ : Int32 = default_state_limit,
) -> Matcher raise AutomatonError {
  if max_states <= 0 {
    raise InvalidArgument("state limit must be positive")
  }
  if inner.states >= max_states {
    raise StateLimit(limit=max_states)
  }
  { kind: Not(inner), states: inner.states + 1, }
}

///|
/// Accepts a key if any prefix, including the empty prefix, matches `inner`.
pub fn starts_with(
  inner : Matcher,
  max_states~ : Int32 = default_state_limit,
) -> Matcher raise AutomatonError {
  if max_states < 2 {
    raise InvalidArgument("starts_with needs a state limit of at least two")
  }
  if inner.states > max_states - 2 {
    raise StateLimit(limit=max_states)
  }
  { kind: Beginning(inner), states: inner.states + 2, }
}

///|
/// Number of state IDs reserved by this matcher's arithmetic encoding.
pub fn Matcher::state_count(self : Matcher) -> Int32 {
  self.states
}

///|
fn pair_state(left : Int32, right : Int32, width : Int32) -> Int32 {
  (left + 1) * width + right + 1
}

///|
fn split_state(state : Int32, width : Int32) -> (Int32, Int32) {
  (state / width - 1, state % width - 1)
}

///|
fn end_matches(automaton : Matcher, state : Int32) -> Bool {
  automaton.is_match(automaton.accept_eof(state).unwrap_or(state))
}

///|
/// Runs an automaton on one key, including its optional EOF transition.
pub fn accepts(automaton : &Automaton, key : Bytes) -> Bool {
  let mut state = automaton.start()
  for byte in key {
    if !automaton.can_match(state) {
      return false
    }
    state = automaton.accept(state, byte)
  }
  let final_state = automaton.accept_eof(state).unwrap_or(state)
  automaton.is_match(final_state)
}

///|
pub fn Matcher::matches(self : Matcher, key : Bytes) -> Bool {
  accepts(self, key)
}

///|
pub fn Matcher::matches_string(self : Matcher, key : String) -> Bool {
  self.matches(@utf8.encode(key))
}
