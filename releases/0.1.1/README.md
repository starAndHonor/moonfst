# Mooncakes 0.1.1 发布验收

2026-11-08 UTC 已发布 **`starAndHonor/fst@0.1.1`**。

```sh
moon add starAndHonor/fst@0.1.1
```

[Mooncakes](https://mooncakes.io/docs/starAndHonor/fst@0.1.1) ·
[源码标签](https://github.com/starAndHonor/moonfst/tree/v0.1.1) ·
[发布源码 CI](https://github.com/starAndHonor/moonfst/actions/runs/42444798209)

发布源码提交为 `389fe2f549d4032707eb73f0360a2bd452d07f0f`，对应 `v0.1.1`。
本目录的发布后验收记录不进入 Mooncakes 归档。

## 变更范围

本补丁版发布 `src/` 源码布局和维护、复现改进，保持公开包名、API、压缩格式及算法源码兼容。
包括固定 MoonBit/core 下载摘要、Rust 工具链版本、本地与 CI 统一验收、实际发布归档与消费者检查。
详细变更见 [CHANGELOG.md](../../CHANGELOG.md)，复现步骤见 [REPRODUCING.md](../../REPRODUCING.md)。

## 验证结果

- 完整本地 `bash scripts/reproduce.sh` 通过；发布源码对应的 GitHub CI 通过。
- 源码仓库 Native **143/143**，JavaScript、Wasm-GC、Wasm 各 **140/140**。
- Rust 双向固定/随机对拍及离线真实负载 smoke 通过。
- 实际归档解压后四后端各 **137/137** 测试通过，词典示例通过，归档独立消费者四后端各 **1/1** 通过。
- `moon publish --dry-run`：服务器 **202 Accepted**；`moon publish`：服务器 **200 OK**。
- 全新临时项目没有 `moon.work` 或本地依赖覆盖，`moon update` 成功，首次 Native 测试明确下载 `starAndHonor/fst@0.1.1`。
- 从 README 提取的完整消费示例在 Native、JavaScript、Wasm-GC、Wasm 各 **1/1** 通过。
- 注册表下载的 **58 个文件**逐字节匹配发布归档及发布源码；清单和摘要见 [package.json](package.json)，消费命令及结果见 [consumer.json](consumer.json)。

归档大小 **125,914 B**，SHA256：

```text
85f1c2d9f557a6efecfb674cc4f93b2a804f2d77d33687640682bf3000357fa2
```

本次不重新发布或覆盖 0.1.0，也不把历史基准数字视为本次重新采样结果。
运行库仍为内存实现；完整图装载验证的内存限制保持原有说明。
