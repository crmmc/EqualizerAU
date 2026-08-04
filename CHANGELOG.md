# Changelog

本文件记录 EqualizerAU 所有面向用户的显著变化。

格式约定（维护者与 Agent 共同遵守）：

- 基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。
- 未发布的变化写在 `## [Unreleased]` 下，分类小节只用 `### Added` / `### Changed` / `### Fixed` / `### Removed`。
- 发布时把 `[Unreleased]` 内容移动到 `## [x.y.z] - YYYY-MM-DD` 小节（版本号不带 `v` 前缀），并清空 `[Unreleased]`。
- Release 流水线按 tag 提取对应版本小节作为 Release Notes：tag `v0.1.0` 必须存在 `## [0.1.0]` 小节，缺失则发布失败。

## [Unreleased]

### Changed

- Graphic EQ FIR 长度随输出采样率缩放（ADR-0020）：`N(Fs) = 16384 × 2^max(0, ceil(log2(Fs/48000)))`，≤48 kHz 保持 16,384 taps，96 kHz→32,768，192 kHz→65,536，高采样率频率分辨率不低于 48 kHz 基准。
- 卷积 IR 性能下降橙色警告门限由 8 秒上调至 30 秒（依据 2026-08-04 M1 Release dense probe；常见长 IR 不再误报）。

## [0.1.0] - 2026-08-04

### Added

- 首个开源技术预览：原生 Process Tap 全局音频处理，无需虚拟音频驱动。
- 前置放大、任意点图形均衡器（编译为 16,384 taps 最小相位 FIR）、外部 WAV 卷积脉冲响应（源路径引用，不复制文件）。
- 按声道组织、排序、复制和启用处理器节点，显式保存后生效。
- Dock 与菜单栏控制，English / 简体中文即时切换。
- arm64 ad-hoc 签名 ZIP，附 SHA-256 校验文件；最低系统 macOS 14.2；技术预览边界见 README「立即使用」。
