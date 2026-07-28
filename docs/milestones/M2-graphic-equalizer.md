# M2：Graphic EQ

> **当前状态**：历史实现已完成；固定 15 段产品模型已由 M6 任意点模型取代，原待验收项不再执行

## 1. 目标

M2 在已经关闭的 M1 原生路线、可靠持久化和安全发布基础上，引入可实时调整的 Graphic EQ。
频段、滤波器、状态发布和数值验收必须在实现前形成独立契约；不能把 M1 只承载每声道净增益
的 Prepared ABI 误当成通用非交换 DSP 链。

## 2. 产品与 DSP 契约

- 固定 15 个 EqualizerAPO 默认中心频率，范围 `-24...+24 dB`，界面步进 `0.1 dB`；
- 每个非零频段使用 2/3-octave constant-Q RBJ peaking biquad；
- 系数按真实采样率在控制线程生成，高于 Nyquist 的频段保留配置并产生节点归属诊断；
- flat Graphic EQ 不生成 stage，保证逐位透明；
- ABI 固定每声道 512 stage、每 Prepared 4096 stage，运行中更新使用 10 ms 双槽 crossfade；
- Processing 旁路继续推进 wet chain 状态，并独立执行 10 ms dry/wet 切换；
- EqualizerAPO 的 16384-tap minimum-phase FIR 未直接移植，理由见
  [`ADR 0008`](../adr/0008-fixed-band-biquad-graphic-equalizer.md)。

## 3. 已实现范围

- schema v3 保存 Channels、Preamp 和 Graphic EQ，并严格校验节点及嵌套 band 字段；v1/v2
  读取后确定性迁移并规范化为 v3；
- Builder 生成按声道分组、声道内有序的 Gain/Biquad stages，作用域、flat 消除、Nyquist
  诊断和容量失败均在发布前完成；
- Runtime ABI v2 同步复制 POD descriptor，验证稳定性与容量，并在预分配执行槽中维护每个
  stage 的独立状态；
- 编辑会话、typed clipboard、Undo/Redo、产品 Save/发布和 15 段 SwiftUI 编辑器均已接入；
- 通用节点行展示 Enabled、有效作用域、flat/增益范围和 active/expected Nyquist 诊断。

## 4. 自动化证据

- 五 target 无签名 `build-for-testing` 通过，证明 C ABI、Swift bridge、应用和测试 bundle 编译；
- Runtime 定向 23 项通过，包括 ABI layout、稳定性/容量拒绝、跨 block/声道状态隔离、
  1 kHz `+6 dB` impulse-response DFT `0.01 dB` 容差、10 ms chain/bypass 切换、热状态恢复、
  overlap、pending 合并、票据和 10000 次并发发布；
- Builder/Swift bridge 定向 17 项通过，产品控制器定向 48 项通过；
- `verify-m1-realtime.sh` 审计 26 个显式 Runtime/host callback helpers；
- 完整 hostless `EqualizerAUM1RuntimeTests` 共 188 项通过，零失败；
- 五 target 隔离、Plist/project/scheme、shell syntax 与 diff whitespace 门禁通过。

## 5. 历史待验收边界与后续结论

M2 完成时尚未启动 hosted test bundle、GUI、真实音频、Tap、Aggregate、设备 IO 或系统路线，
因此当时只形成以下待验收项：

- 15 段编辑布局、直接输入、滚动和诊断可读性；
- flat 透明、boost/cut 听感、运行中 Save、Processing A/B 与无爆音；
- M2 不改变 Core Audio 路线、Tap/Aggregate 生命周期或实时诊断计数 ABI。

这些项目没有被追记为“固定 15 段验收通过”。M4 人工验收否决固定 15 段作为最终产品模型，M6
随后以 schema v7 任意点模型和 minimum-phase FIR 完整替换，并通过当前 Graphic EQ 的签名应用
GUI 与真实音频验收。EqualizerAPO FIR 逐点兼容、可变频点和频响曲线已由 M6 实现；M2 仅保留为
schema v3-v5 迁移与 ABI v2 历史依据，不再有活动验收任务。
