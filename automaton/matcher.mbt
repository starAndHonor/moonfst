// SPDX-License-Identifier: MIT

///|
pub impl Automaton for Matcher with fn start(self) {
  match self.kind {
    Empty => -1
    Either(a, b) | Both(a, b) => pair_state(a.start(), b.start(), b.states + 1)
    Not(inner) => inner.start() + 1
    Beginning(inner) => {
      let state = inner.start()
      if end_matches(inner, state) {
        inner.states + 1
      } else {
        state + 1
      }
    }
    Explicit(machine) => machine.initial
    _ => 0
  }
}

///|
pub impl Automaton for Matcher with fn accept(self, state, byte) {
  if state < 0 || state >= self.states {
    return -1
  }
  match self.kind {
    All => 0
    Empty => -1
    Literal(pattern, prefix) =>
      if state == pattern.length() {
        if prefix {
          state
        } else {
          -1
        }
      } else if pattern[state] == byte {
        state + 1
      } else {
        -1
      }
    Subsequent(pattern) =>
      if state == pattern.length() {
        state
      } else if pattern[state] == byte {
        state + 1
      } else {
        state
      }
    OneByte(lo, hi) =>
      if state == 0 && byte.to_int() >= lo && byte.to_int() <= hi {
        1
      } else {
        -1
      }
    Length(minimum, maximum) =>
      match maximum {
        Some(n) => if state < n { state + 1 } else { -1 }
        None => if state < minimum { state + 1 } else { minimum }
      }
    Either(a, b) | Both(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      pair_state(a.accept(sa, byte), b.accept(sb, byte), b.states + 1)
    }
    Not(inner) => inner.accept(state - 1, byte) + 1
    Beginning(inner) =>
      if state == inner.states + 1 {
        state
      } else {
        let next = inner.accept(state - 1, byte)
        if end_matches(inner, next) {
          inner.states + 1
        } else {
          next + 1
        }
      }
    Explicit(machine) => machine.transitions[state][byte.to_int()]
    Levenshtein(machine) => machine.step(state, byte)
  }
}

///|
pub impl Automaton for Matcher with fn is_match(self, state) {
  if state < 0 || state >= self.states {
    return false
  }
  match self.kind {
    All => true
    Empty => false
    Literal(pattern, _) | Subsequent(pattern) => state == pattern.length()
    OneByte(_, _) => state == 1
    Length(minimum, _) => state >= minimum
    Either(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      a.is_match(sa) || b.is_match(sb)
    }
    Both(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      a.is_match(sa) && b.is_match(sb)
    }
    Not(inner) => !inner.is_match(state - 1)
    Beginning(inner) => state == inner.states + 1
    Explicit(machine) => machine.accepting[state]
    Levenshtein(machine) => machine.matches(state)
  }
}

///|
pub impl Automaton for Matcher with fn can_match(self, state) {
  if state < 0 || state >= self.states {
    return false
  }
  match self.kind {
    Empty => false
    Either(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      a.can_match(sa) || b.can_match(sb)
    }
    Both(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      a.can_match(sa) && b.can_match(sb)
    }
    Not(inner) => !inner.will_always_match(state - 1)
    Beginning(inner) => state == inner.states + 1 || inner.can_match(state - 1)
    Explicit(machine) => machine.live[state]
    // Construction interns only DP rows whose minimum is within the bound.
    // A pending valid UTF-8 prefix is conservatively kept live until completion.
    Levenshtein(_) => true
    _ => true
  }
}

///|
pub impl Automaton for Matcher with fn will_always_match(self, state) {
  if state < 0 || state >= self.states {
    return false
  }
  match self.kind {
    All => true
    Empty => false
    Literal(pattern, prefix) => prefix && state == pattern.length()
    Subsequent(pattern) => state == pattern.length()
    Length(minimum, maximum) => maximum is None && state >= minimum
    Either(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      a.will_always_match(sa) || b.will_always_match(sb)
    }
    Both(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      a.will_always_match(sa) && b.will_always_match(sb)
    }
    Not(inner) => !inner.can_match(state - 1)
    Beginning(inner) => state == inner.states + 1
    Explicit(machine) => machine.universal[state]
    _ => false
  }
}

///|
pub impl Automaton for Matcher with fn accept_eof(self, state) {
  if state < 0 || state >= self.states {
    return None
  }
  match self.kind {
    Either(a, b) | Both(a, b) => {
      let (sa, sb) = split_state(state, b.states + 1)
      let ea = a.accept_eof(sa).unwrap_or(sa)
      let eb = b.accept_eof(sb).unwrap_or(sb)
      Some(pair_state(ea, eb, b.states + 1))
    }
    Not(inner) => Some(inner.accept_eof(state - 1).unwrap_or(state - 1) + 1)
    Beginning(inner) =>
      if state == inner.states + 1 {
        None
      } else {
        let end = inner.accept_eof(state - 1).unwrap_or(state - 1)
        if inner.is_match(end) {
          Some(inner.states + 1)
        } else {
          Some(end + 1)
        }
      }
    Explicit(machine) => machine.eof[state]
    _ => None
  }
}
