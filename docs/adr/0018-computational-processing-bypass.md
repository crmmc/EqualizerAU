# ADR-0018：Processing 真实计算旁路与冷状态恢复

- 状态：Accepted
- 日期：2026-07-31
- 范围：M10 Processing 总旁路、Runtime 执行、Prepared 发布与产品状态
- 关联：ADR-0008、ADR-0014、ADR-0017
- 用户已确认边界：旁路必须在应用内部把 `采集 → 处理器链 → 输出` 切换为 `采集 → 输出`

## 背景

当前 Runtime 的 Processing Off 仅把 wet 输出以 10 ms 淡出到 dry，仍对每个 sample 执行完整
Gain / Biquad / Convolution chain。M10 真实音频复验中，9 秒 dense IR 使 callback 严重超时；
关闭 Processing 后卡顿不消失，因为 dry 输出仍承担同一 wet 计算成本。

这与产品拓扑不符。Processing 总旁路必须保留已建立的 Process Tap、Aggregate Device、捕获和
输出 Audio Unit，只在 EqualizerAU callback 内部切换 sample 路径。节点电源仍是配置草稿，显式
Save 后生效，不与 Processing 总旁路合并。

ADR-0008 决策 6 的“旁路期间继续推进 wet state、从热状态恢复”由本文决策取代。停止执行
wet chain 后，旧 biquad/FIR history 缺失旁路期间输入，不能作为连续状态恢复。

## 拓扑合同

```text
Active / Fading
采集 → finite sanitize → Processor Chain → dry/wet mix → 输出

Fully Bypassed
采集 → finite sanitize ───────────────────────────→ 输出
```

正常 Processing 切换不得创建、销毁或重建 Tap、Aggregate、Audio Unit、SPSC 或 Core Audio 路线，
不得触发 Start/Stop、权限请求、默认设备切换或 Runtime handle 替换。

## 状态机

| 状态 | callback 行为 | 控制线程行为 | 对外状态 |
|---|---|---|---|
| Active | 执行单条 active wet chain | 可正常 Save/发布 | Processing active |
| Fading Out | 最多 10 ms 执行 wet 并线性淡出到 dry | 等待 callback ack | transitional |
| Bypassed | 只 sanitize 和 dry 直通，不访问 stage/FFT state | 可直接安装 fresh Prepared | Processing bypassed |
| Preparing | 继续 dry 直通 | 重读资源、编译并安装 fresh Prepared | transitional |
| Fading In | 对 fresh wet 做 10 ms dry→wet 淡入 | 等待 callback ack | transitional |

`appliedEffectsEnabled` 只在 Fading Out 到达 Bypassed 或 Fading In 到达 Active 后更新。UI、菜单栏
checkmark 和蓝/绿状态点不得把 Preparing 或 Fading In 提前显示为 active。

## Processing Off

1. ProductController 记录最新用户意图并调用现有 Runtime effects 控制通道，不停止路线。
2. 每个 effects request 必须先到 terminal state，再处理最新后继意图；不保留旧的 mid-ramp 反向
   快捷路径。每次 Fading Out/Fading In 都从当时 mix 开始走完整 10 ms，输出保持连续。
3. callback 在淡出到零后的同一 block 剩余 frames 立即走 dry-only，不再访问任一 slot；若此前有
   active chain transition，先把已请求 target 直接提升为 terminal generation。
4. 只有整个 callback block 已确认不再访问 slot 后，才以 release store 发布 Bypassed；控制线程
   acquire-load 该状态后才可写 inactive slot。后续 block 不调用 `processChainSample`，不推进
   biquad、FIR、FFT、chain transition 或 wet 诊断。
5. M1NativeAudioRouteCoordinator 等待 block-boundary ack 后才把 Off 命令报告为已应用；等待
   上限为 2 秒，从 desired=false 成功写入 Runtime 时开始计时。
6. 2 秒内没有 ack 新增 `.effectsBypassTimedOut` recoverable-stop reason；effects operation 终态为
   `stopped(error)`，Product 清除 applied projection、保留未持久化 Off intent 并等待现有手工 Retry。
   2 秒参数已由用户在 2026-07-31 接受 ADR-0018 时确认。

## Bypassed 状态的 Prepared 安装

新增 additive ABI-v3 控制扩展，现有 POD layout 与 ABI 版本不变：

- `EAUM1EffectsState` 固定为 `Active=1`、`FadingOut=2`、`Bypassed=3`、`FadingIn=4`；
- `EAUM1RuntimeCopyEffectsState`：读取 lock-free 状态，不分配、不等待；
- `EAUM1RuntimeReplacePreparedWhileBypassed`：仅在 fully bypassed、无 retired/pending、既有 chain
  transition 已完成且声道 topology 相同时接受候选；
- `EAUM1StatusNotReady=8`：上述控制前置尚未满足时返回，区别于 malformed、capacity 与 OOM。

Replace 在控制线程把候选复制到 inactive slot，生成全新零状态；写入完成后以 release store 切换
active slot，callback 以 acquire load 观察。callback 的 Bypassed ack 保证当前及后续 dry block 不读取
slot，因此不形成数据竞争。成功时消费候选，失败时 ownership 保持调用者；即使执行计划数值相同
也必须重建状态，不能走 equivalent-plan 热状态复用。

现有 `EAUM1RuntimeCapabilities` layout 不增加字段；`EAUM1RuntimeCreate` 的内部 lock-free gate 同时
检查 desired effects 与 acknowledged effects-state atomics，原 `effectsEnabledLockFree` 仍只报告原字段。
RuntimeAccess 跨 await 只保留 Swift compiled stages，不保留 native Prepared；native candidate 在同步
C 调用前才创建，失败立即销毁。每次 await 后重新校验 bridge generation、intent 和 operation ID。

## Save、publication 与串行化

节点 Save 保持 durability-first：`prepare → durable commit succeeded → Runtime application`。
`.uncertain` 不应用候选；同 generation Retry 确认后必须重新 prepare。commit succeeded 但 Runtime
application 失败时，`saved` 已更新、`runtimeBaseline` 不更新，状态进入 `savedPendingStart` 并保留
expected generation/diagnostics，不能报告 Save 全部成功。

durable node application、effects transition 与 fresh activation 共享 Runtime control queue，但 queue lease
只覆盖不含 await 的同步 Runtime 控制调用；callback transition、磁盘 commit、prepare 与 ack 等待不持有
lease。四种身份必须分离：

- `durableApplicationID`：已确认写盘的节点代次，不能被 effects intent supersede；
- `runtimeQueueLeaseID`：一次同步 publish/replace/set-effects 控制临界区；
- `effectsIntentRevision`：每次用户总开关请求递增，表示最新 requested 值；
- `activeEffectsOperationID`：已经开始 prepare 或 fade、必须收敛到 terminal 的当前操作。

Off 是安全高优先级：若 Save 正在磁盘/prepare/等待 callback，Off 可先取得下一个短 queue lease；只有
正在执行的同步 C 调用必须先返回。Save 已进入 native publication 时，该调用已返回并释放 lease；
Off 随后启动 fade，callback 在 Bypassed block-boundary 同时把 Save target generation 提升为 terminal。
Save 的 durableApplicationID 独立接收 generation ack、保留 expectedDiagnostics，再在 Off terminal 后
按 Bypassed 状态继续，不因 effects revision 更新而取消。

- Active：现有 10 ms old/new 双链 crossfade；
- Bypassed：等待/重试 Runtime `NotReady`，随后 cold replace，不执行 wet 或双链；
- Fading/Preparing：等待当前 effects operation terminal，再重新分类；
- route stopped/bridge changed：进入 `savedPendingStart`，不得发布到旧 bridge。

On activation 必须先排空更早的 durable Save application，确保 `runtimeBaseline.nodes` 是最近实际安装的
已保存链。节点 power 仍只修改 draft，未 Save 不改变声音。

若进入 Bypassed 时已有 native retired/pending：callback 在 block-boundary ack 直接完成当前 requested
generation；maintenance 回收 retired 后，必须把**最新 pending**以同一 bypass cold-replace 规则提升为
active，不得发起新的普通 chain transition。Swift pending configuration generation 与 diagnostics 随该
cold promotion 一起完成；不得丢弃已 durable Save。

`waitUntilIdle()` 不是排他 barrier。cold replace 以 Runtime `NotReady` 为最终安全判定，按 1 ms cadence
重试。durable Save 每次重试只校验 durableApplicationID 与 bridge generation，不检查 effects revision；
effects activation 则校验 activeEffectsOperationID、effectsIntentRevision 与 bridge generation。
route change 立即取消旧 bridge 工作；pre-desired-write supersede 立即丢弃 activation preparation；2 秒候选
deadline 到达时 activation 失败并保持 dry，durable Save 保持 `savedPendingStart`。新的同步 C 控制调用
在 runtimeQueueLeaseID 释放前不得进入，但不能用该 lease 阻塞 callback ack 或高优先级 Off。

## Processing On

1. ProductController 保持 dry，先排空更早 durable application，再使用 `runtimeBaseline.nodes`；不得应用
   未保存的 `draft.nodes`。
2. M1NativeAudioRouteCoordinator 在 detached 控制路径按当前 output layout 重新运行 Builder；外部 IR
   按 ADR-0014 每次 activation 重新打开、校验和解码，不使用跨 activation 长期缓存。
3. 等待 fully-bypassed ack；在 desired write 前以 activeEffectsOperationID 与 effectsIntentRevision 驱动
   `NotReady` 重试，route/bridge/layout 或 superseding intent 变化立即丢弃 preparation。
4. 通过 bypass replace 安装 fresh Prepared；diagnostics 先进入 expected，配置 generation 不因单纯
   activation 伪造新节点代次。
5. 只有 replace 成功后才设置 Runtime effects=true，执行完整 10 ms dry→wet 淡入。
6. callback 报告 Active 后才 promotion diagnostics、更新 `appliedEffectsEnabled=true`、
   `runtimeBaseline.effectsEnabled=true` 和绿色状态。
7. Runtime 应用成功后沿用现有 effects runtime-first persistence；持久化 failed/uncertain 不回滚声音或
   terminal runtimeBaseline，但保留未保存/不确定退出事务。prepare、replace 或 fade-in 失败保持 dry。
8. fade-in 超时先发起 Off 并等待 Bypassed；仍超时才进入 recoverable stop。

快速 Off/On、On/Off 只更新 `effectsIntentRevision` 与 requested 值。不可取消点固定为 Runtime 成功接受
`effectsEnabled` desired write：

- 不可取消点之前，新 revision 可使 activation `superseded`，丢弃 Swift preparation；
- 不可取消点之后，activeEffectsOperationID 不再因新 intent 变 stale，必须拥有并处理 terminal ack，
  更新实际 applied/baseline 后才结束；新 intent 只作为 pending successor；
- route/bridge 失效仍可终止旧 operation，因为旧 Runtime 不再代表产品实际路线；其资源必须先释放；
- fade-in timeout 发起的 Off 是原 On operation 的内部补偿阶段，不创建新用户 operation。补偿成功后
  原操作以 `failed` 结束，即使 requested 仍为 true也不得自动重试，必须等待新用户动作或 Retry。

当前 operation terminal 并释放相关 ownership 后，才激活 pending successor。prepare 被 supersede、
route/layout 改变、deadline、Quit 或新 prepare 取代时丢弃 Swift compiled preparation；尚未进入同步
C 调用就不存在 native candidate。每次新 On activation 都重新读取资源，不能复用跨 activation 结果。

## 产品投影、诊断与 operation 终态

Snapshot 明确拆分：

- `requestedEffectsEnabled`：最新用户意图，驱动主窗口 Toggle 与菜单 checkmark；
- `appliedEffectsEnabled`：只代表 callback terminal Active/Bypassed；驱动实际音频判断；
- `processingTransition`：`idle / fadingOut / preparing / fadingIn`；驱动禁用条件和状态文本。

Fading Out 时 requested=false、applied=true；Preparing/Fading In 时 requested=true、applied=false。
状态点只在 terminal Active 为绿色，其他正常终态/transition 为蓝色，失败为红色；状态文本提供非颜色
通道。UI 反向点击基于 requested 值，不得用 `!processingEnabled` 猜测意图。

`activeEffectsOperationID` 由 ProductController 单调分配，终态固定为 `applied / superseded /
cancelledByRouteChange / failed / stopped`。`durableApplicationID` 和 `runtimeQueueLeaseID` 有各自终态，
不得因 effectsIntentRevision 更新而冒充 superseded。persistence `.failed/.uncertain` 是后继 durability
transaction，不是已成功 Runtime operation 的回滚。Quit 等待 active operation、内部补偿、durable
application 和 queue lease 全部释放并到达终态；旧 bridge ack 只完成资源清理，不能更新当前 UI、
baseline 或 diagnostics。

On prepare 的 diagnostics 先进入 expected；replace 后、fade-in 前仍是 expected；Active ack 才 promotion
为 active。superseded、prepare/replace/fade 失败清除对应 expected。Bypassed Save cold replace 成功后，
已安装 generation 可立即 promotion 为 active，即使当前输出是 dry。durable commit 成功但 replace 失败
则保留 expected 并进入 `savedPendingStart`。stale bridge diagnostics 永远不得覆盖当前 bridge。

## 路线、恢复与失败语义

- 正常 Off/On 的 HAL create/destroy/start/stop 调用计数必须为零；捕获和输出持续运行。
- `runtimeBaseline.nodes` 只在 normal/cold chain application terminal 后更新；
  `runtimeBaseline.effectsEnabled` 只在 callback Active/Bypassed ack 后更新。persistence failed/uncertain 不
  回滚已应用 baseline。
- route recovery、sleep/wake 或 format recovery 发生时，旧 bridge 的 prepare/replace/ack 全部失效；
  transitional 中断一律使用最后 terminal `runtimeBaseline`，不得使用最新 intent 或仅因已写盘就使用
  `saved.effectsEnabled`。新 bridge Start 完成后按实际启动结果重建 applied/baseline。
- bypass Save 成功只更新 baseline nodes，effects 值仍取最后 terminal applied 值。
- 若持久化 intent 与 applied 状态不同，UI 必须显示 transitional/error，而不是绿色 active。
- missing/invalid/mismatched IR 仍按 ADR-0014 节点级旁路并可启用其余链；全局 capacity、OOM、
  generation 或 publication 失败保持整条 Processing bypassed。
- fade-out 超时新增 `.effectsBypassTimedOut` stop reason，Product 终态为 stopped/error、关闭自动恢复并
  进入既有手工 Retry；fresh prepare 或 replace 失败只保持 dry，不重启路线。
- fade-in ack 超时先请求 effects=false；若 fade-out 仍不能在上限内完成，再进入同一 recoverable stop。
- Quit 在 accepted/superseded/cancelled effects operation 释放所有资源并到达 terminal 后继续现有事务。

## 影响面

| 层 | 必须修改的职责 |
|---|---|
| `EAUM1Runtime.h/.cpp` | effects enum/ack、NotReady、dry fast path、bypass-only fresh replace、所有权与 transition 完成 |
| `M1RuntimeLeaseAccess.swift` | 查询/等待 effects state、operation token、fresh replace、bridge generation 与 candidate ownership |
| `M1RetirementMaintenanceCoordinator.swift` | 复用 idle barrier；验证 bypass replace 前没有 retired/pending ownership |
| `M1NativeAudioRouteCoordinator.swift` | 无 HAL 变更的 prepare/replace、RouteResources diagnostics、2 秒等待与失败收敛 |
| `M1ProductAudioControlling` / fakes | fresh activation 与 terminal effects ack 协议、调用顺序记录 |
| `M1ProductController.swift` | Off/On 非对称顺序、runtimeBaseline、最新意图、applied/transition/persistence 状态 |
| `M1ProductSnapshot` / `EqualizerAUM1App.swift` | transitional 投影、Toggle/menu checkmark、状态文本和中英本地化 |
| `verify-m1-realtime.sh` | 新 callback helper 与原子操作进入显式实时审计集合 |
| `m6-runtime-probe.cpp` / M10 probe | active、fade、fully-bypassed 成本与超载逃生测量 |
| Runtime/Product/Route/Retirement tests | 删除热状态合同，覆盖 dry fast path、fresh state、顺序、失败、并发和无路线重建 |
| 文档 | ADR-0008、architecture、PRD、CONTEXT、M2 历史记录和 M10 验收边界 |

不修改 schema v8、节点模型、Copy/Paste、Undo/Redo、IR 格式、DSP 算法、设备选择、菜单结构或
Processing 控件位置。

## 自动化与性能门禁

- 10 ms fade-out/fade-in frame 数和反向请求连续性保持精确；
- fully bypassed 对有限输入逐位透明，非有限输入仍按现有规则清零；
- bypass 后 biquad/convolution state 不推进，re-enable 只使用 fresh Prepared；
- dense 384,001-tap、1/2/4/8 channel callback 在 fully bypassed 后接近 dry baseline，成本不得随 taps
  或 stage 数增长；
- dense 9 秒 IR overload 时 Off 在 2 秒候选上限内恢复 dry，且不调用 Start/Stop/HAL；
- bypass Save 直接采用 fresh slot，不执行双链；Active Save 继续双链；
- re-enable 严格为 prepare → replace → enable → ack，外部 IR activation reload 可观察；
- prepare、replace、fade、persistence、route generation、sleep/recovery、rapid intent 和 Quit 均有失败测试；
- 完整 hostless suite、realtime audit、isolation、localization、C++ strict compile 与 Release probe 通过。

## 用户验收

- dense 9 秒 IR 导致 overload 后，关闭 Processing 必须在有限时间恢复干净 dry；
- 旁路期间系统音频连续，Tap/Aggregate/Audio Unit 不重建，macOS 路线无可见变化；
- 重新开启时先保持 dry，准备完成后平滑淡入，无旧尾音、爆音、持续静音或恢复循环；
- bypass 中 Save、外部 IR 原地替换、采样率 mismatch、正常 Quit 均符合现有可见状态与事务语义。

## 拒绝的方案

- 旁路继续执行 wet chain：无法从超载中逃生，已被真实音频复验否决。
- 冻结并恢复旧 DSP state：缺失旁路期间输入，数学状态不连续。
- Off 时停止或重建 Core Audio 路线：产生系统可见切换，违背用户拓扑。
- callback 内重置、构建或释放长 FIR：引入无界工作、分配或所有权竞争。
- 恢复固定 IR 长度上限：回避旁路缺陷，违背 ADR-0017 与用户选择。

## 批准记录

用户于 2026-07-31 明确回复“同意 ADR-0018，按此实现”，批准 fresh 冷状态恢复和 2 秒异常超时后
recoverable stop。本 ADR 自此为 Accepted，M10 按 Runtime → Swift bridge → Product → UI → 验证顺序实施。
