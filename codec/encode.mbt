///|
/// Starts a version 3 FST. The type tag is opaque to the raw format.
pub fn begin(fst_type : UInt64) -> Array[Byte] {
  let buffer : Array[Byte] = []
  pack(buffer, 3UL, 8)
  pack(buffer, fst_type, 8)
  buffer
}

///|
/// Packed widths are 1..8; clz selects nonzero widths without a byte loop.
fn encoded_width(value : UInt64) -> Int32 {
  if value == 0UL {
    pack_size(value)
  } else {
    (71 - value.clz()) >> 3
  }
}

///|
/// Callers reserve the complete node before writing. Every at..at+size range
/// is inside that reserved region, with size bounded by the packed width.
fn write_packed_at(
  buffer : Array[Byte],
  at : Int32,
  value : UInt64,
  size : Int32,
) -> Unit {
  for i = 0; i < size; i = i + 1 {
    buffer.unsafe_set(at + i, (value >> (8 * i)).to_byte())
  }
}

///|
fn reserve_node(buffer : Array[Byte], start : Int32, size : Int32) -> Unit {
  let end = start + size
  if end < start {
    abort("fst exceeds supported address space")
  }
  // Array::resize grows to the exact requested length. Reserve geometrically
  // first so that appending many small nodes retains amortized linear copying.
  let capacity = buffer.capacity()
  if end > capacity {
    let doubled = if capacity <= 1073741823 { capacity * 2 } else { end }
    buffer.reserve_capacity(Int32::max(16, Int32::max(end, doubled)))
  }
  buffer.resize(end, b'\x00')
}

///|
fn delta_value(start : Int32, target : Int32) -> UInt64 {
  if target == 0 {
    0UL
  } else {
    (start - target).to_uint64()
  }
}

///|
fn write_one(buffer : Array[Byte], transition : Transition) -> Int32 {
  let start = buffer.length()
  let common = common_index(transition.input)
  if transition.addr > 0 &&
    transition.addr == start - 1 &&
    transition.output == 0UL {
    let explicit = if common == 0 { 1 } else { 0 }
    reserve_node(buffer, start, explicit + 1)
    if common == 0 {
      buffer.unsafe_set(start, transition.input)
    }
    buffer.unsafe_set(start + explicit, (192 | common).to_byte())
  } else {
    let delta = delta_value(start, transition.addr)
    let tsize = encoded_width(delta)
    let osize = if transition.output == 0UL {
      0
    } else {
      encoded_width(transition.output)
    }
    let explicit = if common == 0 { 1 } else { 0 }
    reserve_node(buffer, start, osize + tsize + explicit + 2)
    write_packed_at(buffer, start, transition.output, osize)
    write_packed_at(buffer, start + osize, delta, tsize)
    let sizes_at = start + osize + tsize
    buffer.unsafe_set(sizes_at, ((tsize << 4) | osize).to_byte())
    if common == 0 {
      buffer.unsafe_set(sizes_at + 1, transition.input)
    }
    buffer.unsafe_set(sizes_at + explicit + 1, (128 | common).to_byte())
  }
  buffer.length() - 1
}

///|
fn write_any(
  buffer : Array[Byte],
  is_final : Bool,
  final_output : UInt64,
  transitions : Array[Transition],
) -> Int32 {
  let start = buffer.length()
  let ntrans = transitions.length()
  let mut tsize = 0
  let mut osize = if final_output == 0UL {
    0
  } else {
    encoded_width(final_output)
  }
  for transition in transitions {
    tsize = Int32::max(
      tsize,
      encoded_width(delta_value(start, transition.addr)),
    )
    if transition.output != 0UL {
      osize = Int32::max(osize, encoded_width(transition.output))
    }
  }
  let count = if ntrans > 0 && ntrans <= 63 { ntrans } else { 0 }
  let index_size = if ntrans > 32 { 256 } else { 0 }
  let final_size = if is_final { osize } else { 0 }
  let count_size = if count == 0 { 1 } else { 0 }
  reserve_node(
    buffer,
    start,
    final_size + ntrans * (osize + tsize + 1) + index_size + count_size + 2,
  )
  let mut at = start
  if osize > 0 {
    if is_final {
      write_packed_at(buffer, at, final_output, osize)
      at = at + osize
    }
    for i = ntrans - 1; i >= 0; i = i - 1 {
      write_packed_at(buffer, at, transitions[i].output, osize)
      at = at + osize
    }
  }
  for i = ntrans - 1; i >= 0; i = i - 1 {
    write_packed_at(buffer, at, delta_value(start, transitions[i].addr), tsize)
    at = at + tsize
  }
  for i = ntrans - 1; i >= 0; i = i - 1 {
    buffer.unsafe_set(at, transitions[i].input)
    at = at + 1
  }
  if ntrans > 32 {
    for i = 0; i < 256; i = i + 1 {
      buffer.unsafe_set(at + i, b'\xff')
    }
    for i = 0; i < ntrans; i = i + 1 {
      buffer.unsafe_set(at + transitions[i].input.to_int(), i.to_byte())
    }
    at = at + 256
  }
  buffer.unsafe_set(at, ((tsize << 4) | osize).to_byte())
  at = at + 1
  if count == 0 {
    buffer.unsafe_set(at, (if ntrans == 256 { 1 } else { ntrans }).to_byte())
    at = at + 1
  }
  buffer.unsafe_set(at, ((if is_final { 64 } else { 0 }) | count).to_byte())
  buffer.length() - 1
}

///|
/// Appends one node, selecting implicit-final, one-transition-next,
/// one-transition, or general encoding. Inputs must be sorted and unique;
/// targets must already have been written, or be the implicit address zero.
pub fn write_node(
  buffer : Array[Byte],
  is_final : Bool,
  final_output : UInt64,
  transitions : Array[Transition],
) -> Int32 {
  if buffer.length() < 16 {
    abort("missing fst header")
  }
  if transitions.length() > 256 {
    abort("too many transitions")
  }
  if !is_final && final_output != 0UL {
    abort("non-final output")
  }
  let mut previous = -1
  for transition in transitions {
    if transition.input.to_int() <= previous {
      abort("unordered transitions")
    }
    if transition.addr != 0 &&
      (transition.addr < 16 || transition.addr >= buffer.length()) {
      abort("invalid transition target")
    }
    previous = transition.input.to_int()
  }
  if is_final && final_output == 0UL && transitions.is_empty() {
    0
  } else if !is_final && transitions.length() == 1 {
    write_one(buffer, transitions[0])
  } else {
    write_any(buffer, is_final, final_output, transitions)
  }
}

///|
/// Appends key count, root address, and masked CRC32C, returning owned bytes.
pub fn finish(buffer : Array[Byte], root~ : Int32, len~ : UInt64) -> Bytes {
  if !((root == 0 && buffer.length() == 16) ||
    (root == buffer.length() - 1 && root >= 16)) {
    abort("root must be the last node written")
  }
  let start = buffer.length()
  reserve_node(buffer, start, 16)
  write_packed_at(buffer, start, len, 8)
  write_packed_at(buffer, start + 8, root.to_uint64(), 8)
  // Compute the checksum directly over the array instead of first copying the
  // complete FST to a temporary Bytes. Only the final owned result is copied.
  let mut crc = 0xffffffffU
  for byte in buffer {
    let index = ((crc ^ byte.to_uint()) & 255U).reinterpret_as_int()
    crc = crc_table[index] ^ (crc >> 8)
  }
  crc = crc.lnot()
  let checksum = ((crc >> 15) | (crc << 17)) + 0xa282ead8U
  reserve_node(buffer, start + 16, 4)
  write_packed_at(buffer, start + 16, checksum.to_uint64(), 4)
  Bytes::from_array(buffer[:])
}
