# ADR-0021：EqualizerAPO 经典滤波器节点

- 状态：Accepted
- 日期：2026-10-13
- 范围：处理链节点模型、配置 schema v9、Biquad 编译、EqualizerAPO 文本粘贴回退
- 关联：ADR-0003、ADR-0004、ADR-0007、ADR-0008、ADR-0013、ADR-0020
- 用户已确认范围：8 基础类型全做（含搁架变体语义）+ ⌘V 粘贴回退支持 `Filter:` 行；
  滤波器频率域 1 Hz … 20 000 Hz（2026-10-13 批准，比 Graphic EQ 域宽）

## 背景

EqualizerAPO 的经典 `Filter` 指令族（峰值/高低通/带通/搁架/陷波/全通）是参数 EQ 预设
（如 AutoEq 参数输出）的通用载体。本项目节点模型此前只有 preamp/channels/graphicEQ/
convolution 四种，无法表达这类滤波。Runtime 自 M2 起具备通用 `EAUM1PreparedStageBiquad`
处理路径（含 `isStableBiquad` 校验与双槽切换），发布层转换完备，仅 Builder 不产出该阶段——
新增经典滤波器不需要任何实时 DSP 新路径。

参考实现在本地 EqualizerAPO 源码中行为明确：类型别名表、参数必需性与默认值
（`BiQuadFilterFactory.cpp`）、RBJ 系数公式（`BiQuad.cpp`）、搁架转角/中心频率换算
（`BiQuadFilter.cpp`）。按仓库对齐规则直接采用，不另立产品选择题。

## 决策

1. **节点模型**：新增 `filter` 节点，负载为 `M1FilterSpecification`
   （类型 + Fc + 增益 + 宽度 Q/带宽倍频程/搁架斜率 + 搁架频点含义）。单一节点类型承载
   peaking、lowPass、highPass、bandPass、lowShelf、highShelf、notch、allPass 八类；
   创建时把参考默认值显式落盘（低/高/带通 Q 0.707，搁架 10.8 dB/oct 转角语义，陷波 Q 30），
   编译期不再有隐式默认。非增益类型增益恒为 0；非搁架类型转角标志恒为 false。
2. **参数域**：Fc ∈ [1, 20 000] Hz（下限容纳亚低频保护滤波；上限保持可听域）；增益
   ±24 dB 对齐 Graphic EQ；Q ∈ [0.05, 100]；带宽 (0.01, 12] oct；搁架斜率 (0, 12] dB/oct
   （与参考实现 ÷12 归一的 S ≤ 1 等价）。
3. **系数设计在控制线程**：新增 `M1BiquadFilterDesign`，公式逐条对照参考实现，系数按输出
   采样率生成、归一化，并以与 Runtime `isStableBiquad` 相同的条件预校验。Apple Accelerate
   不提供 IIR 滤波器设计 API（vDSP 仅有双二阶应用接口），参考公式即兼容性合同；运行时逐
   样本处理沿用既有 `EAUM1PreparedStageBiquad` 路径，本轮不引入 vDSP_biquadm 重写实时核心
   （Float64 系数合同与缓冲布局不同，如需优化须另立 ADR）。
4. **编译与诊断**：启用的 filter 节点编译为按作用域展开的 `.biquad` 阶段（每通道一个），
   零处理延迟；有效频率 ≥ Nyquist 或系数被拒时该节点不产生阶段，产生归属该节点的旁路诊断
   （对齐 ADR-0008 决策 2 语义）；0 dB peaking 照常编译；停用节点不产生阶段。
5. **schema v9**：配置与剪贴板 envelope 同步升版；v8 及更早配置无损加载；`filter` 负载在
   v9 前的文档中显式拒绝；4 MiB 与既有容量上界不变。
6. **粘贴回退**：文本回退按行解析 `GraphicEQ:` 与 `Filter:` 两种命令（命令名大小写不敏感，
   类型别名归一含 Modal/PEQ/LPQ/HPQ/LSC/HSC/6dB/12dB 变体），保持行序建节点；非法行、
   缺必需参数行、域外行丢弃但在可见报告中计数，不静默；`Filter:` 行数上限 512，超限中止
   整次粘贴；私有 JSON 剪贴板优先级不变；文本框聚焦时 ⌘V 仍为系统文本粘贴。
7. **有意偏差**（相对参考实现，全部记录于任务设计文档）：
   - 不复制静默失败：解析/校验失败显式计数可见；
   - 不复制千位分隔怪癖：`1.000` 按 1.0 解析（歧义风险）；
   - 类型别名匹配大小写不敏感（参考为精确匹配）；
   - 显式参数域（参考无界）。

## 后果

- 用户可以创建/编辑/持久化 8 类经典滤波器并按既有节点契约参与通道作用域、Undo/Redo、
  复制粘贴与显式 Save；AutoEq 参数预设可直接 ⌘V 导入。
- Graphic EQ 的 FIR 路线（ADR-0013/0020）与经典滤波器的 biquad 路线并存互不影响。
- 滤波器节点频响曲线渲染与 response evaluation 集成不在本 ADR 范围，留作独立需求卡。
- `IIR` 原始系数、`Delay`、`Copy`、`LoudnessCorrection`、`VSTPlugin` 与结构指令
  （Device/Stage/Include/If/Eval）仍不支持；`Delay`/`Copy` 建议单独立卡。
