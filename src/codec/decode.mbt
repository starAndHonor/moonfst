///|
/// Checks the packed address relative to the first byte of this node. A zero
/// delta is reserved for the implicit empty final state, not a self-loop.
fn decode_delta(
  data : Bytes,
  at : Int32,
  size : Int32,
  start : Int32,
) -> Int32 raise CodecError {
  let delta = unpack(data, at, size)
  if delta == 0UL {
    return 0
  }
  if delta > start.to_uint64() {
    raise InvalidFormat("transition address underflow")
  }
  let target = start - delta.to_int()
  if target < 16 || target >= start {
    raise InvalidFormat("transition does not target an earlier node")
  }
  target
}

///|
fn decode_one(
  data : Bytes,
  address : Int32,
  state : Int32,
) -> Decoded raise CodecError {
  let (input, input_size) = state_input(data, address, state)
  if (state & 64) != 0 {
    let start = address - input_size
    let target = start - 1
    if target < 16 {
      raise InvalidFormat("next-node transition targets header")
    }
    return {
      node: {
        address,
        is_final: false,
        final_output: 0UL,
        transitions: [{ input, output: 0UL, addr: target, }],
      },
      start,
    }
  }
  let sizes_at = address - input_size - 1
  if sizes_at < 16 {
    raise InvalidFormat("missing packed widths")
  }
  let sizes = data[sizes_at].to_int()
  let tsize = sizes >> 4
  let osize = sizes & 15
  if tsize < 1 || tsize > 8 || osize > 8 {
    raise InvalidFormat("invalid single-transition packed width")
  }
  let start = sizes_at - tsize - osize
  if start < 16 {
    raise InvalidFormat("single-transition node overlaps header")
  }
  let output = unpack(data, start, osize)
  let addr = decode_delta(data, start + osize, tsize, start)
  {
    node: {
      address,
      is_final: false,
      final_output: 0UL,
      transitions: [{ input, output, addr, }],
    },
    start,
  }
}

///|
fn validate_index(
  data : Bytes,
  at : Int32,
  transitions : Array[Transition],
) -> Unit raise CodecError {
  let expected = Array::make(256, 255)
  for i = 0; i < transitions.length(); i = i + 1 {
    expected[transitions[i].input.to_int()] = i
  }
  for input = 0; input < 256; input = input + 1 {
    let actual = data[at + input].to_int()
    let wanted = expected[input]
    if wanted < transitions.length() {
      if actual != wanted {
        raise InvalidFormat("transition index disagrees with inputs")
      }
    } else if actual < transitions.length() {
      raise InvalidFormat("transition index contains a spurious transition")
    }
  }
}

///|
fn decode_any(
  data : Bytes,
  header : Header,
  address : Int32,
  state : Int32,
) -> Decoded raise CodecError {
  let inline_count = state & 63
  let count_size = if inline_count == 0 { 1 } else { 0 }
  if address - count_size - 1 < 16 {
    raise InvalidFormat("missing transition count or packed widths")
  }
  let ntrans = if inline_count == 0 {
    let count = data[address - 1].to_int()
    if count == 1 {
      256
    } else {
      count
    }
  } else {
    inline_count
  }
  let sizes_at = address - count_size - 1
  let sizes = data[sizes_at].to_int()
  let tsize = sizes >> 4
  let osize = sizes & 15
  if tsize > 8 || osize > 8 || (ntrans > 0 && tsize == 0) {
    raise InvalidFormat("invalid multi-transition packed width")
  }
  let is_final = (state & 64) != 0
  let index_size = if header.version >= 2UL && ntrans > 32 { 256 } else { 0 }
  let inputs_end = sizes_at - index_size
  let deltas_end = inputs_end - ntrans
  let outputs_end = deltas_end - ntrans * tsize
  let start = outputs_end - ntrans * osize - (if is_final { osize } else { 0 })
  if start < 16 {
    raise InvalidFormat("multi-transition node overlaps header")
  }
  let final_output = if is_final { unpack(data, start, osize) } else { 0UL }
  let transitions : Array[Transition] = []
  let mut previous = -1
  for i = 0; i < ntrans; i = i + 1 {
    let input = data[inputs_end - i - 1]
    if input.to_int() <= previous {
      raise InvalidFormat("transition inputs are not strictly increasing")
    }
    previous = input.to_int()
    let output = unpack(data, outputs_end - (i + 1) * osize, osize)
    let addr = decode_delta(data, deltas_end - (i + 1) * tsize, tsize, start)
    transitions.push({ input, output, addr, })
  }
  if index_size != 0 {
    validate_index(data, inputs_end, transitions)
  }
  { node: { address, is_final, final_output, transitions, }, start, }
}

///|
fn decode_node(
  data : Bytes,
  header : Header,
  address : Int32,
) -> Decoded raise CodecError {
  let stop = footer_start(data, header.version)
  if address == 0 {
    return {
      node: { address, is_final: true, final_output: 0UL, transitions: [], },
      start: 0,
    }
  }
  if address < 16 || address >= stop {
    raise InvalidFormat("node address outside node region")
  }
  let state = data[address].to_int()
  if (state & 128) != 0 {
    decode_one(data, address, state)
  } else {
    decode_any(data, header, address, state)
  }
}

///|
/// Safely decodes one node, including transition ordering and indexed input
/// consistency. `verify` additionally checks referenced nodes and whole paths.
pub fn read_node(
  data : Bytes,
  header : Header,
  address : Int32,
) -> Node raise CodecError {
  decode_node(data, header, address).node
}
