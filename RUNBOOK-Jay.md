# OpenLogi Flow 双机实测 第 2 次 — Jay 操作手册

编辑日期: 2026-10-20 (Asia/Shanghai, UTC+8)。build: Actions run **39235760610** / commit **bd04518f**, 端口 **42424**。
机器: **.9 = Jay-Alienware (Windows 11)**, **.8 = Mac mini (macOS 27, 用户 jayboy137)**。布局: **Mac 在 Alienware 左边**。

---

## ⚠️ 未验证风险 (先读这一段)

下面这些在离线环境里**无法验证**, 第一次真跑时可能和描述不一样。遇到不一样: 不要硬做, 输入 `abort` 回车(脚本会自动恢复), 把结果日志发给 GM。

1. **真正的 Windows PowerShell 5.1 没有跑过**。只在 Linux 的 pwsh 7.4 + PSScriptAnalyzer(5.1 兼容规则) + Pester 里测过。第 3 步的"只解析"检查需要你**另外授权**才能在 Alienware 上跑。
2. **macOS 的 /bin/bash 3.2 只在 Linux 上自编译的 bash 3.2.57 里测过**; macOS 的 `launchctl / tccutil / ps / PlistBuddy / socketfilterfw` 全部是模拟数据。
3. **Windows Options+ 的进程路径** (`C:\Program Files\LogiOptionsPlus\...`, `C:\Program Files\Logi\LogiPluginService\...`) 是推断的。路径不一致时脚本**拒绝开始**(什么都不改), 预检会显示 MISMATCH。
4. Windows 上**没有已知的 Logitech 计划任务**; 脚本不禁用任何计划任务。第 1 次运行误禁用的 `\Microsoft\Windows\PushToInstall\LoginCheck` 只有在你加 `-RepairLoginCheck` 时才会被重新启用(见第 2 步)。
5. Mac 上 Options+ 界面的 bundle id (`com.logi.optionsplus`)、OpenLogi 的登录项标签 `org.openlogi.agent.service` 的行为没有在真机上确认。
6. macOS 27 的系统设置**菜单名称可能和本手册略有不同**(本手册按 macOS 14/15 的中文界面写)。
7. Windows 防火墙/SmartScreen 弹窗是否出现、出现在什么时候, 未验证。
8. `tccutil reset` 能否删掉 OpenLogi 的权限条目未验证; **"本地网络"条目脚本删不掉**, 需要你手动处理(见第 12 步)。
9. Windows 上按 Ctrl+C 后脚本的 `finally` 恢复是否一定会执行: 按 PowerShell 5.1 文档会执行, 但未在真机验证。**推荐用 `abort` 而不是 Ctrl+C。**
10. 看门狗(lease)的计划任务 / LaunchDaemon 未在真机验证; 第 1 次运行时看门狗也没有被真正触发过。
11. Mac 需要能用 `python3`(第 1 次运行看起来是有的)。如果没有 Command Line Tools, 脚本会在**改动任何东西之前**停下并提示 `xcode-select --install`。
12. OpenLogi 本身: QUIC 在 42424 端口上能否穿过两台机器的防火墙、`flow pair-start` 默认端口, 都只在源码里看过, 没有真机验证。

---

## 0. 总览 (大约 30–45 分钟)

| # | 机器 | 做什么 | 约耗时 |
|---|------|--------|--------|
| 1 | 浏览器(任意机器) | 建一个只读 GitHub PAT | 3 分钟 |
| 2 | **两台** | 把脚本放到两台机器上 (**需要你另外授权助手, 或你自己拷**) | 5 分钟 |
| 3 | .9 (可选) | 只解析检查 (不执行任何代码) — **需要你另外授权** | 1 分钟 |
| 4 | .9 然后 .8 | 预检 (只读, 什么都不改) | 各 1 分钟 |
| 5 | **.9 先** | 启动 Windows 脚本, 等绿色 **READY** | 3–5 分钟 |
| 6 | **.8 后** | 启动 Mac 脚本, 做 Mac 的授权 | 5–10 分钟 |
| 7 | 两台 | 核对 6 位配对码 (SAS) | 1–2 分钟 |
| 8 | 两台 | 用真鼠标来回跨屏, 然后两边各按回车 | 3–5 分钟 |
| 9 | 两台 | 等自动恢复, 出现 DONE | 1–2 分钟 |
| 10 | 两台 | 看结果日志 | 5 分钟 |
| 11 | — | 出问题: abort / 紧急恢复 | — |
| 12 | 两台 | 清理测试留下的权限/防火墙条目 | 5 分钟 |

**规则(所有"关卡 GATE"都一样)**: 没有倒计时。每个关卡等你:
- **回车** = 我做完了/继续 (如果脚本能自动检查, 没满足会显示"还没满足"并继续等);
- `skip` 回车 = 跳过这一步继续;
- `abort` 回车 = 结束测试并**自动恢复** Options+;
- 有的关卡还有 `retry` / `restart` / `y` / `n`, 屏幕上会写。

每个关卡都会显示一行 **"看门狗租约剩余 X 分钟 / 硬上限剩余 Y 分钟"**:
- **租约**(默认 20 分钟): 脚本活着时**每分钟自动续租**, 所以你在一个关卡停多久都没关系。只有脚本崩溃/卡死超过 20 分钟, 看门狗才会自动恢复 Options+。
- **硬上限**(默认 120 分钟): 从开始算起 2 小时, 无论如何都会恢复。快到时请尽快结束。

---

## 1. 建 GitHub PAT (浏览器, 约 3 分钟)

只用来下载 build artifact。**不要**把它写进任何文件或命令行。

1. 浏览器打开 https://github.com/settings/personal-access-tokens/new (登录 JayHome137)。
   页面路径: 右上角头像 → **Settings** → 左侧最下面 **Developer settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**。
2. **Token name**: `openlogi-hwtest-run2`; **Expiration**: `7 days`。
3. **Resource owner**: `JayHome137`。
4. **Repository access**: 选 **Only select repositories** → 下拉选 **JayHome137/OpenLogi** (只选这一个)。
5. **Permissions** → **Repository permissions** → **Actions** → 选 **Read-only**。(Metadata: Read-only 会自动加上。) **其它全部保持 No access。**
6. 点页面底部 **Generate token** → 复制 `github_pat_...`。先放在剪贴板, 第 5、6 步各粘贴一次。
7. 测完以后(第 12 步)在同一页面把它 **Delete**。

> 不想用 PAT 也可以: 浏览器打开 https://github.com/JayHome137/OpenLogi/actions/runs/39235760610 , 在 Artifacts 里手动下载 `OpenLogi-windows-x86_64` (Windows) 和 `OpenLogi-macos-dmg-arm64` (Mac), 然后启动命令里加 `-ArtifactZip <路径>` / `--artifact <路径>`。

---

## 2. 把脚本放到两台机器上 (约 5 分钟) — **需要另外授权**

助手**没有**权限碰你的电脑。拷贝这一步要么你自己做, 要么你**单独明确授权**助手去做。目标位置(和第 1 次一样):

| 机器 | 位置 | 内容 |
|------|------|------|
| .9 Alienware | `%LOCALAPPDATA%\Temp\ol-hwtest\` | 整个文件夹: `allowlist.json`, `windows\`, `macos\`, `tools\` |
| .8 Mac mini | `/tmp/ol-hwtest/` | 同样整个文件夹 (`/tmp` 重启后会清空, 重启过就重新拷) |

**`allowlist.json` 必须在 `windows\` / `macos\` 的上一级**, 否则脚本拒绝运行。

### 第 1 次运行留下的东西
第 4 步的预检会告诉你。已知可能有:
- **.9**: `LoginCheck` 计划任务被第 1 次运行**误禁用**。预检里 `task:\Microsoft\Windows\PushToInstall\LoginCheck` 那一行显示 `Disabled  <-- run-1 damage?` 时, 在第 4 步之后执行一次:
  `& "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Emergency-Restore.ps1" -RepairLoginCheck`
  (**请先确认: 第 1 次运行之前 LoginCheck 是启用的吗?** 不确定就先不加 `-RepairLoginCheck`, 告诉 GM。)
- **.8**: launchd 环境变量 `OPENLOGI_LOG` 残留。预检显示 `<-- run-1 leftover` 时执行:
  `sudo /bin/bash /tmp/ol-hwtest/macos/emergency-restore.sh`
- 任一台预检显示 `leftover state ... YES`: 先跑该机器的紧急恢复(第 11 步), 再继续。

---

## 3. (可选, 需要另外授权) Windows PowerShell 5.1 只解析检查 — .9, 约 1 分钟

只**解析**脚本语法, **不执行**脚本里的任何代码, 不需要管理员。在 Alienware: 开始菜单搜 **Windows PowerShell** (蓝色图标, 不是 PowerShell 7) → 打开 → 粘贴:

```powershell
cd "$env:LOCALAPPDATA\Temp\ol-hwtest\windows"; powershell.exe -NoProfile -ExecutionPolicy Bypass -File ..\tools\Test-PsParse.ps1 HwTest.Common.ps1 Invoke-OpenLogiFlowTest.ps1 Watchdog.ps1 Emergency-Restore.ps1 UserSide.ps1
```

屏幕应显示 `PSVersion=5.1.xxxxx Edition=Desktop`, 每个文件 `errors=0`, 最后 `TOTAL_ERRORS=0`。不是 0 → 把输出发给 GM, 不要继续。

---

## 4. 预检 (只读, 什么都不改)

### 4a. .9 Alienware (约 1 分钟)
1. 开始菜单搜 **Windows PowerShell** → 右键 → **以管理员身份运行** → 用户账户控制弹窗点 **是**。
2. 粘贴并回车:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Invoke-OpenLogiFlowTest.ps1" -Mode Preflight
   ```
3. 屏幕会列出: 服务 `OptionsPlusUpdaterService`、Options+ 进程和**完整路径**、LoginCheck 状态、防火墙规则、残留状态。
4. 最后一行 `PREFLIGHT RESULT: OK` → 继续。`BLOCKED` (退出码 4) → 截图/复制发给 GM, **不要继续**。
5. **这个管理员窗口不要关**, 第 5 步继续用。

### 4b. .8 Mac mini (约 1 分钟)
1. Mac 屏幕: **访达** → **应用程序** → **实用工具** → **终端** (或 Command+空格 输入"终端"回车)。
2. 粘贴并回车 (会要 Mac 登录密码, 输入时不显示):
   ```bash
   sudo /bin/bash /tmp/ol-hwtest/macos/run-openlogi-flow-test.sh --mode preflight
   ```
3. 屏幕会列出: python3 版本、allowlist 里的 launchd 任务(loaded/absent)、Options+ 进程路径、`OPENLOGI_LOG`、防火墙状态、到 192.168.1.9 是否能 ping 通(Windows 常屏蔽 ping, ping 不通**不是**错误)。
4. `PREFLIGHT RESULT: OK` → 继续。`BLOCKED` → 发给 GM, 不要继续。终端窗口不要关。

---

## 5. 启动 Windows (先!) — .9, 约 3–5 分钟

在第 4a 步那个**管理员** Windows PowerShell 窗口粘贴并回车:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Invoke-OpenLogiFlowTest.ps1" -Mode Run
```

1. 提示 `粘贴 GitHub PAT 后回车 (输入不显示...)` → **右键粘贴** PAT(看不到字是正常的) → 回车。这时还**什么都没改**。
2. 黄色横幅 "Windows 端已开始。在本窗口出现绿色 READY 之前, 不要启动 Mac 端脚本。"
3. 脚本自动: 快照 → 装看门狗 → 下载解压 OpenLogi → 停 Options+ → 加 2 条防火墙规则 → 启动 openlogi-agent。(1–3 分钟)
4. **可能出现 GATE W1** (agent 没起来, 多半是 SmartScreen): 在 Alienware 屏幕找蓝色窗口 **"Windows 已保护你的电脑"** → 点 **更多信息** → 点 **仍要运行** → 回到 PowerShell 输入 `retry` 回车。
5. **可能出现防火墙弹窗 "Windows 安全中心警报"**: 只勾 **专用网络**, 点 **允许访问**。**不要点"取消"** (取消会生成"阻止"规则, Flow 就连不上了)。这会留下条目, 第 12 步删除。
6. 出现**绿色横幅** `READY: listening on UDP 42424 (Windows / Jay-Alienware 192.168.1.9)` → **去 Mac 做第 6 步**。Windows 窗口进入 **GATE W2 等待 Mac 发起配对**, 会自己等, **不用按键** (监听窗口每 120 秒自动续开)。
7. 如果出现**红色横幅 FAILED**: **不要启动 Mac 脚本**。Windows 窗口会自动恢复并显示 DONE。把 `C:\Users\<你>\OpenLogi-test-result.log` 发给 GM。

---

## 6. 启动 Mac (后!) — .8, 约 5–10 分钟

在 Mac 的终端窗口粘贴并回车:

```bash
sudo /bin/bash /tmp/ol-hwtest/macos/run-openlogi-flow-test.sh --mode run
```

1. **GATE M0 "Windows 端准备好了吗?"** (这时 Mac 还什么都没改): 看 Alienware 窗口是绿色 READY → 在 Mac 终端按**回车**。是红色 FAILED → 输入 `abort` 回车。
2. 提示 `粘贴 GitHub PAT 后回车 (输入不显示)` → Command+V → 回车。
3. 脚本自动: 快照 → 装看门狗(LaunchDaemon) → 下载 → 停 Options+ → 安装 `/Applications/OpenLogi.app` → 启动 OpenLogi。(1–3 分钟)
4. **可能出现 GATE M1** (macOS 拦截未签名程序):
   - 弹窗 **"无法打开 “OpenLogi”"** → 点 **完成** (**不要**点"移到废纸篓")。
   - 屏幕左上角 苹果菜单 → **系统设置** → 左栏 **隐私与安全性** → 右边滚到最下面 **安全性** 一栏 → 看到 **已阻止 “OpenLogi…” 以保护 Mac** → 点 **仍要打开** → 输入 Mac 密码 → 弹窗再点 **仍要打开**。
   - 回终端输入 `retry` 回车。(约 1–2 分钟)
5. **GATE M2 授权 (输入监控 + 辅助功能)** (约 3–5 分钟): 苹果菜单 → **系统设置** → **隐私与安全性**, 下面两项**各做一次**:
   - 点 **输入监控** (第二次点 **辅助功能**)。
   - 列表里有 **OpenLogi Agent** → 打开它右边的开关 (要密码或指纹)。
   - 列表里没有 → 点列表下面的 **+** → 弹出选文件窗口后按 **Command+Shift+G** → 粘贴下面这一行 → 回车 → 点 **打开**:
     `/Applications/OpenLogi.app/Contents/Library/LoginItems/OpenLogi Agent.app`
   - 弹窗问 **退出并重新打开** → 点 **稍后**。
   - 两项都做完 → 回终端输入 `restart` 回车。状态行变成 `辅助功能=已允许  输入监控=已允许` 就**自动继续**。
6. **GATE M3 连接 Windows 并发起配对**: 自动的, 每 10 秒对 `192.168.1.9:42424` 发起一次, **不用按键**。
   - 弹窗 **允许 “OpenLogi Agent” 查找并连接到本地网络上的设备?** → 点 **允许**。(以前点过"不允许": 系统设置 → 隐私与安全性 → **本地网络** → 打开 OpenLogi Agent 的开关。)
   - Mac 防火墙如果弹窗 **是否要允许应用程序 “openlogi-agent” 接受传入网络连接?** → 点 **允许**。
   - 连了 10 分钟还没连上, 状态行会提示你去看 Windows 窗口: 还是 READY 就继续等; 是 FAILED 就输入 `abort` 回车。

---

## 7. 核对配对码 SAS (两台, 约 1–2 分钟)

连上后**两边同时**出现关卡: Windows **GATE W3**, Mac **GATE M4**, 标题里有 6 位码 (例如 `123 456`)。

1. 比较 Alienware 窗口和 Mac 终端里的 6 位码。
2. **一模一样** → 在 Alienware 窗口输入 `y` 回车, **再**在 Mac 终端输入 `y` 回车(两边都要)。
3. **不一样** → 任一边输入 `n` 回车 (拒绝), 出现 W3b / M4b 后两边都按回车重试。
4. 状态行显示 `本机已确认=... 对方已确认=...`; 两边都确认后显示 **配对完成** 并自动继续。
5. 配对码出现后要在 **120 秒内**两边都确认, 超时会进 W3b / M4b: 两边按回车重试即可。

---

## 8. 真鼠标来回跨屏 (两台, 约 3–5 分钟)

两边出现 **GATE W4 / GATE M5 "用真鼠标来回跨屏"**。用 **Logitech 真鼠标**(不要触控板/别的鼠标):

1. 在 **Alienware** 上把光标一直往 **左边缘** 推 → 光标应出现在 **Mac** 屏幕上 (蓝牙切换常要 **10–30 秒**)。
2. 在 **Mac** 上把光标一直往 **右边缘** 推 → 回到 **Alienware**。
3. **至少来回 3 次**。每 5 秒状态行更新次数, 例如 `Alienware->Mac 完成 2 次 | Mac->Alienware 到达 1 次 | 失败/忽略 0 次`。
4. 做完: 在 **Alienware 窗口按回车**, 在 **Mac 终端按回车**。

---

## 9. 等恢复完成 (两台, 约 1–2 分钟)

两边自动: 关 OpenLogi → 删测试文件 → 删防火墙规则 → 恢复 Options+ (服务/进程/界面恢复到测试前状态; 测试前 Options+ 界面没开就不打开) → 卸看门狗 → 对比快照。

- **绿色 DONE** = 恢复全部成功 + 状态对比 PASS。
- **红色 DONE** = 有某项没恢复好。看上面的 `RESTORE SUMMARY`, 每行 OK / FAIL / LEFTOVER。可以再跑一次第 11 步的紧急恢复(重复跑是安全的)。
- 等 DONE 出现以后再关窗口。

---

## 10. 看结果 (约 5 分钟)

| 机器 | 结果日志 (测完唯一应留下的测试文件) |
|------|------|
| .9 | `C:\Users\<你>\OpenLogi-test-result.log` |
| .8 | `/Users/jayboy137/OpenLogi-test-result.log` |

在日志里找:
- `READY: listening on UDP 42424`、`PAIRED with peer name: ...` — 握手和配对成功了;
- `TIMING` / `CROSSING DURATION (...): NNN ms` — 每次跨屏用时(发送端从推到边缘到交接完成);
- `RECEIVER arrival` — 接收端收到;
- `RESTORE SUMMARY` — 每项恢复结果; `LEFTOVER` — 需要你手动清理的(第 12 步);
- `DIFF RESULT: PASS/FAIL` — 测试前后状态对比;
- `[GATE]` 行 — 你在每个关卡输入了什么、几点。

把**两份日志**发给 GM。

---

## 11. 中止 和 紧急恢复

- **正常中止**: 在任一关卡输入 `abort` 回车。该机器会自动恢复并显示 DONE。**另一台也输入 `abort`**。
- **Ctrl+C**: 也会触发恢复 (Mac 确定; Windows 按文档会, 未验证)。恢复过程中**不要再按 Ctrl+C**, 也不要关窗口。
- **窗口被关掉 / 机器卡死**: 看门狗会在租约到期(最多 20 分钟后)或硬上限(2 小时)时自动恢复。不想等就手动紧急恢复:

**.9 Alienware** (管理员 Windows PowerShell):
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Emergency-Restore.ps1"
```
(也可以: `...\Invoke-OpenLogiFlowTest.ps1 -Mode Restore`。如果脚本目录已经被删: `& "$env:ProgramData\OpenLogi-hwtest\suite\Emergency-Restore.ps1"`。)

**.8 Mac mini** (终端):
```bash
sudo /bin/bash /tmp/ol-hwtest/macos/emergency-restore.sh
```
(如果 `/tmp/ol-hwtest` 没了: `sudo /bin/bash "/Library/Application Support/OpenLogi-hwtest/suite/emergency-restore.sh"`。)

紧急恢复**只**动 `allowlist.json` 里列出的东西; 最后显示汇总, 退出码 0 = 全部成功, 3 = 有失败项。

---

## 12. 测完以后的清理 (约 5 分钟)

脚本删不掉、需要你手动处理的条目:

**.8 Mac mini**
1. 苹果菜单 → 系统设置 → 隐私与安全性 → **输入监控**: 选中 **OpenLogi Agent** (以及 OpenLogi) → 点列表下面的 **−**。
2. 同样处理 **辅助功能**。(脚本会先尝试 `tccutil reset`, 已经没了就跳过。)
3. **本地网络**: 这里没有 "−" 按钮, 把 **OpenLogi Agent** 的开关**关掉**即可。(App 已经删除, 条目通常会自己消失; 未验证。)
4. 防火墙(如果第 6 步点过允许): 系统设置 → **网络** → **防火墙** → **选项…** → 选中 **openlogi-agent** → 点 **−** → **好**。

**.9 Alienware**
5. 如果第 5 步点过防火墙弹窗的"允许访问": 开始菜单搜 **高级安全 Windows Defender 防火墙** (或运行 `wf.msc`) → 左边 **入站规则** → 找名称为 **openlogi-agent** 的规则(通常 TCP、UDP 各一条) → 右键 **删除**。
   (脚本自己加的 `OpenLogiHwTest-UDP-42424` / `OpenLogiHwTest-mDNS-5353` 会自动删除。)

**GitHub**
6. 回到 https://github.com/settings/personal-access-tokens → `openlogi-hwtest-run2` → **Delete**。

**脚本文件夹** (可选): 删掉 `.9: %LOCALAPPDATA%\Temp\ol-hwtest` 和 `.8: /tmp/ol-hwtest`。

---

## 13. 第 1 次运行发生了什么, 这次改了什么

**第 1 次运行的问题**
- Windows 脚本在 PowerShell 5.1 严格模式下崩溃: 只有 1 个进程时 `.Count` 不存在 → 恢复中途也会崩。
- Windows 把 `\Microsoft\Windows\PushToInstall\LoginCheck` 当成 Logitech 任务**禁用了** (名字匹配写得太宽)。
- 两边都发起配对, **没有一方在监听** → 永远配不上。
- 固定倒计时(180 秒)太短: 授权和配对还没做完就开始恢复了。
- Mac 的 `openlogi` 命令是用 root 跑的, 找不到用户的 agent。
- Mac 的环境变量 `OPENLOGI_LOG` 留在了 launchd 里。

**这次的改动**
- **Windows 先启动并监听, 显示绿色 READY, Mac 再启动并发起配对**; Mac 在改动任何东西之前先问你 Windows 是否 READY。
- 没有倒计时: 每个关卡都等回车 / skip / abort; 能自动检测的(授权、配对、SAS 确认)会自动继续。
- 看门狗改成"租约": 脚本活着就每分钟续租, 只在崩溃/卡死/超过 2 小时时才自动恢复。
- 所有会被改动的东西都写在 `allowlist.json` 里, 只按**完整名字/完整路径**精确匹配。不在清单里的东西**绝不碰**; `\Microsoft\` 下的任务永远不碰。
- 恢复改成逐项尽力: 一项失败不影响后面, 最后给汇总。
- Mac 恢复时 Options+ 界面回到测试前的状态(之前开着才打开); 不再用 osascript(避免额外的"自动化"授权弹窗)。
- Mac 上默认**不做**鼠标注入测试(少一个辅助功能授权); 需要时加 `--with-injection`。
- 详细改动和全部未验证项: `CHANGES-run2.md`; 白名单说明: `ALLOWLIST.md`。
