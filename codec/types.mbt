// Binary format ported from BurntSushi/fst 0.4.7, MIT licensed.
// Upstream commit: fbd5992376f176c35af2644d74efad58f5656e5c.

///|
/// A transition in ascending input-byte order. Address zero is the implicit
/// final state; all other addresses point to the last byte of a stored node.
#valtype
#derive(Eq, @debug.Debug)
pub(all) struct Transition {
  input : Byte
  output : UInt64
  addr : Int32
}

///|
pub extend Transition with Eq::{equal, not_equal}

///|
pub extend Transition with @debug.Debug::{to_repr}

///|
/// An owned, bounds-checked view of one decoded node.
#derive(Eq, @debug.Debug)
pub(all) struct Node {
  address : Int32
  is_final : Bool
  final_output : UInt64
  transitions : Array[Transition]
}

///|
pub extend Node with Eq::{equal, not_equal}

///|
pub extend Node with @debug.Debug::{to_repr}

///|
/// Header and footer metadata. `len` counts accepted keys, not stored nodes.
#derive(Eq, @debug.Debug)
pub(all) struct Header {
  version : UInt64
  fst_type : UInt64
  len : UInt64
  root : Int32
}

///|
pub extend Header with Eq::{equal, not_equal}

///|
pub extend Header with @debug.Debug::{to_repr}

///|
/// Malformed, unsupported, or internally inconsistent serialized data.
#derive(@debug.Debug)
pub suberror CodecError {
  InvalidFormat(String)
}

///|
pub extend CodecError with @debug.Debug::{to_repr}

///|
priv struct Decoded {
  node : Node
  start : Int32
}
