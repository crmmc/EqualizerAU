# M4：MVP 稳定化

> **当前状态**：hostless 实现完成；等待签名发布、hosted GUI 与真实系统音频验收

## 1. 目标

M4 使已运行的系统音频路线面对设备、格式、sleep/wake、权限和 Core Audio 服务变化时，
能够有界恢复或进入明确可操作状态，同时保持资源所有权和显式配置语义。

## 2. 已实现范围

- system/default-output/device-property 与 sleep/wake 生命周期监听；
- 默认设备 `(AudioObjectID, persistent UID)` 联合身份及事务式、有界监听重绑；
- 最多三次的 stop/re-discover/start 恢复、退避、事件合并和显式 Stop/Quit 取消；
- sleep 期间禁止启动、wake 单次恢复、捕获权限错误分类与系统设置入口；
- Tap/Aggregate 销毁前持久 UID 复核、临时 ID 复用保护和 unknown-identity ownership；
- recovering、waiting、sleeping、permission 与 monitoring failure 产品状态。

决策理由见 [`ADR 0010`](../adr/0010-bounded-audio-lifecycle-recovery.md)。

## 3. 自动化证据

- 产品与资源聚焦故障注入测试 75 项通过；
- 覆盖 route/service 变化、sleep/wake、权限、三次预算、退避中 Stop、恢复事件合并、
  blocked Start/layout 与 Stop/sleep 交错、persistent UID 复用和 unknown identity；
- `EqualizerAUM1` app target 无签名构建通过；
- 完整 hostless `EqualizerAUM1RuntimeTests` 共 235 项通过，零失败；
- realtime audit 29 个显式函数、五 target isolation、独立 C++ `-Wall -Wextra -Werror`、
  Plist/project/scheme、shell syntax 和 diff whitespace 门禁通过。

## 4. 待验收边界

- 未启动 hosted tests、GUI、真实音频、Tap、Aggregate、device IO 或系统路由；
- 尚需签名应用验证首次/撤销捕获权限及设置入口；
- 尚需真实设备验证默认输出切换、拔插、采样率/布局变化、sleep/wake 和 `coreaudiod` 恢复；
- 尚需完成正式签名、notarization、安装/升级与发布包验收；
- M2/M3 的 hosted GUI 与真实音频验收仍独立保留。
