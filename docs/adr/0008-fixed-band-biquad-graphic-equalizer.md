# ADR 0008：固定频段 Biquad Graphic EQ 与双槽切换

| 属性 | 内容 |
|---|---|
| 状态 | 已接受并实现 |
| 日期 | 2026-07-21 |
| 范围 | Graphic EQ 产品契约、DSP、Runtime ABI 与运行中切换 |
| 产品需求 | [`prd.md`](../prd.md) |
| 处理链基础 | [`0007-channel-scope-and-processing-control.md`](0007-channel-scope-and-processing-control.md) |

## 背景

M1 Runtime 只保存每声道净 Preamp 增益，不能表达有序、有状态的滤波器。M2 还需要在真实
采样率下生成系数、限制实时工作上界，并在运行中更新时保留旧状态直到平滑切换完成。

本地 EqualizerAPO 默认配置提供 15 个中心频率，但其 GraphicEQ 使用 16384-tap minimum-phase
FIR 和分区卷积。当前项目没有分区卷积基础；直接移植会同时引入固定延迟、FFT 状态和更大的
实时故障面，与首版低延迟、固定上界目标冲突。

## 决策

1. 首版固定使用 `25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000,
   6300, 10000, 16000 Hz` 十五个中心频率，增益范围为 `-24...+24 dB`，界面步进为 `0.1 dB`。
2. 每个非零频段编译为 2/3-octave constant-Q RBJ peaking biquad。系数按当前输出采样率在
   控制线程生成、归一化并验证稳定性；等于或高于 Nyquist 的频段不进入 Runtime，并产生归属
   Graphic EQ 节点的诊断。
3. 全部 `0 dB` 的 Graphic EQ 不生成 stage，必须保持逐位透明。停用节点也不生成 stage。
4. Runtime ABI v2 接收按声道分组、声道内保持处理顺序的 Gain/Biquad POD stages。每声道最多
   512 个 stage，单个 Prepared 最多 4096 个 stage；超限必须在发布前失败。
5. Runtime 创建时预分配两个 4096-stage 执行槽及滤波状态。发布在控制线程把候选复制到非活动
   槽；回调以固定 10 ms 同时执行旧链和新链并线性 crossfade，结束后才允许维护线程回收旧
   Prepared。切换期间只保留最新 pending 候选。
6. Processing 旁路使用独立 10 ms dry/wet 混合；旁路期间仍推进 wet chain 和 biquad 状态，
   恢复时从热状态淡入。

## 理由

| 关注点 | 采用方案的收益 |
|---|---|
| 产品连续性 | 中心频率沿用 EqualizerAPO 默认 15 段，参数密度适合首版桌面编辑 |
| 实时上界 | 单回调最多执行两条有界 stage chain，不创建 DSP、扩容、加锁或等待 |
| 低延迟 | Biquad cascade 不引入 FIR 分区长度对应的固定延迟 |
| 稳定切换 | 不插值可能失稳的 biquad 系数；旧、新状态各自连续推进后混合输出 |
| 透明性 | flat 节点在 Builder 消除，不让 unity 运算改变 signed zero 或 subnormal |
| 采样率 | 每次针对真实布局编译，高于 Nyquist 的频段显式降级而非生成无效系数 |

## 备选方案

| 方案 | 不采用原因 |
|---|---|
| 直接移植 EqualizerAPO 16384-tap FIR | 需要先建立分区卷积、延迟和 FFT 实时契约，首版影响面过大 |
| 在回调中重算或插值 biquad 系数 | 增加实时计算且中间系数稳定性难以证明 |
| 切换时清空状态并立即替换 | 容易产生瞬态，无法满足运行中稳定调参 |
| 旁路时冻结滤波状态 | 恢复后的 wet 输出不再对应连续输入历史 |
| 动态 stage 容量 | 用户节点数会直接形成无界回调工作和内存增长 |

## 数值与实时边界

- 单一 peaking stage 的 impulse-response DFT 在中心频率应与目标增益相差不超过 `0.01 dB`；
- biquad 状态必须跨 block 连续且不能跨声道泄漏；
- flat/empty chain 保留原 Float32 bit pattern；非有限输入清零，有限溢出饱和；
- 令 `F` 为帧数、`S` 为所有声道 stage 总数，稳定态工作为 `O(F*S)`，链切换期间上界为
  `O(2*F*S)`；`F`、每声道 stage 数和总 stage 数均由 ABI 固定上限约束；
- 系数生成、验证、Prepared 创建和执行槽复制都在控制线程完成，回调只访问预分配存储。

## 重新评估条件

- 产品要求逐点匹配 EqualizerAPO 的 log-frequency FIR 目标响应；
- CPU 测量表明 15 段双链切换无法满足支持设备的实时预算；
- 引入成熟分区卷积后，FIR 的频响收益足以承担明确的延迟和复杂度。
