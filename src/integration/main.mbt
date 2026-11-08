///|
/// This is test tooling. It is excluded from the production source count.
struct Fixture {
  name : String
  kind : String
  data_hex : String
  entries_json : String
}

///|
fn decode_hex(input : String) -> Bytes raise {
  guard input.length() % 2 == 0 else {
    raise @fst.FstError::InvalidArgument("odd hex length in test fixture")
  }
  let output : Array[Byte] = []
  for i in 0..<(input.length() / 2) {
    output.push(@string.parse_uint(input[i * 2:i * 2 + 2], base=16).to_byte())
  }
  Bytes::from_array(output)
}

///|
fn encode_hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let output = StringBuilder()
  for byte in bytes {
    let value = byte.to_int()
    output.write_char(digits[value / 16].to_int().to_char().unwrap())
    output.write_char(digits[value % 16].to_int().to_char().unwrap())
  }
  output.to_string()
}

///|
fn encode_entries(entries : Array[@fst.Entry]) -> Json {
  Json::array(
    entries.map(entry => {
      Json::array([
        Json::string(encode_hex(entry.key)),
        Json::string(entry.value.to_string()),
      ])
    }),
  )
}

///|
fn lookup_json(index : @fst.Fst, probes : Array[String]) -> Json raise {
  let found : Array[Json] = []
  for probe in probes {
    let value = match index.get(decode_hex(probe)) {
      Some(value) => Json::string(value.to_string())
      None => Json::null()
    }
    found.push(Json::array([Json::string(probe), value]))
  }
  Json::array(found)
}

///|
fn check_fixture(fixture : Fixture) -> Json raise {
  let records : Array[(String, String)] = @json.from_json(
    @json.parse(fixture.entries_json),
  )
  let rust_index = @fst.Fst::from_bytes(decode_hex(fixture.data_hex))
  let decoded = rust_index.stream().collect()
  let builder = if fixture.kind == "set" {
    @fst.Builder::set()
  } else {
    @fst.Builder::map()
  }
  for pair in records {
    let (key, value) = pair
    if fixture.kind == "set" {
      builder.add(decode_hex(key))
    } else {
      builder.insert(decode_hex(key), @string.parse_uint64(value[:]))
    }
  }
  let moon_bytes = builder.finish()
  let moon_index = @fst.Fst::from_bytes(moon_bytes)
  assert_eq(moon_index.stream().collect(), decoded)
  let probes = ["", "00", "ff", "00010203", "ffffffffffffffff"]
  let prefix = if records.is_empty() {
    b"\x00"
  } else {
    let middle = decode_hex(records[records.length() / 2].0)
    middle[:if middle.length() > 2 { 2 } else { middle.length() }].to_owned()
  }
  if !records.is_empty() {
    probes.push(records[0].0)
    probes.push(records[records.length() / 2].0)
    probes.push(records[records.length() - 1].0)
  }
  let range : @fst.KeyRange = {
    lower: @fst.Bound::Included(b"\x00"),
    upper: @fst.Bound::Excluded(b"\xff"),
  }
  Json::object({
    "ok": Json::boolean(true),
    "name": Json::string(fixture.name),
    "len": Json::string(rust_index.len().to_string()),
    "entries": encode_entries(decoded),
    "lookups": lookup_json(rust_index, probes),
    "range": encode_entries(rust_index.stream(range~).collect()),
    "prefix_hex": Json::string(encode_hex(prefix)),
    "prefix": encode_entries(rust_index.prefix(prefix).collect()),
    "moon_bytes_hex": Json::string(encode_hex(moon_bytes)),
  })
}

///|
fn main {
  for fixture in fixture_cases() {
    let report = check_fixture(fixture) catch {
      error =>
        Json::object({
          "ok": Json::boolean(false),
          "name": Json::string(fixture.name),
          "error": Json::string(error.to_string()),
        })
    }
    println("MOONFST_INTEROP\t" + report.stringify())
  }
}
