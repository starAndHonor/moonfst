///|
fn unpack(data : Bytes, at : Int32, size : Int32) -> UInt64 raise CodecError {
  if size < 0 || size > 8 || at < 0 || at > data.length() - size {
    raise InvalidFormat("packed integer exceeds byte bounds")
  }
  let mut value = 0UL
  for i = 0; i < size; i = i + 1 {
    value = value | (data[at + i].to_uint64() << (8 * i))
  }
  value
}

///|
fn pack_size(value : UInt64) -> Int32 {
  let mut rest = value >> 8
  let mut size = 1
  while rest != 0UL {
    size = size + 1
    rest = rest >> 8
  }
  size
}

///|
fn pack(buffer : Array[Byte], value : UInt64, size : Int32) -> Unit {
  for i = 0; i < size; i = i + 1 {
    buffer.push((value >> (8 * i)).to_byte())
  }
}

///|
fn checked_add(
  a : UInt64,
  b : UInt64,
  what : String,
) -> UInt64 raise CodecError {
  if 0xffffffffffffffffUL - a < b {
    raise InvalidFormat(what)
  }
  a + b
}

///|
fn footer_start(data : Bytes, version : UInt64) -> Int32 raise CodecError {
  if version < 1UL || version > 3UL {
    raise InvalidFormat("unsupported format version")
  }
  let footer_size = if version >= 3UL { 20 } else { 16 }
  if data.length() < 16 + footer_size {
    raise InvalidFormat("truncated header or footer")
  }
  data.length() - footer_size
}

///|
/// Reads metadata for Rust fst versions 1, 2, and 3. This validates offsets;
/// call `verify` as well to validate the graph, path outputs, and checksum.
pub fn read_header(data : Bytes) -> Header raise CodecError {
  if data.length() < 16 {
    raise InvalidFormat("truncated header")
  }
  let version = unpack(data, 0, 8)
  let stop = footer_start(data, version)
  let fst_type = unpack(data, 8, 8)
  let len = unpack(data, stop, 8)
  let root64 = unpack(data, stop + 8, 8)
  if root64 > 0x7fffffffUL {
    raise InvalidFormat("root address exceeds supported address space")
  }
  let root = root64.to_int()
  if root == 0 {
    if stop != 16 {
      raise InvalidFormat("implicit final root has stored node bytes")
    }
  } else if root < 16 || root != stop - 1 {
    raise InvalidFormat("root is not the last stored node")
  }
  { version, fst_type, len, root, }
}
