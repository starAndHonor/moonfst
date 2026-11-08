///|
fn sx_rank(entries : Array[Entry], key : Bytes) -> Int32 {
  let mut position = 0
  while position < entries.length() &&
        entries[position].key.lexical_compare(key) < 0 {
    position = position + 1
  }
  position
}

///|
fn sx_starts(key : Bytes, prefix : Bytes) -> Bool {
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
fn sx_filter(entries : Array[Entry], range : KeyRange) -> Array[Entry] {
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
fn sx_assert(
  index : FstIndex,
  matcher : &@automaton.Automaton,
  entries : Array[Entry],
) -> Unit raise {
  // A plain sorted array and direct whole-key execution are independent of
  // product graph suffix counts and the index's order-statistic traversal.
  let expected = entries.filter(fn(entry) {
    @automaton.accepts(matcher, entry.key)
  })
  let product = index.search_index(matcher)
  let cached = product.cached_states()
  @debug.assert_eq(product.len(), expected.length().to_uint64())
  @debug.assert_eq(product.is_empty(), expected.is_empty())
  @debug.assert_eq(index.as_fst().search(matcher).collect(), expected)
  @debug.assert_eq(product.stream().collect(), expected)
  for i = 0; i < expected.length(); i = i + 1 {
    @debug.assert_eq(product.select(i.to_uint64()), Some(expected[i]))
  }
  @debug.assert_eq(product.select(expected.length().to_uint64()), None)
  @debug.assert_eq(product.select(0xffffffffffffffffUL), None)
  let queries = entries.map(fn(entry) { entry.key })
  queries.append([
    b"", b"\x00", b"a", b"ab", b"az", b"none", b"\xff", b"\xff\xff",
  ])
  for query in queries {
    let rank = sx_rank(expected, query)
    let found = rank < expected.length() && expected[rank].key == query
    @debug.assert_eq(product.rank(query), (rank.to_uint64(), found))
    @debug.assert_eq(
      product.prefix_count(query),
      expected.count_if(fn(entry) { sx_starts(entry.key, query) }).to_uint64(),
    )
  }
  let ranges = [
    KeyRange::all(),
    KeyRange::closed(b"", b""),
    KeyRange::between(b"", b""),
    KeyRange::prefix(b"a"),
    KeyRange::prefix(b"\xff"),
    { lower: Excluded(b"a"), upper: Included(b"b"), },
    { lower: Included(b"a"), upper: Excluded(b"b"), },
    { lower: Excluded(b"a"), upper: Excluded(b"b"), },
    { lower: Included(b"b"), upper: Included(b"a"), },
    { lower: Excluded(b"\xff"), upper: Unbounded, },
  ]
  for range in ranges {
    let filtered = sx_filter(expected, range)
    @debug.assert_eq(product.range_count(range), filtered.length().to_uint64())
    @debug.assert_eq(product.stream(range~).collect(), filtered)
    let (lower, upper) = product.range_ranks(range)
    @debug.assert_eq(upper - lower, filtered.length().to_uint64())
    for offset in [0, 1, filtered.length(), filtered.length() + 1] {
      for limit in [0, 1, 4] {
        let page = []
        let mut cursor = offset
        while cursor < filtered.length() && page.length() < limit {
          page.push(filtered[cursor])
          cursor = cursor + 1
        }
        @debug.assert_eq(product.page(offset.to_uint64(), limit, range~), page)
      }
    }
    @debug.assert_eq(product.page(0xffffffffffffffffUL, 4, range~), [])
  }
  // Repeated traversals and pages must never consume a reusable index.
  @debug.assert_eq(
    product.stream().take(2),
    expected.exact_view(end=Int32::min(2, expected.length())).to_owned(),
  )
  @debug.assert_eq(product.stream().collect(), expected)
  @debug.assert_eq(product.cached_states(), cached)
}

///|
test "search index built-in predicates agree with direct execution and streams" {
  let keys = [
    b"", b"a", b"ab", b"abc", b"abb", b"ax", b"b", b"ba", b"xabc", b"\x00", b"\xff",
    b"\xff\x00",
  ]
  let original = keys.mapi(fn(i, key) {
    Entry::{
      key,
      value: if i % 3 == 0 {
        0xffffffffffffffffUL
      } else {
        i.to_uint64()
      },
    }
  })
  let map = FstMap::from_entries(original)
  let entries = original.copy()
  entries.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
  let index = map.as_fst().index()
  let matchers = [
    @automaton.always(),
    @automaton.never(),
    @automaton.exact(""),
    @automaton.exact("ab"),
    @automaton.exact_bytes(b"\xff"),
    @automaton.prefix("a"),
    @automaton.prefix_bytes(b"\xff"),
    @automaton.subsequence("ab"),
    @automaton.byte_length(1, maximum=2),
    @automaton.byte_length(2),
    @automaton.complement(@automaton.exact("ab")),
    @automaton.complement(@automaton.prefix("a")),
    @automaton.union(@automaton.prefix("a"), @automaton.prefix("b")),
    @automaton.intersection(@automaton.prefix("a"), @automaton.byte_length(2)),
    @automaton.starts_with(@automaton.exact("a")),
  ]
  for matcher in matchers {
    sx_assert(index, matcher, entries)
  }
}

///|
test "search index empty FST and empty-key maximum output" {
  let empty = FstSet::from_keys([]).as_fst().index()
  for matcher in [@automaton.always(), @automaton.never(), @automaton.exact("")] {
    sx_assert(empty, matcher, [])
  }
  let entries = [Entry::{ key: b"", value: 0xffffffffffffffffUL, }]
  let index = FstMap::from_sorted(entries).as_fst().index()
  for
    matcher in [
      @automaton.always(),
      @automaton.never(),
      @automaton.exact(""),
      @automaton.exact("a"),
      @automaton.complement(@automaton.exact("")),
    ] {
    sx_assert(index, matcher, entries)
  }
}

///|
test "search index product state limits and shortcut resource use" {
  let index = FstSet::from_strings(["a", "ab", "abb", "b"]).as_fst().index()
  @debug.assert_eq(
    index.search_index(@automaton.always(), max_states=1).cached_states(),
    1,
  )
  let never = index.search_index(@automaton.never(), max_states=1)
  @debug.assert_eq(never.cached_states(), 0)
  @debug.assert_eq(never.len(), 0UL)
  let matcher = @automaton.exact("abb")
  let needed = index.search_index(matcher).cached_states()
  assert_true(needed > 1)
  @debug.assert_eq(index.search_index(matcher, max_states=needed).len(), 1UL)
  try index.search_index(matcher, max_states=needed - 1) catch {
    ResourceLimit(_) => ()
    _ => fail("unexpected product state limit error")
  } noraise {
    _ => fail("product state budget exceeded without an error")
  }
  for budget in [0, -1] {
    try index.search_index(matcher, max_states=budget) catch {
      InvalidArgument(_) => ()
      _ => fail("unexpected invalid product budget error")
    } noraise {
      _ => fail("nonpositive product state budget accepted")
    }
  }
  let valid = index.search_index(matcher)
  @debug.assert_eq(valid.stream().keys(), [b"abb"])
  try valid.page(0UL, -1) catch {
    InvalidArgument(_) => ()
    _ => fail("unexpected negative product page error")
  } noraise {
    _ => fail("negative product page size accepted")
  }
}

///|
priv struct SxConservativeUniversal {
  nested : Bool
}

///|
impl @automaton.Automaton for SxConservativeUniversal with fn start(_) {
  0
}

///|
impl @automaton.Automaton for SxConservativeUniversal with fn accept(
  self,
  state,
  byte,
) {
  if state < 0 {
    return -1
  }
  if !self.nested {
    return 1
  }
  if state == 0 {
    if byte == b'a' {
      1
    } else {
      -1
    }
  } else {
    2
  }
}

///|
impl @automaton.Automaton for SxConservativeUniversal with fn is_match(
  self,
  state,
) {
  state >= 0 && (!self.nested || state != 0)
}

///|
impl @automaton.Automaton for SxConservativeUniversal with fn can_match(
  _,
  state,
) {
  state >= 0
}

///|
impl @automaton.Automaton for SxConservativeUniversal with fn will_always_match(
  self,
  state,
) {
  // All descendants also accept universally, but returning false is a valid
  // conservative answer. The parent promise must survive this loss of proof.
  state == (if self.nested { 1 } else { 0 })
}

///|
impl @automaton.Automaton for SxConservativeUniversal with fn accept_eof(_, _) {
  None
}

///|
test "universal shortcut promise survives conservative descendant states" {
  let entries = [
    Entry::{ key: b"", value: 7UL, },
    { key: b"a", value: 11UL, },
    { key: b"ab", value: 0xffffffffffffffffUL, },
    { key: b"abc", value: 0UL, },
    { key: b"ax", value: 2UL, },
    { key: b"b", value: 17UL, },
  ]
  let index = FstMap::from_sorted(entries).as_fst().index()
  for nested in [false, true] {
    sx_assert(index, SxConservativeUniversal::{ nested, }, entries)
  }
  let root_shortcut = index.search_index(
    SxConservativeUniversal::{ nested: false, },
    max_states=1,
  )
  @debug.assert_eq(root_shortcut.len(), entries.length().to_uint64())
  @debug.assert_eq(root_shortcut.cached_states(), 1)
  @debug.assert_eq(root_shortcut.select(2UL), Some(entries[2]))
}

///|
priv struct SxParity {}

///|
impl @automaton.Automaton for SxParity with fn start(_) {
  0
}

///|
impl @automaton.Automaton for SxParity with fn accept(_, state, byte) {
  if byte == b'a' {
    1 - state
  } else {
    state
  }
}

///|
impl @automaton.Automaton for SxParity with fn is_match(_, state) {
  state == 1
}

///|
impl @automaton.Automaton for SxParity with fn can_match(_, _) {
  true
}

///|
impl @automaton.Automaton for SxParity with fn will_always_match(_, _) {
  false
}

///|
impl @automaton.Automaton for SxParity with fn accept_eof(_, _) {
  None
}

///|
test "shared suffix nodes retain distinct automaton product states" {
  let entries = [
    Entry::{ key: b"ax", value: 0UL, },
    { key: b"ay", value: 0UL, },
    { key: b"bx", value: 0UL, },
    { key: b"by", value: 0UL, },
  ]
  let index = FstMap::from_sorted(entries).as_fst().index()
  let product = index.search_index(SxParity::{ })
  assert_true(product.cached_states() > index.cached_nodes())
  @debug.assert_eq(product.len(), 2UL)
  sx_assert(index, SxParity::{ }, entries)
}

///|
priv struct SxEof {
  empty : Bool
}

///|
impl @automaton.Automaton for SxEof with fn start(_) {
  0
}

///|
impl @automaton.Automaton for SxEof with fn accept(_, state, byte) {
  if state == 0 && byte == b'a' {
    1
  } else if state == 1 && byte == b'b' {
    1
  } else {
    -1
  }
}

///|
impl @automaton.Automaton for SxEof with fn is_match(_, state) {
  state == 2
}

///|
impl @automaton.Automaton for SxEof with fn can_match(_, state) {
  state >= 0
}

///|
impl @automaton.Automaton for SxEof with fn will_always_match(_, _) {
  false
}

///|
impl @automaton.Automaton for SxEof with fn accept_eof(self, state) {
  if state == 1 || (self.empty && state == 0) {
    Some(2)
  } else {
    None
  }
}

///|
test "custom EOF matching is checked once without contaminating descendants" {
  let entries = [
    Entry::{ key: b"", value: 0xffffffffffffffffUL, },
    { key: b"a", value: 4UL, },
    { key: b"ab", value: 7UL, },
    { key: b"abb", value: 0UL, },
    { key: b"abc", value: 17UL, },
    { key: b"b", value: 9UL, },
  ]
  let index = FstMap::from_sorted(entries).as_fst().index()
  for empty in [false, true] {
    sx_assert(index, SxEof::{ empty, }, entries)
  }
}

///|
test "Unicode fuzzy product indices reject malformed UTF8 and preserve UInt64 values" {
  let words = [
    "", "a", "e", "é", "ê", "éx", "é", "🙂", "🙃", "🙂é", "猫", "狗",
    "猫咪", "ma", "mañana", "manana", "mañan", "mañanas", "Mañana", "mãnana",
  ]
  let original = words.mapi(fn(i, word) {
    Entry::{
      key: string_bytes(word),
      value: if i % 3 == 0 {
        0xffffffffffffffffUL
      } else {
        i.to_uint64()
      },
    }
  })
  for
    raw in [b"\xff", b"\xc3", b"\xe2\x82", b"\xed\xa0\x80", b"\xf4\x90\x80\x80"] {
    original.push({ key: raw, value: 0UL, })
  }
  original.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
  let index = FstMap::from_sorted(original).as_fst().index()
  for
    matcher in [
      @automaton.levenshtein("", 1),
      @automaton.levenshtein("é", 0),
      @automaton.levenshtein("é", 1),
      @automaton.levenshtein("猫", 1),
      @automaton.levenshtein("🙂", 1),
      @automaton.levenshtein("mañana", 2, max_states=100000),
    ] {
    sx_assert(index, matcher, original)
    let product = index.search_index(matcher)
    for
      raw in [
        b"\xff", b"\xc3", b"\xe2\x82", b"\xed\xa0\x80", b"\xf4\x90\x80\x80",
      ] {
      assert_false(product.rank(raw).1)
    }
    // An incomplete lead-byte prefix such as C3 can be extended into valid
    // UTF-8, whereas these three prefixes can never be repaired by appending.
    for raw in [b"\xff", b"\xed\xa0\x80", b"\xf4\x90\x80\x80"] {
      @debug.assert_eq(product.prefix_count(raw), 0UL)
    }
  }
}

///|
test "product index handles long paths and inherited root universality" {
  let long = Bytes::makei(4096, fn(i) { if i % 2 == 0 { b'a' } else { b'b' } })
  let entries = [
    Entry::{ key: b"", value: 7UL, },
    { key: long, value: 0xffffffffffffffffUL, },
  ]
  let index = FstMap::from_sorted(entries).as_fst().index()
  sx_assert(index, @automaton.exact_bytes(long), entries)
  sx_assert(index, SxConservativeUniversal::{ nested: false, }, entries)
  let exact = index.search_index(@automaton.exact_bytes(long))
  @debug.assert_eq(exact.select(0UL), Some(entries[1]))
  @debug.assert_eq(exact.cached_states(), 4097)
}

///|
test "always product counts UInt64 maximum keys without expanding them" {
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
  let product = index.search_index(
    SxConservativeUniversal::{ nested: false, },
    max_states=1,
  )
  let last = Bytes::makei(63, fn(_) { b'b' })
  @debug.assert_eq(product.len(), 0xffffffffffffffffUL)
  @debug.assert_eq(product.cached_states(), 1)
  @debug.assert_eq(product.rank(last), (0xfffffffffffffffeUL, true))
  @debug.assert_eq(product.prefix_count(last), 1UL)
  @debug.assert_eq(
    product.select(0xfffffffffffffffeUL),
    Some(Entry::{ key: last, value: 0UL, }),
  )
  @debug.assert_eq(product.page(0xfffffffffffffffeUL, 2), [
    Entry::{ key: last, value: 0UL, },
  ])
}

///|
test "seeded raw-byte product graphs match sorted array predicates" {
  let alphabet = [b'\x00', b'a', b'b', b'c', b'\x7f', b'\x80', b'\xff']
  let mut seed = 0x2634fed1U
  for dataset = 0; dataset < 12; dataset = dataset + 1 {
    let original = []
    let reference : Map[Bytes, UInt64] = Map([])
    for row = 0; row < 100; row = row + 1 {
      seed = seed * 1664525U + 1013904223U
      let size = (seed >> 24).reinterpret_as_int() % 8
      let bytes = []
      for _byte = 0; _byte < size; _byte = _byte + 1 {
        seed = seed * 1664525U + 1013904223U
        bytes.push(
          alphabet[(seed >> 16).reinterpret_as_int() % alphabet.length()],
        )
      }
      let key = Bytes::from_array(bytes)
      let value = if row % 7 == 0 {
        0xffffffffffffffffUL
      } else {
        seed.to_uint64() * 4294967297UL
      }
      original.push(Entry::{ key, value, })
      reference[key] = value
    }
    let entries = []
    for key, value in reference {
      entries.push(Entry::{ key, value, })
    }
    entries.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
    let index = FstMap::from_entries(
        original,
        duplicates=KeepLast,
        registry_capacity=dataset % 5,
      )
      .as_fst()
      .index()
    for
      matcher in [
        @automaton.always(),
        @automaton.never(),
        @automaton.prefix("a"),
        @automaton.complement(@automaton.exact("ab")),
        @automaton.subsequence("ab"),
        @automaton.byte_length(2, maximum=4),
        @automaton.intersection(
          @automaton.complement(@automaton.prefix("a")),
          @automaton.subsequence("b"),
        ),
      ] {
      sx_assert(index, matcher, entries)
    }
    sx_assert(index, SxParity::{ }, entries)
    sx_assert(index, SxConservativeUniversal::{ nested: false, }, entries)
  }
}
