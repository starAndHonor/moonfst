///|
/// Validates every reachable node without recursive calls or key expansion.
/// Backward-only edges rule out cycles. Dynamic programming on addresses checks
/// the accepted-key count and every possible accumulated output for overflow.
pub fn verify(data : Bytes) -> Unit raise CodecError {
  let header = read_header(data)
  if header.version >= 3UL {
    let checksum_at = data.length() - 4
    let expected = unpack(data, checksum_at, 4).to_uint()
    let actual = masked_crc_prefix(data, checksum_at)
    if actual != expected {
      raise InvalidFormat("CRC32C checksum mismatch")
    }
  }
  let nodes : Map[Int32, Decoded] = Map([])
  let addresses : Array[Int32] = []
  let pending = [header.root]
  while !pending.is_empty() {
    let address = pending.pop().unwrap()
    if !nodes.contains(address) {
      let decoded = decode_node(data, header, address)
      nodes[address] = decoded
      addresses.push(address)
      for transition in decoded.node.transitions {
        pending.push(transition.addr)
      }
    }
  }
  addresses.sort()
  let totals : Map[Int32, (UInt64, UInt64)] = Map([])
  let mut previous_end = 15
  for address in addresses {
    let decoded = nodes[address]
    if address != 0 {
      if decoded.start <= previous_end {
        raise InvalidFormat("reachable node byte ranges overlap")
      }
      previous_end = address
    }
    let node = decoded.node
    let mut count = if node.is_final { 1UL } else { 0UL }
    let mut output = node.final_output
    for transition in node.transitions {
      let child = match totals.get(transition.addr) {
        Some(value) => value
        None => raise InvalidFormat("cyclic or missing transition target")
      }
      count = checked_add(count, child.0, "accepted key count overflows UInt64")
      let path_output = checked_add(
        transition.output,
        child.1,
        "path output overflows UInt64",
      )
      output = if output > path_output { output } else { path_output }
    }
    totals[address] = (count, output)
  }
  if totals[header.root].0 != header.len {
    raise InvalidFormat("footer key count does not match accepted paths")
  }
}
