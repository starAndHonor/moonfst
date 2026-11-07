# Mooncakes 0.1.0 发布验收

2026-11-07 已发布 **`starAndHonor/fst@0.1.0`**。

```sh
moon add starAndHonor/fst@0.1.0
```

[Mooncakes](https://mooncakes.io/docs/starAndHonor/fst) ·
[源码仓库](https://github.com/starAndHonor/moonfst) ·
[通过的 GitHub CI](https://github.com/starAndHonor/moonfst/actions/runs/42369675436)

发布源码与文档提交为 `8116fad33a0cce07ad1b1fe98eedcfbd3900891d`，
运行库最终改动为 `b2d680e`。发布后的本记录与结果文件不包含在包中。
工具链为 moonc `0.10.20+65efd5b93`，moon `0.1.20261104`。

## 验证结果

- `moon publish --dry-run`：服务器接受预检；归档解压后 `moon check` 通过。
- `moon publish`：返回 **200 OK**。
- `.moonignore` 排除私有申报材料、下载语料、基准、Rust/Python/C 工具、
  外部对拍入口及 CI 配置；归档保留运行库、单元测试、示例和许可文档。
- 归档解压后的 Native、JavaScript、Wasm-GC、Wasm 各 **137/137** 测试通过。
  源码仓库另外包含 3 项自动机外部 API 集成测试和 3 项 native workload
  测试，因此完整仓库为 Native 143、其他后端各 140。
- 在 `/tmp` 的全新独立项目声明注册表依赖，无 `moon.work` 或本地 path
  覆盖。`moon update` 成功，首次 `moon test` 明确下载
  `starAndHonor/fst@0.1.0`；从 README 原样提取的完整消费示例在四后端
  各 **1/1** 测试通过。
- 下载模块的 **57 个文件逐字节匹配已发布归档及仓库文件**。
  清单、逐文件 SHA256 和归档摘要见 [release-package.json](release-package.json)。

归档压缩后 **124,197 B**，SHA256：

```text
9e056119d2755bc35ff0ac5e557b641a09f44b1e92f3ce425305987ac37651bc
```

完整性能数据见 [REPORT.md](REPORT.md)。这次发布没有弱化完整图验证；
装载峰值 RSS 较高、原生内存实现不支持 mmap 等边界仍适用。
