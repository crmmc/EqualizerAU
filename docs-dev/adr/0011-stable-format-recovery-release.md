# ADR 0011：稳定格式恢复与近零点输出释放

- 状态：Accepted
- 日期：2026-07-22

## 背景

ADR 0010 已规定系统音频生命周期事件的有界恢复，但没有定义输出设备格式变化期间何时可以
创建新路线，也没有定义新路线从静音恢复到有效信号时的连续性。M4 人工验收 T17 发现：当前
输出设备运行中切换采样率后，路线和效果能够恢复，但短暂静音后的第一个声音出现爆音。

M0 只验证过普通启动和停止，没有验证采样率变化。Resonance 的 macOS 路线会检测同一设备的
采样率变化、销毁并重建 stream/Tap，并在输入不足时补零；它使用 750 ms 轮询形成天然稳定
窗口，但没有显式处理首个非静音样本。EqualizerAPO 由 Windows Audio Engine 管理格式重建，
不提供可直接移植的 Core Audio 路线连续性方案。

## 决策

1. 保留现有 Core Audio property listener 和 `(AudioObjectID, persistent UID)` 联合身份，不改为
   轮询，也不按设备名称判断身份。
2. 区分默认输出/存活变化与当前输出的 nominal sample rate、stream configuration、preferred
   channel layout 变化。只有后一类事件使用本 ADR 的格式恢复策略；显式 Start、普通 Stop/Start、
   wake 和默认设备切换保持原行为。
3. 同一输出身份的格式恢复采用 make-before-break Tap handover。旧路线停止输出、捕获并销毁
   Aggregate 和 Runtime 后，不立即销毁其 `.muted` Process Tap，而是把该资源及其 ownership
   token 转移为 recovery mute guard。guard 持续阻止被捕获进程的原声直通硬件，不修改物理
   设备 Mute 或用户音量。
4. 保留 guard 后，在创建新 Tap 前重新发现输出。最多读取 6 次，相邻读取间隔 50 ms；
   只有连续两次 `(object ID, UID, sample rate, channel layout, maximum frame count)` 相同才继续。
   未在预算内稳定时，本次启动失败并进入 ADR 0010 的既有有界恢复预算；guard 在同一有界恢复
   批次的重试间保留。
5. 格式恢复的新路线保持捕获先行。输出完成既有 priming 后，再保持固定 50 ms 静音；静音期间
   继续消费 ring 并推进 DSP，不积压待一次性释放的数据。
6. 固定静音结束后，在当前回调块中优先从所有输出声道共同跨越或接触零点的首帧恢复输出。
   多声道不同相位或 DC 可能不存在共同跨零点，因此本回调块内若未找到，则选择“各声道最大
   绝对幅值最小”的帧作为有界近零回退。该搜索只遍历当前预分配回调块，不等待后续块。
7. 释放前的帧写零，释放帧及其后写入正常 DSP 结果。不使用淡入、音量渐变、实时 SRC、额外
   音频线程或动态分配。
8. 新路线自己的 `.muted` Tap、捕获和输出全部启动后，按 persistent UID 复核销毁 guard。恢复
   最终失败、权限失败、取消、显式 Stop 或 Quit 时同样必须释放 guard；销毁失败保留 pending
   ownership 并进入明确清理状态，不得报告 stopped/running 后静默遗留系统静音。
9. 若格式事件携带的联合身份已不是当前输出，或旧 Tap 身份无法安全转移，则不使用 handover，
   按普通路线恢复。默认设备切换不跨设备保留 mute guard。

## 后果

- property listener 的即时性和持久身份语义保留，同时不会在输出格式尚未收敛时创建 Tap。
- 两代路线之间始终至少有一个已登记的 `.muted` Tap，避免完整清理旧路线后短暂恢复未处理原声。
- 不写物理设备 Mute，不覆盖用户音量，也不依赖输出设备是否提供全局静音属性。
- 固定静音不会把旧样本积压到释放点；近零点释放避免从零直接跳到任意幅值。
- 最坏情况下增加 250 ms 格式稳定等待、50 ms 固定静音和不足一个回调块的释放定位；这些延迟
  只作用于自动格式恢复。
- 自动化只能证明状态机、预算、实时边界和确定性样本释放，不能代替真实设备听感；签名应用
  的 T17 已确认无爆音、未处理原声旁路、持续静音、恢复循环或错误。
