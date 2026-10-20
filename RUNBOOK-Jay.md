# OpenLogi Flow 双机实测 — Jay 操作手册

编辑日期：2026-10-20（Asia/Shanghai）。**本手册只描述人工步骤**；脚本已放在本仓库，不会由本文件触发真实主机执行。

## 0. 助手须先完成的预拷贝（Jay 粘贴之前）

| 机器 | 路径 | 内容 |
|------|------|------|
| **Jay-Alienware** | `C:\Users\Jay\AppData\Local\Temp\ol-hwtest\windows\` | `windows/*.ps1` 全套 |
| **Jay-Alienware** | `C:\Users\Jay\AppData\Local\Temp\ol-hwtest\macos\` | `macos/` 全套（供 scp 到 Mini） |
| **Mac Mini** | `/tmp/ol-hwtest/macos/` | 同上；需从 Alienware scp（助手侧 SSH 到 Mini 曾挂起，**请 Jay 确认或自行 scp**） |

从 Alienware 推到 Mini（在 **普通** PowerShell）：

```powershell
scp -i $env:USERPROFILE\.ssh\grokbot_lan -o BatchMode=yes -r "$env:LOCALAPPDATA\Temp\ol-hwtest\macos" Jay@192.168.1.8:/tmp/ol-hwtest/
```

（若 Mini 上 `/tmp/ol-hwtest` 不存在，先 `ssh ... 'mkdir -p /tmp/ol-hwtest'`。）

Artifact：Actions run **39235760610**，到期约 **2027-01-17 UTC**。Windows=`OpenLogi-windows-x86_64`；Mac=`OpenLogi-macos-dmg-arm64`。下载进测试工作目录，**清理时整目录删除**，不留 zip。

## 1. 看门狗时长（推荐 **15 分钟**）

| 项目 | 大约耗时 |
|------|----------|
| 下包 + 解压/挂载 | 0.5–2 min |
| 停 Options+ / 起 OpenLogi | ~1 min |
| **首次** macOS 辅助功能 / 输入监控 / 本地网络授权 | 1–3 min（人工） |
| SAS 配对确认（两边 `openlogi flow confirm`） | 0.5–2 min（人工） |
| 真鼠标往返 N 次（BT handoff 常 10–30 s/次） | 1–3 min |
| 恢复 + 清理 | ~1–1.5 min（脚本预留 ~90 s） |

**5 分钟不够稳**（尤其第一次授权 + 配对）。脚本默认 **`-WatchdogMinutes 15` / `--watchdog-minutes 15`**，可用参数改。超时由 Windows 计划任务 / macOS LaunchDaemon 强制还原 Options+。

协调：可选两边同一 `-StartAtEpochMs` / `--start-at-epoch-ms`（Unix 毫秒）。人手步骤多时也可不传，靠 HumanGate（默认 180 s）+ MeasureWait（默认 180 s）。

## 2. 顺序总览

1. 助手完成 §0 预拷贝。  
2. **两边都已登录图形桌面**（不要锁屏到密码框）。  
3. **先 Mac 再 Windows**（或两边几乎同时）：Mac 要先能点 TCC 弹窗。  
4. 粘贴各自一行命令 → 按提示输入 **GitHub PAT**（不进命令行明文）→ 输入 Mac 的 sudo 密码。  
5. HumanGate 窗口内：两边 `openlogi flow confirm`、Mac 点允许权限。  
6. MeasureWait 窗口内：真鼠标 **Alienware 左边缘 → Mac**，再从 **Mac 右边缘 → Alienware**，至少往返 **3 次**。  
7. 等待脚本自动还原；看结果日志。

GM 布局：Mac 在 Alienware **左侧** → Windows `edge=left`，Mac `edge=right`（脚本默认已如此）。

## 3. Windows 一行（管理员 PowerShell 5.1）

在 **Jay-Alienware** 打开「以管理员身份运行」的 Windows PowerShell，**整行粘贴**：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; $t=Read-Host -AsSecureString 'GitHub PAT'; & "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Invoke-OpenLogiFlowTest.ps1" -Mode Run -DownloadTokenSecure $t -WatchdogMinutes 15 -PeerAddress 192.168.1.8
```

说明：

- `-ExecutionPolicy Bypass` 仅 **Process** 作用域。  
- Token：`Read-Host -AsSecureString`；也可用事先 `$env:OPENLOGI_GH_TOKEN='…'`（脚本用完会 `Remove-Item Env:…`）。**不要**把 PAT 写进这一行明文。  
- `-PeerAddress 192.168.1.8` = Mac Mini（按你的局域网改）。  
- 可选：`-StartAtEpochMs <T0>`、`-PeerName <Mac主机名>`、`-HumanGateSec 180`、`-MeasureWaitSec 180`。

**结果日志（清理后唯一应留下的测试文件）：**  
`C:\Users\Jay\OpenLogi-test-result.log`  
（`%USERPROFILE%\OpenLogi-test-result.log`；工作目录 `%ProgramData%\OpenLogi-hwtest` 测完删除。）

### Windows 出错 → 紧急恢复

同一管理员 PowerShell：

```powershell
& "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Emergency-Restore.ps1"
```

或：

```powershell
& "$env:LOCALAPPDATA\Temp\ol-hwtest\windows\Invoke-OpenLogiFlowTest.ps1" -Mode Restore
```

## 4. macOS 一行（Mac Mini 本机 Terminal + sudo）

**推荐在 Mini 桌面打开 Terminal 粘贴**（SSH 无 TTY 时 `sudo` 要密码会失败；不要依赖 `sudo -S` 把密码塞进管道，除非你自己清楚风险）。

```bash
cd /tmp/ol-hwtest/macos && sudo bash ./run-openlogi-flow-test.sh --mode run --watchdog-minutes 15 --peer-address 192.168.1.9
```

- 先提示 **sudo 密码**，若未设 env/参数，再提示 **GitHub PAT**（`read -s`，不回显）；下载后脚本清空 `TOKEN` / `OPENLOGI_GH_TOKEN` / `GITHUB_TOKEN`。  
- `--peer-address` 填 **Alienware 的局域网 IP**（本环境读到 Alienware=`192.168.1.9`；若网段变化请改）。  
- 可选：先 `export OPENLOGI_GH_TOKEN='…'` 再 `sudo -E bash ./run-openlogi-flow-test.sh …`（`-E` 保留环境变量）。

从 Alienware 经 SSH 开跑：**不推荐**（sudo 密码）。若坚持预检只读：

```powershell
ssh -i $env:USERPROFILE\.ssh\grokbot_lan -o BatchMode=yes Jay@192.168.1.8 "bash /tmp/ol-hwtest/macos/run-openlogi-flow-test.sh --mode preflight"
```

**结果日志：**  
`/Users/Jay/OpenLogi-test-result.log`  
工作目录 `/Library/Application Support/OpenLogi-hwtest` 测完删除。

### macOS 出错 → 紧急恢复

```bash
sudo bash /tmp/ol-hwtest/macos/emergency-restore.sh
```

## 5. HumanGate 期间你要做的事

1. **配对**：两边日志/`openlogi flow status` 出现 SAS 六位码 → **人眼核对一致** → 两边都执行：
   ```text
   openlogi flow confirm
   ```
   （GUI 若有确认按钮也可以。）脚本**不会**自动 confirm。  
2. **macOS 权限**（系统设置 → 隐私与安全性）：**辅助功能**、**输入监控**、**本地网络** 允许 OpenLogi / OpenLogi Agent（未签名包换构建可能要重授）。Gatekeeper「仍要打开」也要点一次。  
3. 权限与 confirm 做完后等 HumanGate 结束即可，不必重跑脚本。

## 6. MeasureWait 期间：真鼠标跨越

| 方向 | 操作 |
|------|------|
| Alienware → Mac | 鼠标推向 Alienware **左**屏边缘，进入 Mac |
| Mac → Alienware | 鼠标推向 Mac **右**屏边缘，回到 Alienware |

至少 **往返 3 次**。BT 切换常 **10–30 s**；不要用脚本注入代替（Windows 会丢 `LLMHF_INJECTED`）。

## 7. 成功 / 失败怎么看

- 结果日志里搜 `TIMING` / `CROSSING` / `handoff completed` / `incoming handoff finished`。  
- 结尾应有 restore 与 diff；Options+ 应回到测前（macOS **不用** disable/enable；PluginService 用 kill/`open -g -j`）。  
- 若看门狗先开火：仍会走同一套 restore；再跑一次 emergency 也安全（幂等）。

## 8. 未核实（UNVERIFIED）

- ~~Alienware 局域网 IP~~：本环境读到 **192.168.1.9**（以太网）；若你改了网段请重查。  
- Options+ Windows 服务/进程名是否与指南完全一致（脚本预检会打印实机名）。  
- cp-dev-mgr 是否会在 bootstrap 后自行拉起 LogiPluginService。  
- 首次 TCC 弹窗是否在 sudo 会话里可靠出现（建议 Mini **本机** Terminal）。  
- 两机时钟偏差；若 `-StartAtEpochMs` 对不齐，可改不传、靠 HumanGate。  
- Artifact 在到期日前仍可下（run `39235760610`）。

## 9. 与 README 的关系

技术细节、标签白名单、RunningBoard PluginService 策略见 `README.md`。**日常开跑只看本 RUNBOOK。**
