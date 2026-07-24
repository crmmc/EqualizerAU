# M5：EqualizerAPO 编辑器对齐

> **当前状态**：M5-B 已完成，M5-C 性能基线待开始
> **前置条件**：M4 收尾缺陷和受阻的真实音频验收已完成

## 1. 目标

M5 将处理器编排区域和各处理器的展示、选择及编排交互对齐本地 EqualizerAPO，形成适合
重复编辑的紧凑桌面工作流。目标是在该范围内逐项 100% 对齐参考行为；只有参考行为与 macOS
平台规范、本项目 PRD、实时安全、数据完整性或既有 ADR 冲突时才允许明确适配。对齐范围仅限
处理器组合区域及处理器本身，不复制 Windows 应用外壳，也不改变本项目的 macOS 生命周期、
实时安全和显式 Save 语义。

## 2. 阶段输入

M4 人工验收确认了以下需求：

- Add 控件移到顶部并紧邻 `Processing`；
- 当前处理器编排和处理器展示不符合目标，需要作为整体重新设计；
- 拖拽排序必须恢复并与选择、复制及节点身份语义一致；
- Preamp、Channels、Convolution 等全部处理器均属于对齐范围；
- IR 导入失败必须显示包含具体原因的清晰模态警告；
- 展开处理器和 Paste 存在可感知卡顿，完成新编辑器后必须定向测量。

## 3. 探索门禁

2026-07-23 已完成第一轮源码探索，未启动 GUI 或真实音频，也未修改编辑器源码：

- 当前实现：`EqualizerAUM1App.swift`、`M1EditingSession.swift`、处理模型、配置 codec、Builder
  及相关 hostless 测试；
- 参考实现：`../EqualizerAPO/Editor/FilterTable*`、`FilterTableRow*`、`MainWindow*`、
  `PreampFilterGUI*`、`ChannelFilterGUI*`、`ConvolutionFilterGUI*` 及对应 filter/parser；
- 既有约束：PRD、架构、ADR 0003/0004/0005/0009 和 M1-M4 里程碑。

探索确认当前模型层已经具备稳定 UUID、有序组 move/Option-copy、typed clipboard、预算化
Undo/Redo、显式 Save 和不可变 IR sidecar。主要差距集中在编辑器容器、常显处理器控件、键盘
事件路由、拖拽反馈、Channels 停用、IR 错误反馈和交互性能。以下矩阵和原型确认前，不开始
编辑器重写。

## 4. 行为矩阵

分类含义：`采用` 表示直接采用参考行为；`适配` 表示参考意图保留，但由 macOS 规范或本项目
既有契约改变实现；`不采用` 表示属于 Windows/Qt 外壳；`延期` 表示由 M6 负责。

| 范围 | EqualizerAPO 源码行为 | 当前行为 | M5 契约 | 分类 |
|---|---|---|---|---|
| 顶部操作区 | Add 位于行内和列表末尾 | Save、Processing 和状态在顶部，Add 位于列表底部 | Add 移到 Processing 右侧；顶部 Add 始终追加节点且不改变选择，符合 PRD，不保留行内 Add | 适配 |
| 处理器行 | 编号/拖拽区、Add、Remove 和完整处理器 GUI 同行常显，无展开模型 | 通用摘要行；只有 focused 行展开专用编辑器 | 使用紧凑分隔行，常显拖拽、启停、主要参数和删除；不再以 focus 隐式展开作为主要交互 | 采用 |
| 指针选择 | 单击替换，Ctrl 单项切换，Shift 替换为 anchor 到目标范围，空白清空选择 | 已实现相同行为，以 Command 代替 Ctrl；缺少明确空白取消入口 | 保留当前模型，使用 Command 多选并支持点击列表空白清空选择 | 适配 |
| 键盘选择 | Up/Down 选择并聚焦，Ctrl+Up/Down 仅移动 focus，Shift 扩展；Space 加选，Ctrl+Space 切换 | Up/Down 仅移动 focus，Shift 扩展；缺少 Space 行为 | PRD 的方向键 focus 语义优先；补充 Space 加选、Command+Space 切换，并保证焦点可见和自动滚动 | 适配 |
| 文本输入路由 | Qt first responder 接收文本编辑快捷键 | 应用级 replacement commands 可能截获输入框 Cut/Copy/Paste/Delete | 文本或数值输入获得焦点时，标准编辑命令必须留给控件；节点命令只在列表上下文生效 | 适配 |
| 拖拽起点 | 只允许从编号 header 拖动，超过系统阈值后开始 | 整行 drag 手势，未选行异步改选后可能读取旧 selection | 只从稳定尺寸拖拽 handle 开始；按下未选行先同步建立 selection，再创建拖拽快照 | 采用 |
| 拖拽目标 | 行中心决定前/后插入，左侧箭头持续指示目标；默认 move，Ctrl-copy | 支持行前/末尾 drop 和 Option-copy，但无持续插入反馈 | 使用整行宽度插入线；保持有序组相对顺序、move UUID、Option-copy 新 UUID 和 drop 后整组选中 | 适配 |
| 删除 | 行内 Remove 删除单行；Delete 删除全部选择；均不确认 | 已具备同等行为和 Undo | 直接保留，并确保文本输入中的 Delete 不触发节点删除 | 采用 |
| 节点启停 | power toggle 可注释任意可解析 filter，包括 Channel | Channels 不能停用；其余处理器可停用 | 所有节点均显示 power；使用 typed `isEnabled` 而非注释文本。Channels 停用时不改变后续 scope，需要配置 schema 迁移 | 适配 |
| Cut/Copy/Paste | 复制文本；Paste 在首个选择前插入，无选择时追加并选中新行 | typed JSON、4 MiB 预算、新 UUID 和相同插入语义 | 保留 native typed clipboard、预算和身份契约，不增加 EqualizerAPO 文本互操作 | 适配 |
| Undo/Redo | 不支持 | 两栈合计 30 步、64 MiB，连续手势合并 | 保留本项目增强及标准 macOS 快捷键，不为参考一致性删除 | 适配 |
| Preamp | 常显 power、`-20...20 dB` 旋钮和 `-100...100 dB`/`0.1 dB` 输入 | focused 行展开 Enabled、slider 和数值输入 | 常显 power、旋钮和直接输入；输入超出旋钮范围时不得被旋钮夹回 | 采用 |
| Channels | 常显选择摘要和 Change 对话框；支持 All、已知声道、自定义声道及排序 | focused 行使用菜单，自定义声道另开模态；无 power | 常显摘要、power 和 Change；只允许 All 和当前默认输出枚举声道，旧未知标识仅可移除；Cancel 不修改 | 适配 |
| Convolution | 外部路径输入、Select file、内联文件状态；不复制文件 | 导入不可变 WAV sidecar，展示 metadata 和 Replace；错误只进底部状态 | 保留 sidecar、完整性校验和 Replace；常显文件 metadata，不提供可编辑外部路径 | 适配 |
| IR 错误 | 红色内联文字，不阻止保存 | 底部通用错误字符串 | 损坏、超限、不支持或导入失败使用包含具体原因的原生模态警告；旧 IR、草稿和活动链保持不变 | 适配 |
| Graphic EQ | 有固定/可变频段专用 GUI | 固定 15 段 focused 编辑器 | M5 只接入通用容器、选择、启停、删除和拖拽；固定 15 段仅作迁移期占位，专用模型和界面由 M6 替换 | 延期 |
| 保存与声音 | Instant mode 可在编辑时写配置 | 草稿与已保存配置、活动链分离，显式 Save 后发布 | 保留显式 Save、提交代次和运行时原子发布，不采用 Instant mode | 不采用 |
| Windows/Qt 外壳 | 多文档 tab、dockable analysis、Windows 设备/ACL/UAC 和注册表偏好 | 单实例、单主窗口、关闭窗口不退出 | 不复制外壳、路由、安装和平台权限行为 | 不采用 |
| 参数性能 | 参数更新只改当前 item；结构变化全量重建 GUI | 每次 value change 串行 normalize、validate、规范编码，可能积压 | 先建立主线程时延和队列深度基线，再减少中间快照工作；不得绕过完整校验、预算或显式 Save | 适配 |

## 5. 目标原型

这是布局和交互原型，不规定 SwiftUI 类型或视觉 token：

```text
┌─ Save ─ Processing [on/off] ─ Add ▾ ───────────── route/status ─┐
├─ 1  [drag] [power]  Preamp       [knob] [ 0.0 dB ]    [delete] ┤
├─ 2  [drag] [power]  Channels     L, R        [Change…] [delete] ┤
├────────────── drop insertion indicator ─────────────────────────┤
├─ 3  [drag] [power]  Convolution  room.wav · 48 kHz     [Replace]│
│                                      2 ch · 200 ms      [delete]│
└─ output / save / validation / runtime status ───────────────────┘
```

- 行以分隔线组织，不使用嵌套卡片；拖拽 handle、power 和删除具有稳定尺寸；
- selection、keyboard focus、hover 和 drop target 是彼此可区分的状态；
- Add、power、删除、Replace 等图标或短命令均有工具提示和可访问名称；
- 参数编辑不改变行高或导致列表位置跳动；长文件名截断但完整名称可通过工具提示读取；
- 窗口继续满足现有 `760 x 520` 默认尺寸和 `620 x 420` 最小内容尺寸，较窄窗口允许处理器
  参数区域换行，但工具操作不重叠。

## 6. 人工验收清单

1. Add 位于 Processing 右侧，追加四类节点且不改变既有选择；空链也可新增。
2. 每个处理器无需先聚焦即可查看和操作主要控件；单击控件不会意外改变组选择。
3. 普通单选、Command 切换、Shift 连选、Select All、空白取消和键盘 focus 均与矩阵一致。
4. 文本和数值输入中的 Command-X/C/V/A、Delete、方向键只作用于输入控件。
5. 从拖拽 handle 移动连续或非连续选择时，插入线稳定，顺序和 UUID 保持；Option-copy 生成
   新 UUID，Undo/Redo 各作为一步恢复。
6. Preamp 的旋钮、直接输入、power 和声道诊断正确；超出旋钮范围的合法输入值保持不变。
7. Channels 只列出 All 和当前默认输出的枚举声道，旧未知标识只能移除；停用后不改变后续效果的
   scope，Save、退出和重启后状态一致。
8. Convolution 成功导入后展示文件名、采样率、声道和时长；取消 Replace 保留旧 IR。
9. 损坏、超限或不支持的 IR 显示含具体原因的模态警告，确认后编辑器继续可用，旧 IR 不变。
10. Undo/Redo、Cut/Copy/Paste、Save、Discard、关窗重开和 Quit 无行为回归。
11. 在阶段定义的长处理链与最大合法 paste 样本上测量 Add、Paste、拖拽和连续参数编辑；不得
    出现未定义阈值之外的主线程阻塞、命令积压或行布局跳动。

## 7. 计划范围

- 处理器列表的布局、顺序表达和稳定尺寸；
- 单选、Command 多选、Shift 连续选择、Select All 与键盘操作；
- move/copy 拖拽、插入位置反馈、相对顺序和节点身份；
- 顶部 Add、删除、启用/停用及处理器级编辑入口；
- Preamp、Channels 和 Convolution 的目标展示与参数交互；
- Convolution 文件选择、文件信息和导入失败模态反馈；
- Undo/Redo、Cut/Copy/Paste 与显式 Save 语义在新编辑器中的完整保留；
- Paste 和高频编辑操作的主线程延迟测量与定向优化。

## 8. 非目标

- 不复制 EqualizerAPO 的 Windows 菜单、窗口外壳、APO 路由或安装流程；
- 不在本阶段实现 EqualizerAPO 配置文件导入；
- 不在本阶段决定或实现任意频率 Graphic EQ 的持久化与 DSP；该特性属于 M6；
- 不以修改实时音频路线作为解决界面性能问题的手段；
- 不改变已保存配置是运行时唯一配置事实来源的产品语义。

## 9. 阶段顺序

1. 用户确认本文件中的行为矩阵、原型和人工验收清单；已于 2026-07-23 完成；
2. M5-A 实现顶部 Add、通用处理器行、选择、键盘事件路由、拖拽 handle 与插入反馈；候选实现
   已于 2026-07-23 完成，原生 GUI 人工验收及收尾验证于 2026-07-24 完成；
3. M5-B 接入 Preamp、Channels 和 Convolution，并完成 Channels `isEnabled` schema 迁移与
   IR 模态错误；候选实现、自动化验证和原生 GUI 人工验收已于 2026-07-24 完成；
4. M5-C 建立性能基线，只修复已测得的连续编辑、Paste 或结构变化瓶颈；
5. 完成 hostless、Hosted GUI、签名应用和逐项人工验收。

## 10. M5-A 候选实现与证据

- 用户确认独立 HTML SPA 布局原型 `docs/prototypes/m5-editor-layout.html` 后，候选实现将 Add
  移到 Processing 右侧并移除列表底部 Add，节点继续固定追加且不改变选择；
- 列表改为稳定高度的紧凑行，常显编号、拖拽 handle、power、处理器摘要或主控件和删除；
  Preamp 常显旋钮与直接输入，Channels 常显摘要和 Change，Convolution 常显文件 metadata
  和 Replace；
- 固定 15 段 Graphic EQ 保留迁移期摘要、频段预览和弹出编辑入口，避免在 M6 替换前丢失
  既有编辑能力；最终任意频率模型与专用界面仍只属于 M6；
- 新增 Space/Command-Space 选择语义和 focus 自动滚动；文本输入优先消费 Undo/Redo、
  Cut/Copy/Paste、Select All、Delete、方向键和 Space，不再误触节点命令；
- 拖拽只从固定 handle 开始，行中心决定前后插入，整行插入线持续反馈；未选行拖拽在模型层
  原子替换 selection 后再执行 move/copy，消除异步 UI selection 竞态；
- 新增 3 项 editing session 测试；相关聚焦测试共 25 项通过，完整 hostless
  `EqualizerAUM1RuntimeTests` 共 281 项通过，零失败；
- `EqualizerAUM1` 无签名 `build-for-testing`、29-function realtime audit、5-target isolation 和
  diff whitespace 检查通过；独立静态复审发现的 Graphic EQ 编辑入口、文本 Undo/Redo、
  无选择 Cut/Copy、行内控件选择传播和 accessibility 问题均已修正并复核；
- 自动化阶段未启动 GUI 或真实音频；后续原生 GUI 结论仅采用用户实际操作后报告的结果，
  不能以 hostless 或静态证据替代。
- 人工验收修复完成后重新执行完整 `EqualizerAUM1RuntimeTests`，281 项测试零失败；工程与 M1
  Info.plist lint、diff whitespace 和 Apple Development 签名候选严格验证均通过，M5-A 关闭。

### 10.1 已完成的人工验收

- 2026-07-23 的 Apple Development 签名 arm64 Debug 候选构建成功，严格签名验证通过；
- 首次 Xcode 运行发现自有拖拽 UTType 未在应用 Info.plist 导出的告警；候选已增加
  `UTExportedTypeDeclarations`，重新构建后产物声明和严格签名验证通过；
- 按用户标记将处理器序号移到拖拽 handle 之后，并增大为居中显示；用户在重新构建的原生
  应用中确认布局通过；
- 用户实际拖动处理器验证基础排序和插入反馈可用；随后确认非连续多选 move 与 Option-copy
  均按稳定顺序原子处理整组、drop 后选择正确，且各自只需一次 Undo/Redo 即可恢复或重放。
  人工验收清单第 5 项关闭。
- 用户从顶部 Add 依次追加 Preamp、Channels、Convolution 和 Graphic EQ，确认节点固定出现
  在列表末尾，原有组选择保持且新节点不自动加入选择；空链中 Add 仍可创建第 1 行，随后两次
  Undo 分别移除新节点并原子恢复删除前整条链。人工验收清单第 1 项关闭。
- 用户未先聚焦处理器行即可操作 Preamp 主控件、Channels Change、Convolution Replace 和
  Graphic EQ 编辑入口，取消或关闭后原组选择均保持，人工验收清单第 2 项关闭。但 Graphic EQ
  编辑入口实测至少约 5 秒才弹出，且弹出界面横向滚动严重卡顿；该问题记入清单第 11 项和 M5-C
  性能基线，不能因界面最终出现而视为性能通过。
- Preamp 直接输入 `40 dB` 后保持原值而仅将旋钮视觉限制在 `+20 dB` 端点，`±120 dB` 输入按
  契约限制为 `±100 dB`；连续旋钮手势、power 启停均可单步 Undo/Redo 且不改变组选择。Channels
  改为仅 `L` 后，后续 Preamp scope 正确显示 `L`，Cancel 不改变草稿。人工验收清单第 6 项关闭。
- 普通单选、Command 切换、Shift 连选和 Select All 的选择结果正确；首次验收发现行选择命中区
  分散且取消选择仅覆盖底部固定 `32 pt` 透明行，导致鼠标操作不灵敏。候选随后增加控件后方的
  连续整行选择层，并让取消区域填满列表剩余高度；用户复测确认行选择、空白取消以及控件不
  干扰组选择均通过。用户随后确认方向键只移动可见 focus 描边、Shift+方向键连续扩选、Space
  加选、Command+Space 切换以及超出视口时自动滚动均符合契约，人工验收清单第 3 项关闭。
- Preamp 数值框中的 Select All、Copy、Delete、Paste 和方向键均只作用于文本，没有触发处理器
  命令；但输入 `12` 被格式化为 `12.0` 后，第一次文本 Undo 只回到格式化前的 `12`，没有撤销
  用户参数编辑。源码确认 `TextField(value:format:)` 把规范化重写注册进了 AppKit 文本历史；
  候选随后改为聚焦期间保留原始文本并合并参数手势，只在 Return 或失焦时校验、限制范围并
  规范化为一位小数。用户复测确认聚焦期间文本 Undo/Redo 和提交后的参数 Undo/Redo 均不会再
  停留于格式化中间态；Command-X 也只剪切输入框文本，不会删除处理器，随后 Paste 和 Return
  正常恢复并提交数值。人工验收清单第 4 项关闭。

### 10.2 M5-B 候选实现与自动化证据

- 配置和 typed clipboard 升级到 schema v5，Channels 必须显式编码 `isEnabled`；v1-v4 读取后
  规范化为 v5，旧 Channels 缺省迁移为启用，未知或跨版本字段继续由严格 shape 校验拒绝；
- Channels power 接入统一节点编辑、复制和 Undo/Redo；disabled Channels 在 UI 中变暗，scope
  resolver 和 Builder 均忽略它，后续效果继续沿用前一个启用的 Channels scope；
- Channels 菜单在音频停止时被动读取默认输出布局，只提供 All 和枚举声道，不创建 Tap、Aggregate
  或启动音频；旧配置中的未知标识单独显示且只能取消选择，不再提供自由文本新增入口；
- 枚举名称优先采用完整 channel layout，再以 Core Audio 明确提供的 preferred stereo pair 补充
  `L`/`R`；其余数字标识显示为 `Channel N`，不按声道总数猜测多声道顺序；
- Convolution Add/Replace 的导入失败改为原生模态警告，按 32 MiB、2 秒、WAV 结构、encoding、
  metadata、sample 完整性和 storage 错误给出具体原因；取消选择不产生错误，失败不修改草稿或
  既有 IR 引用；
- 初始 4 个聚焦测试类共 73 项通过；枚举修复后的 2 个相关测试类共 115 项通过，完整
  `EqualizerAUM1RuntimeTests` 共 289 项通过，零失败；M1
  Apple Development 签名 arm64 Debug 候选构建、严格签名验证、Plist lint、29-function realtime
  audit、5-target isolation 和 diff whitespace 检查均通过；
- 自动化阶段未启动 GUI 或真实音频，不能以 hostless 测试替代人工验收；对应签名候选的用户
  人工验收结果记录于下节。

### 10.3 M5-B 已完成的人工验收

- 用户在 Apple Development 签名候选中确认 Channels 菜单按当前默认输出显示 `L`、`R`，并
  分别验证 `L`、`R`、`L + R` 和 `All` 作用域，处理结果均符合预期；
- 用户确认 Channels 停用后的 scope 行为正确，显式 Save、退出和重启后配置状态保持一致；
- 用户确认合法 mono WAV 可成功导入；以损坏 WAV Replace 时显示具体模态错误，确认后编辑器
  仍可用且原 IR 保持不变。人工验收清单第 7 至 9 项关闭，M5-B 关闭。

## 11. 退出条件

- 探索矩阵中的每项行为都有采用、适配或不采用的明确结论；
- 处理器可按目标交互新增、选择、移动、复制、删除和编辑，顺序与实际处理顺序一致；
- Preamp、Channels、Convolution 的展示和交互通过人工对照验收；
- 损坏、超限或不支持的 IR 产生具体、可确认的模态错误，旧 IR 保持不变；
- Undo/Redo、Cut/Copy/Paste、Save、Discard 和窗口生命周期没有回归；
- Paste 和连续参数编辑不产生已定义阈值之外的主线程阻塞；
- hostless、Hosted GUI、签名构建和相关人工验收均形成阶段证据。

## 12. 当前未决边界

- 行为矩阵、原型和人工验收清单已由用户确认；M5-A 和 M5-B 已完成，下一阶段为 M5-C 性能
  基线与已测瓶颈修复；
- Channels `isEnabled` 已使用 schema v5 和兼容测试实现，不是 UI 假开关；作用域枚举、Save 和
  重启后的状态保持已由用户在签名候选中确认；
- Graphic EQ 在 M5 中只服从通用处理器容器契约，其最终专用界面由 M6 替换；
- 主线程时延、命令积压和长链样本阈值必须先通过可重复测量确定，不预先指定缓存、并发或
  状态管理方案；
- 现有 Convolution sidecar 尚无孤儿回收 API；是否新增回收属于独立数据生命周期问题，不能
  混入 IR 错误弹窗修复，发现可复现泄漏后另行记录和批准。
