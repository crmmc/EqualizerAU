# ADR-0024：EqualizerAPO 完整配置导入

- 状态：Accepted
- 日期：2026-10-15
- 范围：控制层解析器、编辑会话导入操作、预览弹窗与菜单入口、本地化
- 关联：ADR-0004、ADR-0013、ADR-0021、ADR-0022；PRD §7.7、§7.10
- 用户已确认决策（2026-10-15 brainstorm）：覆盖矩阵（D1）、"先校验→逐项弹窗→三选一"
  流程（D2/D3）、Convolution 路径策略（D4）、M14 不做导出（D5）

## 背景

EqualizerAPO 的配置是按行组织的 `Command: Parameters` 文本（本地解析器分发表共 17 条
指令：Preamp、Filter（含 IIR 裸系数变体）、Delay、Copy、GraphicEQ、Convolution、
Include、Device、Channel、Stage、If/ElseIf/Else/EndIf、Eval、LoudnessCorrection、
VSTPlugin）。Windows 用户迁移到本项目时，已有两条行级粘贴入口（`GraphicEQ:` M6、
`Filter:` M12），但整套配置文件（含 Include 链、Channel 作用域结构）无法一次迁移。
PRD §3.2 长期目标"评估 EqualizerAPO 配置的部分导入"、§12 挂起"导入范围"决策。

指令与本项目能力对照（结论：真缺的音频能力只有 Copy；Windows 专属管道永不移植）：

| 档 | 指令 | 处理 |
|---|---|---|
| 有等价节点 | Preamp、Filter、Delay、GraphicEQ、Convolution、Channel | 映射导入 |
| 真缺音频能力 | Copy（声道混合/虚拟声道）、Filter IIR（裸系数） | 跳过 + 报告 |
| Windows 专属 | Device、Stage、readReg、VSTPlugin | 跳过 + 报告 |
| 配置脚本 | If 块、Eval/内联表达式 | 跳过 + 报告 |
| 语义不同 | LoudnessCorrection（两搁架近似 vs 本项目 ISO 226） | 跳过 + 报告 |

## 决策

1. **覆盖矩阵（D1）**：六类指令映射到既有节点类型，零 schema、零 Runtime ABI 改动：
   - `Preamp: x dB` → Preamp 节点（夹紧 ±100 dB）；多条求和交给既有契约。
   - `Filter N: ON <Type> …` → Filter 节点，复用 `M1EqualizerAPOTextCodec` 的行解析
     （单一事实源，与粘贴共享全部别名/斜率/带宽/夹紧语义）；`OFF <Type> 参数` →
     停用节点；`ON/OFF None` 空槽为 REW 导出噪声，静默跳过。
   - `GraphicEQ:` → GraphicEQ 节点（±24 夹紧、域外点丢弃、单行 >512 点整次中止）。
   - `Delay: x ms / n samples` → Delay 节点，双单位原样保留；超预算值不拦截，
     由既有分代旁路诊断呈现。
   - `Channel: 缩写/数字/all` → Channels 节点；`M1ChannelIdentifier` 的大写规范化 +
     数字序号 + 自定义标签与 APO 语义直映射，缺失声道走既有非阻塞警告。
   - `Convolution: path` → Convolution 节点；相对路径按导入文件目录解析，Unix 绝对
     路径原样使用，Windows 绝对路径按原样保留为源路径（`URL(fileURLWithPath:)` 会把
     盘符路径当相对路径拼上工作目录，故不经 URL 转换）+ 问题项标注，用户可改路径复活
     （走 M8 缺失旁路契约）；非 WAV 扩展名标注"格式可能不受支持"，不硬拒。
   - `Include:` 相对所在文件目录跟随加载，深度上限 3 层（主文件之外最多三层
     Include，2026-10-15 用户拍板）；不可读/超深/Windows 路径 →
     `includeFailure` 问题项后继续（问题归属发起 Include 的文件与行号）。**同一文件只
     加载一次**：循环包含（A→B→A）与菱形包含（两个文件各包含同一公共文件）统一按
     "已包含过，跳过重复包含"（`includeDuplicate`）报告——参考实现没有去重、菱形
     公共文件会复制两份；本项目是扁平单层处理链，全局去重 + 深度上限 + 节点总量上限
     把层级包含图约束为有界展开，不复制、不为深层级适配（2026-10-15 用户拍板）。     导入 + Include 展开总文本量 ≤ 4 MiB（磁盘读取器在加载前先查文件大小）。
     **作用域归位**：进入 Include 前记住当前作用域，返回后若被内层文件改变则补发一
     个 Channels 节点恢复到记住的值（对齐参考实现 FilterEngine 的 save/restore；
     恢复到外层值，不是统一 all）。Windows 路径判定为盘符前缀 `^[A-Za-z]:[\\/]` 或
     UNC `\\…`，裸冒号是合法 macOS 文件名不作 Windows 处理。
   - 磁盘读取编码：严格 UTF-8 优先，失败后 Latin-1 容错重读（对齐参考实现 UTF-8 →
     CP_ACP 回退；Latin-1 与 CP1252 仅 0x80–0x9F 区有差，配置文件该区罕见）。
   - `Device:`/`Stage:` 不做段落门控：段内其余指令照常导入；`Device:` 行计数 >1 时
     预览弹窗显著警告"多设备段已全部导入"。理由：保信息量，删除多余段比重新输入容易，
     比猜测保留哪一段诚实。
   - `If` 块整体跳过（嵌套合并为一条问题项，注明起始行与行数），不做静态求值；
     `Eval`、含反引号内联表达式的映射指令行 → 表达式问题项。
   - 非 Command 格式行（REW 导出头部等）静默忽略，与参考解析器一致。
2. **导入流程（D2/D3，用户设计）**：菜单入口"导入EqualizerAPO配置…"→ 选文件后
   **先整体校验，全程不动草稿** → 硬失败（不可读、无可识别指令、超总量、单行超 512 点、
   生成草稿超 4 MiB）直接报错不弹窗；成功则弹**预览弹窗**（导入摘要：按类型节点数 +
   停用数；逐项问题：文件名+行号+指令+原因分类；多 Device 段警告）→ 用户三选一：
   **覆盖现有**（整链草稿替换为一步 Undo）/ **末尾追加**（链尾追加为一步 Undo）/
   **取消**。
3. **追加的作用域守卫**：导入块自带首个 `Channel:` 行时不加守卫；否则若现有链尾有效
   作用域非 all，自动补一个 `Channels(all)` 节点，保持源配置的隐式 all 语义（判定在
   `M1EditingSession.importAppending` 内部完成，链语义归会话所有）。
4. **落点语义**：应用后新导入节点成为当前选择（对齐粘贴契约）；音效总开关、Save、
   Undo/Redo、复制粘贴语义全部不变；导入结果只是草稿，APO 文本不成为可写事实来源
   （PRD §7.7）。
5. **导出（D5）**：不纳入 M14；响度节点无 APO 等价物、声道标签反向映射等导出特有
   失真问题留待独立小里程碑。
6. **可扩展性**：覆盖矩阵是数据不是结构——后续 Copy 声道混合节点等能力落地后，解析器
   增加对应行映射即可扩大覆盖（与 M12→M13 行粘贴的递进方式一致）。
7. **Filter 行数上限**：导入路径沿用粘贴的 `maximumFilterLines`（512）整次中止契约，
   超限抛 `filterLineLimitExceeded` 并映射为可见错误。**节点总量上限**：导入计划节点
   总数 ≤ `maximumNodeCount`（64，2026-10-15 用户拍板），超出整次中止——扁平单层
   处理链的容量边界，
   深层级包含图不做适配。
8. **有意偏差补充**（2026-10-15 两轮审查后固化）：`Preamp`/`Delay` 行按"恰好两个
   token + 空格分隔"解析，比参考实现的流式前缀匹配更严（如 `Preamp: 6dB` 无空格
   形式报 invalidLine 而非接受）——方向是可见报告而非静默丢失；孤立
   `Else`/`ElseIf`/`EndIf` 行报 invalidLine（参考实现静默忽略）；命令匹配大小写
   不敏感（参考实现区分大小写，宽松方向无损）；裸 `Filter:` 空参数/仅状态词行静默
   跳过（粘贴路径同类行计入 ignored 报告，口径差异已知）；`Channel: ALL L` 混写报
   invalidLine（参考实现等效全选，极罕见）；`C:file.txt` 盘符相对路径按 Unix 相对
   路径处理（极罕见）。

## 考虑过的替代方案

- **活引用 Include 节点**：在链上保留一个指向外部 APO 配置文件、每次生效时重新解析的
  节点（技术上可行，M8 卷积外部路径是先例）。否决：会让无法在应用内编辑的外部文本
  持续决定声音，违反 PRD §7.7"APO 文本不作事实来源"的契约；需要 schema 升版与运行时
  准备链改造，属独立里程碑级工作；其解决的"外部工具持续再生 APO 配置需要同步"场景
  小众。一次性导入摊平已覆盖迁移主场景。

## 后果

- 解析器为纯控制层代码（`M1EqualizerAPOConfigImporter` + 可注入文件读取协议），全部
  可 hostless 测试；预览弹窗状态独立于 PendingApplication 持久化机制。
- 粘贴与导入共享同一套 Filter/GraphicEQ 行解析，语义不会漂移。
- 依赖 If/Eval/Copy 的配置（如 selective_delay.txt）迁移后行为不等价，但弹窗逐项可见，
  不静默丢失。

## 验证

- `M1EqualizerAPOConfigImporterTests` 30 例、`M1EditingSessionTests` 导入 5 例、
  `M1ProductControllerTests` 导入 6 例、`M1AppModelTests` 导入 1 例；全套 hostless
  569 例 0 失败。
- `make check`（含本地化一致性 + 隔离审计 + 实时审计）与 `make coverage` 门禁通过
  （导入器单文件 94.51%）。
