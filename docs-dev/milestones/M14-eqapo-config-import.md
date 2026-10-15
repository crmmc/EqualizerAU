# M14 EqualizerAPO 配置导入

- 状态：实现完成，全部门禁通过；**用户真实导入验收待完成**
- 决策：[`ADR-0024`](../adr/0024-eqapo-config-import.md)
- 产品需求：[`prd.md`](../prd.md) §7.10
- 任务：`.trellis/tasks/10-15-m14-eqapo-config-import/`

## 交付范围

- **解析器**（`M1EqualizerAPOConfigImporter`，Configuration/）：按 ADR-0024 覆盖矩阵
  解析六类映射指令 + Include 链（循环防护、深度 8、总量 4 MiB）；产出纯数据
  `M1APOConfigImportPlan`（节点、逐项问题、文件名、按类型计数、多 Device 段警告）；
  文件读取经可注入协议（磁盘实现带大小预检）；Filter/GraphicEQ 行解析复用
  `M1EqualizerAPOTextCodec`（仅提升可见性，行为零变化）。
- **会话操作**（`M1EditingSession`）：`importReplacing`（整链替换一步 Undo）、
  `importAppending`（链尾追加一步 Undo；链尾作用域非 all 且导入块无首个 Channel 行时
  自动补 Channels(all) 守卫）；应用后新节点成为选择。
- **控制器与 UI**：`M1ProductController.importEqualizerAPOConfiguration`（后台解析、
  硬失败走可见错误、成功停靠 pendingImport 快照字段）；预览 Sheet（摘要 + 逐项问题 +
  覆盖现有/末尾追加/取消三按钮）；菜单入口"导入EqualizerAPO配置…"；中英文本地化
  20 个新键。
- **零改动面**：schema 不变、Runtime ABI 不变、持久化格式不变、既有粘贴/保存语义不变。
- 不在本期：导出、Copy 声道混合节点、If 静态求值、IIR 裸系数、非 WAV 格式解码。

## 自动化证据（2026-10-15，本地 arm64）

- `make check` 通过：project/Plist lint、shell 语法、M1 隔离审计（新登记
  `M1EqualizerAPOConfigImporter.swift` 源 + `M1EqualizerAPOConfigImporterTests.swift`
  测试，两个 target 数组同步）、实时安全审计（不受影响，42 函数不变）、本地化一致性
  （新增 20 键均含 zh-Hans；动态 Text 审计基线登记 `kindName(kind`、
  `sourceLabel(issue`、`reason(issue.category`）。
- `make coverage` 通过：hostless 全套 **558 用例 0 失败**（2 例既有独占调度竞态跳过），
  核心逻辑覆盖率 ≥95% 门禁与 10/10 主功能路径通过；`M1EqualizerAPOConfigImporter.swift`
  单文件 92.29%（≥90% 关键文件线）。
- 新增测试：`M1EqualizerAPOConfigImporterTests` 22 例（六类指令映射与顺序、大小写与
  REW 槽位噪声、停用滤波行、REW 逗号小数、selective_delay 的 Copy 报告、逐类问题与
  行号、多 Device 段警告、未闭合 If 块、Include 链/循环/深度/不可读、Convolution 路径
  三分支、Filter 域违规、Preamp 夹紧、Delay 域与预算不拦截、Channel all/数字/空、
  512 点中止、无指令文件、主文件不可读、总量超限、磁盘读取器）、`M1EditingSessionTests`
  +5（替换一步 Undo、追加守卫三种情形、空列表 no-op）、`M1ProductControllerTests` +5
  （停靠计划不动草稿、硬失败可见错误、替换+Undo 恢复未保存编辑、追加守卫、取消）。
- App target（含 Sheet/菜单 UI 文件）构建通过（hostless 套件不编译 App UI，单独验证）。

## 待完成

- 用户真实导入验收：用真实 Windows 迁移配置（或 REW 导出 + 含 Include/Device/Copy 的
  配置）在 Release 构建上走完整流程——校验、弹窗逐项问题、覆盖与追加两个落点、
  Undo 回退、卷积路径复活（沿用"交互式音频结论只来自用户实际执行并报告的证据"约定）。
