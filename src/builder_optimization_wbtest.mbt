///|
test "bucket fingerprint never substitutes for full node equality" {
  let a = build_node(false)
  a.transitions.push({ input: b'a', output: 1UL, addr: 0, })
  let signature = node_signature(a, 7UL, [])
  let b = build_node(false)
  b.transitions.push({ input: b'a', output: 2UL, addr: 0, })
  assert_true(signature_matches(signature, a, 7UL))
  assert_true(!signature_matches(signature, b, 7UL))
  assert_true(!signature_matches(signature, a, 8UL))
  assert_true(!signature_matches(signature, { ..a, is_final: true, }, 7UL))
  assert_true(!signature_matches(signature, { ..a, final_output: 1UL, }, 7UL))
  let other_input = build_node(false)
  other_input.transitions.push({ input: b'b', output: 1UL, addr: 0, })
  assert_true(!signature_matches(signature, other_input, 7UL))
  let other_target = build_node(false)
  other_target.transitions.push({ input: b'a', output: 1UL, addr: 16, })
  assert_true(!signature_matches(signature, other_target, 7UL))
}

///|
test "two-way promotion and evicted buffers keep active slots distinct" {
  let builder = Builder::map(registry_capacity=2)
  let a = build_node(false)
  a.transitions.push({ input: b'a', output: 1UL, addr: 0, })
  let b = build_node(false)
  b.transitions.push({ input: b'b', output: 2UL, addr: 0, })
  let c = build_node(false)
  c.transitions.push({ input: b'c', output: 3UL, addr: 0, })
  let a_address = builder.compile_node(a)
  let b_address = builder.compile_node(b)
  assert_eq(builder.compile_node(a), a_address)
  assert_eq(builder.statistics().compiled_nodes, 2)
  ignore(builder.compile_node(c))
  assert_eq(builder.compile_node(a), a_address)
  assert_eq(builder.statistics().compiled_nodes, 3)
  assert_true(builder.compile_node(b) > b_address)
  assert_eq(builder.statistics().compiled_nodes, 4)
  assert_eq(builder.statistics().registry_entries, 2)
  assert_true(
    builder.registry[0].signature.words != builder.registry[1].signature.words,
  )
}

///|
test "two-way bucket capacities including odd and disabled" {
  let entries : Array[Entry] = []
  for i in 0..<400 {
    entries.push({
      key: string_bytes("group/\{i}/shared"),
      value: i.to_uint64() * 65537UL,
    })
  }
  entries.sort_by((a, b) => a.key.lexical_compare(b.key))
  let mut maximum_depth = 0
  for entry in entries {
    maximum_depth = Int32::max(maximum_depth, entry.key.length())
  }
  for capacity in [0, 1, 2, 3, 7, 20000] {
    let builder = Builder::map(registry_capacity=capacity)
    for entry in entries {
      builder.insert(entry.key, entry.value)
      assert_true(builder.statistics().registry_entries <= capacity)
      assert_true(
        builder.stack.length() + builder.spare_nodes.length() <=
        maximum_depth + 1,
      )
    }
    let fst = Fst::from_bytes(builder.finish())
    assert_eq(fst.stream().collect(), entries)
    assert_eq(builder.statistics().registry_entries, 0)
  }
}
