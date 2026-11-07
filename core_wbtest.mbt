///|
test "set order is lexical, not shortlex; duplicates and empty key" {
  let input = [b"b", b"aba", b"ab", b"a", b"", b"b"]
  let set = FstSet::from_keys(input)
  @debug.assert_eq(set.keys(), [b"", b"a", b"ab", b"aba", b"b"])
  @debug.assert_eq(input, [b"b", b"aba", b"ab", b"a", b"", b"b"])
  assert_eq(set.len(), 5UL)
  assert_true(set.contains(b""))
  assert_false(set.contains(b"aa"))
  let loaded = FstSet::from_bytes(set.to_bytes())
  assert_true(loaded.same_keys(set))
}

///|
test "map output factoring through existing prefix nodes" {
  let pairs = [
    ("", 18446744073709551615UL),
    ("a", 100UL),
    ("ab", 3UL),
    ("aba", 0UL),
    ("abb", 18446744073709551615UL),
    ("abc", 7UL),
    ("b", 2UL),
    ("ba", 1UL),
    ("bb", 9UL),
    ("c", 0UL),
  ]
  let map = FstMap::from_strings(pairs)
  @debug.assert_eq(map.string_entries(), pairs)
  for pair in pairs {
    let (key, value) = pair
    @debug.assert_eq(map.get_str(key), Some(value))
  }
  @debug.assert_eq(map.get(b"ac"), None)
  @debug.assert_eq(map.get(b"abbb"), None)
  let stats = map.as_fst().statistics()
  assert_eq(stats.keys, 10UL)
  assert_eq(stats.min_key_length, 0)
  assert_eq(stats.max_key_length, 3)
  assert_true(stats.nodes > 0)
}

///|
test "duplicate policies use original order and check arithmetic" {
  let entries = [
    Entry::{ key: b"x", value: 3UL, },
    { key: b"a", value: 1UL, },
    { key: b"x", value: 7UL, },
  ]
  @debug.assert_eq(
    FstMap::from_entries(entries, duplicates=KeepFirst).get(b"x"),
    Some(3UL),
  )
  @debug.assert_eq(
    FstMap::from_entries(entries, duplicates=KeepLast).get(b"x"),
    Some(7UL),
  )
  @debug.assert_eq(
    FstMap::from_entries(entries, duplicates=Sum).get(b"x"),
    Some(10UL),
  )
  @debug.assert_eq(
    FstMap::from_entries(entries, duplicates=Minimum).get(b"x"),
    Some(3UL),
  )
  @debug.assert_eq(
    FstMap::from_entries(entries, duplicates=Maximum).get(b"x"),
    Some(7UL),
  )
  try FstMap::from_entries(entries) catch {
    DuplicateKey(key) => @debug.assert_eq(key, b"x")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("duplicate accepted")
  }
  try
    FstMap::from_strings(
      [("x", 18446744073709551615UL), ("x", 1UL)],
      duplicates=Sum,
    )
  catch {
    Overflow => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("sum overflow accepted")
  }
}

///|
test "builder rejects invalid operations without losing prior keys" {
  let builder = Builder::map()
  builder.insert(b"a", 5UL)
  try builder.insert(b"", 0UL) catch {
    OutOfOrder(_, _) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("unsorted accepted")
  }
  try builder.insert(b"a", 6UL) catch {
    DuplicateKey(_) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("duplicate accepted")
  }
  builder.insert(b"ab", 1UL)
  let map = builder.into_map()
  @debug.assert_eq(map.string_entries(), [("a", 5UL), ("ab", 1UL)])
  try builder.finish() catch {
    BuilderClosed => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("double finish accepted")
  }
  try builder.insert(b"b", 2UL) catch {
    BuilderClosed => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("write after finish accepted")
  }
}

///|
test "bounded registry and disabled registry preserve every output" {
  let entries = []
  for i = 0; i < 500; i = i + 1 {
    entries.push(Entry::{
      key: string_bytes("word-\{i}-shared"),
      value: (i * 719).to_uint64(),
    })
  }
  let reference = FstMap::from_entries(entries)
  for capacity in [0, 1, 2, 7, 100] {
    let map = FstMap::from_entries(entries, registry_capacity=capacity)
    assert_true(reference.same_entries(map))
  }
}

///|
test "arbitrary bytes and all 256 outgoing edges" {
  let keys = [b""]
  for i = 0; i < 256; i = i + 1 {
    keys.push(Bytes::from_array([i.to_byte()]))
    keys.push(Bytes::from_array([i.to_byte(), b'\x00', b'\xff']))
  }
  let set = FstSet::from_keys(keys)
  assert_eq(set.len(), 513UL)
  assert_eq(set.as_fst().statistics().max_fanout, 256)
  for key in keys {
    assert_true(set.contains(key))
  }
  try set.strings() catch {
    InvalidUtf8 => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("invalid UTF-8 decoded")
  }
  @debug.assert_eq(set.prefix(b"\xff").keys(), [b"\xff", b"\xff\x00\xff"])
}

///|
test "iterative traversal handles a long single key" {
  let key = Bytes::from_array(Array::make(12000, b'x'))
  let set = FstSet::from_keys([key])
  assert_true(set.contains(key))
  @debug.assert_eq(set.keys(), [key])
  assert_eq(set.as_fst().statistics().max_key_length, 12000)
}

///|
test "range endpoint combinations and prefix carry" {
  let set = FstSet::from_strings(["", "a", "aa", "ab", "b", "ba", "z", "za"])
  let keys = set.keys()
  let bounds = [
    Unbounded,
    Included(b""),
    Excluded(b""),
    Included(b"a"),
    Excluded(b"a"),
    Included(b"b"),
    Excluded(b"b"),
    Included(b"za"),
    Excluded(b"za"),
    Included(b"\xff"),
  ]
  for lower in bounds {
    for upper in bounds {
      let range = KeyRange::{ lower, upper, }
      @debug.assert_eq(
        set.stream(range~).keys(),
        keys.filter(fn(key) { range.contains(key) }),
      )
    }
  }
  @debug.assert_eq(prefix_successor(b"ab\xff"), Some(b"ac"))
  @debug.assert_eq(prefix_successor(b"\xff\xff"), None)
  @debug.assert_eq(prefix_successor(b""), None)
  @debug.assert_eq(set.prefix_str("a").strings(), ["a", "aa", "ab"])
  @debug.assert_eq(set.prefix_str("").strings(), set.strings())
}

///|
test "streams are independent and continue after take and skip" {
  let set = FstSet::from_strings(["a", "b", "c", "d", "e"])
  let a = set.stream()
  let b = set.stream()
  @debug.assert_eq(a.take(2).map(fn(e) { e.key }), [b"a", b"b"])
  assert_eq(a.skip(1), 1)
  @debug.assert_eq(a.keys(), [b"d", b"e"])
  @debug.assert_eq(a.next(), None)
  @debug.assert_eq(b.keys(), set.keys())
  b.close()
  @debug.assert_eq(b.next(), None)
}

///|
test "automaton traversal agrees with direct predicate" {
  let set = FstSet::from_strings([
    "", "a", "ab", "abc", "cab", "cat", "cot", "cut", "中国", "中间", "😀",
    "😀猫",
  ])
  let matchers = [
    @automaton.always(),
    @automaton.never(),
    @automaton.exact("cat"),
    @automaton.prefix("a"),
    @automaton.subsequence("ab"),
    @automaton.complement(@automaton.prefix("c")),
    @automaton.union(@automaton.prefix("a"), @automaton.exact("cat")),
    @automaton.intersection(@automaton.prefix("c"), @automaton.subsequence("t")),
    @automaton.levenshtein("cat", 1),
    @automaton.levenshtein("中国", 1),
  ]
  let keys = set.keys()
  for matcher in matchers {
    @debug.assert_eq(
      set.search(matcher).keys(),
      keys.filter(fn(key) { matcher.matches(key) }),
    )
  }
}

///|
test "stored common prefixes and longest prefix preserve map outputs" {
  let fst = FstMap::from_strings([
    ("", 9UL),
    ("a", 8UL),
    ("ab", 7UL),
    ("abc", 6UL),
    ("b", 5UL),
  ]).as_fst()
  @debug.assert_eq(
    fst.common_prefixes(b"abcd").map(fn(e) { (e.key, e.value) }),
    [(b"", 9UL), (b"a", 8UL), (b"ab", 7UL), (b"abc", 6UL)],
  )
  @debug.assert_eq(
    fst.longest_prefix(b"abx"),
    Some(Entry::{ key: b"ab", value: 7UL, }),
  )
  @debug.assert_eq(
    fst.longest_prefix(b"x"),
    Some(Entry::{ key: b"", value: 9UL, }),
  )
  @debug.assert_eq(FstSet::from_keys([]).as_fst().longest_prefix(b"x"), None)
}

///|
test "set algebra and predicates" {
  let a = FstSet::from_strings(["", "a", "ab", "b"])
  let b = FstSet::from_strings(["a", "b", "c"])
  @debug.assert_eq(a.union(b).strings(), ["", "a", "ab", "b", "c"])
  @debug.assert_eq(a.intersection(b).strings(), ["a", "b"])
  @debug.assert_eq(a.difference(b).strings(), ["", "ab"])
  @debug.assert_eq(a.symmetric_difference(b).strings(), ["", "ab", "c"])
  assert_true(a.intersection(b).is_subset(a))
  assert_true(a.union(b).is_superset(b))
  assert_true(a.difference(b).is_disjoint(b))
  assert_false(a.is_subset(b))
  assert_true(FstSet::from_keys([]).is_subset(a))
}

///|
test "heap merge source indices, parity and reducers" {
  let a = FstMap::from_strings([("a", 1UL), ("b", 2UL)])
  let b = FstMap::from_strings([("a", 3UL), ("c", 4UL)])
  let c = FstMap::from_strings([("a", 5UL), ("b", 6UL)])
  let inputs = [a.as_fst(), b.as_fst(), c.as_fst()]
  let union = merge(inputs, Union).collect()
  @debug.assert_eq(union[0], MergedEntry::{
    key: b"a",
    values: [
      { index: 0, value: 1UL, },
      { index: 1, value: 3UL, },
      { index: 2, value: 5UL, },
    ],
  })
  @debug.assert_eq(merge(inputs, Intersection).into_set().strings(), ["a"])
  @debug.assert_eq(merge(inputs, Difference).into_set().strings(), [])
  @debug.assert_eq(merge(inputs, SymmetricDifference).into_set().strings(), [
    "a", "c",
  ])
  @debug.assert_eq(merge(inputs, Union).into_map(Sum).string_entries(), [
    ("a", 9UL),
    ("b", 8UL),
    ("c", 4UL),
  ])
  @debug.assert_eq(a.union(b, KeepLast).string_entries(), [
    ("a", 3UL),
    ("b", 2UL),
    ("c", 4UL),
  ])
  assert_eq(merge([], Intersection).count(), 0UL)
  assert_eq(merge([a.as_fst(), a.as_fst()], SymmetricDifference).count(), 0UL)
}

///|
test "random byte dictionaries round trip and algebra agree with reference" {
  let mut seed = 491729U
  for round = 0; round < 20; round = round + 1 {
    let entries : Map[Bytes, UInt64] = Map([])
    for i = 0; i < 200; i = i + 1 {
      seed = seed * 1664525U + 1013904223U
      let length = (seed % 12U).reinterpret_as_int()
      let bytes = []
      for j = 0; j < length; j = j + 1 {
        seed = seed * 1664525U + 1013904223U
        bytes.push((seed >> 24).to_byte())
      }
      seed = seed * 1664525U + 1013904223U
      let high = seed.to_uint64()
      seed = seed * 1664525U + 1013904223U
      entries[Bytes::from_array(bytes)] = (high << 32) | seed.to_uint64()
    }
    let expected = entries
      .iter()
      .map(fn(pair) { Entry::{ key: pair.0, value: pair.1, } })
      .to_array()
    expected.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
    let map = FstMap::from_sorted(expected, registry_capacity=round % 11)
    @debug.assert_eq(map.entries(), expected)
    for entry in expected {
      @debug.assert_eq(map.get(entry.key), Some(entry.value))
    }
    let left = FstSet::from_keys(
      expected
      .mapi(fn(i, e) { (i, e) })
      .filter(fn(p) { p.0 % 2 == 0 })
      .map(fn(p) { p.1.key }),
    )
    let right = FstSet::from_keys(
      expected
      .mapi(fn(i, e) { (i, e) })
      .filter(fn(p) { p.0 % 3 == 0 })
      .map(fn(p) { p.1.key }),
    )
    @debug.assert_eq(
      left.intersection(right).keys(),
      expected
      .mapi(fn(i, e) { (i, e) })
      .filter(fn(p) { p.0 % 6 == 0 })
      .map(fn(p) { p.1.key }),
    )
  }
}
