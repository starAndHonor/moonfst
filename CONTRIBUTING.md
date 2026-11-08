# 维护约定

## 目录边界

```text
moonfst/
├── moon.mod                 # 发布模块和 source = "src"
├── toolchain.json           # MoonBit/core 固定下载地址及 SHA256
├── rust-toolchain.toml      # Rust 固定版本
├── src/
│   ├── moon.pkg             # starAndHonor/fst 根包
│   ├── *.mbt                # Set/Map、构建、查询、流、可选索引
│   ├── *_wbtest.mbt         # 与被测包放在一起的白盒测试
│   ├── pkg.generated.mbti   # 生成的公开 API
│   ├── codec/               # starAndHonor/fst/codec
│   ├── automaton/           # starAndHonor/fst/automaton
│   │   └── integration/     # 独立包视角的自动机 API 测试
│   ├── examples/dictionary/ # 对外示例，随包发布
│   ├── integration/         # Rust 双向对拍入口，不随包发布
│   └── benchmarks/          # MoonBit 基准程序及开发专用 C I/O
├── scripts/                 # 生成、验收、计时和诊断协调器
├── oracle/                  # 独立 Rust 参考工具及 Cargo.lock
├── fixtures/                # 小型固定二进制、预期结果及 manifest
├── benchmarks/
│   ├── corpora/            # 外部语料来源、摘要、许可证
│   └── results/            # 已归档的测量证据
├── .github/workflows/       # 与本地相同的验收入口
├── artifacts/               # 忽略的安装、临时输出和私人文件
├── REPRODUCING.md
├── ARCHITECTURE.md
├── THIRD_PARTY.md
└── README.md
```

MoonBit 的 `source = "src"` 只改变物理布局，模块和公开包名仍为 `starAndHonor/fst`、
`starAndHonor/fst/codec`、`starAndHonor/fst/automaton`。运行源码中的程序时使用文件系统路径，
例如 `moon run src/examples/dictionary --target wasm-gc`。

## 修改运行库

实现和包内测试放在 `src/` 对应包中，按职责拆文件，不为增加代码行数拆分函数或提交。
不能让运行库依赖 `oracle/`、下载数据或开发工具。C 文件仅用于 Native 基准的 I/O/RSS。

公开 API 变化后运行 `moon info`，审阅 `src/**/pkg.generated.mbti` 的差异，并更新 README 示例。
自动生成的接口文件提交到 Git，但不手工编辑。测试数据不计入生产代码统计。
运行库核心边界和验证前提见 [ARCHITECTURE.md](ARCHITECTURE.md)。

```sh
moon fmt
moon info
bash scripts/reproduce.sh
```

新增测试应验证独立预期或回归行为。涉及编解码和查询语义的修改，要保留 Rust 双向对拍；
涉及性能的修改，用固定负载重测，不用旧报告证明新代码。完整入口见 [复现说明](REPRODUCING.md)。

## 数据、结果和生成文件

- 固定小样本：修改生成器后运行 `python3 scripts/generate_fixtures.py`，审阅变化；CI 用 `--check` 核对。
- 大型外部数据：提交来源清单、固定提交、摘要和许可证，下载结果写入被忽略的目录。
- 新基准：写入 `artifacts/benchmarks/`。需要归档时，选择有解释价值的一组报告、完整原始结果及方法说明。
- 历史报告：保留原始源码指纹、环境和数字；不能通过批量替换路径改写历史测量证据。
- 诊断脚本：`query_ablation.py`、`query_cost_counts.py` 是旧查询实现的历史实验，当前实现会明确拒绝执行；复现实验应检出其报告记录的历史提交。

## 发布与忽略规则

Git 忽略可再生的缓存和私人材料；Mooncakes 归档再排除开发工具。
修改 `.gitignore` 或 `.moonignore` 后，运行完整验收中的 `verify_package.py`，检查实际归档能独立测试和消费。
新源码、配置、生成器和复现所需清单必须提交，不得依赖未跟踪的本地输入。

`scripts/verify_package.py` 只构建、解压、验证归档，不执行 `moon publish`。
目录整理不会覆盖已经发布的 `0.1.0`；后续发布功能版本时应更新版本和发布记录。
