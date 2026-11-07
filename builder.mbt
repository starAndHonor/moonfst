///|
/// Mutable nodes belong only to the unfinished stack or spare pool. Registry
/// slots own independent words, so a node can be reset and reused safely.
/// Objects are allocated only when maximum unfinished depth grows.
priv struct BuildNode {
  mut is_final : Bool
  mut final_output : UInt64
  transitions : Array[@codec.Transition]
  mut has_pending : Bool
  mut pending_input : Byte
  mut pending_output : UInt64
}

///|
/// Independent registry words let completed-node storage return to the pool.
/// The first two words store finality/final output; each edge uses one packed
/// input/address word and one complete UInt64 output. Full word equality, not
/// the fingerprint alone, decides state equivalence.
/// Only an evicted slot's words may be overwritten for a later node.
#valtype
priv struct BuildSignature {
  fingerprint : UInt64
  words : FixedArray[UInt64]
}

///|
#valtype
priv struct RegistrySlot {
  signature : BuildSignature
  address : Int32
}

///|
/// Observable builder memory/compression counters.
#derive(Eq, @debug.Debug)
pub(all) struct BuilderStatistics {
  keys : UInt64
  compiled_nodes : Int32
  reused_nodes : Int32
  registry_entries : Int32
  unfinished_nodes : Int32
  bytes_written : Int32
}

///|
/// Sorted incremental construction, with a bounded state-deduplication cache.
pub struct Builder {
  priv buffer : Array[Byte]
  priv stack : Array[BuildNode]
  priv spare_nodes : Array[BuildNode]
  priv mut registry : FixedArray[RegistrySlot]
  priv mut registry_count : Int32
  priv registry_rows : Int32
  priv registry_capacity : Int32
  priv mut previous : Bytes?
  priv mut count : UInt64
  priv mut closed : Bool
  priv mut compiled_nodes : Int32
  priv mut reused_nodes : Int32
  priv map_mode : Bool
}

///|
fn build_node(is_final : Bool) -> BuildNode {
  {
    is_final,
    final_output: 0UL,
    transitions: [],
    has_pending: false,
    pending_input: b'\x00',
    pending_output: 0UL,
  }
}

///|
/// Only unfinished storage is recycled. Registry words own a compact copy and
/// never alias these arrays. Stack plus pool stays bounded by maximum depth.
fn Builder::new_node(self : Builder, is_final : Bool) -> BuildNode {
  match self.spare_nodes.pop() {
    None => build_node(is_final)
    Some(node) => {
      node.is_final = is_final
      node.final_output = 0UL
      node.has_pending = false
      node.pending_input = b'\x00'
      node.pending_output = 0UL
      node
    }
  }
}

///|
fn make_builder(
  map_mode : Bool,
  registry_capacity : Int32,
  fst_type : UInt64,
) -> Builder raise FstError {
  if registry_capacity < 0 {
    raise InvalidArgument("registry_capacity must be nonnegative")
  }
  {
    buffer: @codec.begin(fst_type),
    stack: [build_node(false)],
    spare_nodes: [],
    registry: FixedArray::make(registry_capacity, {
      signature: { fingerprint: 0UL, words: [], },
      address: 0,
    }),
    registry_count: 0,
    registry_rows: registry_capacity / 2 + registry_capacity % 2,
    registry_capacity,
    previous: None,
    count: 0UL,
    closed: false,
    compiled_nodes: 0,
    reused_nodes: 0,
    map_mode,
  }
}

///|
/// Duplicate set keys are accepted and counted once. Keys must be sorted.
pub fn Builder::set(
  registry_capacity~ : Int32 = 20000,
  fst_type~ : UInt64 = 0UL,
) -> Builder raise FstError {
  make_builder(false, registry_capacity, fst_type)
}

///|
/// Map keys must be strictly increasing. Values span the full UInt64 range.
pub fn Builder::map(
  registry_capacity~ : Int32 = 20000,
  fst_type~ : UInt64 = 0UL,
) -> Builder raise FstError {
  make_builder(true, registry_capacity, fst_type)
}

///|
pub fn Builder::statistics(self : Builder) -> BuilderStatistics {
  {
    keys: self.count,
    compiled_nodes: self.compiled_nodes,
    reused_nodes: self.reused_nodes,
    registry_entries: self.registry_count,
    unfinished_nodes: self.stack.length(),
    bytes_written: self.buffer.length(),
  }
}

///|
fn node_fingerprint(node : BuildNode) -> UInt64 {
  let finality = if node.is_final { 1UL } else { 0UL }
  let mut hash = (14695981039346656037UL ^ finality) * 1099511628211UL
  hash = (hash ^ node.final_output) * 1099511628211UL
  for transition in node.transitions {
    hash = (hash ^ transition.input.to_uint64()) * 1099511628211UL
    hash = (hash ^ transition.output) * 1099511628211UL
    hash = (hash ^ transition.addr.to_uint64()) * 1099511628211UL
  }
  hash
}

///|
fn signature_matches(
  signature : BuildSignature,
  node : BuildNode,
  fingerprint : UInt64,
) -> Bool {
  if signature.fingerprint != fingerprint ||
    signature.words.length() != 2 + node.transitions.length() * 2 {
    return false
  }
  let words = signature.words
  if words[0] != (if node.is_final { 1UL } else { 0UL }) ||
    words[1] != node.final_output {
    return false
  }
  let mut at = 2
  for transition in node.transitions {
    let packed = transition.input.to_uint64() |
      (transition.addr.to_uint64() << 8)
    if words[at] != packed || words[at + 1] != transition.output {
      return false
    }
    at = at + 2
  }
  true
}

///|
fn node_signature(
  node : BuildNode,
  fingerprint : UInt64,
  reused : FixedArray[UInt64],
) -> BuildSignature {
  let needed = 2 + node.transitions.length() * 2
  let words = if reused.length() == needed {
    reused
  } else {
    FixedArray::make(needed, 0UL)
  }
  words[0] = if node.is_final { 1UL } else { 0UL }
  words[1] = node.final_output
  let mut at = 2
  for transition in node.transitions {
    words[at] = transition.input.to_uint64() |
      (transition.addr.to_uint64() << 8)
    words[at + 1] = transition.output
    at = at + 2
  }
  { fingerprint, words, }
}

///|
fn Builder::compile_node(self : Builder, node : BuildNode) -> Int32 {
  if node.is_final && node.final_output == 0UL && node.transitions.is_empty() {
    self.reused_nodes = self.reused_nodes + 1
    return 0
  }
  let fingerprint = if self.registry_capacity > 0 {
    node_fingerprint(node)
  } else {
    0UL
  }
  let first = if self.registry_capacity > 0 {
    (fingerprint % self.registry_rows.to_uint64()).to_int() * 2
  } else {
    0
  }
  if self.registry_capacity > 0 {
    let recent = self.registry[first]
    if signature_matches(recent.signature, node, fingerprint) {
      self.reused_nodes = self.reused_nodes + 1
      return recent.address
    }
    if first + 1 < self.registry_capacity {
      let older = self.registry[first + 1]
      if signature_matches(older.signature, node, fingerprint) {
        self.registry[first] = older
        self.registry[first + 1] = recent
        self.reused_nodes = self.reused_nodes + 1
        return older.address
      }
    }
  }
  let address = @codec.write_node(
    self.buffer,
    node.is_final,
    node.final_output,
    node.transitions,
  )
  self.compiled_nodes = self.compiled_nodes + 1
  if self.registry_capacity > 0 {
    let evicted = if first + 1 < self.registry_capacity {
      let older = self.registry[first + 1]
      self.registry[first + 1] = self.registry[first]
      older
    } else {
      self.registry[first]
    }
    if evicted.signature.words.is_empty() {
      self.registry_count = self.registry_count + 1
    }
    let signature = node_signature(node, fingerprint, evicted.signature.words)
    self.registry[first] = { signature, address, }
  }
  address
}

///|
/// Finalize all nodes below the common prefix, deepest first.
fn Builder::compile_suffix(self : Builder, depth : Int32) -> Unit {
  while self.stack.length() > depth + 1 {
    let child = self.stack.pop().unwrap()
    let address = self.compile_node(child)
    let parent = self.stack[self.stack.length() - 1]
    if parent.has_pending {
      parent.transitions.push({
        input: parent.pending_input,
        output: parent.pending_output,
        addr: address,
      })
      parent.has_pending = false
    }
    child.transitions.clear()
    self.spare_nodes.push(child)
  }
}

///|
/// Factor an output prefix down into an unfinished subtree.
fn BuildNode::push_output(self : BuildNode, prefix : UInt64) -> Unit {
  for i = 0; i < self.transitions.length(); i = i + 1 {
    let edge = self.transitions[i]
    self.transitions[i] = {
      input: edge.input,
      output: edge.output + prefix,
      addr: edge.addr,
    }
  }
  if self.is_final {
    self.final_output = self.final_output + prefix
  }
  if self.has_pending {
    self.pending_output = self.pending_output + prefix
  }
}

///|
pub fn Builder::insert(
  self : Builder,
  key : Bytes,
  value : UInt64,
) -> Unit raise FstError {
  if self.closed {
    raise BuilderClosed
  }
  if !self.map_mode && value != 0UL {
    raise InvalidArgument("a set builder only accepts zero outputs")
  }
  if self.previous is Some(previous) {
    let order = key.lexical_compare(previous)
    if order < 0 {
      raise OutOfOrder(previous, key)
    }
    if order == 0 {
      if self.map_mode {
        raise DuplicateKey(key)
      }
      return
    }
  }
  if key.is_empty() {
    self.stack[0].is_final = true
    self.stack[0].final_output = value
  } else {
    let mut depth = 0
    let mut remaining = value
    while depth < key.length() && depth < self.stack.length() {
      let node = self.stack[depth]
      if !node.has_pending || node.pending_input != key[depth] {
        break
      }
      let common = UInt64::min(node.pending_output, remaining)
      let carry = node.pending_output - common
      node.pending_output = common
      remaining = remaining - common
      depth = depth + 1
      if carry != 0UL {
        self.stack[depth].push_output(carry)
      }
    }
    self.compile_suffix(depth)
    for i = depth; i < key.length(); i = i + 1 {
      let node = self.stack[i]
      node.has_pending = true
      node.pending_input = key[i]
      node.pending_output = if i == depth { remaining } else { 0UL }
      self.stack.push(self.new_node(i == key.length() - 1))
    }
  }

  self.previous = Some(key)
  self.count = checked_add(self.count, 1UL)
}

///|
pub fn Builder::add(self : Builder, key : Bytes) -> Unit raise FstError {
  if self.map_mode {
    raise InvalidArgument("use insert on a map builder")
  }
  self.insert(key, 0UL)
}

///|
pub fn Builder::insert_str(
  self : Builder,
  key : String,
  value : UInt64,
) -> Unit raise FstError {
  self.insert(string_bytes(key), value)
}

///|
pub fn Builder::add_str(self : Builder, key : String) -> Unit raise FstError {
  self.add(string_bytes(key))
}

///|
/// Errors leave previously inserted entries intact; later entries are unprocessed.
pub fn Builder::extend_entries(
  self : Builder,
  entries : Array[Entry],
) -> Unit raise FstError {
  for entry in entries {
    self.insert(entry.key, entry.value)
  }
}

///|
/// Finish once. Afterwards the builder rejects inserts and further finishes.
pub fn Builder::finish(self : Builder) -> Bytes raise FstError {
  if self.closed {
    raise BuilderClosed
  }
  self.compile_suffix(0)
  let root = self.compile_node(self.stack[0])
  let result = @codec.finish(self.buffer, root~, len=self.count)
  self.closed = true
  self.stack.clear()
  self.spare_nodes.clear()
  self.registry = []
  self.registry_count = 0
  result
}

///|
pub fn Builder::into_fst(self : Builder) -> Fst raise FstError {
  Fst::from_bytes(self.finish())
}

///|
pub fn Builder::into_set(self : Builder) -> FstSet raise FstError {
  if self.map_mode {
    raise InvalidArgument("use into_map on a map builder")
  }
  { fst: self.into_fst(), }
}

///|
pub fn Builder::into_map(self : Builder) -> FstMap raise FstError {
  { fst: self.into_fst(), }
}
