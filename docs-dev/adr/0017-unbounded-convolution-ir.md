# ADR-0017：Convolution IR 长度自由与原采样率加载

- 状态：Accepted
- 日期：2026-07-30
- 关联：ADR-0009、ADR-0013、ADR-0014；Processing computational bypass 见 Accepted ADR-0018，
  long-IR Runtime kernel 见 Accepted ADR-0019

## 背景

EqualizerAU 原先把 WAV IR 限制为最大 32 MiB、最长 2 秒，并在 ABI v3 中限制单 kernel
384,000 taps、所有声道实例合计 131,072 taps。EqualizerAPO 没有这些产品级长度配额，而是按
源文件 frame count 初始化卷积；它也不会把 IR 重采样到设备采样率，采样率不匹配时不创建该
卷积 filter。用户要求取消人为样本数上限，由用户决定长度，同时保留文件基本检查和明确诊断。

## 决策

1. Convolution 不再设置文件字节数、时长、单 kernel taps 或所有实例总 taps 的固定上限。
   schema v8 继续只保存标准化绝对 `sourcePath`，不保存音频 bytes 或加载 metadata。
2. 继续只接受 1...64 声道、8...768 kHz 的 RIFF/WAVE PCM 8/16/24/32-bit 或 Float32；继续
   拒绝损坏结构、未知 chunk 边界、压缩编码、Float64、空音频、非有限和 subnormal sample。
3. loader 只接受普通文件，分块读取并支持取消；文件长度、RIFF chunk、frame count、数组长度和
   ABI `uint32_t tapCount` 必须能安全表示，算术不得溢出。
4. 不执行 IR sample-rate conversion。源采样率与当前输出采样率相差超过 1 Hz 时，仅旁路所属
   Convolution 节点并显示 source/target 采样率；配置 `isEnabled` 保持用户意图，下一次生效重试。
5. 不修改或写回用户文件。受支持的整数 PCM 和 Float32 均解码为内部 Float taps，这与
   EqualizerAPO/libsndfile 的 float processing boundary 等价，不承诺内部保留源位深表示。
6. 源 IR 严格超过 **30 秒**时仍正常加载，但 source diagnostic 标记性能可能下降；UI 以橙色
   弱警告显示。恰好 30 秒不警告。阈值由 2026-08-04 M1 Release dense probe 修订：ADR-0019
   内核下 dense ~9 s（432k taps）× 8 声道 stable 仍约 33% of 5.33 ms deadline，原 8 秒
   （旧 2 秒产品上限 ×4）已不再代表风险线；30 秒覆盖常见长 IR，仅对多分钟 / 超长源提示。
7. 单 Prepared 最多 8 个 convolution channel instances、每声道 512 stages 和总计 4096 stages
   的结构容量保持不变；这些限制约束拓扑数量，不限制每个 IR 的样本数。
8. Runtime 继续在控制路径复制 taps、生成 partition spectra 和分配全部历史状态；callback 不做
   文件 IO 或动态分配。ABI v3 结构不变，无需 ABI v4。
9. 内存不足、`uint32_t` 无法表示或 Prepared 动态分配失败仍会使本次 prepare 失败并保留旧活动链。
   这是机器资源或表示失败，不重新包装为固定产品样本数上限。Swift 在进入和离开 C ABI 时检查
   Task cancellation；ABI v3 内部同步 FFT prepare 不可中途取消，长 IR 取消需等待当前创建返回。
10. Builder 只在降低为 Runtime stage 时逐声道移除最后一个非零 sample 之后的精确零值；全零声道
    保留一个零 tap。源 WAV、schema、source/target frame metadata 和超过 30 秒警告均保持完整。
    该处理不删除任何可能影响输出的 sample，2 秒与 9 秒但有效 taps 相同的 IR 会生成相同 kernel。

## 结果

长 IR 的初始化时间、常驻内存、每个 256-frame partition 的 FFT 累加工作和 10 ms 双链切换成本
随有效 taps 数增长。应用只在源文件超过 30 秒时提示，不替用户删除任何可能影响输出的 sample、
降采样或静默降质；末尾精确零值不进入 Runtime kernel，因为它们对卷积结果无贡献。采样率不匹配、
文件损坏和不支持编码保持节点级旁路；全局 Prepared 分配失败保持整批失败。

## 拒绝的替代方案

- 自动截断到固定 taps 或删除非零尾部：改变用户 IR，且没有透明的声学语义。
- 自动重采样：偏离 EqualizerAPO 行为并改变用户提供的离散冲击响应。
- 超过阈值直接拒绝：把性能建议错误提升为产品能力限制。
- 完全取消时长警告：失去对多分钟级 IR 的非阻塞提示；正确做法是按测量上调门限。
- 保留 8 秒橙色警告：与 2026-08-04 Release 测量及 ADR-0019 内核结果不符，对常见长 IR 误报。
- callback 中按需读取或扩容：引入文件 IO、锁或动态分配，破坏 realtime 边界。
