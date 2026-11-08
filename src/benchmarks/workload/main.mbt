///|
/// Native development tooling. No FFI is used by the MoonFST library.
extern "C" fn read_input() -> Bytes = "moonfst_workload_read_input"

///|
extern "C" fn read_fst() -> Bytes = "moonfst_workload_read_fst"

///|
#borrow(bytes)
extern "C" fn write_fst(bytes : Bytes, length : Int32) -> Unit = "moonfst_workload_write_fst"

///|
extern "C" fn rss_kib() -> Int64 = "moonfst_workload_rss_kib"

///|
extern "C" fn peak_rss_kib() -> Int64 = "moonfst_workload_peak_rss_kib"

///|
struct Config {
  mode : String
  order : String
  samples : Int32
  warmups : Int32
  query_seed : UInt32
}

///|
struct Dataset {
  // Retain the original input through memory snapshots in addition to the
  // independently owned decoded keys shared by these three record arrays.
  input : Bytes
  n : Int32
  a : Array[@fst.Entry]
  b : Array[@fst.Entry]
  all : Array[@fst.Entry]
}

///|
struct Queries {
  ordered : Array[@fst.Entry]
  hits : Array[Bytes]
  misses : Array[Bytes]
  mixed : Array[Bytes]
  hit_sum : UInt64
  mixed_sum : UInt64
}

///|
struct Snapshot {
  rss : Int64
  peak : Int64
}

///|
fn snapshot() -> Snapshot {
  { rss: rss_kib(), peak: peak_rss_kib(), }
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
  let mode = @env.get_env_var("MOONFST_WORKLOAD_MODE").unwrap_or("timing")
  let order = @env.get_env_var("MOONFST_WORKLOAD_ORDER").unwrap_or("sorted")
  let samples = read_count("MOONFST_WORKLOAD_SAMPLES", 7)
  let warmups = read_count("MOONFST_WORKLOAD_WARMUPS", 2)
  let query_seed = match @env.get_env_var("MOONFST_WORKLOAD_QUERY_SEED") {
    None => 305419896U
    Some(value) => @string.parse_uint(value[:])
  }
  guard mode == "timing" ||
    mode == "memory-baseline" ||
    mode == "memory-build" ||
    mode == "memory-union" ||
    mode == "memory-load" else {
    raise @fst.FstError::InvalidArgument("unknown WORKLOAD_MODE")
  }
  guard order == "sorted" || order == "shuffled" else {
    raise @fst.FstError::InvalidArgument(
      "WORKLOAD_ORDER must be sorted or shuffled",
    )
  }
  guard samples > 0 && warmups >= 0 && samples <= 2147483647 - warmups else {
    raise @fst.FstError::InvalidArgument("invalid sample or warmup count")
  }
  { mode, order, samples, warmups, query_seed, }
}

///|
fn read_u32(input : Bytes, offset : Int32) -> UInt32 raise {
  guard offset >= 0 && offset <= input.length() - 4 else {
    raise @fst.FstError::InvalidFormat("truncated workload u32")
  }
  let mut value = 0U
  for byte = 0; byte < 4; byte = byte + 1 {
    value = value | (input[offset + byte].to_uint() << (byte * 8))
  }
  value
}

///|
fn read_u64(input : Bytes, offset : Int32) -> UInt64 raise {
  guard offset >= 0 && offset <= input.length() - 8 else {
    raise @fst.FstError::InvalidFormat("truncated workload u64")
  }
  let mut value = 0UL
  for byte = 0; byte < 8; byte = byte + 1 {
    value = value | (input[offset + byte].to_uint64() << (byte * 8))
  }
  value
}

///|
fn check_sorted_unique(entries : Array[@fst.Entry]) -> Unit raise {
  for position = 1; position < entries.length(); position = position + 1 {
    guard entries[position - 1].key.lexical_compare(entries[position].key) < 0 else {
      raise @fst.FstError::InvalidFormat("workload contains duplicate keys")
    }
  }
}

///|
fn parse_dataset(input : Bytes) -> Dataset raise {
  guard input.length() >= 16 &&
    input.range_equal(start=0, b"MFSTW001", other_start=0, len=8) else {
    raise @fst.FstError::InvalidFormat("invalid MFSTW001 input header")
  }
  let count = read_u32(input, 8)
  guard count >= 2U && count <= 1431655764U && count % 2U == 0U else {
    raise @fst.FstError::InvalidFormat("workload n must be even and >= 2")
  }
  let n = count.reinterpret_as_int()
  let total = n + n / 2
  guard read_u32(input, 12) == total.reinterpret_as_uint() else {
    raise @fst.FstError::InvalidFormat("workload total must equal 3*n/2")
  }
  // Every record needs at least twelve bytes, even when its key is empty.
  guard total <= (input.length() - 16) / 12 else {
    raise @fst.FstError::InvalidFormat("workload record count exceeds input")
  }
  let a = []
  let b = []
  let all = []
  let mut offset = 16
  for position = 0; position < total; position = position + 1 {
    let length = read_u32(input, offset)
    let value = read_u64(input, offset + 4)
    offset = offset + 12
    guard length <= (input.length() - offset).reinterpret_as_uint() else {
      raise @fst.FstError::InvalidFormat("truncated workload key")
    }
    let end = offset + length.reinterpret_as_int()
    let key = input.exact_view(start=offset, end~).to_owned()
    offset = end
    let entry = @fst.Entry::{ key, value, }
    if position < n {
      a.push(entry)
    }
    if position >= n / 2 {
      b.push(entry)
    }
    all.push(entry)
  }
  guard offset == input.length() else {
    raise @fst.FstError::InvalidFormat("trailing bytes after workload records")
  }
  a.sort_by((left, right) => left.key.lexical_compare(right.key))
  b.sort_by((left, right) => left.key.lexical_compare(right.key))
  all.sort_by((left, right) => left.key.lexical_compare(right.key))
  check_sorted_unique(all)
  { input, n, a, b, all, }
}

///|
fn fnv_byte(hash : UInt64, byte : Byte) -> UInt64 {
  (hash ^ byte.to_uint64()) * 1099511628211UL
}

///|
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
fn make_indices(n : Int32, order : String, seed : UInt32) -> Array[Int32] {
  let indices = Array::makei(n, index => index)
  if order == "shuffled" {
    let mut state = seed
    for index = n - 1; index > 0; index = index - 1 {
      state = state * 1664525U + 1013904223U
      let other = (state % (index + 1).reinterpret_as_uint()).reinterpret_as_int()
      let temporary = indices[index]
      indices[index] = indices[other]
      indices[other] = temporary
    }
  }
  indices
}

///|
fn make_queries(dataset : Dataset, config : Config) -> Queries {
  let indices = make_indices(dataset.n, config.order, config.query_seed)
  let ordered = indices.map(index => dataset.a[index])
  let hits = ordered.map(entry => entry.key)
  let misses = ordered.map(entry => entry.key + b"\xff")
  let mixed = Array::makei(dataset.n, position => {
    if position % 2 == 0 {
      hits[position]
    } else {
      misses[position]
    }
  })
  let mut hit_sum = 0UL
  let mut mixed_sum = 0UL
  for position = 0; position < ordered.length(); position = position + 1 {
    let value = ordered[position].value
    hit_sum = hit_sum + value
    if position % 2 == 0 {
      mixed_sum = mixed_sum + value
    }
  }
  { ordered, hits, misses, mixed, hit_sum, mixed_sum, }
}

///|
fn build(entries : Array[@fst.Entry]) -> Bytes raise {
  let builder = @fst.Builder::map()
  for entry in entries {
    builder.insert(entry.key, entry.value)
  }
  builder.finish()
}

///|
fn lookup(index : @fst.Fst, keys : Array[Bytes]) -> (UInt64, UInt64) raise {
  let mut sum = 0UL
  let mut count = 0UL
  for key in keys {
    if index.get(key) is Some(value) {
      sum = sum + value
      count = count + 1UL
    }
  }
  (sum, count)
}

///|
fn union_owned(a : @fst.Fst, b : @fst.Fst) -> Array[@fst.Entry] raise {
  let output = []
  let merged = @fst.merge([a, b], @fst.Operation::Union)
  while merged.next() is Some(group) {
    output.push(@fst.Entry::{ key: group.key, value: group.values[0].value, })
  }
  output
}

///|
fn verify_queries(a : @fst.Fst, queries : Queries) -> Unit raise {
  for position = 0; position < queries.ordered.length(); position = position + 1 {
    let expected = queries.ordered[position].value
    assert_eq(a.get(queries.hits[position]), Some(expected))
    assert_eq(a.get(queries.misses[position]), None)
    assert_eq(
      a.get(queries.mixed[position]),
      if position % 2 == 0 {
        Some(expected)
      } else {
        None
      },
    )
  }
}

///|
/// Check full records as well as checksums outside every timed interval.
fn describe_entries(
  actual : Array[@fst.Entry],
  expected : Array[@fst.Entry],
) -> (UInt64, UInt64) raise {
  assert_eq(actual, expected)
  (checksum_entries(actual), actual.length().to_uint64())
}

///|
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
    assert_eq(describe(result), expected)
    if iteration >= config.warmups {
      times.push(elapsed)
    }
    // Destruction of the final owned result finishes before the next timer.
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
fn run_timing(config : Config, dataset : Dataset) -> Json raise {
  let a_bytes = build(dataset.a)
  let b_bytes = build(dataset.b)
  let a = @fst.Fst::from_bytes(a_bytes)
  let b = @fst.Fst::from_bytes(b_bytes)
  assert_eq(a.stream().collect(), dataset.a)
  assert_eq(b.stream().collect(), dataset.b)
  let queries = make_queries(dataset, config)
  verify_queries(a, queries)
  assert_eq(union_owned(a, b), dataset.all)
  // Optional output is written outside every measured interval.
  write_fst(a_bytes, a_bytes.length())
  let n = dataset.n.to_uint64()
  let dataset_hash = checksum_entries(dataset.a)
  let b_hash = checksum_entries(dataset.b)
  let union_hash = checksum_entries(dataset.all)
  let mut input_key_bytes = 0UL
  for entry in dataset.a {
    input_key_bytes = input_key_bytes + entry.key.length().to_uint64()
  }
  let metrics = [
    measure(
      config,
      "build",
      () => build(dataset.a),
      bytes => {
        // The reference has passed CRC/full graph validation and an exact
        // decoded-record comparison. Length alone would be insufficient.
        assert_eq(bytes, a_bytes)
        (bytes.length().to_uint64(), n)
      },
      (a_bytes.length().to_uint64(), n),
    ),
    measure(
      config,
      "lookup_hit",
      () => lookup(a, queries.hits),
      value => value,
      (queries.hit_sum, n),
    ),
    measure(
      config,
      "lookup_miss",
      () => lookup(a, queries.misses),
      value => value,
      (0UL, 0UL),
    ),
    measure(
      config,
      "lookup_mixed",
      () => lookup(a, queries.mixed),
      value => value,
      (queries.mixed_sum, n / 2UL),
    ),
    measure(
      config,
      "stream_owned",
      () => a.stream().collect(),
      entries => describe_entries(entries, dataset.a),
      (dataset_hash, n),
    ),
    measure(
      config,
      "union_owned",
      () => union_owned(a, b),
      entries => describe_entries(entries, dataset.all),
      (union_hash, dataset.all.length().to_uint64()),
    ),
  ]
  Json::object({
    "schema": @json.to_json(1),
    "measurement_revision": @json.to_json(2),
    "engine": Json::string("moonbit"),
    "mode": Json::string("timing"),
    "n": @json.to_json(dataset.n),
    "total": @json.to_json(dataset.all.length()),
    "order": Json::string(config.order),
    "query_seed": @json.to_json(config.query_seed),
    "order_hash": Json::string(checksum_entries(queries.ordered).to_string()),
    "dataset_hash": Json::string(dataset_hash.to_string()),
    "b_hash": Json::string(b_hash.to_string()),
    "union_hash": Json::string(union_hash.to_string()),
    "input_key_bytes": Json::number(input_key_bytes.to_double()),
    "fst_bytes": @json.to_json(a_bytes.length()),
    "samples": @json.to_json(config.samples),
    "warmups": @json.to_json(config.warmups),
    "metrics": Json::array(metrics),
  })
}

///|
fn memory_report(
  mode : String,
  n : Int32,
  baseline : Snapshot,
  after : Snapshot,
  validation : Snapshot,
  fst_bytes : Int32,
  checksum : UInt64,
  result_count : Int32,
) -> Json {
  Json::object({
    "schema": @json.to_json(1),
    "measurement_revision": @json.to_json(2),
    "engine": Json::string("moonbit"),
    "mode": Json::string(mode),
    "memory_source": Json::string("proc-self-status"),
    "n": @json.to_json(n),
    "baseline_rss_kib": Json::number(baseline.rss.to_double()),
    "baseline_peak_rss_kib": Json::number(baseline.peak.to_double()),
    "after_rss_kib": Json::number(after.rss.to_double()),
    "peak_rss_kib": Json::number(after.peak.to_double()),
    "validation_after_rss_kib": Json::number(validation.rss.to_double()),
    "validation_peak_rss_kib": Json::number(validation.peak.to_double()),
    "fst_bytes": @json.to_json(fst_bytes),
    "checksum": Json::string(checksum.to_string()),
    "result_count": @json.to_json(result_count),
    "load_validation": Json::string("CRC and complete graph validation"),
  })
}

///|
fn run_memory(config : Config, dataset : Dataset) -> Json raise {
  let keeper = @bench.Bench()
  keeper.keep(dataset)
  if config.mode == "memory-baseline" {
    let hash = checksum_entries(dataset.a)
    let baseline = snapshot()
    let report = memory_report(
      config.mode,
      dataset.n,
      baseline,
      baseline,
      baseline,
      0,
      hash,
      dataset.n,
    )
    keeper.keep((dataset.input, dataset.a, dataset.b, dataset.all))
    report
  } else if config.mode == "memory-build" {
    let baseline = snapshot()
    let bytes = build(dataset.a)
    keeper.keep((dataset, bytes))
    let after = snapshot()
    // Full decoding and owned enumeration happen only after the build peak
    // was recorded; the original input and built bytes remain live.
    let index = @fst.Fst::from_bytes(bytes)
    let records = index.stream().collect()
    assert_eq(records, dataset.a)
    let hash = checksum_entries(records)
    keeper.keep((dataset, bytes, index, records))
    let validation = snapshot()
    let report = memory_report(
      config.mode,
      dataset.n,
      baseline,
      after,
      validation,
      bytes.length(),
      hash,
      records.length(),
    )
    keeper.keep(
      (dataset.input, dataset.a, dataset.b, dataset.all, bytes, index, records),
    )
    report
  } else {
    let a_bytes = build(dataset.a)
    let b_bytes = build(dataset.b)
    let a = @fst.Fst::from_bytes(a_bytes)
    let b = @fst.Fst::from_bytes(b_bytes)
    assert_eq(a.stream().collect(), dataset.a)
    assert_eq(b.stream().collect(), dataset.b)
    keeper.keep((dataset, a_bytes, b_bytes, a, b))
    let baseline = snapshot()
    let records = union_owned(a, b)
    keeper.keep((dataset, a_bytes, b_bytes, a, b, records))
    let after = snapshot()
    assert_eq(records, dataset.all)
    let hash = checksum_entries(records)
    let validation = snapshot()
    let report = memory_report(
      config.mode,
      dataset.n,
      baseline,
      after,
      validation,
      a_bytes.length(),
      hash,
      records.length(),
    )
    keeper.keep(
      (
        dataset.input,
        dataset.a,
        dataset.b,
        dataset.all,
        a_bytes,
        b_bytes,
        a,
        b,
        records,
      ),
    )
    report
  }
}

///|
fn run_load(config : Config) -> Json raise {
  let n = read_count("MOONFST_WORKLOAD_N", 0)
  guard n >= 2 && n % 2 == 0 else {
    raise @fst.FstError::InvalidArgument(
      "memory-load requires even WORKLOAD_N >= 2",
    )
  }
  let bytes = read_fst()
  let keeper = @bench.Bench()
  keeper.keep(bytes)
  let baseline = snapshot()
  let index = @fst.Fst::from_bytes(bytes)
  keeper.keep((bytes, index))
  let after = snapshot()
  assert_eq(index.len(), n.to_uint64())
  let records = index.stream().collect()
  let hash = checksum_entries(records)
  keeper.keep((bytes, index, records))
  let validation = snapshot()
  let report = memory_report(
    config.mode,
    n,
    baseline,
    after,
    validation,
    bytes.length(),
    hash,
    records.length(),
  )
  keeper.keep((bytes, index, records))
  report
}

///|
fn run() -> Json raise {
  let config = read_config()
  if config.mode == "memory-load" {
    run_load(config)
  } else {
    let dataset = parse_dataset(read_input())
    if config.mode == "timing" {
      run_timing(config, dataset)
    } else {
      run_memory(config, dataset)
    }
  }
}

///|
fn main {
  let report = run() catch { error => abort(error.to_string()) }
  println(report.stringify())
}
