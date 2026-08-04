# M10：Convolution IR 长度自由与原采样率加载

- 状态：已完成并关闭
- 日期：2026-07-30
- 决策：[`ADR-0017`](../adr/0017-unbounded-convolution-ir.md)、
  [`ADR-0018`](../adr/0018-computational-processing-bypass.md) 与
  [`ADR-0019`](../adr/0019-float64-deadline-distributed-convolution.md) 均已接受
- 前置：M8 Convolution source-path 已完成并关闭

## 目标

取消 Convolution 的人为文件大小、时长和 taps 配额，不截断、不重采样用户 IR；保留严格 WAV
基本检查、节点级旁路和 realtime callback 无文件 IO/无动态分配边界。超过 8 秒只提示性能可能
下降，不阻止加载。Processing Off 必须把应用内部路径从 `采集 → Processor Chain → 输出` 切换为
`采集 → 输出`，在 10 ms 淡出完成后停止全部 wet DSP，同时保持 Core Audio 路线不变。

## 范围

- 删除 32 MiB 和 2 秒 loader 限制；
- 删除 ABI v3 单 kernel 384,000 taps 与总计 131,072 taps 限制；
- 保留最多 8 个 convolution channel instances；
- IR 与输出采样率偏差超过 1 Hz 时节点级旁路并显示原因；
- 删除离线 windowed-sinc IR SRC；
- 超过 8 秒时显示非阻塞性能警告；
- Builder 降低到 Runtime stage 时逐声道去除末尾精确零值，全零声道保留一个零 tap；
- Processing Off 在 10 ms fade-out 后进入 computational bypass，不再执行任何 wet stage 或 FFT；
- Processing On 保持 dry，按当前输出和 `runtimeBaseline.nodes` 重读资源、安装 fresh Prepared 后
  才 10 ms fade-in；
- bypass 状态 Save 直接安装 fresh slot，Active 状态 Save 继续原有 10 ms 双链 crossfade；
- 正常 Off/On 不创建、销毁、启动或停止 Tap、Aggregate、Audio Unit 与 Runtime handle；
- 保留 WAV encoding、metadata、声道、空音频、finite/normal sample、普通文件、取消、整数和
  动态分配检查；
- schema v8、源路径生命周期、Prepared 深拷贝、10 ms 切换和 explicit Save 语义不变。

## 非目标

- 不取消 Graphic EQ 的 512 控制点上限或 16,384-tap FIR 设计；
- 不增加 FLAC/OGG、Float64、true-stereo 或矩阵 IR；
- 不增加文件监听、hot reload 或跨生效长期缓存；
- 不在 callback 中加载、分配或重建卷积；
- 不改变输出设备选择、登录启动或 EqualizerAPO 配置导入范围；
- 不把节点 power 改成立即生效，节点编辑仍需 explicit Save；
- 不为正常 Processing Off/On 重启 Core Audio 路线。

## 自动化验收

- 超过 2 秒、超过旧 131,072 总 taps 和超过旧 384,000 单 kernel 边界的 IR 可以加载并创建
  Prepared；
- `>8 s` source diagnostic 有性能警告，普通短 IR 无警告；
- sourceFrameCount 与警告保留完整文件长度，但 2 秒/9 秒且有效 taps 相同的 IR 编译为相同 kernel；
- 采样率不匹配只旁路所属节点并保留 source/target 原因；
- 损坏 WAV、不支持 encoding、空音频、非有限/subnormal sample 和声道不匹配仍被拒绝或旁路；
- 9 个 convolution instances 仍整批拒绝；
- full hostless tests、isolation、realtime、localization、C++ strict compile 和 diff checks 通过；
- Release 模式重放短 IR 基线，并增加代表性长 IR prepare/steady-state 测量；
- fully bypassed callback 成本接近 dry baseline，且不随 taps、stage 或声道实例工作量增长；
- dense 9 秒 IR overload 后 Off 在候选 2 秒上限内恢复 dry，正常路径无 Start/Stop/HAL 调用；
- re-enable 顺序为 prepare → bypass replace → enable → callback ack，失败始终保持 dry；
- bypass Save、rapid intent、persistence、route generation、sleep/recovery 与 Quit drain 全覆盖。

## 实现顺序

1. 用户确认 ADR-0018 的 fresh 冷状态恢复与 2 秒异常超时策略；ADR 改为 Accepted；
2. Runtime dry fast path、effects ack 与 bypass-only fresh replacement；
3. RuntimeLeaseAccess、RouteCoordinator 的等待/所有权/bridge generation，不触碰 HAL 生命周期；
4. ProductController 非对称 Off/On 流程、最新意图、持久化和失败终态；
5. UI transitional 状态与中英本地化；
6. focused/full tests、Release active/bypass probe、签名候选和用户原生真实音频复验；
7. 用 formal-r4 选出的 ADR-0019 Float64 deadline-distributed multistage NUP 替换 scalar uniform tail，
   重新执行产品级数学、可变 callback、Release 性能、签名候选和真实音频验收。

前 1～7 步的实现与自动化验证均已完成；用户已确认 computational bypass 可以从 dense IR
overload 恢复稳定 dry，并于 2026-08-02 通过 ADR-0019 最终 Release 候选完整验收。M10 已完成并
关闭；commit、push、tag 与公开发布仍需单独授权。

## 最佳卷积内核实验

2026-08-01 在 `.build/convolution-lab/` 完成六方案隔离对比，永久决策见
[`ADR-0019`](../adr/0019-float64-deadline-distributed-convolution.md)。formal-r4 以共享 direct oracle、
extreme finite、signed saturation、pending-S3 reset、完整 432,000-tap impulse 与 S3 cross-partition
gate 淘汰四个会对合法 finite Float32 产生 Inf/NaN 的 Float32 vDSP 候选；formal-r4 的 scalar
基线与 Float64 方案通过正确性，只有 Float64 deadline-distributed multistage 通过 432k stereo primary
qualification。

winner 的 432k stereo wall p99 为 0.3614 ms（95% CI 0.3530...0.3724），相对 scalar baseline paired
提升 11.81 倍；8-channel active wall p99 CI 上界 1.5712 ms，dual-bank 4-channel-each 上界
1.4571 ms，均低于 5.333 ms deadline 的 50%。reported stereo memory 从 56.05 MiB 降到
22.63 MiB。两路独立数学/统计复核和最终 ASan/UBSan 均为 CLEAN。实验 runner 固定 256 frames，
产品适配保留 256-tap direct head，并已证明任意 callback 分块下仍为 0-frame latency。

## ADR-0019 产品集成证据

产品 Runtime 已把 scalar full-complex uniform tail 替换为 Accelerate Float64 packed-real、
deadline-distributed multistage NUP；ABI v3 和 schema v8 不变。tail 为 `256×1 @ 256`、
`512×≤4 @ 512`、`2048×≤8 @ 2560` 和 `16384×N @ 18944`，S2/S3 固定在 `T-256`
publish。相同 taps 共享 immutable kernel spectra，各声道、stage、slot 的 history 独立。

最终 corrected product probe 使用 dense 432,000 taps、完整 steady-state warmup、五个不同 phase 和
每场景 8,192 callbacks。所有 wall/thread-CPU deadline misses 均为 0：

| 声道实例 | Active wall p99 中位数 | Active callback 最坏 | 双链 transition 最坏 | Fade-out 最坏 | Bypassed wall p99 中位数 |
|---|---:|---:|---:|---:|---:|
| 1 | 0.215 ms | 0.599 ms | 0.313 ms | 0.217 ms | 0.0007 ms |
| 2 | 0.429 ms | 1.309 ms | 0.654 ms | 0.431 ms | 0.0011 ms |
| 4 | 0.862 ms | 1.558 ms | 1.264 ms | 0.924 ms | 0.0016 ms |
| 8 | 1.744 ms | 2.819 ms | 2.499 ms | 1.833 ms | 0.0025 ms |

日志为 `.build/m10-nup-product-release-final.log`。最终 RuntimeSmoke 39/39；完整 hostless suite
347 tests、2 个性能 fixture 按设计跳过、0 failures；最终源 432k ASan+UBSan、全部静态门禁和两路
独立实现复核均通过。Apple Development arm64 **Release** 候选已构建到
`.build/M10NUPAcceptanceDerivedData/Build/Products/Release/M1/EqualizerAU.app`，strict codesign、
Hardened Runtime、Accelerate 链接与版本 `0.1.0 (1)` 均已核验，但尚未由助手启动。

## 历史 Release 性能证据（scalar uniform）

2026-07-30 在 arm64 Release、48 kHz、256-frame blocks 下隔离重放 5 次：

| taps / 声道实例 | 1 ch | 2 ch | 4 ch | 8 ch |
|---|---:|---:|---:|---:|
| 16,384 stable ratio 中位数 | 0.02061 | 0.04082 | 0.08383 | 0.16925 |
| 16,384 transition ratio 中位数 | 0.03612 | 0.07402 | 0.17005 | 0.34025 |
| 384,001 stable ratio 中位数 | 0.19453 | 0.40038 | 0.80819 | 1.64057 |
| 384,001 transition ratio 中位数 | 0.32402 | 0.92942 | 2.44918 | 7.59602 |
| 384,001 transition ratio 最大值 | 0.49834 | 1.22224 | 2.59980 | 15.98830 |
| 384,001 prepare 中位数 | 8.041 ms | 15.581 ms | 32.279 ms | 62.446 ms |

修正后的 probe 使用不同 candidate taps，并在 kernel 末尾保留非零 tap，确保真实进入 10 ms
双链 crossfade 且代表不可裁剪的有效长度。384,001 taps 的 8 声道稳定处理已超过 realtime；
4/8 声道 transition 也超过 realtime。该结果支持“允许用户选择、严格超过 8 秒显示性能警告”的
合同，不恢复硬拒绝，但用户验收必须覆盖长 IR Save/Processing 切换是否出现 underrun 或听感中断。
精确零尾部不属于这项成本：2 秒和 9 秒 unit impulse 均编译为一个 tap。最终日志为
`.build/m10-m6-baseline-trim-final.log` 和 `.build/m10-long-ir-performance-trim-rerun.log`。

2026-07-31 ADR-0018 实现后在相同 Release 条件隔离重放 5 次；probe 新增真实 fade-out 与
fully-bypassed dry-path 测量：

| taps / 声道实例 | 1 ch | 2 ch | 4 ch | 8 ch |
|---|---:|---:|---:|---:|
| 16,384 stable ratio 中位数 | 0.02063 | 0.04111 | 0.08088 | 0.17244 |
| 16,384 fade-out ratio 中位数 | 0.01601 | 0.03238 | 0.06399 | 0.12811 |
| 16,384 bypassed ratio 中位数 | 0.00011 | 0.00019 | 0.00028 | 0.00046 |
| 384,001 stable ratio 中位数 | 0.19870 | 0.39122 | 0.79673 | 1.64767 |
| 384,001 chain transition ratio 中位数 | 0.34979 | 0.95493 | 2.07624 | 5.92893 |
| 384,001 fade-out ratio 中位数 | 0.10028 | 0.21340 | 0.42021 | 0.84521 |
| 384,001 fade-out ratio 最大值 | 0.11157 | 0.21946 | 0.46002 | 1.15659 |
| 384,001 bypassed ratio 中位数 | 0.00011 | 0.00019 | 0.00028 | 0.00048 |
| 384,001 prepare 中位数 | 7.798 ms | 15.095 ms | 30.579 ms | 62.380 ms |

16,384-tap stable 数值与历史基线同量级。dense 8-channel active steady 仍超过 realtime，但 Off 只承担
有限 10 ms fade；fully bypassed 后 ratio 降到 `0.00048`，且 384,001-tap 与 16,384-tap 的 dry 成本
相同量级，证明旁路不再执行 stage/FFT。8-channel fade-out 单次最大值仍可能超过 realtime；这项
当时的第三轮验收门槛已在 2026-08-01 computational bypass 真实音频复验中通过。日志为
`.build/m10-computational-bypass-baseline.log` 与 `.build/m10-computational-bypass-long-ir.log`。

2026-07-30 首轮候选自动化验证（已被 trailing-zero 修正取代）：focused suites 72/72 通过；完整
`EqualizerAUM1RuntimeTests` 323 tests、2 个性能 fixture 按设计跳过、0 failures；5-target isolation、realtime audit、localization、
`plutil`、全部 zsh 语法、C++ strict compile、Markdown links 和 `git diff --check` 全部通过。
第一次完整重放命中既有间歇 recovery race，隔离重放也复现一次；未改 timeout，最终完整重放通过。
Apple Development arm64 Debug 首轮候选曾构建于 `.build/M10AcceptanceDerivedData`，
`codesign --verify --deep --strict` 通过，TeamIdentifier 为 `598JJTW3KA`；该候选已删除，不得再用于验收。

2026-07-31 trailing-zero 修正后验证：focused suites 75/75 通过；完整
`EqualizerAUM1RuntimeTests` 326 tests、2 个性能 fixture 按设计跳过、0 failures；全部静态门禁通过；
独立只读复核最终为 CLEAN。dense 384,001-tap Release probe 保留末尾非零 tap 并完成隔离重放，
2 秒/9 秒 unit impulse 则由 Builder contract test 证明均编译为一个 tap。修正版 Apple Development
arm64 Debug 候选已重建到 `.build/M10AcceptanceDerivedData`，strict codesign 通过，TeamIdentifier
为 `598JJTW3KA`。

2026-07-31 ADR-0018 computational bypass 最终自动化验证：核心 focused suites 185/185 通过
（Runtime 32、retirement 14、route 46、Product 93）；完整 `EqualizerAUM1RuntimeTests` 340 tests、
2 个性能 fixture 按设计跳过、0 failures。5-target isolation、30 个 realtime 显式函数审计、
localization、`plutil`、全部 zsh 语法、Runtime/probe C++ strict compile、Markdown links 与
`git diff --check` 全部通过。两轮独立只读 recheck 在 freshness、deadline、latest intent、route ack、
activation token 线性化和错误来源隔离修正后均为 CLEAN。最终 Apple Development arm64 Debug 候选
于 2026-07-31 21:29 重建到 `.build/M10AcceptanceDerivedData`，`codesign --verify --deep --strict`
通过，TeamIdentifier `598JJTW3KA`；未启动 GUI 或真实音频。

## 用户验收

2026-07-31 首轮候选未通过：带离散回声的 2 秒夹具被报告为卡顿沙哑，尾部增加精确零值的
9 秒夹具更严重。两份文件的非零 taps 相同，因此后者差异确认 Runtime 对无贡献零 partition 的
成本；验收夹具本身也不适合透明度判断。修正要求是 Prepared 仅保留有效 taps，并以真正 unit
impulse 重新验收，不能把性能警告解释为音频损坏可以接受。

2026-07-31 第二轮候选再次未通过：2 秒与 9 秒 unit impulse 已证明 trailing-zero 修正有效，
但真正具有非零 9 秒尾部的 dense IR 使声音完全无法听；关闭全局 Processing 后卡顿不消失。
运行时代码确认全局旁路仍无条件执行 wet chain，只在末端混回 dry。该结果否决 ADR-0008 的
hot-state bypass，并将 ADR-0018 computational bypass 提升为 M10 关闭前的硬阻塞项。

2026-08-01 第三轮用户真实音频验收确认 ADR-0018 computational bypass 已起效：dense 9 秒 IR
active overload 时，Processing Off 能进入稳定 dry，用户回复“起效了，没问题”。该结果关闭旁路
架构缺陷。用户同时要求 dense IR active path 采用经六方案 formal-r4 选出的最佳实现，随后形成
ADR-0019 并完成产品集成与自动化验证。

2026-08-02，用户针对上一轮交付的完整 Release 验收清单回复“测试通过了”。该清单覆盖
48 kHz 2 秒 unit impulse 透明度、9 秒零尾与性能警告、9 秒 dense IR active 稳定性、Save 双链切换、
全局 Processing Off/On fresh-state 恢复、44.1/48 kHz mismatch 节点级旁路与恢复，以及正常 Quit。
据此，ADR-0017 长度自由、ADR-0018 computational bypass 和 ADR-0019 最佳 long-IR 内核均完成
自动化、原生 GUI 与真实音频验收，M10 正式完成并关闭。该结果不授权 commit、push、tag 或发布。
