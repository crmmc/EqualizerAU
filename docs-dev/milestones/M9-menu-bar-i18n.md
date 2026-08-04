# M9：菜单栏、主菜单精简与中英 i18n

> **当前状态**：已完成并关闭
> **批准记录**：2026-07-28，用户批准边界文档；同日明确批准 Dock 始终保留的可达性修正
> **前置条件**：M8 已完成并关闭

## 1. 目标

把 EqualizerAU 完善为可长期驻留的 macOS 音频工具：主窗口关闭后音频继续运行，Dock 提供可靠的系统入口，
菜单栏提供快速恢复和控制；同时精简无实际功能的主菜单，并提供英文/简体中文切换。

## 2. 已录入需求

- 关闭主窗口后应用继续运行，当前处理、草稿和音频链不丢失，Dock 图标保持可见；
- 点击 Dock 或菜单栏小图标都可唤醒原主界面，恢复时不创建第二个窗口或第二套产品状态；
- 菜单栏使用固定的三推子专用 template 主图标；右下角独立 indicator 以绿色、蓝色、红色实心圆
  分别表达处理中、未处理和异常，tooltip/menu 文本提供非颜色状态说明；
- 主窗口系统菜单隐藏无产品功能支撑的默认项；
- Edit 一级菜单保持简洁，8 个焦点/多选/移动命令收进 `Processor Selection` 子菜单；
- 增加英文与简体中文 i18n，并提供用户可控的语言切换；
- 中英字体 fallback、基线、文本长度、固定宽度、截断和辅助功能字号必须纳入设计与验收。

## 3. 文档边界

- [`ADR-0015`](../adr/0015-menu-bar-window-lifecycle.md)：菜单栏点击、Dock activation policy、窗口恢复、
  主菜单精简、快捷键和退出事务；
- [`ADR-0016`](../adr/0016-runtime-language-localization.md)：语言偏好、String Catalog、即时切换、错误本地化、
  系统 UI 边界、字体布局和资源归属；
- 本文只管理 M9 范围、实施顺序、非目标和验收，不重复 ADR 的技术理由。

## 4. 范围

- 单主窗口与菜单栏入口共享唯一 `M1AppModel`、Controller、Route 和 bootstrap；
- 应用始终保持 `.regular` activation policy，窗口关闭/恢复不改变 Dock 可见性，也不隐式 Save、Stop
  或修改 Effects；
- 菜单栏提供安全恢复和退出路径，所有 Quit 继续经过现有 termination transaction；
- 主菜单只保留已定义产品命令及必要 macOS 生命周期命令；
- 产品自有窗口、菜单、状态、错误、提示、辅助功能和权限说明具备 en/zh-Hans 资源；
- 运行中切换应用自有语言不得触发配置、音频 Route 或 Runtime 变更。

## 5. 非目标

- 登录启动和非默认输出设备选择；
- 隐藏菜单栏图标或改为无窗口应用；
- 全局快捷键、通知、自动更新、菜单栏实时波形或电平；
- 在菜单栏编辑处理器、保存配置或展示完整 diagnostics；
- 新 DSP、Runtime ABI、schema、权限或音频生命周期能力；
- 翻译用户文件名/路径、CSV、Hz/dB/ch、schema/UUID 或原始技术详情。

## 6. 实施阶段

1. 批准 ADR-0015/0016，并冻结术语、菜单和点击行为；
2. 建立语言资源、偏好和结构化 presentation/error 边界；
3. 迁移产品自有文本并处理字体、固定宽度和长文本布局；
4. 精简主菜单并建立 `Processor Selection` 子菜单；
5. 实现菜单栏、窗口注册、Dock 常驻和统一 Quit；
6. 完整自动化、静态门禁、签名候选和用户 GUI/真实音频验收。

## 7. 自动化退出条件

- en/zh-Hans catalog key、复数和 placeholder 完整，资源仅进入 EqualizerAUM1 产品 target；
- 已知错误可按当前语言重新格式化，未知系统错误保留原始技术原因；
- 用户可见硬编码和本地化标签固定宽度均有可执行静态门禁及显式豁免；
- 所有既有编辑、选择、窗口和退出快捷键在菜单精简后保持有效；
- 菜单栏和窗口恢复不重复 bootstrap、窗口、Controller、Route 或音频资源；
- 完整 runtime tests、5-target isolation、realtime audit、lint 和严格编译通过。

2026-07-28 自动化证据：hostless `EqualizerAUM1RuntimeTests` 321 项执行、2 项性能 fixture 按设计跳过、
0 failures；5-target isolation、realtime source audit、localization catalog/placeholder/plural gate、plist、
全部 zsh 语法、严格 C++/ObjC++ 编译和 `git diff --check` 通过。arm64 Debug 签名候选位于
`.build/M9AcceptanceDerivedData/Build/Products/Debug/M1/EqualizerAU.app`，已通过
`codesign --verify --deep --strict`。最终只读复核为 CLEAN；该次自动化完成时尚未记录用户验收。

2026-07-29 三态 indicator 修正后的最终重验记录：产品编译和全部静态门禁通过。10,000-publication
callback stress test 曾在系统 load average 22–29 下命中既有 10 秒 wall-clock deadline；负载降至 14.7 后
隔离重放 1.19 秒通过，随后完整 hostless suite 321 项执行、2 项性能 fixture 按设计跳过、0 failures。
测试 timeout 与 Runtime 均未修改。签名候选已重建并通过 `codesign --verify --deep --strict`。

2026-07-29 用户确认当前签名候选原生 GUI 验收通过，覆盖 Dock 常驻、窗口恢复、精简菜单、Cmd-Q、
中英切换、固定三推子图标以及蓝/绿/红 8×8 实心状态点。

2026-07-29 用户进一步确认真实音频验收通过：Processing 蓝/绿状态切换无爆音或错误静音，关闭与恢复
窗口时音频和状态连续，语言切换不改变声音，正常 Quit 后系统原声恢复。M9 全部退出条件满足并关闭。

## 8. 用户验收退出条件

- 关闭主窗口后 Dock 和菜单栏均保留、真实音频不中断；点击任一入口恢复同一窗口和草稿；
- 菜单栏固定三推子图标在深色/浅色和高亮状态下清晰，不与系统媒体控制混淆；Processing active
  显示绿色实心点，未处理显示蓝色实心点，错误显示红色实心点，状态切换不更换主图标；
- 菜单只显示批准的命令，无空菜单、重复分隔线、失效快捷键或无法退出状态；
- 中英文在最小窗口、正常/缩放窗口和较大文字设置下无重叠、裁切、错误换行或基线错位；
- 语言切换保持窗口尺寸、滚动、焦点、选区、输入草稿、Undo/Redo、Save 和 Processing 状态；
- Quit 仍覆盖 Graphic EQ 待提交草稿、Save/Discard/Cancel、失败阻止退出和资源清理；
- 窗口关闭/恢复、语言切换和退出无爆音、错误静音或残留系统音频资源。
