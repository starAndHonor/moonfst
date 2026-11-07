///|
/// Construct from sorted byte keys. Equal consecutive keys are coalesced.
pub fn FstSet::from_sorted(
  keys : Array[Bytes],
  registry_capacity~ : Int32 = 20000,
) -> FstSet raise FstError {
  let builder = Builder::set(registry_capacity~)
  for key in keys {
    builder.add(key)
  }
  builder.into_set()
}

///|
/// Sort a copy; the caller's array is never reordered.
pub fn FstSet::from_keys(
  keys : Array[Bytes],
  registry_capacity~ : Int32 = 20000,
) -> FstSet raise FstError {
  let sorted = keys.copy()
  sorted.sort_by(fn(a, b) { a.lexical_compare(b) })
  FstSet::from_sorted(sorted, registry_capacity~)
}

///|
/// Strings are indexed by their UTF-8 bytes without normalization.
pub fn FstSet::from_strings(
  keys : Array[String],
  registry_capacity~ : Int32 = 20000,
) -> FstSet raise FstError {
  FstSet::from_keys(keys.map(string_bytes), registry_capacity~)
}

///|
/// Interpret any valid FST as a set by ignoring outputs, as Rust fst does.
pub fn FstSet::from_bytes(data : Bytes) -> FstSet raise FstError {
  { fst: Fst::from_bytes(data), }
}

///|
pub fn FstSet::as_fst(self : FstSet) -> Fst {
  self.fst
}

///|
pub fn FstSet::to_bytes(self : FstSet) -> Bytes {
  self.fst.to_bytes()
}

///|
pub fn FstSet::len(self : FstSet) -> UInt64 {
  self.fst.len()
}

///|
pub fn FstSet::is_empty(self : FstSet) -> Bool {
  self.fst.is_empty()
}

///|
pub fn FstSet::contains(self : FstSet, key : Bytes) -> Bool raise FstError {
  self.fst.contains(key)
}

///|
pub fn FstSet::contains_str(self : FstSet, key : String) -> Bool raise FstError {
  self.fst.contains_str(key)
}

///|
/// Results remain byte sorted and own their key bytes.
pub fn FstSet::stream(
  self : FstSet,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.fst.stream(range~)
}

///|
pub fn FstSet::search(
  self : FstSet,
  matcher : &@automaton.Automaton,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.fst.search(matcher, range~)
}

///|
pub fn FstSet::prefix(self : FstSet, prefix : Bytes) -> Stream raise FstError {
  self.fst.prefix(prefix)
}

///|
pub fn FstSet::prefix_str(
  self : FstSet,
  prefix : String,
) -> Stream raise FstError {
  self.fst.prefix_str(prefix)
}

///|
pub fn FstSet::keys(self : FstSet) -> Array[Bytes] raise FstError {
  self.stream().keys()
}

///|
/// Fails if any accepted key is not valid UTF-8.
pub fn FstSet::strings(self : FstSet) -> Array[String] raise FstError {
  self.stream().strings()
}

///|
/// Stream values and keys into a fresh zero-output set.
pub fn FstSet::from_stream(
  stream : Stream,
  registry_capacity~ : Int32 = 20000,
) -> FstSet raise FstError {
  let builder = Builder::set(registry_capacity~)
  builder.extend_stream(stream)
  builder.into_set()
}

///|
/// Keep only a range without allocating an intermediate array of keys.
pub fn FstSet::slice(self : FstSet, range : KeyRange) -> FstSet raise FstError {
  FstSet::from_stream(self.stream(range~))
}

///|
/// Re-encode keys with the current writer and chosen registry budget.
pub fn FstSet::rebuild(
  self : FstSet,
  registry_capacity~ : Int32 = 20000,
) -> FstSet raise FstError {
  FstSet::from_stream(self.stream(), registry_capacity~)
}

///|
/// Short-circuit comparison that does not materialize either set.
pub fn FstSet::is_subset(self : FstSet, other : FstSet) -> Bool raise FstError {
  if self.len() > other.len() {
    return false
  }
  let left = self.stream()
  let right = other.stream()
  let mut candidate = right.next()
  while left.next() is Some(entry) {
    while candidate is Some(value) && value.key.lexical_compare(entry.key) < 0 {
      candidate = right.next()
    }
    match candidate {
      Some(value) if value.key == entry.key => ()
      _ => return false
    }
  }
  true
}

///|
pub fn FstSet::is_superset(
  self : FstSet,
  other : FstSet,
) -> Bool raise FstError {
  other.is_subset(self)
}

///|
/// Compare logical keys; byte encodings may differ due to registry budgets.
pub fn FstSet::same_keys(self : FstSet, other : FstSet) -> Bool raise FstError {
  self.len() == other.len() && self.is_subset(other)
}

///|
pub fn FstSet::is_disjoint(
  self : FstSet,
  other : FstSet,
) -> Bool raise FstError {
  let left = self.stream()
  let right = other.stream()
  let mut a = left.next()
  let mut b = right.next()
  while a is Some(x) && b is Some(y) {
    let order = x.key.lexical_compare(y.key)
    if order == 0 {
      return false
    } else if order < 0 {
      a = left.next()
    } else {
      b = right.next()
    }
  }
  true
}
