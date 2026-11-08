///|
fn bytes_from_ints(values : Array[Int32]) -> Bytes {
  Bytes::makei(values.length(), fn(i) { values[i].to_byte() })
}

///|
fn[T] automaton_raises(run : () -> T raise AutomatonError) -> Bool {
  try {
    ignore(run())
    false
  } catch {
    _ => true
  }
}

///|
fn small_byte_words(alphabet : Array[Int32], maximum : Int32) -> Array[Bytes] {
  let all = [b""]
  let mut level = [b""]
  for _ in 0..<maximum {
    let next : Array[Bytes] = []
    for prefix in level {
      for byte in alphabet {
        let word = Bytes::makei(prefix.length() + 1, fn(i) {
          if i < prefix.length() {
            prefix[i]
          } else {
            byte.to_byte()
          }
        })
        next.push(word)
        all.push(word)
      }
    }
    level = next
  }
  all
}

///|
fn state_after(matcher : Matcher, key : Bytes) -> Int32 {
  key
  .iter()
  .fold(init=matcher.start(), fn(state, byte) { matcher.accept(state, byte) })
}

///|
test "dynamic automaton trait, empty language and empty key" {
  let all : &Automaton = always()
  assert_true(accepts(all, b""))
  assert_true(accepts(all, b"\x00\xff"))
  assert_false(never().matches(b""))
  assert_false(never().matches(b"anything"))
  assert_true(exact_bytes(b"").matches(b""))
  assert_false(exact_bytes(b"").matches(b"a"))
  assert_true(prefix_bytes(b"").matches(b"\xff"))
  assert_true(subsequence_bytes(b"").matches(b"anything"))
}

///|
test "literal prefixes, binary keys and byte subsequences" {
  let literal = exact_bytes(b"a\x00\xff")
  assert_true(literal.matches(b"a\x00\xff"))
  assert_false(literal.matches(b"a\x00"))
  assert_false(literal.matches(b"a\x00\xffa"))
  assert_true(prefix("月").matches_string("月亮"))
  assert_false(prefix("月").matches_string("日月"))
  assert_true(subsequence("abc").matches_string("a--b--c"))
  assert_false(subsequence("abc").matches_string("acb"))
  assert_true(subsequence_bytes(b"\xff\x00").matches(b"\xffa\x00"))
  assert_false(literal.can_match(-1))
  assert_false(literal.is_match(100))
  assert_eq(literal.accept(-1, b'a'), -1)
}

///|
test "Boolean combinations obey their language identities" {
  let a = prefix_bytes(b"a")
  let b = subsequence_bytes(b"b")
  let either = union(a, b)
  let both = intersection(a, b)
  let negated = complement(a)
  let demorgan = complement(union(complement(a), complement(b)))
  for word in small_byte_words([0, 97, 98, 255], 3) {
    assert_eq(either.matches(word), a.matches(word) || b.matches(word))
    assert_eq(both.matches(word), a.matches(word) && b.matches(word))
    assert_eq(negated.matches(word), !a.matches(word))
    assert_eq(demorgan.matches(word), both.matches(word))
  }
  assert_true(complement(never()).matches(b"arbitrary"))
  assert_false(complement(always()).matches(b""))
}

///|
test "starts_with absorbs any accepted prefix" {
  let matcher = starts_with(union(exact("cat"), exact("dog")))
  for word in ["cat", "cats", "dog", "dogma"] {
    assert_true(matcher.matches_string(word))
  }
  for word in ["", "ca", "d", "xcat", "do"] {
    assert_false(matcher.matches_string(word))
  }
  assert_true(starts_with(exact("")).matches(b"\xff"))
  assert_false(starts_with(never()).matches(b"cat"))
}

///|
test "byte range and finite or unbounded byte lengths" {
  let digit = byte_range(b'0', b'9')
  assert_true(digit.matches(b"5"))
  assert_false(digit.matches(b"55"))
  assert_false(digit.matches(b"a"))
  assert_true(automaton_raises(() => byte_range(b'z', b'a')))
  let finite = byte_length(2, maximum=4)
  let unbounded = byte_length(2)
  for count in 0..<8 {
    let key = Bytes::make(count, b'x')
    assert_eq(finite.matches(key), count >= 2 && count <= 4)
    assert_eq(unbounded.matches(key), count >= 2)
  }
  assert_true(automaton_raises(() => byte_length(-1)))
  assert_true(automaton_raises(() => byte_length(4, maximum=3)))
  assert_true(automaton_raises(() => byte_length(10, max_states=10)))
}

///|
test "composition limits reject oversized arithmetic products" {
  let a = exact("abcdef")
  assert_true(automaton_raises(() => union(a, a, max_states=63)))
  assert_eq(union(a, a, max_states=64).state_count(), 64)
  assert_true(automaton_raises(() => complement(a, max_states=7)))
  assert_true(automaton_raises(() => starts_with(a, max_states=8)))
  assert_true(automaton_raises(() => intersection(a, a, max_states=0)))
}

///|
test "pruning promises are sound over exhaustive short continuations" {
  let matchers = [
    always(),
    never(),
    exact("ab"),
    prefix("ab"),
    subsequence("ab"),
    complement(prefix("a")),
    union(exact("b"), prefix("a")),
    intersection(prefix("a"), subsequence("b")),
    starts_with(exact("ab")),
    byte_length(1),
    byte_length(0, maximum=2),
  ]
  let words = small_byte_words([0, 97, 98, 255], 2)
  for matcher in matchers {
    for prefix in words {
      let state = state_after(matcher, prefix)
      for suffix in words {
        let end = suffix
          .iter()
          .fold(init=state, fn(state, byte) { matcher.accept(state, byte) })
        let accepted = end_matches(matcher, end)
        if !matcher.can_match(state) {
          assert_false(accepted)
        }
        if matcher.will_always_match(state) {
          assert_true(accepted)
        }
      }
    }
  }
}

///|
test "explicit DFA cyclic liveness and universal suffix classification" {
  let builder = DfaBuilder::new()
  let dead = builder.add_state(false)
  let all = builder.add_state(true)
  let prefix = builder.add_state(false)
  builder.add_range(dead, b'\x00', b'\xff', dead)
  builder.add_range(all, b'\x00', b'\xff', all)
  builder.add_transition(prefix, b'a', all)
  builder.set_start(prefix)
  let machine = builder.build()
  assert_false(machine.can_match(dead))
  assert_false(machine.will_always_match(dead))
  assert_true(machine.can_match(prefix))
  assert_false(machine.will_always_match(prefix))
  assert_true(machine.will_always_match(all))
  assert_true(machine.matches(b"a\x00\xff"))
  assert_false(machine.matches(b""))
  assert_false(machine.matches(b"b"))
}

///|
test "DFA EOF transitions compose and starts_with tests prefix EOF" {
  let builder = DfaBuilder::new()
  let initial = builder.add_state(false)
  let after_a = builder.add_state(false)
  let yes = builder.add_state(true)
  builder.add_transition(initial, b'a', after_a)
  builder.set_eof(after_a, Some(yes))
  let machine = builder.build()
  assert_true(machine.matches(b"a"))
  assert_false(machine.matches(b""))
  assert_false(machine.matches(b"ab"))
  assert_true(complement(machine).matches(b"ab"))
  assert_false(complement(machine).matches(b"a"))
  assert_true(union(machine, exact("b")).matches(b"a"))
  assert_true(intersection(machine, prefix("a")).matches(b"a"))
  assert_true(starts_with(machine).matches(b"abc"))
}

///|
test "DFA snapshot independence, conflicting ranges and invalid tables" {
  let builder = DfaBuilder::new(max_states=2)
  let initial = builder.add_state(false)
  let yes = builder.add_state(true)
  builder.add_transition(initial, b'b', yes)
  assert_true(
    automaton_raises(() => builder.add_range(initial, b'a', b'c', yes)),
  )
  let snapshot = builder.build()
  assert_false(snapshot.matches(b"a"))
  builder.remove_transition(initial, b'b')
  builder.add_transition(initial, b'a', yes)
  assert_true(snapshot.matches(b"b"))
  assert_false(snapshot.matches(b"a"))
  assert_true(builder.build().matches(b"a"))
  assert_true(automaton_raises(() => builder.add_state(false)))
  assert_true(automaton_raises(() => builder.set_start(2)))
  assert_true(automaton_raises(() => builder.set_eof(0, Some(2))))
  assert_true(automaton_raises(() => dfa_from_table(0, [[0]], [true])))
  let row = Array::make(256, -1)
  row[0] = 1
  assert_true(automaton_raises(() => dfa_from_table(0, [row], [true])))
  row[0] = 0
  let machine = dfa_from_table(0, [row], [true])
  row[1] = 0
  assert_false(machine.matches(b"\x01"))
  assert_true(machine.matches(b"\x00\x00"))
}

///|
test "EOF rejection overrides raw acceptance through every combinator" {
  let builder = DfaBuilder::new()
  let yes = builder.add_state(true)
  let no = builder.add_state(false)
  builder.set_eof(yes, Some(no))
  let machine = builder.build()
  assert_false(machine.matches(b""))
  assert_false(machine.can_match(yes))
  assert_true(complement(machine).matches(b""))
  assert_false(starts_with(machine).matches(b""))
  assert_false(starts_with(machine).matches(b"a"))
  assert_false(intersection(machine, always()).matches(b""))
  assert_false(union(machine, never()).matches(b""))
}
