# ADR 0010：有界系统音频生命周期恢复

- 状态：Accepted
- 日期：2026-07-21

## 背景

默认输出、设备格式、sleep/wake 和 Core Audio 服务变化会使运行路线失效。临时
`AudioObjectID` 还可能在服务重建后被复用。恢复不能改变显式 Save、Start、Stop 或 Quit 的
语义，也不能因事件风暴形成无界重启。

## 决策

1. 独立 monitor 监听 system object、当前默认输出属性和 sleep/wake，不创建音频资源。
2. 默认输出监听身份由 `AudioObjectID` 与持久 device UID 共同确定；Tap/Aggregate 销毁前也
   必须复核各自持久 UID。
3. 产品层仅在先前存在运行意图时自动恢复。每批最多三次，退避为 250 ms、1 s；恢复中的
   事件合并为一次后继恢复，预算耗尽后等待显式 Start 或新的明确定义事件。
4. generation token 覆盖 Start、output-layout 读取、退避、sleep、Stop 和 Quit。失效操作不得
   发布 running 投影，也不得停止后继代次拥有的路线。
5. sleep 只停止，wake 才恢复。捕获权限拒绝不自动重试，并展示系统设置入口。
6. monitor 重绑定在新监听完整注册后才移除旧监听；同 numeric ID、不同 UID 必须重绑。重绑
   失败有界重试，耗尽后向产品层报告明确状态。

## 后果

- 配置提交和运行恢复保持独立，系统事件不会隐式保存草稿。
- 事件风暴和持续故障不会形成无界 stop/start 循环。
- unknown-identity 资源宁可保留 cleanup ownership，也不会仅凭复用的临时 ID 销毁对象。
- 真实设备、权限、sleep 和 Core Audio 服务验收仍必须在签名应用中人工执行。
