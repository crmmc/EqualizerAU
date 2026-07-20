# ADR 0006：M1 独立实现，不复用 M0 产物

| 属性 | 内容 |
|---|---|
| 状态 | M1 已接受 |
| 日期 | 2026-07-19 |
| 范围 | M0 与 M1 的源码、测试、构建和证据边界 |
| 路线依据 | [`0001-native-process-tap-route.md`](0001-native-process-tap-route.md) |
| M1 计划 | [`M1-processing-chain-foundation.md`](../milestones/M1-processing-chain-foundation.md) |

## 背景

M0 是为验证 macOS 同设备原生 Process Tap 路线而构建的证明性实现。它包含固定增益、
实验入口、诊断探针、BlackHole 后备证明和针对短时可行性的生命周期代码。M0 的价值是
路线证据和失败经验，不是产品实现基础。

直接在 M0 代码上替换 DSP 或复用其桥接、状态机和测试，可以缩短早期开发时间，但会把
证明阶段的结构和假设带入 M1，也会让 M0 测试通过被误认为 M1 已重新证明产品合同。

## 决策

1. M1 独立编码自己的应用控制、配置、音频生命周期、实时桥接、DSP 和诊断实现。
2. M1 不得导入、链接、调用、复制或增量改造 M0 的源码、类型、C ABI、测试夹具、测试
   用例、生成文件或构建产物。
3. M0 只允许作为只读参考：系统 API 使用经验、已观测失败、路线选择理由、生命周期顺序、
   实时限制和人工证据可以指导 M1 设计。
4. M1 可以采用与 M0 相同的外部拓扑和行为约束，但必须在 M1 自有模块中重新实现，并由
   M1 自有测试、故障注入和人工验收重新证明。
5. M0 测试继续只证明 M0，不计入任何 M1 子里程碑的完成证据。M1 不以“原测试继续通过”
   代替独立验证。
6. M1 产品入口完成切换前，M0 保持只读参考；归档或删除 M0 产物属于单独、显式的清理
   决定，不在独立实现过程中边写边改。

### 物理落实边界

M1 在现有 `EqualizerAU.xcodeproj` 内使用独立 target 和物理目录，不把新文件加入 M0 target：

| Target | 产品与职责 | 允许的源码根 |
|---|---|---|
| `EqualizerAUM1Runtime` | 静态运行时库；Prepared 状态、实时处理、发布与引用记账 | `EqualizerAUM1Runtime/` |
| `EqualizerAUM1` | M1 应用宿主；SwiftUI、配置、Builder、Core Audio 与生命周期 | `EqualizerAUM1/` |
| `EqualizerAUM1RuntimeTests` | 不依赖应用宿主的 DSP、并发和实时边界测试 | `EqualizerAUM1RuntimeTests/` |
| `EqualizerAUM1Tests` | M1 应用控制、Builder、配置和界面模型测试 | `EqualizerAUM1Tests/` |
| `EqualizerAUM1IntegrationTests` | 不启动真实音频的 M1 HAL 集成测试 | `EqualizerAUM1IntegrationTests/` |

`EqualizerAUM1` 只链接 `EqualizerAUM1Runtime`，使用自己的 bridging header，并且 bridging
header 只导入 M1 自有 C 头。M1 target 不得依赖 M0 app、M0 test bundle、M0 bridging header、
M0 目录或 M0 构建产物。M0 与 M1 可以暂时存在于同一个 Xcode 工程，但 target membership、
依赖图、头文件搜索路径、链接参数、复制阶段和测试宿主必须隔离。

M1 实时 C ABI 使用 `EAUM1` 符号前缀、固定宽度 POD 和 opaque handle。Swift、Objective-C
对象、STL 类型、异常和所有权不明确的裸指针不得跨 ABI。具体函数集合由
[`M1.0 运行时内核`](../milestones/M1.0-runtime-kernel.md)约束。

## 理由

| 关注点 | 独立实现的收益 |
|---|---|
| 产品边界 | M1 不继承证明性 UI、固定 DSP 或后备路线耦合 |
| 测试可信度 | 每项 M1 合同都有针对新实现的证据，不借用 M0 通过结果 |
| 所有权 | M1 的类型、ABI、资源代次和清理协议从起点按产品需求设计 |
| 可审查性 | M0 保持稳定参考，M1 变更不会重写历史证据 |
| 迁移风险 | 产品切换是显式门槛，不会在同一路径上形成半 M0、半 M1 状态 |

## 备选方案

| 方案 | 不采用原因 |
|---|---|
| 在 M0 上逐步替换 DSP 和 UI | 证明性结构会成为隐式产品架构，边界难以审计 |
| 复用 M0 音频核心，只重写配置和界面 | 无法独立证明桥接、生命周期和失败所有权满足 M1 |
| 复制 M0 源码到 M1 后修改 | 仍然继承实现和缺陷，不属于独立编码 |
| 复用 M0 测试作为 M1 回归 | 测试绑定旧接口和假设，不能证明 M1 新合同 |
| 把 M1 源码加入现有 M0 app target | 会继承 target-wide M0 bridging header、模块和测试宿主，无法证明物理隔离 |
| 为 M1 新建独立 `.xcodeproj` | 隔离更强，但当前阶段增加 workspace、签名和双工程维护；独立 target 已能建立可审计边界 |

## 后果

- M1 初始开发量增加，需要重新建立 Core Audio 和实时数据面；
- M1.0 必须遵守已在子里程碑中锁定的自有模块、ABI、资源所有权和测试边界；
- 工程文件必须能通过静态审计证明 M0/M1 target membership 和依赖图没有交叉；
- 文档可以引用 M0 事实，但实现计划不得使用“复用、沿用、替换 M0 组件”表达交付；
- 产品切换前可能同时存在只读 M0 参考和未完成 M1 实现，但二者不得互相调用；
- M1 关闭时必须用 M1 证据独立证明原生路线、启停、清理和真实音频结果。

## 重新评估条件

本决策不因工期压力自动重开。只有产品负责人明确允许复用某一项 M0 产物，并为其边界、
测试可信度和迁移风险建立替代 ADR 时，才可逐项例外。
