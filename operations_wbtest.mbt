///|
/// Materialized reference independent of heap ordering and root replacement.
fn operations_reference(
  inputs : Array[Array[Entry]],
  operation : Operation,
) -> Array[MergedEntry] {
  let keys : Array[Bytes] = []
  for entries in inputs {
    for entry in entries {
      keys.push(entry.key)
    }
  }
  keys.sort_by((left, right) => left.lexical_compare(right))
  let result = []
  let mut previous : Bytes? = None
  for key in keys {
    if previous is Some(before) && before == key {
      continue
    }
    previous = Some(key)
    let values : Array[IndexedValue] = []
    for source = 0; source < inputs.length(); source = source + 1 {
      for entry in inputs[source] {
        if entry.key == key {
          values.push({ index: source, value: entry.value, })
          break
        }
      }
    }
    let keep = match operation {
      Union => true
      Intersection => values.length() == inputs.length()
      Difference => values.length() == 1 && values[0].index == 0
      SymmetricDifference => values.length() % 2 == 1
    }
    if keep {
      result.push({ key, values, })
    }
  }
  result
}

///|
test "root replacement merge matches independent reference across source counts" {
  let mut seed = 3197783U
  for count in [0, 1, 2, 3, 5, 8] {
    for round = 0; round < 4; round = round + 1 {
      let inputs : Array[Array[Entry]] = []
      for source = 0; source < count; source = source + 1 {
        let entries : Array[Entry] = []
        if source % 3 == 0 {
          entries.push({ key: b"", value: 18446744073709551615UL, })
        }
        for ordinal = 0; ordinal < 40; ordinal = ordinal + 1 {
          seed = seed * 1664525U + 1013904223U
          if seed % 5U < 3U && (round != 0 || source != count - 1) {
            entries.push({
              key: Bytes::from_array([ordinal.to_byte(), b'\x00']),
              value: (source.to_uint64() << 48) | ordinal.to_uint64(),
            })
          }
        }
        entries.push({ key: b"\xff", value: source.to_uint64(), })
        inputs.push(entries)
      }
      for operation in [Union, Intersection, Difference, SymmetricDifference] {
        let expected = operations_reference(inputs, operation)
        let sources : Array[&EntrySource] = []
        let graphs : Array[Fst] = []
        for entries in inputs {
          sources.push(ArraySource::from_sorted(entries))
          graphs.push(FstMap::from_sorted(entries).as_fst())
        }
        @debug.assert_eq(merge_sources(sources, operation).collect(), expected)
        @debug.assert_eq(merge(graphs, operation).collect(), expected)
      }
    }
  }
}

///|
test "equal-key merge groups keep source order without sorting" {
  let sources : Array[&EntrySource] = []
  for index = 0; index < 33; index = index + 1 {
    sources.push(
      ArraySource::from_sorted([
        { key: b"\x00", value: index.to_uint64(), },
        { key: b"shared", value: (index + 100).to_uint64(), },
        { key: Bytes::from_array([b'\xff', index.to_byte()]), value: 0UL, },
      ]),
    )
  }
  let groups = merge_sources(sources, Union).collect()
  assert_eq(groups.length(), 35)
  for group_index = 0; group_index < 2; group_index = group_index + 1 {
    assert_eq(groups[group_index].values.length(), 33)
    for index = 0; index < 33; index = index + 1 {
      assert_eq(groups[group_index].values[index].index, index)
      assert_eq(
        groups[group_index].values[index].value,
        (index + group_index * 100).to_uint64(),
      )
    }
  }
}

///|
test "fresh FST merges preserve all operations across ranges and arbitrary source counts" {
  let keys = [
    b"", b"\x00", b"\x00\xff", b"a", b"aa", b"b", b"\xff", b"\xff\xff",
  ]
  let ranges : Array[KeyRange] = [
    KeyRange::all(),
    KeyRange::prefix(b"a"),
    KeyRange::prefix(b"\xff"),
    KeyRange::closed(b"", b"\x00"),
    { lower: Excluded(b"a"), upper: Included(b"\xff"), },
    { lower: Unbounded, upper: Excluded(b""), },
    KeyRange::between(b"z", b"a"),
  ]
  for count in [0, 1, 2, 3, 5, 17, 33] {
    for empty_member in [false, true] {
      let inputs : Array[Array[Entry]] = []
      let graphs : Array[Fst] = []
      for source = 0; source < count; source = source + 1 {
        let records : Array[Entry] = []
        if !empty_member || source != count / 2 {
          for ordinal = 0; ordinal < keys.length(); ordinal = ordinal + 1 {
            if ordinal == 0 || (source + ordinal) % 3 != 0 {
              records.push({
                key: keys[ordinal],
                value: if source % 3 == 0 && ordinal % 2 == 0 {
                  18446744073709551615UL
                } else {
                  (source.to_uint64() << 40) | ordinal.to_uint64()
                },
              })
            }
          }
        }
        inputs.push(records)
        graphs.push(FstMap::from_sorted(records, registry_capacity=7).as_fst())
      }
      for range in ranges {
        let filtered = inputs.map(records => {
          records.filter(entry => range.contains(entry.key))
        })
        for operation in [Union, Intersection, Difference, SymmetricDifference] {
          let expected = operations_reference(filtered, operation)
          @debug.assert_eq(merge(graphs, operation, range~).collect(), expected)
          // The public stream constructor retains the external checked path.
          // It must agree with the concrete fresh-FST path on the same range.
          let streams : Array[Stream] = []
          for graph in graphs {
            streams.push(graph.stream(range~))
          }
          @debug.assert_eq(
            MergeStream::new(streams, operation).collect(),
            expected,
          )
        }
      }
    }
  }
}

///|
test "repeated FST inputs open independent streams and preserve source priority" {
  let records : Array[Entry] = [
    { key: b"", value: 18446744073709551615UL, },
    { key: b"a", value: 0UL, },
    { key: b"ab", value: 7UL, },
    { key: b"\xff", value: 19UL, },
  ]
  let fst = FstMap::from_sorted(records, registry_capacity=1).as_fst()
  for count in [1, 2, 3, 5, 32] {
    let inputs = Array::make(count, records)
    let graphs = Array::make(count, fst)
    for operation in [Union, Intersection, Difference, SymmetricDifference] {
      let expected = operations_reference(inputs, operation)
      @debug.assert_eq(merge(graphs, operation).collect(), expected)
    }
  }
}

///|
test "fresh merge results own their keys and value groups through advance and close" {
  let records : Array[Entry] = [
    { key: b"a", value: 18446744073709551615UL, },
    { key: b"aa", value: 0UL, },
    { key: b"ab", value: 7UL, },
    { key: b"b", value: 11UL, },
  ]
  let fst = FstMap::from_sorted(records, registry_capacity=1).as_fst()
  let merged = merge([fst, fst], Union)
  let first = merged.next().unwrap()
  let second = merged.next().unwrap()
  let second_values = second.values.copy()
  first.values[0] = { index: 77, value: 42UL, }
  first.values.push({ index: 99, value: 1UL, })
  let third = merged.next().unwrap()
  merged.close()
  merged.close()
  @debug.assert_eq(merged.next(), None)
  @debug.assert_eq(merged.collect(), [])
  @debug.assert_eq([first.key, second.key, third.key], [b"a", b"aa", b"ab"])
  @debug.assert_eq(first.values[0], IndexedValue::{ index: 77, value: 42UL, })
  assert_eq(first.values.length(), 3)
  @debug.assert_eq(second.values, second_values)
  @debug.assert_eq(third.values, [
    IndexedValue::{ index: 0, value: 7UL, },
    { index: 1, value: 7UL, },
  ])
  @debug.assert_eq(fst.get(b"a"), Some(18446744073709551615UL))
  @debug.assert_eq(fst.stream().collect(), records)
}
