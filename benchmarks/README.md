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


## 真实词典、随机查询顺序与进程内存

在 Linux 上运行独立的真实负载工具：

```sh
python3 scripts/workload_benchmark.py \
  --sizes 10000 100000 200000 --orders sorted shuffled \
  --samples 7 --warmups 2 --rounds 3 --memory-rounds 3 \
  --output benchmarks/results/my-real-run
```

脚本按固定 SHA256 下载 MIT 授权的 Jieba 中文词典，保留真实词频，随后
在独立 Python 参考实现中准备输入和预期结果。语料许可、固定提交、重复
记录处理与抽样规则见 [corpora/README.md](corpora/README.md)。下载文件与
派生工作负载位于被 Git 忽略的 `benchmarks/data/`；报告保留完整来源和指纹。

新增的 `benchmarks/workload` 和 `oracle/src/bin/fst_workload.rs` 使用同一份
二进制输入。A/B 各 N 条、重叠 N/2；每次按同一规则排序后构建自己的 FST。
分别测排序查询、固定种子打乱的查询，以及 50% 命中混合查询。查询命中
checksum、命中数、请求顺序 hash、A/B/并集 hash 均由 Python 独立验证，
每个 runner 在计时外对样本结果逐条比较。最后导出两边的 FST 作逐字节对照。

真实负载工具当前使用测量方法 `measurement_revision = 2`，二进制语料协议
仍为 `MFSTW001`。Rust 的输入记录使用 `Arc<[u8]>`，MoonBit 使用不可变
`Bytes`；A/B/并集与 hit 查询共享原词条的 key，miss 为每条请求新建追加 FF
的 key，mixed 共享已有 hit/miss key。Rust 的 timed stream/union 输出仍为
每条记录新建 `Vec<u8>`，MoonBit 对应输出也复制 key，未因输入共享减少
输出拥有所有权所需的工作。

两侧输入均来自运行时文件，查询循环消费每次 get 的结果并累计 sum/count。
Rust 保留批次结果的 `black_box`，不在逐 key 查询或输入参数上插入额外
屏障；MoonBit 在计时结束后用 `Bench.keep` 保留批次结果。两者的批次
防优化机制仍有实现差异，屏障不产生逐词成本。协调器严格校验 revision，
旧 runner 即使通过 `--skip-build` 启动也会被拒绝。

[历史真实基线 real-baseline-v1](results/real-baseline-v1/REPORT.md) 使用旧
Rust 输入布局：A/B/并集和查询数组深拷贝 `Vec<u8>` key，并对逐 key 查询
设置 `black_box`。该报告与原始数据保持不变，只能作为旧方法快照；其 RSS
和时间不能与 revision 2 混合汇总或直接解释为当前实现的语言差异。

内存用独立进程分阶段测量 `memory-baseline`、`memory-build`、
`memory-load`、`memory-union`。输入/输出一直保留到操作后快照；build 在
完整装载验证前记录快照，load 从预先导出的 FST 开始，不在该进程构建词典。
两侧读取 Linux `/proc/self/status` 的 VmRSS 与 VmHWM，记录操作前、操作后
和内容验证后的数据。高水位包含进程准备历史，RSS 包含输入表示、分配器
保留与语言运行时，不能把 `peak-before` 解释成精确库内存。
共享策略对齐后，Arc/Bytes 的头部、原子引用计数、容器布局和分配器仍不同，
总 RSS 仍不能直接归因于运行库。build 的装载验证后快照可能远高于构建
操作后快照；union 的进程高水位也可能在准备两个 FST 时已经达到。

MoonBit 装载验证完整可达图，Rust 对照装载只打开并校验 CRC；报告会明确
这项工作量差异。真实词典不等于真实查询日志：每词一次请求，未命中在键
后追加 FF，没有按词频加权，也不宣称覆盖冷缓存或磁盘吞吐。

该工具包只支持 native；其 C 辅助代码仅负责文件 I/O 与 Linux 内存读数，
不参与 FST 算法，并从发布包中排除。运行库仍然没有 Rust/C FFI 依赖。

不联网的完整工具协议复验：

```sh
python3 -m unittest scripts/test_benchmark.py scripts/test_workload_benchmark.py
python3 scripts/workload_smoke.py
```

第二条构建两个 release runner，在手工 UTF-8 小样本上核对两种查询顺序、
四种内存模式及最终编码；它验证正确性，不以小样本耗时作为性能结论。
