// The first 63 entries of fst's COMMON_INPUTS_INV are sufficient: a common
// byte is stored as its one-based rank in the low six bits of the state byte.

///|
let common_inputs : Bytes = b"te/oasripcnw.hlm-du012g=:bf3y5&_4v9678k%?xCDASFIBEjPTzRNM+LOqHG"

///|
/// Invert the format's fixed alphabet once, rather than scanning 63 bytes for
/// every single-edge node. This is a 256-byte format table, independent of keys.
let common_ranks : FixedArray[Byte] = {
  let ranks = FixedArray::make(256, b'\x00')
  for i = 0; i < common_inputs.length(); i = i + 1 {
    ranks[common_inputs[i].to_int()] = (i + 1).to_byte()
  }
  ranks
}

///|
fn common_index(input : Byte) -> Int32 {
  // Every Byte is in 0..255, within the fixed rank table.
  common_ranks.unsafe_get(input.to_int()).to_int()
}

///|
fn state_input(
  data : Bytes,
  address : Int32,
  state : Int32,
) -> (Byte, Int32) raise CodecError {
  let index = state & 63
  if index == 0 {
    if address < 17 {
      raise InvalidFormat("missing explicit transition input")
    }
    (data[address - 1], 1)
  } else {
    (common_inputs[index - 1], 0)
  }
}
