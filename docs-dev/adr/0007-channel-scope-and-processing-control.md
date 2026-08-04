# ADR-0007：有序声道作用域与单一 Processing 控件

| 属性 | 内容 |
|---|---|
| 状态 | 已接受；M2 前置基础已实现 |
| 日期 | 2026-07-20 |
| 范围 | 原生配置节点模型、声道选择语义、主处理控件 |
| 产品需求 | [`prd.md`](../prd.md) |
| 配置决策 | [`0004-versioned-native-configuration-and-explicit-save.md`](0004-versioned-native-configuration-and-explicit-save.md) |

## 背景

M1 schema v1 把声道选择重复保存在每个 Preamp 上，界面也同时暴露 Start/Stop 与音效旁路。
Graphic EQ 会增加更多效果类型；继续复制声道字段会让作用域、复制粘贴和迁移语义随节点类型
扩散，同时两个主开关会让用户难以判断“透明 A/B”和“销毁系统音频路线”的区别。

EqualizerAPO 的 `Channel:` 指令本身不执行 DSP，而是为后续滤镜建立有序作用域。该模型适合
自由处理链，也能让未来 Graphic EQ 与 Preamp 使用同一套声道选择规则。

## 决策

1. 原生配置升级为 schema v2 的异构有序节点；当前支持 `channels` 和 `preamp`。
2. Channels 是非 DSP 控制节点。其选择从当前位置起作用，直到下一个 Channels 节点覆盖；
   链首缺省作用域是 `all`。
3. Preamp 等效果节点不在 v2 中保存独立声道字段，只展示当前继承的有效作用域。
4. schema v1 读取时，在有效声道选择变化处插入 Channels，保留全部原 Preamp UUID 和顺序。
   合成 Channels UUID 必须确定且不得与源配置任何 UUID 冲突；下一次显式 Save 才写出 v2。
5. 只复制效果节点时，粘贴后继承目标位置的作用域；连同 Channels 节点复制时保留显式作用域。
6. 主窗口只提供一个 Processing 控件：停止时开启会启动系统处理；运行中关闭只旁路效果，
   不销毁系统音频路线。真正的 Start/Stop 保留在高级 Audio 命令和恢复路径。
7. Processing 的显示值来自已应用 Runtime 状态，不从草稿推断。持久化或 Runtime 更新失败时
   不得把控件显示为已经成功切换。

## 理由

| 关注点 | 采用方案的收益 |
|---|---|
| 节点扩展 | Preamp、Graphic EQ 和后续效果共享同一有序作用域语义 |
| 可见顺序 | Channels 在链中的位置直接解释下游效果范围 |
| 迁移 | v1 的实际 DSP 选择可无损映射，Preamp 身份与顺序不变 |
| 剪贴板 | 是否携带作用域由是否复制 Channels 节点明确决定 |
| 用户控制 | 主界面只有一个处理总控，A/B 旁路不会触发路线重建 |
| 生命周期 | 高级 Start/Stop 仍可用于资源恢复和故障清理 |

## 备选方案

| 方案 | 不采用原因 |
|---|---|
| 每个效果继续保存 channels | 字段和编辑器随效果类型重复，复制后的作用域含义不清楚 |
| Channels 作为 DSP 节点 | 它只改变控制层编译作用域，不应增加实时工作或 Runtime ABI |
| Processing 关闭即 Stop | A/B 操作会重建 Tap/IO 路线，延迟和故障面不必要地扩大 |
| 隐藏真正的 Stop | 故障恢复和显式资源释放仍需要生命周期命令 |

## 后果

- Builder 必须按顺序遍历节点并维护当前声道作用域；Channels 本身不产生实时工作；
- 未解析声道诊断归属 Channels，并在同一作用域内去重；
- 编辑器必须使用通用节点外壳，类型专属参数只在展开区显示；
- schema v2 解码必须拒绝跨类型字段，不能静默丢弃错误数据；
- M2 引入 Graphic EQ 时仍需单独修订 Prepared/Runtime ABI，本 ADR 不决定频段或滤波算法。

## 重新评估条件

- 后续条件节点要求非线性或嵌套作用域；
- EqualizerAPO 导入证明其 Channel 语义无法映射到当前有序节点；
- 产品研究表明运行旁路与路线 Stop 必须成为同等级主控。
