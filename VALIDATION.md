# 本地验收记录

2026-11-06，使用官方 latest 安装的 **moonc v0.10.20+65efd5b93**，
moon / moonrun 为 **0.1.20261104 (940aa18)**。CI 固定相同可下载版本。

本轮性能优化后，`bash scripts/check.sh --min-production-lines=4000` 退出码为 0：

| 检查 | 结果 |
|---|---|
| 格式与四后端编译 | 通过，项目 `--deny-warn` |
| Native / JavaScript / Wasm / Wasm-GC 测试 | 每个后端 **132 / 132** |
| Rust oracle 自测 | 3 / 3 |
| Rust benchmark 自测 / Python 基准协议与统计测试 | 4 / 4，16 / 16 |
| 固定二进制样本精确再生成 | 19 / 19 |
| Oracle 查询和损坏输入 | 57 个查询、39 个坏输入通过 |
| 固定双向互操作 | 19 组，15,923 条记录 |
| 固定种子随机双向互操作 | 64 组，6,508 条记录 |

固定及随机互操作在 Native、JavaScript、Wasm-GC 均通过。
比较完整有序键值、完整 UInt64 数值、CRC32C，以及精确查询、前缀和范围。
本轮另将最终源码在三个后端重新构建的全部 83 组文件与 Rust 输出逐字节比较：
22,431 条记录、756,663 字节全部相同，见
[构建证据](benchmarks/results/optimized-v1/builder-proof.json)。
Rust 参考是 crates.io 原版 `fst = "=0.4.7"`，对应上游提交
`fbd5992376f176c35af2644d74efad58f5656e5c`，依赖由 Cargo.lock 固定。

测试包括任意字节、空键、256 路分支、长路径、最大键数、输出溢出、
畸形文件、Unicode 编辑距离独立 DP 对照、非法 UTF-8、自动机保守剪枝、
游标回滚、rank/select/page、词频排行、反向遍历及数据源错误后的清理。
本轮新增压缩字段宽度 0..8、旧 v1/v2 与 v3、256 路索引、按字比较尾部、
所有单字节标签、长路径、缓存哈希碰撞和池对象复用、所有范围边界组合、
EOF 自动机、混合 next/take/skip/count、返回 key 持有与非法 UTF-8 后继续消费等回归。
词典示例四后端输出一致，README 的消费项目代码另行运行验证。

## 代码量

`python3 scripts/count_loc.py` 的生产口径为 **27 个文件、4,634 行**。
统计物理非空、非注释代码行，包含括号等分隔符。
另有 4,707 行测试；示例、生成数据、集成入口、文档、公开接口生成文件、
第三方缓存和 Rust/Python/Shell 都不计入生产 MoonBit。
这不是官方赛事门槛，也不代替复杂度或质量评价。

## 复验

```sh
bash scripts/check.sh
python3 scripts/interop.py --target native --target js --target wasm-gc
python3 scripts/random_interop.py --target native --target js --target wasm-gc
moon run examples/dictionary --target wasm-gc
```

对拍脚本应顺序运行，它们临时替换集成输入，结束或失败时恢复小占位文件。
全新检出不需要先运行生成器就能编译和测试。
工具要求及统计细则见 [scripts/README.md](scripts/README.md)。

本地原始日志和机器可读摘要在 `oracle/target/validation/`，由 Git 忽略。
本轮统一日志为 `optimized-check.log`，精确字节互操作摘要为
`optimized-exact-interop.json`。正式性能报告及原始样本另存于
[benchmarks/results/optimized-v1/](benchmarks/results/optimized-v1/REPORT.md)：
两种数据分布、三档规模、每项 3 轮 × 7 次采样，全部预热和采样校验通过。
CI 配置会生成并上传相同证据；本记录不声称 GitHub Actions 已远程运行。

当前为纯 MoonBit 内存实现，未提供 mmap、磁盘流式输出、并行构建或
上游 CLI 的逐项复刻。写出 v3；旧 v1/v2 读取由格式测试覆盖。
不同构建器或缓存预算可产生不同但语义等价的二进制数据。
