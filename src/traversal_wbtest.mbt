///|
fn traversal_test_compare_nodes(index : Fst) -> Unit raise {
  let pending = [index.root_address()]
  let seen : Map[Int32, Bool] = Map([])
  while pending.pop() is Some(address) {
    if seen.contains(address) {
      continue
    }
    seen[address] = true
    let decoded = read_node(index, address)
    let view = traversal_node(index, address)
    assert_eq(view.count, decoded.transitions.length())
    assert_eq(view.is_final, decoded.is_final)
    assert_eq(view.final_output, decoded.final_output)
    for position = 0; position < view.count; position = position + 1 {
      let edge = decoded.transitions[position]
      assert_eq(traversal_edge_input(index.data, view, position), edge.input)
      assert_eq(traversal_edge_output(index.data, view, position), edge.output)
      assert_eq(traversal_edge_address(index.data, view, position), edge.addr)
      pending.push(edge.addr)
    }
  }
}

///|
fn traversal_test_map(count : Int32, empty : Bool) -> FstMap raise {
  let entries : Array[Entry] = []
  if empty {
    entries.push({ key: b"", value: 18446744073709551615UL, })
  }
  let values = [
    0UL, 1UL, 255UL, 256UL, 65535UL, 65536UL, 16777216UL, 4294967296UL, 1099511627776UL,
    281474976710656UL, 72057594037927936UL, 18446744073709551615UL,
  ]
  for first = 0; first < count; first = first + 1 {
    entries.push({
      key: Bytes::from_array([first.to_byte()]),
      value: values[first % values.length()],
    })
    for second in [0, 32, 255] {
      entries.push({
        key: Bytes::from_array([first.to_byte(), second.to_byte()]),
        value: values[(first + second) % values.length()],
      })
    }
    entries.push({
      key: Bytes::from_array([first.to_byte(), b'x', b'y', b'z', b'q']),
      value: 0UL,
    })
  }
  FstMap::from_entries(entries)
}

///|
test "compressed traversal agrees with strict decoder across branch and width boundaries" {
  for count in [0, 1, 2, 31, 32, 33, 63, 64, 255, 256] {
    for empty in [false, true] {
      traversal_test_compare_nodes(traversal_test_map(count, empty).as_fst())
    }
  }
}

///|
test "compressed traversal preserves legacy v1 and indexed v2 layouts" {
  for pair in [(1, 31), (2, 256)] {
    let (version, count) = pair
    let original = traversal_test_map(count, true)
    let legacy = original.to_bytes().to_array()
    legacy.truncate(legacy.length() - 4)
    legacy[0] = version.to_byte()
    let restored = Fst::from_bytes(Bytes::from_array(legacy))
    traversal_test_compare_nodes(restored)
    assert_eq(restored.stream().collect(), original.stream().collect())
    let forward = original.stream().collect()
    forward.rev_in_place()
    assert_eq(restored.reverse().collect(), forward)
  }
}

///|
test "incremental traversal orders preserve all range bound combinations" {
  let keys = [
    b"", b"\x00", b"\x00\x00", b"\x00\xff", b"\x01", b"\x01\x00", b"\x7f", b"\xff",
    b"\xff\x00", b"\xff\xff",
  ]
  let bounds : Array[Bound] = [Unbounded]
  for key in keys {
    bounds.push(Included(key))
    bounds.push(Excluded(key))
  }
  for lower in bounds {
    for upper in bounds {
      let range : KeyRange = { lower, upper, }
      for key in keys {
        let mut lower_order = 0
        let mut upper_order = 0
        for i in 0..<key.length() {
          lower_order = lower.extend_order(lower_order, i, key[i])
          upper_order = upper.extend_order(upper_order, i, key[i])
        }
        assert_eq(
          range.contains_orders(lower_order, upper_order, key.length()),
          range.contains(key),
        )
      }
    }
  }
}
