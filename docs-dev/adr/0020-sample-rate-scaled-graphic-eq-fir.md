# ADR-0020：采样率缩放的 Graphic EQ FIR 长度

- 状态：Accepted
- 日期：2026-08-04
- 批准：用户 2026-08-04 确认采用采样率缩放方案，不扩展为对数分配 FIR 分辨率
- 关联：修订 [`ADR-0013`](0013-arbitrary-point-minimum-phase-graphic-equalizer.md) §4/§5 的固定
  16,384 taps 算法合同；Runtime 承载能力由 Accepted
  [`ADR-0017`](0017-unbounded-convolution-ir.md) 与
  [`ADR-0019`](0019-float64-deadline-distributed-convolution.md) 提供

## 背景

ADR-0013 规定 Graphic EQ 在任何输出采样率下都按真实采样率生成固定 16,384 taps 的
minimum-phase FIR。FIR 的频率分辨率约为 `Fs / N`，固定 N 意味着分辨率随采样率升高而线性
变差：

| 输出采样率 | 16,384 taps 分辨率 |
|---|---:|---:|
| 44.1 / 48 kHz | ≈ 2.7 / 2.9 Hz |
| 88.2 / 96 kHz | ≈ 5.4 / 5.9 Hz |
| 176.4 / 192 kHz | ≈ 10.8 / 11.7 Hz |

使用外接解码器、刻意开启高采样率的用户——恰恰是音频投入最高的用户——得到最差的 EQ
精度。同一组密集低频控制点在 48 kHz 下可满足编译响应误差合同（max 0.75 dB / p99 0.1 dB），
在 192 kHz 下偏差可达四倍并触发分辨率诊断。产品体验与硬件投入倒挂。

M10 已消除 Runtime 侧障碍：ADR-0017 删除了单 kernel 与总 taps 配额，ADR-0019 的 Float64
deadline-distributed 多级卷积已在 432,000 taps、8 声道实例下实测满足实时期限；Graphic EQ
FIR 编译后就是普通 convolution descriptor，零算法延迟（256-tap direct head + partitioned
tail）与 taps 无关。固定 16,384 仅是 Builder 侧设计常量，不是运行时约束。

## 决策

Graphic EQ 的 FIR 长度 N 随输出采样率缩放，保持 FIR 时间长度恒定（参考 48 kHz 的
≈341 ms），向上取 2 的幂，下限 16,384：

```
N(Fs) = 16384 × 2^max(0, ceil(log2(Fs / 48000)))
```

| 输出采样率 | N | 设计网格（2N） | 分辨率 |
|---|---:|---:|---:|
| ≤48 kHz | 16,384 | 32,768 | ≈ 2.9 Hz（与现状逐位一致） |
| 88.2 / 96 kHz | 32,768 | 65,536 | ≈ 2.7 / 2.9 Hz |
| 176.4 / 192 kHz | 65,536 | 131,072 | ≈ 2.7 / 2.9 Hz |

- ≤48 kHz 行为与 ADR-0013 现状逐位一致，保留与 EqualizerAPO 参考实现的 parity；更高采样率
  相对参考实现是正向偏差（更准），需在文档中明示，不再宣称全采样率"APO 同款行为"；
- 除 N 与设计网格外，ADR-0013 §4 的生成流程不变：域内点目标、`-100 dB` 下限、real-cepstrum
  minimum-phase 变换、IFFT 保留前 N taps、`0.5 * (1 + cos(πi / N))` 单边 taper（原公式
  `2πi / 32768` 按 2N 泛化）、Float32 转换与非有限值拒绝；
- 编译响应误差合同（max 0.75 dB / p99 0.1 dB）数值不变，但必须在每个标准采样率 × 对应 N
  的组合上重新验证；
- 配置契约不变：schema v8 只持久化控制点，FIR 是派生物；旧配置无需迁移，下次 Save 按当前
  采样率的新 N 重新编译；
- 运行时合同不变：每个 Graphic EQ 仍降为 ABI v3 convolution descriptor，与 WAV Convolution
  共享最多 8 个声道实例；0 frames 算法延迟、10 ms 双槽切换、latest-pending 合并与退休维护
  不变；
- 分辨率诊断的产品语义不变：编译响应与目标超差时显示节点归属的诊断，不静默平滑；提升 N
  后诊断触发条件在高采样率下回到与 48 kHz 相同的水平；
- 实例超限或资源不足时仍在 prepare 阶段整单拒绝，不缩短 FIR、不回退 biquad。

## 候选方案

1. **保持固定 16,384**（拒绝）：高采样率用户分辨率劣化的问题本身不解决。
2. **固定提升到 65,536**（拒绝）：48 kHz 用户承担 4 倍卷积 CPU 而无收益，且失去与参考
   实现在基准采样率下的 parity。
3. **N 随 Fs 线性缩放但不取幂**（拒绝）：非 2 幂设计网格与 FFT 尺寸使实现和验证矩阵复杂化，
   收益相对 snap-up 可忽略（88.2 kHz 取幂后分辨率 2.69 Hz，已优于 48 kHz 基准）。

## 后果

- Save 时 FIR 设计成本随 N 增长（设计网格 2N 的 cepstrum + IFFT），仍在控制路径执行，需实测
  记录各采样率 prepare 耗时；
- 每声道实例卷积 CPU 与内存随 N 增长，需在 96/192 kHz、1/2/4/8 实例下重建 Release 性能基线，
  期限口径沿用 M10（各级别低于 deadline 50%）；极端采样率（如 768 kHz 输出）的 N=262,144
  组合由性能门禁实测约束，不预设承诺；
- 测试矩阵增加采样率维度：每个标准采样率都要验证 N 映射、误差合同和回归等价性。

## 验证

见 [`milestones/M11-sample-rate-scaled-graphic-eq-fir.md`](../milestones/M11-sample-rate-scaled-graphic-eq-fir.md)。
