# OpenLogi Flow 双机硬件测试脚本 (run 2)

**Jay 只需要看 [`RUNBOOK-Jay.md`](RUNBOOK-Jay.md)**。本文件是技术概览。
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
