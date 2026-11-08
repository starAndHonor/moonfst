# 本地验收记录

本文件保留 0.1.0 发布前的历史验收证据。后续源码目录统一迁移至 `src/`；当前复现入口、工具链锁定与发布归档检查见 [REPRODUCING.md](REPRODUCING.md)。历史性能数字不代表目录整理后的重新采样。

2026-11-07，使用 **moonc v0.10.20+65efd5b93**，moon / moonrun 为
**0.1.20261104 (940aa18)**，对 `starAndHonor/fst` 完成发布前本地验收。
CI 配置固定同一编译器与匹配 core；本记录不声称远程 CI 已运行。

## 本次正确性验收

完整 `scripts/check.sh` 验收通过：

| 检查 | 结果 |
|---|---|
| 格式与四后端编译 | 通过，项目 `--deny-warn` |
| Native 测试 | **143 / 143**：140 项库相关测试、3 项 native 工作负载测试 |
| JavaScript / Wasm / Wasm-GC 测试 | 各 **140 / 140** |
| Rust oracle 自测 | **3 / 3** |
| Rust 合成基准 / 真实工作负载自测 | **4 / 4**、**5 / 5** |
| Python 协议与统计测试 | **27 / 27**：合成基准 16 项、真实工作负载 11 项 |
| 固定二进制样本再生成、查询及损坏输入检查 | 通过，共 19 组固定样本 |
| Native 固定双向互操作 | **19 组、15,923 条记录** |
| Native 固定种子随机双向互操作 | **64 组、6,508 条记录** |
| 离线数据 workload smoke | 两种查询顺序、四种内存模式、两个引擎及编码逐字节对照全部通过 |

本次完整对拍在 **Native** 上运行，比较完整有序键值、完整 UInt64 数值、
CRC32C，以及精确查询、前缀和范围。Rust 参考为未修改的 crates.io
`fst = "=0.4.7"`，对应上游提交
`fbd5992376f176c35af2644d74efad58f5656e5c`，依赖由 Cargo.lock 固定。
workload smoke 使用手工 UTF-8 小样本，不下载 Jieba 词典；其耗时不作为
性能结论。协议及工具说明见
[开发验收说明](https://github.com/starAndHonor/moonfst/blob/main/scripts/README.md)。

测试保留任意字节、空键、完整 u64、压缩宽度 0..8、v1/v2/v3、256 路分支、
长路径、畸形文件、输出溢出、Unicode 编辑距离独立 DP、严格 UTF-8、
自动机 EOF/剪枝、rank/select/page、游标回滚、词频排行与反向遍历等覆盖。
本轮新增任意 K 源及双流合并对照，涵盖四种操作、空范围与边界、前缀及高字节
键序、一侧耗尽、重复 FST 的独立流，以及返回 key/value 组的所有权。
归约溢出、重复键拒绝、回调异常和第二匹配源 refill 失败均检查永久关闭、
后续 `None`、重复 `close` 及底层读取/关闭次数，正常归约另有对照。

## 代码量

本次生产 MoonBit 为 **27 个文件、4,802 行**非空非注释物理代码行，
包含括号等分隔符；测试另计 **5,062 行**。示例、生成数据、集成入口、
文档、公开接口生成文件、第三方缓存及 Rust/Python/Shell/C 开发工具均
不计入生产 MoonBit。统计口径见
[count_loc.py](https://github.com/starAndHonor/moonfst/blob/main/scripts/count_loc.py)。
代码量不是官方赛事门槛，也不代替复杂度或质量评价。

## 历史互操作证据

**2026-11-06** 的验收曾在 Native、JavaScript、Wasm-GC 上，对 19 组固定及
64 组随机样本完成双向互操作；当时重新构建的 83 组完整文件均逐字节等于
Rust 输出，合计 **22,431 条记录、756,663 B**。详见
[历史构建证据](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/optimized-v1/builder-proof.json)。
这是对应当时源码的历史结果，**不是本次重新执行的三后端字节一致验收**。

## 性能与内存测量

真实工作负载当前采用 **`measurement_revision = 2`**。Rust 输入使用共享的
`Arc<[u8]>`，MoonBit 使用不可变 `Bytes`；A/B/并集及命中查询共享原词条键，
mixed 共享已有 hit/miss 键。两边遍历与并集输出仍复制拥有所有权的 key。
Rust 保留批次结果屏障，移除逐 key 的额外 `black_box`；协调器拒绝旧 revision
的 runner。两边的批次防优化机制及运行时表示仍有差异。

2026-11-07 的
[real-optimized-v1 正式报告](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-optimized-v1/REPORT.md)
已完成：固定版本 Jieba 真实词典，N 为 1 万、10 万、20 万，sorted/shuffled
两种查询配置，每项 3 轮 × 7 次采样、每轮预热 2 次，所有样本校验通过。
三个规模的编码均与 Rust 逐字节相同，20 万条编码为 **1,949,554 B**。
shuffled 配置的并集中位耗时分别为 Rust 的 **0.808 / 0.789 / 0.834 倍**；
sorted 的 10 万条并集基本持平，另两档更快。这些结果不支持所有操作和配置
均领先。sorted/shuffled 只改变查询顺序，构建与并集的输入仍按字节序排列。

RSS 的 baseline/build/load/union 阶段各在独立进程运行，读取 Linux
`/proc/self/status` 的 `VmRSS` 与 `VmHWM`，保留操作前、操作后和内容验证后
快照。20 万条 union 的 before/after/peak 中位数为：MoonBit
**50,784 / 63,384 / 129,452 KiB**，Rust **53,928 / 67,256 / 67,256 KiB**。
MoonBit 的 peak 与 baseline_peak 中位数相同，不能解释为并集新增的内存。
同规模 load 峰值为 MoonBit **94,428 KiB**、Rust **4,400 KiB**；两侧均从
预先导出的编码开始，但 MoonBit 验证完整可达图，Rust 只打开并检查 CRC，
工作量不同。完整原始数据见
[raw.json](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-optimized-v1/raw.json)。

RSS 包含输入、运行时及分配器保留；高水位可能来自准备阶段，不能当作
操作净分配、精确堆大小或库独有内存。共享输入策略对齐后，Arc/Bytes 头部、
容器布局及分配器仍不同。全新进程不等于冷缓存；上述均为单机 native 热运行，
不外推到磁盘吞吐、实际查询流量或其他后端。

历史
[real-baseline-v1](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-baseline-v1/REPORT.md)
使用旧 Rust Vec 深拷贝输入和逐 query 屏障，不能与 revision 2 混合汇总，
也不能直接用于当前 RSS 公平性结论。测量方法见
[基准说明](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/README.md)。

## 复验与发布状态

以下命令从源码仓库根目录运行：

```sh
bash scripts/check.sh
python3 scripts/interop.py --target native --target js --target wasm-gc
python3 scripts/random_interop.py --target native --target js --target wasm-gc
python3 scripts/workload_smoke.py
moon run src/examples/dictionary --target wasm-gc
```

列表提供完整复验入口，不表示其中额外的三后端对拍和词典示例均已在本轮
重新执行。对拍脚本应顺序运行；它们临时替换集成输入，结束或失败时恢复
小占位文件。全新检出不需要预先生成测试数据；离线构建需先备齐工具链及
Cargo 依赖。

本轮完整日志保存在本地忽略路径
`artifacts/development/20261107/release-check.log`，工具链与 LOC 数据位于
`oracle/target/validation/`。Mooncakes 归档排除这些本地证据和开发工具，
保留纯 MoonBit 运行库、单元测试、示例及许可/架构文档。native 工作负载的
C 文件只负责开发工具的文件 I/O 与 RSS 采集，不进入运行库。

本记录描述发布前验收；注册表下载消费与发布结果另见
[发布验收记录](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-optimized-v1/RELEASE.md)。
当前运行库仍为内存实现，不提供 mmap、磁盘流式输出、并行构建或
上游 CLI 的逐项复刻。写出 v3，旧 v1/v2 读取由格式测试覆盖；不同构建器
或缓存预算可生成语义等价但字节不同的图。
