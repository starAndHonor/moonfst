///|
/// The private packed reader is used only with an immutable, fully verified
/// Fst. Every packed field lies in the node region and has width 0..8. A valid
/// file has at least 16 footer bytes after that region, so the 8-byte read is
/// within the original Bytes even when the field is narrower. Masking discards
/// adjacent fields. No caller may pass unvalidated data to these helpers.
#inline
fn packed_read(data : Bytes, at : Int32, size : Int32) -> UInt64 {
  if size == 0 {
    0UL
  } else {
    let shift = (8 - size) * 8
    data.unsafe_read_uint64_le(at) << shift >> shift
  }
}

///|
/// The common-input alphabet is part of the fst format, not a key cache.
let packed_common_inputs : Bytes = b"te/oasripcnw.hlm-du012g=:bf3y5&_4v9678k%?xCDASFIBEjPTzRNM+LOqHG"

///|
/// Traverse only selected edges of an immutable, verified graph. All address,
/// width, input-index and output-sum invariants are established by from_bytes.
/// This routine allocates no Node/Transition arrays and retains no key cache.
fn packed_lookup(fst : Fst, key : Bytes) -> UInt64? raise FstError {
  let data = fst.data
  let indexed = fst.header.version >= 2UL
  let length = key.length()
  let mut address = fst.header.root
  let mut output = 0UL
  for position = 0; position < length; position = position + 1 {
    if address == 0 {
      return None
    }
    let state = data.unsafe_get(address).to_int()
    let input = key.unsafe_get(position)
    if (state & 128) != 0 {
      // Keep these scalars in the loop: a tuple-returning helper allocates on
      // the native backend even when the helper carries an inline hint.
      let rank = state & 63
      let input_size = if rank == 0 { 1 } else { 0 }
      let label = if rank == 0 {
        data.unsafe_get(address - 1)
      } else {
        packed_common_inputs.unsafe_get(rank - 1)
      }
      if label != input {
        return None
      }
      if (state & 64) != 0 {
        address = address - input_size - 1
      } else {
        let sizes_at = address - input_size - 1
        let sizes = data.unsafe_get(sizes_at).to_int()
        let tsize = sizes >> 4
        let osize = sizes & 15
        let start = sizes_at - tsize - osize
        output = output + packed_read(data, start, osize)
        let delta = packed_read(data, start + osize, tsize).to_int()
        address = if delta == 0 { 0 } else { start - delta }
      }
    } else {
      let inline_count = state & 63
      let count_size = if inline_count == 0 { 1 } else { 0 }
      let count = if inline_count == 0 {
        let count = data.unsafe_get(address - 1).to_int()
        if count == 1 {
          256
        } else {
          count
        }
      } else {
        inline_count
      }
      let sizes_at = address - count_size - 1
      let index_size = if indexed && count > 32 { 256 } else { 0 }
      let inputs_end = sizes_at - index_size
      let selected = if index_size != 0 {
        let index = data.unsafe_get(inputs_end + input.to_int()).to_int()
        if index >= count {
          return None
        }
        index
      } else {
        let index = packed_find_input(data, inputs_end, count, input)
        if index < 0 {
          return None
        }
        index
      }
      let sizes = data.unsafe_get(sizes_at).to_int()
      let tsize = sizes >> 4
      let osize = sizes & 15
      let deltas_end = inputs_end - count
      let outputs_end = deltas_end - count * tsize
      let start = outputs_end -
        count * osize -
        (if (state & 64) != 0 { osize } else { 0 })
      output = output +
        packed_read(data, outputs_end - (selected + 1) * osize, osize)
      let delta = packed_read(data, deltas_end - (selected + 1) * tsize, tsize).to_int()
      address = if delta == 0 { 0 } else { start - delta }
    }
  }
  if address == 0 {
    return Some(output)
  }
  let state = data.unsafe_get(address).to_int()
  if (state & 128) != 0 || (state & 64) == 0 {
    return None
  }
  let inline_count = state & 63
  let count_size = if inline_count == 0 { 1 } else { 0 }
  let count = if inline_count == 0 {
    let count = data.unsafe_get(address - 1).to_int()
    if count == 1 {
      256
    } else {
      count
    }
  } else {
    inline_count
  }
  let sizes_at = address - count_size - 1
  let sizes = data.unsafe_get(sizes_at).to_int()
  let tsize = sizes >> 4
  let osize = sizes & 15
  let index_size = if indexed && count > 32 { 256 } else { 0 }
  let start = sizes_at -
    index_size -
    count -
    count * tsize -
    (count + 1) * osize
  Some(checked_add(output, packed_read(data, start, osize)))
}

///|
/// Input labels are stored in descending order immediately before inputs_end.
/// For small nodes compare eight labels per word with no heap objects. Reading
/// a short tail is safe for the same verified-file/footer reason as packed_read;
/// a match beyond count is rejected. Large unindexed v1 nodes use binary search.
fn packed_find_input(
  data : Bytes,
  inputs_end : Int32,
  count : Int32,
  input : Byte,
) -> Int32 {
  if count <= 32 {
    let repeated = input.to_uint64() * 0x0101010101010101UL
    let start = inputs_end - count
    let mut offset = 0
    while offset < count {
      let word = data.unsafe_read_uint64_le(start + offset) ^ repeated
      // The low set bit identifies the first zero byte. Subtraction may also
      // flag a following 0x01 through borrow, but never an earlier byte.
      let matches = (word - 0x0101010101010101UL) &
        word.lnot() &
        0x8080808080808080UL
      if matches != 0UL {
        let found = offset + (matches.ctz() >> 3)
        return if found < count { count - found - 1 } else { -1 }
      }
      offset = offset + 8
    }
    -1
  } else {
    let mut low = 0
    let mut high = count
    while low < high {
      let middle = low + (high - low) / 2
      if data.unsafe_get(inputs_end - middle - 1) < input {
        low = middle + 1
      } else {
        high = middle
      }
    }
    if low < count && data.unsafe_get(inputs_end - low - 1) == input {
      low
    } else {
      -1
    }
  }
}
