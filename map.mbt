///|
/// Build from strictly increasing byte keys. Duplicate keys are an error.
pub fn FstMap::from_sorted(
  entries : Array[Entry],
  registry_capacity~ : Int32 = 20000,
) -> FstMap raise FstError {
  let builder = Builder::map(registry_capacity~)
  builder.extend_entries(entries)
  builder.into_map()
}

///|
/// Resolve duplicates in original input order, independently of sort stability.
pub fn FstMap::from_entries(
  entries : Array[Entry],
  duplicates~ : DuplicatePolicy = Reject,
  registry_capacity~ : Int32 = 20000,
) -> FstMap raise FstError {
  let ordered = entries.mapi(fn(i, entry) { (i, entry) })
  ordered.sort_by(fn(a, b) {
    let order = a.1.key.lexical_compare(b.1.key)
    if order == 0 {
      a.0.compare(b.0)
    } else {
      order
    }
  })
  let builder = Builder::map(registry_capacity~)
  let mut index = 0
  while index < ordered.length() {
    let entry = ordered[index].1
    let mut value = entry.value
    index = index + 1
    while index < ordered.length() && ordered[index].1.key == entry.key {
      let next = ordered[index].1.value
      value = match duplicates {
        Reject => raise DuplicateKey(entry.key)
        KeepFirst => value
        KeepLast => next
        Sum => checked_add(value, next)
        Minimum => if value < next { value } else { next }
        Maximum => if value > next { value } else { next }
      }
      index = index + 1
    }
    builder.insert(entry.key, value)
  }
  builder.into_map()
}

///|
pub fn FstMap::from_strings(
  entries : Array[(String, UInt64)],
  duplicates~ : DuplicatePolicy = Reject,
  registry_capacity~ : Int32 = 20000,
) -> FstMap raise FstError {
  FstMap::from_entries(
    entries.map(fn(entry) {
      Entry::{ key: string_bytes(entry.0), value: entry.1, }
    }),
    duplicates~,
    registry_capacity~,
  )
}

///|
pub fn FstMap::from_bytes(data : Bytes) -> FstMap raise FstError {
  { fst: Fst::from_bytes(data), }
}

///|
pub fn FstMap::as_fst(self : FstMap) -> Fst {
  self.fst
}

///|
pub fn FstMap::as_set(self : FstMap) -> FstSet {
  { fst: self.fst, }
}

///|
pub fn FstMap::to_bytes(self : FstMap) -> Bytes {
  self.fst.to_bytes()
}

///|
pub fn FstMap::len(self : FstMap) -> UInt64 {
  self.fst.len()
}

///|
pub fn FstMap::is_empty(self : FstMap) -> Bool {
  self.fst.is_empty()
}

///|
pub fn FstMap::get(self : FstMap, key : Bytes) -> UInt64? raise FstError {
  self.fst.get(key)
}

///|
pub fn FstMap::get_str(self : FstMap, key : String) -> UInt64? raise FstError {
  self.fst.get_str(key)
}

///|
pub fn FstMap::contains(self : FstMap, key : Bytes) -> Bool raise FstError {
  self.fst.contains(key)
}

///|
pub fn FstMap::stream(
  self : FstMap,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.fst.stream(range~)
}

///|
pub fn FstMap::search(
  self : FstMap,
  matcher : &@automaton.Automaton,
  range~ : KeyRange = KeyRange::all(),
) -> Stream raise FstError {
  self.fst.search(matcher, range~)
}

///|
pub fn FstMap::prefix(self : FstMap, prefix : Bytes) -> Stream raise FstError {
  self.fst.prefix(prefix)
}

///|
pub fn FstMap::prefix_str(
  self : FstMap,
  prefix : String,
) -> Stream raise FstError {
  self.fst.prefix_str(prefix)
}

///|
pub fn FstMap::entries(self : FstMap) -> Array[Entry] raise FstError {
  self.stream().collect()
}

///|
pub fn FstMap::string_entries(
  self : FstMap,
) -> Array[(String, UInt64)] raise FstError {
  self.stream().string_entries()
}

///|
pub fn FstMap::from_stream(
  stream : Stream,
  registry_capacity~ : Int32 = 20000,
) -> FstMap raise FstError {
  let builder = Builder::map(registry_capacity~)
  builder.extend_stream(stream)
  builder.into_map()
}

///|
pub fn FstMap::slice(self : FstMap, range : KeyRange) -> FstMap raise FstError {
  FstMap::from_stream(self.stream(range~))
}

///|
pub fn FstMap::rebuild(
  self : FstMap,
  registry_capacity~ : Int32 = 20000,
) -> FstMap raise FstError {
  FstMap::from_stream(self.stream(), registry_capacity~)
}

///|
/// Compare logical key/value pairs rather than implementation-dependent bytes.
pub fn FstMap::same_entries(
  self : FstMap,
  other : FstMap,
) -> Bool raise FstError {
  if self.len() != other.len() {
    return false
  }
  let left = self.stream()
  let right = other.stream()
  while left.next() is Some(a) {
    match right.next() {
      Some(b) if a == b => ()
      _ => return false
    }
  }
  right.next() is None
}

///|
/// Transform values while preserving key order and compact output factoring.
pub fn FstMap::map_values(
  self : FstMap,
  f : (Bytes, UInt64) -> UInt64 raise?,
) -> FstMap raise {
  let builder = Builder::map()
  let stream = self.stream()
  while stream.next() is Some(entry) {
    builder.insert(entry.key, f(entry.key, entry.value))
  }
  builder.into_map()
}
