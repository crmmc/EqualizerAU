# ADR-0009：不可变 IR 与零延迟混合卷积

| 属性 | 内容 |
|---|---|
| 状态 | 部分被 ADR-0014、ADR-0017 与 ADR-0019 取代；零延迟 direct head、ABI v3 与 Prepared 所有权仍有效 |
| 日期 | 2026-07-21 |
| 范围 | WAV IR、配置引用、SRC、Runtime ABI 与实时卷积 |
| 产品需求 | [`prd.md`](../prd.md) |
| 前置决策 | [`0003-prepared-dsp-chain-publication.md`](0003-prepared-dsp-chain-publication.md) |

## 后续修订

2026-07-28，ADR-0014 取代本文关于 immutable sidecar、storage ID、导入时复制、hash/metadata
预检和资源失败整批拒绝的决策。2026-07-30，ADR-0017 进一步取代 WAV 字节/时长、IR SRC、
单 kernel/总 taps 容量和对应失败语义。当前 schema v8 保存外部绝对源路径，每次生效重读且不
重采样；采样率不匹配只旁路所属节点，超过 30 秒只警告（2026-08-04 由 8 秒上调）。2026-08-01，ADR-0019 取代本文
关于 256-frame scalar full-complex uniform tail 的实现，改为 256-tap direct head 加 Accelerate
Float64 deadline-distributed multistage NUP。本文的声道映射、ABI v3、零延迟 direct head、
Prepared ownership 和 realtime callback 无 IO/分配约束继续有效。

## 背景

M3 需要让用户导入 WAV 脉冲响应并在有序处理链中安全切换。外部绝对路径无法保证重启后可用，
把 WAV bytes 写入配置会破坏现有配置与历史预算。传统 uniform partitioned convolution 还会引入
一个 partition 的固定延迟，使 dry/wet 旁路及包含不同节点的旧、新链无法时间对齐。

## 决策

1. 导入的原始 WAV 以新 UUID 保存为应用数据目录中的不可变 sidecar。schema v4 只保存 storage
   ID、原文件名、SHA-256、source sample rate、channel count 和 frame count。
2. 只接受最大 `32 MiB`、最长 2 秒、1...64 声道、8...768 kHz 的 RIFF/WAVE linear PCM 8/16/24/32 或
   Float32。拒绝压缩、Float64、空音频、非有限和 subnormal 样本；文件与目录同步完成后才返回引用。
3. Builder 在控制线程重新验证 sidecar hash/metadata，并以 windowed-sinc 适配真实输出采样率。
   支持的 source/target sample rate 为 8...768 kHz；降采样按 cutoff 扩展 sinc 支撑以抑制混叠，
   有限 IR 按零延拓处理并保持 impulse response gain。
   无输出时仍对启用节点执行去重、有界的 sidecar 完整性预检；全未解析作用域在布局编译时
   为空操作且不读取文件。
4. Mono IR 广播到作用域内全部声道；多声道 IR 必须严格等于有效作用域声道数，并按作用域顺序
   一一映射。不使用 modulo、重复最后声道或扬声器位置猜测。
5. ABI v3 使用独立 Convolution descriptor。每个 kernel 的前 256 taps 使用 direct FIR，tap 256
   起使用 256-frame partition、512-point FFT uniform overlap-add。该组合保持第 0 帧响应，不增加
   算法延迟。
6. 单 Prepared 最多 8 个 Convolution stages；单 kernel 最多 384000 taps，所有实际声道实例
   taps 合计最多 131072。未引用 descriptor、非法 taps 和容量超限必须在控制线程拒绝。
7. 发布继续复用现有双执行槽、pending 合并、10 ms 旧/新链 crossfade 和退休维护。IR 加载、SRC、
   taps 复制、FFT plan、频谱与全部状态分配均不得进入音频回调。

## 理由

| 关注点 | 采用方案的收益 |
|---|---|
| 持久性 | 配置不依赖外部路径，掉电后不会提交尚未同步的 sidecar 引用 |
| 延迟 | direct head 消除 partition 固有延迟，旁路和不同拓扑链可直接沿用现有 crossfade |
| 实时上界 | descriptor 数、实例 taps、FFT partition 和回调帧数均有固定容量 |
| 布局正确性 | 显式 scope 顺序映射，不从声道数量猜扬声器语义 |
| 失败语义 | decode、SRC 或容量失败发生在 Save 的 prepare 阶段，旧配置和活动链保持不变 |

## 备选方案

| 方案 | 不采用原因 |
|---|---|
| 配置保存外部 WAV 路径 | 文件可移动、权限可变化，无法形成可靠的已保存配置 |
| 把 WAV bytes 写入 JSON | 冲击 `4 MiB` 配置和 `64 MiB` Undo/Redo 预算 |
| 全 uniform partitioned FFT | 引入 256-frame 延迟，破坏现有 dry/wet 与不同拓扑切换对齐 |
| 全 direct FIR | 长 IR 的每帧乘加成本过高 |
| 回调中加载、SRC 或建 FFT | 包含 I/O、分配和无界工作，不满足实时规则 |
| 多声道 modulo 映射 | 会把错误 IR 静默应用到不对应的声道 |

## 当前边界

- 实现 diagonal per-channel convolution，不支持 true-stereo 或声道交叉矩阵 IR；
- sidecar 不自动垃圾回收；替换或删除节点不会立即删除可能仍被 previous 配置引用的文件；
- 不提供实时 SRC；只有 IR 在 prepare 阶段离线适配当前输出采样率；
- hosted 文件选择器和真实音频连续性仍需独立人工验收。
