///|
/// A descending byte-lexicographic traversal. It intentionally does not
/// implement EntrySource, whose contract requires ascending keys.
pub struct ReverseStream {
  priv inner : Stream
}

///|
/// Traverse greatest keys first without collecting and reversing a forward
/// traversal. Memory is proportional to the active path.
pub fn Fst::reverse(
  self : Fst,
  range~ : KeyRange = KeyRange::all(),
) -> ReverseStream raise FstError {
  {
    inner: self.search_direction(
      @automaton.always(),
      range,
      true,
      unfiltered=true,
    ),
  }
}

///|
/// Automaton states still consume each key from its first byte to its last;
/// reverse traversal changes only the order in which complete keys are emitted.
pub fn Fst::search_reverse(
  self : Fst,
  matcher : &@automaton.Automaton,
  range~ : KeyRange = KeyRange::all(),
) -> ReverseStream raise FstError {
  { inner: self.search_direction(matcher, range, true), }
}

///|
pub fn ReverseStream::next(self : ReverseStream) -> Entry? raise FstError {
  self.inner.next()
}

///|
pub fn ReverseStream::close(self : ReverseStream) -> Unit {
  self.inner.close()
}

///|
pub fn ReverseStream::take(
  self : ReverseStream,
  count : Int32,
) -> Array[Entry] raise FstError {
  self.inner.take(count)
}

///|
pub fn ReverseStream::skip(
  self : ReverseStream,
  count : Int32,
) -> Int32 raise FstError {
  self.inner.skip(count)
}

///|
pub fn ReverseStream::collect(
  self : ReverseStream,
) -> Array[Entry] raise FstError {
  self.inner.collect()
}

///|
pub fn ReverseStream::keys(self : ReverseStream) -> Array[Bytes] raise FstError {
  self.inner.keys()
}

///|
pub fn ReverseStream::strings(
  self : ReverseStream,
) -> Array[String] raise FstError {
  self.inner.strings()
}

///|
pub fn ReverseStream::count(self : ReverseStream) -> UInt64 raise FstError {
  self.inner.count()
}

///|
pub fn FstSet::reverse(
  self : FstSet,
  range~ : KeyRange = KeyRange::all(),
) -> ReverseStream raise FstError {
  self.fst.reverse(range~)
}

///|
pub fn FstMap::reverse(
  self : FstMap,
  range~ : KeyRange = KeyRange::all(),
) -> ReverseStream raise FstError {
  self.fst.reverse(range~)
}

///|
/// Offset is relative to the greatest key in the selected range. Use this for
/// backward pagination without enumerating the preceding descending results.
pub fn FstIndex::page_reverse(
  self : FstIndex,
  offset : UInt64,
  limit : Int32,
  range~ : KeyRange = KeyRange::all(),
) -> Array[Entry] raise FstError {
  if limit < 0 {
    raise InvalidArgument("page limit must be nonnegative")
  }
  let (lower, upper) = self.range_ranks(range)
  if limit == 0 || offset >= upper - lower {
    return []
  }
  match self.select(upper - 1UL - offset) {
    None => []
    Some(first) =>
      self.fst
      .reverse(range={ lower: range.lower, upper: Included(first.key), })
      .take(limit)
  }
}

///|
/// Page matching keys in descending order without changing the reusable index.
pub fn SearchIndex::page_reverse(
  self : SearchIndex,
  offset : UInt64,
  limit : Int32,
  range~ : KeyRange = KeyRange::all(),
) -> Array[Entry] raise FstError {
  if limit < 0 {
    raise InvalidArgument("page limit must be nonnegative")
  }
  let (lower, upper) = self.range_ranks(range)
  if limit == 0 || offset >= upper - lower {
    return []
  }
  match self.select(upper - 1UL - offset) {
    None => []
    Some(first) =>
      self.index.fst
      .search_reverse(self.matcher, range={
        lower: range.lower,
        upper: Included(first.key),
      })
      .take(limit)
  }
}
