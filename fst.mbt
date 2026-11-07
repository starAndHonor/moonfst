///|
/// Validate the complete reachable graph and checksum before exposing it.
pub fn Fst::from_bytes(data : Bytes) -> Fst raise FstError {
  @codec.verify(data) catch {
    error => raise InvalidFormat(@debug.to_string(error))
  }
  let header = @codec.read_header(data) catch {
    error => raise InvalidFormat(@debug.to_string(error))
  }
  { data, header, }
}

///|
pub fn Fst::to_bytes(self : Fst) -> Bytes {
  self.data
}

///|
pub fn Fst::len(self : Fst) -> UInt64 {
  self.header.len
}

///|
pub fn Fst::is_empty(self : Fst) -> Bool {
  self.header.len == 0UL
}

///|
pub fn Fst::version(self : Fst) -> UInt64 {
  self.header.version
}

///|
pub fn Fst::fst_type(self : Fst) -> UInt64 {
  self.header.fst_type
}

///|
pub fn Fst::byte_size(self : Fst) -> Int32 {
  self.data.length()
}

///|
pub fn Fst::get(self : Fst, key : Bytes) -> UInt64? raise FstError {
  packed_lookup(self, key)
}

///|
pub fn Fst::get_str(self : Fst, key : String) -> UInt64? raise FstError {
  self.get(string_bytes(key))
}

///|
pub fn Fst::contains(self : Fst, key : Bytes) -> Bool raise FstError {
  self.get(key) is Some(_)
}

///|
pub fn Fst::contains_str(self : Fst, key : String) -> Bool raise FstError {
  self.contains(string_bytes(key))
}

///|
/// Find the longest accepted prefix, including the empty key if present.
pub fn Fst::longest_prefix(self : Fst, input : Bytes) -> Entry? raise FstError {
  let mut node = read_node(self, self.header.root)
  let mut output = 0UL
  let mut best = if node.is_final {
    Some(Entry::{ key: b"", value: node.final_output, })
  } else {
    None
  }
  for i = 0; i < input.length(); i = i + 1 {
    match find_transition(node, input[i]) {
      None => break
      Some(edge) => {
        output = checked_add(output, edge.output)
        node = read_node(self, edge.addr)
        if node.is_final {
          best = Some({
            key: input.exact_view(end=i + 1).to_owned(),
            value: checked_add(output, node.final_output),
          })
        }
      }
    }
  }
  best
}

///|
/// All stored keys that are prefixes of input, shortest first.
pub fn Fst::common_prefixes(
  self : Fst,
  input : Bytes,
) -> Array[Entry] raise FstError {
  let results : Array[Entry] = []
  let mut node = read_node(self, self.header.root)
  let mut output = 0UL
  if node.is_final {
    results.push({ key: b"", value: node.final_output, })
  }
  for i = 0; i < input.length(); i = i + 1 {
    match find_transition(node, input[i]) {
      None => break
      Some(edge) => {
        output = checked_add(output, edge.output)
        node = read_node(self, edge.addr)
        if node.is_final {
          results.push({
            key: input.exact_view(end=i + 1).to_owned(),
            value: checked_add(output, node.final_output),
          })
        }
      }
    }
  }
  results
}

///|
/// Structural analysis is proportional to nodes and transitions, not keys.
pub fn Fst::statistics(self : Fst) -> Statistics raise FstError {
  let visited : Map[Int32, Bool] = Map([])
  let nodes : Array[@codec.Node] = []
  let pending = [self.header.root]
  let mut transitions = 0
  let mut final_nodes = 0
  let mut max_fanout = 0
  while pending.pop() is Some(address) {
    if visited.contains(address) {
      continue
    }
    visited[address] = true
    let node = read_node(self, address)
    nodes.push(node)
    transitions = transitions + node.transitions.length()
    if node.is_final {
      final_nodes = final_nodes + 1
    }
    if node.transitions.length() > max_fanout {
      max_fanout = node.transitions.length()
    }
    for edge in node.transitions {
      pending.push(edge.addr)
    }
  }
  nodes.sort_by(fn(a, b) { a.address.compare(b.address) })
  let depths : Map[Int32, (Int32, Int32)] = Map([])
  for node in nodes {
    let mut min_depth = if node.is_final { 0 } else { 2147483647 }
    let mut max_depth = if node.is_final { 0 } else { -1 }
    for edge in node.transitions {
      if depths.get(edge.addr) is Some((minimum, maximum)) {
        if minimum != 2147483647 && minimum + 1 < min_depth {
          min_depth = minimum + 1
        }
        if maximum >= 0 && maximum + 1 > max_depth {
          max_depth = maximum + 1
        }
      }
    }
    depths[node.address] = (min_depth, max_depth)
  }
  let (minimum, maximum) = depths[self.header.root]
  {
    keys: self.len(),
    bytes: self.byte_size(),
    nodes: nodes.length(),
    transitions,
    final_nodes,
    max_fanout,
    min_key_length: if self.is_empty() {
      0
    } else {
      minimum
    },
    max_key_length: if self.is_empty() {
      0
    } else {
      maximum
    },
  }
}

///|
/// Inspect a copy of a decoded node. Invalid addresses return format errors.
pub fn Fst::node(self : Fst, address : Int32) -> @codec.Node raise FstError {
  read_node(self, address)
}

///|
pub fn Fst::root_address(self : Fst) -> Int32 {
  self.header.root
}

///|
/// Build a DOT graph without expanding shared nodes more than once.
pub fn Fst::to_dot(self : Fst) -> String raise FstError {
  let lines = [
    "digraph fst {",
    "  rankdir=LR;",
    "  start [shape=point];",
    "  start -> n\{self.header.root};",
  ]
  let seen : Map[Int32, Bool] = Map([])
  let pending = [self.header.root]
  while pending.pop() is Some(address) {
    if seen.contains(address) {
      continue
    }
    seen[address] = true
    let node = read_node(self, address)
    let shape = if node.is_final { "doublecircle" } else { "circle" }
    lines.push(
      "  n\{address} [shape=\{shape},label=\"\{address}/\{node.final_output}\"];",
    )
    for edge in node.transitions {
      lines.push(
        "  n\{address} -> n\{edge.addr} [label=\"\{edge.input.to_int()}/\{edge.output}\"];",
      )
      pending.push(edge.addr)
    }
  }
  lines.push("}")
  lines.join("\n")
}
