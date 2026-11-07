// Castagnoli polynomial, reflected representation. A single-byte table avoids
// platform-specific SIMD and the large generated slice-by-16 upstream table.

///|
let crc_table : Array[UInt32] = Array::makei(256, fn(i) {
  let mut value = i.reinterpret_as_uint()
  for bit = 0; bit < 8; bit = bit + 1 {
    value = if (value & 1U) == 1U {
      (value >> 1) ^ 0x82f63b78U
    } else {
      value >> 1
    }
  }
  value
})

///|
/// Standard CRC32C, initialized and finalized with all bits inverted.
pub fn crc32c(data : Bytes) -> UInt32 {
  crc_prefix(data, data.length())
}

///|
fn crc_prefix(data : Bytes, end : Int32) -> UInt32 {
  let mut crc = 0xffffffffU
  for i = 0; i < end; i = i + 1 {
    let b = data[i]
    let index = ((crc ^ b.to_uint()) & 255U).reinterpret_as_int()
    crc = crc_table[index] ^ (crc >> 8)
  }
  crc.lnot()
}

///|
/// Snappy's masked CRC32C, as stored in the version 3 fst footer.
pub fn masked_crc32c(data : Bytes) -> UInt32 {
  let crc = crc32c(data)
  ((crc >> 15) | (crc << 17)) + 0xa282ead8U
}

///|
fn masked_crc_prefix(data : Bytes, end : Int32) -> UInt32 {
  let crc = crc_prefix(data, end)
  ((crc >> 15) | (crc << 17)) + 0xa282ead8U
}
