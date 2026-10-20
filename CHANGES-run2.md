# CHANGES — 第 2 次运行 (相对 run 1 基线 commit c09cbe7)

日期: 2026-10-20 (Asia/Shanghai)。全部工作只在助手自己的机器上完成; **没有**连接、拷贝或运行任何东西到 Jay 的机器。
端口 42424、build run 39235760610 @ bd04518f、布局 (Mac 在左: Windows edge=left, Mac edge=right) 均**未改动**。

## ⚠️ 未验证 (UNVERIFIED) 风险清单 — 最上面先看

| # | 未验证项 | 影响 | 缓解 |
|---|---|---|---|
| U1 | 真正的 Windows PowerShell 5.1 从未运行 (只有 pwsh 7.4.6 + PSSA 5.1 兼容规则 + Pester) | 5.1 特有行为可能不同 | 已准备 5.1 只解析命令 (RUNBOOK 第 3 步, **需 Jay 另外授权**, 未运行) |
| U2 | macOS 工具 (`launchctl`, `tccutil`, BSD `ps`/`date`/`stat`, `PlistBuddy`, `socketfilterfw`, `hdiutil`, `open`) 全是模拟/录制数据 | 输出格式不同会导致匹配失败 | 匹配失败默认 = 不碰 (fail closed); 预检先显示 |
| U3 | macOS `/bin/bash` 3.2 只用 Linux 上自编译的 bash 3.2.57 测试 | 平台差异 | 语法检查 + 123 项测试在 3.2.57 下全部通过 |
| U4 | Windows Options+ 可执行路径 (`C:\Program Files\LogiOptionsPlus\*.exe`, `C:\Program Files\Logi\LogiPluginService\LogiPluginService.exe`) | 路径不对 → 拒绝开始 | 预检 MISMATCH, 退出码 4, 什么都不改 |
| U5 | Windows 是否存在 Logitech 计划任务 | 若有, 本次不会禁用它, Options+ 可能被它拉起 | 有重生监视 (Watch-OptionsPlusRespawn) 并记录 |
| U6 | run 1 之前 `LoginCheck` 是否为启用状态 | 盲目启用可能违背 Jay 的原设置 | 只在 run-1 state 记录或 `-RepairLoginCheck` 时启用 |
| U7 | Mac Options+ 界面 bundle id (回退 `com.logi.optionsplus`) | 只用于信息 | 恢复只用精确 bundle 路径 `open -g` |
| U8 | `org.openlogi.agent.service` (SMAppService, KeepAlive SuccessfulExit=false) 在 bootout 后的行为 | agent 可能被重新拉起 | 恢复后再按精确路径停止 OpenLogi 进程; 报告 LEFTOVER |
| U9 | `StartupApproved\Run` 下是否会出现 `OpenLogiAgent` 值 | 可能留下条目 | 测试前不存在才删 |
| U10 | `tccutil reset ListenEvent/Accessibility <bundle>` 对 root/用户 TCC 库是否有效; ListenEvent 名称 | 授权条目可能残留 | RUNBOOK 第 12 步手动 "−" |
| U11 | 本地网络 (Local Network) TCC 无法用 tccutil 重置 | 残留开关 | 报 LEFTOVER, RUNBOOK 第 12 步 |
| U12 | `launchctl asuser <uid> launchctl getenv/setenv/unsetenv` 在 macOS 27 上的行为 | `OPENLOGI_LOG` 可能残留 | 预检显示; 紧急恢复会 unset |
| U13 | bash `read -t` 在 tty 上超时时是否保留已输入的半行 | 关卡输入可能丢字 | 关卡 1 秒轮询; 丢字时重新输入即可 |
| U14 | LaunchDaemon 看门狗在 launchd 下 "最后一步 bootout 自己" 的顺序 | 看门狗可能多留一轮 | 下一轮 tick 发现无 state 退出码 10, 并删 plist |
| U15 | Mac 上 `python3` 可用 (run 1 推断有) | 无 CLT 时会弹安装框 | 新增 `python_ok`: 用 `xcode-select -p` 检查, 不执行 shim; 不可用则在改动前停止 |
| U16 | macOS 27 的系统设置中文菜单名称 | RUNBOOK 描述可能略不同 | RUNBOOK 写明按 14/15 界面 |
| U17 | SmartScreen / Windows 防火墙弹窗 / macOS 防火墙弹窗何时出现 | 人工步骤 | 关卡 W1 / RUNBOOK 指引, 防火墙 "取消" 会生成阻止规则 → 明确写 "不要点取消" |
| U18 | Windows 用 `Get-NetUDPEndpoint` 判定 42424 的拥有者是 openlogi-agent | 判定失败 → 不显示 READY, 抛 FAILED | 20 秒重试 |
| U19 | PS 5.1 中 Ctrl+C 时 `finally` 恢复一定执行 (文档如此) | 可能不恢复 | 看门狗租约兜底 (≤20 分钟); RUNBOOK 推荐 `abort` |
| U20 | conhost 中 `[Console]::KeyAvailable` 轮询 | 关卡输入 | Pester 中用 mock 测试 Read-GateKeyLine 逻辑 |
| U21 | OpenLogi QUIC 在 42424 绑定、`flow pair-start` 的 ManualCandidateSource 默认端口 | 配对失败 | 显式传 `192.168.1.9:42424` |
| U22 | SMAppService / 后台任务管理 (BTM) 的登录项残留 | "登录项" 里可能留下 OpenLogi | 快照中只读记录, 报告 |
| U23 | Windows 看门狗计划任务 / Mac LaunchDaemon 在真机上按租约触发 | 崩溃时恢复延迟 | 决策逻辑 (Get-LeaseDecision / lease_decision) 已离线测试 |
| U24 | macOS CLI 必须以用户身份 + HOME 运行才能找到 `~/.config/openlogi/agent.sock` (源码推断; run 1 用 root 跑, 很可能失败) | run 2 已改为用户身份 | — |

## 测试环境无法模拟的
- 真 PowerShell 5.1 / .NET Framework 4.x; Windows cmdlet (`Get-ScheduledTask`, `Get-NetFirewallRule`, `Get-Service`, `Get-CimInstance`, `Get-NetUDPEndpoint`, `Register-ScheduledTask`) — Pester 中全部是带参数的 stub + Mock。
- macOS 的 launchd / TCC / RunningBoard / Gatekeeper / SMAppService, BSD 用户态工具, `/bin/bash` 3.2 的 Apple 补丁版本。
- 真蓝牙 Logitech 鼠标、两机网络、QUIC、SAS 配对、OpenLogi agent 本身。
- 带中文的控制台编码 (PS 5.1 conhost 代码页)。

## 改动清单

### 新文件
- `allowlist.json` — 所有可改动对象的唯一机器可读清单 (见 `ALLOWLIST.md`)。
- `ALLOWLIST.md`, `CHANGES-run2.md` (本文件), 重写 `RUNBOOK-Jay.md`, 更新 `README.md`。
- `windows/tests/HwTest.Tests.ps1` (Pester, StrictMode Latest, 37 个测试), `windows/tests/PSScriptAnalyzerSettings.psd1`。
- `macos/testdata/`: `ps-axww-ppid.txt`, `run1-state.json`, `run1-snapshot-pre.json`, `run2-snapshot-post.json`, `flow-{prompted,paired,failed,none}.json`。
- `tools/run-offline-tests.sh` (整套离线测试, 日志写 `test-logs/`), `tools/Test-PsParse.ps1` (只解析, 不执行)。

### A. PowerShell 5.1 加固 (`windows/HwTest.Common.ps1`, 全部 .ps1)
- 所有函数输出在调用处用 `@()` 包住后再 `.Count`; 新增 `Get-Prop` / `Get-Count`; `Set-StrictMode -Version 2.0`。
- **新发现并修复 (本轮离线测试)**:
  - `Get-Count $null` 返回 1 (`@($null).Count` = 1)。`Get-Count (Get-Process ... -EA SilentlyContinue)` 在进程不存在时会误报 "在运行" → 恢复时 Options+ agent 不会被重启。已修: `$null` → 0。
  - `Get-AL` 对空/缺失的 key 返回一个 `$null` 元素 → 已过滤。
  - `Test-InList '' $null` 返回 true → 已修。
  - `Format-LeaseStatus` 中 `[Math]::Max(0, [long]...)` 选中 Int32 重载 → 溢出异常 (每个关卡都会调用, 例如 Restore 模式)。已改 `[long]0`。
  - `Read-State` 对 run-1 state 用 `Join-Path` 拼 `C:\` 路径 (Linux 测试报错; Windows 上正常) → 改为字符串拼接。
- 不用 5.1 没有的语法 (三元、`??`、`-AsHashtable`、三参数 `Join-Path`、class)。PSSA `PSUseCompatibleSyntax`(5.1) / `PSUseCompatibleCommands` / `PSUseCompatibleTypes` (Windows PowerShell 5.1 Desktop 配置) **0 条**。
- 所有 .ps1 为 UTF-8 **带 BOM** (5.1 需要它才能正确读中文)。
- 恢复改为逐项尽力 (`Invoke-RestoreStep`): 每项单独 try/catch, 失败继续, 最后 `RESTORE SUMMARY` (OK / FAIL / LEFTOVER), 退出码 0/3。看门狗走同一条恢复路径 (`Invoke-FullRestore -FromWatchdog`)。

### B. 只碰 Logitech/Options+ (精确清单)
- run 1 的子串匹配误把 `\Microsoft\Windows\PushToInstall\LoginCheck` 当 Logitech 任务禁用了。现在: 不禁用任何计划任务; `\Microsoft\` 硬性禁止; LoginCheck 只在 run-1 state 记录或 `-RepairLoginCheck` 时**启用**。
- 进程/服务/防火墙/注册表/路径/launchd label 全部按 `allowlist.json` 精确匹配; 名字对但路径不对 → 拒绝开始。
- 对比快照时 run-1 的 `\Microsoft\` 噪声被归一化去掉。

### C. 握手 (READY)
- Windows = 响应方 (`openlogi flow listen`, 120 秒窗口, 超时自动重开), Mac = 发起方 (`flow pair-start 192.168.1.9:42424`)。run 1 两边都没监听。
- Windows 在 `flow enable` 后确认 UDP 42424 的拥有者是 `openlogi-agent`, 然后才打印/记录 `READY: listening on UDP 42424` (绿色横幅)。
- Mac 在**改动任何东西之前**有 GATE M0 (Windows READY 了吗?); 配对阶段每 10 秒重试, 超过 10 分钟提示去看 Windows 窗口。
- Windows 等配对没有固定 sleep (GATE W2 自动检测 Prompted)。
- 失败时红色大横幅 FAILED: Windows 写 "不要再启动 Mac 端脚本 / Mac 端输入 abort"; Mac 写 "Windows 窗口输入 abort"。

### D. 中文人工关卡 (`Wait-HumanGate` / `gate`)
- 关卡: W1 (SmartScreen), W2 (等 Mac), W3/W3b (SAS), W4 (测量); M0, M1 (Gatekeeper), M2 (TCC 输入监控 + 辅助功能, 精确路径, Command+Shift+G), M3 (配对), M4/M4b (SAS), M5 (测量)。
- 关卡循环检查状态 (`api status` 的 accessibility_granted / input_monitoring_granted, `flow status` 的 Prompted/Paired/Failed、本机/对方已确认), 满足自动继续; 否则等 回车 / skip / abort (+ retry / restart / y / n)。
- SAS: 显示 6 位码 (`123 456`), `y` → `flow confirm`, `n` → `flow reject`, 通过 flow status 检测双方确认。
- 每个关卡打印租约剩余和硬上限剩余。

### 租约看门狗 (Steering 2)
- `lease.json` = {leaseUntilMs, hardCapMs, renewedMs, phase, mainPid}; 每个阶段续租, 关卡中每分钟续租; 租约默认 20 分钟, 硬上限默认 120 分钟。
- 决策顺序: 无 state → 退出; 已完成 → 退出; 超过硬上限 → 触发; 主进程已死 (pid + 启动时间) → 触发; 租约过期 → 触发; 否则等待。
- Windows: 计划任务 `\OpenLogiHwTest-Watchdog` 每分钟跑 `Watchdog.ps1`; 触发时杀主进程、完整恢复、注销自己。
- Mac: LaunchDaemon `com.openlogi.hwtest.watchdog` (StartInterval 60, RunAtLoad) + 后台 30 秒循环, 都跑 `watchdog.sh --tick`; 恢复用互斥目录 `/tmp/OpenLogiHwTestRestore.lock` 串行化; 在 launchd 下最后一步 bootout 自己。
- run-1 state 的 `deadlineMs` 当作硬上限兼容。
- 参数: `-LeaseMinutes/-HardCapMinutes`, `--lease-minutes/--hard-cap-minutes`; 旧参数 `-WatchdogMinutes` 映射为租约, `-HumanGateSec/-MeasureWaitSec/-StartAtEpochMs` 忽略并提示。

### E. Mac 恢复
- Options+ 界面: 测试前在跑才 `open -g` 恢复; 不用 osascript (避免 "自动化" 授权弹窗); 只对精确路径 SIGTERM。
- LogiPluginService: 按精确 bundle `open -g -j` 恢复, 从不 bootout 它的 RunningBoard label。
- 只 bootout/bootstrap 清单内的 job, 从不 `launchctl disable/enable`。
- 本脚本自己的进程 (主进程树、看门狗、标记) 从进程列表、kill 和快照对比中排除。
- `openlogi` CLI 以登录用户 + HOME 运行 (run 1 用 root, 找不到 agent socket)。
- `OPENLOGI_LOG` 测试前不存在才 unset; run-1 残留由预检显示、紧急恢复清除。
- Mac 鼠标注入默认关闭 (`--with-injection` 开启), 少一个辅助功能授权。`inject.sh` 修复了重复的 `--edge` 和空数组展开 (bash 3.2 `set -u` 下报错)。
- 新增 `python_ok` 检查 (U15)。

### 其它
- Windows: PAT 在改动之前以 `Read-Host -AsSecureString` 询问; 用完清除 (变量与环境变量)。Mac: PAT 用 `read -s`, 经 stdin 交给 `curl -K -`, 不出现在命令行/ps 中。仓库里没有任何 token (测试中 grep 检查)。
- Windows 预检 / Mac 预检为只读, 路径不匹配退出码 4。Run 模式发现残留 state / 看门狗时拒绝开始。
- 紧急恢复脚本: 有 state 走完整恢复; 无 state 时只按清单默认值恢复; Windows `-RepairLoginCheck` / `-DeleteOpenLogiDirs`, Mac `--delete-openlogi-dirs`。

## 离线测试结果 (2026-10-20, `tools/run-offline-tests.sh`, 日志 `test-logs/`)
见 `test-logs/SUMMARY.txt`; 全部 PASS。PSSA 剩余 19 条 Warning (空 catch 块为有意的尽力而为; 两条未用参数), 0 Error, 0 兼容性问题。
