# ADR-0019：Float64 deadline-distributed 多级卷积

| 属性 | 内容 |
|---|---|
| 状态 | Accepted；产品集成、自动化与用户真实音频验收完成 |
| 日期 | 2026-08-01 |
| 范围 | Runtime Convolution 数值表示、分区拓扑、调度、内存与性能门槛 |
| 取代 | ADR-0009 的 scalar full-complex uniform tail |
| 关联 | [`ADR-0017`](0017-unbounded-convolution-ir.md)、[`ADR-0018`](0018-computational-processing-bypass.md)、[`M10`](../milestones/M10-convolution-ir-length.md) |

## 背景

ABI v3 原实现把每个 kernel 的前 256 taps 逐样本直接计算，余下 taps 全部拆成 256-frame
partition，并每 256 samples 以自写 Float64 full-complex 512-point FFT 扫描所有 partitions。该结构
零算法延迟且正确，但 432,000-tap dense IR 每个声道每轮约执行 1,687 × 512 个 complex MAC；
Release stereo 尚可运行，多声道和双链切换缺少稳定余量，Debug 验收候选更会持续 underrun。

M10 在 `.build/convolution-lab/` 建立隔离实验，统一比较六种方案：当时产品的 scalar uniform、Float32
vDSP uniform、Float32 two-stage、Float32 immediate multistage、Float32 deadline-distributed
multistage，以及对应的 Float64 deadline-distributed multistage。临时目录可清理，因此本 ADR
永久记录实验合同与结论，不依赖该目录长期存在。

## 实验结论

formal-r4 对六种方案运行共享数学 gate。Float32 四种候选在普通音频范围内很快，但 packed real
FFT 对 `0.75 × FLT_MAX` 的有限 input/kernel 产生 Inf/NaN，违反 Runtime“有限溢出按符号饱和”
合同，全部淘汰。formal-r4 scalar baseline 和 Float64 distributed 通过 identity、all-zero、dense direct oracle、
extreme finite、signed saturation、pending-S3 reset、完整 432,000-tap impulse、S3 cross-chunk /
cross-partition、双声道隔离与 canary；最终候选还通过 ASan 与 UBSan。

性能使用 arm64 Release、48 kHz、256-frame quantum，独立进程、完整 steady-state warmup、固定随机
顺序、每场景 15 次 replay 与 8,192 callbacks。每个 callback 同时记录 wall 和 calling-thread CPU；
对 replay-level p99 做 10,000 次 bootstrap。qualification 要求两类 p99 的 95% CI 上界均不超过
5.333 ms deadline 的 50%。

| 432,000 taps | Wall p99 ms（95% CI） | CPU p99 ms（95% CI） |
|---|---:|---:|
| 1 channel | 0.1685（0.1668...0.1818） | 0.1682（0.1662...0.1782） |
| 2 channels | 0.3614（0.3530...0.3724） | 0.3594（0.3423...0.3681） |
| 4 channels | 0.7201（0.7094...0.7373） | 0.7188（0.7075...0.7324） |
| 8 channels | 1.4797（1.3698...1.5712） | 1.4782（1.3671...1.5568） |
| dual bank，2 channels each | 0.7260（0.6701...0.7767） | 0.7226（0.6690...0.7637） |
| dual bank，4 channels each | 1.4373（1.3529...1.4571） | 1.4280（1.3472...1.4447） |

paired screen 中，winner 相对当前实现的 432k stereo p99 提升 11.81 倍（95% CI
9.09...22.24），dual-bank 提升 11.89 倍（10.75...16.17）；reported stereo memory 从
56.05 MiB 降到 22.63 MiB，prepare 中位数从 19.33 ms 降到 5.49 ms。final 的 dual-4 场景在
122,880 callbacks 中保留一个 6.185 ms wall miss，同点 thread CPU 为 3.912 ms；未删除离群值。
两路独立数学与统计复核最终均为 CLEAN。

## 产品集成证据

产品 variant 保留任意 `frameCount` 的 256-tap direct head，并将 formal-r4 的 Float64 packed-real
multistage tail 接入 ABI v3。S2/S3 调度按累计 sample cursor 的 256-sample quantum 推进；即使
partition 数少于 MAC group 数，也保留固定 2/10 phase，使 inverse 始终在 `T-256` publish。
相同 taps 的 Prepared descriptors 和 execution-slot convolvers 共享同一 immutable kernel owner；
equivalent publication 把新 Prepared rebase 到该 owner，不复制 callback state。

最终 product probe 使用 deterministic dense 432,000 taps、每 callback 独立 capture fixture、完整
IR steady-state warmup和五个不同 64-quantum phase；每场景 8,192 callbacks，分别记录 wall 与
calling-thread CPU。48 kHz / 256 frames 的 deadline 为 5.333 ms。

| 声道实例 | Active wall/CPU p99 中位数 | Active 单 callback 最坏 | 双链 transition 最坏 | Fade-out 最坏 | Bypassed wall p99 中位数 |
|---|---:|---:|---:|---:|---:|
| 1 | 0.215 / 0.215 ms | 0.599 ms | 0.313 ms | 0.217 ms | 0.0007 ms |
| 2 | 0.429 / 0.429 ms | 1.309 ms | 0.654 ms | 0.431 ms | 0.0011 ms |
| 4 | 0.862 / 0.863 ms | 1.558 ms | 1.264 ms | 0.924 ms | 0.0016 ms |
| 8 | 1.744 / 1.744 ms | 2.819 ms | 2.499 ms | 1.833 ms | 0.0025 ms |

五次 replay 合计 163,840 个 active callbacks、40 个真实 old/new transition callbacks、40 个
steady-state phase fade-out callbacks 和 163,840 个 fully-bypassed callbacks；所有阶段 wall/CPU
deadline misses 都为 0，Runtime non-finite、saturation 和 invalid-call diagnostics 也全部为 0。
原始日志为 `.build/m10-nup-product-release-final.log`。

产品验证还包括：39/39 Runtime smoke、完整 432,000-tap 逐样本 impulse oracle、可变 callback
bitwise 分段一致性、S2/S3 固定 publish quantum、extreme finite/saturation、equivalent owner identity、
不同 IR retirement，以及最终完整 hostless suite 347 tests、2 个性能 fixture 按设计跳过、0 failures。
最终 Runtime 源的 432k ASan+UBSan 生命周期重放、5-target isolation、41 个 realtime 显式函数审计、
localization、plist、全部 zsh、C++ strict compile、Markdown links 和 diff checks 均通过。两路独立
产品实现复核在修正 fixed phase、probe 输入边界与 test-hook 隔离后均为 CLEAN。

为避免测试状态进入正式 Runtime，最终产品不保留 slot allocator fault-injection branch 或 kernel/setup
原子计数器；两阶段 build-then-commit 仍保持状态与 ownership 合同，但自动化证据不冒充 deterministic
allocator-exhaustion 注入。Apple Development arm64 Release 候选位于
`.build/M10NUPAcceptanceDerivedData/Build/Products/Release/M1/EqualizerAU.app`，strict codesign、
Hardened Runtime、Accelerate 最终链接和版本 `0.1.0 (1)` 均已核验，尚未由助手启动。

## 决策

1. ABI 继续为 v3；`EAUM1PreparedConvolution` 仍只传入 `tapCount + planar Float32 taps`，不新增
   持久化字段、配置 schema 或 callback API。
2. 产品必须支持任意 `frameCount <= maximumFrameCount`。因此实验 winner 的固定 256-frame 首段
   不直接照搬：taps `[0, 256)` 保留逐样本 Float64 direct FIR，保证第 0 帧响应和 0-frame 算法延迟。
3. tail 无缝覆盖为 `256×1 @ 256`、`512×≤4 @ 512`、`2048×≤8 @ 2560`、
   `16384×N @ 18944`；每段采用 Accelerate Float64 packed-real FFT、split-complex spectrum 与
   `vDSP_zvmulD` / `vDSP_zvmaD` MAC，inverse 使用已验证的 `1 / (4 × fftSize)` scale。
4. 调度由每个 convolution state 的累计 sample cursor 驱动，与 host callback 次数无关。处理绝对
   sample `n` 前，若 `n % 256 == 0`，先推进一次已有 distributed job；处理 chunk 末 sample 后才
   建立新 job 并执行首组 MAC。`frameCount == 0` 不推进。由此 S2/S3 都在首个目标 sample 的
   `T-256` 完成 inverse/publish，即使 host 以 1 frame 分块也不改变时序；一次 callback 跨越多少
   quantum 就必须处理多少事件。
5. 256/512 segments 在输入 chunk 完成时计算。2048 segment 在 chunk 末完成 forward + 首组 MAC，
   下一 quantum 做第二组 MAC，再下一 quantum inverse/publish；16384 segment 在 chunk 末做
   forward + 首组 MAC，后续 9 个 quantum 各做一组，第 10 个 quantum inverse/publish。
6. tail 写入预分配 absolute-output timeline；每个 sample 读取并清零当前位置，再与 direct head 相加。
   禁止写入已读取的 sample；direct 与所有 segments 在 Float64 中完整求和后才执行一次输出边界转换。
7. 相同 taps 的 descriptor 共享不可变 taps、FFT setup 和 kernel spectra。Prepared descriptor table 与
   每个 execution slot 都持有 `shared_ptr<const Kernel>` owner；callback 只解引用已缓存 owner，
   不复制或销毁 shared owner。equivalent publication 删除旧 Prepared 后，slot owner 仍保持 kernel
   有效，并把 candidate rebase 到同一个 owner，避免悬空引用和重复 spectrum。
8. 每个 convolution stage、声道和 execution slot 仍持有独立 direct history、segment input/history、
   accumulator、job phase 和 timeline，不共享可变状态。
9. FFT setup、kernel transform、taps copy 和全部状态分配只在 Prepared / slot control path 发生；
   callback 不分配、不加锁、不做 IO、不创建 FFT setup，不引入普通 worker thread。
10. Prepared、RuntimeCreate、normal publish、pending promotion 与 bypass cold replace 均先在临时对象或
    inactive slot 完成所有可失败构建；只有成功后才递增 generation、交换 Prepared、改 ticket 或消费
    candidate。失败必须保留旧活动链、candidate ownership 与可重试的原 retirement ticket，不能形成
    无 ticket 的孤立 pending。
11. DSP 内部保持 Float64，输出边界继续执行现有 finite Float32 饱和、NaN 归零和 subnormal 归零；
    diagnostic counter 语义不因使用 Accelerate 而删除。
12. 双 execution slot、10 ms old/new chain crossfade、latest-pending、retirement ticket、fully-bypassed
    cold replace 和 ADR-0018 computational bypass 的状态机保持不变；retired slot 只在 callback 已确认
    terminal generation 后由 control path 清理。
13. 方案先以现有单 callback thread 落地。只有真实 Release/Core Audio 证据仍不足时才重新评估
    Audio Workgroup late-segment workers；普通 GCD/background queue 不得进入 realtime 方案。

## 不采用的方案

| 方案 | 原因 |
|---|---|
| 保留 scalar uniform | 复杂度随 IR partitions 线性增长，formal-r4 primary qualification 失败 |
| Float32 vDSP 方案 | 极端但合法的 finite Float32 输入会形成 Inf/NaN，违反现有数值合同 |
| 只换 vDSP uniform | 向量化有收益，但仍每 256 samples 扫描所有长尾 partitions |
| two-stage 256/4096 | 比 uniform 快，但 screen p99 明显落后多级分时方案，周期峰值更高 |
| immediate multistage | 平均成本下降，但整个 16384-stage 工作集中到单次 callback |
| Garcia 最小平均成本分区 | 可能产生零 clearance，平均最优不等于 realtime deadline 可调度 |
| 直接使用第三方 convolver | ABI、可变 callback、数值饱和、发布所有权和许可证边界均不匹配 |
| 立即引入多线程 | 增加 wakeup jitter、同步和优先级反转；单线程 winner 已通过 8ch active / 4ch dual gate |

## 产品验收门槛

- direct、每个 segment 边界、跨 segment 抵消和完整长 tail 与高精度直接卷积一致；
- 1/7/63/2/97 等可变 callback 分块与单块结果一致，首帧 impulse 仍在第 0 帧；
- extreme finite input/kernel 不出现 Inf/NaN，signed saturation 与 diagnostic 继续正确；
- mono kernel 可共享只读频谱，但所有声道、stage、slot 的 history/reset 互不泄漏；
- equivalent publication 保留 state，不同 IR 继续走 10 ms 双链与退休维护；
- fully bypassed 不执行 vDSP，cold replace 后启用 fresh state；
- realtime source audit 覆盖所有新增 callback helper；ASan/UBSan、完整 hostless suite 和静态门禁通过；
- Release product probe 必须保持 432k stereo p99 明显优于旧实现，并覆盖 1/2/4/8 active、dual chain、
  fade-out 与 fully-bypassed 成本；
- 最终 Apple Development Release 候选由用户验证 dense 9 秒 IR active、Save 双链、Processing Off/On、
  采样率 mismatch 恢复和正常 Quit，无持续卡顿、爆音、静音或恢复循环。

## 结果边界

本 ADR 已完成算法选择、产品适配、自动化和 Core Audio 真实音频验收。2026-08-02，用户针对
最终 Apple Development Release 候选的完整清单回复“测试通过了”；dense IR active、Save 双链、
Processing Off/On、采样率 mismatch 恢复和正常 Quit 均据此记录为通过，M10 已完成并关闭。
这不构成 commit、push、tag 或公开发布授权。

## 批准记录

2026-08-01，用户要求整理实验结果、写入 ADR，并继续 M10 把最佳方案用于程序后交由用户实测。
该指令批准本 ADR 及产品集成；没有授权 commit、push、tag 或发布。
