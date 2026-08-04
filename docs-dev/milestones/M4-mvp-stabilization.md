# M4：MVP 稳定化

> **当前状态**：AUD-01、AUD-02、AUD-03、APP-01、UI-01 已关闭；其余受约束项目明确延期
> **验收基线**：`fba18d4 feat: implement M4 audio recovery`
> **验收日期**：2026-07-23

## 1. 目标

M4 使已运行的系统音频路线面对设备、格式、sleep/wake、权限和 Core Audio 服务变化时，
能够有界恢复或进入明确可操作状态，同时保持资源所有权和显式配置语义。

## 2. 已实现范围

- system/default-output/device-property 与 sleep/wake 生命周期监听；
- 默认设备 `(AudioObjectID, persistent UID)` 联合身份及事务式、有界监听重绑；
- 最多三次的 stop/re-discover/start 恢复、退避、事件合并和显式 Stop/Quit 取消；
- sleep 期间禁止启动、wake 单次恢复、捕获权限错误分类与系统设置入口；
- Tap/Aggregate 销毁前持久 UID 复核、临时 ID 复用保护和 unknown-identity ownership；
- 同一输出格式恢复的稳定快照确认、固定静音/近零释放和跨代 `.muted` Tap handover；
- 实际路线 Tap 的启动前权限门禁、provisional unmuted 到 `.muted` 转换及前台复核；
- recovering、waiting、sleeping、permission 与 monitoring failure 产品状态。

决策理由见 [`ADR 0010`](../adr/0010-bounded-audio-lifecycle-recovery.md)。

## 3. 自动化证据

- 产品与资源聚焦故障注入测试 80 项通过；
- 覆盖 route/service 变化、sleep/wake、权限、三次预算、退避中 Stop、恢复事件合并、
  blocked Start/layout 与 Stop/sleep 交错、persistent UID 复用和 unknown identity；
- `EqualizerAUM1` app target 无签名构建通过；
- 完整 hostless `EqualizerAUM1RuntimeTests` 共 278 项通过，零失败；
- 新增设备列表事件分类与跨重绑定重试状态测试：默认输出联合身份未变时不恢复，临时 ID
  或持久 UID 变化时恢复，首次重绑定失败后重试成功仍能补发一次事件；
- AUD-02 聚焦 Product、Route、Audio IO 与 Host 测试 118 项通过；覆盖设备属性事件身份与
  优先级、格式稳定/抖动/取消、错误设备降级、50 ms startup gate、共同跨零点、最小幅值回退、
  partial underrun、backlog drop 的 DSP 连续性、旧 Tap guard 转移/接管顺序、终态清理、
  销毁失败重试、maintenance callback 和显式 Stop/sleep/cancellation 交错；
- AUD-03 第一版 Product 与 Route/Resource 聚焦测试 110 项通过，但其临时 Tap 设计已被实机
  冷启动失败否定；修订后的 Route/Resource 聚焦测试 36 项通过，覆盖同一实际 Tap 的
  IOProc-before-probe、probe-before-mute、mute-before-start 顺序、权限拒绝、依赖清理、pending
  ownership 重试，以及前台复核不创建第二个 Tap；
- `EqualizerAUM1` app 和全部 test bundle 的无签名构建通过，Hosted test 未执行；
- realtime audit 29 个显式函数、五 target isolation、独立 C++ `-Wall -Wextra -Werror`、
  Plist/project/scheme、shell syntax 和 diff whitespace 门禁通过。

## 4. 人工验收约束与构建

- 缺陷先完整记录，不在发现后立即修改源码；被已知缺陷污染的测试暂停；
- GUI、真实音频和系统生命周期结论只采用用户实际操作后报告的结果；
- Apple Development 签名的 arm64 Debug 应用启用了 Hardened Runtime，bundle identifier 为
  `com.ruimingchen.EqualizerAU`；
- 验收应用位于 `.build/M4AcceptanceDerivedData/Build/Products/Debug/M1/EqualizerAU.app`；
- 候选修复后已覆盖重建同一路径应用；构建、`codesign --verify --deep --strict`、arm64 架构及
  产物内 `LSMultipleInstancesProhibited=true` 均通过。

## 5. 已通过的人工验收

| 编号 | 结果 |
|---|---|
| T00 | 签名 Debug 应用构建和签名验证通过。 |
| T01 | 首次启动和基础界面可用；同时发现窗口和编辑器后续要求。 |
| T02 | 修复后仅启用 `-9 dB` Preamp 并开启 Processing，连续音频稳定降幅；无卡顿、恢复循环或 route-operation 错误。 |
| T03 | Add、多选、Cut、Paste 功能可用；Paste 的性能问题转交 M5。 |
| T04 | Add Preamp、修改、删除及连续 Undo/Redo 的状态和值恢复正确。 |
| T05 | 关闭主窗口后应用保留在 Dock；Dock 重开保留未保存草稿。 |
| T10 | 合法的 0.2 秒、单声道、48 kHz、Int16 PCM WAV IR 导入成功。 |
| T11 | 取消 Replace IR 后保留原 IR 和节点状态。 |
| T12 | 伪造 `.wav` 文本文件被拒绝，原 IR 保留，应用继续可用。 |
| T13 | 合法但 3 秒的 WAV 被 2 秒上限拒绝，原 IR 保留。 |
| T14 | 原始 WAV 移走后，保存、退出和重启仍可从不可变 sidecar 恢复 IR。 |
| T15 | 仅启用短回声 IR 时 Processing 可稳定切换卷积湿声与干声；无卡顿、爆音、静音、恢复循环或 route-operation 错误。 |
| T17 | 同一输出设备切换采样率后，handover 恢复通过；无爆音、未处理原声旁路、持续静音、恢复循环或错误。 |
| T19-A | 撤销系统音频捕获权限并完全退出后冷启动；显式 Start 未进入运行态，界面进入权限/设置状态，持续播放的原音频始终正常可听。 |
| T19-B | 路线运行时在系统设置关闭权限但不重启；当前进程授权仍有效，路线和旁路保持正常、原音频始终可听，显式 Stop 正常完成，符合平台预期。 |
| T20 | 重新授予系统音频捕获权限并重启应用后，Processing 可稳定启动，声音和效果正常，无恢复循环或错误。 |
| T23 | 已保存配置在退出和重启后恢复。 |
| T24-A | 有未保存修改时 Quit 选择 Cancel，应用保持打开且草稿不丢失。 |
| T24-B | Quit 选择 Save 后，`-9 dB` Preamp 在重启后恢复。 |
| T24-C | 草稿改为 `-3 dB` 后选择 Discard，重启恢复已保存的 `-9 dB`。 |
| T25 | 连续音频下重复五次 Stop Engine / Start Engine；每次停止后原声正常、启动后效果恢复，无静音、爆音、卡顿、恢复循环或错误。 |
| T26 | 30 秒连续音频的两次诊断快照中，Captured frames 从 `632320` 增至 `1946112`，Rendered frames 从 `623616` 增至 `1937920`；Overflow、Underrun、Dropped backlog、Invalid、Overlapping、Non-finite、Saturated 计数始终为 `0`。 |
| APP-01 | 对运行中的签名应用执行强制重复启动，系统未创建第二实例，`pgrep -x EqualizerAU` 进程计数保持 `1`。 |
| UI-01 | 菜单无 `New Window`；`Command+N`、重复 Dock 激活及关闭后 Dock 重开均保持唯一主窗口。 |

T19 未通过：首次现场中，运行中撤销系统音频捕获权限后，应用仍显示 `Processing active`，
系统声音消失；完全退出应用后声音恢复。ADR 0012 候选修复完成后，签名应用又发现撤权后
冷启动并显式 Start 仍会使系统静音；停止 Engine 或退出应用后原声恢复。详见 AUD-03。

## 6. M4 收尾缺陷

### AUD-01：音频卡顿和自恢复循环

开启 Processing 并应用负 Preamp 后，出现持续卡顿、重复
`Recovering audio route (1/3)...`、`invalidState("route operation is already in progress")`，
输出状态在无活动输出与 `2 ch 48,000 Hz` 间变化。

源码边界确认应用创建或销毁 Tap/Aggregate 会产生与真实设备变化共用的设备列表信号，而旧
monitor 无条件将该信号升级为系统服务恢复。候选修复先重读默认输出 `(AudioObjectID, UID)`：
身份未变时忽略列表变化，身份变化时恢复；首次重绑定失败会保留事件语义到重试成功。修复
没有吞掉 `operationInProgress`。修复后 T02 已由用户在签名应用中复测通过，AUD-01 关闭。

### APP-01：单应用实例

应用必须在程序级保证单进程实例。重复启动应激活既有实例及其主窗口，不得创建另一个可
独立控制系统音频路线的进程。候选修复已加入 `LSMultipleInstancesProhibited`，并由 app-hosted
测试读取生产 Plist 契约。签名应用的强制重复启动与进程计数已由用户复测通过，APP-01
关闭。该要求独立于 AUD-01。

### UI-01：单主窗口

移除 `New Window` 入口和创建多个 editor 主窗口的能力。T05 的 Dock 重开路径只出现一个
窗口，不代表菜单中的多窗口入口符合要求。候选修复已将 `WindowGroup` 改为唯一 `Window`
scene，并在 Dock/reopen 回调中激活或恢复该窗口。签名应用的菜单、快捷键、重复 Dock 激活
和关闭后重开已由用户复测通过，UI-01 关闭。

### AUD-02：采样率切换瞬间爆音

Processing 运行并持续播放时，在“音频 MIDI 设置”切换当前真实输出设备采样率，路线能够恢复，
效果也继续生效，但切换瞬间出现短暂爆音。T17 因此未通过。按人工验收的 record-first 约束，
该问题先保留现场结论，没有在其余可执行验收完成前修改源码。用户进一步确认爆音发生在短暂
静音结束后的第一个声音。2026-07-22 已批准 ADR 0011：保留事件监听和联合 UID，在格式恢复时
等待输出快照稳定，并仅对该恢复路线执行 50 ms 固定静音及有界近零点释放。源码、故障注入、
完整 hostless、实时审计、严格编译和静态复审已通过。首次签名应用复测确认爆音已消失，但旧
`.muted` Process Tap 完整清理至新 Tap 接管之间会短暂输出未处理原声，证明仅处理新路线释放
不足以覆盖 replacement ownership 空窗。用户随后批准把同设备旧 Tap 作为跨代 mute guard：
旧 Aggregate/Runtime/IO 清理后保留旧 Tap，新 Tap、捕获和输出全部启动后才按持久 UID 销毁；
身份变化降级、取消、显式 Stop/sleep/Quit、维护终态、权限失败和预算耗尽均有明确清理语义。
该 handover 实现已通过 118 项聚焦、263 项完整 hostless、构建、实时/隔离/严格编译门禁和
独立复审。签名应用随后由用户再次执行 T17，确认无爆音、未处理原声旁路、持续静音、恢复循环
或错误；AUD-02 关闭。

### AUD-03：运行中撤销权限后静音且状态失真

Processing 运行时在系统设置中撤销 EqualizerAU 的系统音频捕获权限，应用仍显示
`Processing active` 和活动输出格式，但系统声音消失，也没有进入 permission 状态或安全停止
路线。用户执行 `Command+Q` 完全退出应用后声音恢复，证明退出清理能够释放该路线。T19
因此未通过。当前证据只确认运行期权限撤销未被正确处理，不提前断言底层回调或权限通知的
具体行为；按 record-first 约束先记录，后续统一诊断和修复。重新授予权限并重启应用后的
T20 已通过，但只证明冷启动恢复路径可用，不关闭运行期撤权缺陷。

2026-07-22 用户批准了第一版 ADR 0012：应用返回前台且路线稳定运行时创建不接入 Aggregate
的临时 unmuted Process Tap，权限拒绝或其他探针错误均先安全停止现有路线。第一版候选源码
通过 110 项聚焦、275 项完整 hostless、app/build-for-testing、实时/隔离、两份 C++ 严格编译、
静态门禁和独立复审。

签名应用复测未关闭该缺陷：用户先撤销权限并退出应用，随后冷启动并显式开启 Processing，
系统仍进入静音状态，且只有停止 Engine 或退出应用后原声才恢复。该结果表明当前环境中的
生产 Tap 创建路径没有及时向产品层暴露预期的权限拒绝；仅依赖
`AudioHardwareCreateProcessTap` 的创建错误不足以覆盖该真实边界。此次操作没有验证“路线
运行中撤权后返回前台”的探针分支是否单独有效，但已经证明当时的整体权限安全契约仍不成立，
T19 当时未通过，AUD-03 继续处于打开状态。

Apple 公开文档和 SDK 没有提供系统音频权限 preflight 或运行期撤权通知，但允许读取和修改
`kAudioTapPropertyDescription`。Chromium 自 macOS CATap 初始实现起，采用“创建实际 Tap、
Aggregate 和 IOProc 后，在 `AudioDeviceStart` 前读取并同值写回实际 Tap description”的默认
权限探测；任一步失败均按权限缺失处理。该行为是公开属性操作上的生产经验，不是 Apple 明文
保证的权限查询契约。

用户随后批准修订方案：实际路线 Tap 先以 provisional unmuted 创建并登记 ownership，完成
Aggregate、Runtime 和捕获 IOProc 注册后，在同一 Tap 上执行 description 读取和同值写回；
成功后把同一对象切换为 `.muted`，才允许启动捕获并创建输出。失败时捕获和输出均不启动，按
IOProc、Aggregate、Tap 顺序清理。前台复核复用既有路线 Tap，不再创建第二个 Tap。修订候选的
36 项 Route/Resource 聚焦、278 项完整 hostless、app/build-for-testing、实时/隔离、两份 C++
严格编译和静态门禁均已通过。2026-07-23 的签名应用 T19-A 已通过：撤权并完全退出后的冷启动
Start 未进入运行态，界面进入权限/设置状态，持续播放的原音频始终正常可听。

同日尝试 T19-B 时，签名应用先在重新授权后稳定运行。用户在系统设置中关闭权限但不重启
应用，当前进程的授权没有实际失效：路线保持运行，旁路功能正常，原音频始终可听，随后显式
Stop 也正常完成。继续显示运行符合当前有效授权，不应误判为回归；重启后撤权生效的边界已由
T19-A 覆盖。用户确认当前状态通过并视为已修复，AUD-03 关闭；前台复核继续作为实际授权失效
时的防御性门禁。

## 7. 转交后续阶段的需求

以下项目不是 M4 生命周期实现的局部收尾，已按独立产品特性拆分：

- M5 接收处理器 Add 位置、EqualizerAPO 编辑器对齐、拖拽、全部处理器展示、IR 错误弹窗
  以及相关交互性能要求，见 [`M5-equalizerapo-editor-parity.md`](M5-equalizerapo-editor-parity.md)；
- M6 接收废止固定 15 段 Graphic EQ、任意频率控制点及其 DSP 和编辑交互要求，见
  [`M6-arbitrary-point-graphic-equalizer.md`](M6-arbitrary-point-graphic-equalizer.md)。

## 8. 暂停项目与退出条件

- T16 默认输出设备切换由用户选择本轮暂缓，尚无通过或失败结论；
- T18 sleep/wake 恢复由用户选择本轮暂缓，尚无通过或失败结论；
- T19 的旧候选曾因撤权后冷启动 Start 静音而失败；修订候选的冷启动拒权 T19-A 已通过，
  当前进程授权仍有效时继续稳定运行的 T19-B 也符合平台预期，AUD-03 已关闭；
  T20 重新授权后的冷启动恢复、T25 五次重复启停和 T26 实时诊断通过；
- T21-T22 涉及 Core Audio 系统服务故障与恢复边界；仓库禁止主动重启 `coreaudiod`，本轮不以破坏性系统操作制造现场，延期验收且不虚构结论；
- T06-T09 转交 M6：固定 15 段模型已被新产品要求取代；
- AUD-01、AUD-02、AUD-03、APP-01 与 UI-01 已通过人工复测关闭；T25-T26 已通过；用户暂缓或
  受安全约束的 T16、T18、T21-T22 保持明确延期结论；
- Hosted Tests、正式签名、Archive、安装和 notarization 在相关功能阶段完成后统一执行。
