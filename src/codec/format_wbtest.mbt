///|
fn rejects(data : Bytes) -> Bool {
  try {
    verify(data)
    false
  } catch {
    InvalidFormat(_) => true
  }
}

///|
fn reseal(buffer : Array[Byte]) -> Bytes {
  let end = buffer.length() - 4
  let checksum = masked_crc32c(Bytes::makei(end, fn(i) { buffer[i] }))
  for i = 0; i < 4; i = i + 1 {
    buffer[end + i] = (checksum >> (8 * i)).to_byte()
  }
  Bytes::from_array(buffer[:])
}

///|
fn roundtrip_node(
  is_final : Bool,
  final_output : UInt64,
  transitions : Array[Transition],
) -> Node raise {
  let buffer = begin(0UL)
  let root = write_node(buffer, is_final, final_output, transitions)
  let count = transitions.length().to_uint64() +
    (if is_final { 1UL } else { 0UL })
  let data = finish(buffer, root~, len=count)
  verify(data)
  let node = read_node(data, read_header(data), root)
  @debug.assert_eq(node.is_final, is_final)
  @debug.assert_eq(node.final_output, final_output)
  @debug.assert_eq(node.transitions, transitions)
  node
}

///|
test "CRC32C standard vectors and Snappy masking" {
  @debug.assert_eq(crc32c(b""), 0U)
  @debug.assert_eq(crc32c(b"123456789"), 0xe3069283U)
  @debug.assert_eq(masked_crc32c(b""), 0xa282ead8U)
  @debug.assert_eq(masked_crc32c(b"123456789"), 0xc78ab0e5U)
}

///|
test "implicit final node and explicit empty-language root differ" {
  let final_data = finish(begin(9UL), root=0, len=1UL)
  verify(final_data)
  @debug.assert_eq(final_data.length(), 36)
  @debug.assert_eq(read_header(final_data), Header::{
    version: 3UL,
    fst_type: 9UL,
    len: 1UL,
    root: 0,
  })
  @debug.assert_eq(read_node(final_data, read_header(final_data), 0), Node::{
    address: 0,
    is_final: true,
    final_output: 0UL,
    transitions: [],
  })
  let empty = roundtrip_node(false, 0UL, [])
  @debug.assert_eq(empty.address, 18)
}

///|
test "all 256 inputs roundtrip through common and explicit single states" {
  @debug.assert_eq(common_inputs.length(), 63)
  for input = 0; input < 256; input = input + 1 {
    let buffer = begin(0UL)
    let root = write_node(buffer, false, 0UL, [
      { input: input.to_byte(), output: 0UL, addr: 0, },
    ])
    let common = common_index(input.to_byte())
    @debug.assert_eq(root, if common == 0 { 19 } else { 18 })
    let data = finish(buffer, root~, len=1UL)
    verify(data)
    let node = read_node(data, read_header(data), root)
    @debug.assert_eq(node.transitions[0].input, input.to_byte())
    @debug.assert_eq(node.transitions[0].addr, 0)
  }
}

///|
test "one-transition-next common and explicit states" {
  for input in [b'a', b'\xff'] {
    let buffer = begin(0UL)
    let child = write_node(buffer, true, 17UL, [])
    let root = write_node(buffer, false, 0UL, [
      { input, output: 0UL, addr: child, },
    ])
    let data = finish(buffer, root~, len=1UL)
    verify(data)
    @debug.assert_eq(data[root].to_int() & 192, 192)
    let node = read_node(data, read_header(data), root)
    @debug.assert_eq(node.transitions[0].addr, child)
    @debug.assert_eq(
      read_node(data, read_header(data), child).final_output,
      17UL,
    )
  }
}

///|
test "packed outputs cover all widths including UInt64 maximum" {
  for width = 1; width <= 8; width = width + 1 {
    let value = 1UL << (8 * width - 1)
    ignore(
      roundtrip_node(false, 0UL, [{ input: b'a', output: value, addr: 0, }]),
    )
    ignore(roundtrip_node(true, value, []))
  }
  ignore(
    roundtrip_node(false, 0UL, [
      { input: b'a', output: 0xffffffffffffffffUL, addr: 0, },
    ]),
  )
  ignore(roundtrip_node(true, 0xffffffffffffffffUL, []))
}

///|
test "transition cardinality boundaries and indexed nodes" {
  for count in [2, 31, 32, 33, 63, 64, 255, 256] {
    let transitions = Array::makei(count, fn(i) {
      Transition::{
        input: i.to_byte(),
        output: (i * 1000).to_uint64(),
        addr: 0,
      }
    })
    ignore(roundtrip_node(false, 0UL, transitions))
    ignore(roundtrip_node(true, 7UL, transitions))
  }
}

///|
test "packed integer helpers preserve every bit in all widths" {
  for width = 1; width <= 8; width = width + 1 {
    let value = if width == 8 {
      0xffffffffffffffffUL
    } else {
      (1UL << (width * 8)) - 1UL
    }
    let buffer : Array[Byte] = []
    pack(buffer, value, width)
    @debug.assert_eq(pack_size(value), width)
    @debug.assert_eq(unpack(Bytes::from_array(buffer[:]), 0, width), value)
  }
}

///|
test "every truncated prefix and checksum mutation is rejected" {
  let buffer = begin(0UL)
  let transitions = Array::makei(64, fn(i) {
    Transition::{ input: i.to_byte(), output: i.to_uint64(), addr: 0, }
  })
  let root = write_node(buffer, true, 77UL, transitions)
  let data = finish(buffer, root~, len=65UL)
  for prefix = 0; prefix < data.length(); prefix = prefix + 1 {
    assert_true(rejects(Bytes::makei(prefix, fn(i) { data[i] })))
  }
  for offset = 0; offset < data.length(); offset = offset + 1 {
    let modified = data.to_array()
    modified[offset] = modified[offset] ^ b'\x01'
    assert_true(rejects(Bytes::from_array(modified[:])))
  }
}

///|
test "malformed metadata is rejected even with a valid checksum" {
  let data = finish(begin(0UL), root=0, len=1UL)
  for offset in [0, 16, 24, 31] {
    let modified = data.to_array()
    modified[offset] = b'\xff'
    assert_true(rejects(reseal(modified)))
  }
}

///|
test "invalid packed widths and delta underflow are rejected" {
  let buffer = begin(0UL)
  let root = write_node(buffer, false, 0UL, [
    { input: b'a', output: 0UL, addr: 0, },
  ])
  let data = finish(buffer, root~, len=1UL)
  for width in [0, 0x90, 0x19, 0xff] {
    let modified = data.to_array()
    modified[17] = width.to_byte()
    assert_true(rejects(reseal(modified)))
  }
  let modified = data.to_array()
  modified[16] = b'\xff'
  assert_true(rejects(reseal(modified)))
}

///|
test "transition order and index are validated independently of checksum" {
  let buffer = begin(0UL)
  let transitions = Array::makei(33, fn(i) {
    Transition::{ input: i.to_byte(), output: 0UL, addr: 0, }
  })
  let root = write_node(buffer, false, 0UL, transitions)
  let data = finish(buffer, root~, len=33UL)
  let decoded = decode_node(data, read_header(data), root)
  let index_start = root - 1 - 256
  let bad_index = data.to_array()
  bad_index[index_start] = b'\x01'
  assert_true(rejects(reseal(bad_index)))
  let spurious = data.to_array()
  spurious[index_start + 255] = b'\x00'
  assert_true(rejects(reseal(spurious)))
  let duplicate = data.to_array()
  duplicate[decoded.start + 33] = duplicate[decoded.start + 34]
  assert_true(rejects(reseal(duplicate)))
}

///|
test "graph verification checks output overflow" {
  let buffer = begin(0UL)
  let leaf = write_node(buffer, true, 1UL, [])
  let root = write_node(buffer, false, 0UL, [
    { input: b'a', output: 0xffffffffffffffffUL, addr: leaf, },
  ])
  assert_true(rejects(finish(buffer, root~, len=1UL)))
}

///|
test "graph verification counts paths without expanding exponential keys" {
  let buffer = begin(0UL)
  let mut child = 0
  for _depth = 0; _depth < 64; _depth = _depth + 1 {
    child = write_node(buffer, false, 0UL, [
      { input: b'a', output: 0UL, addr: child, },
      { input: b'b', output: 0UL, addr: child, },
    ])
  }
  assert_true(rejects(finish(buffer, root=child, len=0UL)))
}

///|
test "untrusted read_node arguments never bypass region bounds" {
  let data = finish(begin(0UL), root=0, len=1UL)
  let header = read_header(data)
  for address in [-1, 1, 15, 16, 35, 0x7fffffff] {
    let rejected = try {
      ignore(read_node(data, header, address))
      false
    } catch {
      InvalidFormat(_) => true
    }
    assert_true(rejected)
  }
  let forged = Header::{ version: 99UL, fst_type: 0UL, len: 1UL, root: 0, }
  let rejected = try {
    ignore(read_node(data, forged, 0))
    false
  } catch {
    InvalidFormat(_) => true
  }
  assert_true(rejected)
}

///|
test "reachable node byte ranges may not overlap" {
  let buffer = begin(0UL)
  // The output's bytes 00 10 85 also happen to form a valid single-transition
  // node ending at 18. Both interpretations must not be reachable at once.
  let outer = write_node(buffer, true, 0x851000UL, [])
  let root = write_node(buffer, false, 0UL, [
    { input: b'a', output: 0UL, addr: outer, },
    { input: b'b', output: 0UL, addr: 18, },
  ])
  assert_true(rejects(finish(buffer, root~, len=2UL)))
}

///|
test "next-node compression cannot point into the header" {
  for tail in [[b'\xc5'], [b'\xff', b'\xc0']] {
    let buffer = begin(0UL)
    buffer.append(tail[:])
    let root = buffer.length() - 1
    assert_true(rejects(finish(buffer, root~, len=1UL)))
  }
}

///|
test "version 1 and 2 format differences are decoded" {
  for version in [1UL, 2UL] {
    let buffer : Array[Byte] = []
    pack(buffer, version, 8)
    pack(buffer, 0UL, 8)
    // 33 transitions to the implicit final node, in reverse storage order.
    for _i = 0; _i < 33; _i = _i + 1 {
      buffer.push(b'\x00')
    }
    for input = 32; input >= 0; input = input - 1 {
      buffer.push(input.to_byte())
    }
    if version >= 2UL {
      for input = 0; input < 256; input = input + 1 {
        buffer.push((if input < 33 { input } else { 255 }).to_byte())
      }
    }
    buffer.push(b'\x10')
    buffer.push(b'\x21')
    let root = buffer.length() - 1
    pack(buffer, 33UL, 8)
    pack(buffer, root.to_uint64(), 8)
    let data = Bytes::from_array(buffer[:])
    verify(data)
    @debug.assert_eq(
      read_node(data, read_header(data), root).transitions.length(),
      33,
    )
  }
}

///|
test "deep unary graphs verify without recursive traversal" {
  let buffer = begin(0UL)
  let mut child = 0
  for _depth = 0; _depth < 12000; _depth = _depth + 1 {
    child = write_node(buffer, false, 0UL, [
      { input: b'a', output: 0UL, addr: child, },
    ])
  }
  verify(finish(buffer, root=child, len=1UL))
}

///|
test "UInt64 maximum accepted-key count remains valid" {
  let buffer = begin(0UL)
  let mut child = write_node(buffer, false, 0UL, [])
  // count(next) = 1 + 2 * count(previous), starting at zero.
  for _depth = 0; _depth < 64; _depth = _depth + 1 {
    child = write_node(buffer, true, 0UL, [
      { input: b'a', output: 0UL, addr: child, },
      { input: b'b', output: 0UL, addr: child, },
    ])
  }
  verify(finish(buffer, root=child, len=0xffffffffffffffffUL))
}

///|
test "arbitrary checked node payloads never escape as host bounds traps" {
  let mut seed = 0x05f71a2bU
  for sample = 0; sample < 2048; sample = sample + 1 {
    let buffer = begin(0UL)
    let size = 1 + sample % 127
    for _byte = 0; _byte < size; _byte = _byte + 1 {
      seed = seed * 1664525U + 1013904223U
      buffer.push((seed >> 16).to_byte())
    }
    let root = buffer.length() - 1
    let data = finish(buffer, root~, len=0UL)
    verify(data) catch {
      InvalidFormat(_) => ()
    }
  }
}
