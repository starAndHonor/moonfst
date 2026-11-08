///|
/// Multiway operations on sorted streams. Difference subtracts every stream
/// after the first. SymmetricDifference keeps keys with odd source count.
#derive(Eq, @debug.Debug)
pub(all) enum Operation {
  Union
  Intersection
  Difference
  SymmetricDifference
}

///|
/// The value and zero-based source index of a key in a merge result.
#valtype
#derive(Eq, @debug.Debug)
pub(all) struct IndexedValue {
  index : Int32
  value : UInt64
}

///|
/// Values are ordered by ascending source index.
#derive(Eq, @debug.Debug)
pub(all) struct MergedEntry {
  key : Bytes
  values : Array[IndexedValue]
}

///|
#valtype
priv struct HeapItem {
  entry : Entry
  source : Int32
}

///|
/// Fresh two-way merges retain borrowed heads in each stream's key buffer.
priv struct PairStreams {
  left : Stream
  right : Stream
  mut left_ready : Bool
  mut right_ready : Bool
}

///|
/// Only merge(Fst[]) owns freshly opened streams whose ordering follows from
/// the verified graph. Public application sources retain their checked path.
priv enum MergeInputs {
  FstPair(PairStreams)
  FstStreams(Array[Stream])
  Checked(Array[&EntrySource])
}

///|
/// Streaming merge, using O(number of sources) heads plus each stream's
/// active path. Inputs are consumed and must not be shared during iteration.
pub struct MergeStream {
  priv inputs : MergeInputs
  priv heap : Array[HeapItem]
  priv operation : Operation
  priv mut finished : Bool
}

///|
fn heap_before(a : HeapItem, b : HeapItem) -> Bool {
  let order = a.entry.key.lexical_compare(b.entry.key)
  order < 0 || (order == 0 && a.source < b.source)
}

///|
fn heap_push(heap : Array[HeapItem], item : HeapItem) -> Unit {
  heap.push(item)
  let mut index = heap.length() - 1
  while index > 0 {
    let parent = (index - 1) / 2
    if !heap_before(item, heap[parent]) {
      break
    }
    heap[index] = heap[parent]
    index = parent
  }
  heap[index] = item
}

///|
/// Only the root changed, and its replacement cannot precede the old root.
/// Move the smaller child into the hole until the replacement fits. Values
/// remain in the flat array; no temporary Option/HeapItem boxes are needed.
fn heap_sift_down(heap : Array[HeapItem]) -> Unit {
  if heap.length() < 2 {
    return
  }
  let item = heap[0]
  let mut index = 0
  while index < heap.length() / 2 {
    let left = index * 2 + 1
    let right = left + 1
    let child = if right < heap.length() && heap_before(heap[right], heap[left]) {
      right
    } else {
      left
    }
    if !heap_before(heap[child], item) {
      break
    }
    heap[index] = heap[child]
    index = child
  }
  heap[index] = item
}

///|
/// Each supplied stream must be independent; ownership is transferred by
/// convention. Zero inputs produce an empty result for every operation.
pub fn MergeStream::new(
  sources : Array[Stream],
  operation : Operation,
) -> MergeStream raise FstError {
  let inputs : Array[&EntrySource] = []
  for stream in sources {
    inputs.push(stream)
  }
  merge_sources(inputs, operation)
}

///|
/// Merge external readers as well as FST streams. Inputs are validated as
/// consumed, so invalid ordering cannot silently corrupt the result.
pub fn merge_sources(
  sources : Array[&EntrySource],
  operation : Operation,
) -> MergeStream raise FstError {
  let checked : Array[&EntrySource] = []
  for source in sources {
    checked.push(CheckedSource::new(source))
  }
  let heap = []
  errdefer (for source in checked {
    source.close()
  })
  for index = 0; index < checked.length(); index = index + 1 {
    let next = checked[index].next()
    if next is Some(entry) {
      heap_push(heap, { source: index, entry, })
    }
  }
  { inputs: Checked(checked), heap, operation, finished: false, }
}

///|
/// Create independent streams, even if the same FST appears more than once.
pub fn merge(
  inputs : Array[Fst],
  operation : Operation,
  range~ : KeyRange = KeyRange::all(),
) -> MergeStream raise FstError {
  let sources : Array[Stream] = []
  errdefer (for stream in sources {
    stream.close()
  })
  for input in inputs {
    sources.push(input.stream(range~))
  }
  if sources.length() == 2 {
    let left = sources[0]
    let right = sources[1]
    let left_ready = left.advance()
    if !left_ready {
      left.close()
    }
    let right_ready = right.advance()
    if !right_ready {
      right.close()
    }
    return {
      inputs: FstPair({ left, right, left_ready, right_ready, }),
      heap: [],
      operation,
      finished: false,
    }
  }
  let heap = []
  for source = 0; source < sources.length(); source = source + 1 {
    let stream = sources[source]
    if stream.advance() {
      heap_push(heap, { source, entry: stream.current_entry(), })
    } else {
      stream.close()
    }
  }
  { inputs: FstStreams(sources), heap, operation, finished: false, }
}

///|
fn MergeStream::input_count(self : MergeStream) -> Int32 {
  match self.inputs {
    FstPair(_) => 2
    FstStreams(streams) => streams.length()
    Checked(sources) => sources.length()
  }
}

///|
/// Refill the minimum head in place. Verified FST traversal or CheckedSource
/// guarantees increasing keys, so one downward heap repair is sufficient.
fn MergeStream::advance_root(self : MergeStream) -> Unit raise FstError {
  let source = self.heap[0].source
  let available = match self.inputs {
    FstPair(_) => abort("two-way merge has no heap heads")
    FstStreams(streams) => {
      let stream = streams[source]
      if stream.advance() {
        self.heap[0] = { source, entry: stream.current_entry(), }
        true
      } else {
        stream.close()
        false
      }
    }
    Checked(sources) =>
      match sources[source].next() {
        Some(entry) => {
          self.heap[0] = { source, entry, }
          true
        }
        None => false
      }
  }
  if !available {
    let last = self.heap.length() - 1
    if last > 0 {
      self.heap[0] = self.heap[last]
    }
    self.heap.truncate(last)
  }
  heap_sift_down(self.heap)
}

///|
/// Compare borrowed buffers without constructing either head's owned key.
fn pair_key_order(left : Stream, right : Stream) -> Int32 {
  let mut index = 0
  while index < left.key.length() && index < right.key.length() {
    let order = left.key[index].to_int() - right.key[index].to_int()
    if order != 0 {
      return order
    }
    index = index + 1
  }
  left.key.length() - right.key.length()
}

///|
fn MergeStream::next_pair(
  self : MergeStream,
  pair : PairStreams,
) -> MergedEntry? raise FstError {
  while pair.left_ready || pair.right_ready {
    let order = if !pair.left_ready {
      1
    } else if !pair.right_ready {
      -1
    } else {
      pair_key_order(pair.left, pair.right)
    }
    let keep = match self.operation {
      Union => true
      Intersection => order == 0
      Difference => order < 0
      SymmetricDifference => order != 0
    }
    // Copy only a returned key, before advancing its mutable source buffer.
    // Each group owns its values, including equal-key source order 0 then 1.
    let group = if keep {
      let key = Bytes::from_array(
        if order <= 0 {
          pair.left.key
        } else {
          pair.right.key
        },
      )
      let values : Array[IndexedValue] = if order == 0 {
        [
          { index: 0, value: pair.left.current_value, },
          { index: 1, value: pair.right.current_value, },
        ]
      } else if order < 0 {
        [{ index: 0, value: pair.left.current_value, }]
      } else {
        [{ index: 1, value: pair.right.current_value, }]
      }
      Some({ key, values, })
    } else {
      None
    }
    // Refill before yielding, preserving the heap path's failure boundary.
    if order <= 0 {
      pair.left_ready = pair.left.advance()
      if !pair.left_ready {
        pair.left.close()
      }
    }
    if order >= 0 {
      pair.right_ready = pair.right.advance()
      if !pair.right_ready {
        pair.right.close()
      }
    }
    if group is Some(_) {
      return group
    }
  }
  self.finished = true
  None
}

///|
pub fn MergeStream::next(self : MergeStream) -> MergedEntry? raise FstError {
  errdefer self.close()
  self.next_group()
}

///|
/// A merge cannot safely resume after a reader fails: its popped head may
/// already be absent from the heap. The public entrypoint closes all inputs.
fn MergeStream::next_group(self : MergeStream) -> MergedEntry? raise FstError {
  if self.finished {
    return None
  }
  if self.inputs is FstPair(pair) {
    return self.next_pair(pair)
  }
  while !self.heap.is_empty() {
    let first = self.heap[0]
    let key = first.entry.key
    let first_value : IndexedValue = {
      index: first.source,
      value: first.entry.value,
    }
    self.advance_root()
    // Keep the first two values in scalars until group size is known. A
    // singleton keeps its exact-sized array; a pair needs no grow-and-copy.
    // Larger groups retain ordinary array growth and the same source order.
    let values = if !self.heap.is_empty() && self.heap[0].entry.key == key {
      let second = self.heap[0]
      let second_value : IndexedValue = {
        index: second.source,
        value: second.entry.value,
      }
      self.advance_root()
      [first_value, second_value]
    } else {
      [first_value]
    }
    while !self.heap.is_empty() && self.heap[0].entry.key == key {
      let item = self.heap[0]
      values.push({ index: item.source, value: item.entry.value, })
      self.advance_root()
    }
    // The heap compares (key, source), so equal-key heads arrive in source
    // order. Refilling one source cannot add the same key again because every
    // input is strictly increasing. No group sort is necessary.
    let keep = match self.operation {
      Union => true
      Intersection => values.length() == self.input_count()
      Difference => values.length() == 1 && values[0].index == 0
      SymmetricDifference => values.length() % 2 == 1
    }
    if keep {
      return Some({ key, values, })
    }
  }
  self.finished = true
  None
}

///|
pub fn MergeStream::close(self : MergeStream) -> Unit {
  match self.inputs {
    FstPair(pair) => {
      pair.left_ready = false
      pair.right_ready = false
      pair.left.close()
      pair.right.close()
    }
    FstStreams(streams) =>
      for stream in streams {
        stream.close()
      }
    Checked(sources) =>
      for source in sources {
        source.close()
      }
  }
  self.heap.clear()
  self.finished = true
}

///|
pub fn MergeStream::collect(
  self : MergeStream,
) -> Array[MergedEntry] raise FstError {
  let result = []
  while self.next() is Some(entry) {
    result.push(entry)
  }
  result
}

///|
pub fn MergeStream::take(
  self : MergeStream,
  count : Int32,
) -> Array[MergedEntry] raise FstError {
  if count < 0 {
    raise InvalidArgument("take count must be nonnegative")
  }
  let result = []
  while result.length() < count {
    match self.next() {
      Some(entry) => result.push(entry)
      None => break
    }
  }
  result
}

///|
pub fn MergeStream::count(self : MergeStream) -> UInt64 raise FstError {
  let mut count = 0UL
  while self.next() is Some(_) {
    count = checked_add(count, 1UL)
  }
  count
}

///|
/// Collapse grouped outputs using a checked arithmetic policy.
pub fn MergedEntry::reduce(
  self : MergedEntry,
  policy : DuplicatePolicy,
) -> Entry raise FstError {
  if self.values.is_empty() {
    raise InvalidArgument("cannot reduce an empty output group")
  }
  let mut value = self.values[0].value
  for index = 1; index < self.values.length(); index = index + 1 {
    let next = self.values[index].value
    value = match policy {
      Reject => raise DuplicateKey(self.key)
      KeepFirst => value
      KeepLast => next
      Sum => checked_add(value, next)
      Minimum => if value < next { value } else { next }
      Maximum => if value > next { value } else { next }
    }
  }
  { key: self.key, value, }
}

///|
pub fn MergeStream::into_set(
  self : MergeStream,
  registry_capacity~ : Int32 = 20000,
) -> FstSet raise FstError {
  errdefer self.close()
  let builder = Builder::set(registry_capacity~)
  while self.next() is Some(entry) {
    builder.add(entry.key)
  }
  builder.into_set()
}

///|
/// Choose how to combine shared keys explicitly; no silent UInt64 overflow.
pub fn MergeStream::into_map(
  self : MergeStream,
  policy : DuplicatePolicy,
  registry_capacity~ : Int32 = 20000,
) -> FstMap raise FstError {
  errdefer self.close()
  let builder = Builder::map(registry_capacity~)
  while self.next() is Some(group) {
    let entry = group.reduce(policy)
    builder.insert(entry.key, entry.value)
  }
  builder.into_map()
}

///|
/// Custom reductions can use source indices for priority or weighted merging.
pub fn MergeStream::reduce_with(
  self : MergeStream,
  f : (MergedEntry) -> UInt64 raise?,
) -> FstMap raise {
  errdefer self.close()
  let builder = Builder::map()
  while self.next() is Some(entry) {
    builder.insert(entry.key, f(entry))
  }
  builder.into_map()
}

///|
pub fn FstSet::union(self : FstSet, other : FstSet) -> FstSet raise FstError {
  merge([self.fst, other.fst], Union).into_set()
}

///|
pub fn FstSet::intersection(
  self : FstSet,
  other : FstSet,
) -> FstSet raise FstError {
  merge([self.fst, other.fst], Intersection).into_set()
}

///|
pub fn FstSet::difference(
  self : FstSet,
  other : FstSet,
) -> FstSet raise FstError {
  merge([self.fst, other.fst], Difference).into_set()
}

///|
pub fn FstSet::symmetric_difference(
  self : FstSet,
  other : FstSet,
) -> FstSet raise FstError {
  merge([self.fst, other.fst], SymmetricDifference).into_set()
}

///|
pub fn FstMap::union(
  self : FstMap,
  other : FstMap,
  policy : DuplicatePolicy,
) -> FstMap raise FstError {
  merge([self.fst, other.fst], Union).into_map(policy)
}

///|
pub fn FstMap::intersection(
  self : FstMap,
  other : FstMap,
  policy : DuplicatePolicy,
) -> FstMap raise FstError {
  merge([self.fst, other.fst], Intersection).into_map(policy)
}

///|
pub fn FstMap::difference(
  self : FstMap,
  other : FstMap,
) -> FstMap raise FstError {
  merge([self.fst, other.fst], Difference).into_map(KeepFirst)
}

///|
pub fn FstMap::symmetric_difference(
  self : FstMap,
  other : FstMap,
) -> FstMap raise FstError {
  merge([self.fst, other.fst], SymmetricDifference).into_map(KeepFirst)
}
