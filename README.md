# OpenLogi Flow 双机硬件测试脚本 (run 2)

**Jay 只需要看 [`RUNBOOK-Jay.md`](RUNBOOK-Jay.md)** (只写操作)。本文件放所有技术细节。
改动和全部未验证项: [`CHANGES-run2.md`](CHANGES-run2.md)。允许改动的对象: [`ALLOWLIST.md`](ALLOWLIST.md) / `allowlist.json`。

- Build: GitHub Actions run **39235760610** @ **bd04518f** (JayHome137/OpenLogi, branch openlogi-custom);
  artifacts `OpenLogi-windows-x86_64`, `OpenLogi-macos-dmg-arm64`。
- 机器: **.9** Jay-Alienware (Windows 11, PowerShell 5.1), **.8** Mac mini (macOS 27 arm64, 用户 jayboy137)。
- 布局: Mac 在 Alienware 左边 → Windows `edge=left`, Mac `edge=right`。Flow UDP 端口 **42424**。
- 测试期间 Logi Options+ 停止, 结束后精确恢复到测试前状态。

## 目录
```
allowlist.json                 唯一的可改动对象清单 (两边脚本都加载; 缺失 = 拒绝运行)
windows/
  Invoke-OpenLogiFlowTest.ps1  -Mode Preflight | Run | Restore
  HwTest.Common.ps1            公共函数 (清单、快照、停止/恢复、租约、关卡、flow status 解析)
  Watchdog.ps1                 计划任务 \OpenLogiHwTest-Watchdog 每分钟运行 (租约看门狗)
  Emergency-Restore.ps1        紧急恢复 (-RepairLoginCheck, -DeleteOpenLogiDirs)
  UserSide.ps1                 在登录用户会话中运行的小动作 (启动 agent / 注入探针 / 重启 Options+)
  tests/                       Pester 测试 + PSScriptAnalyzer 设置
macos/
  run-openlogi-flow-test.sh    --mode preflight | run | restore
  common.sh                    公共函数 (bash 3.2 兼容)
  watchdog.sh                  LaunchDaemon com.openlogi.hwtest.watchdog + 30 秒后台循环 (--tick)
  emergency-restore.sh         紧急恢复 (--delete-openlogi-dirs)
  inject.sh / inject.swift     可选 CGEvent 注入探针 (--with-injection)
  test-discovery.sh, testdata/ 离线测试
tools/
  run-offline-tests.sh         整套离线测试, 完整日志写到 test-logs/
  Test-PsParse.ps1             只解析 .ps1 (不执行), 可在 Windows PowerShell 5.1 下用
test-logs/                     最近一次离线测试的完整日志 + SUMMARY.txt
```

## 流程
1. 预检 (两边, 只读)。
2. **Windows 先**: 快照 → 租约看门狗 → artifact → 停 Options+ → 防火墙规则 → 启动 agent → `flow enable` →
   确认 UDP 42424 由 openlogi-agent 监听 → `flow listen` → 绿色 **READY: listening on UDP 42424**。
3. **Mac 后**: GATE M0 (Windows READY?) → 快照 → 看门狗 → artifact → 停 Options+ → 安装 OpenLogi.app →
   Gatekeeper / TCC 关卡 → `flow enable` → 每 10 秒 `flow pair-start 192.168.1.9:42424`。
4. 两边 SAS 关卡 (`y` → `flow confirm`), 自动检测配对完成 → 写 `[[flow.layout]]` → 真鼠标测量关卡 → 解析 agent 日志里的 Flow 事件和用时。
5. 结束 / abort / 出错: 逐项恢复 → `RESTORE SUMMARY` → 快照对比 `DIFF RESULT`。

## 关卡与租约
- 没有倒计时: 关卡等 回车 / `skip` / `abort` (+ 关卡专用命令), 能自动检测的条件满足后自动继续。
- 看门狗是**崩溃保护**: 租约默认 20 分钟, 每阶段及关卡中每分钟续租; 硬上限默认 120 分钟。
  主进程死亡 / 租约过期 / 超过硬上限 → 看门狗执行与主脚本相同的恢复。
- 参数: Windows `-LeaseMinutes 20 -HardCapMinutes 120`, Mac `--lease-minutes 20 --hard-cap-minutes 120`。

## 结果
- `.9: %USERPROFILE%\OpenLogi-test-result.log`, `.8: ~/OpenLogi-test-result.log` (测试后唯一保留的测试文件)。
- 工作目录 `%ProgramData%\OpenLogi-hwtest` / `/Library/Application Support/OpenLogi-hwtest` 恢复时删除。

## 离线测试 (助手机器上, Linux)
```
tools/run-offline-tests.sh [/path/to/bash-3.2]
```
包含: JSON 解析; .ps1 BOM; pwsh 解析器; PSScriptAnalyzer (默认规则 + PSUseCompatibleSyntax 5.1 +
PSUseCompatibleCommands/Types `win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`);
Pester (StrictMode Latest, mock 返回 0/1/多个对象); bash -n (bash 5 和 3.2.57); shellcheck; test-discovery.sh
(bash 5 和 3.2.57); token 字符串扫描。**真 PowerShell 5.1 和真 macOS 无法在 Linux 上运行**, 见 CHANGES-run2.md。

## 握手细节
- 源码 (bd04518f) 中: `flow listen` = 响应方 (120 秒窗口), `flow pair-start <addr>` = 发起方。run 1 两边都只发起, 没有一方监听。
- Windows (.9) 是响应方: `flow enable` → 20 秒内确认 UDP 42424 的拥有者是 `openlogi-agent` (`Get-NetUDPEndpoint`) → `flow listen`
  → 打印并记录 `READY: listening on UDP 42424`。GATE W2 每 3 秒查 `flow status`, 监听窗口结束时自动重开, 没有固定 sleep。
- Mac (.8) 是发起方: GATE M0 (改动前人工确认 READY) → GATE M3 每 10 秒 `flow pair-start 192.168.1.9:42424`, 超过 600 秒提示去看 Windows。
- SAS: `flow status` 的 `pairing.Prompted{sas, local_confirmed, peer_confirmed}`; `y` → `flow confirm`, `n` → `flow reject`; Paired / peers 出现即自动继续。
- 失败: 红色 FAILED 横幅 (Windows: 不要启动 Mac / Mac 输入 abort; Mac: Windows 输入 abort), 然后自动恢复。
- macOS 上 `openlogi` CLI 以登录用户 + HOME 运行 (agent socket 在 `~/.config/openlogi/agent.sock`); run 1 用 root 跑。

## 租约看门狗
- `lease.json` = `{leaseUntilMs, hardCapMs, renewedMs, phase, mainPid}`。每个阶段续租; 关卡中每分钟续租。默认租约 20 分钟, 硬上限 120 分钟。
- 决策: 无 state → 退出; 已完成 → 退出; 超硬上限 → 触发; 主进程死 (pid + 启动时间) → 触发; 租约过期 → 触发; 否则等待。
- Windows: 计划任务 `\OpenLogiHwTest-Watchdog` (每分钟 + 开机时) 运行 suite 里的 `Watchdog.ps1`; 触发时结束主进程 → `Invoke-FullRestore -FromWatchdog` → 注销任务。
- Mac: LaunchDaemon `com.openlogi.hwtest.watchdog` (StartInterval 60, RunAtLoad) + nohup 30 秒循环, 都运行 `watchdog.sh --tick`;
  恢复用互斥目录 `/tmp/OpenLogiHwTestRestore.lock` 串行; launchd 下最后一步 bootout 自己。run-1 state 的 `deadlineMs` 当作硬上限。

## 清单 (allowlist) 原则
详见 `ALLOWLIST.md`。只按精确名字 / 完整路径改动; 没有通配符或子串匹配 (run 1 的子串匹配误禁用了 `\Microsoft\...\LoginCheck`)。
- Windows 进程路径已用 run-1 预快照核实 (agent, appbroker, logivoice, updater, 两个 crashpad 路径)。
- **路径读不到的进程** (run 1 中非管理员读取时 appbroker / updater / 一个 crashpad 路径为空): 先用 `Process.Path`, 再用 CIM
  `Win32_Process.ExecutablePath`。仍读不到 → **不结束它、也不阻止测试** (记 WARN)。理由: 无法证明它是清单里的文件, 所以不能动;
  而停止 `OptionsPlusUpdaterService` 通常会让它们退出。路径**读得到但不在清单里** → 不动且拒绝开始 (预检退出码 4)。
- 恢复 (run 1 已验证): 恢复服务启动类型并启动服务后, 所有 Options+ 进程会自己回来。脚本等 60 秒, 按名字核对测试前在跑的每个进程;
  只有 `logioptionsplus_agent` (以及 LogiPluginService, 如果有) 仍缺失时才在用户会话里启动; 每个名字记 OK / ERROR。
- Windows 的 Options+ 窗口 (`logioptionsplus`) 从不被脚本结束 (它不会被自动重启); Run 在改动前的 GATE W0 等 Jay 自己关掉。
- Windows 没有 Logitech 计划任务 (run 1 已验证); 不禁用任何计划任务。HKLM Run `Logitech Download Assistant` 永不碰。
- Mac: 只 bootout/bootstrap 清单中的 launchd job, 从不 `launchctl disable/enable`, 不用 osascript; LogiPluginService 只按 bundle 路径 `open -g -j` 恢复;
  Options+ 界面测试前在跑才 `open -g`。Mac 注入探针默认关闭 (`--with-injection`)。

## 紧急恢复细节
- Windows `Emergency-Restore.ps1`: 有 state → 结束主进程 (如在跑) → 完整恢复 → 注销看门狗。无 state → 只按清单默认值恢复。退出码 0 = 全部 OK, 3 = 有失败。
  - `-RepairLoginCheck`: 若 `\Microsoft\Windows\PushToInstall\LoginCheck` 为 Disabled 则启用它 (只用于修 run-1 那类损坏; 当前 Jay 已确认它是 Ready, 不需要)。
  - `-DeleteOpenLogiDirs`: 同时删除清单中的 OpenLogi 目录。
  - 脚本目录没了时: `%ProgramData%\OpenLogi-hwtest\suite\Emergency-Restore.ps1`。
- Mac `emergency-restore.sh`: 有 state → `full_restore`; 无 state → 清单默认值, unset `OPENLOGI_LOG`; `--delete-openlogi-dirs` 同时重置 TCC。
  脚本目录没了时: `/Library/Application Support/OpenLogi-hwtest/suite/emergency-restore.sh`。
- 也可以: `Invoke-OpenLogiFlowTest.ps1 -Mode Restore` / `run-openlogi-flow-test.sh --mode restore`。

## 不用 PAT 的方式
浏览器打开 https://github.com/JayHome137/OpenLogi/actions/runs/39235760610 下载 `OpenLogi-windows-x86_64` / `OpenLogi-macos-dmg-arm64`,
然后 `-ArtifactZip <路径>` / `--artifact <路径>`。**Mac 默认就用这种方式** (PAT 只显示一次, 两台机器没有共享剪贴板); `--artifact` 接受 zip、dmg 或 Safari 自动解压出的文件夹。PAT 在 Windows 用 `Read-Host -AsSecureString` (改动前询问), Mac 用 `read -s` 并经 stdin 交给 `curl -K -`。

## Windows PowerShell 5.1 只解析检查 (未运行, 需要 Jay 另外授权)
见 `tools/PARSE-ONLY-windows.txt`。只解析, 不执行脚本代码, 不需要管理员:
```
cd "$env:LOCALAPPDATA\Temp\ol-hwtest\windows"; powershell.exe -NoProfile -ExecutionPolicy Bypass -File ..\tools\Test-PsParse.ps1 HwTest.Common.ps1 Invoke-OpenLogiFlowTest.ps1 Watchdog.ps1 Emergency-Restore.ps1 UserSide.ps1
```

## 第 1 次运行发生了什么
- PS 5.1 StrictMode: 单个 Process 对象的 `.Count` 抛异常 → 主流程和恢复中途崩溃。
- 子串匹配把 `\Microsoft\Windows\PushToInstall\LoginCheck` 当 Logitech 任务禁用 (之后已重新启用, Jay 确认现为 Ready)。
- 两边都发起配对, 没人监听; 固定 180 秒倒计时太短; Mac CLI 以 root 运行; Mac launchd 环境变量 `OPENLOGI_LOG` 可能残留 (预检会查)。
- run-1 残留 (目录、state.json、看门狗任务/plist、App、日志、脚本) 已由 Jay 在两台上删除并核实。
