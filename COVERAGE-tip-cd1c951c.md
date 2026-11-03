# 产品 tip 生产语义覆盖

对照源：`feat/twindesk-mvp1-edge` @ `cd1c951cb0a2b8d33971b8cf2f87907dfa100221`，只读。该 tip 相对 `origin/openlogi-custom` 的增量包括 `handoff/sender.rs` 的 `accept_then_switch` 重排，以及 detector/geometry 测试。下表区分产品实现、hwtest 离线证据和仍需真机/授权夹具的验证；离线日志与模拟事件不是硬件证据。

| 行为/边界 | 产品 tip / 自动化覆盖 | hwtest 覆盖与状态 |
| --- | --- | --- |
| Accept-before-ChangeHost | tip 的 `accept_then_switch` 在有效 Accept 完整验证后才调用 switch；Rust 单元测试覆盖有效 Accept、Reject、2s request timeout、错 transfer ID、arm timeout 为 0 或超过 40s。 | H05、H06；离线 parser 验证事件分类，不验证真实协议时序。stock Build 无完整 Accept/ChangeHost trace；授权协议/HID trace 或可重复故障夹具缺失时 **阻塞真机**。 |
| timeout / arm / arrival ack | sender request timeout 2s；receiver arm timeout 30s；sender 在本地 switch 后等待 peer arm timeout + 2s slack，最大 42s。非法 arm 值不执行 switch。 | H05、H06；RUNBOOK 分开描述 request timeout、receiver Timeout/Partial、sender arrival-ack timeout。延迟/丢包需授权夹具；超时不一概等于未切换。**未由本 hwtest 离线测试验证协议行为**。 |
| geometry / detector | tip 增加 geometry 与 edge detector 单元测试，覆盖产品内共享边、布局及 crossing 判定。精确阈值属于产品单元测试责任。 | H03、H04；人工检查同一主机共享边、多屏错位/间隙/重叠布局，以及 dwell/cooldown/rearm/modifier 可见行为。Linux 离线套件不能驱动真实显示布局或鼠标。**阻塞真机**。 |
| switch 失败清理 | `accept_then_switch` 返回 switch 结果；sender 的失败路径发 SwitchFailed cancel 并清理 outgoing handoff。 | H07；日志事件可分类，但不能证明内部 outgoing 清理或 receiver pending 取消。需要授权、可重复的 ChangeHost 故障夹具及状态观测；缺少时 **阻塞真机**。 |
| 跨机 handoff 成功 | 产品实现通过 Logitech HID++ ChangeHost 使目标设备切换，并有 sender/receiver terminal event。 | H02 要求真 Logitech 鼠标双向至少 3 个不同 transfer 的 sender outcome=1、receiver outcome=1 且 `arrived=requested>0`，并人工确认设备实际切换。合成 fixtures 只测解析；**未实测，阻塞真机**。 |
| 产品边界 | 本测试只以 Logitech HID++ ChangeHost 和物理设备 host slot 切换为通过依据。 | 不接受软件 KVM、远程桌面、SendInput/CGEvent 注入、光标预定位或其他厂商设备作为通过证据。H08 键盘需是可配置的 Logitech ChangeHost 设备，否则记录 blocked/未测。 |

## 用例入口

`handoff-cases.json` 固定 8 个案例；Windows 和 macOS Run 都逐项要求 `pass`、`blocked` 或 `fail` 人工裁定。`pass` 只记为 `PASS-MANUAL`，且 H02 还要求两方向各至少 3 个不同成功 transfer；脚本不会自动给出整体通过结论。空日志、重复 transfer、失败 outcome、无效时间戳不会算作 Arrived。`tests/agent-events.log` 是显式标记的合成 parser fixture。

用例索引：H01 设备与映射；H02 外露边成功往返；H03 共享边与 geometry；H04 dwell/cooldown/rearm/modifier；H05 Accept-before-ChangeHost；H06 timeout/arm/arrival ack；H07 switch 失败清理；H08 键盘跟随。

`tools/test-handoff-contract.py` 检查 fixture、case manifest、allowlist 固定哈希、源 tip 漂移 guard 与日志边界。可设置 `OPENLOGI_SOURCE_TREE=/workspace/OpenLogi-mvp1-edge` 执行可选源代码对照；它仍不替代 Rust 单元测试或真机。

## 授权边界

离线实现与文档已准备；Jay 另行授权前，不得向 `.8` / `.9` 拷贝或运行脚本，不 SSH，不做 Windows PowerShell 5.1 parse-only，不改设备或 Flow 配置，不停止/卸载 Options+。完成真机验收前，仍建议等待真机结果后再合并产品 PR #16。
