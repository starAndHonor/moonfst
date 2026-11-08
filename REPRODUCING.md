# 从全新检出复现

仓库保留全部手写源码、测试、生成器、固定样本、数据来源清单和历史报告。
构建缓存、下载语料、临时对拍数据及新测量输出可以忽略；验收不依赖作者机器上的这些文件。

## 环境准备

完整验收环境为 Linux x86_64，需要 Python 3.12+、Node.js 22、Rustup、`cc`、`curl` 和 Git。
MoonBit 运行库支持其他平台；自动安装脚本及 `/proc` RSS 验收目前针对 Linux x86_64。

```sh
git clone https://github.com/starAndHonor/moonfst.git
cd moonfst
python3 scripts/bootstrap.py
. artifacts/env.sh
bash scripts/reproduce.sh
```

`bootstrap.py` 从 `toolchain.json` 读取固定版本的官方编译器和配套 core，下载后校验 SHA256，
安装至项目内被忽略的 `artifacts/toolchains/moon/`。它不修改 `~/.moon` 或 shell 配置。
激活后，`MOON_HOME` 与 `PATH` 指向该安装。已有正确工具链的开发者可直接执行验收。

Rust 由 `rust-toolchain.toml` 固定为 1.94.1；通过 Rustup 的 Cargo 首次运行时会安装该版本。
Rust 参考依赖由 `oracle/Cargo.lock` 固定，所有构建使用 `--locked`。
Python 验收和统计使用标准库，无需安装 pip 包；绘图是单独的可选功能。

工具版本与实际命令输出记录在 `oracle/target/validation/`。`scripts/doctor.py` 会拒绝
不符合锁定版本的 MoonBit/Rust、错误的 Node 主版本以及不能运行 RSS 验收的平台。

## 验收做了什么

`bash scripts/reproduce.sh` 调用与 CI 相同的 `scripts/check.sh`：

1. 检查工具链、格式，并单独统计生产源码、测试和开发工具。
2. 运行 Rust 自测及 Python 协议、统计和语料处理测试。
3. 使用 Rust 重新生成固定样本并与 Git 中的文件核对；验证完整键值、CRC 和损坏输入。
4. 在 Native、JavaScript、Wasm-GC、Wasm 上检查、构建并运行 MoonBit 测试。
5. 完成 19 组固定和 64 组固定种子随机样本的 Native 双向互操作。
6. 使用仓库内定义的小样本复现真实负载协议、两种查询顺序、四种内存模式和编码一致性；不下载外部词典。
7. 实际执行 `moon package`，检查发布文件边界；解压归档，在四后端运行归档测试。
8. 创建仓库外消费项目，通过本地工作区解析解压后的包，在四后端运行 README 的完整示例，并运行词典演示。

最后一步验证的是本次源码打出的包，既不回退到工作目录，也不冒用注册表上旧版本的测试结果。
此流程不会发布或覆盖 Mooncakes 版本。四后端额外双向对拍可顺序运行：

```sh
python3 scripts/interop.py --target native --target js --target wasm-gc --target wasm
python3 scripts/random_interop.py --target native --target js --target wasm-gc --target wasm
moon run src/examples/dictionary --target wasm-gc
```

对拍脚本暂时替换 `src/integration/fixtures_generated.mbt`，在 `finally` 中恢复。
不要在同一个检出中并发执行这些脚本。CI 最后用 `git diff --exit-code` 检查是否污染已跟踪文件。

## 复现性能与真实词典

```sh
# 验收后运行完整合成基准、真实词典和内存基准。
bash scripts/reproduce.sh --bench
```

新报告写入被忽略的 `artifacts/benchmarks/synthetic-时间戳/` 和 `real-时间戳/`，
不覆盖 `benchmarks/results/` 下的历史证据。也可以单独运行：

```sh
python3 scripts/benchmark.py --output artifacts/benchmarks/my-synthetic-run
python3 scripts/workload_benchmark.py \
  --sizes 10000 100000 200000 --orders sorted shuffled \
  --samples 7 --warmups 2 --rounds 3 --memory-rounds 3 \
  --output artifacts/benchmarks/my-real-run
```

真实词典首次从 `benchmarks/corpora/jieba.json` 中的固定提交下载。
下载和缓存均检查长度及 SHA256，随后按固定种子生成语言无关的输入：

```sh
python3 scripts/prepare_workload.py --n 100000
```

输出为 `benchmarks/data/jieba-100000.bin` 及来源 JSON。运行完整基准会自动准备各规模输入，
无须手工执行生成器。许可证保留在 `benchmarks/corpora/JIEBA-LICENSE.txt`。

复现目标是相同数据、校验结果、编码和测量流程；耗时与进程 RSS 会随机器、运行时和系统状态变化。
历史报告记录对应源码指纹及原始样本，不能当成当前目录重组后的重新采样结果。
计时边界、输入共享和 RSS 解释见 [基准方法](benchmarks/README.md)。

## 哪些内容可以忽略

| 路径 | 内容 | 恢复方式 |
|---|---|---|
| `_build/`、`target/` | MoonBit 编译和发布归档缓存 | `moon build`、`moon package` |
| `oracle/target/` | Rust 编译、临时诊断、验收日志 | `bash scripts/reproduce.sh` |
| `benchmarks/data/` | 下载词典、二进制负载及导出 FST | `prepare_workload.py` 或完整真实基准 |
| `artifacts/cache/toolchains/` | 经 SHA256 验证的工具链压缩包 | `scripts/bootstrap.py` |
| `artifacts/toolchains/`、`artifacts/env.sh` | 项目内工具链及激活脚本 | `scripts/bootstrap.py` |
| `artifacts/benchmarks/`、`artifacts/profiles/` | 新测量及诊断输出 | 对应基准或分析脚本 |
| `artifacts/submission/` | 私人申报材料 | 与包的构建和复现无关，不要求提供 |
| `__pycache__/`、`*.pyc` | Python 缓存 | Python 自动生成 |

`fixtures/` 中的小型固定互操作样本和预期结果提交到 Git，保证普通测试无须联网生成。
`src/integration/fixtures_generated.mbt` 中的小占位数据也提交，保证新检出直接可编译。
`benchmarks/results/` 保留已公开报告和必要原始数据；临时新结果使用 `artifacts/`。

首次准备工具链、Rust 依赖和真实词典需要网络。离线执行前，可保留工具链安装、
`artifacts/cache/toolchains/`、Cargo registry 缓存及已校验的 `benchmarks/data/`。
上游工具链归档有保留期限，长期归档应保存 `toolchain.json` 对应的两个原始压缩包；
安装脚本接受 `--cache` 指向已有缓存，不会静默改用 `latest`。

## Git 仓库与发布包

`.gitignore` 忽略可重建输出和私人文件；`.moonignore` 进一步排除开发工具、外部语料、
Rust oracle、跨语言入口及 CI。Git 中有复现所需内容，不要求把所有开发材料发布给库消费者。
发布包保留 `src/` 运行库、单元测试、词典示例、README、架构和许可证。

维护目录和修改 API 的约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 已执行的独立检出验证

2026-11-08 UTC，对代码提交 `870473a59dab9ae49f51059bc132fb9344954921` 执行独立
`git clone --no-local`，克隆路径含空格，初始不存在 `_build/`、`oracle/target/`、
`benchmarks/data/`、`artifacts/` 或 `.mooncakes/`。工具链从已核验 SHA256 的原始压缩包缓存
重新安装；没有复制项目编译缓存、预生成负载或本机申报文件。实际执行
`bash scripts/reproduce.sh --bench`，结果如下：

| 检查 | 结果 |
|---|---|
| 源码四后端检查、构建、测试 | Native 143/143，其余三后端各 140/140 |
| Rust / Python 自测 | Rust oracle 3、合成 runner 4、真实 runner 5；Python 27，全部通过 |
| Native 双向互操作 | 19 组固定、64 组随机样本通过 |
| 发布归档 | 57 个文件与检出内容逐字节匹配；四后端各 137/137 测试通过 |
| 仓库外消费者 | 解压归档依赖解析、README 示例四后端各 1/1 通过；词典示例通过 |
| 合成基准 | 两种分布 × 1千/1万/10万条，3轮各7次采样，全部结果校验通过 |
| 真实词典与内存 | 首次下载固定 Jieba 词典；1万/10万/20万条，两种查询顺序，3轮各7次；72个独立内存进程，全部校验通过 |
| 检出洁净性 | 整套流程结束后 `git status --porcelain` 为空 |

同一代码提交的 [GitHub CI](https://github.com/starAndHonor/moonfst/actions/runs/42444231973)
也通过完整验收及发布归档/消费者检查。CI 默认不采集正式性能数字，避免把共享 runner 的
时序波动当成性能结论。后续提交的实时状态见仓库 Actions。

本次本地日志、归档清单和新测量保存在被忽略的 `artifacts/reproducibility/`；
这些是执行结果，不是下一位开发者运行验收所需的输入。
