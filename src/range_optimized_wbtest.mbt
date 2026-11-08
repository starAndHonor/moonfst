///|
/// Full-key comparisons deliberately avoid the traversal's inherited prefix
/// relations, pruning helpers, and KeyRange::contains implementation.
fn rx_reference(entries : Array[Entry], range : KeyRange) -> Array[Entry] {
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
fn rx_starts(key : Bytes, prefix : Bytes) -> Bool {
  if key.length() < prefix.length() {
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
fn rx_subsequence(key : Bytes, pattern : Bytes) -> Bool {
  let mut next = 0
  for byte in key {
    if next < pattern.length() && byte == pattern[next] {
      next = next + 1
    }
  }
  next == pattern.length()
}

///|
fn rx_predicate(kind : Int32, key : Bytes) -> Bool {
  match kind {
    0 => true
    1 => false
    2 => key.is_empty()
    3 => rx_starts(key, b"a")
    4 => !rx_starts(key, b"a")
    5 => rx_starts(key, b"\x00") || rx_starts(key, b"\xff")
    6 => rx_starts(key, b"a") && key.length() >= 2 && key.length() <= 4
    7 => rx_subsequence(key, b"\x00\xff")
    8 => key.length() >= 1 && key.length() <= 3
    _ => key == b"ab"
  }
}

///|
fn rx_matcher(kind : Int32) -> @automaton.Matcher raise {
  match kind {
    0 => @automaton.always()
    1 => @automaton.never()
    2 => @automaton.exact_bytes(b"")
    3 => @automaton.prefix_bytes(b"a")
    4 => @automaton.complement(@automaton.prefix_bytes(b"a"))
    5 =>
      @automaton.union(
        @automaton.prefix_bytes(b"\x00"),
        @automaton.prefix_bytes(b"\xff"),
      )
    6 =>
      @automaton.intersection(
        @automaton.prefix_bytes(b"a"),
        @automaton.byte_length(2, maximum=4),
      )
    7 => @automaton.subsequence_bytes(b"\x00\xff")
    8 => @automaton.byte_length(1, maximum=3)
    _ => @automaton.exact_bytes(b"ab")
  }
}

///|
fn rx_bounds(keys : Array[Bytes]) -> Array[Bound] {
  let bounds : Array[Bound] = [Unbounded]
  for key in keys {
    bounds.push(Included(key))
    bounds.push(Excluded(key))
  }
  bounds
}

///|
fn rx_entries(keys : Array[Bytes]) -> Array[Entry] {
  let entries = keys.mapi(fn(i, key) {
    Entry::{
      key,
      value: if i % 3 == 0 {
        0xffffffffffffffffUL
      } else {
        i.to_uint64()
      },
    }
  })
  entries.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
  entries
}

///|
fn rx_plain(fst : Fst, entries : Array[Entry], range : KeyRange) -> Unit raise {
  let expected = rx_reference(entries, range)
  let forward = fst.stream(range~)
  @debug.assert_eq(forward.collect(), expected)
  @debug.assert_eq(forward.next(), None)
  @debug.assert_eq(forward.next(), None)
  let descending = expected.copy()
  descending.rev_in_place()
  let reverse = fst.reverse(range~)
  @debug.assert_eq(reverse.collect(), descending)
  @debug.assert_eq(reverse.next(), None)
  @debug.assert_eq(reverse.next(), None)
}

///|
fn rx_search(
  fst : Fst,
  entries : Array[Entry],
  range : KeyRange,
  matcher : &@automaton.Automaton,
  predicate : (Bytes) -> Bool,
) -> Unit raise {
  let expected = rx_reference(entries, range).filter(fn(entry) {
    predicate(entry.key)
  })
  @debug.assert_eq(fst.search(matcher, range~).collect(), expected)
  let descending = expected.copy()
  descending.rev_in_place()
  @debug.assert_eq(fst.search_reverse(matcher, range~).collect(), descending)
}

///|
test "range relations exhaustive raw byte endpoint combinations agree with array filtering" {
  let entries = rx_entries([
    b"", b"\x00", b"\x00\x00", b"\x00\x01", b"\x00\xff", b"\x01", b"a", b"a\x00",
    b"aa", b"aaa", b"ab", b"ab\x00", b"ab\xff", b"ac", b"b", b"ba", b"\x7f", b"\x80",
    b"\xff", b"\xff\x00", b"\xff\xff",
  ])
  let fst = FstMap::from_sorted(entries).as_fst()
  let bounds = rx_bounds([
    b"", b"\x00", b"\x00\x00", b"\x00\x80", b"a", b"a\x00", b"aa", b"aab", b"ab",
    b"aba", b"b", b"\x80", b"\xff", b"\xff\x00", b"\xff\xff", b"\xff\xff\x00",
  ])
  for lower in bounds {
    for upper in bounds {
      rx_plain(fst, entries, { lower, upper, })
    }
  }
}

///|
test "range relations empty dictionary and empty key respect exclusive equality" {
  let bounds = rx_bounds([b"", b"\x00", b"a", b"\xff"])
  for entries in [[], [Entry::{ key: b"", value: 0xffffffffffffffffUL, }]] {
    let fst = FstMap::from_sorted(entries).as_fst()
    for lower in bounds {
      for upper in bounds {
        let range : KeyRange = { lower, upper, }
        rx_plain(fst, entries, range)
        for kind in [0, 1, 2, 4] {
          rx_search(fst, entries, range, rx_matcher(kind), fn(key) {
            rx_predicate(kind, key)
          })
        }
      }
    }
  }
}

///|
test "range relations compose with pruning complement and prefix automata in either direction" {
  let entries = rx_entries([
    b"", b"a", b"a\x00", b"a\x00\xff", b"aa", b"ab", b"aba", b"abb", b"abbbb", b"ac",
    b"b", b"ba", b"\x00", b"\x00\xff", b"\x00x\xff", b"\xff", b"\xff\x00",
  ])
  let fst = FstMap::from_sorted(entries, registry_capacity=1).as_fst()
  let bounds = rx_bounds([
    b"", b"\x00", b"a", b"ab", b"ac", b"\xff", b"\xff\xff",
  ])
  for kind = 0; kind < 10; kind = kind + 1 {
    let matcher = rx_matcher(kind)
    for lower in bounds {
      for upper in bounds {
        rx_search(fst, entries, { lower, upper, }, matcher, fn(key) {
          rx_predicate(kind, key)
        })
      }
    }
  }
}

///|
priv struct RxEofEven {}

///|
impl @automaton.Automaton for RxEofEven with fn start(_) {
  0
}

///|
impl @automaton.Automaton for RxEofEven with fn accept(_, state, _) {
  1 - state
}

///|
impl @automaton.Automaton for RxEofEven with fn is_match(_, state) {
  state == 2
}

///|
impl @automaton.Automaton for RxEofEven with fn can_match(_, _) {
  true
}

///|
impl @automaton.Automaton for RxEofEven with fn will_always_match(_, _) {
  false
}

///|
impl @automaton.Automaton for RxEofEven with fn accept_eof(_, state) {
  Some(if state == 0 { 2 } else { 3 })
}

///|
test "range relations check terminal ordering together with custom EOF acceptance" {
  let entries = rx_entries([
    b"", b"a", b"aa", b"aaa", b"aab", b"ab", b"b", b"ba", b"baa",
  ])
  let fst = FstMap::from_sorted(entries).as_fst()
  let bounds = rx_bounds([b"", b"a", b"aa", b"aaa", b"ab", b"b", b"ba"])
  for lower in bounds {
    for upper in bounds {
      rx_search(fst, entries, { lower, upper, }, RxEofEven::{ }, fn(key) {
        key.length() % 2 == 0
      })
    }
  }
}

///|
fn rx_join(prefix : Bytes, suffix : Bytes) -> Bytes {
  let buffer = prefix.to_array()
  for byte in suffix {
    buffer.push(byte)
  }
  Bytes::from_array(buffer)
}

///|
test "range relations preserve long undecided prefixes and reset after sibling backtracking" {
  let prefix = Bytes::makei(1024, fn(_) { b'a' })
  let before = prefix.exact_view(end=1023).to_owned()
  let zero = rx_join(prefix, b"\x00")
  let zero_zero = rx_join(prefix, b"\x00\x00")
  let zero_ff = rx_join(prefix, b"\x00\xff")
  let one = rx_join(prefix, b"\x01")
  let ff = rx_join(prefix, b"\xff")
  let missing = rx_join(prefix, b"\x00\x80")
  let entries = rx_entries([
    b"", before, prefix, zero, zero_zero, zero_ff, one, ff, b"b", b"\xff",
  ])
  let fst = FstMap::from_sorted(entries).as_fst()
  let ranges = [
    KeyRange::all(),
    KeyRange::closed(prefix, prefix),
    KeyRange::between(prefix, prefix),
    KeyRange::between(before, prefix),
    KeyRange::closed(before, zero_zero),
    { lower: Excluded(prefix), upper: Included(ff), },
    { lower: Included(prefix), upper: Excluded(ff), },
    { lower: Excluded(zero), upper: Included(zero_ff), },
    { lower: Included(missing), upper: Excluded(one), },
    { lower: Excluded(ff), upper: Unbounded, },
    { lower: Unbounded, upper: Excluded(before), },
    { lower: Included(ff), upper: Included(before), },
  ]
  for range in ranges {
    rx_plain(fst, entries, range)
    rx_search(fst, entries, range, @automaton.prefix_bytes(before), fn(key) {
      rx_starts(key, before)
    })
    rx_search(
      fst,
      entries,
      range,
      @automaton.complement(@automaton.exact_bytes(zero)),
      fn(key) { key != zero },
    )
  }
}

///|
test "range relations handle indexed byte fanout and all FF prefix boundaries" {
  let entries = [Entry::{ key: b"", value: 7UL, }]
  for input = 0; input < 256; input = input + 1 {
    let key = Bytes::from_array([input.to_byte()])
    entries.push({ key, value: input.to_uint64(), })
    entries.push({ key: rx_join(key, b"\x00"), value: 0xffffffffffffffffUL, })
    entries.push({ key: rx_join(key, b"\xff"), value: 0UL, })
  }
  entries.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
  let fst = FstMap::from_sorted(entries).as_fst()
  let bounds = rx_bounds([
    b"", b"\x00", b"\x00\xff", b"\x01", b"\x80", b"\xff", b"\xff\xff",
  ])
  for lower in bounds {
    for upper in bounds {
      rx_plain(fst, entries, { lower, upper, })
    }
  }
}

///|
test "range relations survive interleaved cursors and partial consumption" {
  let entries = rx_entries([
    b"", b"a", b"aa", b"ab", b"aba", b"abb", b"b", b"ba", b"bb", b"\xff",
  ])
  let fst = FstMap::from_sorted(entries).as_fst()
  for
    range in [
      KeyRange::all(),
      KeyRange::closed(b"a", b"b"),
      { lower: Excluded(b"a"), upper: Excluded(b"b"), },
      { lower: Included(b"aba"), upper: Unbounded, },
    ] {
    let expected = rx_reference(entries, range)
    let descending = expected.copy()
    descending.rev_in_place()
    let forward = fst.stream(range~)
    let reverse = fst.reverse(range~)
    @debug.assert_eq(forward.take(0), [])
    @debug.assert_eq(reverse.take(0), [])
    for i = 0; i < expected.length(); i = i + 1 {
      @debug.assert_eq(forward.take(1), [expected[i]])
      @debug.assert_eq(reverse.next(), Some(descending[i]))
    }
    @debug.assert_eq(forward.next(), None)
    @debug.assert_eq(reverse.next(), None)
    rx_plain(fst, entries, range)
    let skipped = fst.stream(range~)
    let skip = Int32::min(2, expected.length())
    @debug.assert_eq(skipped.skip(2), skip)
    @debug.assert_eq(
      skipped.collect(),
      expected.exact_view(start=skip).to_owned(),
    )
  }
}

///|
test "range relations seeded dictionaries and mixed endpoint queries match array truth" {
  let mut seed = 0x8294c33dU
  for dataset = 0; dataset < 10; dataset = dataset + 1 {
    let entries : Array[Entry] = []
    for row = 0; row < 48; row = row + 1 {
      seed = seed * 1664525U + 1013904223U
      let length = (seed >> 24).reinterpret_as_int() % 7
      let bytes = []
      for _i = 0; _i < length; _i = _i + 1 {
        seed = seed * 1664525U + 1013904223U
        bytes.push(
          if dataset % 2 == 0 {
            (seed >> 24).to_byte()
          } else {
            (seed >> 24).to_byte() & b'\x03'
          },
        )
      }
      let key = Bytes::from_array(bytes)
      if !entries.any(fn(entry) { entry.key == key }) {
        entries.push({
          key,
          value: if row % 5 == 0 {
            0xffffffffffffffffUL
          } else {
            row.to_uint64()
          },
        })
      }
    }
    entries.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
    let fst = FstMap::from_sorted(entries, registry_capacity=dataset % 4).as_fst()
    let points = [b"", b"\x00", b"\x01", b"a", b"\xff"]
    for entry in entries {
      points.push(entry.key)
    }
    for query = 0; query < 64; query = query + 1 {
      seed = seed * 1664525U + 1013904223U
      let lower_key = points[(seed >> 16).reinterpret_as_int() % points.length()]
      seed = seed * 1664525U + 1013904223U
      let upper_key = points[(seed >> 16).reinterpret_as_int() % points.length()]
      let range : KeyRange = {
        lower: if query % 7 == 0 {
          Unbounded
        } else if query % 2 == 0 {
          Included(lower_key)
        } else {
          Excluded(lower_key)
        },
        upper: if query % 11 == 0 {
          Unbounded
        } else if query % 3 == 0 {
          Included(upper_key)
        } else {
          Excluded(upper_key)
        },
      }
      rx_plain(fst, entries, range)
      let kind = query % 10
      rx_search(fst, entries, range, rx_matcher(kind), fn(key) {
        rx_predicate(kind, key)
      })
    }
  }
}

///|
test "stream advance mixed consumers preserve current values and owned results" {
  let entries = [
    Entry::{ key: b"", value: 0xffffffffffffffffUL, },
    { key: b"a", value: 0UL, },
    { key: b"aa", value: 0xfffffffffffffffeUL, },
    { key: b"ab", value: 7UL, },
    { key: b"b", value: 0xffffffffffffffffUL, },
    { key: b"ba", value: 19UL, },
    { key: b"bb", value: 0UL, },
    { key: b"c", value: 256UL, },
  ]
  let fst = FstMap::from_sorted(entries).as_fst()
  let stream = fst.stream()
  @debug.assert_eq(stream.take(0), [])
  @debug.assert_eq(stream.skip(0), 0)
  let first = stream.next()
  @debug.assert_eq(first, Some(entries[0]))
  let held = stream.take(2)
  @debug.assert_eq(held, [entries[1], entries[2]])
  @debug.assert_eq(stream.skip(1), 1)
  @debug.assert_eq(stream.next(), Some(entries[4]))
  @debug.assert_eq(stream.count(), 3UL)
  @debug.assert_eq(stream.count(), 0UL)
  @debug.assert_eq(stream.next(), None)
  @debug.assert_eq(stream.keys(), [])
  stream.close()
  @debug.assert_eq(first, Some(entries[0]))
  @debug.assert_eq(held, [entries[1], entries[2]])

  let key_stream = fst.stream()
  @debug.assert_eq(key_stream.take(1), [entries[0]])
  @debug.assert_eq(key_stream.skip(1), 1)
  let held_keys = key_stream.keys()
  @debug.assert_eq(held_keys, [b"aa", b"ab", b"b", b"ba", b"bb", b"c"])
  key_stream.close()
  @debug.assert_eq(held_keys, [b"aa", b"ab", b"b", b"ba", b"bb", b"c"])

  let strings = fst.stream()
  @debug.assert_eq(strings.skip(3), 3)
  @debug.assert_eq(strings.strings(), ["ab", "b", "ba", "bb", "c"])
  @debug.assert_eq(strings.next(), None)
  let pairs = fst.stream()
  @debug.assert_eq(pairs.take(2), [entries[0], entries[1]])
  @debug.assert_eq(pairs.string_entries(), [
    ("aa", 0xfffffffffffffffeUL),
    ("ab", 7UL),
    ("b", 0xffffffffffffffffUL),
    ("ba", 19UL),
    ("bb", 0UL),
    ("c", 256UL),
  ])
  @debug.assert_eq(pairs.count(), 0UL)

  let reverse = fst.reverse()
  @debug.assert_eq(reverse.take(0), [])
  @debug.assert_eq(reverse.skip(0), 0)
  @debug.assert_eq(reverse.next(), Some(entries[7]))
  @debug.assert_eq(reverse.skip(1), 1)
  @debug.assert_eq(reverse.next(), Some(entries[5]))
  let held_reverse = reverse.take(2)
  @debug.assert_eq(held_reverse, [entries[4], entries[3]])
  @debug.assert_eq(reverse.count(), 3UL)
  @debug.assert_eq(reverse.next(), None)
  reverse.close()
  @debug.assert_eq(held_reverse, [entries[4], entries[3]])
}

///|
test "stream advance close EOF and invalid counts never expose stale current entries" {
  let entries = rx_entries([b"", b"a", b"aa", b"b"])
  let fst = FstMap::from_sorted(entries).as_fst()
  for phase = 0; phase < 3; phase = phase + 1 {
    let stream = fst.stream()
    if phase >= 1 {
      @debug.assert_eq(stream.next(), Some(entries[0]))
    }
    if phase == 2 {
      @debug.assert_eq(stream.count(), 3UL)
    }
    stream.close()
    stream.close()
    @debug.assert_eq(stream.take(0), [])
    @debug.assert_eq(stream.take(2), [])
    @debug.assert_eq(stream.skip(0), 0)
    @debug.assert_eq(stream.skip(2), 0)
    @debug.assert_eq(stream.count(), 0UL)
    @debug.assert_eq(stream.keys(), [])
    @debug.assert_eq(stream.strings(), [])
    @debug.assert_eq(stream.string_entries(), [])
    @debug.assert_eq(stream.collect(), [])
    @debug.assert_eq(stream.next(), None)
  }
  let reverse = fst.reverse()
  @debug.assert_eq(reverse.next(), Some(entries[3]))
  reverse.close()
  reverse.close()
  @debug.assert_eq(reverse.take(0), [])
  @debug.assert_eq(reverse.skip(10), 0)
  @debug.assert_eq(reverse.count(), 0UL)
  @debug.assert_eq(reverse.keys(), [])
  @debug.assert_eq(reverse.strings(), [])
  @debug.assert_eq(reverse.collect(), [])
  @debug.assert_eq(reverse.next(), None)

  let checked_stream = fst.stream()
  @debug.assert_eq(checked_stream.next(), Some(entries[0]))
  try checked_stream.take(-1) catch {
    InvalidArgument(_) => ()
    _ => fail("unexpected negative take error")
  } noraise {
    _ => fail("negative take accepted")
  }
  try checked_stream.skip(-1) catch {
    InvalidArgument(_) => ()
    _ => fail("unexpected negative skip error")
  } noraise {
    _ => fail("negative skip accepted")
  }
  @debug.assert_eq(checked_stream.next(), Some(entries[1]))
  @debug.assert_eq(checked_stream.count(), 2UL)
  for matcher in [@automaton.never(), @automaton.exact_bytes(b"absent")] {
    let empty = fst.search(matcher)
    @debug.assert_eq(empty.take(0), [])
    @debug.assert_eq(empty.skip(0), 0)
    @debug.assert_eq(empty.count(), 0UL)
    @debug.assert_eq(empty.next(), None)
  }
}

///|
test "stream advance mixed EOF filtered consumers retain immutable key snapshots" {
  let entries = rx_entries([
    b"", b"a", b"aa", b"aaa", b"aab", b"ab", b"b", b"ba", b"baa",
  ])
  let fst = FstMap::from_sorted(entries).as_fst()
  let range : KeyRange = { lower: Excluded(b"a"), upper: Included(b"ba"), }
  let expected = rx_reference(entries, range).filter(fn(entry) {
    entry.key.length() % 2 == 0
  })
  @debug.assert_eq(expected.map(fn(entry) { entry.key }), [b"aa", b"ab", b"ba"])
  let stream = fst.search(RxEofEven::{ }, range~)
  @debug.assert_eq(stream.take(0), [])
  @debug.assert_eq(stream.skip(0), 0)
  let first = stream.next()
  @debug.assert_eq(first, Some(expected[0]))
  @debug.assert_eq(stream.skip(1), 1)
  let last = stream.take(2)
  @debug.assert_eq(last, [expected[2]])
  @debug.assert_eq(stream.count(), 0UL)
  @debug.assert_eq(stream.next(), None)
  stream.close()
  @debug.assert_eq(first, Some(expected[0]))
  @debug.assert_eq(last, [expected[2]])

  let keys_stream = fst.search(RxEofEven::{ }, range~)
  let held_keys = keys_stream.keys()
  @debug.assert_eq(held_keys, [b"aa", b"ab", b"ba"])
  keys_stream.close()
  let other = fst.stream()
  @debug.assert_eq(other.skip(100), entries.length())
  @debug.assert_eq(held_keys, [b"aa", b"ab", b"ba"])
  let reverse = fst.search_reverse(RxEofEven::{ }, range~)
  @debug.assert_eq(reverse.take(0), [])
  @debug.assert_eq(reverse.skip(0), 0)
  @debug.assert_eq(reverse.next(), Some(expected[2]))
  @debug.assert_eq(reverse.count(), 2UL)
  @debug.assert_eq(reverse.next(), None)
}

///|
test "stream advance string decoding failure consumes only the failed record" {
  let entries = [
    Entry::{ key: b"a", value: 7UL, },
    { key: b"\xc0", value: 0xffffffffffffffffUL, },
    { key: b"\xc0\x80", value: 0UL, },
    { key: b"\xff", value: 19UL, },
  ]
  let fst = FstMap::from_sorted(entries).as_fst()
  let strings = fst.stream()
  let held = strings.next()
  @debug.assert_eq(held, Some(entries[0]))
  try strings.strings() catch {
    InvalidUtf8 => ()
    _ => fail("unexpected string decoding error")
  } noraise {
    _ => fail("invalid UTF-8 accepted")
  }
  @debug.assert_eq(strings.next(), Some(entries[2]))
  @debug.assert_eq(strings.next(), Some(entries[3]))
  @debug.assert_eq(strings.next(), None)
  strings.close()
  @debug.assert_eq(held, Some(entries[0]))

  let pairs = fst.stream()
  @debug.assert_eq(pairs.take(1), [entries[0]])
  try pairs.string_entries() catch {
    InvalidUtf8 => ()
    _ => fail("unexpected string-entry decoding error")
  } noraise {
    _ => fail("invalid UTF-8 string entry accepted")
  }
  @debug.assert_eq(pairs.next(), Some(entries[2]))
  @debug.assert_eq(pairs.count(), 1UL)
  @debug.assert_eq(pairs.next(), None)
}
