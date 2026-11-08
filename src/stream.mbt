///|
#valtype
priv struct Frame {
  node : TraversalNode
  output : UInt64
  state : Int32
  key_length : Int32
  next_edge : Int32
  visited_final : Bool
  lower_order : Int32
  upper_order : Int32
}

///|
/// Lazy lexicographic traversal. Only the active path and compressed-node
/// cursors are held; transition arrays are never materialized for traversal.
pub struct Stream {
  priv fst : Fst
  priv matcher : &@automaton.Automaton
  priv range : KeyRange
  priv frames : Array[Frame]
  priv key : Array[Byte]
  priv reverse : Bool
  priv unfiltered : Bool
  priv unbounded : Bool
  priv mut done : Bool
  priv mut current_value : UInt64
}

///|
/// Whether any extension of a prefix can lie inside the range.
fn KeyRange::may_contain_prefix(self : KeyRange, prefix : Bytes) -> Bool {
  match self.upper {
    Unbounded => ()
    Included(bound) => if prefix.lexical_compare(bound) > 0 { return false }
    Excluded(bound) => if prefix.lexical_compare(bound) >= 0 { return false }
  }
  match self.lower {
    Unbounded => true
    Included(bound) | Excluded(bound) =>
      prefix.lexical_compare(bound) >= 0 || bound.has_prefix(prefix)
  }
}

///|
/// Automata prune subtrees before their compressed-node cursors are opened.
pub fn Fst::search(
  self : Fst,
  matcher : &@automaton.Automaton,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.search_direction(matcher, range, false)
}

///|
/// Retain the error effect used by the public forward/reverse constructors.
/// Opening cursors over verified bytes no longer performs fallible decoding.
#warnings("-unused_error_type")
fn Fst::search_direction(
  self : Fst,
  matcher : &@automaton.Automaton,
  range : KeyRange,
  reverse : Bool,
  unfiltered~ : Bool = false,
) -> Stream raise FstError {
  let state = matcher.start()
  let frames : Array[Frame] = []
  if matcher.can_match(state) &&
    range.may_contain_prefix(b"") &&
    !self.is_empty() {
    let node = traversal_node(self, self.header.root)
    frames.push({
      node,
      output: 0UL,
      state,
      key_length: 0,
      next_edge: if reverse {
        node.count - 1
      } else {
        0
      },
      visited_final: !node.is_final,
      lower_order: 0,
      upper_order: 0,
    })
  }
  let unbounded = range.lower is Unbounded && range.upper is Unbounded
  {
    fst: self,
    matcher,
    range,
    frames,
    key: [],
    reverse,
    unfiltered,
    unbounded,
    done: false,
    current_value: 0UL,
  }
}

///|
pub fn Fst::stream(
  self : Fst,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.search_direction(@automaton.always(), range, false, unfiltered=true)
}

///|
pub fn Fst::prefix(self : Fst, prefix : Bytes) -> Stream raise FstError {
  self.stream(range=KeyRange::prefix(prefix))
}

///|
pub fn Fst::prefix_str(self : Fst, prefix : String) -> Stream raise FstError {
  self.prefix(string_bytes(prefix))
}

///|
/// Advance without allocating an Option or an owned key. The active path is
/// copied only by APIs that return a key; count/skip keep no discarded copies.
fn Stream::advance(self : Stream) -> Bool raise FstError {
  if self.done {
    return false
  }
  while !self.frames.is_empty() {
    let top = self.frames.length() - 1
    let mut frame = self.frames[top]
    // Unary chains have no pending siblings or final keys. Keep their cursor
    // local rather than storing and reloading a complete frame at each byte.
    // Persist it only at a yield or when branching creates a backtrack point.
    while true {
      if !frame.visited_final && (!self.reverse || frame.next_edge < 0) {
        frame = { ..frame, visited_final: true, }
        if frame.node.is_final {
          let matches = if self.unfiltered {
            true
          } else {
            let terminal = match self.matcher.accept_eof(frame.state) {
              Some(state) => state
              None => frame.state
            }
            self.matcher.is_match(terminal)
          }
          if matches &&
            (
              self.unbounded ||
              self.range.contains_orders(
                frame.lower_order,
                frame.upper_order,
                frame.key_length,
              )
            ) {
            self.frames[top] = frame
            self.current_value = checked_add(
              frame.output,
              frame.node.final_output,
            )
            return true
          }
        }
      }
      if frame.next_edge < 0 || frame.next_edge >= frame.node.count {
        self.frames.truncate(top)
        if self.frames.is_empty() {
          self.key.clear()
        } else {
          self.key.truncate(self.frames[self.frames.length() - 1].key_length)
        }
        break
      }
      let edge_position = frame.next_edge
      frame = {
        ..frame,
        next_edge: frame.next_edge + (if self.reverse { -1 } else { 1 }),
      }
      let input = traversal_edge_input(self.fst.data, frame.node, edge_position)
      let state = if self.unfiltered {
        0
      } else {
        self.matcher.accept(frame.state, input)
      }
      if !self.unfiltered && !self.matcher.can_match(state) {
        continue
      }
      let lower_order = if self.unbounded || frame.lower_order != 0 {
        frame.lower_order
      } else {
        self.range.lower.extend_order(
          frame.lower_order,
          frame.key_length,
          input,
        )
      }
      let upper_order = if self.unbounded || frame.upper_order != 0 {
        frame.upper_order
      } else {
        self.range.upper.extend_order(
          frame.upper_order,
          frame.key_length,
          input,
        )
      }
      if lower_order < 0 || upper_order > 0 {
        continue
      }
      self.key.truncate(frame.key_length)
      self.key.push(input)
      let address = traversal_edge_address(
        self.fst.data,
        frame.node,
        edge_position,
      )
      let output = traversal_edge_output(
        self.fst.data,
        frame.node,
        edge_position,
      )
      let node = traversal_node(self.fst, address)
      let child : Frame = {
        node,
        // Full graph validation has checked every possible path-output sum.
        output: frame.output + output,
        state,
        key_length: self.key.length(),
        next_edge: if self.reverse {
          node.count - 1
        } else {
          0
        },
        visited_final: !node.is_final,
        lower_order,
        upper_order,
      }
      if frame.node.count == 1 && !frame.node.is_final {
        frame = child
      } else {
        self.frames[top] = frame
        self.frames.push(child)
        break
      }
    }
  }
  self.done = true
  false
}

///|
fn Stream::current_entry(self : Stream) -> Entry {
  { key: Bytes::from_array(self.key), value: self.current_value, }
}

///|
pub fn Stream::next(self : Stream) -> Entry? raise FstError {
  if self.advance() {
    Some(self.current_entry())
  } else {
    None
  }
}

///|
/// Stop early and release the active traversal stack.
pub fn Stream::close(self : Stream) -> Unit {
  self.frames.clear()
  self.key.clear()
  self.done = true
}

///|
pub fn Stream::collect(self : Stream) -> Array[Entry] raise FstError {
  let entries = []
  while self.advance() {
    entries.push(self.current_entry())
  }
  entries
}

///|
/// Consume at most count results without exhausting the stream.
pub fn Stream::take(
  self : Stream,
  count : Int32,
) -> Array[Entry] raise FstError {
  if count < 0 {
    raise InvalidArgument("take count must be nonnegative")
  }
  let entries = []
  while entries.length() < count && self.advance() {
    entries.push(self.current_entry())
  }
  entries
}

///|
pub fn Stream::skip(self : Stream, count : Int32) -> Int32 raise FstError {
  if count < 0 {
    raise InvalidArgument("skip count must be nonnegative")
  }
  let mut skipped = 0
  while skipped < count && self.advance() {
    skipped = skipped + 1
  }
  skipped
}

///|
pub fn Stream::count(self : Stream) -> UInt64 raise FstError {
  let mut count = 0UL
  while self.advance() {
    count = checked_add(count, 1UL)
  }
  count
}

///|
pub fn Stream::keys(self : Stream) -> Array[Bytes] raise FstError {
  let keys = []
  while self.advance() {
    keys.push(Bytes::from_array(self.key))
  }
  keys
}

///|
/// UTF-8 decoding is strict and preserves a leading BOM as a character.
pub fn Stream::strings(self : Stream) -> Array[String] raise FstError {
  let keys = []
  while self.advance() {
    keys.push(bytes_string(Bytes::from_array(self.key)))
  }
  keys
}

///|
pub fn Stream::string_entries(
  self : Stream,
) -> Array[(String, UInt64)] raise FstError {
  let entries = []
  while self.advance() {
    entries.push(
      (bytes_string(Bytes::from_array(self.key)), self.current_value),
    )
  }
  entries
}

///|
/// Extend a sorted builder directly without materializing the result set.
pub fn Builder::extend_stream(
  self : Builder,
  stream : Stream,
) -> Unit raise FstError {
  while stream.next() is Some(entry) {
    if self.map_mode {
      self.insert(entry.key, entry.value)
    } else {
      self.add(entry.key)
    }
  }
}
