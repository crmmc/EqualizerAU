# M7：开源技术预览发布

> **当前状态**：许可证、来源审计和打包流程已完成；路径泄漏修复待提交，Release 性能重放与用户验收待完成
> **前置条件**：M6 已完成并关闭

## 1. 目标

生成与公开源码对应、可验证且可重放构建的 EqualizerAU `0.1.0` arm64 技术预览。发布不加入
Apple Developer Program，不使用 Developer ID，不提交 notarization，也不进入 Mac App Store。

## 2. 发布契约

- 项目许可证为 `GPL-3.0-or-later`，仓库包含完整许可证和必要上游归属；
- 同时提供对应源码 commit、arm64 Release ZIP 和 SHA-256；
- 应用只使用免费的 ad-hoc 签名满足 Apple Silicon 代码完整性要求，不声明开发者身份；
- 用户按 Apple 官方逐应用流程在“隐私与安全性”中选择“仍要打开”；
- 不要求用户全局关闭 Gatekeeper，不推荐 `spctl --master-disable`；
- 原生 schema v8 配置仍是唯一运行与持久化事实来源；
- 首版版本为 `0.1.0 (1)`，最低系统为 macOS 14.2，bundle identifier 保持
  `com.ruimingchen.EqualizerAU`。

## 3. 明确非目标

- Developer ID Application、Apple notarization、Mac App Store 和付费 Apple Developer Program；
- DMG/PKG、自动更新、登录启动和非默认输出设备选择；
- 菜单栏入口不纳入 M7 的实现范围，由后续 [`M9`](./M9-menu-bar-i18n.md) 独立实现和验收；
- 若 M9 在 M7 最终 ZIP 前完成，M7 必须从包含已验收 M9 的最新干净 commit 重新打包，不得发布旧候选或回退 M9；
- x86_64/Universal 构建及 Intel Mac 兼容承诺；
- 在本阶段加入新的 DSP、编辑器或系统音频生命周期能力；
- 创建 tag、推送仓库、上传二进制或公开发布页面。

## 4. 实施顺序

1. 审计 EqualizerAPO、算法和其他可能上游来源，冻结版权与许可证归属；
2. 增加 GPL-3.0-or-later `LICENSE` 和 `THIRD_PARTY_NOTICES.md`；
3. 统一 Info.plist 与 build settings 的版本来源；
4. 增加可重放的 arm64 Release、ad-hoc 签名、ZIP 和 SHA-256 打包脚本；
5. 运行完整自动化、静态门禁、Release 性能和产物结构检查；
6. 由用户使用最终 ZIP 完成 Gatekeeper、权限、GUI、真实音频和覆盖升级验收；
7. 回填证据后关闭 M7。公开发布仍需用户另行明确授权。

## 5. 自动化门禁

- 完整 `EqualizerAUM1RuntimeTests` 零失败，性能夹具只允许按设计默认跳过；
- 5-target isolation、29-function realtime audit、project/Plist lint、C++ 严格编译、shell syntax 和
  `git diff --check` 全部通过；
- M6 Release 性能重放无明显回退；
- 产物只有 arm64，不包含测试 bundle、非系统动态依赖、证书、密钥或本机路径；
- ad-hoc `codesign --verify --deep --strict` 通过，且不得误报为 Developer ID 或 notarized；
- ZIP 的 SHA-256 可重复计算并与发布记录一致。

## 6. 用户验收

用户必须从最终 ZIP 解压并移动到 `/Applications`，然后确认：

1. 首次阻止后可通过“系统设置 → 隐私与安全性 → 仍要打开”逐应用授权；
2. 系统音频捕获权限可申请，Start/Stop 和退出后原声恢复正常；
3. Preamp、Graphic EQ、Convolution、Save 和重启恢复正常；
4. 覆盖安装同版本候选后 schema v8 配置与外部 Convolution 源路径保留，必要的系统权限行为有真实记录；
5. 用户知晓该产物未经 Apple 识别开发者签名或恶意软件公证。

GUI、权限和真实音频结论只采用用户实际操作后报告的结果。

## 7. 退出条件

- provenance 审计无未解决的许可证冲突或来源缺口；
- LICENSE、上游归属、源码构建说明、未签名风险说明和 SHA-256 验证说明完整；
- Release ZIP 可从干净构建目录重放生成并通过全部自动化门禁；
- 用户完成最终 ZIP 的安装、权限、GUI、真实音频和覆盖升级验收；
- 文档明确这是无 Developer ID、未 notarize 的 arm64 开源技术预览，而非 Gatekeeper 认证发行版。

## 8. 当前证据

- 2026-07-28 完成定向 provenance 审计：minimum-phase FIR、对数频率插值和 CSV parser 明确
  归属 EqualizerAPO GPL-2.0-or-later；Runtime FFT/convolution、WAV、SRC 和 Core Audio 未发现
  复制的第三方实现，未发现与 GPL-3.0-or-later 冲突的纳入代码；
- GNU 官方 GPLv3 完整文本已写入 `LICENSE`，EqualizerAPO 来源、RBJ 算法参考和未纳入依赖边界
  已写入 `THIRD_PARTY_NOTICES.md`；
- `scripts/package-adhoc-preview.zsh` 从独立 DerivedData 构建 arm64 Release，显式禁用 Xcode 签名，
  再应用 ad-hoc Hardened Runtime 签名；版本、bundle identifier、最低系统、架构、动态依赖、测试
  bundle 泄漏、ZIP 往返签名和 SHA-256 检查均通过；
- 最新完整 `EqualizerAUM1RuntimeTests` 执行 321 项，其中 2 个性能夹具按设计跳过，其余零失败；
  5-target isolation、29-function realtime audit、project/Plist lint、两份 C++ 严格编译、全部 zsh
  syntax 和 `git diff --check` 通过；
- 独占执行的 5 次 arm64 Release ABI v3 重放中，1/2/4/8 声道 stable_ratio 中位数分别为
  `0.02283/0.04306/0.09122/0.17921`，各档 transition 最高分别为
  `0.03148/0.09000/0.10040/0.20502`，与 M6 基线同量级；
- 2026-07-29 首次从干净 `54118b6` 重放成功，但字节级扫描发现 Release 可执行文件泄漏本机源码和
  DerivedData 绝对路径，因此该 ZIP 已废弃，未交付验收；
- `scripts/package-adhoc-preview.zsh` 已在 ad-hoc 签名前增加 `strip -S`，并在签名、许可证和
  `SOURCE_COMMIT.txt` 组装后扫描整个 payload 的本机源码路径。dirty 验证包路径命中为 0，大小
  777868 bytes，SHA-256 为
  `e7c7cd1d0cf75a18d23ff21b652aab8fed2a5d0466031d967da13c70ac29234f`，签名仍为
  `Signature=adhoc`、`TeamIdentifier=not set` 和 `flags=adhoc,runtime`；
- 当前脚本与本文有未提交改动，验证包 `SOURCE_COMMIT.txt` 正确标记 `54118b6-dirty`，不得发布或用于
  Gatekeeper/TCC 验收。最终仍需提交修复、从新干净 commit 重放、在低负载环境重放 Release 性能，
  再由用户完成 ZIP 安装、权限、GUI、真实音频和覆盖升级验收。
