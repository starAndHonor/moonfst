///|
fn ix_ref_rank(entries : Array[Entry], query : Bytes) -> Int32 {
  let mut rank = 0
  while rank < entries.length() && entries[rank].key.lexical_compare(query) < 0 {
    rank = rank + 1
  }
  rank
}

///|
fn ix_ref_select(entries : Array[Entry], ordinal : Int32) -> Entry? {
  if ordinal < 0 || ordinal >= entries.length() {
    None
  } else {
    Some(entries[ordinal])
  }
}

///|
fn ix_ref_starts(key : Bytes, prefix : Bytes) -> Bool {
  if prefix.length() > key.length() {
    return false
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    if key[i] != prefix[i] {
      return false
    }
  }
  true
}

///|
fn ix_ref_filter(entries : Array[Entry], range : KeyRange) -> Array[Entry] {
  entries.filter(fn(entry) {
    let lower = match range.lower {
      Unbounded => true
      Included(bound) => entry.key.lexical_compare(bound) >= 0
      Excluded(bound) => entry.key.lexical_compare(bound) > 0
    }
    let upper = match range.upper {
      Unbounded => true
      Included(bound) => entry.key.lexical_compare(bound) <= 0
      Excluded(bound) => entry.key.lexical_compare(bound) < 0
    }
    lower && upper
  })
}

///|
fn ix_assert_query(
  index : FstIndex,
  entries : Array[Entry],
  query : Bytes,
) -> Unit raise {
  let rank = ix_ref_rank(entries, query)
  let exists = rank < entries.length() && entries[rank].key == query
  @debug.assert_eq(index.rank(query), (rank.to_uint64(), exists))
  @debug.assert_eq(index.lower_bound(query), ix_ref_select(entries, rank))
  @debug.assert_eq(
    index.upper_bound(query),
    ix_ref_select(entries, rank + (if exists { 1 } else { 0 })),
  )
  @debug.assert_eq(
    index.floor(query),
    ix_ref_select(entries, if exists { rank } else { rank - 1 }),
  )
  @debug.assert_eq(index.predecessor(query), ix_ref_select(entries, rank - 1))
  let prefix_count = entries.count_if(fn(entry) {
    ix_ref_starts(entry.key, query)
  })
  @debug.assert_eq(index.prefix_count(query), prefix_count.to_uint64())
  @debug.assert_eq(
    index.prefix_ranks(query),
    (rank.to_uint64(), (rank + prefix_count).to_uint64()),
  )
}

///|
fn ix_assert_range(
  index : FstIndex,
  entries : Array[Entry],
  range : KeyRange,
) -> Unit raise {
  let expected = ix_ref_filter(entries, range)
  @debug.assert_eq(index.range_count(range), expected.length().to_uint64())
  let lower = entries.count_if(fn(entry) {
    match range.lower {
      Unbounded => false
      Included(bound) => entry.key.lexical_compare(bound) < 0
      Excluded(bound) => entry.key.lexical_compare(bound) <= 0
    }
  })
  let upper = entries.count_if(fn(entry) {
    match range.upper {
      Unbounded => true
      Included(bound) => entry.key.lexical_compare(bound) <= 0
      Excluded(bound) => entry.key.lexical_compare(bound) < 0
    }
  })
  @debug.assert_eq(
    index.range_ranks(range),
    (lower.to_uint64(), (if upper < lower { lower } else { upper }).to_uint64()),
  )
  for limit in [0, 1, 3, 100] {
    for offset in [0, 1, expected.length(), expected.length() + 1] {
      let page = []
      let mut i = offset
      while i < expected.length() && page.length() < limit {
        page.push(expected[i])
        i = i + 1
      }
      @debug.assert_eq(index.page(offset.to_uint64(), limit, range~), page)
    }
  }
  @debug.assert_eq(index.page(0xffffffffffffffffUL, 10, range~), [])
}

///|
test "index empty dictionary and empty-key-only map" {
  let empty = FstSet::from_keys([]).as_fst().index()
  @debug.assert_eq(empty.len(), 0UL)
  @debug.assert_eq(empty.select(0UL), None)
  @debug.assert_eq(empty.select(0xffffffffffffffffUL), None)
  for query in [b"", b"a", b"\x00", b"\xff"] {
    ix_assert_query(empty, [], query)
  }
  ix_assert_range(empty, [], KeyRange::all())
  let one = [Entry::{ key: b"", value: 0xffffffffffffffffUL, }]
  let index = FstMap::from_sorted(one).as_fst().index()
  @debug.assert_eq(index.len(), 1UL)
  @debug.assert_eq(index.select(0UL), Some(one[0]))
  @debug.assert_eq(index.select(1UL), None)
  ix_assert_query(index, one, b"")
  ix_assert_query(index, one, b"\x00")
  ix_assert_range(index, one, KeyRange::closed(b"", b""))
  ix_assert_range(index, one, KeyRange::between(b"", b""))
}

///|
test "index four endpoint combinations including reversed and byte boundary ranges" {
  let keys = [
    b"", b"\x00", b"\x00\x00", b"a", b"aa", b"ab", b"b", b"\xff", b"\xff\x00", b"\xff\xff",
  ]
  let entries = keys.mapi(fn(i, key) {
    Entry::{ key, value: if i % 2 == 0 { 0UL } else { 0xffffffffffffffffUL }, }
  })
  let fst = FstMap::from_sorted(entries).as_fst()
  let index = fst.index()
  @debug.assert_eq(index.cached_nodes(), fst.statistics().nodes)
  for i = 0; i < entries.length(); i = i + 1 {
    @debug.assert_eq(index.select(i.to_uint64()), Some(entries[i]))
    ix_assert_query(index, entries, entries[i].key)
  }
  for query in [b"\x01", b"aaa", b"ac", b"z", b"\xff\xff\x00"] {
    ix_assert_query(index, entries, query)
  }
  let bounds = [
    Unbounded,
    Included(b""),
    Excluded(b""),
    Included(b"\x00"),
    Excluded(b"\x00"),
    Included(b"a"),
    Excluded(b"a"),
    Included(b"ac"),
    Excluded(b"ac"),
    Included(b"\xff"),
    Excluded(b"\xff"),
    Included(b"\xff\xff"),
    Excluded(b"\xff\xff"),
  ]
  for lower in bounds {
    for upper in bounds {
      ix_assert_range(index, entries, { lower, upper, })
    }
  }
  try index.page(0UL, -1) catch {
    InvalidArgument(_) => ()
    _ => fail("unexpected negative-page error")
  } noraise {
    _ => fail("negative page limit accepted")
  }
}

///|
test "index seeded byte dictionaries agree with an independently sorted reference" {
  let mut seed = 0x1771a23bU
  for dataset = 0; dataset < 24; dataset = dataset + 1 {
    let original = [Entry::{ key: b"", value: 0xffffffffffffffffUL, }]
    let distinct : Map[Bytes, UInt64] = Map([(b"", 0xffffffffffffffffUL)])
    for row = 0; row < 80; row = row + 1 {
      seed = seed * 1664525U + 1013904223U
      let size = (seed >> 24).reinterpret_as_int() % 9
      let bytes = []
      for _byte = 0; _byte < size; _byte = _byte + 1 {
        seed = seed * 1664525U + 1013904223U
        bytes.push((seed >> 24).to_byte())
      }
      let key = Bytes::from_array(bytes)
      seed = seed * 1664525U + 1013904223U
      let high = seed.to_uint64()
      seed = seed * 1664525U + 1013904223U
      let value = if row % 11 == 0 {
        0xffffffffffffffffUL
      } else {
        (high << 32) | seed.to_uint64()
      }
      original.push({ key, value, })
      distinct[key] = value
    }
    let expected = []
    for key, value in distinct {
      expected.push(Entry::{ key, value, })
    }
    expected.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
    let index = FstMap::from_entries(
        original,
        duplicates=KeepLast,
        registry_capacity=dataset % 7,
      )
      .as_fst()
      .index()
    @debug.assert_eq(index.len(), expected.length().to_uint64())
    @debug.assert_eq(index.as_fst().stream().collect(), expected)
    for i = 0; i < expected.length(); i = i + 1 {
      @debug.assert_eq(index.select(i.to_uint64()), Some(expected[i]))
      ix_assert_query(index, expected, expected[i].key)
      let key = expected[i].key
      if !key.is_empty() {
        ix_assert_query(
          index,
          expected,
          key.exact_view(end=key.length() - 1).to_owned(),
        )
      }
    }
    for _query = 0; _query < 40; _query = _query + 1 {
      seed = seed * 1664525U + 1013904223U
      let query = Bytes::from_array([
        (seed >> 24).to_byte(),
        (seed >> 8).to_byte(),
      ])
      ix_assert_query(index, expected, query)
    }
    @debug.assert_eq(index.select(expected.length().to_uint64()), None)
    @debug.assert_eq(index.select(0xffffffffffffffffUL), None)
    for bound = 0; bound < 8; bound = bound + 1 {
      seed = seed * 1664525U + 1013904223U
      let left = expected[(seed >> 16).reinterpret_as_int() % expected.length()].key
      seed = seed * 1664525U + 1013904223U
      let right = expected[(seed >> 16).reinterpret_as_int() % expected.length()].key
      ix_assert_range(index, expected, {
        lower: if (bound & 1) == 0 {
          Included(left)
        } else {
          Excluded(left)
        },
        upper: if (bound & 2) == 0 {
          Included(right)
        } else {
          Excluded(right)
        },
      })
    }
  }
}

///|
test "index long keys and Unicode helpers preserve maximum outputs" {
  let long = Bytes::makei(4096, fn(i) { if i % 2 == 0 { b'a' } else { b'b' } })
  let shorter = long.exact_view(end=4095).to_owned()
  let expected = [
    Entry::{ key: b"", value: 0xffffffffffffffffUL, },
    { key: b"a", value: 7UL, },
    { key: shorter, value: 0UL, },
    { key: long, value: 0xffffffffffffffffUL, },
    { key: b"\xff", value: 1UL, },
  ]
  let index = FstMap::from_sorted(expected).as_fst().index()
  for entry in expected {
    ix_assert_query(index, expected, entry.key)
  }
  @debug.assert_eq(index.select(3UL), Some(expected[3]))
  @debug.assert_eq(index.prefix_count(b"ab"), 2UL)
  ix_assert_range(index, expected, KeyRange::prefix(shorter))
  let unicode = FstMap::from_strings([
      ("", 1UL),
      ("α", 2UL),
      ("αβ", 3UL),
      ("猫", 0xffffffffffffffffUL),
    ])
    .as_fst()
    .index()
  @debug.assert_eq(unicode.rank_str("α"), (1UL, true))
  @debug.assert_eq(unicode.prefix_count_str("α"), 2UL)
  @debug.assert_eq(unicode.rank_str("猫"), (3UL, true))
}

///|
test "index supports a compact graph with UInt64 maximum keys without enumeration" {
  let buffer = @codec.begin(0UL)
  let mut child = @codec.write_node(buffer, false, 0UL, [])
  for _depth = 0; _depth < 64; _depth = _depth + 1 {
    child = @codec.write_node(buffer, true, 0UL, [
      { input: b'a', output: 0UL, addr: child, },
      { input: b'b', output: 0UL, addr: child, },
    ])
  }
  let index = Fst::from_bytes(
    @codec.finish(buffer, root=child, len=0xffffffffffffffffUL),
  ).index()
  let last = Bytes::makei(63, fn(_) { b'b' })
  let after = Bytes::makei(64, fn(_) { b'b' })
  @debug.assert_eq(index.len(), 0xffffffffffffffffUL)
  @debug.assert_eq(index.rank(last), (0xfffffffffffffffeUL, true))
  @debug.assert_eq(index.rank(after), (0xffffffffffffffffUL, false))
  @debug.assert_eq(
    index.select(0xfffffffffffffffeUL),
    Some(Entry::{ key: last, value: 0UL, }),
  )
  @debug.assert_eq(index.select(0xffffffffffffffffUL), None)
  @debug.assert_eq(index.upper_bound(last), None)
  @debug.assert_eq(
    index.prefix_ranks(last),
    (0xfffffffffffffffeUL, 0xffffffffffffffffUL),
  )
  @debug.assert_eq(index.range_count(KeyRange::all()), 0xffffffffffffffffUL)
  @debug.assert_eq(index.range_count(KeyRange::closed(last, last)), 1UL)
  @debug.assert_eq(index.page(0xfffffffffffffffeUL, 2), [
    Entry::{ key: last, value: 0UL, },
  ])
}

///|
fn ix_cursor_state(cursor : Cursor) -> (Bytes, Int32, Int32, UInt64, UInt64?) {
  (
    cursor.key(),
    cursor.depth(),
    cursor.address(),
    cursor.output_prefix(),
    cursor.value(),
  )
}

///|
test "cursor failed movement and seek restore complete prior position" {
  let fst = FstMap::from_strings([
    ("", 0xffffffffffffffffUL),
    ("a", 5UL),
    ("ab", 1UL),
    ("abc", 0xffffffffffffffffUL),
    ("ax", 0UL),
    ("b", 17UL),
    ("ba", 2UL),
  ]).as_fst()
  let cursor = fst.cursor()
  @debug.assert_eq(cursor.value(), Some(0xffffffffffffffffUL))
  assert_false(cursor.back())
  assert_true(cursor.advance_bytes(b"ab"))
  let state = ix_cursor_state(cursor)
  let edges = cursor.transitions()
  assert_false(cursor.advance(b'\xff'))
  @debug.assert_eq(ix_cursor_state(cursor), state)
  assert_false(cursor.advance_bytes(b"c-missing"))
  @debug.assert_eq(ix_cursor_state(cursor), state)
  @debug.assert_eq(cursor.transitions(), edges)
  assert_false(cursor.seek(b"abc-missing"))
  @debug.assert_eq(ix_cursor_state(cursor), state)
  assert_false(cursor.seek(b"missing"))
  @debug.assert_eq(ix_cursor_state(cursor), state)
  assert_true(cursor.advance_bytes(b""))
  @debug.assert_eq(ix_cursor_state(cursor), state)
  for depth in [-1, 3] {
    try cursor.truncate(depth) catch {
      InvalidArgument(_) => ()
      _ => fail("unexpected cursor truncation error")
    } noraise {
      _ => fail("invalid cursor depth accepted")
    }
    @debug.assert_eq(ix_cursor_state(cursor), state)
  }
  assert_true(cursor.advance(b'c'))
  @debug.assert_eq(cursor.value(), Some(0xffffffffffffffffUL))
  cursor.truncate(1)
  @debug.assert_eq(cursor.key(), b"a")
  @debug.assert_eq(cursor.value(), Some(5UL))
  assert_true(cursor.back())
  @debug.assert_eq(cursor.key(), b"")
  assert_false(cursor.back())
}

///|
test "cursor forks and returned key and transition snapshots are independent" {
  let map = FstMap::from_strings([
    ("a", 5UL),
    ("abc", 0xffffffffffffffffUL),
    ("ax", 0UL),
    ("b", 17UL),
  ])
  let fst = map.as_fst()
  let cursor = fst.cursor()
  assert_true(cursor.seek(b"a"))
  let original = ix_cursor_state(cursor)
  let fork = cursor.fork()
  let key_snapshot = cursor.key()
  let snapshot = cursor.transitions()
  let original_edges = snapshot.copy()
  assert_true(snapshot.length() > 0)
  snapshot[0] = { input: b'\xff', output: 0xffffffffffffffffUL, addr: 1, }
  snapshot.clear()
  @debug.assert_eq(cursor.transitions(), original_edges)
  @debug.assert_eq(fork.transitions(), original_edges)
  assert_true(fork.seek(b"b"))
  @debug.assert_eq(fork.value(), Some(17UL))
  @debug.assert_eq(ix_cursor_state(cursor), original)
  assert_true(cursor.advance_bytes(b"bc"))
  @debug.assert_eq(cursor.key(), b"abc")
  @debug.assert_eq(cursor.value(), Some(0xffffffffffffffffUL))
  @debug.assert_eq(fork.key(), b"b")
  @debug.assert_eq(key_snapshot, b"a")
  @debug.assert_eq(map.get(b"abc"), Some(0xffffffffffffffffUL))
  cursor.reset()
  @debug.assert_eq(cursor.depth(), 0)
  @debug.assert_eq(cursor.value(), None)
  @debug.assert_eq(fork.key(), b"b")
}

///|
test "cursor accepts nonfinal paths and completions preserve absolute keys and values" {
  let map = FstMap::from_strings([
    ("abc", 0xffffffffffffffffUL),
    ("abd", 0UL),
    ("axy", 7UL),
    ("b", 4UL),
  ])
  let cursor = map.as_fst().cursor()
  assert_true(cursor.seek(b"ab"))
  @debug.assert_eq(cursor.value(), None)
  let original = ix_cursor_state(cursor)
  @debug.assert_eq(cursor.completions().collect(), [
    Entry::{ key: b"abc", value: 0xffffffffffffffffUL, },
    { key: b"abd", value: 0UL, },
  ])
  @debug.assert_eq(ix_cursor_state(cursor), original)
  assert_true(cursor.advance(b'c'))
  @debug.assert_eq(cursor.value(), Some(0xffffffffffffffffUL))
  @debug.assert_eq(cursor.completions().collect(), [
    Entry::{ key: b"abc", value: 0xffffffffffffffffUL, },
  ])
  @debug.assert_eq(cursor.transitions(), [])
}

///|
test "cursor empty dictionary and long binary path" {
  let empty = FstSet::from_keys([]).as_fst().cursor()
  @debug.assert_eq(empty.value(), None)
  @debug.assert_eq(empty.transitions(), [])
  assert_false(empty.seek(b"x"))
  @debug.assert_eq(empty.key(), b"")
  let key = Bytes::makei(4096, fn(i) { (i % 256).to_byte() })
  let cursor = FstMap::from_sorted([
      Entry::{ key, value: 0xffffffffffffffffUL, },
    ])
    .as_fst()
    .cursor()
  assert_true(cursor.seek(key))
  @debug.assert_eq(cursor.value(), Some(0xffffffffffffffffUL))
  @debug.assert_eq(cursor.depth(), 4096)
  let at_end = ix_cursor_state(cursor)
  assert_false(cursor.advance_bytes(b"\xff"))
  @debug.assert_eq(ix_cursor_state(cursor), at_end)
  cursor.truncate(4000)
  let fork = cursor.fork()
  assert_true(cursor.advance_bytes(key.exact_view(start=4000).to_owned()))
  @debug.assert_eq(cursor.value(), Some(0xffffffffffffffffUL))
  @debug.assert_eq(fork.depth(), 4000)
  @debug.assert_eq(fork.value(), None)
}
