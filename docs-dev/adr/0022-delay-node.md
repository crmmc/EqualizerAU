# ADR-0022：Delay 延迟节点

- 状态：Accepted
- 日期：2026-10-14
- 范围：处理链节点模型、配置 schema v10、Runtime 延迟阶段与 ABI v4
- 关联：ADR-0003、ADR-0004、ADR-0007、ADR-0008、ADR-0021
- 用户已确认范围：与响度校正同批交付（2026-10-14）；整数 + 分数两级延迟，优于参考实现的
  整数舍入；`Delay:` 粘贴行解析不在本期

## 背景

EqualizerAPO 的 `Delay` 指令为单值延迟（`Delay: <数值> ms|samples`，小数可用、单位不区分
大小写），受前置 Channel 作用域约束；参考实现把毫秒值四舍五入到整数采样（`DelayFilter.cpp`），
无分数延迟。声道对齐（低音炮距离补偿、左右校准）是该滤镜的主要用途。

本项目 Runtime（ABI v3）只有 Gain/Biquad/Convolution 三种阶段，没有延迟路径；新增延迟需要
新的实时阶段类型与描述符版本。所有既有节点契约（启用/停用、通道作用域、Undo/Redo、显式
Save、4 MiB 预算）不变。

## 决策

1. **节点模型**：新增 `delay` 节点，负载为 `M1DelaySpecification`（数值 + 单位 ms/samples）。
   单节点单延迟值，声道差异通过既有 Channels 作用域 + 多节点表达（与参考实现的 Channel
   作用域等价）。
2. **参数域**：延迟 ∈ (0, 1000] ms 等效值。ms 单位上限 1000 ms；samples 单位上限直接桥接
   Runtime 宏 `EAUM1_MAX_DELAY_SAMPLES`（192000 采样，即最高支持采样率 192 kHz 下的
   1000 ms），两级上限给出同一内存预算上界（每延迟线 ≤ 192002 个 float）。默认 10 ms。
3. **Runtime 阶段**：新增阶段种类 `EAUM1PreparedStageDelay`（kind = 4），新增描述符
   `EAUM1PreparedDelay { uint32_t integerDelay; float fraction; }`（fraction ∈ [0, 1)），
   阶段 `b0` 携带描述符索引（与 Convolution 同一模式）。`EAUM1_RUNTIME_ABI_VERSION` 3 → 4，
   新增 `EAUM1PreparedDescriptionV4` 与 `EAUM1PreparedStateCreateV4`（追加 delays 数组），
   既有 V2/V3 入口不变。
4. **实时实现**：每描述符每声道一条预分配环形缓冲（Prepare 时按 1 s 每声道预算上限分配并
   清零，控制线程完成）；回调内只做有界索引读写与线性插值
   `y[n] = fraction·x[n−d−1] + (1−fraction)·x[n−d]`，无分配、无锁、无动态结构。
5. **编译与诊断**：启用的 delay 节点按作用域展开为每声道一个延迟阶段；超预算或采样率
   折算非法的节点不产生阶段，产生归属该节点的旁路诊断（对齐 ADR-0008 决策 2 语义）。
   极小值折算后因浮点下溢坍缩为 (0, 0) 的描述符（仅手改配置可达，UI 下限 0.01）不产生
   阶段也不产生诊断——静默旁路，避免整个 prepare 失败。
6. **schema v10**：配置与剪贴板 envelope 同步升版（与响度校正节点共用本次升版）；v9 及更早
   配置无损加载；`delay` 负载在 v10 前的文档中显式拒绝。
7. **有意偏差**（相对参考实现）：参考实现整数采样舍入，本实现整数 + 分数线性插值两级；参考
   实现无延迟上限（受内存约束），本实现显式 1000 ms 预算。

## 后果

- 用户可创建/编辑/持久化延迟节点，按既有节点契约参与通道作用域、Undo/Redo、复制粘贴与
  显式 Save；声道对齐精度达到分数采样级。
- Runtime ABI 升 v4，两侧测试按 spec 规则同步更新；既有 V2/V3 调用方不受影响。
- `Delay:` 文本粘贴行解析留给配置导入需求卡（APO-01+），本期不做。
