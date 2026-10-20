# ALLOWLIST — 测试脚本允许改动的全部对象

**唯一来源: `allowlist.json`** (与 `windows\` `macos\` 同级)。`windows/HwTest.Common.ps1` (`Import-HwAllowlist` / `Get-AL`) 和
`macos/common.sh` (`al_load` / `al_get`) 都从这里读取; 找不到或读不了 → **拒绝运行 (fail closed)**, 紧急恢复也不会做任何变更。

## 匹配规则
- **只做精确匹配**: 名字 / 完整路径 / 完整任务路径 / 完整 launchd label。**没有通配符、正则、子串匹配**
  (Windows 比较不区分大小写, macOS 区分大小写)。
- 进程: 名字和**可执行文件完整路径**都必须匹配。名字对但路径不对 → 不碰, 并且 Run 模式拒绝开始 (预检显示 MISMATCH, 退出码 4)。
- 本脚本自身的进程 (主脚本、子进程、看门狗、`ol-hwtest` / `OpenLogi-hwtest` 标记) 从进程列表和快照对比中排除。
- **唯一的动态 ID**: macOS `application.com.logi.pluginservice.<随机>` (RunningBoard 给 LogiPluginService 起的 label)。
  从不对它 bootout; 只用精确可执行路径 `/Applications/Utilities/LogiPluginService.app/Contents/MacOS/*` 停止,
  用 `open -g -j /Applications/Utilities/LogiPluginService.app` 恢复。
- 路径中的 token 运行时展开: Windows `{Profile} {Sid} {WorkRoot} {PkgRoot} {Port} {ConfigHome} {StateHome} {DataHome}`;
  macOS `{uid} {home} {ConfigHome} {StateHome} {DataHome}`。**token 为空 → 这一项被丢弃** (fail closed)。
- `unverified: true` = 没在 Jay 的机器上确认过。

## Windows (.9)
| 类别 | 精确对象 | 允许的动作 |
|---|---|---|
| 服务 | `OptionsPlusUpdaterService` (ImagePath `"C:\Program Files\LogiOptionsPlus\logioptionsplus_updater.exe" --run-as-service`, 测试前 Automatic/Running, 已核实) | 改启动类型 / 停止 / 恢复原启动类型并启动 |
| 计划任务 (禁用) | **无** (run 1 核实: Windows 没有 Logitech 计划任务) | — |
| 永不碰 | HKLM `...\CurrentVersion\Run` : `Logitech Download Assistant` | — |
| 计划任务 (仅修复) | `\Microsoft\Windows\PushToInstall\LoginCheck` | 只**启用**: run-1 state 记录为测试禁用, 或手动 `-RepairLoginCheck` (当前已是 Ready, 不需要)。**永不禁用** |
| 硬性禁止 | 任何 `\Microsoft\` 下的任务 | 除上面这一项修复外绝不改动 |
| 自己的任务 | `\OpenLogiHwTest-Watchdog`, `\OpenLogiHwTest-User-StartAgent`, `\OpenLogiHwTest-User-Inject`, `\OpenLogiHwTest-User-Restore-logioptionsplus_agent`, `\OpenLogiHwTest-User-Restore-LogiPluginService` | 创建 / 删除 |
| Options+ 进程 | **已核实 (run-1 预快照)**: `C:\Program Files\LogiOptionsPlus\` 下 `logioptionsplus_agent.exe`, `logioptionsplus_appbroker.exe`, `logioptionsplus_updater.exe`, `logi_crashpad_handler.exe`, `logivoice\logioptionsplus_logivoice.exe`, `logivoice\logi_crashpad_handler.exe`。**未见过**: `logioptionsplus.exe` (界面), `C:\Program Files\Logi\LogiPluginService\LogiPluginService.exe` | 停止 (路径读不到 → 不停止, 不阻止测试); 恢复靠启动服务, 按名字核对; `logioptionsplus_agent` / `LogiPluginService` 仍缺时在用户会话里启动 |
| OpenLogi 进程 | `{PkgRoot}\openlogi-agent.exe`, `OpenLogi.exe`, `openlogi-overlay.exe`, `bin\openlogi.exe` | 停止 |
| 防火墙规则 | `OpenLogiHwTest-UDP-{Port}`, `OpenLogiHwTest-mDNS-5353` (组 `OpenLogi-HwTest`) | 创建 / 删除 (按 Name 精确) |
| 注册表值 (测试前不存在才删) | `HKU\{Sid}\...\CurrentVersion\Run` : `OpenLogiAgent`; `HKU\{Sid}\...\Explorer\StartupApproved\Run` : `OpenLogiAgent` (未验证) | 删除 |
| 路径 (测试前不存在才删) | `{WorkRoot}` (= `%ProgramData%\OpenLogi-hwtest`), `{Profile}\OpenLogi-hwtest-pkg`, `{ConfigHome}\openlogi`, `{StateHome}\openlogi`, `{DataHome}\openlogi`, `{ConfigHome}\openlogi-dev`, `AppData\Roaming\OpenLogi`, `AppData\Local\OpenLogi`, `AppData\Local\org.openlogi.openlogi`, `AppData\Local\Programs\OpenLogi` | 删除 (测试前已存在的先备份, 恢复时还原) |
| 路径 (测试创建且为空才删) | `{ConfigHome}`, `{StateHome}`, `{DataHome}`, `{Profile}\.local` | 删除空目录 |
| 只写 | `{Profile}\OpenLogi-test-result.log` | 写结果日志 (保留) |

## macOS (.8)
| 类别 | 精确对象 | 允许的动作 |
|---|---|---|
| launchd (Options+) | `gui/{uid}` `com.logi.cp-dev-mgr` (`/Library/LaunchAgents/com.logi.optionsplus.plist`) | bootout / bootstrap / kickstart |
| launchd (Options+) | `system` `com.logi.optionsplus.updater` (`/Library/LaunchDaemons/com.logi.optionsplus.updater.plist`) | bootout / bootstrap |
| launchd (OpenLogi) | `gui/{uid}` `org.openlogi.agent.service` (未验证) | 只 bootout |
| launchd (自己) | `system` `com.openlogi.hwtest.watchdog` (`/Library/LaunchDaemons/com.openlogi.hwtest.watchdog.plist`) | 创建/删除 plist, bootstrap / bootout |
| 永不碰 | `com.logitech.LogiRightSight.Agent`, `com.logi.optionsplus.logivoice`, `com.logitech.manager.daemon` | — |
| **从不使用** | `launchctl disable/enable`, `osascript` | — |
| RunningBoard (唯一动态 ID) | `application.com.logi.pluginservice.*` → 只认 bundle `/Applications/Utilities/LogiPluginService.app` | 按精确路径停止; `open -g -j` 恢复 |
| Options+ 进程 | `logioptionsplus_agent`, `logioptionsplus_updater` (在 `/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/...`), `LogiPluginService`, `LogiPluginServiceNative`, `LogiPluginServiceExt` (`/Applications/Utilities/LogiPluginService.app/Contents/MacOS/`), `logioptionsplus` (`/Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus`) | SIGTERM (宽限后 SIGKILL), 每次 kill 前重新核对路径 |
| Options+ 界面 | `/Applications/logioptionsplus.app` (bundle id 回退值 `com.logi.optionsplus`, 未验证) | 测试前在跑才 `open -g` 恢复 |
| OpenLogi 进程 | `/Applications/OpenLogi.app/Contents/MacOS/openlogi-desktop`, `.../MacOS/openlogi`, `.../LoginItems/OpenLogi Agent.app/Contents/MacOS/openlogi-agent`, `.../LoginItems/OpenLogi Overlay.app/Contents/MacOS/openlogi-overlay` | 停止 |
| TCC 重置 | 服务 `Accessibility`, `ListenEvent` × bundle `org.openlogi.openlogi`, `org.openlogi.agent`, `org.openlogi.overlay` | `tccutil reset` (本地网络无法重置 → 报 LEFTOVER) |
| launchd 用户环境变量 | `OPENLOGI_LOG` | 测试前不存在才 unsetenv |
| 路径 (测试前不存在才删) | `/Applications/OpenLogi.app`, `/Library/Application Support/OpenLogi-hwtest`, `{home}/Library/Application Support/OpenLogi-hwtest`, `{ConfigHome}/openlogi`, `{StateHome}/openlogi`, `{DataHome}/openlogi`, `{ConfigHome}/openlogi-dev`, `{home}/Library/Application Support/OpenLogi`, `{home}/Library/Caches/org.openlogi.openlogi`, `{home}/Library/Preferences/org.openlogi.openlogi.plist`, `/tmp/OpenLogiHwTestRestore.lock` | 删除 (已存在的目录先备份后还原) |
| 路径 (测试创建且为空才删) | `{ConfigHome}`, `{StateHome}`, `{DataHome}`, `{home}/.local` | 删除空目录 |
| 只写 | `{home}/OpenLogi-test-result.log` | 写结果日志 (保留) |

## 只读取、从不改动 (信息)
Windows: 所有计划任务列表、`OPENLOGI_LOG` 环境变量、任何指向 OpenLogi 的防火墙规则 (报告为 LEFTOVER, 由 Jay 手动删)。
macOS: 所有含 logi 的 launchd label、disabled 表、socketfilterfw 应用列表、BTM/登录项、TCC 只读信息、UDP 监听者。

## 测试如何证明"不在清单里的绝不碰"
- Pester (`windows/tests/HwTest.Tests.ps1`): `\Microsoft\Windows\Logitech\Fake`、`\Vendor\Helper`、`\Other\UserLoginSync` 等相似任务从不被禁用;
  相似名字/错误路径的进程不被停止; `Remove-PathSafe` 拒绝清单外路径; `Invoke-UserTask` 拒绝清单外任务名; 防火墙只按精确 Name 删除。
- `macos/test-discovery.sh`: DRY 模式 (`HT_DRY_KILL / HT_DRY_LAUNCHCTL / HT_DRY_RM / HT_DRY_OPEN`) 记录"本来会动什么",
  断言精确集合 (例如只 kill `777 4242 5555 5556 5557 6000`; 同名不同路径/相似名字的 6100/6200/6300/6400、OpenLogi 进程、本脚本自己的进程树 9000/9100、`vim notes-openlogi.txt` 等都不碰);
  清单外 launchd label 和路径被拒绝; 清单文件缺失时所有变更函数拒绝。
