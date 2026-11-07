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
