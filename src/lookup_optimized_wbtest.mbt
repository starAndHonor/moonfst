///|
/// Linear array truth is independent of both the builder and either decoder.
fn opt_array_get(entries : Array[Entry], key : Bytes) -> UInt64? {
  for entry in entries {
    if entry.key == key {
      return Some(entry.value)
    }
  }
  None
}

///|
/// Keep the owned strict decoder as a second, structurally different reader.
fn opt_slow_get(data : Bytes, key : Bytes) -> UInt64? raise {
  let header = @codec.read_header(data)
  let mut node = @codec.read_node(data, header, header.root)
  let mut output = 0UL
  for input in key {
    let mut selected : @codec.Transition? = None
    for edge in node.transitions {
      if edge.input == input {
        selected = Some(edge)
        break
      }
    }
    match selected {
      None => return None
      Some(edge) => {
        output = output + edge.output
        node = @codec.read_node(data, header, edge.addr)
      }
    }
  }
  if node.is_final {
    Some(output + node.final_output)
  } else {
    None
  }
}

///|
fn opt_check(
  data : Bytes,
  entries : Array[Entry],
  queries : Array[Bytes],
) -> Unit raise {
  let fst = Fst::from_bytes(data)
  @debug.assert_eq(fst.len(), entries.length().to_uint64())
  for query in queries {
    let expected = opt_array_get(entries, query)
    @debug.assert_eq(opt_slow_get(data, query), expected)
    @debug.assert_eq(fst.get(query), expected)
    @debug.assert_eq(fst.contains(query), expected is Some(_))
  }
}

///|
fn opt_pack(buffer : Array[Byte], value : UInt64, width : Int32) -> Unit {
  for byte = 0; byte < width; byte = byte + 1 {
    buffer.push((value >> (byte * 8)).to_byte())
  }
}

///|
fn opt_header(version : UInt64) -> Array[Byte] {
  let buffer : Array[Byte] = []
  opt_pack(buffer, version, 8)
  opt_pack(buffer, 0UL, 8)
  buffer
}

///|
fn opt_finish(
  buffer : Array[Byte],
  version : UInt64,
  root : Int32,
  count : UInt64,
) -> Bytes {
  opt_pack(buffer, count, 8)
  opt_pack(buffer, root.to_uint64(), 8)
  if version >= 3UL {
    let crc = @codec.masked_crc32c(Bytes::from_array(buffer))
    opt_pack(buffer, crc.to_uint64(), 4)
  }
  Bytes::from_array(buffer)
}

///|
/// Explicit widths exercise legal over-wide encodings that the canonical
/// writer cannot naturally produce for a small test file.
fn opt_general(
  buffer : Array[Byte],
  version : UInt64,
  is_final : Bool,
  final_output : UInt64,
  edges : Array[@codec.Transition],
  tsize : Int32,
  osize : Int32,
) -> Int32 {
  let start = buffer.length()
  if is_final {
    opt_pack(buffer, final_output, osize)
  }
  for i = edges.length() - 1; i >= 0; i = i - 1 {
    opt_pack(buffer, edges[i].output, osize)
  }
  for i = edges.length() - 1; i >= 0; i = i - 1 {
    let delta = if edges[i].addr == 0 {
      0UL
    } else {
      (start - edges[i].addr).to_uint64()
    }
    opt_pack(buffer, delta, tsize)
  }
  for i = edges.length() - 1; i >= 0; i = i - 1 {
    buffer.push(edges[i].input)
  }
  if version >= 2UL && edges.length() > 32 {
    for input = 0; input < 256; input = input + 1 {
      let mut ordinal = 255
      for i = 0; i < edges.length(); i = i + 1 {
        if edges[i].input.to_int() == input {
          ordinal = i
          break
        }
      }
      buffer.push(ordinal.to_byte())
    }
  }
  buffer.push(((tsize << 4) | osize).to_byte())
  let inline_count = if edges.length() > 0 && edges.length() <= 63 {
    edges.length()
  } else {
    0
  }
  if inline_count == 0 {
    buffer.push(
      (if edges.length() == 256 { 1 } else { edges.length() }).to_byte(),
    )
  }
  buffer.push(((if is_final { 64 } else { 0 }) | inline_count).to_byte())
  buffer.length() - 1
}

///|
fn opt_single(
  buffer : Array[Byte],
  input : Byte,
  common : Bool,
  target : Int32,
  output : UInt64,
  tsize : Int32,
  osize : Int32,
) -> Int32 {
  let start = buffer.length()
  opt_pack(buffer, output, osize)
  opt_pack(
    buffer,
    if target == 0 {
      0UL
    } else {
      (start - target).to_uint64()
    },
    tsize,
  )
  buffer.push(((tsize << 4) | osize).to_byte())
  if !common {
    buffer.push(input)
  }
  // 't' is COMMON_INPUTS_INV[1]. All other inputs here are explicit.
  buffer.push((128 | (if common { 1 } else { 0 })).to_byte())
  buffer.length() - 1
}

///|
fn opt_append(key : Bytes, byte : Byte) -> Bytes {
  let bytes = key.to_array()
  bytes.push(byte)
  Bytes::from_array(bytes)
}

///|
test "optimized lookup empty language empty key and terminal UInt64 boundaries" {
  for version in [1UL, 2UL, 3UL] {
    let empty = opt_header(version)
    let root = opt_general(empty, version, false, 0UL, [], 0, 0)
    opt_check(opt_finish(empty, version, root, 0UL), [], [
      b"", b"a", b"\x00", b"\xff",
    ])
    opt_check(
      opt_finish(opt_header(version), version, 0, 1UL),
      [{ key: b"", value: 0UL, }],
      [b"", b"a", b"\x00", b"\xff"],
    )
    for width = 1; width <= 8; width = width + 1 {
      let value = if width == 8 {
        0xffffffffffffffffUL
      } else {
        (1UL << (width * 8)) - 1UL
      }
      let buffer = opt_header(version)
      let root = opt_general(buffer, version, true, value, [], 0, width)
      opt_check(
        opt_finish(buffer, version, root, 1UL),
        [{ key: b"", value, }],
        [b"", b"a", b"\x00", b"\xff"],
      )
    }
  }
}

///|
test "optimized lookup every common and explicit single and next input byte" {
  for version in [1UL, 2UL, 3UL] {
    for input = 0; input < 256; input = input + 1 {
      let byte = input.to_byte()
      let key = Bytes::from_array([byte])
      let wrong = Bytes::from_array([(input ^ 128).to_byte()])
      for next in [false, true] {
        let buffer = opt_header(version)
        let target = if next {
          @codec.write_node(buffer, true, 13UL, [])
        } else {
          0
        }
        let root = @codec.write_node(buffer, false, 0UL, [
          { input: byte, output: if next { 0UL } else { 13UL }, addr: target, },
        ])
        let data = opt_finish(buffer, version, root, 1UL)
        @debug.assert_eq(
          data[root].to_int() & 192,
          if next {
            192
          } else {
            128
          },
        )
        opt_check(data, [{ key, value: 13UL, }], [
          b"",
          key,
          wrong,
          opt_append(key, b'\x00'),
        ])
      }
    }
  }
}

///|
test "optimized lookup single packed widths one through eight and zero outputs" {
  for version in [1UL, 2UL, 3UL] {
    for tsize = 1; tsize <= 8; tsize = tsize + 1 {
      for osize = 0; osize <= 8; osize = osize + 1 {
        let value = if osize == 0 {
          0UL
        } else if osize == 8 {
          0xfffffffffffffff8UL
        } else {
          (1UL << (osize * 8)) - 1UL
        }
        for common in [false, true] {
          let buffer = opt_header(version)
          let child = opt_general(buffer, version, true, 7UL, [], 0, 1)
          let input = if common { b't' } else { b'\xff' }
          let root = opt_single(
            buffer, input, common, child, value, tsize, osize,
          )
          let key = Bytes::from_array([input])
          opt_check(
            opt_finish(buffer, version, root, 1UL),
            [{ key, value: value + 7UL, }],
            [b"", key, b"\x00", opt_append(key, b'\x00')],
          )
          // The all-zero delta is an implicit final target even when stored
          // in eight bytes; it must not be subtracted from this node's start.
          let direct = opt_header(version)
          let root = opt_single(direct, input, common, 0, value, tsize, osize)
          opt_check(opt_finish(direct, version, root, 1UL), [{ key, value, }], [
            b"",
            key,
            opt_append(key, b'\xff'),
          ])
        }
      }
    }
  }
}

///|
test "optimized lookup general packed widths and final prefix output are independent" {
  for version in [1UL, 2UL, 3UL] {
    for tsize = 1; tsize <= 8; tsize = tsize + 1 {
      for osize = 0; osize <= 8; osize = osize + 1 {
        let value = if osize == 0 {
          0UL
        } else if osize == 8 {
          0xfffffffffffffff8UL
        } else {
          (1UL << (osize * 8)) - 1UL
        }
        let buffer = opt_header(version)
        let child = opt_general(buffer, version, true, 7UL, [], 0, 1)
        let root = opt_general(
          buffer,
          version,
          true,
          value,
          [
            { input: b'\x00', output: value, addr: child, },
            { input: b'\xff', output: value, addr: 0, },
          ],
          tsize,
          osize,
        )
        opt_check(
          opt_finish(buffer, version, root, 3UL),
          [
            { key: b"", value, },
            { key: b"\x00", value: value + 7UL, },
            { key: b"\xff", value, },
          ],
          [b"", b"\x00", b"\x01", b"\x80", b"\xff", b"\x00\x00", b"\xff\xff"],
        )
      }
    }
  }
}

///|
test "optimized lookup fanout index thresholds and ordinal 255 in all versions" {
  for version in [1UL, 2UL, 3UL] {
    for count in [31, 32, 33, 63, 64, 255, 256] {
      let expected : Array[Entry] = []
      let edges : Array[@codec.Transition] = []
      for i = 0; i < count; i = i + 1 {
        let input = if count == 255 {
          if i < 128 {
            i
          } else {
            i + 1
          }
        } else if count <= 33 {
          i * 7
        } else {
          i
        }
        let value = if input == 0 {
          0xffffffffffffffffUL
        } else {
          input.to_uint64() * 1000000007UL
        }
        let key = Bytes::from_array([input.to_byte()])
        expected.push({ key, value, })
        edges.push({ input: input.to_byte(), output: value, addr: 0, })
      }
      let queries = [b"", b"\x00\x00", b"\xff\x00", b"\xff\xff"]
      for input = 0; input < 256; input = input + 1 {
        queries.push(Bytes::from_array([input.to_byte()]))
      }
      for is_final in [false, true] {
        let buffer = opt_header(version)
        let root = opt_general(
          buffer,
          version,
          is_final,
          if is_final {
            7UL
          } else {
            0UL
          },
          edges,
          1,
          8,
        )
        let records = expected.copy()
        if is_final {
          records.push({ key: b"", value: 7UL, })
        }
        opt_check(
          opt_finish(buffer, version, root, records.length().to_uint64()),
          records,
          queries,
        )
      }
    }
  }
}

///|
test "optimized lookup missing index entries accept every out-of-range ordinal" {
  for version in [2UL, 3UL] {
    let buffer = opt_header(version)
    let edges = Array::makei(33, fn(i) {
      @codec.Transition::{ input: i.to_byte(), output: i.to_uint64(), addr: 0, }
    })
    let root = opt_general(buffer, version, true, 42UL, edges, 1, 1)
    let index_start = root - 1 - 256
    for input = 33; input < 256; input = input + 1 {
      // The format accepts any ordinal >= count for a missing input.
      buffer[index_start + input] = (33 + (input - 33) % 223).to_byte()
    }
    let expected = [Entry::{ key: b"", value: 42UL, }]
    let queries = [b""]
    for input = 0; input < 256; input = input + 1 {
      let key = Bytes::from_array([input.to_byte()])
      queries.push(key)
      if input < 33 {
        expected.push({ key, value: input.to_uint64(), })
      }
    }
    opt_check(opt_finish(buffer, version, root, 34UL), expected, queries)
  }
}

///|
test "optimized lookup distinguishes final prefixes interior states and raw bytes" {
  let keys = [
    b"", b"\x00", b"\x00\x00", b"\x00\xff", b"a", b"aa", b"ab", b"abc", b"ab\xff",
    b"\x80", b"\xc0\x80", b"\xff", b"\xff\x00", b"\xff\xff",
  ]
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
  let map = FstMap::from_sorted(entries)
  let queries = keys.copy()
  for key in keys {
    queries.push(opt_append(key, b'\x00'))
    queries.push(opt_append(key, b'\xff'))
  }
  queries.append([b"b", b"ac", b"\x7f", b"\xfe", b"\xc0"])
  opt_check(map.to_bytes(), entries, queries)
  for query in queries {
    @debug.assert_eq(map.get(query), opt_array_get(entries, query))
  }
}

///|
test "optimized lookup deep unary graph consumes exactly the key bytes" {
  let key = Bytes::makei(4096, fn(i) { if i % 5 == 0 { b'\xff' } else { b'a' } })
  let buffer = @codec.begin(0UL)
  let mut root = 0
  for i = key.length() - 1; i >= 0; i = i - 1 {
    root = @codec.write_node(buffer, false, 0UL, [
      {
        input: key[i],
        output: if i == key.length() - 1 {
          0xffffffffffffffffUL
        } else {
          0UL
        },
        addr: root,
      },
    ])
  }
  let queries = [
    b"",
    key,
    key.exact_view(end=4095).to_owned(),
    opt_append(key, b'\x00'),
  ]
  for position in [0, 2048, 4095] {
    let wrong = key.to_array()
    wrong[position] = wrong[position] ^ b'\x01'
    queries.push(Bytes::from_array(wrong))
  }
  opt_check(
    @codec.finish(buffer, root~, len=1UL),
    [{ key, value: 0xffffffffffffffffUL, }],
    queries,
  )
}

///|
test "optimized lookup deterministic dictionaries agree with independent array truth" {
  let mut seed = 0xf17e9a23U
  for dataset = 0; dataset < 16; dataset = dataset + 1 {
    let entries : Array[Entry] = []
    for row = 0; row < 96; row = row + 1 {
      seed = seed * 1664525U + 1013904223U
      let length = (seed >> 24).reinterpret_as_int() % 17
      let bytes : Array[Byte] = []
      for i = 0; i < length; i = i + 1 {
        seed = seed * 1664525U + 1013904223U
        bytes.push((seed >> 24).to_byte())
      }
      let key = Bytes::from_array(bytes)
      seed = seed * 1664525U + 1013904223U
      let high = seed.to_uint64()
      seed = seed * 1664525U + 1013904223U
      let value = if row % 13 == 0 {
        0UL
      } else if row % 17 == 0 {
        0xffffffffffffffffUL
      } else {
        (high << 32) | seed.to_uint64()
      }
      if opt_array_get(entries, key) is None {
        entries.push({ key, value, })
      }
    }
    entries.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
    let map = FstMap::from_sorted(entries, registry_capacity=dataset % 5)
    let queries = [b"", b"\x00", b"\xff"]
    for entry in entries {
      queries.push(entry.key)
      queries.push(opt_append(entry.key, b'\x00'))
      queries.push(opt_append(entry.key, b'\xff'))
      if !entry.key.is_empty() {
        queries.push(
          entry.key.exact_view(end=entry.key.length() - 1).to_owned(),
        )
      }
    }
    for _query = 0; _query < 32; _query = _query + 1 {
      seed = seed * 1664525U + 1013904223U
      queries.push(
        Bytes::from_array([(seed >> 24).to_byte(), (seed >> 8).to_byte()]),
      )
    }
    opt_check(map.to_bytes(), entries, queries)
  }
}

///|
test "optimized lookup still requires complete load validation" {
  let buffer = opt_header(3UL)
  let edges = Array::makei(33, fn(i) {
    @codec.Transition::{ input: i.to_byte(), output: i.to_uint64(), addr: 0, }
  })
  let root = opt_general(buffer, 3UL, false, 0UL, edges, 1, 1)
  let valid = opt_finish(buffer, 3UL, root, 33UL)
  // This indexed root has an inline count, so its index starts at root-257.
  let invalid = valid.to_array()
  invalid[root - 1 - 256] = b'\x01'
  let crc_at = invalid.length() - 4
  let crc = @codec.masked_crc32c(Bytes::makei(crc_at, fn(i) { invalid[i] }))
  for i = 0; i < 4; i = i + 1 {
    invalid[crc_at + i] = (crc >> (8 * i)).to_byte()
  }
  try Fst::from_bytes(Bytes::from_array(invalid)) catch {
    InvalidFormat(_) => ()
    _ => fail("unexpected malformed-load error")
  } noraise {
    _ => fail("malformed index was exposed to the optimized reader")
  }
}
