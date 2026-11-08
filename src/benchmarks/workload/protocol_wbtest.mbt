///|
fn encode_test_input(n : Int32, entries : Array[@fst.Entry]) -> Bytes {
  let bytes = b"MFSTW001".to_array()
  for number in [n, entries.length()] {
    for shift in 0..<4 {
      bytes.push((number.reinterpret_as_uint() >> (shift * 8)).to_byte())
    }
  }
  for entry in entries {
    for shift in 0..<4 {
      bytes.push(
        (entry.key.length().reinterpret_as_uint() >> (shift * 8)).to_byte(),
      )
    }
    for shift in 0..<8 {
      bytes.push((entry.value >> (shift * 8)).to_byte())
    }
    for byte in entry.key {
      bytes.push(byte)
    }
  }
  Bytes::from_array(bytes)
}

///|
fn rejects_input(bytes : Bytes) -> Bool {
  try {
    ignore(parse_dataset(bytes))
    false
  } catch {
    @fst.FstError::InvalidFormat(_) => true
    _ => false
  }
}

///|
test "workload parser preserves split before lexical sorting and u64 values" {
  let original = [
    @fst.Entry::{ key: b"z", value: 18446744073709551615UL, },
    @fst.Entry::{ key: b"", value: 2UL, },
    @fst.Entry::{ key: b"aa", value: 3UL, },
  ]
  let input = encode_test_input(2, original)
  let dataset = parse_dataset(input)
  assert_eq(dataset.input, input)
  assert_eq(dataset.n, 2)
  assert_eq(dataset.a, [original[1], original[0]])
  assert_eq(dataset.b, [original[1], original[2]])
  assert_eq(dataset.all, [original[1], original[2], original[0]])
  let index = @fst.Fst::from_bytes(build(dataset.a))
  assert_eq(index.stream().collect(), dataset.a)
}

///|
test "workload parser rejects malformed and ambiguous records" {
  let entries = [
    @fst.Entry::{ key: b"a", value: 0UL, },
    @fst.Entry::{ key: b"b", value: 1UL, },
    @fst.Entry::{ key: b"c", value: 2UL, },
  ]
  let input = encode_test_input(2, entries)
  assert_true(rejects_input(b""))
  for end = 0; end < input.length(); end = end + 1 {
    assert_true(rejects_input(input.exact_view(start=0, end~).to_owned()))
  }
  assert_true(rejects_input(input + b"x"))
  assert_true(rejects_input(encode_test_input(3, entries)))
  assert_true(rejects_input(encode_test_input(2, [entries[0], entries[1]])))
  assert_true(
    rejects_input(encode_test_input(2, [entries[0], entries[0], entries[2]])),
  )
  let oversized = input.to_array()
  for byte in 0..<4 {
    oversized[16 + byte] = b'\xff'
  }
  assert_true(rejects_input(Bytes::from_array(oversized)))
}

///|
test "workload shuffle is reproducible and mixed queries alternate positions" {
  assert_eq(make_indices(4, "shuffled", 305419896U), [2, 1, 0, 3])
  assert_eq(make_indices(4, "sorted", 305419896U), [0, 1, 2, 3])
  let original = [
    @fst.Entry::{ key: b"a", value: 2UL, },
    @fst.Entry::{ key: b"b", value: 3UL, },
    @fst.Entry::{ key: b"c", value: 5UL, },
    @fst.Entry::{ key: b"d", value: 7UL, },
    @fst.Entry::{ key: b"e", value: 11UL, },
    @fst.Entry::{ key: b"f", value: 13UL, },
  ]
  let dataset = parse_dataset(encode_test_input(4, original))
  let config : Config = {
    mode: "timing",
    order: "shuffled",
    samples: 1,
    warmups: 0,
    query_seed: 305419896U,
  }
  let queries = make_queries(dataset, config)
  assert_eq(queries.hits, [b"c", b"b", b"a", b"d"])
  assert_eq(queries.mixed, [b"c", b"b\xff", b"a", b"d\xff"])
  assert_eq(queries.hit_sum, 17UL)
  assert_eq(queries.mixed_sum, 7UL)
  let index = @fst.Fst::from_bytes(build(dataset.a))
  verify_queries(index, queries)
  assert_eq(lookup(index, queries.hits), (17UL, 4UL))
  assert_eq(lookup(index, queries.misses), (0UL, 0UL))
  assert_eq(lookup(index, queries.mixed), (7UL, 2UL))
}
