# MoonFST

`starAndHonor/fst` 将 Rust [`fst 0.4.7`](https://github.com/BurntSushi/fst/tree/fbd5992376f176c35af2644d74efad58f5656e5c) 的紧凑有序集合与映射移植到 MoonBit。键是任意字节串，值覆盖完整 `UInt64` 范围；相同前缀和等价后缀可以共享图结构，适合构建只读词典、自动补全索引、符号表和静态路由表。

运行库使用纯 MoonBit，不链接 Rust/C 库，也不依赖 JavaScript FFI。Rust 参考程序、Python 脚本及真实负载工具的 C 文件仅用于开发验收；C 代码只负责文件 I/O 和 Linux RSS 读数，不参与 FST 算法。

## 安装与快速运行

在消费项目根目录安装 `starAndHonor/fst@0.1.1`：

```sh
moon add starAndHonor/fst@0.1.1
```

也可以在 `consumer/moon.mod` 中声明依赖：

```text
name = "demo/consumer"

import {
  "starAndHonor/fst@0.1.1",
}
```

在 `consumer/moon.pkg` 中添加测试导入：

```text
import {
  "starAndHonor/fst" @fst,
  "starAndHonor/fst/automaton" @automaton,
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

在消费项目根目录运行 `moon test . --target wasm-gc --deny-warn`。

### 源码仓库与复现

运行库及 MoonBit 测试、示例统一放在 `src/`，Rust 参考工具放在 `oracle/`，生成和验收入口放在 `scripts/`。固定样本、数据来源清单与历史报告提交到 Git；下载缓存和新测量输出可以从源码重新生成。

在 Linux x86_64 安装 Python 3.12+、Node.js 22、Rustup、`cc`、`curl` 后，从全新检出运行：

```sh
python3 scripts/bootstrap.py
. artifacts/env.sh
bash scripts/reproduce.sh
```

工具链版本与下载摘要固定在 `toolchain.json`，Rust 版本固定在 `rust-toolchain.toml`。验收覆盖四后端、Rust 双向互操作，以及实际发布归档与仓库外消费者。完整性能复现使用 `bash scripts/reproduce.sh --bench`；新结果写入忽略的 `artifacts/benchmarks/`。目录职责与维护约定见 [CONTRIBUTING.md](https://github.com/starAndHonor/moonfst/blob/main/CONTRIBUTING.md)，缓存重建及离线条件见 [REPRODUCING.md](https://github.com/starAndHonor/moonfst/blob/main/REPRODUCING.md)。这两个开发文档在源码仓库提供，不随 Mooncakes 包发布。

### 本地工作区

发布前或需要修改源码时，可以使用本地工作区。将仓库 `moonfst/` 与消费项目 `consumer/` 放在同一目录，在它们的父目录创建 `moon.work`：

```text
members = [
  "./moonfst",
  "./consumer",
]
```

消费项目仍使用上面的依赖与导入配置；工作区按模块名解析本地成员，版本号不会触发 Mooncakes 下载。此配置遵循 MoonBit 的[本地依赖说明](https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html#dependency-management)。在父目录运行 `moon -C consumer test . --target wasm-gc --deny-warn`。

### 词典示例

在源码仓库根目录运行：

```sh
moon run src/examples/dictionary --target wasm-gc
```

示例演示建表、中文前缀、Unicode 模糊查询、rank/page、最高词频和词频合计。也可以用 `--target native` 或 `--target js`。

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

以下开发命令从[源码仓库](https://github.com/starAndHonor/moonfst)根目录运行。Mooncakes 发布归档保留运行库、单元测试、示例及说明文档；基准、外部语料、Rust/Python 工具和跨语言集成入口仅在源码仓库提供。

### 合成数据基准

与 Rust `fst 0.4.7` 的可复现 native release 基准：

```sh
python3 scripts/benchmark.py --output artifacts/benchmarks/my-run
```

覆盖构建、命中/近似未命中查询、完整遍历、前缀查询、并集和编码大小；默认两种数据分布、三个规模，每项 21 个样本，并验证两边结果。测量方法见 [benchmarks/README.md](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/README.md)，2026-11-06 查询优化后的实测见[基准报告](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/optimized-v1/REPORT.md)，原始慢版本的[基线报告](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/latest/REPORT.md)保留用于对照。

该次合成数据测量中，两种分布、三个规模的排序命中与近似未命中查询均快于 Rust，编码文件尺寸相同；10 万条时查询加速约 1.55～2.08 倍。全量遍历基本持平，并集仍有差距。具体实现、安全前提、逐字节互操作和防优化屏障控制实验见[优化与验收说明](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/optimized-v1/OPTIMIZATION.md)。这些数字对应报告记录的源码与环境，不代表后续改动后的重新测量。

### 真实词典、查询顺序与 RSS

在 Linux 上运行真实负载工具：

```sh
python3 scripts/workload_benchmark.py \
  --sizes 10000 100000 200000 --orders sorted shuffled \
  --samples 7 --warmups 2 --rounds 3 --memory-rounds 3 \
  --output artifacts/benchmarks/my-real-run
```

工具按固定提交与 SHA256 读取 MIT 授权的 Jieba 词典，保留词频，从 349,045 个唯一词条中抽样；A/B 各 N 条、重叠 N/2。每词一次查询，比较排序与固定种子打乱的顺序，以及 50% 命中混合请求。近似未命中是在完整 UTF-8 词条后追加 `FF`；这些请求不是实际查询日志，也没有按词频加权。Python 独立校验 A/B、并集、查询顺序及操作结果。

2026-11-07 的[优化后真实词典报告](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-optimized-v1/REPORT.md)采用测量方法 revision 2：两端共享不可变输入键，查询只保留批次级防优化处理，每项 3 轮 × 7 次采样。shuffled 运行组中，1 万、10 万、20 万条并集耗时分别为 Rust 的 **80.8%、78.9%、83.4%**；sorted 运行组的 10 万条并集基本持平。20 万条 shuffled 命中/未命中/混合查询耗时分别为 Rust 的 73.2%、73.9%、53.2%。三档编码逐字节相同，分别为 123,328、1,035,223、1,949,554 B。这些是单机中位数，完整分位数与限制见报告。

[旧真实词典基线](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-baseline-v1/REPORT.md)保留原始证据；它使用旧 Rust 输入深拷贝和逐查询屏障，不能与 revision 2 混合汇总。实现改动与受控前后比较见[并集优化说明](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-optimized-v1/OPTIMIZATION.md)。语料来源和许可证见[语料说明](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/corpora/README.md)。

内存测量为 baseline/build/load/union 各自启动新进程，读取 Linux `/proc/self/status` 的 `VmRSS` 与 `VmHWM`，保留操作前、操作后和内容验证后的快照。RSS 包含输入表示、分配器保留及运行时；高水位包含准备阶段，不能视为精确堆分配或操作净内存。load 使用预先导出的 FST：Rust 打开并校验 CRC，MoonBit 还验证完整可达图，两者工作量不同。全新进程不等于冷缓存，以上均为单机 native 热运行，不外推到磁盘吞吐或其他后端。

### 正确性复验

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

测试材料覆盖任意字节、完整 u64 边界、共享后缀、稠密分支、长路径、损坏输入和固定种子的随机差分。自动机另有独立标量 DP 对照和严格 UTF-8 解码对照。具体参考协议见 [oracle/README.md](https://github.com/starAndHonor/moonfst/blob/main/oracle/README.md)，二进制样本见 [fixtures/README.md](https://github.com/starAndHonor/moonfst/blob/main/fixtures/README.md)，完整复验步骤见[开发工具说明](https://github.com/starAndHonor/moonfst/blob/main/scripts/README.md)。

`python3 scripts/count_loc.py` 将生产 MoonBit、测试、生成文件和其他语言工具分开统计。实现细节见 [ARCHITECTURE.md](ARCHITECTURE.md)；来源与许可见 [THIRD_PARTY.md](THIRD_PARTY.md) 和 [LICENSE](LICENSE)。
