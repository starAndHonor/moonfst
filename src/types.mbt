///|
/// Errors reported at the public library boundary.
#derive(@debug.Debug)
pub(all) suberror FstError {
  InvalidArgument(String)
  OutOfOrder(Bytes, Bytes)
  DuplicateKey(Bytes)
  BuilderClosed
  InvalidFormat(String)
  InvalidUtf8
  Overflow
  ResourceLimit(String)
}

///|
/// One owned key/value result. Keys are arbitrary bytes, including NUL.
#valtype
#derive(Eq, @debug.Debug)
pub(all) struct Entry {
  key : Bytes
  value : UInt64
}

///|
/// Inclusive or exclusive lexicographic range endpoint.
#derive(Eq, @debug.Debug)
pub(all) enum Bound {
  Unbounded
  Included(Bytes)
  Excluded(Bytes)
}

///|
/// A half-open or closed byte range; each endpoint has its own inclusion rule.
#derive(Eq, @debug.Debug)
pub(all) struct KeyRange {
  lower : Bound
  upper : Bound
}

///|
/// How an unsorted map constructor resolves duplicate keys.
#derive(Eq, @debug.Debug)
pub(all) enum DuplicatePolicy {
  Reject
  KeepFirst
  KeepLast
  Sum
  Minimum
  Maximum
}

///|
/// An immutable validated FST. Arrays exposed by inspection are fresh copies.
pub struct Fst {
  priv data : Bytes
  priv header : @codec.Header
}

///|
/// Set view of an immutable FST.
pub struct FstSet {
  priv fst : Fst
}

///|
/// Map view: byte-string keys and unsigned 64-bit values.
pub struct FstMap {
  priv fst : Fst
}

///|
/// Structural statistics, computed without enumerating accepted strings.
#derive(Eq, @debug.Debug)
pub(all) struct Statistics {
  keys : UInt64
  bytes : Int32
  nodes : Int32
  transitions : Int32
  final_nodes : Int32
  max_fanout : Int32
  min_key_length : Int32
  max_key_length : Int32
}

///|
pub fn KeyRange::all() -> KeyRange {
  { lower: Unbounded, upper: Unbounded, }
}

///|
pub fn KeyRange::between(lower : Bytes, upper : Bytes) -> KeyRange {
  { lower: Included(lower), upper: Excluded(upper), }
}

///|
pub fn KeyRange::closed(lower : Bytes, upper : Bytes) -> KeyRange {
  { lower: Included(lower), upper: Included(upper), }
}

///|
pub fn KeyRange::contains(self : KeyRange, key : Bytes) -> Bool {
  self.above_lower(key) && self.below_upper(key)
}

///|
fn KeyRange::above_lower(self : KeyRange, key : Bytes) -> Bool {
  match self.lower {
    Unbounded => true
    Included(bound) => key.lexical_compare(bound) >= 0
    Excluded(bound) => key.lexical_compare(bound) > 0
  }
}

///|
fn KeyRange::below_upper(self : KeyRange, key : Bytes) -> Bool {
  match self.upper {
    Unbounded => true
    Included(bound) => key.lexical_compare(bound) <= 0
    Excluded(bound) => key.lexical_compare(bound) < 0
  }
}

///|
/// Return the exclusive upper bound of all byte strings with this prefix.
pub fn prefix_successor(prefix : Bytes) -> Bytes? {
  let bytes = prefix.to_array()
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    if bytes[i] != b'\xff' {
      bytes[i] = (bytes[i].to_int() + 1).to_byte()
      bytes.truncate(i + 1)
      return Some(Bytes::from_array(bytes))
    }
  }
  None
}

///|
pub fn KeyRange::prefix(prefix : Bytes) -> KeyRange {
  {
    lower: Included(prefix),
    upper: match prefix_successor(prefix) {
      Some(end) => Excluded(end)
      None => Unbounded
    },
  }
}

///|
fn checked_add(a : UInt64, b : UInt64) -> UInt64 raise FstError {
  let result = a + b
  if result < a {
    raise Overflow
  }
  result
}

///|
fn string_bytes(value : String) -> Bytes {
  @utf8.encode(value)
}

///|
fn bytes_string(value : Bytes) -> String raise FstError {
  @utf8.decode(value, ignore_bom=false) catch {
    _ => raise InvalidUtf8
  }
}

///|
fn read_node(fst : Fst, address : Int32) -> @codec.Node raise FstError {
  @codec.read_node(fst.data, fst.header, address) catch {
    error => raise InvalidFormat(@debug.to_string(error))
  }
}

///|
fn find_transition(node : @codec.Node, input : Byte) -> @codec.Transition? {
  let mut low = 0
  let mut high = node.transitions.length()
  while low < high {
    let middle = low + (high - low) / 2
    let transition = node.transitions[middle]
    if transition.input < input {
      low = middle + 1
    } else if transition.input > input {
      high = middle
    } else {
      return Some(transition)
    }
  }
  None
}
