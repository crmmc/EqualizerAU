# ADR 0013：任意点 Graphic EQ 与 minimum-phase FIR

- 状态：Accepted
- 日期：2026-07-24
- 范围：Graphic EQ 产品模型、schema 迁移、曲线、DSP、Runtime 表达与容量
- 产品需求：[`prd.md`](../prd.md)
- 前置决策：[`0008-fixed-band-biquad-graphic-equalizer.md`](0008-fixed-band-biquad-graphic-equalizer.md)、[`0009-immutable-ir-and-hybrid-convolution.md`](0009-immutable-ir-and-hybrid-convolution.md)

## 背景

M4 人工验收否决了固定 15 段产品模型。M6 要求用户以任意频率控制点定义 Graphic EQ，图形、
数值、保存配置和实际频响服从同一契约。ADR 0008 的 15 个 constant-Q peaking biquad 不能表达
EqualizerAPO 的任意点曲线；ADR 0009 已实现零算法延迟的 hybrid convolution，因此 ADR 0008
记录的 FIR 重新评估条件现已满足。

本地 EqualizerAPO 源码的实际路径为：

- `GraphicEQFilterFactory.cpp` 提取频率/gain 数对并按频率排序；
- `GainIterator.cpp` 在点间按对数频率轴对 dB 做线性插值，首点之前和末点之后保持端点 gain；
- `GraphicEQFilter.cpp` 在 32,768 点频率网格上生成 16,384-tap minimum-phase FIR，并用
  partitioned convolution 执行；
- EqualizerAPO 编辑器采用左侧 15/31/variable 模式、中间频响图、右侧 Frequency/Gain 表格和
  Import、Export、Invert、Normalize、Reset 工具；参考频响图同时支持点拖动和双击新增。

参考实现没有验证非正频率、重复频率、非有限值、点数量或正 gain 上界；这些输入会进入
`log(0)`、零宽插值或 FFT 非有限传播。M6 采用参考曲线语义，不复制这些未定义行为。

## 候选决策

### 1. 单一数据模型与 schema v7

Graphic EQ 只有一个可写产品模型：按频率严格升序的 `points` 数组；每点只持久化
`frequencyHz` 与 `gainDB`，不同时保留固定 `bands` 模型。

- 点数量：`0...512`；空数组表示 flat `0 dB`；
- 频率：正有限值，不设产品输入上限；相邻点频率必须严格递增，重复频率整单拒绝；
- gain：有限值，`-24...+24 dB`；模型和直接输入不做隐式量化；
- 点身份只属于一次编辑器会话，用本地临时 UUID 保持表格选择穿越重排；点 UUID 不写入配置，
  不成为 DSP 或复制粘贴语义的一部分；
- 直接数值输入保留用户提供的合法有限值；
- 结构、范围、顺序或容量错误拒绝整个候选，不排序、合并、夹取或丢弃用户点。

512 点上限约束编辑、编码和曲线采样工作，不改变 FIR 回调成本。配置、typed clipboard 与
Undo/Redo 继续受既有 `4 MiB`、`4 MiB` 和 `30 records / 64 MiB` 预算约束。

### 2. 曲线语义

令保存点中过滤出的 `20...20000 Hz` 域内严格升序控制点为 `(f_i, g_i)`：

- 无点时 `G(f) = 0 dB`；
- `f <= f_0` 时 `G(f) = g_0`；
- `f >= f_last` 时 `G(f) = g_last`；
- 两点之间令 `t = (ln(f) - ln(f_i)) / (ln(f_{i+1}) - ln(f_i))`，
  `G(f) = g_i + t * (g_{i+1} - g_i)`。

控制点使用绝对 Hz，输出采样率变化不移动、删除或重写点。主动 DSP 目标域固定为
`20...20000 Hz`：只有域内至少存在一个控制点时才生成 Graphic EQ FIR；域外点原样持久化、编辑
和导出，但不参与域内插值、边界值或 FIR 设计。目标域之外设为 `0 dB`，不构造 band-pass 或硬切
输出；有限 FIR 在边界外产生的自然过渡保留。Nyquist 以上点仍持久化和导出。

编辑器的主曲线显示上述目标响应。当前输出和已编译 FIR 可用时，同时显示实测/编译响应；
两者超过数值容差时显示节点归属的分辨率诊断，不把有限 FIR 的偏差隐藏成用户曲线。

### 3. 旧配置、剪贴板与历史迁移

配置与 typed clipboard 同步升级到 schema v7：

- schema v3、v4、v5 的固定 15 个 `bands` 按原顺序逐点迁移为 `points`；
- 保留节点 UUID、顺序、`isEnabled`、Channels 作用域及每个频率/gain，不把全零旧节点折叠为空；
- 旧版本仍按各自契约严格验证后迁移，不能用 v7 规则宽松解释损坏 payload；
- schema v6 允许的 `20...30000 Hz` 点严格验证后原样迁移，不删除、夹取或投影；
- schema v7 接受所有正有限频率的 `points`，拒绝 `bands`、未知字段、重复 key 和跨类型字段；
- 正常读取只在内存中迁移；显式 Save 或既有 recovery 重建路径写出唯一规范的 schema v7。

### 4. FIR 生成

启用且非 flat 的 Graphic EQ 在 detached 控制路径针对真实输出采样率生成 16,384 taps：

1. 先排除 `20...20000 Hz` 之外的保存点，再在 32,768 点频率网格上对域内点设置主动目标；
   域外 magnitude 为 `0 dB`；
2. magnitude 在取自然对数前以 `-100 dB` 为数值下限；
3. 通过 real-cepstrum minimum-phase 变换生成复频谱；
4. IFFT 后保留前 16,384 taps，并应用 `0.5 * (1 + cos(2πi / 32768))` 单边 taper；
5. 转为 Float32；subnormal 归零；任一非有限值或非法 tap 整单拒绝。

空点、没有域内点、主动目标全部为 `0 dB` 或停用节点不生成 stage，继续保证逐位透明。FIR 生成、FFT setup、
taps 验证和 Prepared 创建不得进入实时回调。

### 5. Runtime ABI 与容量

不新增 ABI v4。每个 Graphic EQ FIR 降低为现有 ABI v3 convolution descriptor，并按当前
Channels 作用域为每个实际声道追加一个有序 convolution stage。Graphic EQ 与 WAV Convolution
共享同一实时预算：

- 最多 8 个 convolution 声道实例；
- 所有实例 taps 合计最多 131,072；
- 单 kernel 继续受 384,000 taps 上限约束；
- 前 256 taps direct FIR，tail 使用 256-frame partition / 512-point FFT；算法延迟为 0 frames；
- 运行中替换继续使用完整新 Prepared、10 ms 双槽 crossfade、latest-pending 合并和退休维护。

超限在 Save 的 prepare 阶段拒绝整个候选，旧 saved configuration 与 active chain 不变；不删除
部分 EQ、不缩短 FIR，也不把 FIR 回退为 biquad。无活动输出时可保存结构合法配置；之后在真实
布局上 prepare 仍须通过同一容量检查才能应用。

### 6. 编辑器范围

M6 最终编辑器以 EqualizerAPO 的界面和操作习惯为迁移基线，并接受 2026-07-25 用户纠正：

- 编辑器只暴露唯一的任意点模型，不提供 15/31 固定模式或自动重采样；
- 中间频响曲线严格只读，只显示 target 与 compiled FIR，不承载选择、新增、删除或拖动；
- 右侧 Frequency/Gain 表格是唯一直接编辑面；独立 Select 列负责选择，两个数值输入框始终显示
  边框，明确区分“选择参数点”和“修改参数”；
- 工具栏提供 Import、Export、Invert、Normalize 与 Reset selected/all；CSV 导入保留
  EqualizerAPO 的数字对、多文件合并和 `*` 行跳过习惯，但结果仍须整体通过本 ADR 的范围、
  唯一性与点数限制；
- 表格支持多选、Command-A、Delete 和方向键微调；
- 本地编辑状态，关闭编辑器时一次完整校验与一个 Undo history step。

曲线只读是对参考实现的有意产品约束，优先级高于 EqualizerAPO 原本的图形拖点和双击新增；除此
之外不得以模糊的点击区域混合选择与数值编辑。

## 数值与性能验收候选

- 曲线 evaluator 对空集、常量端点、对数中点和采样率无关性使用 `1e-12 dB` Double 容差；
- schema/clipboard 对 0、1、512 点及所有边界执行严格 round-trip 和拒绝测试；
- flat 节点不生成 stage，Runtime 保留所有 Float32 bit pattern；
- 44.1、48、96、192 kHz 的 broad-slope 代表曲线，在 `40 Hz...min(18 kHz, 0.45*sampleRate)`
  内域对目标响应最大误差不超过 `0.75 dB`，99th percentile 不超过 `0.1 dB`；20...40 Hz 与
  18...20 kHz 为目标从/向域外 `0 dB` 过渡的边界区，UI 仍显示真实 compiled 响应；
- 更密集或更陡的合法曲线不被静默改写；编译响应与目标响应偏差超过上述容差时必须产生可见
  分辨率诊断，并由 UI 同时呈现目标与编译响应；
- 参考 arm64 Release、48 kHz、256-frame、16,384 taps 的 5 次 ABI v3 重放中，稳定态中位数为：
  1 instance `2.041%`、2 instances `4.071%`、4 instances `8.705%`、8 instances `18.183%`
  实时时长；8-instance 范围 `16.574...19.308%`。10 ms 双链切换按相同工作上界不超过稳定态
  两倍；正式实现后必须把该重放固化为默认跳过的性能夹具，并重新测量生成、prepare 与回调。

## 理由

| 关注点 | 候选方案 |
|---|---|
| 产品语义 | 直接表达 EqualizerAPO 风格的任意点目标，而不是把点误解释为 peaking filter 参数 |
| 兼容性 | 旧 15 段和 schema v6 的 30 kHz 点原样保留；20 Hz...20 kHz 仅约束主动 DSP 目标 |
| 可见正确性 | 目标与编译响应可同时检查，有限 FIR 分辨率不足不会被隐藏 |
| 实时安全 | 复用已验证 ABI v3 hybrid convolution 和完整 Prepared 发布，不增加回调构图 |
| 容量 | EQ 与 IR 使用同一真实资源预算，超限整单失败，无双重统计或静默降级 |
| 延迟 | minimum-phase FIR 与 direct head 保持 0-frame 算法延迟，不破坏 dry/wet 对齐 |

## 不采用的方案

| 方案 | 原因 |
|---|---|
| 每个任意点生成一个 constant-Q biquad | 点是目标曲线锚点，不包含 Q；结果不等于对数插值目标，点数还直接扩大回调 stage 数 |
| 在回调中更新 FIR 或 FFT | 包含无界计算、plan/state 构建与分配，违反实时契约 |
| 为 Graphic EQ 新增独立 FIR ABI v4 | ABI v3 已能表达同一有序、零延迟 convolution，新增类型只会复制状态机和容量逻辑 |
| 自动合并密集点或缩短 FIR | 静默改变用户曲线，违反 PRD 和 M6 非目标 |
| 同时保留 fixed bands 与 arbitrary points | 形成两个可写事实来源，使迁移、clipboard、Undo 和 DSP 语义分叉 |
| 直接采用 EqualizerAPO 的无边界 parser | 非正/重复频率和非有限值会进入未定义插值与 FFT；点数和正 gain 无上界 |

## 与既有 ADR 的关系

本 ADR 获批并实现后：

- 取代 ADR 0008 的固定 15 段产品模型和 Graphic EQ biquad 编译决策；
- 保留 ADR 0008 的控制线程编译、flat 透明、完整 Prepared 与 10 ms 切换原则；
- 直接复用 ADR 0009 的 ABI v3 convolution、零算法延迟、资源上界和失败语义；
- ADR 0008 保留为 schema v3-v5 与 M2 历史实现依据，不删除或改写历史记录。

## 批准记录

2026-07-24，用户批准本 ADR 的完整候选契约：`20...30000 Hz`、`±24 dB`、最多 512 点、
16,384 taps、共享 ABI v3 convolution 容量，以及目标/编译双曲线与
`0.75 dB max / 0.1 dB p99` 代表曲线容差。实现必须按模型/schema → FIR Builder/Runtime →
最终编辑器的顺序推进；自动化证据不能替代用户执行的原生 GUI 与真实音频验收。

2026-07-25，用户对编辑器范围作出重大纠正：必须以 EqualizerAPO 操作习惯为迁移基线，且频响
曲线必须仅用于预览。该纠正取代原先的图形拖动/双击新增范围，并将表格编辑以及
Import/Export/Invert/Normalize/Reset 纳入本阶段验收；DSP、schema、容量和数值契约不变。

2026-07-25，用户在原生 GUI 验证后进一步删除 15/31 固定模式，只保留任意点编辑，并要求用独立
Select 列和有边框的 Frequency/Gain 输入框明确区分选择与修改。该决定只删除新编辑器中的模式
切换；schema v3-v5 固定 15 段数据仍须按既定迁移契约读取。

2026-07-26，用户明确 `20...20000 Hz` 只是主动 DSP 目标域，不是配置输入或保存范围；schema v7
接受并原样保留所有正有限频率点，schema v6 不投影，有限 FIR 的自然域外影响不做输出硬切。

2026-07-27，用户通过 GUI 发现添加 `30 kHz / -6 dB` 会改变可听域曲线，并进一步明确纠正：域外点的
“保留”不代表参与处理设计。实现改为只用 20 Hz...20 kHz 内的点插值和生成 FIR；域外点不改变
目标曲线、compiled 曲线或 taps。有限 FIR 自身在边界外的自然响应仍保留，不做输出硬切。
