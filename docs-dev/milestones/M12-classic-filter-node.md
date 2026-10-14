# M12 经典滤波器节点

- 状态：实现完成，自动化验收通过；**用户真实音频验收待完成**
- 决策：[`ADR-0021`](../adr/0021-classic-filter-node.md)
- 产品需求：[`prd.md`](../prd.md) §7.6

## 交付范围

- 新增 `filter` 处理链节点：peaking、lowPass、highPass、bandPass、lowShelf、highShelf、
  notch、allPass 八类；参数 = 类型 + 中心频率（1–20 000 Hz）+ 增益（±24 dB，仅增益类类型）
  + Q/带宽倍频程/搁架斜率 + 搁架转角/中心频点含义（PRD 7.6 / ADR-0021）。
- 创建时落盘参考默认值（低/高/带通 Q 0.707；搁架 10.8 dB/oct 转角；陷波 Q 30）；参数语义
  逐条对照本地 EqualizerAPO 参考实现（`BiQuadFilterFactory.cpp` / `BiQuad.cpp` /
  `BiQuadFilter.cpp`）。
- 配置 schema v8 → v9（`M1ConfigurationSnapshot.schemaVersion`）与剪贴板 envelope 同步升版；
  v8 及更早配置无损加载，v9 前文档中的 filter 负载显式拒绝。
- 编译链：`M1BiquadFilterDesign` 控制线程按输出采样率生成 RBJ 系数 → 预校验有限性/稳定性
  （镜像 Runtime `isStableBiquad`）→ 按 Channels 作用域逐通道发布 `EAUM1PreparedStageBiquad`；
  运行时零新增 DSP 路径，双槽切换与诊断语义复用。
- 有效频率 ≥ Nyquist 或系数被拒：该节点不生成 stage，产生节点归属旁路诊断
  （`M1ProcessingBuildDiagnostics.filterBypasses`），行内警告图标与 diagnostics snapshot 均可见。
- UI：添加菜单"Filter"入口、行内类型选择/频率/增益/宽度编辑器、搁架转角/中心切换、
  中英文本地化（`EqualizerAUM1/Resources/Localizable.xcstrings`）。
- ⌘V 文本回退解析 `GraphicEQ:` 与 `Filter:` 行（`M1EqualizerAPOTextCodec`），保持行序建节点；
  非法/域外行计数可见（`pastedTextPartialImport`），`Filter:` 行上限 512
  （`pastedFilterLineLimitExceeded`）；私有 JSON 优先级不变。

## 有意偏差（相对参考实现）

| 行为 | 参考实现 | 本项目 |
|---|---|---|
| 解析失败 | 日志后静默跳过 | 丢弃但计数可见 |
| `1.000` 千位分隔 | 重读为 1000 | 按 1.0 解析 |
| 类型别名匹配 | 大小写敏感 | 大小写不敏感 |
| 参数域 | 无界 | Fc/增益/Q/带宽/斜率显式域 |
| 非增益类型带 Gain | Trace 忽略 | 编译忽略 + 粘贴报告计数 |

## 自动化证据（2026-10-13，本地 arm64）

- `make check` 通过：project/Plist lint、shell 语法、M1 隔离审计（含新增源文件登记）、
  实时安全审计、本地化一致性（新增键均含 zh-Hans）。
- `make coverage` 通过：`EqualizerAUM1RuntimeTests` 460+ 用例 0 失败，核心生产逻辑覆盖率
  **95.07%**（≥95% 门禁），10/10 主功能路径测试通过。
- 新增测试：`M1BiquadFilterDesignTests`（每类型关键频点响应 parity、默认值表、转角换算、
  域校验、防御守卫、Builder 接线与旁路诊断）、`M1EqualizerAPOTextCodecTests`（别名归一、
  默认值、垃圾数字回退、域外/非法行计数、行数上限、混合行序）、`M1FilterEditingTests`
  （会话 add/set/gesture 合并/Undo、envelope v9 round-trip、v8 配置与 envelope 兼容）、
  控制器与 AppModel 粘贴/新增命令测试。
- 既有测试同步：schema 版本预期 8 → 9、不支持的 schema 预期 9 → 10。

## 待完成

- 用户真实音频验收：在真实输出设备上创建各类滤波器并确认可听行为与预期一致
  （沿用 M11 的"交互式音频结论只来自用户实际执行并报告的证据"约定）。
