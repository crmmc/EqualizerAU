# M6：任意频率 Graphic EQ

> **当前状态**：已完成并关闭；schema v7、minimum-phase FIR、任意点编辑器、自动化、性能、签名、原生 GUI 与真实音频验收全部通过
> **前置条件**：M5 通用处理器容器与交互契约已完成

## 1. 目标

M6 用 EqualizerAPO 风格的任意频率控制点 Graphic EQ 取代 M2 固定 15 段产品模型。用户能够
新增和删除控制点，并编辑每个点的频率和 gain；可见曲线、保存配置和实际音频响应必须遵循
同一份已验证契约。

## 2. 阶段输入

- M4 人工验收明确否决固定 15 段模型，原 T06-T09 在新模型完成前不具备验收意义；
- [`ADR 0008`](../adr/0008-fixed-band-biquad-graphic-equalizer.md) 已记录“产品要求
  逐点匹配 EqualizerAPO”与“具备成熟分区卷积”两个重新评估条件；
- M3 已提供有界、预分配的 hybrid convolution 基础，但是否以及如何用于新 Graphic EQ
  必须在本阶段重新论证，不能直接视为既定实现；
- M5 提供通用处理器容器、选择和编排交互。

## 3. 探索与决策门禁

本阶段尚未确定最终数据模型、滤波器算法、Runtime 表达或完整编辑工具。实施前必须：

1. 阅读本地 EqualizerAPO 的 Graphic EQ parser、filter、curve/DSP 和 editor 源码；
2. 固化控制点排序、端点、插值、重复频率、数值范围和采样率变化语义；
3. 比较目标频响、延迟、CPU、内存、切换行为及多个 EQ/Convolution 共存容量；
4. 确定旧 schema 和 typed clipboard 的确定性迁移；
5. 新增 ADR 记录最终 DSP、Runtime ABI 和容量决策，并明确其与 ADR 0008 的关系；
6. 在数值和实时契约获批前，不开始 Runtime 或最终 Graphic EQ 界面实现。

探索结果回填本文件及对应 ADR，不另建同阶段 spec。最终候选见
[`ADR 0013`](../adr/0013-arbitrary-point-minimum-phase-graphic-equalizer.md)；该 ADR 已于
2026-07-24 获用户批准，实现按 schema/model、FIR Builder/Runtime、最终界面顺序推进。

### 3.1 本地 EqualizerAPO 源码结论

2026-07-24 已完成 parser、filter、curve/DSP 和 editor 的只读追踪：

- `GraphicEQFilterFactory.cpp` 从参数中提取频率/gain 数对、按频率排序，并固定创建
  16,384-tap Graphic EQ；
- `GainIterator.cpp` 在点间按对数频率轴对 dB 线性插值，首点之前和末点之后保持端点 gain，
  空点集为 `0 dB`；
- `GraphicEQFilter.cpp` 在 32,768 点网格生成 minimum-phase 频谱，保留前 16,384 taps 并应用
  单边 cosine taper，然后由 hybrid convolution 逐声道执行；
- `GraphicEQFilterGUI*` 使用同一理想插值器画曲线，支持图表同步选择、双击新增、Delete 删除、
  二维拖动和数值表格直接编辑；15/31 模式、CSV、Invert、Normalize 和 Reset 是附加工具；
- 参考 parser 没有点数、有限值、正频率、重复频率或正 gain 上界。重复或非正频率会进入零宽
  对数插值或 `log(0)`，因此这些行为属于参考缺陷，不进入产品契约。

### 3.2 候选行为契约

| 范围 | ADR 0013 候选 | 理由 |
|---|---|---|
| 模型 | schema v7 单一严格升序 `points`，0...512 点 | 不保留 fixed/arbitrary 两个可写事实来源 |
| 数值 | 正有限频率、不设输入上限；主动 DSP 域 `20...20000 Hz`；gain `-24...+24 dB` | 兼容 EqualizerAPO 配置且不主动 EQ 域外 |
| 插值 | 只使用 20 Hz...20 kHz 域内点，在对数频率轴上对 dB 线性插值 | 域外点保留但不改变处理曲线 |
| 迁移 | schema/clipboard v3-v6 的点原值迁移 | 不移动、折叠或丢弃用户控制点 |
| DSP | 20 Hz...20 kHz 主动目标、域外 0 dB 的 16,384-tap minimum-phase FIR | 不构造硬切输出，保留 FIR 自然边界影响 |
| Runtime | 复用 ABI v3 convolution；不新增 ABI v4 | ADR 0009 已有预分配、零算法延迟 hybrid path |
| 容量 | EQ 与 WAV IR 共享 8 instances / 131,072 taps | 统计真实回调成本，超限整单拒绝 |
| 显示 | 目标曲线与当前采样率编译响应同时可见 | 不隐藏有限 FIR 对极端密集曲线的近似误差 |
| 编辑 | 只读曲线；独立 Select 列；有边框 Frequency/Gain；表格增删改与工具栏 | 用户纠正后的清晰操作边界 |
| 提交 | 弹窗本地编辑，关闭时一次校验和一个 Undo step | 保留 M5 已验收的性能与草稿语义 |

用户于 2026-07-25 明确将 CSV import/export、Invert 和 Normalize 纳入 M6，要求频响曲线仅预览，
并在原生 GUI 验证后删除 15/31 固定模式，只保留任意点表格；该纠正取代原候选中的图形拖动、
双击新增和固定模式自动重采样。

### 3.3 数值与实时探针

探索阶段只使用 `/tmp` 数值/ABI 探针和 `.build/` 产物，未启动 GUI、真实音频或 profiling 工具：

- minimum-phase 数值原型确认 flat 生成单位冲激；broad-slope 曲线在 44.1...192 kHz 的候选
  可听频域容差内；极端相邻跳变会暴露有限 FIR 分辨率误差，因此 ADR 要求目标与编译响应双线
  显示和节点归属诊断，而不是静默平滑；
- arm64 Release、48 kHz、256-frame、16,384 taps 的 ABI v3 稳定态重放 5 次，中位数分别为
  1 instance `2.041%`、2 instances `4.071%`、4 instances `8.705%`、8 instances `18.183%`
  实时时长；8-instance 范围 `16.574...19.308%`；
- 现有 8-instance/131,072-tap 上界在稳定态保留明显余量，10 ms 双槽切换工作上界约翻倍；
  因此候选复用现有容量，不在没有测量依据时扩大回调故障面；
- Debug 探针和首次失败的 Release hosted `build-for-testing` 不作为性能证据；后者因 Release
  模块未启用 `@testable` 被既有 hosted test 配置阻止，随后只构建 Runtime Release target 完成测量。

## 4. 计划范围

- 任意数量范围内的频率/gain 控制点及严格验证；
- 旧固定 15 段配置、剪贴板和历史快照的兼容迁移；
- 按真实输出采样率生成并发布目标 DSP；
- 与 Preamp、Channels、Convolution 的有序组合及固定资源上界；
- 只读频响预览和任意点列表表格编辑；
- 独立 Select 列、有边框 Frequency/Gain，以及表格新增、删除、直接输入和选择；
- 运行中保存、发布、旁路和切换行为；
- 频响、透明性、瞬态、实时预算和编辑性能验证。

## 5. 非目标

- 不扩展为 Parametric EQ、Dynamic EQ、AutoEQ 或任意滤波器设计器；
- 不在本阶段实现完整 EqualizerAPO 配置导入；
- 不因迁移方便而同时保留两个可写 Graphic EQ 产品模型；
- 不在实时回调中生成系数、FFT、滤波器或动态分配存储；
- 不以静默截断控制点或改变用户曲线来规避容量失败。

## 6. 阶段顺序

1. 完成本地参考实现探索和行为契约；已于 2026-07-24 完成候选；
2. 新增 ADR，确定模型、迁移、DSP、ABI 和容量；ADR 0013 已于 2026-07-24 批准；
3. 实现模型与 schema 迁移并完成兼容测试；候选已完成；
4. 实现控制线程编译和 Runtime，并完成数值及 realtime 验证；候选与正式性能重放已完成；
5. 在 M5 容器中实现最终 Graphic EQ 编辑器；已完成并通过原生 GUI 验收；
6. 完成自动化、签名应用和真实音频验收；已完成。

## 7. 退出条件

- 用户可以通过 EqualizerAPO 风格表格可靠新增、删除、选择并直接编辑任意频率控制点，频响图
  保持只读；
- 旧配置确定性迁移，保存后只有一个规范的新模型；
- 可见曲线与目标和实测频响在已定义容差内一致；
- flat 配置透明，参数变化和 Save 不产生明显爆音、卡顿或长期中断；
- 多个 Graphic EQ 与 Convolution 共存时容量和失败行为明确，不静默降级；
- 实时回调继续满足预分配、无锁、无 I/O 和有界工作约束；
- T06-T09 由针对新模型的自动化、GUI 和真实音频验收替代并通过。

## 8. 当前未决边界

- ADR 0013 最新修订已批准：正有限频率点原样保存，`20...20000 Hz` 仅为主动 DSP 域；
  `±24 dB`、最多 512 点和 16,384 taps 不变；
- Runtime ABI v3 与 WAV Convolution 共享 8 instances / 131,072 taps 的契约已批准；
- 目标曲线与编译响应双线呈现及 `0.75 dB max / 0.1 dB p99` 代表曲线容差已批准；
- 性能阈值已有 Release 重放基线，正式实现后必须固化可重复夹具并重新测量；
- schema/model、FIR Builder/Runtime 与最终编辑器按阶段顺序实现，不能以后一阶段绕过前一阶段验证。

## 9. 候选实现与自动化证据

- 当前唯一模型为 schema v7 `points`；配置与 typed clipboard v3-v5 的旧 15 `bands` 先按独立
  legacy 频率/gain 契约严格验证，再逐点迁移；schema v6 的 20...30 kHz 点集原样保留并
  canonical 写出 v7。合法 v3-v6 配置、clipboard、Paste、Undo/Redo、
  0/1/512 点边界和错误 shape 均有 hostless 覆盖；
- Builder 使用 Accelerate 在 detached 控制路径生成 32,768 design / 16,384-tap minimum-phase
  FIR，应用完整单边 cosine taper，subnormal 归零；empty、没有域内点或主动目标全零时不生成
  stage。44.1/48/96/192 kHz 的 40 Hz...18 kHz broad-slope 响应、域外点不改变目标或 taps、
  FIR 自然边界过渡、Nyquist 以上点保留、密集点分辨率诊断和 ABI v3
  Prepared 均有数值测试；
- Graphic EQ 与 WAV IR 共享 8 convolution instances / 131,072 taps；1 个 EQ 在 8 声道恰好
  用满实例预算，9 声道和 EQ/IR 混合超限整单失败；
- 最终编辑器候选只保留任意点模型，中间为只读 target/compiled 双曲线，右侧表格用独立 Select
  列和有边框 Frequency/Gain 输入框分开选择与修改，并提供 Import/Export/Invert/Normalize/Reset
  工具栏。Command 多选、Command-A、Delete 和方向键保留；编辑留在本地，关闭弹窗一次提交；
- preview 只持有一个可取消 detached task，Builder 在节点、magnitude、FFT、taper/tap 和响应阶段
  协作检查取消；启动路线复用第一次 detached 编译的 diagnostics，不在 ProductController actor
  上重复生成 FIR；
- 完整 `EqualizerAUM1RuntimeTests` 304 项中 2 个性能夹具默认跳过，其余 302 项零失败。首次完整
  失败确认是新增 mock fallback Builder 改变恢复竞态时序，删除不必要 fallback 后该测试单独
  0.007 s 通过，完整重跑通过，未修改测试超时；
- 显式 M6 控制性能夹具（512 points、stereo、20 Hz...20 kHz 主动域）5 次重放中位数：
  FIR build 54 ms、Prepared create 7 ms、preview 53 ms；
- 正式 arm64 Release ABI v3 重放 5 次：8 instances 稳定态中位数约 16.8%、最高 20.3%，
  transition 最高 30.3%；脚本为 `scripts/measure-m6-runtime.zsh`；
- 29-function realtime audit、5-target isolation、project/Plist lint、shell syntax 和 diff whitespace
  检查均通过。自动化阶段未启动 GUI、真实音频或 profiler；对应结论只能由用户在签名候选中
  实际操作后记录。2026-07-25 用户纠正后的 EqualizerAPO 三栏/只读曲线候选已重新通过上述门禁，
  Apple Development arm64 Debug 构建和 strict codesign 验证通过。用户于 2026-07-26 对当时候选完成
  原生 GUI 验收；之后发现并修复复选框取消/删除命中、30 kHz 点改变域内曲线、数值输入中间态
  被立即校验/重排、Command-A 误选外层处理器，以及选择操作视觉不一致问题。最新签名候选已于
  2026-07-27 通过用户原生 GUI 复验和真实音频验收，M6 全部退出条件满足并关闭。
