///|
priv struct SourceProbe {
  entries : Array[Entry]
  fail_at : Int32
  mut position : Int32
  mut calls : Int32
  mut closes : Int32
  mut closed : Bool
}

///|
fn source_probe(entries : Array[Entry], fail_at~ : Int32 = -1) -> SourceProbe {
  { entries, fail_at, position: 0, calls: 0, closes: 0, closed: false, }
}

///|
impl EntrySource for SourceProbe with fn next(self) {
  if self.closed {
    return None
  }
  let call = self.calls
  self.calls = self.calls + 1
  if call == self.fail_at {
    raise InvalidFormat("external reader failed")
  }
  if self.position == self.entries.length() {
    None
  } else {
    let entry = self.entries[self.position]
    self.position = self.position + 1
    Some(entry)
  }
}

///|
impl EntrySource for SourceProbe with fn close(self) {
  self.closes = self.closes + 1
  self.closed = true
}

///|
extend SourceProbe with EntrySource::{next, close}

///|
fn[T] source_test_error(run : () -> T raise) -> Error? {
  try {
    ignore(run())
    None
  } catch {
    error => Some(error)
  }
}

///|
fn source_test_entries() -> Array[Entry] {
  [
    Entry::{ key: b"a", value: 1UL, },
    { key: b"b", value: 2UL, },
    { key: b"c", value: 3UL, },
    { key: b"d", value: 4UL, },
    { key: b"e", value: 5UL, },
  ]
}

///|
test "ArraySource copies sorted entries and consumes arbitrary byte keys" {
  let entries = [
    Entry::{ key: b"", value: 18446744073709551615UL, },
    { key: b"\x00", value: 0UL, },
    { key: b"a", value: 42UL, },
    { key: b"\xff", value: 9UL, },
  ]
  let expected = entries.copy()
  let source = ArraySource::from_sorted(entries)
  entries[0] = { key: b"changed", value: 0UL, }
  assert_eq(source.remaining(), 4)
  @debug.assert_eq(collect_source(source), expected)
  assert_eq(source.remaining(), 0)
  @debug.assert_eq(source.next(), None)
  source.close()
  @debug.assert_eq(source.next(), None)
}

///|
test "ArraySource rejects descending or duplicate map keys and coalesces set keys" {
  let descending = source_test_error(() => {
    ArraySource::from_sorted([
      Entry::{ key: b"b", value: 1UL, },
      { key: b"a", value: 2UL, },
    ])
  })
  assert_true(descending is Some(OutOfOrder(_, _)))
  let repeated = source_test_error(() => {
    ArraySource::from_sorted([
      Entry::{ key: b"a", value: 1UL, },
      { key: b"a", value: 2UL, },
    ])
  })
  assert_true(repeated is Some(DuplicateKey(_)))
  let set = ArraySource::from_sorted_keys([
    b"", b"", b"\x00", b"a", b"a", b"\xff",
  ])
  @debug.assert_eq(collect_source(set), [
    Entry::{ key: b"", value: 0UL, },
    { key: b"\x00", value: 0UL, },
    { key: b"a", value: 0UL, },
    { key: b"\xff", value: 0UL, },
  ])
  assert_true(
    source_test_error(() => ArraySource::from_sorted_keys([b"b", b"a"]))
    is Some(OutOfOrder(_, _)),
  )
}

///|
test "filter map window and fold compose lazily while preserving keys" {
  let probe = source_probe(source_test_entries())
  let filtered = filter_source(probe, entry => entry.value % 2UL == 1UL)
  let mapped = map_source(filtered, entry => entry.value * 10UL)
  let window = window_source(mapped, 1UL, 2UL)
  assert_eq(probe.calls, 0)
  let summary = fold_source(window, (0UL, 0UL, []), (state, entry) => {
    let (count, sum, keys) = state
    keys.push(entry.key)
    (count + 1UL, sum + entry.value, keys)
  })
  @debug.assert_eq(summary, (2UL, 80UL, [b"c", b"e"]))
  assert_true(probe.closed)
  @debug.assert_eq(window.next(), None)
  window.close()
  assert_eq(probe.closes, 1)
}

///|
test "window zero limit and out of range offsets do not leak results" {
  let zero_probe = source_probe(source_test_entries())
  let zero = window_source(zero_probe, 18446744073709551615UL, 0UL)
  assert_eq(zero_probe.calls, 0)
  @debug.assert_eq(zero.next(), None)
  assert_eq(zero_probe.calls, 0)
  assert_true(zero_probe.closed)
  @debug.assert_eq(zero.next(), None)
  zero.close()
  assert_eq(zero_probe.closes, 1)
  let past_end = window_source(
    ArraySource::from_sorted(source_test_entries()),
    9UL,
    2UL,
  )
  @debug.assert_eq(collect_source(past_end), [])
  let probe = source_probe(source_test_entries())
  let one = window_source(probe, 2UL, 1UL)
  @debug.assert_eq(one.next(), Some(Entry::{ key: b"c", value: 3UL, }))
  assert_eq(probe.calls, 3)
  @debug.assert_eq(one.next(), None)
  assert_true(probe.closed)
  one.close()
  assert_eq(probe.closes, 1)
}

///|
test "source fold handles empty input and propagates callback errors" {
  let empty = ArraySource::from_sorted([])
  assert_eq(fold_source(empty, 17UL, (sum, entry) => sum + entry.value), 17UL)
  let probe = source_probe(source_test_entries())
  let error = source_test_error(() => {
    fold_source(probe, 0UL, (sum, entry) => {
      if entry.key == b"b" {
        raise InvalidArgument("fold callback failed")
      }
      sum + entry.value
    })
  })
  assert_true(error is Some(InvalidArgument(_)))
  assert_eq(probe.position, 2)
  probe.close()
}

///|
test "builder consumes application sources and FST streams without staging arrays" {
  let builder = Builder::map()
  builder.extend_source(ArraySource::from_sorted(source_test_entries()))
  let map = builder.into_map()
  @debug.assert_eq(map.entries(), source_test_entries())
  let copied = Builder::map()
  copied.extend_source(map.stream())
  assert_true(copied.into_map().same_entries(map))
  let set_builder = Builder::set()
  set_builder.extend_source(
    source_probe([
      Entry::{ key: b"a", value: 4UL, },
      { key: b"a", value: 9UL, },
      { key: b"b", value: 8UL, },
    ]),
  )
  @debug.assert_eq(set_builder.into_set().keys(), [b"a", b"b"])
}

///|
fn source_test_merge(operation : Operation) -> MergeStream raise FstError {
  let fst = FstMap::from_strings([
    ("a", 1UL),
    ("c", 3UL),
    ("e", 5UL),
    ("f", 6UL),
  ])
  let array = ArraySource::from_sorted([
    Entry::{ key: b"b", value: 20UL, },
    { key: b"c", value: 30UL, },
    { key: b"e", value: 50UL, },
    { key: b"f", value: 60UL, },
  ])
  let external = source_probe([
    Entry::{ key: b"c", value: 300UL, },
    { key: b"d", value: 400UL, },
    { key: b"e", value: 500UL, },
  ])
  merge_sources([fst.stream(), array, external], operation)
}

///|
test "merge_sources preserves source provenance across heterogeneous inputs" {
  let merged = source_test_merge(Union).collect()
  @debug.assert_eq(merged.map(entry => entry.key), [
    b"a", b"b", b"c", b"d", b"e", b"f",
  ])
  @debug.assert_eq(merged[2].values, [
    IndexedValue::{ index: 0, value: 3UL, },
    { index: 1, value: 30UL, },
    { index: 2, value: 300UL, },
  ])
  @debug.assert_eq(merged[5].values, [
    IndexedValue::{ index: 0, value: 6UL, },
    { index: 1, value: 60UL, },
  ])
  @debug.assert_eq(
    source_test_merge(Intersection).collect().map(entry => entry.key),
    [b"c", b"e"],
  )
  @debug.assert_eq(
    source_test_merge(Difference).collect().map(entry => entry.key),
    [b"a"],
  )
  @debug.assert_eq(
    source_test_merge(SymmetricDifference).collect().map(entry => entry.key),
    [b"a", b"b", b"c", b"d", b"e"],
  )
  assert_eq(source_test_merge(Union).into_map(Sum).get(b"c"), Some(333UL))
}

///|
test "merge_sources handles zero inputs and empty intersection members" {
  for operation in [Union, Intersection, Difference, SymmetricDifference] {
    @debug.assert_eq(merge_sources([], operation).next(), None)
  }
  let nonempty = ArraySource::from_sorted(source_test_entries())
  let empty = ArraySource::from_sorted([])
  assert_eq(merge_sources([nonempty, empty], Intersection).count(), 0UL)
}

///|
test "CheckedSource closes permanently after duplicate or descending external keys" {
  for
    entries in [
      [Entry::{ key: b"b", value: 1UL, }, { key: b"a", value: 2UL, }],
      [Entry::{ key: b"b", value: 1UL, }, { key: b"b", value: 2UL, }],
    ] {
    let probe = source_probe(entries)
    let checked = CheckedSource::new(probe)
    @debug.assert_eq(checked.next(), Some(entries[0]))
    let error = source_test_error(() => checked.next())
    if entries[0].key == entries[1].key {
      assert_true(error is Some(DuplicateKey(_)))
    } else {
      assert_true(error is Some(OutOfOrder(_, _)))
    }
    assert_true(probe.closed)
    let calls = probe.calls
    @debug.assert_eq(checked.next(), None)
    assert_eq(probe.calls, calls)
    checked.close()
    checked.close()
    assert_eq(probe.closes, 1)
  }
}

///|
test "CheckedSource closes on external failure and EOF without polling again" {
  let probe = source_probe(source_test_entries(), fail_at=1)
  let checked = CheckedSource::new(probe)
  assert_true(checked.next() is Some(_))
  assert_true(source_test_error(() => checked.next()) is Some(InvalidFormat(_)))
  assert_true(probe.closed)
  @debug.assert_eq(checked.next(), None)
  assert_eq(probe.calls, 2)
  checked.close()
  assert_eq(probe.closes, 1)
  let empty = source_probe([])
  let exhausted = CheckedSource::new(empty)
  @debug.assert_eq(exhausted.next(), None)
  @debug.assert_eq(exhausted.next(), None)
  assert_eq(empty.calls, 1)
  assert_true(empty.closed)
  exhausted.close()
  assert_eq(empty.closes, 1)
}

///|
test "merge_sources detects a faulty external order before yielding a corrupted group" {
  for
    bad in [
      [Entry::{ key: b"b", value: 1UL, }, { key: b"a", value: 2UL, }],
      [Entry::{ key: b"b", value: 1UL, }, { key: b"b", value: 2UL, }],
    ] {
    let probe = source_probe(bad)
    let merged = merge_sources([probe], Union)
    let error = source_test_error(() => merged.next())
    if bad[0].key == bad[1].key {
      assert_true(error is Some(DuplicateKey(_)))
    } else {
      assert_true(error is Some(OutOfOrder(_, _)))
    }
    assert_true(probe.closed)
    merged.close()
    @debug.assert_eq(merged.next(), None)
  }
  let probe = source_probe(source_test_entries(), fail_at=1)
  let merged = merge_sources([probe], Union)
  assert_true(source_test_error(() => merged.next()) is Some(InvalidFormat(_)))
  assert_true(probe.closed)
  merged.close()
}

///|
test "filter and map callbacks fail closed and close the underlying reader once" {
  let filtered_probe = source_probe(source_test_entries())
  let filtered = filter_source(filtered_probe, _ => {
    raise InvalidArgument("filter callback failed")
  })
  assert_true(
    source_test_error(() => filtered.next()) is Some(InvalidArgument(_)),
  )
  assert_true(filtered_probe.closed)
  assert_eq(filtered_probe.closes, 1)
  @debug.assert_eq(filtered.next(), None)
  filtered.close()
  filtered.close()
  assert_eq(filtered_probe.closes, 1)
  let mapped_probe = source_probe(source_test_entries())
  let mapped = map_source(mapped_probe, _ => {
    raise InvalidArgument("map callback failed")
  })
  assert_true(
    source_test_error(() => mapped.next()) is Some(InvalidArgument(_)),
  )
  assert_true(mapped_probe.closed)
  assert_eq(mapped_probe.closes, 1)
  @debug.assert_eq(mapped.next(), None)
  mapped.close()
  mapped.close()
  assert_eq(mapped_probe.closes, 1)
  @debug.assert_eq(mapped_probe.next(), None)
}

///|
test "merge_sources releases every input on constructor or iteration failure" {
  let opened = source_probe(source_test_entries())
  let failure = source_probe([], fail_at=0)
  assert_true(
    source_test_error(() => merge_sources([opened, failure], Union))
    is Some(InvalidFormat(_)),
  )
  assert_true(opened.closed)
  assert_true(failure.closed)
  assert_eq(opened.closes, 1)
  assert_eq(failure.closes, 1)
  let failing = source_probe(source_test_entries(), fail_at=1)
  let healthy = source_probe([Entry::{ key: b"z", value: 9UL, }])
  let merged = merge_sources([failing, healthy], Union)
  assert_true(source_test_error(() => merged.next()) is Some(InvalidFormat(_)))
  assert_true(failing.closed)
  assert_true(healthy.closed)
  @debug.assert_eq(merged.next(), None)
  merged.close()
  assert_eq(failing.closes, 1)
  assert_eq(healthy.closes, 1)
}

///|
test "window closes once when the external reader fails during skip or take" {
  for offset in [0UL, 2UL] {
    let probe = source_probe(source_test_entries(), fail_at=0)
    let window = window_source(probe, offset, 2UL)
    assert_true(
      source_test_error(() => window.next()) is Some(InvalidFormat(_)),
    )
    assert_true(probe.closed)
    assert_eq(probe.closes, 1)
    @debug.assert_eq(window.next(), None)
    window.close()
    assert_eq(probe.closes, 1)
  }
}

///|
fn source_assert_closed_merge(
  merged : MergeStream,
  left : SourceProbe,
  right : SourceProbe,
  expected_calls : Int32,
) -> Unit raise {
  assert_true(left.closed)
  assert_true(right.closed)
  assert_eq(left.closes, 1)
  assert_eq(right.closes, 1)
  assert_eq(left.calls, expected_calls)
  assert_eq(right.calls, expected_calls)
  @debug.assert_eq(merged.next(), None)
  merged.close()
  merged.close()
  @debug.assert_eq(merged.next(), None)
  assert_eq(left.calls, expected_calls)
  assert_eq(right.calls, expected_calls)
  assert_eq(left.closes, 1)
  assert_eq(right.closes, 1)
}

///|
test "merge into_map closes sources after overflow or duplicate reduction" {
  for overflow in [true, false] {
    let left = source_probe([
      { key: b"a", value: 18446744073709551615UL, },
      { key: b"b", value: 2UL, },
    ])
    let right = source_probe([
      { key: b"a", value: 1UL, },
      { key: b"c", value: 3UL, },
    ])
    let merged = merge_sources([left, right], Union)
    let policy = if overflow { Sum } else { Reject }
    let error = source_test_error(() => merged.into_map(policy))
    if overflow {
      assert_true(error is Some(Overflow))
    } else {
      assert_true(error is Some(DuplicateKey(_)))
    }
    // Both readers still have a buffered tail, so EOF cannot hide a missing
    // close in the materializing consumer's error path.
    source_assert_closed_merge(merged, left, right, 2)
  }
}

///|
test "merge reduce_with closes every source after a later callback failure" {
  let left = source_probe([
    { key: b"a", value: 1UL, },
    { key: b"b", value: 2UL, },
    { key: b"d", value: 4UL, },
  ])
  let right = source_probe([
    { key: b"a", value: 10UL, },
    { key: b"b", value: 20UL, },
    { key: b"e", value: 50UL, },
  ])
  let merged = merge_sources([left, right], Union)
  let mut callbacks = 0
  let error = source_test_error(() => {
    merged.reduce_with(group => {
      callbacks = callbacks + 1
      if group.key == b"b" {
        raise InvalidArgument("merge reduction callback failed")
      }
      group.reduce(Sum).value
    })
  })
  assert_true(error is Some(InvalidArgument(_)))
  assert_eq(callbacks, 2)
  source_assert_closed_merge(merged, left, right, 3)
  assert_eq(callbacks, 2)
}

///|
test "merge closes both sources when the second matching head fails on refill" {
  let left = source_probe([
    { key: b"a", value: 1UL, },
    { key: b"b", value: 2UL, },
  ])
  let right = source_probe(
    [{ key: b"a", value: 10UL, }, { key: b"c", value: 3UL, }],
    fail_at=1,
  )
  let merged = merge_sources([left, right], Union)
  assert_true(source_test_error(() => merged.next()) is Some(InvalidFormat(_)))
  // The first matching source has already advanced normally, but no group
  // may escape after refilling the second source fails.
  source_assert_closed_merge(merged, left, right, 2)
}

///|
test "merge materializing reductions preserve normal results and EOF closure" {
  for callback in [false, true] {
    let left = source_probe([
      { key: b"a", value: 2UL, },
      { key: b"c", value: 5UL, },
    ])
    let right = source_probe([
      { key: b"a", value: 7UL, },
      { key: b"b", value: 11UL, },
    ])
    let merged = merge_sources([left, right], Union)
    let result = if callback {
      merged.reduce_with(group => group.reduce(Sum).value)
    } else {
      merged.into_map(Sum)
    }
    @debug.assert_eq(result.as_fst().stream().collect(), [
      Entry::{ key: b"a", value: 9UL, },
      { key: b"b", value: 11UL, },
      { key: b"c", value: 5UL, },
    ])
    source_assert_closed_merge(merged, left, right, 3)
  }
}
