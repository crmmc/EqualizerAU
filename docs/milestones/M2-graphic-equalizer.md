# M2：Graphic EQ

> **当前状态**：M2 前置配置与界面基础已完成；Graphic EQ DSP 尚未开始

## 1. 目标

M2 在已经关闭的 M1 原生路线、可靠持久化和安全发布基础上，引入可实时调整的 Graphic EQ。
频段、滤波器、状态发布和数值验收必须在实现前形成独立契约；不能把 M1 只承载每声道净增益
的 Prepared ABI 误当成通用非交换 DSP 链。

## 2. 已完成的前置基础

- 配置升级为 schema v2 的异构有序节点，当前包含 Channels 和 Preamp；
- v1 per-Preamp 声道选择可确定、无 UUID 冲突地迁移为 Channels 作用域；
- Builder 按可见顺序解析作用域，Channels 不增加实时工作，诊断归属作用域节点；
- typed 剪贴板、历史、移动和 Option-copy 支持异构节点；
- 主界面使用通用可展开节点行，并以一个 Processing 控件统一启动和运行旁路；
- Save 位于主工具栏左侧，普通 footer 不再显示内部 `clean`，实时诊断移入高级 Audio 菜单；
- 真正的 Start/Stop、键盘重排和诊断能力仍保留为高级或可访问命令。

## 3. 前置验证证据

- 五 target 无签名 `build-for-testing` 通过，未运行 hosted bundle；
- schema、Builder、编辑会话和产品控制器定向 hostless 测试 85 项通过；
- 覆盖 v1 迁移确定性与 UUID 冲突、严格 v2 字段、作用域重置和未解析诊断归属/去重、
  Channels 剪贴板、错误节点类型编辑，以及 Processing 的持久化和 Runtime 失败投影；
- 未启动 GUI、真实音频、Tap、Aggregate、设备 IO 或系统路由。

## 4. Graphic EQ 实施前门槛

1. 确定首版频段数、中心频率、增益范围和直接输入行为；
2. 用 ADR 明确滤波器类型、系数生成、采样率变化和参数平滑；
3. 修订 Prepared/Runtime ABI，使有序非交换节点具有明确所有权、发布和退休语义；
4. 定义全零透明、参考频响误差、运行中调参和数值边界的自动化门槛；
5. 证明实时工作有固定上界，系数和处理结构在控制线程预构建。

## 5. 非目标

- 本前置阶段不实现 Graphic EQ DSP，不决定 10/15/31 频段；
- 不改变 Core Audio 路线、Tap/Aggregate 生命周期或实时诊断 ABI；
- 不删除高级 Start/Stop、键盘重排或诊断能力；
- 不进行最终视觉主题润色或真实音频验收。
