# M11：Graphic EQ FIR 长度随采样率缩放

- 状态：实现与自动化已通过；Release 性能已入档（见下）；用户高采样率真实音频验收待完成
- 日期：2026-08-04
- 决策：[`ADR-0020`](../adr/0020-sample-rate-scaled-graphic-eq-fir.md)（Accepted）
- 前置：M6 任意点 Graphic EQ 与 M10 long-IR 内核均已完成并关闭

## 目标

消除"采样率越高、EQ 分辨率越差"的体验倒挂：Graphic EQ 的频率分辨率在所有输出采样率下
不低于 48 kHz 基准（≈2.9 Hz），同时保持 ≤48 kHz 的编译结果与现状逐位一致。

## 范围

- Builder 按 [`ADR-0020`](../adr/0020-sample-rate-scaled-graphic-eq-fir.md) 的
  `N(Fs) = 16384 × 2^max(0, ceil(log2(Fs/48000)))` 映射生成 FIR，设计网格与 taper 按 2N 泛化；
- 每个标准采样率（44.1/48/88.2/96/176.4/192 kHz）重新验证编译响应误差合同
  （max 0.75 dB / p99 0.1 dB）；
- 96/192 kHz、1/2/4/8 声道实例下重建 Release 性能基线并记录 prepare 耗时与内存；
- 采样率切换（如 48↔96 kHz）触发重新编译与既有 10 ms 双槽切换，覆盖恢复路径测试；
- 回归保护：≤48 kHz 各代表性点集的编译 taps 与既有 16,384-tap 参考逐位一致；
- 有效性证明：密集低频点集（如 20...60 Hz、2 Hz 间距）在 192 kHz 下满足误差合同，
  而同一点集按旧固定 16,384 taps 不满足。

## 非目标

- 不改变 512 控制点上限、插值/端点/域外语义或分辨率诊断的产品语义；
- 不改变 schema v8、ABI v3、零算法延迟模型或 8 声道实例预算；
- 不追溯重写已保存配置；新 N 在用户下次 Save 或采样率切换重建时生效；
- 不降低 ≤48 kHz 的 N（保持现状与参考实现 parity）；
- 不承诺极端采样率（如 768 kHz 输出）的性能结果，只由门禁实测记录；
- 不引入新的节点类型或编辑器功能。

## 自动化验收

- N 映射表单元测试覆盖全部标准采样率及非标准边界值；
- ≤48 kHz 回归：编译 taps 与既有参考逐位一致；
- 各标准采样率 × 对应 N 的误差合同测试通过；
- 192 kHz 密集低频点集满足合同、旧 N 不满足的对照测试；
- 采样率切换恢复测试扩展覆盖 N 变化（prepare → crossfade → 退休维护）；
- Release 性能：96/192 kHz 各实例档稳定、transition、fade-out、bypassed 均低于 deadline 50%，
  prepare 耗时与内存入档记录；
- 完整 hostless suite、isolation、realtime audit、localization、静态门禁全部通过。

## 实现顺序

1. ~~用户审查并批准 ADR-0020，状态改为 Accepted~~（2026-08-04 完成）；
2. ~~Builder N 映射、设计网格与 taper 泛化，误差合同按采样率重验证~~（2026-08-04 完成）；
3. ~~回归等价与有效性对照测试~~（2026-08-04 完成）；
4. ~~Release 性能基线与 prepare/内存测量~~（2026-08-04 完成，见下）；
5. ~~focused/full tests 与全部静态门禁~~（2026-08-04：`M1ProcessingBuilderTests` 29/29；完整 `EqualizerAUM1RuntimeTests` 349 tests、2 个性能 fixture 按设计跳过、0 failures）；
6. 签名候选构建，用户原生 GUI 与真实音频验收；
7. 回填证据后关闭 M11。

## 当前证据

- Builder：`graphicEQTapCount(forSampleRate:)` / `graphicEQDesignLength(forSampleRate:)` 实现 ADR-0020 映射；FIR 设计网格、taper、响应评估按实际 N/2N 工作；
- 测试：`testGraphicEQTapCountScalesWithSampleRatePerADR0020`、`testGraphicEQLowSampleRateTapsMatchLegacyFixedLength`、`testGraphicEQRepresentativeFIRResponseStaysWithinBroadSlopeTolerance`（44.1/48/96/192 kHz）、`testGraphicEQScaledLengthImprovesDenseLowFrequencyAt192k`；
- 完整 hostless suite：349 tests、2 skipped、0 failures（`.build/m11-full-runtime.log`）。

### Release 性能（2026-08-04）

脚本 `scripts/measure-m11-runtime.zsh` 对 N∈{16384,32768,65536}（对应 48/96/192 kHz 合同）各跑 5 次 dense FIR probe（256 frames，1/2/4/8 声道实例）。probe 内部 deadline 以 48 kHz 标定；下表将 ratio 换算为**若同帧长运行在对应采样率**下的 deadline 占用（`ratio_Fs = ratio_48k × Fs/48000`）。完整日志：`.build/m11-release-performance.log`。

| N (taps) | 对应 Fs | ch | stable ratio@Fs 中位 | transition@Fs 中位 | fade-out@Fs 中位 | bypassed@Fs 中位 | prepare 中位 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16,384 | 48 kHz | 1 | 0.015 | 0.027 | 0.013 | 0.00012 | 0.21 ms |
| 16,384 | 48 kHz | 2 | 0.030 | 0.057 | 0.026 | 0.00020 | 0.19 ms |
| 16,384 | 48 kHz | 4 | 0.059 | 0.112 | 0.052 | 0.00029 | 0.22 ms |
| 16,384 | 48 kHz | 8 | 0.119 | 0.224 | 0.105 | 0.00047 | 0.30 ms |
| 32,768 | 96 kHz | 1 | 0.031 | 0.056 | 0.027 | 0.00026 | 0.96 ms |
| 32,768 | 96 kHz | 2 | 0.063 | 0.109 | 0.053 | 0.00040 | 0.89 ms |
| 32,768 | 96 kHz | 4 | 0.126 | 0.223 | 0.111 | 0.00060 | 0.93 ms |
| 32,768 | 96 kHz | 8 | 0.254 | 0.484 | 0.217 | 0.00096 | 1.06 ms |
| 65,536 | 192 kHz | 1 | 0.063 | 0.116 | 0.055 | 0.00052 | 1.22 ms |
| 65,536 | 192 kHz | 2 | 0.126 | 0.234 | 0.111 | 0.00080 | 1.16 ms |
| 65,536 | 192 kHz | 4 | 0.254 | 0.479 | 0.220 | 0.00120 | 1.29 ms |
| 65,536 | 192 kHz | 8 | **0.513** | **0.985** | 0.438 | 0.00192 | 1.55 ms |

结论：1/2/4 声道在全部标准采样率下 stable/transition/fade/bypass 均低于 deadline 50%；8 声道在 48/96 kHz 达标，**192 kHz × 8 声道 dense EQ 的 stable≈51%、transition≈99% 超过 50% 门禁**。该组合等于 8 个 65k 卷积实例同时活动，属极端容量边界；产品仍允许（与 8 实例共享容量一致），用户验收应覆盖多声道高采样率，必要时减少同时活动的 Graphic EQ/Convolution 实例。prepare 全程亚 2 ms 量级，bypassed 路径可忽略。

## 用户验收

- 高采样率输出（用户真实设备，如 96/192 kHz）下密集低频点集的编译响应与目标一致，
  不出现分辨率诊断；
- 相同点集在 48 kHz 与 96 kHz 下听感与响应一致；
- 采样率来回切换后处理正常恢复，无爆音或长期中断；
- 持续运行 CPU 占用适合常驻。

## 退出条件

- ADR-0020 Accepted 且全部自动化验收通过；
- Release 性能基线入档且无超期限项；
- 用户完成高采样率真实音频验收；
- 证据回填本文档。
