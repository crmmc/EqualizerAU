# M8：Convolution 外部源路径生命周期

> **当前状态**：已完成并关闭
>
> M10/ADR-0017 已取代本文的 IR SRC、32 MiB/2 秒、tap 总量和 duration bypass 语义；本文的
> schema v8 sourcePath、每次生效重读、节点级资源旁路和 Prepared 持有契约继续有效。

## 1. 目标

以 schema v8 外部源路径替代新 Convolution 的应用内 WAV 副本。每次配置真正生效时重新读取
和校验文件，成功结果进入 Prepared 内存；资源局部失败时仅有效旁路该节点，并保留用户开关。

决策理由见 [`ADR-0014`](../adr/0014-convolution-source-path-loading.md)。

## 2. 范围

- `M1ConvolutionIRReference` 只保存标准化绝对 `sourcePath`；
- 配置和 typed clipboard 规范写 schema v8；
- v4-v7 `storageID` 确定性迁移到历史 sidecar 绝对路径；
- Add/Replace 只记录路径，不复制、不预校验；
- Start、运行中 Save、路由重建和格式恢复重新读取、校验、解码和 SRC；
- Prepared 持有 taps，不增加音频 callback IO 或长期全局缓存；
- missing、IO、WAV、metadata、sample、duration 和 channel mismatch 形成节点 owned bypass diagnostic；
- schema 与全局 convolution/stage/tap 容量错误仍整批失败；
- UI 显示文件名、完整路径、最后成功加载 metadata 或有效旁路原因。

## 3. 非目标

- 不监听外部文件变化，不自动 Save 或热重载；
- 不复制、打包、移动、删除或垃圾回收外部文件；
- 不自动删除 schema v4-v7 的历史 sidecar；
- 不支持压缩音频、Float64、true-stereo/矩阵 IR 或超过既有 32 MiB/2 秒边界；
- 不扩展 ABI v3、卷积容量、UI 布局或性能优化范围。

## 4. 验收

### 自动化

- v4-v7 config/clipboard 迁移到历史 sidecar 路径，v8 严格 round-trip；
- v8 拒绝空路径、相对路径、NUL 和未知字段；
- Add/Replace 失败不创建应用数据文件；
- 同一路径修改后下一次 build 使用新内容；
- missing、损坏、超限与 channel mismatch 只旁路 owned 节点并产生 diagnostic；
- 不可用节点恢复后下一次 build 自动重新加入；
- stage/tap/Prepared 容量仍整批拒绝；
- 完整 runtime tests、5-target isolation、realtime audit、lint 和严格编译通过。

### 用户验收

- Add/Replace 后 UI 显示外部路径；
- 删除或卸载源文件后 Save/Start 仍可运行，其节点显示 bypass；
- 文件恢复后再次 Save/Start 自动恢复 Convolution；
- 原地替换 WAV 后下一次生效使用新内容；
- 真实音频确认旁路、恢复和切换无爆音、静音或错误节点状态。

## 5. 完成证据

- 2026-07-28：完整 `EqualizerAUM1RuntimeTests` 通过 319 项，2 项性能 fixture 按设计跳过，0 失败；
- 5-target isolation、realtime audit、lint、严格 C++/Objective-C++ 编译和 `git diff --check` 全部通过；
- Apple Development 签名验收候选通过 `codesign --verify --deep --strict`；
- 2026-07-28：用户完成 GUI 与真实音频验收，确认外部路径、资源旁路、恢复、原地替换和切换行为通过。
