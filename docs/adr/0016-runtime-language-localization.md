# ADR-0016：应用内中英本地化与即时切换

- 状态：Accepted
- 日期：2026-07-28
- 关联：ADR-0015、M9

## 背景

项目当前没有 String Catalog 或本地化 API，EqualizerAUM1 产品代码约有 453 个字符串字面量，其中
App 文件约 237 个。只翻译菜单会让状态、错误、退出确认、工具提示和辅助功能中英混杂。当前
`visibleError`、`.failed(String)`、`.stayOpen(String)`、`latestEditError` 及提前执行的
`String(describing:)` 还会缓存无法在语言切换后重新格式化的英文。

中文系统字体 fallback、字宽和基线也会放大现有固定列宽、单行截断、`fixedSize()` 和固定弹窗风险。

## Proposed 决策

1. 支持 `Follow System`、`English`、`简体中文`；首次启动默认 Follow System，显式选择写入应用
   `UserDefaults`，不进入 schema v8，不随处理链 Copy/Paste。
2. Language 同时出现在应用菜单和状态项右键菜单，两处写同一偏好。
3. 应用自有 UI 立即切换，不重启，不调用 Save、Start/Stop、Route 或 Runtime；禁止修改全局
   `AppleLanguages`、交换 `Bundle.main` 或 method swizzling。
4. SwiftUI views 使用 locale environment 和 String Catalog；Commands、状态项、AppKit alerts 和动态状态
   通过同一 presentation localizer 在展示时生成。
5. macOS 权限面板、文件选择器以及继续由系统提供的 About/Hide/Quit/Minimize/Zoom 遵循系统语言，
   不承诺随应用偏好立即变化；应用自有 UI 不得因此混用硬编码英文。

## 资源与 target 边界

- `Localizable.xcstrings`：development region 保持 `en`，project `knownRegions` 增加 `zh-Hans`；
- `InfoPlist.xcstrings`：至少本地化系统音频捕获权限说明；
- EqualizerAUM1 产品 target Resources phase 只新增上述两个 catalog；其余四个 M1 target 不复制 catalog；
- `verify-m1-isolation.sh` 使用这一精确资源白名单；
- EqualizerAU 产品名不翻译。

## 文本与错误边界

本地化按钮、菜单、状态、错误上下文、校验提示、help、accessibility、退出确认和 diagnostics 标签。
用户文件名/路径、Hz/dB/ch、数字、schema/UUID、CSV 和原始技术详情保持原样。

候选术语：Preamp=前置放大，Graphic EQ=图形均衡器，Convolution=卷积，Processing=音频处理，
Engine=音频引擎，Channel=声道。

`M1TerminationPrompt` 保持结构化 enum。应用拥有的已知错误改存 localization key 和 typed arguments；
未知系统错误显示本地化上下文加原始原因，不能翻译、吞掉或仅保存最终英文字符串。

## 字体与布局边界

- 使用 macOS 系统字体和系统 CJK fallback，不按语言硬编码字体或基线偏移；
- `.monospacedDigit()` 只用于数值；SF Symbol 与文字用系统 Label 或 first text baseline；
- 本地化标签原则上不用固定 `frame(width:)`；数值、图标点击区和双语验证列进入显式豁免；
- 审计处理器类型 104 px、Graphic EQ 34/140/120 px 列、单行截断、`fixedSize()` 和固定弹窗；
- 长文案使用 min/max width、layout priority、换行或 `ViewThatFits`，不缩小字号掩盖溢出；
- 路径可 middle-truncate，但必须提供完整 tooltip；操作文字不得静默省略；
- 切换语言保持窗口尺寸、滚动、焦点、选区和未提交文本草稿。

## 静态与验收边界

静态门禁扫描 `EqualizerAUM1/**/*.swift` 的 SwiftUI 标签、Commands、help、accessibility、`NSAlert` 和
错误载体赋值；SF Symbol、UTType、通知名、路径、单位、schema/UUID、格式串及技术详情只可通过显式
审阅豁免存在。Catalog 必须验证 en/zh-Hans key、复数、placeholder 类型和最长 presentation 文案。

GUI 在中英文、最小 620x420、正常/缩放窗口和系统较大文字下覆盖主窗口、Graphic EQ、Convolution、
菜单、alerts 和 popovers；不得重叠、裁切、错误换行、基线跳动或出现不可达控件。运行中切换语言不得
改变 Processing、草稿、Undo/Redo、Save、音频代际或真实音频。

## 拒绝的替代方案

- 只翻菜单：造成混合语言和不可重译错误。
- 修改 AppleLanguages 或 swizzle Bundle：影响进程全局且不可维护。
- 切换语言时重启或重建音频：把展示偏好错误升级为生命周期事件。
- 以固定宽度或缩小字号修补中文：会在其他文本长度和辅助功能字号再次失败。

## 批准门禁

本 ADR 在用户明确批准前保持 Proposed；需要确认三种语言模式、即时切换、双入口和候选术语表。
