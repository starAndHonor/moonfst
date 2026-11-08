///|
fn reference_value_statistics(entries : Array[Entry]) -> ValueStatistics {
  let mut minimum : UInt64? = None
  let mut maximum : UInt64? = None
  let mut sum = Some(0UL)
  for entry in entries {
    minimum = match minimum {
      Some(value) if value < entry.value => minimum
      _ => Some(entry.value)
    }
    maximum = match maximum {
      Some(value) if value > entry.value => maximum
      _ => Some(entry.value)
    }
    sum = match sum {
      Some(value) => {
        let next = value + entry.value
        if next < value {
          None
        } else {
          Some(next)
        }
      }
      None => None
    }
  }
  { count: entries.length().to_uint64(), minimum, maximum, sum, }
}

///|
test "value statistics and ranked output match materialized reference" {
  let mut seed = 719337U
  for round = 0; round < 12; round = round + 1 {
    let entries = []
    for i = 0; i < 150; i = i + 1 {
      seed = seed * 1664525U + 1013904223U
      let value = if round % 2 == 0 {
        (seed % 17U).to_uint64()
      } else {
        (seed.to_uint64() << 32) | (seed ^ 0xac18c34U).to_uint64()
      }
      entries.push(Entry::{ key: string_bytes("word-\{i}"), value, })
    }
    entries.push({ key: b"", value: 0UL, })
    let map = FstMap::from_entries(entries)
    let ordered = map.entries()
    let index = map.as_fst().index()
    @debug.assert_eq(
      index.value_statistics(),
      reference_value_statistics(ordered),
    )
    for start = 0; start < ordered.length(); start = start + 7 {
      for end = start; end <= ordered.length(); end = end + 13 {
        let expected = ordered.exact_view(start~, end~).to_owned()
        @debug.assert_eq(
          index.value_statistics_at(start.to_uint64(), end.to_uint64()),
          reference_value_statistics(expected),
        )
      }
    }
    for
      range in [
        KeyRange::all(),
        KeyRange::prefix(b"word-1"),
        KeyRange::between(b"word-30", b"word-70"),
        { lower: Excluded(b"word-99"), upper: Unbounded, },
        KeyRange::between(b"z", b"a"),
      ] {
      let expected = ordered.filter(fn(entry) { range.contains(entry.key) })
      @debug.assert_eq(
        index.value_statistics(range~),
        reference_value_statistics(expected),
      )
      expected.sort_by(fn(a, b) {
        if a.value == b.value {
          a.key.lexical_compare(b.key)
        } else if a.value > b.value {
          -1
        } else {
          1
        }
      })
      for limit in [0, 1, 2, 10, 200] {
        @debug.assert_eq(
          index.top(limit, range~),
          expected.exact_view(end=limit.min(expected.length())).to_owned(),
        )
      }
    }
    @debug.assert_eq(
      index.prefix_value_statistics(b"word-1"),
      index.value_statistics(range=KeyRange::prefix(b"word-1")),
    )
  }
}

///|
test "value statistics report overflow without losing count or extrema" {
  let index = FstMap::from_strings([
      ("a", 18446744073709551615UL),
      ("ab", 0UL),
      ("b", 1UL),
    ])
    .as_fst()
    .index()
  @debug.assert_eq(index.value_statistics(), ValueStatistics::{
    count: 3UL,
    minimum: Some(0UL),
    maximum: Some(18446744073709551615UL),
    sum: None,
  })
  @debug.assert_eq(
    index.prefix_value_statistics(b"a").sum,
    Some(18446744073709551615UL),
  )
  @debug.assert_eq(index.top(2).map(fn(e) { e.key }), [b"a", b"b"])
  let empty = FstSet::from_keys([]).as_fst().index()
  @debug.assert_eq(empty.value_statistics(), reference_value_statistics([]))
  @debug.assert_eq(empty.top(3), [])
  try index.value_statistics_at(2UL, 1UL) catch {
    InvalidArgument(_) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("reversed ordinal range accepted")
  }
  try index.top(-1) catch {
    InvalidArgument(_) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("negative top count accepted")
  }
}

///|
test "reverse traversal, filters and both kinds of reverse pages" {
  let map = FstMap::from_strings([
    ("", 0UL),
    ("a", 1UL),
    ("aa", 2UL),
    ("ab", 3UL),
    ("aba", 4UL),
    ("b", 5UL),
    ("月光", 6UL),
    ("月亮", 7UL),
  ])
  let fst = map.as_fst()
  let index = fst.index()
  let keys = map.entries()
  let bounds = [
    Unbounded,
    Included(b""),
    Excluded(b""),
    Included(b"a"),
    Excluded(b"a"),
    Included(b"b"),
    Excluded(b"b"),
  ]
  let matchers = [
    @automaton.always(),
    @automaton.never(),
    @automaton.prefix("a"),
    @automaton.levenshtein("ab", 1),
  ]
  for lower in bounds {
    for upper in bounds {
      let range = KeyRange::{ lower, upper, }
      let expected = keys.filter(fn(e) { range.contains(e.key) })
      expected.rev_in_place()
      @debug.assert_eq(fst.reverse(range~).collect(), expected)
      for offset in [0UL, 1UL, 4UL, 18446744073709551615UL] {
        let page = if offset >= expected.length().to_uint64() {
          []
        } else {
          let start = offset.to_int()
          expected
          .exact_view(start~, end=(start + 3).min(expected.length()))
          .to_owned()
        }
        @debug.assert_eq(index.page_reverse(offset, 3, range~), page)
      }
      for matcher in matchers {
        let matching = expected.filter(fn(e) { matcher.matches(e.key) })
        @debug.assert_eq(
          fst.search_reverse(matcher, range~).collect(),
          matching,
        )
        let search = index.search_index(matcher)
        @debug.assert_eq(
          search.page_reverse(0UL, 3, range~),
          matching.exact_view(end=matching.length().min(3)).to_owned(),
        )
      }
    }
  }
  let backwards = fst.reverse()
  @debug.assert_eq(backwards.take(1).map(fn(e) { e.key }), [
    string_bytes("月光"),
  ])
  assert_eq(backwards.skip(1), 1)
  assert_eq(backwards.count(), 6UL)
  @debug.assert_eq(backwards.next(), None)
  backwards.close()
}
