///|
test "FST search and range pruning agree with direct automaton execution" {
  let keys = [
    b"", b"a", b"ab", b"abc", b"b", b"ba", b"xaaa", b"yaaa", b"xbaa", b"ybaa", b"\xc3",
    b"\xc3\xa9", b"\xf0\x9f\x98\x80", b"\xff",
  ]
  let set = @fst.FstSet::from_keys(keys)
  let sorted = set.keys()
  let matchers = [
    @a.always(),
    @a.never(),
    @a.exact("a"),
    @a.prefix("x"),
    @a.subsequence("ba"),
    @a.union(@a.prefix("x"), @a.prefix("y")),
    @a.intersection(@a.prefix("y"), @a.subsequence("b")),
    @a.complement(@a.exact("a")),
    @a.starts_with(@a.exact("a")),
    @a.levenshtein("", 1),
    @a.levenshtein("é", 1),
  ]
  for matcher in matchers {
    for
      range in [
        @fst.KeyRange::all(),
        @fst.KeyRange::closed(b"a", b"b"),
        @fst.KeyRange::prefix(b"\xc3"),
      ] {
      let expected = sorted.filter(fn(key) {
        range.contains(key) && @a.accepts(matcher, key)
      })
      let actual = set.search(matcher, range~).keys()
      assert_eq(actual, expected)
    }
  }
}

///|
test "FST EOF acceptance does not consume or alter states used for longer keys" {
  let builder = @a.DfaBuilder::new()
  let start = builder.add_state(false)
  let after_a = builder.add_state(false)
  let yes = builder.add_state(true)
  builder.add_transition(start, b'a', after_a)
  builder.add_transition(after_a, b'b', after_a)
  builder.set_eof(after_a, Some(yes))
  let matcher = builder.build()
  let set = @fst.FstSet::from_strings(["", "a", "ab", "abb", "abc", "b"])
  assert_eq(set.search(matcher).strings(), ["a", "ab", "abb"])
  assert_eq(set.search(@a.complement(matcher)).strings(), ["", "abc", "b"])
  assert_eq(set.search(@a.starts_with(matcher)).strings(), [
    "a", "ab", "abb", "abc",
  ])
}

///|
test "FST checks EOF acceptance at the empty key before traversing children" {
  let builder = @a.DfaBuilder::new()
  let initial = builder.add_state(false)
  let yes = builder.add_state(true)
  builder.set_eof(initial, Some(yes))
  let set = @fst.FstSet::from_strings(["", "a", "b"])
  assert_eq(set.search(builder.build()).strings(), [""])
}
