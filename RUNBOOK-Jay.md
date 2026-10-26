# OpenLogi Flow 双机测试 (第 2 次) — Jay 操作步骤

**.9** = Alienware (Windows), **.8** = Mac mini。全程约 30–45 分钟。

## 先知道 (还没在真机验证过)
- 脚本还没在真 Windows / 真 Mac 上跑过。看到和下面不一样的东西: 输入 `abort` 回车, 把两份日志发给 GM。
- 安全弹窗 (SmartScreen、"仍要打开"、防火墙) 可能出现的时机不同, 也可能不出现。
- macOS 27 的设置菜单名字可能和下面略有不同。
- 结束后 Mac 的"本地网络"权限条目要你手动关掉 (第 9 步)。
- 托盘 "退出" Options+ 会不会连后台进程一起停, 没验证过; 不影响测试结果。
- Windows 上请用 `abort`, 不要用 Ctrl+C (Ctrl+C 不一定会恢复)。
- 测完请确认 Options+ 在两台上都正常; 不正常就跑第 8 步的恢复命令。

**别点 PowerShell 窗口里面** (点了会暂停输出; 如果点了, 按一下 Esc)。

**每一步的规则**: 屏幕停在一个 "GATE" 时, 做完就按 **回车**; `skip` = 跳过; `abort` = 结束并自动恢复。没有倒计时, 不用赶。

---

**0. 准备 (约 5 分钟)**
- 脚本由助手拷到两台机器, **需要你另外点头授权**。
- 使用对应 `openlogi-custom` 成功 Build run 的 run ID 和完整 head SHA；必须是本次要测的构建提交。启动命令显式填写 run ID/SHA，脚本会检查该 run 成功且 SHA 相符。手动下载的 zip 必须从同一 run 的 Artifacts 区下载；普通 zip 无法由脚本独立证明其来源。
- (只给 Windows 用) 如需脚本下载，建 PAT: 在 .9 浏览器打开 https://github.com/settings/personal-access-tokens/new → Token name `openlogi-hwtest-run2`, Expiration `7 days` → Repository access 选 **Only select repositories** → 选 **JayHome137/OpenLogi** → Permissions → **Actions: Read-only** → Generate token。
- (Mac 用) 在 **.8 浏览器**打开对应 Build run 的页面 → **Artifacts** → 下载 `OpenLogi-macos-dmg-arm64`。

**1. 预检 .9 (1 分钟)** — **关掉 Options+ 窗口；如果还卡在这里，右下角托盘里右键 Options+ 图标 > 退出。** 开始菜单搜 **Windows PowerShell** → 右键 **以管理员身份运行** → **是**。粘贴:
```
Set-ExecutionPolicy -Scope Process Bypass -Force; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Invoke-OpenLogiFlowTest.ps1" -Mode Preflight
```
最后一行绿色 `PREFLIGHT RESULT: OK` → 继续。红色 `BLOCKED` → 发给 GM, 停。窗口别关。

**2. 预检 .8 (1 分钟)** — Command+空格 输入 **终端** 回车。粘贴下面这行 (末尾有空格, 先别回车), 再把 **下载** 里的 **OpenLogi-macos-dmg-arm64** 拖进终端, 回车 (要输 Mac 密码, 不显示):
```
sudo /bin/bash /tmp/ol-hwtest/macos/run-openlogi-flow-test.sh --mode preflight --artifact 
```
`PREFLIGHT RESULT: OK` → 继续。看到 `!!! codesign ... NOT signed` → 停, 告诉 GM。窗口别关。

**3. 先启动 .9 (3–5 分钟)** — 将命令中的 `<run-id>` 和 `<40-char-sha>` 替换为本次 Build run 的实际值。**关掉 Options+ 窗口；如果还卡在这里，右下角托盘里右键 Options+ 图标 > 退出** (窗口还开着时脚本停在 GATE W0, 关好按回车)。在 .9 的管理员窗口粘贴:
```
Set-ExecutionPolicy -Scope Process Bypass -Force; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Invoke-OpenLogiFlowTest.ps1" -Mode Run -ArtifactRunId <run-id> -ExpectedSha <40-char-sha>
```
- 提示 PAT → 右键粘贴 (看不到字是正常的) → 回车。
- 如果出现蓝色 **Windows 已保护你的电脑**: 点 **更多信息** → **仍要运行**, 回窗口输入 `retry` 回车。
- 如果出现 **Windows 安全中心警报**: 只勾 **专用网络** → **允许访问**。**不要点"取消"**。
- 等到**绿色** `READY: listening on UDP 42424` → 去第 4 步。出现**红色 FAILED** → **不要启动 Mac**, 等 DONE, 发日志给 GM。

**4. 再启动 .8 (5–10 分钟)** — 将 `<run-id>`、`<40-char-sha>` 和 `<artifact-path>` 换成实际值，路径用双引号括起。然后在 .8 终端粘贴命令:
```
sudo /bin/bash /tmp/ol-hwtest/macos/run-openlogi-flow-test.sh --mode run --run-id <run-id> --expected-sha <40-char-sha> --artifact "<artifact-path>"
```
将 `<run-id>` 和 `<40-char-sha>` 替换为所选 Build run 的实际值；`<artifact-path>` 替换为从该 run 下载的 artifact zip 路径。脚本会在修改系统前核对 Build run 成功状态和 commit SHA。
- 如果弹 **"终端"想访问"下载"文件夹中的文件** → 点 **允许**。
- 问 "Windows 端准备好了吗?" → .9 是绿色 READY 就按回车。
- 如果弹 **无法打开 "OpenLogi"**: 点 **完成**。然后 苹果菜单 → **系统设置** → **隐私与安全性** → 拉到底 → **仍要打开** → 输密码 → **仍要打开**。回终端输入 `retry` 回车。
- 授权 (3–5 分钟): **系统设置** → **隐私与安全性** → 先点 **输入监控**, 再点 **辅助功能**, 各做一次:
  有 **OpenLogi Agent** 就打开开关; 没有就点 **+** → 按 **Command+Shift+G** → 粘贴
  `/Applications/OpenLogi.app/Contents/Library/LoginItems/OpenLogi Agent.app` → 回车 → **打开**。问"退出并重新打开"点 **稍后**。
  两项都做完 → 回终端输入 `restart` 回车。显示 `已允许 / 已允许` 后自动继续。
- 弹 **允许 "OpenLogi Agent" 查找本地网络上的设备** → **允许**。弹 **接受传入网络连接** → **允许**。
- 之后它自己连 .9, 不用按键 (每 10 秒试一次)。

**5. 核对 6 位码 (1–2 分钟)** — 两边窗口都会显示一个 6 位码 (如 `123 456`)。
一样: **.9 输入 `y` 回车, 再 .8 输入 `y` 回车**。不一样: 输入 `n` 回车, 然后两边按回车重试。要在 2 分钟内两边都确认。显示 **配对完成** 后自动继续。

**6. 鼠标跨屏与键盘跟随 (5–8 分钟)** — 用 Logitech 真鼠标:
.9 上光标往 **左边缘** 推 → 到 Mac; Mac 上往 **右边缘** 推 → 回 .9。每次可能要等 10–30 秒。**来回至少 3 次**。窗口里的计数会增加。做完两边各按 **回车**。
若键盘也连接到同一 Logitech 接收器/设备组，在两台分别打开文本输入框；每次鼠标切换后输入不同短文本，确认键盘输入跟随鼠标所在端，并反向重复。记录键盘型号、连接方式和结果；没有可配置键盘则标记未测。

**7. 等 DONE (1–2 分钟)** — 两边自动恢复 Options+。等到出现 **DONE** 再关窗口。
绿色 = 全部恢复好; 红色 = 有项目没恢复, 跑第 8 步。
把这两份日志发给 GM: `.9: C:\Users\<你>\OpenLogi-test-result.log`, `.8: /Users/jayboy137/OpenLogi-test-result.log`。

**8. 出问题时**
- 任何一步输入 `abort` 回车 → 自动恢复。**另一台也输入 `abort`**。
- 窗口被关了: 最多 20 分钟后会自动恢复。想马上恢复:
  - .9 (管理员 PowerShell): `Set-ExecutionPolicy -Scope Process Bypass -Force; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Emergency-Restore.ps1"`
  - .8 (终端): `sudo /bin/bash /tmp/ol-hwtest/macos/emergency-restore.sh`
  - .8 重启过 (`/tmp` 会被清空) 就用: `sudo /bin/bash "/Library/Application Support/OpenLogi-hwtest/suite/emergency-restore.sh"`

**9. 收尾 (5 分钟)**
- .8: 对照结果日志的测试前后权限快照，只移除本轮新增的 **输入监控**、**辅助功能**授权；**本地网络**也只关闭本轮新增的 OpenLogi Agent 条目。若无法确认某项是本轮新增，保留并报告，不要清除测试前已有授权。
- .8: **系统设置** → **网络** → **防火墙** → **选项…** → 只移除本次测试新出现的 OpenLogi Agent 规则；测试前已有规则保留。
- .8: **系统设置** → **通用** → **登录项与扩展** → 在列表里选中 **OpenLogi** 和 **bash** 的后台项目 → 点 **−** (或关掉开关)。
- .9: 脚本创建的规则名为 `OpenLogiHwTest-UDP-42424` 和 `OpenLogiHwTest-mDNS-5353`，正常恢复会自动删除；仅在 RESTORE SUMMARY 报未清除时，删除这两个精确名称且确认是本次测试新增的规则。不要删除所有名为 `openlogi-agent` 的规则。
- 两台都删掉拷进来的脚本文件夹: .9 `%LOCALAPPDATA%\Temp\ol-hwtest`, .8 终端 `sudo rm -rf /tmp/ol-hwtest`。
- GitHub: https://github.com/settings/personal-access-tokens → `openlogi-hwtest-run2` → **Delete**。

技术细节见 `README.md`。
