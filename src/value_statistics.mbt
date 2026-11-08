///|
/// Aggregate map outputs. An empty group has count 0, no extrema, and sum 0.
/// Sum is None only when the exact mathematical total exceeds UInt64::MAX;
/// individual outputs, extrema and counts remain exact.
#derive(Eq, @debug.Debug)
pub(all) struct ValueStatistics {
  count : UInt64
  minimum : UInt64?
  maximum : UInt64?
  sum : UInt64?
}

///|
fn empty_value_statistics() -> ValueStatistics {
  { count: 0UL, minimum: None, maximum: None, sum: Some(0UL), }
}

///|
fn value_singleton(value : UInt64) -> ValueStatistics {
  { count: 1UL, minimum: Some(value), maximum: Some(value), sum: Some(value), }
}

///|
fn add_without_wrap(a : UInt64, b : UInt64) -> UInt64? {
  let sum = a + b
  if sum < a {
    None
  } else {
    Some(sum)
  }
}

///|
fn multiply_without_wrap(a : UInt64, b : UInt64) -> UInt64? {
  if a == 0UL || b == 0UL {
    Some(0UL)
  } else if b > 18446744073709551615UL / a {
    None
  } else {
    Some(a * b)
  }
}

///|
/// Summaries here describe disjoint subsets of one validated FST, so their
/// count cannot exceed the checked footer count even when their sums overflow.
fn combine_value_statistics(
  a : ValueStatistics,
  b : ValueStatistics,
) -> ValueStatistics {
  let minimum = match (a.minimum, b.minimum) {
    (None, value) | (value, None) => value
    (Some(x), Some(y)) => Some(if x < y { x } else { y })
  }
  let maximum = match (a.maximum, b.maximum) {
    (None, value) | (value, None) => value
    (Some(x), Some(y)) => Some(if x > y { x } else { y })
  }
  let sum = match (a.sum, b.sum) {
    (Some(x), Some(y)) => add_without_wrap(x, y)
    _ => None
  }
  { count: a.count + b.count, minimum, maximum, sum, }
}

///|
/// Prepend a transition output to every represented suffix. Validation has
/// already proved each full path fits UInt64; only the group sum may overflow.
fn shift_value_statistics(
  summary : ValueStatistics,
  prefix : UInt64,
) -> ValueStatistics {
  let sum = match (summary.sum, multiply_without_wrap(prefix, summary.count)) {
    (Some(a), Some(b)) => add_without_wrap(a, b)
    _ => None
  }
  {
    count: summary.count,
    minimum: summary.minimum.map(fn(value) { value + prefix }),
    maximum: summary.maximum.map(fn(value) { value + prefix }),
    sum,
  }
}

///|
/// Aggregate all outputs in a range using cached subtree summaries. Whole
/// subtrees are consumed in one step; their keys are never enumerated.
pub fn FstIndex::value_statistics(
  self : FstIndex,
  range~ : KeyRange = KeyRange::all(),
) -> ValueStatistics {
  let (lower, upper) = self.range_ranks(range)
  self.summarize_interval(lower, upper)
}

///|
/// Aggregate a half-open interval of ordinal positions. Both endpoints may
/// equal len, but a reversed interval or endpoint beyond len is an error.
pub fn FstIndex::value_statistics_at(
  self : FstIndex,
  lower : UInt64,
  upper : UInt64,
) -> ValueStatistics raise FstError {
  if lower > upper || upper > self.len() {
    raise InvalidArgument("statistics ordinal interval is outside the index")
  }
  self.summarize_interval(lower, upper)
}

///|
/// All matching keys under a prefix, including the prefix itself if present.
pub fn FstIndex::prefix_value_statistics(
  self : FstIndex,
  prefix : Bytes,
) -> ValueStatistics {
  let (lower, upper) = self.prefix_ranks(prefix)
  self.summarize_interval(lower, upper)
}

///|
fn FstIndex::summarize_interval(
  self : FstIndex,
  lower : UInt64,
  upper : UInt64,
) -> ValueStatistics {
  let mut result = empty_value_statistics()
  if lower >= upper {
    return result
  }
  // Ordinals in a task are relative to the task's suffix language.
  let pending = [(self.fst.header.root, 0UL, lower, upper)]
  while pending.pop() is Some(task) {
    let (address, output, start, end) = task
    let indexed = self.nodes[address]
    if start == 0UL && end == indexed.count {
      result = combine_value_statistics(
        result,
        shift_value_statistics(indexed.summary, output),
      )
      continue
    }
    if start == 0UL && indexed.node.is_final {
      result = combine_value_statistics(
        result,
        value_singleton(output + indexed.node.final_output),
      )
    }
    for position = 0
        position < indexed.node.transitions.length()
        position = position + 1 {
      let first = indexed.cumulative[position]
      let last = indexed.cumulative[position + 1]
      if end <= first {
        break
      }
      if start >= last {
        continue
      }
      let edge = indexed.node.transitions[position]
      let child_start = if start > first { start - first } else { 0UL }
      let child_end = if end < last { end - first } else { last - first }
      if child_start < child_end {
        pending.push((edge.addr, output + edge.output, child_start, child_end))
      }
    }
  }
  result
}

///|
/// Extract the top outputs within a byte range using cached subtree maxima.
/// Results are ordered by descending value, with byte-lexical key tie breaks.
/// The frontier is a best-first heap, so a high-scoring narrow subtree can be
/// explored before a large subtree whose outputs are all lower.
pub fn FstIndex::top(
  self : FstIndex,
  limit : Int32,
  range~ : KeyRange = KeyRange::all(),
) -> Array[Entry] raise FstError {
  if limit < 0 {
    raise InvalidArgument("top limit must be nonnegative")
  }
  let results = []
  let (lower, upper) = self.range_ranks(range)
  if limit == 0 || lower >= upper {
    return results
  }
  let frontier : Array[ScoreItem] = []
  let root = self.nodes[self.fst.header.root]
  if root.summary.maximum is Some(maximum) {
    score_push(frontier, {
      address: self.fst.header.root,
      output: 0UL,
      key: b"",
      maximum,
      terminal: false,
    })
  }
  while results.length() < limit {
    match score_pop(frontier) {
      None => break
      Some(item) => {
        if item.terminal {
          results.push({ key: item.key, value: item.output, })
          continue
        }
        let node = self.nodes[item.address].node
        if node.is_final && range.contains(item.key) {
          let value = item.output + node.final_output
          score_push(frontier, {
            address: item.address,
            output: value,
            key: item.key,
            maximum: value,
            terminal: true,
          })
        }
        for edge in node.transitions {
          let bytes = item.key.to_array()
          bytes.push(edge.input)
          let key = Bytes::from_array(bytes)
          if !range.may_contain_prefix(key) {
            continue
          }
          let output = item.output + edge.output
          if self.nodes[edge.addr].summary.maximum is Some(suffix) {
            score_push(frontier, {
              address: edge.addr,
              output,
              key,
              maximum: output + suffix,
              terminal: false,
            })
          }
        }
      }
    }
  }
  results
}

///|
priv struct ScoreItem {
  address : Int32
  output : UInt64
  key : Bytes
  maximum : UInt64
  terminal : Bool
}

///|
fn score_before(a : ScoreItem, b : ScoreItem) -> Bool {
  if a.maximum != b.maximum {
    a.maximum > b.maximum
  } else {
    let order = a.key.lexical_compare(b.key)
    if order != 0 {
      order < 0
    } else {
      !a.terminal && b.terminal
    }
  }
}

///|
fn score_push(heap : Array[ScoreItem], item : ScoreItem) -> Unit {
  heap.push(item)
  let mut position = heap.length() - 1
  while position > 0 {
    let parent = (position - 1) / 2
    if !score_before(heap[position], heap[parent]) {
      break
    }
    let saved = heap[parent]
    heap[parent] = heap[position]
    heap[position] = saved
    position = parent
  }
}

///|
fn score_pop(heap : Array[ScoreItem]) -> ScoreItem? {
  if heap.is_empty() {
    return None
  }
  let first = heap[0]
  let last = heap.pop().unwrap()
  if !heap.is_empty() {
    heap[0] = last
    let mut position = 0
    while position < heap.length() / 2 {
      let left = position * 2 + 1
      let right = left + 1
      let child = if right < heap.length() &&
        score_before(heap[right], heap[left]) {
        right
      } else {
        left
      }
      if !score_before(heap[child], heap[position]) {
        break
      }
      let saved = heap[position]
      heap[position] = heap[child]
      heap[child] = saved
      position = child
    }
  }
  Some(first)
}
