# MoonFST 与 Rust fst 基准

这组基准比较 MoonFST 与固定版本 Rust `fst = 0.4.7` 完成相同 Map 工作负载的耗时和编码大小。两侧使用各自默认 builder 生成的图，并在各自的图上查询；结果反映整个库的实现，包括节点布局、缓存、分配和运行时成本，不能据此推导 MoonBit 与 Rust 的语言速度差异。

## 运行

在仓库根目录执行：

```sh
python3 scripts/benchmark.py --cpu 2 --output benchmarks/results/my-run
```

完整采样参数如下；选择本机可用的 CPU 和尚未存在的输出目录：

```sh
python3 scripts/benchmark.py \
  --sizes 1000 10000 100000 \
  --shapes shared random \
  --samples 7 --warmups 2 --rounds 3 \
  --cpu 2 --output benchmarks/results/my-run
```

脚本构建并运行两个 **native release** 执行文件：MoonBit runner 和 Rust runner。构建使用当前工具链，Rust 依赖受 `oracle/Cargo.lock` 与精确版本约束；复现时应一起保留结果中的机器、工具链和运行参数信息。

`--cpu N` 可指定逻辑 CPU；`--no-affinity` 关闭绑核。实际使用的 CPU 及亲和性设置以本次报告为准。`--skip-build` 复用已有 release 执行文件，适合在源码与构建产物一致时重复采样。

先检查协议和正确性的较小运行：

```sh
python3 scripts/benchmark.py \
  --sizes 1000 --samples 3 --warmups 1 --rounds 1 \
  --output oracle/target/benchmark-smoke
```

小规模 smoke 用于验证入口与结果校验流程，不作为正式性能结论。

## 数据协议

`n` 是每个 Map 的条目数，必须是至少为 2 的偶数。固定种子为 `0x00c0ffee`，即十进制 `12648430`。先按原始序号 `i = 0 .. 3*n/2-1` 生成总共 `3*n/2` 条记录：A 取 `i < n`，B 取 `i >= n/2`。A、B 各有 `n` 条，重叠 `n/2` 条，union 有 `3*n/2` 条。最后分别按原始字节的字典序排序。

| shape | key 生成规则 | key 长度 |
| --- | --- | --- |
| `shared` | `b"catalog/" + [Byte(i % 64)] + b"/item/" + hex8(i) + b"/meta"` | 28 字节 |
| `random` | 连续 LCG 生成的 12 字节，再追加 `i` 的 4 字节大端表示 | 16 字节 |

`hex8(i)` 为高位在前、宽度 8 的小写 ASCII 十六进制。`[Byte(i % 64)]` 是单个原始字节，包含 NUL 等非文本字节。random 的 LCG 状态连续跨 key 推进，每产生一个字节先执行：

```text
state = (state * 1664525 + 1013904223) mod 2^32
byte  = state >> 24
```

随机部分使用固定种子，序号后缀保证 key 唯一。两种 shape 的 value 都是：

```text
value = (UInt64(i) << 32) | UInt64((UInt32(i) * 2654435761) mod 2^32)
```

所有查询 key、near-miss key、prefix 的上下界都在开始采样前准备好。

## 测量的操作

每个进程按下表顺序执行。每个 sample 执行一次完整操作，不做自动扩大的批量循环。

| 指标 | 一次 sample 的工作 | `result_count` |
| --- | --- | --- |
| `build` | 从排序好的 A 新建 Map builder，逐条插入，返回完成的编码字节 | `n` |
| `lookup_hit` | 按 A 的排序顺序查询全部 `n` 个已存在 key | `n` |
| `lookup_miss` | 查询全部 `n` 个 near-miss key；每个 key 为 A 的 key 后追加 `0xff` | 命中数，应为 0 |
| `stream_owned` | 遍历 A，收集所有拥有独立 key 的 `(key, value)` 记录 | `n` |
| `prefix_owned` | 执行 32 个 prefix 范围查询，每个范围各自收集拥有 key 的结果，再按查询顺序扁平化 | 实际输出条目数 |
| `union_owned` | 合并 A 和 B，完整收集拥有 key 的结果；重复 key 选择 source index 较小者的 value | `3*n/2` |

prefix 的 `p` 从 0 到 31。shared 使用 `b"catalog/" + [p] + b"/"`，random 使用单字节 `[p]`；两侧均使用预计算的闭下界、开上界范围。它们不是把同一次结果重复测 32 遍，而是 32 个不同范围。union 的重叠记录本来具有相同 value，但 Rust 侧仍明确按 source index 选择，避免依赖上游返回的冲突值顺序。[上游 Map union 接口](https://github.com/BurntSushi/fst/blob/fbd5992376f176c35af2644d74efad58f5656e5c/src/map.rs)

`stream_owned`、`prefix_owned`、`union_owned` 均为每个输出 key 创建拥有所有权的副本，避免把 Rust 的借用游标与 MoonBit 的完整收集直接比较。操作期间为最终结果及中间状态进行的分配计入耗时。

## 计时边界与实现差异

Rust 使用 `std::time::Instant` 和 `std::hint::black_box`。MoonBit 使用 core/bench 的单调时钟，`monotonic_clock_end` 返回微秒；报告统一保存 `samples_us`。这里直接采集每次完整操作的耗时，没有采用 core/bench 的自适应批次大小。[core/bench 时钟文档](https://mooncakes.io/docs/moonbitlang/core/bench#monotonic_clock_end)

两种语言的防优化机制并不相同：Rust 在每个 lookup key 上使用 `black_box`，并在停止计时前对批次结果使用 `black_box`；MoonBit 在停止计时后用 `Bench.keep` 保留结果，再执行断言。动态输入、结果依赖和生成 C 中保留的查询调用表明 MoonBit 并未省去查询。为检查每 key 屏障的影响，本轮另保留仅删除 Rust 两处 `black_box(key)` 的[控制实验](results/optimized-v1/lookup-barrier-control.json)，其余屏障和工作不变。

计时从调用操作前开始，到结果产生并保留后结束。`lookup_hit` 的 wrapping sum 和 `lookup_miss` 的命中计数在计时内进行，用来消费每次查找结果；它们包含相应加法或分支的成本。其余指标的完整记录 hash、正确性比较及最终结果的释放位于计时外，最终结果在下一次计时前释放。操作内部为推进算法而释放临时状态的成本仍计入。

数据生成、排序、构造查询、预建查询用 Map、装载验证、进程启动、JSON 编解码与文件 I/O 均不计入指标。Rust `build` 使用 `MapBuilder::memory()`、`insert()`、`into_inner()`，不包含 `Map::new()` 或验证；MoonBit 也在构建返回编码字节后停止计时。查询用 Map 在采样前准备并核验。这里没有把 MoonBit 的完整图验证与 Rust 仅打开 footer 的成本作比较，也不提供 CRC 或完整验证的性能指标。[上游 builder 源码](https://github.com/BurntSushi/fst/blob/fbd5992376f176c35af2644d74efad58f5656e5c/src/raw/build.rs)

两个 builder 当前默认均采用 10,000 个桶、每桶 2 个最近使用的节点槽位，共 20,000 slots。MoonFST 使用与 Rust 0.4.7 相同的节点 fingerprint 规则，仍逐字段检查节点相等；命中时直接比较未完成节点，仅 miss 时保存独立 packed-word 签名，并可复用被淘汰 slot 的 buffer。基准仍在两侧各自构建的图上查询，并保留各自 `fst_bytes`；该值是单独的空间指标，不代替完整记录校验。[上游 registry 源码](https://github.com/BurntSushi/fst/blob/fbd5992376f176c35af2644d74efad58f5656e5c/src/raw/registry.rs)

## 正确性与校验值

Python 独立生成预期记录、dataset hash、各操作的 checksum 和结果数量，验证两个 runner 的进程级 JSON 摘要。每个 runner 在内部检查每次 warmup 与 sample 的结果；Python 不接收逐样本完整输出记录。build 的每次输出与该 runner 已解码、校验的参考编码逐字节比较，比较位于计时外。

`dataset_hash` 采用 FNV-1a 64 位，初始值 `14695981039346656037`、乘数 `1099511628211`，每步按 `2^64` 取模。按排序后的 A 顺序，对每条记录依次输入：key 的所有原始字节、key 长度的 4 字节小端表示、value 的 8 字节小端表示。owned 流输出使用同一记录 hash 规则，包括 prefix 的实际扁平化顺序。

| 指标 | checksum |
| --- | --- |
| `build` | 本次编码字节长度；只核对各自的正确构建，不跨实现比较长度相等 |
| `lookup_hit` | 所有命中 value 的 wrapping sum，模 `2^64` |
| `lookup_miss` | 命中数，应为 0 |
| 三项 owned 流 | 对实际输出记录序列计算上述 FNV-1a hash |

JSON 中的 64 位 checksum、dataset hash 使用十进制字符串，以保留全部精度。时间样本与记录数量使用 JSON 数字。

## 采样与结果文件

默认每个 case 运行三轮，每轮分别启动两种 engine，并交替先后顺序；每个进程内每项操作先 warmup 2 次，再采样 7 次。因此每个 `(shape, n, engine, metric)` 汇总 21 个原始时间样本。warmup 不进入统计；跨进程轮次帮助观察运行波动，但不会消除机器负载、频率变化或缓存状态的影响。

报告使用合并样本的中位数、p25/p75 与 p95；JSON/CSV 的时间单位为微秒，可读的 `REPORT.md` 表格换算为毫秒。分位数采用排序样本上的线性插值：对 `m` 个样本和分位 `q`，位置为 `(m-1)*q`，在相邻两个位置之间插值。它们描述这次采样的分布，不是置信区间；p95 也不是单次 get 的尾延迟，而是一次完整指标操作的样本分位数。

`--output` 目录保存可阅读的 `REPORT.md`、CSV 汇总和原始 JSON。应从这些文件引用实际机器和工具链对应的数值。本说明只定义方法，不预填尚未生成的性能结果。

脚本拒绝覆盖已有结果；再次测量请选择新的 `--output` 目录。本轮优化见 [优化后报告](results/optimized-v1/REPORT.md) 和 [优化与验收说明](results/optimized-v1/OPTIMIZATION.md)，原始慢版本见 [优化前报告](results/latest/REPORT.md)。可选图表需要 Matplotlib，正式计时结束后运行：

```sh
python3 scripts/plot_benchmark.py benchmarks/results/my-run
```

生成的 `comparison.png` 与 `comparison.svg` 展示最大规模下两种数据的耗时比值。采样和统计脚本本身只依赖 Python 标准库。

本轮使用可复现的合成数据，只测内存中的 native release 操作与最终编码大小。没有测 mmap、真实业务语料、磁盘吞吐、冷启动或峰值 RSS；`fst_bytes` 表示编码大小，不能作为运行时内存占用。实际选型还应在目标语料与部署环境中重新运行。

对原始查询差距的源码对照、结构计数和隔离消融实验见 [历史查询性能分析](results/query-analysis/ANALYSIS.md)。生产查询现已采用经完整验证后的压缩字节直接读取、小节点按字查找和无元组分配路径；遍历采用压缩游标。旧消融结果对应当时的源码快照，不能作为当前实现的消融结果。`query_ablation.py` 会拒绝在优化后的源码上重建旧实验，以免错误标注基线。
