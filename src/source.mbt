///|
/// A consumable byte-lexicographic stream of unique keys. Sources own their
/// iteration position and must not be consumed concurrently through aliases.
/// Applications can implement this for file readers and database cursors.
pub(open) trait EntrySource {
  fn next(Self) -> Entry? raise FstError
  fn close(Self) -> Unit
}

///|
pub impl EntrySource for Stream with fn next(self) {
  Stream::next(self)
}

///|
pub impl EntrySource for Stream with fn close(self) {
  Stream::close(self)
}

///|
/// A source backed by a copied array of immutable entries.
pub struct ArraySource {
  priv entries : Array[Entry]
  priv mut position : Int32
}

///|
/// Validate input order once without constructing an intermediate FST.
pub fn ArraySource::from_sorted(
  entries : Array[Entry],
) -> ArraySource raise FstError {
  let owned = entries.copy()
  for position = 1; position < owned.length(); position = position + 1 {
    let previous = owned[position - 1].key
    let next = owned[position].key
    let comparison = previous.lexical_compare(next)
    if comparison > 0 {
      raise OutOfOrder(previous, next)
    } else if comparison == 0 {
      raise DuplicateKey(next)
    }
  }
  { entries: owned, position: 0, }
}

///|
/// Set input permits and coalesces consecutive repeated keys.
pub fn ArraySource::from_sorted_keys(
  keys : Array[Bytes],
) -> ArraySource raise FstError {
  let entries = []
  let mut previous : Bytes? = None
  for key in keys {
    if previous is Some(before) {
      let comparison = before.lexical_compare(key)
      if comparison > 0 {
        raise OutOfOrder(before, key)
      } else if comparison == 0 {
        continue
      }
    }
    entries.push(Entry::{ key, value: 0UL, })
    previous = Some(key)
  }
  { entries, position: 0, }
}

///|
pub fn ArraySource::remaining(self : ArraySource) -> Int32 {
  self.entries.length() - self.position
}

///|
pub impl EntrySource for ArraySource with fn next(self) {
  if self.position >= self.entries.length() {
    None
  } else {
    let result = self.entries[self.position]
    self.position = self.position + 1
    Some(result)
  }
}

///|
pub impl EntrySource for ArraySource with fn close(self) {
  self.position = self.entries.length()
}

///|
/// A validating adapter. A source error or order violation permanently closes
/// this adapter, preventing stale data from leaking after a caught error.
pub struct CheckedSource {
  priv source : &EntrySource
  priv mut previous : Bytes?
  priv mut closed : Bool
}

///|
pub fn CheckedSource::new(source : &EntrySource) -> CheckedSource {
  { source, previous: None, closed: false, }
}

///|
pub impl EntrySource for CheckedSource with fn next(self) {
  if self.closed {
    return None
  }
  errdefer self.close()
  let next = self.source.next()
  match next {
    None => {
      self.close()
      None
    }
    Some(entry) => {
      if self.previous is Some(previous) {
        let comparison = previous.lexical_compare(entry.key)
        if comparison >= 0 {
          if comparison == 0 {
            raise DuplicateKey(entry.key)
          } else {
            raise OutOfOrder(previous, entry.key)
          }
        }
      }
      self.previous = Some(entry.key)
      // Preserve the underlying Option instead of unboxing and rebuilding it.
      // Its owned entry and key remain valid after the next read.
      next
    }
  }
}

///|
pub impl EntrySource for CheckedSource with fn close(self) {
  if !self.closed {
    self.closed = true
    self.source.close()
  }
}

///|
/// Filter entries lazily while preserving their key order.
pub struct FilterSource {
  priv source : &EntrySource
  priv predicate : (Entry) -> Bool raise FstError
  priv mut closed : Bool
}

///|
pub fn filter_source(
  source : &EntrySource,
  predicate : (Entry) -> Bool raise FstError,
) -> FilterSource {
  { source, predicate, closed: false, }
}

///|
pub impl EntrySource for FilterSource with fn next(self) {
  if self.closed {
    return None
  }
  errdefer self.close()
  while self.source.next() is Some(entry) {
    if (self.predicate)(entry) {
      return Some(entry)
    }
  }
  self.close()
  None
}

///|
pub impl EntrySource for FilterSource with fn close(self) {
  if !self.closed {
    self.closed = true
    self.source.close()
  }
}

///|
/// Transform only values; keys and ordering are preserved.
pub struct MapSource {
  priv source : &EntrySource
  priv transform : (Entry) -> UInt64 raise FstError
  priv mut closed : Bool
}

///|
pub fn map_source(
  source : &EntrySource,
  transform : (Entry) -> UInt64 raise FstError,
) -> MapSource {
  { source, transform, closed: false, }
}

///|
pub impl EntrySource for MapSource with fn next(self) {
  if self.closed {
    return None
  }
  errdefer self.close()
  match self.source.next() {
    None => {
      self.close()
      None
    }
    Some(entry) => Some({ key: entry.key, value: (self.transform)(entry), })
  }
}

///|
pub impl EntrySource for MapSource with fn close(self) {
  if !self.closed {
    self.closed = true
    self.source.close()
  }
}

///|
/// Skip and bound results without consuming anything at construction.
pub struct WindowSource {
  priv source : &EntrySource
  priv mut skip : UInt64
  priv mut remaining : UInt64
  priv mut closed : Bool
}

///|
pub fn window_source(
  source : &EntrySource,
  offset : UInt64,
  limit : UInt64,
) -> WindowSource {
  { source, skip: offset, remaining: limit, closed: false, }
}

///|
pub impl EntrySource for WindowSource with fn next(self) {
  if self.closed || self.remaining == 0UL {
    self.close()
    return None
  }
  errdefer self.close()
  while self.skip > 0UL {
    match self.source.next() {
      None => {
        self.close()
        return None
      }
      Some(_) => self.skip = self.skip - 1UL
    }
  }
  match self.source.next() {
    None => {
      self.close()
      None
    }
    Some(entry) => {
      self.remaining = self.remaining - 1UL
      Some(entry)
    }
  }
}

///|
pub impl EntrySource for WindowSource with fn close(self) {
  if !self.closed {
    self.closed = true
    self.source.close()
  }
}

///|
/// Extend a builder from an application source without temporary arrays.
/// Set builders coalesce sorted duplicates; map builders require unique keys.
pub fn Builder::extend_source(
  self : Builder,
  source : &EntrySource,
) -> Unit raise FstError {
  while source.next() is Some(entry) {
    if self.map_mode {
      self.insert(entry.key, entry.value)
    } else {
      self.add(entry.key)
    }
  }
}

///|
pub fn collect_source(source : &EntrySource) -> Array[Entry] raise FstError {
  let result = []
  while source.next() is Some(entry) {
    result.push(entry)
  }
  result
}

///|
/// Fold without allocating a collection of all results.
pub fn[A] fold_source(
  source : &EntrySource,
  initial : A,
  step : (A, Entry) -> A raise?,
) -> A raise {
  let mut accumulator = initial
  while source.next() is Some(entry) {
    accumulator = step(accumulator, entry)
  }
  accumulator
}
