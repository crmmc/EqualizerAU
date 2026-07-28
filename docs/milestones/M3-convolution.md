# M3：Convolution

> **当前状态**：已完成并关闭；hostless 实现由 M4 T10–T15 真实音频和 M5-B 编辑器人工验收补齐

本文记录 M3 当时的 schema v4 immutable sidecar 契约。2026-07-28 批准的
[`ADR-0014`](../adr/0014-convolution-source-path-loading.md) 和
[`M8`](./M8-convolution-source-path.md) 已取代资源复制、storage ID、预检及资源错误整批失败语义；
ABI v3 hybrid convolution、WAV/SRC、声道映射、容量与实时边界继续有效。

## 1. 目标

M3 在 M2 有序处理链和双槽发布基础上加入 WAV IR 导入、格式适配、实时卷积与安全替换。
文件错误、布局不匹配或容量超限必须在 Save 的 prepare 阶段失败，不能改变已保存配置或活动链。

## 2. 产品与 DSP 契约

- schema v4 引用应用数据目录中的不可变 WAV sidecar，不保存外部路径或音频 bytes；
- 接受最大 `32 MiB`、最长 2 秒、1...64 声道、8...768 kHz 的 PCM 8/16/24/32 与 Float32 WAV；
- 控制线程完成严格解析、SHA-256/metadata 复验、windowed-sinc SRC 与 FFT prepare；
- mono IR 广播；多声道 IR 必须严格匹配当前有效作用域，并按作用域顺序映射；
- zero-latency hybrid kernel 使用 256-tap direct head 和 256/512 partitioned FFT tail；
- 单 Prepared 最多 8 个卷积 stage，实际声道实例 taps 合计最多 131072；
- 发布沿用 10 ms 双槽 crossfade、pending 合并和退休维护。

决策理由见 [`ADR-0009`](../adr/0009-immutable-ir-and-hybrid-convolution.md)。

## 3. 已实现范围

- WAV 导入、原子 sidecar 写入、文件/目录同步、immutable storage ID 和加载时完整性复验；
- schema v1-v3 兼容读取并规范写 v4，配置与 typed clipboard 均严格拒绝跨 kind/未知字段；
- Builder 支持 scope 映射、Gain flush、离线 SRC、容量预算和 source diagnostics；
- Runtime ABI v3 支持 Gain、Biquad 与 Convolution 任意有序组合，同时保留旧 ABI 创建入口；
- 编辑会话、Undo/Redo、复制、替换、产品 Save/发布及 SwiftUI 文件选择和节点摘要已接入；
- 无效 IR 或 prepare 失败时，旧保存配置和旧活动链保持不变。

## 4. 自动化证据

- `EqualizerAUM1` app target 无签名构建通过；
- Runtime smoke 30 项通过，包括 ABI、malformed/capacity、即时 delta、direct/tail 数值、可变 block、
  声道隔离、stage 顺序、publication、pending、equivalence 和回收；
- 完整 hostless `EqualizerAUM1RuntimeTests` 共 222 项通过，零失败；
- `verify-m1-realtime.sh` 审计 29 个显式 Runtime/host callback helpers；
- 五 target isolation、独立 C++ `-Wall -Wextra -Werror`、shell syntax 与 diff whitespace 门禁通过。

## 5. 历史待验收边界与后续验收

M3 完成时未启动 hosted test bundle、GUI、NSOpenPanel、真实音频、Tap、Aggregate、设备 IO 或
系统路线，因此当时保留 Add/Replace/取消、metadata 布局、IR 听感和切换稳定性的人工边界。
后续证据已补齐：

- M4 T10–T15 由用户在签名应用中确认合法 WAV 导入、取消 Replace、损坏/超时长拒绝、不可变
  sidecar 重启恢复，以及短回声 IR 的 Processing A/B 和无爆音、静音或恢复循环；
- M5-B 由用户确认 Convolution 常显文件名、采样率、声道、时长、Replace 和具体 IR 错误模态，
  并通过最终处理器行 GUI 人工验收；
- 不支持 true-stereo/矩阵 IR、压缩音频、Float64 WAV 或超过 2 秒的 IR，仍是明确产品边界而非
  未完成实现；
- sidecar 自动垃圾回收不属于 M3。现有孤儿回收需求只有出现独立、可复现数据生命周期问题后
  才重新立项。

因此 M3 没有剩余活动验收任务，本文保留为 schema v4、ABI v3 和 IR 契约的历史依据。
