# EqualizerAU Agent 工作指南

本文只规定长期有效的仓库工作方式，不重复产品需求、架构、ADR 或里程碑历史。

## 阅读顺序

```mermaid
flowchart LR
    A[README.md] --> B[docs-dev/prd.md]
    B --> C[docs-dev/architecture.md]
    C --> D[相关 ADR]
    D --> E[相关测试]
```

1. 从 [`README.md`](README.md) 获取入口和命令。
2. 从 [`docs-dev/prd.md`](docs-dev/prd.md) 确认产品需求。
3. 修改音频生命周期或 DSP 前阅读 [`docs-dev/architecture.md`](docs-dev/architecture.md)。
4. 阅读相关 [`docs-dev/adr/`](docs-dev/adr/) 了解决策约束。
5. 阅读相关测试；测试是可执行的行为契约。

## 本地参考项目

| 项目 | 工作区路径 | 简介与参考范围 |
|---|---|---|
| EqualizerAPO | [`../EqualizerAPO/`](../EqualizerAPO/) | Windows 系统级均衡器。涉及 EqualizerAPO 配置兼容时，以其本地解析器、滤镜、编辑器和文档源码核对术语、取值与 DSP 行为；Windows APO 路由不直接移植到本项目。 |
| Resonance | [`../resonance/`](../resonance/) | 跨平台系统级均衡器和音频效果引擎，在 macOS 使用 Core Audio Process Tap，并支持 EqualizerAPO 配置导入。用于参考原生 macOS 路线、实时处理链和配置互操作，不作为本项目行为契约。 |

参考项目前先阅读其本地源码，不以网络镜像代替当前工作区版本。参考项目不能覆盖本项目的
PRD、架构、ADR 或测试契约；采用不同设计时，以本项目已记录的约束为准。

规划 EqualizerAPO 对齐范围内的产品术语和编辑行为时，若本地 EqualizerAPO 已有明确
实现，先直接采用并同步到本项目契约，不把同一行为再次作为产品选择题。只有参考实现
没有对应行为，或其行为与 macOS 平台规范、本项目实时安全、数据完整性或既有 ADR
发生冲突时，才提出单独决策；冲突及有意差异必须写明原因。

## 仓库结构

| 路径 | 职责 |
|---|---|
| `EqualizerAU/App/` | SwiftUI 与 `AppModel` |
| `EqualizerAU/Audio/` | Core Audio 控制层和 Swift 生命周期 |
| `EqualizerAU/Audio/AudioIOBridge.*` | Objective-C++ 实时桥接与 DSP 边界 |
| `EqualizerAUTests/` | 单元测试、失败注入和确定性竞态测试 |
| `EqualizerAUIntegrationTests/` | 不启动音频的真实 HAL 测试 |
| `EqualizerAUM1Runtime/` | M1 独立 C++ 实时静态库与 `EAUM1` C ABI |
| `EqualizerAUM1/` | M1 独立 macOS 应用宿主、控制层与资源 |
| `EqualizerAUM1RuntimeTests/` | 不加载应用宿主的 M1 Runtime 测试 |
| `EqualizerAUM1Tests/` | M1 app hosted 单元测试 |
| `EqualizerAUM1IntegrationTests/` | M1 hosted、默认不启动音频的集成测试 |
| `docs-dev/` | PRD、架构、ADR 和里程碑 |

## 构建与测试

```bash
xcodebuild \
  -project EqualizerAU.xcodeproj \
  -scheme EqualizerAU \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  test
```

元数据检查：

```bash
plutil -lint EqualizerAU.xcodeproj/project.pbxproj EqualizerAU/Resources/Info.plist
codesign --verify --deep --strict .build/DerivedData/Build/Products/Debug/EqualizerAU.app
```

M1 独立工程边界与无音频构建：

```bash
./scripts/verify-m1-isolation.sh

xcodebuild \
  -project EqualizerAU.xcodeproj \
  -scheme EqualizerAUM1 \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/M1DerivedData \
  build-for-testing CODE_SIGNING_ALLOWED=NO
```

## 不可破坏的约束

```mermaid
flowchart LR
    A[创建并启动捕获] --> B[创建并启动输出]
    B --> C[运行]
    C --> D[停止并销毁输出]
    D --> E[停止并销毁捕获]
    E --> F[销毁 Aggregate]
    F --> G[销毁 Process Tap]
```

- 除非新 ADR 明确批准，原生路线保持单应用进程。
- 必须保持捕获先行：先创建并启动捕获，再创建并启动输出。
- 生产 Tap 必须绑定设备、采用排他模式、排除本进程并使用 `.muted`。
- 不得擅自改用 BlackHole 或要求安装驱动。
- 不得使用 `sudo`、修改 `/Library`、重启 `coreaudiod` 或自动改变真实系统路由。
- 未经用户明确许可，不得启动或控制 GUI，也不得启动真实音频。
- 不得跨发现代次持久化临时 `AudioObjectID`。
- 必须保留所有权令牌和依赖感知清理语义。
- 小型实验不得无依据增加 helper、daemon、IPC、SRC、监控器或恢复框架。
- M0 的源码、类型、桥接 ABI、测试夹具、测试用例和构建产物只允许作为只读参考，不得
  被 M1 导入、链接、调用、复制或改造成 M1 实现。M1 必须独立编码并用自己的测试重新
  证明所采用的路线、生命周期、实时和失败语义；M0 测试通过不能计作 M1 证据。

## 实时规则

音频捕获和渲染回调只能使用预分配内存、原子操作、有界循环和有界内存复制。

| 回调内禁止事项 | 原因 |
|---|---|
| 分配内存或扩容容器 | 延迟不可控 |
| 锁、信号量、actor 跳转、等待或休眠 | 可能阻塞实时线程 |
| 日志、字符串格式化和错误对象构造 | 可能分配并阻塞 |
| 文件、网络、数据库和配置 I/O | 延迟不可控 |
| 动态创建 DSP、FFT 或滤波器结构 | 工作量和内存行为不可控 |

所有分配和校验必须在对象发布给实时回调前由控制层完成。运行中可以在非实时线程
预构建新对象，但不得原地修改回调正在使用的对象；旧对象只能在确认无在途回调引用
后回收。

## 修改纪律

- 选择能回答当前产品问题的最小改动。
- 行为变化必须更新测试，不在文档中复制全部测试细节。
- 当前实现变化只更新 `architecture.md`。
- 重要决策变化应新增或替代 ADR。
- 阶段证据和结果只更新对应里程碑文档。
- `prd.md` 不得包含实现方案或测试历史。
- 生命周期、共享桥接或路线变化先跑聚焦测试，再跑完整测试。

## 文档版本管理

- 本项目的开发文档属于正式仓库资产，允许纳入 Git 提交，包括 `README.md`、PRD、架构、ADR、
  里程碑以及项目级 `AGENTS.md`。
- 文档必须遵守唯一事实所有者和提交范围；与当前实现无关的后续阶段规划应使用独立提交，
  不与源码修复混杂。
- 面向用户的变化按 `CHANGELOG.md` 头部约定写入 `[Unreleased]` 节；发布版本小节由 CI 按 tag
  提取为 Release Notes，版本号与日期在发布时落定。

## 发布流水线

两条 GitHub Actions 流水线，均不使用 Developer ID、不公证，产物仅为 arm64 ad-hoc 签名：

- `.github/workflows/ci.yml`：push 到 `main` 或 PR 触发，执行 project/Plist lint、shell 语法检查和
  `EqualizerAUM1RuntimeTests` 全量（`CODE_SIGNING_ALLOWED=NO`）。CI 只跑 hostless 套件，与 M7 自动化
  门禁口径一致；hosted 套件需启动 GUI 宿主，属于本地签名验收，runner 上启动不稳定，不纳入 CI。
  实时竞态压力测试 `testTenThousandPublicationsRaceARealCallbackThreadWithoutLeaks` 依赖独占调度，
  共享 runner 上偶发超时，CI 跳过，本地完整验证仍执行。
- `.github/workflows/release.yml`：推送 `v*` tag 触发，`test` job 先复跑同一套测试，通过后 `release`
  job 调用 `scripts/package-adhoc-preview.zsh` 打包，从 `CHANGELOG.md` 提取对应版本小节作为 notes，
  产出 **draft** Release（ZIP + `.sha256`），由用户审阅后手动发布。

发布操作约定：

1. 版本号三处必须一致：tag（`v0.1.0`）、`project.pbxproj` 的 `MARKETING_VERSION`（`0.1.0`）、
   `CHANGELOG.md` 版本小节（`[0.1.0]`，不带 `v`）。`CURRENT_PROJECT_VERSION` 必须保持 `1`，与打包
   脚本 `EXPECTED_BUILD` 默认值一致。
2. 发布前把 `CHANGELOG.md` 的 `[Unreleased]` 内容移入新版本小节并写日期；tag 无对应小节则流水线
   发布失败。格式契约见 `CHANGELOG.md` 头部。
3. 发布只通过推送 tag 触发流水线完成，不从本地产出或手动上传发布物；本地打包脚本仅用于验证。
4. tag、push 等变更线上仓库的操作必须先获得用户明确授权。

## 完成标准

- 目标行为已实现，失败后的资源所有权仍然明确。
- 相关聚焦测试和完整测试通过。
- 实时回调约束未被破坏。
- 应用元数据或构建产物变化时完成签名和 Plist 检查。
- 文档只更新其唯一事实所有者，不复制当前状态。
- 交互式音频结论只来自用户实际执行并报告的证据。
