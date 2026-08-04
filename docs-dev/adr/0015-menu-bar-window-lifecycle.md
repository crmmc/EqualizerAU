# ADR-0015：菜单栏与主窗口生命周期

- 状态：Accepted
- 日期：2026-07-28
- 关联：ADR-0011、M9

## 背景

当前应用关闭最后一个窗口不会退出。最初候选要求关闭主窗口时隐藏 Dock，只通过菜单栏小图标恢复；
原生 GUI 验收发现菜单栏状态项可能受刘海和可用宽度限制而不可见，因此用户在 2026-07-28 明确批准
改为始终保留 Dock，菜单栏作为快捷入口，Dock 作为系统级可靠恢复和退出入口。主窗口菜单还包含大量
SwiftUI 自动生成但没有产品行为的项，Edit 中 8 个处理器选择命令平铺后也过长。

现有 termination delegate、待提交 Graphic EQ 草稿、Save/Discard/Cancel 和音频清理事务不能被新的
窗口或菜单入口绕过。

## 决策

1. 正常启动显示主窗口，应用在整个进程生命周期保持 `.regular` activation policy；本 ADR 不增加登录启动
   或隐藏启动。
2. 用户关闭唯一编辑器窗口时不退出、不 Save、不 Stop；Dock 和菜单栏图标都继续存在，音频和唯一
   `M1AppModel` 保持运行。
3. 点击 Dock 图标或菜单栏图标都按固定 Scene ID `editor` 恢复窗口并激活应用，不搜索“第一个可见窗口”，
   也不创建第二个 WindowGroup。
4. 菜单栏右键打开小型上下文菜单，候选只含只读状态、Open EqualizerAU、Processing、Language 和
   Quit EqualizerAU；左键恢复行为不得被菜单样式取代。
5. 因为需要左右键不同语义，使用 AppKit `NSStatusItem` 的显式 action/menu 边界，而不是强行使用
   `MenuBarExtra(.menu)`。状态项只持有 MainActor UI 协调对象，不持有 Runtime/HAL 资源。
6. AppDelegate model 接线、状态项注册和唯一 bootstrap 必须独立于编辑器 `onAppear`，菜单可交互前完成。
7. Quit 必须调用 `NSApp.terminate(nil)`；禁止 `exit`、直接 shutdown 或直接 Stop。取消退出或提交失败时，
   重新显示编辑器并保留原草稿和错误。
8. 菜单栏始终使用固定的三推子 EqualizerAU 专用 template 主图标；Processing、Bypass、Stopped 和过渡
   状态不切换 waveform、speaker、stop 或 recovery 等系统媒体语义图标。主图标右下角使用独立 8×8
   indicator overlay：Processing active 为绿色实心圆，未处理状态为蓝色实心圆，错误、权限异常或
   cleanupRequired 为红色实心圆；tooltip/menu 文本继续提供明确的非颜色状态说明。

## 主菜单边界

保留：

- 应用菜单：About、Language、Hide、Hide Others、Show All、Quit；Language 的模式与本地化行为由 ADR-0016 定义；
- File：Save、显式 Close Window；
- Edit：Undo、Redo、Cut、Copy、Paste、Delete、Select All；
- `Processor Selection` 子菜单：Move Focus Up/Down、Extend Selection Up/Down、Add/Toggle Focused
  Processor、Move Selection Up/Down；
- Audio：Start Engine、Stop Engine、Diagnostics Snapshot；
- Window：Minimize、Zoom。

隐藏：Settings、Services、New/Open/Open Recent、Save As、Duplicate/Rename/Move/Revert、通用
Import/Export、Page Setup/Print、Find/Spelling/Substitutions/Transformations/Speech/Dictation/Emoji、
Toolbar/Sidebar/Full Screen、Window List/Tab/Arrangement 和无 Help Book 的 Help。

先使用 SwiftUI `Scene.commandsRemoved()` 移除默认 scene commands，再通过 `CommandGroupPlacement` 和显式
自有命令重建批准菜单；禁止按标题、本地化字符串或菜单位置遍历 `NSMenuItem`。Graphic EQ CSV
Import/Export 保留在其编辑器内。

## 快捷键与 responder

保留 Cmd-S/Z/Shift-Z/X/C/V/A/W/Q、Delete、Up/Down、Shift-Up/Down、Space、Cmd-Space、
Cmd-Control-Up/Down，以及保留系统项对应的 Cmd-H、Cmd-Option-H、Cmd-M。`NSTextView` 为 first
responder 时，文本命令可用性独立于产品 `canEdit`，优先交给文本编辑器。

## 拒绝的替代方案

- 关闭窗口同时退出或 Stop：违背驻留工具目标，并扩大音频生命周期变化。
- 关闭窗口自动 Save：绕过显式 Save 和退出事务。
- 关闭窗口后隐藏 Dock：菜单栏状态项可能被刘海或其他状态项遮挡，不能作为唯一可靠入口。
- 只保留 Dock、不建菜单栏入口：不满足快速恢复和 Processing/Language 快捷控制需求。
- 左键先展开菜单：未满足“点击图标唤醒主界面”的直接行为。
- 按菜单标题删项：受系统语言和菜单顺序影响，不可验证。

## 结果与批准门禁

实现引入 AppKit status item，但 activation policy 始终为 `.regular`，不修改 schema、DSP、Runtime 或 Route。
2026-07-28 用户明确批准 Dock 常驻修正；本 ADR 保持 Accepted。
