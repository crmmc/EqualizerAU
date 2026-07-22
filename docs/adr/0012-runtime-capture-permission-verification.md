# ADR 0012：启动与运行期捕获权限复核及安全停机

- 状态：Accepted
- 日期：2026-07-22

## 背景

ADR 0010 已规定创建 Process Tap 返回 `kAudioDevicePermissionsError` 时停止自动重试并展示权限
状态。M4 人工验收 T19 发现：路线运行中撤销系统音频捕获权限后，既有 `.muted` Tap 仍阻止原声
直通，捕获却不再提供可处理音频；应用继续显示运行，导致系统声音消失，直到 Quit 清理路线。
第一版修复又在“撤权后退出、冷启动并显式 Start”路径中复现相同静音，证明 Tap 创建成功不能
单独作为完整权限边界。

macOS 没有公开的“仅系统音频录制”权限查询 API。`CGPreflightScreenCaptureAccess` 检查屏幕录制，
不能代表该权限；私有 TCC API 不可采用。Apple 公开 API 允许读取和修改既有 Tap 的
`kAudioTapPropertyDescription`，但没有把该属性定义为权限查询，也没有公开运行期撤权通知。
音频帧停滞或全零不能可靠区分撤权、正常静音和暂停播放。

Chromium 的 macOS 14.2+ CATap 路线在创建实际 Tap、Aggregate 和捕获 IOProc 后、
`AudioDeviceStart` 前，读取实际 Tap 的 description 并把同一值写回；任一步失败都按缺少系统
音频权限处理。该机制随初始实现 commit
[`f425afc`](https://github.com/chromium/chromium/commit/f425afc7c40ba20e55d643a681a53fdf88bba06b)
默认启用。它是公开属性操作上的生产经验，不是 Apple 文档承诺的权限 preflight 契约。

## 决策

1. 每次 Start 或恢复都创建实际路线将使用的 private、device-bound、排除本进程的 Process Tap，
   但在路线尚未获准启动时保持 `CATapUnmuted`。Tap 创建后立即登记 ownership，并继续完成
   persistent UID、格式和 Aggregate 校验。
2. 创建 Runtime 和捕获 IOProc，但不调用 `AudioDeviceStart`。随后从该实际 Tap 读取
   `kAudioTapPropertyDescription`，并把同一 description 写回。读或写返回
   `kAudioDevicePermissionsError` 时按捕获权限拒绝处理；其他 `OSStatus` 保留为明确 Core Audio
   错误。
3. 权限探测成功后，把同一 description 的 `muteBehavior` 改为 `.muted` 并写回同一 Tap。只有
   mute 写入成功后才能启动捕获，再创建和启动输出；进入运行态的生产 Tap 仍严格保持 `.muted`。
4. 权限探测或 mute 转换失败时，不启动捕获或输出，按捕获 IOProc、Aggregate、Tap 的依赖顺序
   清理。销毁失败继续使用现有 pending ownership 和 cleanup-required 语义，供 Stop/Quit 重试。
5. 应用从其他应用返回前台时，若产品路线稳定处于 running、没有 start/stop/recovery、未在
   sleep 或 termination 中，则在既有实际路线 Tap 上再次执行 description 读取和同值写回。
   不创建第二个 Tap，不改变当前 muteBehavior。
6. 前台复核成功时，当前 Processing、恢复意图和产品投影保持不变。权限拒绝时关闭自动恢复并
   执行普通 route stop，释放 `.muted` Tap；成功清理后进入 `permissionRequired`。重新授权不会
   自动启动 Processing，用户须显式 Start。
7. 前台复核发生其他错误时，同样优先普通 stop。清理成功后进入明确 waiting 状态并展示原错误；
   清理失败则以 cleanup-required 为主，保留 ownership 供显式 Stop/Quit 重试，不得继续报告
   running。
8. 若前台激活与其他路线操作交错，generation token 阻止过期复核覆盖新状态；coordinator 的
   Stop/恢复会等待短暂的 Tap 属性操作结束。若路线已经不再稳定 running，本次复核跳过；正在
   创建路线的 Start/恢复流程自身承担启动权限门禁。
9. 用户仍停留在系统设置时不承诺即时发现撤权；返回 EqualizerAU 前台时完成复核。不采用后台
   周期探测、私有 TCC、物理设备 Mute、权限 listener 或基于静音内容的看门狗。

## 后果

- 拒绝权限的启动路线在任何 Tap 抑制硬件原声前失败关闭；同一实际 Tap 从 provisional unmuted
  转为生产 `.muted`，避免“探测 Tap 成功后另建生产 Tap”的额外 TOCTOU 窗口。
- Aggregate 和 IOProc 会在权限结论前短暂存在，但捕获和输出均未启动；任何失败都走现有依赖
  清理，不留下无 ownership 的 HAL 对象。
- 运行期安全边界从“下一次路线重建才发现”收紧到“用户返回应用时复核并安全停止”。公开 API
  没有即时撤权通知，因此设置窗口内的撤权到返回应用之间仍存在受限检测窗口。
- description 同值写回是公开且有效的属性更新，但其权限语义依赖 Chromium 经验和本项目实机
  验证。自动化证明调用顺序、错误映射、状态机、所有权和失败清理；签名应用证明重启后生效的
  撤权会在冷启动 mute 前被拒绝。系统设置未使当前运行进程的授权失效时，路线继续运行是预期
  行为；前台复核保留为实际授权失效时的防御性门禁。

## 验收结果

第一版候选实现通过 275 项 hostless 测试、构建和静态复审，但 2026-07-22 的签名应用复测发现
真实失败路径：先撤销系统音频捕获权限并退出应用，再冷启动并显式 Start，应用仍进入会阻止
系统原声的路线；停止 Engine 或退出应用后原声恢复。产品层没有在 Start 时收到预期的权限拒绝。

该结果不证明第一版前台激活探针分支本身一定无效，因为此次操作没有从运行中的路线切回应用；
但它证明只把 Process Tap 创建错误视为完整权限边界，不能满足整体安全契约。第一版临时 Tap
设计由上述实际路线 Tap 双门禁替代。

修订候选的资源与协调器聚焦测试共 36 项、完整 hostless 测试共 278 项通过，证明同一 Tap 的
IOProc-before-probe、probe-before-mute、mute-before-start 顺序以及失败清理；app、全部 test
bundle 的无签名构建和静态门禁也已通过。2026-07-23 执行签名应用 T19-A：应用完全退出且
系统音频捕获权限已撤销时，用户确认持续播放的原音频正常可听；冷启动后显式 Start 未进入
运行态，界面进入权限/设置状态，原音频始终未被压制。冷启动拒权路径通过。

同日尝试 T19-B 时，路线先在重新授权后稳定运行。用户在系统设置中关闭权限但不重启应用，
当前进程的授权并未实际失效：路线继续正常运行，旁路功能正常，原音频始终可听，显式 Stop
也正常完成。该平台行为不要求路线错误地进入 permission 状态；一旦重启使撤权生效，T19-A
已经覆盖启动安全边界。用户确认当前状态符合预期并视为修复通过；AUD-03 关闭。
