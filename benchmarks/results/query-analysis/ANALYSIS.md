> 历史诊断：本报告记录优化前的完整节点解码查询路径。生产实现现已改为按需读取压缩边，最新结果见 [优化后报告](../optimized-v1/REPORT.md)。下述原始样本和消融数据保留不变；历史消融脚本不会覆盖当前优化实现或旧快照。

# 查询性能原因分析

结论：当前 get 复用了用于安全读取和节点检查的完整解码器。它每一步先展开节点的全部出边，再寻找其中一条；Rust fst 的查询使用借用原始编码的节点视图，按需解码所选边。隔离实验表明，改为后一种访问方式，MoonBit 查询本身可以加速约 11–41 倍。这个差距首先是当前查询实现的设计问题。

本次只新增诊断脚本与证据，正式库和正式 benchmark runner 的源码保持与原基准逐文件 hash 一致。direct_lookup 是分析用原型，未作为生产优化合入。

当前调用链是 [Fst::get](../../../fst.mbt#L44) → [read_node](../../../types.mbt#L170) → [decode_node / decode_any](../../../codec/decode.mbt#L99) → 全部 Transition → [find_transition](../../../types.mbt#L177)。get 每消费一个 key 字节便重新走一遍此过程；同一个根节点及公共前缀节点会被反复展开。

Rust 固定参考版本中，[Node](https://github.com/BurntSushi/fst/blob/fbd5992376f176c35af2644d74efad58f5656e5c/src/raw/node.rs#L22) 是包含借用字节切片的 Copy 视图。[查询循环](https://github.com/BurntSushi/fst/blob/fbd5992376f176c35af2644d74efad58f5656e5c/src/raw/mod.rs#L682) 先找输入标签，再解码一条转移；[find_input](https://github.com/BurntSushi/fst/blob/fbd5992376f176c35af2644d74efad58f5656e5c/src/raw/node.rs#L692) 在出度超过 32 且格式版本 ≥ 2 时直接使用 256 字节索引表，低出度时扫描输入字节。正常查询无需为节点或边分配堆对象。

MoonBit 生成的 C 和 release 反汇编确认：Array[Transition] 是 Transition 指针数组，解码循环每条边创建一个堆对象；Node、Decoded、数组及部分中间值也有分配。每推进一步又释放旧节点及出边，带来引用计数、对象遍历、分配器和指针访问成本。问题不只是多做几次比较。

高出度节点还会调用 [validate_index](../../../codec/decode.mbt#L75)：新建 256 项 expected 数组、逐边填表、逐项检查编码中的 256 项索引。检查完成后，get 仍对已展开的边做二分查找，没有利用编码内的索引直接定位。装载时的 CRC 和全图验证只执行一次，已排除在原基准计时之外；这里重复的是查询过程中每个节点的局部解码验证。

对固定字节字母表，两者相对 key 长度仍然是线性的；更有意义的比较是每个节点的实际工作量。当前实现约为完整出度 d 的解码/分配，加上高出度时的 256 项复查，再二分查找；Rust 高出度只读取一个索引项，低出度最多扫描 32 个输入标签。

结构计数直接插在隔离副本的现有解码函数中，Fst::get 未改。生成数据、建图和完整验证后重置计数，再执行 10 万次查询；计数结果不用于比较耗时。

| 每次命中查询的平均成本 | 共享前缀键 | 随机字节键 |
|---|---:|---:|
| key 长度 | 28 字节 | 16 字节 |
| 节点读取（包括末尾隐式终态） | 29 | 17 |
| 实际解码的出边 | 122.43 | 471.44 |
| 完整检查的索引槽位 | 256 | 512 |
| expected 数组初始化槽位 | 256 | 512 |
| expected 填表次数 | 64 | 455.91 |

随机键路径更短，但高出度节点更多，解码边数达到共享前缀键的约 3.85 倍。10 万次随机键查询会产生 47,144,147 个 Transition，而真正要沿着走的路径只有每次 16 条边。高出度节点一遍遍展开，解释了随机键查询差距随数据量增大的现象。[完整结构计数](cost-counts.json)

near-miss 输入是在已有 key 后追加 FF，必须走完整条原路径才失败，因而本次 hit/miss 的结构计数完全相同。顺序遍历则能把正在访问的节点保存在栈中并继续消费其出边，重复展开公共节点的成本得到摊薄，这与原基准中遍历约 4 倍、独立查询约 22–67 倍的差距相符。

隔离消融实验保持同一批数据、同一构建器、同一完整装载验证以及相同 hit/miss 输出。CPU 固定为 2，native release，三轮轮换版本顺序，每进程预热 2 次并采样 7 次，每格共 21 个样本。三个版本都通过 19 个上游 fixture 的查询检查、小规模生成器检查和所有大规模输出 checksum 校验。

- baseline：正式查询实现。
- skip_index_validation：仅查询读取时跳过 256 项索引一致性复查；装载 verify 仍保留检查，其余完整出边解码与分配保持。
- direct_lookup：保留装载 verify，查询直接读取压缩节点元数据、使用高出度索引表，只解码选中边。保留输出溢出和选中地址等检查，避免完整 Transition 数组。

| 10 万次查询，中位数 ms | baseline | 只跳过索引复查 | 按需读取原型 | 原型加速 |
|---|---:|---:|---:|---:|
| 共享前缀：命中 | 317.675 | 277.066 | 28.586 | 11.11× |
| 共享前缀：near-miss | 309.995 | 279.224 | 23.988 | 12.92× |
| 随机键：命中 | 787.193 | 677.280 | 19.848 | 39.66× |
| 随机键：near-miss | 766.288 | 676.298 | 18.508 | 41.40× |

仅跳过索引复查使耗时下降约 10%–14%。大部分改进来自按需读取这一整体变化：它同时减少了全边解包、局部验证、数组增长、对象分配和释放，不能把全部提升归为某个单独因素的占比。[原始样本](ablation-raw.json) · [中位数、分位数和倍数](ablation-summary.json)

这次消融使用只计查询的独立 runner，且机器频率和其他系统负载没有锁定；baseline 绝对时间与上次正式 benchmark 有差别。因此表中只比较本轮三个版本，不用原型时间除以上一轮的 Rust 时间来宣称新的跨语言倍数。direct_lookup 也尚未完成生产变更所需的完整回归和接口设计。

另外使用 gprof 对单独重编译的 C 副本做了查询采样与调用计数。系统的 perf_event_paranoid=4 禁止 perf 采样，因此没有修改系统设置。profiling 只在 lookup_hit 执行期间打开，三批共 30 万次查询：read_node 调用 510 万次，packed unpack 调用 276,057,180 次，即每次 get 约 920.19 次解包。Transition 数组 push 约 458.23 次/get，数组扩容约 12.79 次/get。这与结构计数相互印证。[校正后的调用记录](gprof-calls.json)

gprof 的原始函数报告会把 GCC 的 .isra.0 克隆误归给前一个符号，产生虚假的 fail/debug.to_string 名称；mcount@plt 的采样也会显示为 _init。已用原始 gmon 地址、readelf/nm、objdump 和带行信息的报告核对。这里不将受插桩影响的采样百分比当作原始 benchmark 的耗时分解。[行解析报告](gprof-random-lines.txt) · [方法和局限](gprof-random.json) · [GNU gprof 文档](https://sourceware.org/binutils/docs/gprof/Executing.html)

后续生产优化应优先实现面向已验证 Fst 的压缩节点查询视图，按标签定位并只读取所选边；保留严格解码器用于装载验证和公开节点检查。随后再考虑减少单出边路径、结果包装和引用计数成本。直接给全部解码节点加缓存会增加常驻内存，不能替代按需读取设计；小范围热点缓存可以在基本查询路径修好后单独评估。

复现脚本：

```sh
python3 scripts/query_cost_counts.py --sizes 100000
python3 scripts/query_ablation.py --run
python3 scripts/profile_query.py --shape random --n 100000 --samples 3 --cpu 2
```

按顺序运行，避免并行负载干扰。结构计数与消融脚本的临时副本位于 oracle/target/；profiling 另需 GNU cc/gprof，并先存在正式 benchmark 的 native release 生成 C 和运行时构建产物。诊断脚本不改生产源文件。

