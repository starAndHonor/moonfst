///|
fn print_entries(title : String, entries : Array[@fst.Entry]) -> Unit raise {
  println(title)
  for entry in entries {
    let word = @utf8.decode(entry.key[:])
    println("  \{word}\t\{entry.value}")
  }
}

///|
fn dictionary_demo() -> Unit raise {
  // The convenience constructor accepts unsorted input and builds UTF-8 keys.
  let dictionary = @fst.FstMap::from_strings([
    ("月亮", 120UL),
    ("月光", 90UL),
    ("月球", 80UL),
    ("太阳", 200UL),
    ("星星", 150UL),
    ("星光", 70UL),
    ("月", 30UL),
    ("天空", 110UL),
  ])
  // The same bytes can be stored and loaded through the public v3 API.
  let restored = @fst.FstMap::from_bytes(dictionary.to_bytes())
  println("词条：\{restored.len()}")
  print_entries("前缀：月", restored.prefix_str("月").collect())

  let fuzzy = @automaton.levenshtein("月亮", 1)
  print_entries(
    "模糊查询：月亮（Unicode 编辑距离 ≤ 1）",
    restored.search(fuzzy).collect(),
  )

  let index = restored.as_fst().index()
  let (rank, exists) = index.rank_str("月亮")
  println("月亮的零基 rank：\{rank}；存在：\{exists}")
  print_entries("分页：跳过 4 条，最多取 3 条", index.page(4UL, 3))
  print_entries("词频最高的 3 条", index.top(3))
  let statistics = index.value_statistics()
  println("总词频：\{statistics.sum.unwrap()}")
}

///|
fn main {
  dictionary_demo() catch {
    error => abort(error.to_string())
  }
}
