///|
/// Development tooling; excluded from production library source counts.
struct Config {
  n : Int32
  shape : String
  samples : Int32
  warmups : Int32
}

///|
struct Dataset {
  a : Array[@fst.Entry]
  b : Array[@fst.Entry]
  all : Array[@fst.Entry]
  misses : Array[Bytes]
  ranges : Array[@fst.KeyRange]
  prefix_expected : Array[@fst.Entry]
  input_key_bytes : UInt64
}

///|
fn read_count(name : String, fallback : Int32) -> Int32 raise {
  match @env.get_env_var(name) {
    None => fallback
    Some(value) => @string.parse_int(value[:])
  }
}

///|
fn read_config() -> Config raise {
  let n = read_count("MOONFST_BENCH_N", 10000)
  let shape = @env.get_env_var("MOONFST_BENCH_SHAPE").unwrap_or("shared")
  let samples = read_count("MOONFST_BENCH_SAMPLES", 7)
  let warmups = read_count("MOONFST_BENCH_WARMUPS", 2)
  guard n >= 2 && n % 2 == 0 && n <= 1431655764 else {
    raise @fst.FstError::InvalidArgument(
      "N must be even, >= 2, and 3*N/2 must fit Int32",
    )
  }
  guard shape == "shared" || shape == "random" else {
    raise @fst.FstError::InvalidArgument("SHAPE must be shared or random")
  }
  guard samples > 0 && warmups >= 0 && samples <= 2147483647 - warmups else {
    raise @fst.FstError::InvalidArgument(
      "SAMPLES must be positive and WARMUPS nonnegative",
    )
  }
  { n, shape, samples, warmups, }
}

///|
fn append_bytes(target : Array[Byte], bytes : Bytes) -> Unit {
  for byte in bytes {
    target.push(byte)
  }
}

///|
fn shared_key(index : Int32) -> Bytes {
  let key = b"catalog/".to_array()
  key.push((index % 64).to_byte())
  append_bytes(key, b"/item/")
  let digits = b"0123456789abcdef"
  for position = 0; position < 8; position = position + 1 {
    let shift = (7 - position) * 4
    let digit = (index.reinterpret_as_uint() >> shift) & 15U
    key.push(digits[digit.reinterpret_as_int()])
  }
  append_bytes(key, b"/meta")
  Bytes::from_array(key)
}

///|
fn prefix_ranges(shape : String) -> Array[@fst.KeyRange] {
  Array::makei(32, index => {
    let prefix = if shape == "shared" {
      let bytes = b"catalog/".to_array()
      bytes.push(index.to_byte())
      bytes.push(b'/')
      Bytes::from_array(bytes)
    } else {
      Bytes::from_array([index.to_byte()])
    }
    @fst.KeyRange::prefix(prefix)
  })
}

///|
fn check_sorted(entries : Array[@fst.Entry]) -> Unit raise {
  for position = 1; position < entries.length(); position = position + 1 {
    guard entries[position - 1].key.lexical_compare(entries[position].key) < 0 else {
      raise @fst.FstError::InvalidArgument(
        "benchmark input must have unique sorted keys",
      )
    }
  }
}

///|
fn make_dataset(config : Config) -> Dataset raise {
  let a : Array[@fst.Entry] = []
  let b : Array[@fst.Entry] = []
  let all : Array[@fst.Entry] = []
  let mut state = 0x00c0ffeeU
  for index = 0; index < config.n + config.n / 2; index = index + 1 {
    let key = if config.shape == "shared" {
      shared_key(index)
    } else {
      let bytes : Array[Byte] = []
      for _ in 0..<12 {
        state = state * 1664525U + 1013904223U
        bytes.push((state >> 24).to_byte())
      }
      for position = 0; position < 4; position = position + 1 {
        bytes.push(
          (index.reinterpret_as_uint() >> ((3 - position) * 8)).to_byte(),
        )
      }
      Bytes::from_array(bytes)
    }
    let value = (index.to_uint64() << 32) |
      (index.reinterpret_as_uint() * 2654435761U).to_uint64()
    let entry = @fst.Entry::{ key, value, }
    if index < config.n {
      a.push(entry)
    }
    if index >= config.n / 2 {
      b.push(entry)
    }
    all.push(entry)
  }
  a.sort_by((left, right) => left.key.lexical_compare(right.key))
  b.sort_by((left, right) => left.key.lexical_compare(right.key))
  all.sort_by((left, right) => left.key.lexical_compare(right.key))
  check_sorted(a)
  check_sorted(b)
  check_sorted(all)
  let ranges = prefix_ranges(config.shape)
  let prefix_expected = []
  for range in ranges {
    for entry in a {
      if range.contains(entry.key) {
        prefix_expected.push(entry)
      }
    }
  }
  let misses = a.map(entry => {
    let bytes = entry.key.to_array()
    bytes.push(b'\xff')
    Bytes::from_array(bytes)
  })
  let mut input_key_bytes = 0UL
  for entry in a {
    input_key_bytes = input_key_bytes + entry.key.length().to_uint64()
  }
  { a, b, all, misses, ranges, prefix_expected, input_key_bytes, }
}

///|
fn fnv_byte(hash : UInt64, byte : Byte) -> UInt64 {
  (hash ^ byte.to_uint64()) * 1099511628211UL
}

///|
/// Key bytes, four little-endian length bytes, then eight little-endian value
/// bytes. Wrapping UInt64 arithmetic is part of the shared benchmark protocol.
fn checksum_entries(entries : Array[@fst.Entry]) -> UInt64 {
  let mut hash = 14695981039346656037UL
  for entry in entries {
    for byte in entry.key {
      hash = fnv_byte(hash, byte)
    }
    let length = entry.key.length().reinterpret_as_uint()
    for position = 0; position < 4; position = position + 1 {
      hash = fnv_byte(hash, (length >> (position * 8)).to_byte())
    }
    for position = 0; position < 8; position = position + 1 {
      hash = fnv_byte(hash, (entry.value >> (position * 8)).to_byte())
    }
  }
  hash
}

///|
fn build(entries : Array[@fst.Entry]) -> Bytes raise {
  let builder = @fst.Builder::map()
  for entry in entries {
    builder.insert(entry.key, entry.value)
  }
  // Validation is deliberately outside the build metric.
  builder.finish()
}

///|
fn lookup_hit(index : @fst.Fst, entries : Array[@fst.Entry]) -> UInt64 raise {
  let mut sum = 0UL
  for entry in entries {
    match index.get(entry.key) {
      Some(value) => sum = sum + value
      None =>
        raise @fst.FstError::InvalidFormat(
          "benchmark lookup_hit did not find an expected key",
        )
    }
  }
  sum
}

///|
fn lookup_miss(index : @fst.Fst, keys : Array[Bytes]) -> UInt64 raise {
  let mut count = 0UL
  for key in keys {
    if index.get(key) is Some(_) {
      count = count + 1UL
    }
  }
  count
}

///|
fn prefix_owned(
  index : @fst.Fst,
  ranges : Array[@fst.KeyRange],
) -> Array[@fst.Entry] raise {
  let output = []
  for range in ranges {
    let records = index.stream(range~).collect()
    for entry in records {
      output.push(entry)
    }
  }
  output
}

///|
fn union_owned(a : @fst.Fst, b : @fst.Fst) -> Array[@fst.Entry] raise {
  let output = []
  let merged = @fst.merge([a, b], @fst.Operation::Union)
  while merged.next() is Some(group) {
    // Indexed values are source-ordered, so this selects source zero whenever
    // both contain a key. Source grouping and final record allocation are timed.
    output.push(@fst.Entry::{ key: group.key, value: group.values[0].value, })
  }
  output
}

///|
fn describe_entries(entries : Array[@fst.Entry]) -> (UInt64, UInt64) {
  (checksum_entries(entries), entries.length().to_uint64())
}

///|
/// Each iteration owns a fresh complete result. Clocks bracket only production
/// of that result. Hashing, checking, opaque retention, and final destruction
/// take place afterwards and before the following iteration starts.
fn[T] measure(
  config : Config,
  name : String,
  operation : () -> T raise,
  describe : (T) -> (UInt64, UInt64) raise,
  expected : (UInt64, UInt64),
) -> Json raise {
  let keeper = @bench.Bench()
  let times : Array[Double] = []
  for iteration = 0
      iteration < config.warmups + config.samples
      iteration = iteration + 1 {
    let start = @bench.monotonic_clock_start()
    let result = operation()
    let elapsed = @bench.monotonic_clock_end(start)
    keeper.keep(result)
    let actual = describe(result)
    assert_eq(actual, expected)
    if iteration >= config.warmups {
      times.push(elapsed)
    }
    keeper.keep(())
  }
  Json::object({
    "name": Json::string(name),
    "samples_us": @json.to_json(times),
    "checksum": Json::string(expected.0.to_string()),
    "result_count": Json::number(expected.1.to_double()),
  })
}

///|
fn run() -> Json raise {
  let config = read_config()
  let dataset = make_dataset(config)
  let a_bytes = build(dataset.a)
  let b_bytes = build(dataset.b)
  let a = @fst.Fst::from_bytes(a_bytes)
  let b = @fst.Fst::from_bytes(b_bytes)
  // Dataset construction, order checks, validation and query creation are not
  // timed. These full comparisons also establish the benchmark's correctness.
  assert_eq(a.stream().collect(), dataset.a)
  assert_eq(b.stream().collect(), dataset.b)
  for entry in dataset.a {
    assert_eq(a.get(entry.key), Some(entry.value))
  }
  assert_eq(lookup_miss(a, dataset.misses), 0UL)
  assert_eq(prefix_owned(a, dataset.ranges), dataset.prefix_expected)
  assert_eq(union_owned(a, b), dataset.all)
  let mut expected_sum = 0UL
  for entry in dataset.a {
    expected_sum = expected_sum + entry.value
  }
  let n = config.n.to_uint64()
  let metrics = [
    measure(
      config,
      "build",
      () => build(dataset.a),
      bytes => {
        // The reference bytes were decoded and compared with every input
        // record above. Equal length alone would not establish correctness.
        assert_eq(bytes, a_bytes)
        (bytes.length().to_uint64(), n)
      },
      (a_bytes.length().to_uint64(), n),
    ),
    measure(
      config,
      "lookup_hit",
      () => lookup_hit(a, dataset.a),
      sum => (sum, n),
      (expected_sum, n),
    ),
    measure(
      config,
      "lookup_miss",
      () => lookup_miss(a, dataset.misses),
      found => (found, found),
      (0UL, 0UL),
    ),
    measure(
      config,
      "stream_owned",
      () => a.stream().collect(),
      entries => describe_entries(entries),
      describe_entries(dataset.a),
    ),
    measure(
      config,
      "prefix_owned",
      () => prefix_owned(a, dataset.ranges),
      entries => describe_entries(entries),
      describe_entries(dataset.prefix_expected),
    ),
    measure(
      config,
      "union_owned",
      () => union_owned(a, b),
      entries => describe_entries(entries),
      describe_entries(dataset.all),
    ),
  ]
  Json::object({
    "schema": @json.to_json(1),
    "engine": Json::string("moonbit"),
    "shape": Json::string(config.shape),
    "n": @json.to_json(config.n),
    "samples": @json.to_json(config.samples),
    "warmups": @json.to_json(config.warmups),
    "seed": @json.to_json(12648430),
    "dataset_hash": Json::string(checksum_entries(dataset.a).to_string()),
    "input_key_bytes": Json::number(dataset.input_key_bytes.to_double()),
    "fst_bytes": @json.to_json(a_bytes.length()),
    "metrics": Json::array(metrics),
  })
}

///|
fn main {
  let report = run() catch { error => abort(error.to_string()) }
  println(report.stringify())
}
