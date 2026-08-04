# 未来需求池：EqualizerAPO 配置导入与多文件 Include

> **状态**：仅记录想法与源码调研，未排期、未批准、未实现
> **使用方式**：未来从下列需求卡中选择范围，再建立正式 milestone/ADR；本文件本身不是实施计划

## 1. 背景

EqualizerAU 当前只运行一份 schema v7 原生配置，没有 EqualizerAPO parser、Include resolver、
导入预览或外部配置监听。未来可以把 EqualizerAPO 文本作为一次性导入来源，但原生 JSON 应继续
作为唯一可写事实来源，导入后仍需显式 Save。

2026-07-27 已读取本地 EqualizerAPO 的 `FilterEngine.cpp` 和 Preamp、Channel、GraphicEQ、
Convolution、Include factories，确认：

- 每行按第一个 `:` 分割；参考实现会静默忽略未知命令和多数解析失败；
- `Preamp` 接受逗号小数并用宽松 `swscanf` 解析；
- `Channel` 以空格拆分并大写，作用域影响后续效果；
- `GraphicEQ` 宽松提取数字对、丢弃孤立尾值并排序；
- Include 与 Convolution 相对路径以声明命令的文件目录为基准；
- Include 继承调用点 Channel，返回后恢复调用前 Channel；
- 参考 Include 只有 100 层深度限制，没有明确环诊断；
- 参考 Convolution 支持的格式多于 EqualizerAU 当前严格 WAV 契约。

这些是兼容事实，不代表应该复制其静默失败行为。

## 2. 可独立选择的需求卡

### APO-01：单文件解析与逐行诊断

解析空行、`#` 注释、Preamp、Channel 和 GraphicEQ；每个结果保留文件、行号和原文。未知命令、
尾随垃圾、非有限值、重复频率或超产品契约内容明确阻断，不静默忽略。无文件写入和 UI 依赖。

### APO-02：导入预览

选择根配置后展示规范化节点顺序、来源和全部 warning/error。存在阻断项时禁止确认，不提供
“忽略后继续”。取消预览不得修改草稿、sidecar 或音频状态。依赖 APO-01。

### APO-03：Preamp 与 GraphicEQ 草稿导入

把合法 Preamp 和 GraphicEQ 转为原生节点；GraphicEQ 域外正频率点按 M6 契约原样保存但不参与
20 Hz...20 kHz DSP。确认形成一个未保存草稿步骤，Undo 可完整恢复，仍需 Save。依赖 APO-01/02。

### APO-04：Channel 作用域导入

把 `Channel: all`、正整数和非空标识转换为 Channels 节点，保留命令顺序和后续作用域；不根据
当前设备声道数猜测或删除未解析标识。依赖 APO-01/02。

### APO-05：嵌套 Include 配置树

递归解析多文件：子文件继承调用点 Channel，返回后恢复外层 Channel；必要时生成恢复 Channels
节点。相对 Include/Convolution 路径以当前文件目录解析。使用当前递归栈检测环，允许同一文件在
退出调用栈后再次 Include。正式实施前需冻结深度、文件数和聚合字节预算。依赖 APO-01/04。

### APO-06：Convolution 无副作用检查

在预览阶段读取并验证 WAV 大小、格式、时长、采样率、声道和样本，但不写应用 IR 目录；不支持
的 FLAC/OGG 等格式明确报告。依赖现有 M1 WAV 契约，可独立于最终导入事务实施。

### APO-07：Convolution sidecar 批量事务

为所有 WAV 预分配 storage IDs，整批写入；任一写入或后续草稿替换失败时，只回滚本事务创建的
资源。当前 `importWAV` 是先持久化再新增节点且没有批量回滚，不能直接循环复用。需先建立 ADR、
失败恢复和 orphan 清理证据。依赖 APO-06。

### APO-08：整份配置原子替换

确认后默认替换当前节点草稿、保留 effectsEnabled，并形成一个 Undo step；active/saved chain 在
显式 Save 前不变。解析、容量、IR 或草稿失败时原草稿保持不变。依赖所选 parser 和资源需求。

### APO-09：EqualizerAPO 文本导出

把受支持节点导出为新的 APO 文本文件。它不改变运行配置，也不建立反向同步。需要先单独定义
Channels、域外 GraphicEQ 点、IR 文件复制和不支持节点的导出契约，不与导入默认捆绑。

### APO-10：外部文件持续链接与监听

让运行配置持续依赖 Include 文件并在文件变化时自动更新。该模式会绕过显式 Save、Undo/Redo、
generation 和单一事实来源，当前明确不建议。若未来确有需求，必须作为独立产品模型重新论证，
不能视为 APO-05 的自然延伸。

## 3. 推荐选择顺序

1. APO-01 + APO-02：先得到无副作用 parser 和预览；
2. APO-03 + APO-04 + APO-08：交付单文件基础导入；
3. APO-05：增加 EqualizerAPO 原生多文件 Include 语义；
4. APO-06 + APO-07：具备回滚后再导入 Convolution；
5. APO-09 或 APO-10 仅在出现独立用户需求时重新评估。

## 4. 不变约束

- schema v7 原生配置是唯一运行和持久化事实来源；
- EqualizerAPO 文件默认只是导入来源，修改后不会自动同步；
- 导入预览不写配置或 sidecar，不启动或重配音频；
- 不支持或损坏内容必须可定位，不复制参考实现的静默丢弃；
- 所有确认操作仍遵循草稿、Undo/Redo、显式 Save、4 MiB 配置预算和实时线程隔离。
