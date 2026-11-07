# moonfst

`moonfst/fst` 将 Rust [`fst 0.4.7`](https://github.com/BurntSushi/fst/tree/fbd5992376f176c35af2644d74efad58f5656e5c) 的紧凑有序集合与映射移植到 MoonBit。键是任意字节串，值覆盖完整 `UInt64` 范围；相同前缀和等价后缀可以共享图结构，适合构建只读词典、自动补全索引、符号表和静态路由表。

运行库使用纯 MoonBit，不链接 Rust/C 库，也不依赖 JavaScript FFI。Rust 参考程序和 Python 脚本只用于开发验收。当前仓库是源码项目，尚未声明已发布到 Mooncakes。

## 快速运行

在仓库根目录运行词典示例：

```sh
moon run examples/dictionary --target wasm-gc
```

示例演示建表、中文前缀、Unicode 模糊查询、rank/page、最高词频和词频合计。也可以用 `--target native` 或 `--target js`。

本地消费项目使用新版 `moon.mod` 与 `moon.work`。例如将仓库 `moonfst/` 与消费项目 `consumer/` 放在同一目录，在它们的父目录创建 `moon.work`：

```text
members = [
  "./moonfst",
  "./consumer",
]
```

在 `consumer/moon.mod` 中声明依赖：

```text
name = "demo/consumer"

import {
  "moonfst/fst@0.1.0",
}
```

工作区按模块名解析本地成员，版本号不会触发 Mooncakes 下载。此配置遵循 MoonBit 的[本地依赖说明](https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html#dependency-management)。在 `consumer/moon.pkg` 中添加测试导入：

```text
import {
  "moonfst/fst" @fst,
  "moonfst/fst/automaton" @automaton,
} for "test"
```

下面是完整的 `consumer/quickstart_test.mbt`：

```moonbit
test {
  // 便捷构造器复制、排序输入；Set 自动合并重复键。
  let words = @fst.FstSet::from_strings(["月亮", "月光", "太阳", "月亮"])
  assert_eq(words.len(), 3UL)
  assert_eq(words.prefix_str("月").strings(), ["月亮", "月光"])

  // 编辑距离按 Unicode scalar value 计算。
  let fuzzy = @automaton.levenshtein("月亮", 1)
  assert_eq(words.search(fuzzy).strings(), ["月亮", "月光"])

  // Map 默认拒绝重复键；UInt64 不经过浮点数转换。
  let counts = @fst.FstMap::from_strings([
    ("apple", 10UL),
    ("apricot", 20UL),
    ("banana", 18446744073709551615UL),
  ])
  assert_eq(counts.get_str("banana"), Some(18446744073709551615UL))
  let restored = @fst.FstMap::from_bytes(counts.to_bytes())
  assert_eq(restored.get_str("apple"), Some(10UL))

  // 已有序的数据可以增量写入，避免先复制并排序所有键。
  let builder = @fst.Builder::map()
  builder.insert(b"a", 1UL)
  builder.insert(b"ab", 2UL)
  builder.insert(b"b", 3UL)
  let built = builder.into_map()
  assert_eq(built.get(b"ab"), Some(2UL))

  let index = built.as_fst().index()
  assert_eq(index.rank(b"ab"), (1UL, true))
  assert_eq(index.prefix_count(b"a"), 2UL)
  assert_eq(index.select(2UL).unwrap().key, b"b")

  // 对匹配结果直接计数、定位和分页，无须收集所有命中键。
  let matching = index.search_index(@automaton.prefix_bytes(b"a"))
  assert_eq(matching.len(), 2UL)
  assert_eq(matching.select(1UL).unwrap().key, b"ab")
  assert_eq(index.page_reverse(0UL, 1)[0].key, b"b")

  let statistics = index.prefix_value_statistics(b"a")
  assert_eq(statistics.sum, Some(3UL))
  assert_eq(index.top(1)[0].key, b"b")

  let cursor = built.as_fst().cursor()
  assert_true(cursor.advance_bytes(b"ab"))
  assert_eq(cursor.value(), Some(2UL))
}
```

在父目录运行 `moon -C consumer test . --target wasm-gc --deny-warn`。

## 数据与顺序

- 键按无符号字节的字典序排列；较短的公共前缀先出现。空键、NUL 和非法 UTF-8 都是合法的字节键。
- `*_str`、`from_strings` 使用 UTF-8 编码，不进行大小写折叠、规范化或语言相关排序。调用 `strings()` 遇到非法 UTF-8 会报错，且保留开头的 BOM 字符。
- `Builder::set` 要求非递减键，相同键合并；`Builder::map` 要求严格递增键，相同键报错。有序要求是 UTF-8 **字节序**，不能依赖 MoonBit 的 UTF-16 字符串比较来预排序任意文本。
- `FstMap::from_entries` 和 `from_strings` 可选择 `Reject`、`KeepFirst`、`KeepLast`、`Sum`、`Minimum`、`Maximum` 重复键策略。加法溢出明确报错。
- 构建结果不可原地修改。批量变更可以合并有序流，再构建新 FST。

`registry_capacity` 限制构建器保留的等价节点缓存；淘汰缓存可能降低后缀共享率，不改变查询结果。因此不承诺任意缓存大小都得到全局最小图。构建器的输出字节缓冲仍在内存中。

## 查询与集合操作

`FstSet`、`FstMap` 都提供精确查询、前缀流、自动机搜索和有界范围流。`KeyRange` 的上下界可分别包含或排除；`between` 是左闭右开，`closed` 是两端包含。`Stream` 按字节序惰性遍历，支持 `next`、`take`、`skip`、`count`、`close`。

`merge` / `MergeStream` 支持多路并集、交集、差集和对称差集，并保留每个值的来源编号。Map 合并再显式选择重复值的归约策略。多路对称差集使用奇数次出现语义。

本项目增加以下可选工具：

- **`FstIndex`**：缓存每个节点的后缀路径数，提供 `rank`、`select`、前缀计数、上下界、区间计数和分页；索引构建按图节点与边计算，不枚举全部键。缓存需要额外内存。
- **`SearchIndex`**：缓存 FST 与自动机的乘积图，对匹配结果提供计数、rank/select、范围查询和分页。`max_states` 限制乘积状态数；超限明确报错。自定义自动机的状态及剪枝承诺必须在索引整个使用期内保持稳定。
- **`ValueStatistics` 与 `top`**：`FstIndex` 可按前缀、键范围或序号区间统计条数、最小值、最大值与总和；总和超出 `UInt64` 时为 `None`，其他字段仍精确。`top` 使用子图最大值优先探索，按值降序返回结果，同值按字节序排列。
- **`ReverseStream`**：按字节序降序惰性遍历，支持范围和自动机搜索；自动机仍从键的首字节向后消费。`FstIndex` 和 `SearchIndex` 的 `page_reverse` 支持从大键一侧分页。
- **`Cursor`**：逐字节推进、回退、原子批量推进、定位和独立分叉。适合词法扫描或自定义遍历；推进失败保留原位置。

`EntrySource` 让应用接入按字节序严格递增的外部数据源；`Stream` 与经过顺序验证的 `ArraySource` 均实现此接口。`filter_source`、`map_source`、`window_source` 和 `fold_source` 允许惰性过滤、修改值、截取与归约，`Builder::extend_source` 和 `merge_sources` 可直接消费数据。`CheckedSource` 检查外部源的单调性；检查、过滤、值映射与窗口适配器在读取或回调失败后关闭底层源，并保持关闭，重复 `close` 不重复传递。多路合并也在失败时关闭全部输入。提前停止消费时应显式 `close`，同一可消费源不能通过别名并发迭代。降序的 `ReverseStream` 不实现要求升序的 `EntrySource`。

## 自动机

`automaton` 包包含精确字节匹配、前缀、字节子序列、并/交/补、`starts_with`、单字节范围、字节长度约束，以及可验证的显式 DFA 构建器。`Matcher` 实现公开的 `Automaton` trait，可直接传给 `search`，也支持用户自定义实现。

Levenshtein 自动机将插入、删除和替换各计为一次编辑，按 Unicode scalar value 计算，表情等补充平面字符计为一个标量，组合附加符号单独计数。它不把转置视为一次编辑，也不自动合并规范等价文本。例如 `é` 与 `e` 加组合重音之间的距离为 2。

Levenshtein 只接受严格有效的 UTF-8：截断、多余 continuation byte、过长编码、代理项及超出 U+10FFFF 的编码均不匹配。构造时预先建立有界 DFA，搜索时不维护增长缓存。`max_states` 和 `max_work` 超限返回 `AutomatonError`；不能通过超限后静默剪枝来产生不完整结果。复合自动机也检查状态编号乘积的上限。

自定义自动机的 `can_match` / `will_always_match` 是剪枝承诺，必须保持保守正确。状态 ID 在一次遍历中应稳定；EOF 转移只在完整键结尾应用一次。

## 格式兼容与内存边界

写入格式为 Rust fst **v3**，包括小端整数、节点编码、输出因子和 masked CRC32C 校验。固定参考版本是 `fst = "=0.4.7"`，上游提交 `fbd5992376f176c35af2644d74efad58f5656e5c`。双向验收比较完整键值与查询结果；不同构建器可以产生等价但字节不同的压缩图。

`Fst::from_bytes` 在开放查询前验证校验和及完整可达图，包括地址、边顺序、节点范围、接受键数量和路径输出溢出。读取器还识别旧版 v1/v2 元数据；跨语言参考验收主要针对 v3。

当前实现接收并完整验证内存 `Bytes`。精确查询和遍历直接读取压缩节点，公开节点检查才生成独立数组；不提供 mmap 或磁盘流式构建。地址受当前 `Int32` 可表示范围限制，不能据此承诺 Rust 上游的超大索引规模。`FstIndex` 会额外保留解码节点、累计计数和值统计；`SearchIndex` 还需乘积图缓存。

## 验证

与 Rust `fst 0.4.7` 的可复现 native release 基准：

```sh
python3 scripts/benchmark.py --output benchmarks/results/my-run
```

覆盖构建、命中/近似未命中查询、完整遍历、前缀查询、并集和编码大小；默认两种数据分布、三个规模，每项 21 个样本，并验证两边结果。测量方法见 [benchmarks/README.md](benchmarks/README.md)，优化后实测见 [基准报告](benchmarks/results/optimized-v1/REPORT.md)，原始慢版本的 [基线报告](benchmarks/results/latest/REPORT.md) 保留用于对照。

本轮两种分布、三个规模的命中与近似未命中查询均快于 Rust，编码文件尺寸相同；10 万条时查询加速约 1.55～2.08 倍。全量遍历基本持平，并集仍有差距。具体实现、安全前提、逐字节互操作和防优化屏障控制实验见 [优化与验收说明](benchmarks/results/optimized-v1/OPTIMIZATION.md)。

当前实测工具链为 `moon 0.1.20261104` 与 `moonc v0.10.20+65efd5b93`。配置采用 `moon.mod` / `moon.pkg`，整型索引采用 `Int32`，公开 trait 方法使用显式 `extend`。JavaScript 测试还需要 Node.js，native 测试需要工具链要求的 C 编译器。

```sh
moon fmt --check
moon test --target native --deny-warn
moon test --target js --deny-warn
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
```

跨语言验收另需 Python 3 和 Rust/Cargo：

```sh
cargo test --locked --manifest-path oracle/Cargo.toml
python3 scripts/generate_fixtures.py --check
python3 scripts/verify_oracle.py
python3 scripts/interop.py --target native --target js --target wasm-gc
python3 scripts/random_interop.py --target native
```

测试材料覆盖任意字节、完整 u64 边界、共享后缀、稠密分支、长路径、损坏输入和固定种子的随机差分。自动机另有独立标量 DP 对照和严格 UTF-8 解码对照。具体参考协议见 [oracle/README.md](oracle/README.md)，二进制样本见 [fixtures/README.md](fixtures/README.md)。

`python3 scripts/count_loc.py` 将生产 MoonBit、测试、生成文件和其他语言工具分开统计。实现细节见 [ARCHITECTURE.md](ARCHITECTURE.md)；来源与许可见 [THIRD_PARTY.md](THIRD_PARTY.md) 和 [LICENSE](LICENSE)。
