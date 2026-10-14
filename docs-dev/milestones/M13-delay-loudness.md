# M13 延迟与响度校正节点

- 状态：实现完成，全部门禁通过；**用户真实音频验收待完成**
- 决策：[`ADR-0022`](../adr/0022-delay-node.md)（延迟）、[`ADR-0023`](../adr/0023-loudness-correction-node.md)（响度校正）
- 产品需求：[`prd.md`](../prd.md) §7.8、§7.9
- 任务：`.trellis/tasks/10-14-m13-delay-loudness/`

## 交付范围

- **Delay 节点**：数值 + 单位（ms/samples），整数 + 分数（线性插值）两级延迟；参数域
  (0, 1000] ms 等效；Runtime 新增 `EAUM1PreparedStageDelay` 阶段与 `EAUM1PreparedDescriptionV4`，
  ABI 3 → 4；每描述符每声道预分配环形缓冲，回调内仅有界读写与插值。
- **响度校正节点**：ISO 226:2003 等响曲线差（Suzuki–Takeshima 2004 拟合）→ 复用 GraphicEQ
  最小相位 FIR 编译管线（目标增益函数化改造，ADR-0020 长度合同不变）；参数 = 参考音量
  （输出音量旋钮域）+ 强度（0…1）；曲线峰值防削波下移；参考音量处平坦无阶段。
- **音量观察与自动重发布**：控制层 AudioObject 监听输出设备音量（标量→分贝），1 dB 量化 +
  300 ms 防抖；变化后从已保存配置重建预编译链并走既有 publish（10 ms 交叉淡化 + 候选合并）；
  草稿、Undo、generation、持久化全部不变。
- **schema v10**：配置与剪贴板 envelope 同步升版；v9 及更早无损加载；`delay`/`loudness`
  负载在 v10 前显式拒绝。
- **UI**：两个新节点的添加入口、行内参数编辑（延迟值/单位；参考音量/强度）、中英文本地化。
- 不在本期：`Delay:` 粘贴行解析、响应曲线渲染（APO-13）、信号驱动式自适应、绝对声压级
  校准、ISO 226:2023 数据替换。

## 有意偏差（相对 EqualizerAPO 参考实现）

| 行为 | 参考实现 | 本项目 |
|---|---|---|
| 延迟精度 | 整数采样舍入 | 整数 + 分数线性插值 |
| 延迟上限 | 无显式上限 | 1000 ms 显式预算 |
| 响度曲线 | 两搁架 + 手调系数近似 | ISO 226 等响曲线差精确编译 |
| 换参数机制 | 音频线程临界区换系数 | 后台重编译 + 原子发布（10 ms 交叉淡化） |
| 防削波 | 防护性 preamp | 曲线整体下移最大正增益（等价） |
| 音量语义 | Windows 主音量 dB | 输出设备标量→分贝换算（不支持时近似并可见） |

## 自动化证据（2026-10-14，本地 arm64）

- `make check` 通过：project/Plist lint、shell 语法、M1 隔离审计（新增 3 个源文件登记：
  M1EqualLoudnessCurve.swift、M1OutputVolumeObserver.swift、EAUM1DelayStage.hpp 与测试文件）、
  实时安全审计（新增延迟回调路径无分配无锁）、本地化一致性（新增 9 键均含 zh-Hans，
  动态 Text 基线登记 delayUnitLabel）。
- `make coverage` 通过：`EqualizerAUM1RuntimeTests` 520+ 用例 0 失败，核心生产逻辑覆盖率
  ≥95%（门禁），`EAUM1Runtime.cpp` 单文件 95.10% ≥95% 红线，10/10 主功能路径通过。
- 新增测试：`EAUM1RuntimeSmokeTests` 7 例（V4 校验矩阵、整数/分数脉冲、跨块历史、
  等价/差异发布语义、增益-双二阶-卷积-延迟混合链）、`M1EqualLoudnessCurveTests` 8 例
  （1 kHz 归一、公开锚点对照、±对称、夹紧下移、强度缩放、支撑域端点保持）、
  `M1ProcessingBuilderTests` 8 例（ms/samples 折算、极端采样率旁路、超预算抛错、
  响度 FIR 随音量变化、参考音量/零强度无阶段、工厂 V4 接线）、
  `M1FilterEditingTests` 8 例（增删改 + Undo + envelope v10 round-trip + v9 拒绝 +
  归一化 + 规格助手）、`M1ProductControllerTests` 6 例（同代次重发布、草稿/提交不变、
  无响度节点不重建、量化去重、停止态记忆、失败吞掉重试）。
- 既有测试同步：schema 版本预期 9 → 10、不支持 schema 10 → 11、ABI 版本 3 → 4。

## 待完成

- 用户真实音频验收：在真实输出设备上（1）用延迟节点对齐左右声道/低音炮并确认消除梳状滤波；
  （2）调低系统音量确认低频补偿自动跟随、调回参考音量确认补偿归零、快速拖动音量确认无爆音
  （沿用"交互式音频结论只来自用户实际执行并报告的证据"约定）。
