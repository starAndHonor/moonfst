///|
/// Private cursor over an already fully verified FST. General-node fields are
/// byte offsets, so visiting a node never allocates its transition array. The
/// single-edge representation stores its input and packed-field positions.
#valtype
priv struct TraversalNode {
  count : Int32
  is_final : Bool
  final_output : UInt64
  single_input : Int32
  start : Int32
  inputs_end : Int32
  tsize : Int32
  osize : Int32
}

///|
/// Fst construction has verified all offsets, widths, backward addresses,
/// transition ordering, indexed labels and complete path outputs. Keep this
/// helper private: the public codec reader retains its strict decoding checks.
fn traversal_node(fst : Fst, address : Int32) -> TraversalNode {
  if address == 0 {
    return {
      count: 0,
      is_final: true,
      final_output: 0UL,
      single_input: -1,
      start: 0,
      inputs_end: 0,
      tsize: 0,
      osize: 0,
    }
  }
  let data = fst.data
  let state = data.unsafe_get(address).to_int()
  if (state & 128) != 0 {
    let rank = state & 63
    let input_size = if rank == 0 { 1 } else { 0 }
    let input = if rank == 0 {
      data.unsafe_get(address - 1)
    } else {
      packed_common_inputs.unsafe_get(rank - 1)
    }
    let mut start = address - input_size - 1
    let mut tsize = 0
    let mut osize = 0
    if (state & 64) == 0 {
      let sizes_at = address - input_size - 1
      let sizes = data.unsafe_get(sizes_at).to_int()
      tsize = sizes >> 4
      osize = sizes & 15
      start = sizes_at - tsize - osize
    }
    return {
      count: 1,
      is_final: false,
      final_output: 0UL,
      single_input: input.to_int(),
      // Width zero distinguishes one-next: start then holds its child address.
      start,
      inputs_end: 0,
      tsize,
      osize,
    }
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
  let is_final = (state & 64) != 0
  let index_size = if fst.header.version >= 2UL && count > 32 { 256 } else { 0 }
  let inputs_end = sizes_at - index_size
  let deltas_end = inputs_end - count
  let outputs_end = deltas_end - count * tsize
  let start = outputs_end - count * osize - (if is_final { osize } else { 0 })
  {
    count,
    is_final,
    final_output: if is_final {
      packed_read(data, start, osize)
    } else {
      0UL
    },
    single_input: -1,
    start,
    inputs_end,
    tsize,
    osize,
  }
}

///|
#inline
fn traversal_edge_input(data : Bytes, node : TraversalNode, at : Int32) -> Byte {
  if node.single_input >= 0 {
    node.single_input.to_byte()
  } else {
    data.unsafe_get(node.inputs_end - at - 1)
  }
}

///|
#inline
fn traversal_edge_output(
  data : Bytes,
  node : TraversalNode,
  at : Int32,
) -> UInt64 {
  if node.single_input >= 0 {
    packed_read(data, node.start, node.osize)
  } else {
    let outputs_end = node.inputs_end - node.count * (1 + node.tsize)
    packed_read(data, outputs_end - (at + 1) * node.osize, node.osize)
  }
}

///|
#inline
fn traversal_edge_address(
  data : Bytes,
  node : TraversalNode,
  at : Int32,
) -> Int32 {
  if node.single_input >= 0 {
    if node.tsize == 0 {
      node.start
    } else {
      let delta = packed_read(data, node.start + node.osize, node.tsize)
      if delta == 0UL {
        0
      } else {
        node.start - delta.to_int()
      }
    }
  } else {
    let delta = packed_read(
      data,
      node.inputs_end - node.count - (at + 1) * node.tsize,
      node.tsize,
    )
    if delta == 0UL {
      0
    } else {
      node.start - delta.to_int()
    }
  }
}

///|
/// Relation of the consumed path to the equally long prefix of this bound.
/// Zero means all bytes compared so far match; it does not yet mean the whole
/// key equals the bound. A nonzero relation can never change on extension.
#inline
fn Bound::extend_order(
  self : Bound,
  order : Int32,
  position : Int32,
  input : Byte,
) -> Int32 {
  match self {
    Unbounded => 0
    Included(bound) | Excluded(bound) =>
      if order != 0 {
        order
      } else if position >= bound.length() {
        1
      } else if input < bound[position] {
        -1
      } else if input > bound[position] {
        1
      } else {
        0
      }
  }
}

///|
/// Resolve a matching prefix using length only when a complete key is visited.
fn KeyRange::contains_orders(
  self : KeyRange,
  lower_order : Int32,
  upper_order : Int32,
  length : Int32,
) -> Bool {
  let lower = match self.lower {
    Unbounded => true
    Included(bound) =>
      lower_order > 0 || (lower_order == 0 && length == bound.length())
    Excluded(_) => lower_order > 0
  }
  if !lower {
    return false
  }
  match self.upper {
    Unbounded => true
    Included(_) => upper_order <= 0
    Excluded(bound) =>
      upper_order < 0 || (upper_order == 0 && length < bound.length())
  }
}
