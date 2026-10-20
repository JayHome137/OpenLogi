# OpenLogi Flow 实机自动化测试套件（Windows + macOS）

> **只写文件，不在本机执行。** 另一名助手稍后在 Jay 离开时远程跑。本目录全部产出在 Linux box 的 `/workspace/openlogi-hwtest/`，**不访问、不登录 Jay 的机器**。
>
> 目标构建：GitHub Actions run [`39235760610`](https://github.com/JayHome137/OpenLogi/actions/runs/39235760610)（`openlogi-custom` @ `bd04518f`，未签名）。Windows 用便携 zip `OpenLogi-windows-x86_64`；macOS 用对应架构的 DMG。
>
> 依据：仓库代码（二进制名、CLI、配置/日志路径、真实日志文案）+ `/workspace/openlogi-test-without-uninstalling-optionsplus.md` + `/workspace/openlogi-flow-test-checklist.md`。**不发明**不存在的 CLI/日志/IPC。

## 目录

```
openlogi-hwtest/
  README.md                          本文件（中文）
  windows/
    Invoke-OpenLogiFlowTest.ps1      主入口（Preflight / Run / Restore）
    HwTest.Common.ps1                共享库（快照、停/恢复 Options+、看门狗、清理、日志解析）
    UserSide.ps1                     在用户交互会话里启动 agent / SendInput 探测
    Watchdog.ps1                     SYSTEM 计划任务回调（超时强制恢复）
    Emergency-Restore.ps1            人工紧急恢复
  macos/
    run-openlogi-flow-test.sh        主入口（preflight / run / restore）
    common.sh                        共享库
    inject.swift / inject.sh         CGEvent 注入探测
    watchdog.sh                      分离进程 + LaunchDaemon 回调
    emergency-restore.sh             人工紧急恢复
```

## 唯一结果日志（固定位置）

| 机器 | 路径 |
|------|------|
| Windows（Jay-Alienware） | `%USERPROFILE%\OpenLogi-test-result.log` |
| macOS（Jay's Mac Mini） | `~/OpenLogi-test-result.log` |

测完后**只保留这一份**（含计时、状态 diff、错误）。临时目录、解压包、测试创建的配置/数据目录、计划任务、本测试加的防火墙规则都会删掉。

## 怎么跑

### Windows（管理员 PowerShell）

```powershell
cd <本套件拷到机器后的路径>\windows

# 1) 只读预检（改不了任何东西）
.\Invoke-OpenLogiFlowTest.ps1 -Mode Preflight -ArtifactZip $env:USERPROFILE\Downloads\OpenLogi-windows-x86_64.zip

# 2) 正式跑（本地产物）
.\Invoke-OpenLogiFlowTest.ps1 -Mode Run `
  -ArtifactZip $env:USERPROFILE\Downloads\OpenLogi-windows-x86_64.zip `
  -PeerAddress 192.168.x.x `
  -FlowEdge left `
  -StartAtEpochMs 1730000000000 `
  -WatchdogMinutes 5

# 或用 token 下载（不要把 token 写进脚本）
.\Invoke-OpenLogiFlowTest.ps1 -Mode Run -DownloadToken $env:GH_TOKEN -PeerAddress ...

# 3) 手动恢复（与看门狗同一路径）
.\Invoke-OpenLogiFlowTest.ps1 -Mode Restore
# 或：
.\Emergency-Restore.ps1
```

### macOS（需要 sudo；图形界面用户已登录）

```bash
cd <套件路径>/macos

# 1) 只读预检（可不 sudo）
./run-openlogi-flow-test.sh --mode preflight --artifact ~/Downloads/OpenLogi-macos-dmg-arm64.zip

# 2) 正式跑
sudo ./run-openlogi-flow-test.sh --mode run \
  --artifact ~/Downloads/OpenLogi-macos-dmg-arm64.zip \
  --peer-address 192.168.x.y \
  --flow-edge right \
  --start-at-epoch-ms 1730000000000 \
  --watchdog-minutes 5

# 3) 恢复
sudo ./run-openlogi-flow-test.sh --mode restore
# 或：
sudo ./emergency-restore.sh
```


## 套件如何到两台机器 / Preflight 与产物

本目录目前只在 Linux box：`/workspace/openlogi-hwtest/`。**不会**自动推到 Jay 的电脑。请先拷过去再跑，例如：

```bash
# 在能访问 box 与两台机器的环境里（示例）
scp -r /workspace/openlogi-hwtest 'jay@Jay-Alienware:C:/Users/Jay/OpenLogi-hwtest'
scp -r /workspace/openlogi-hwtest 'jay@mac-mini:~/OpenLogi-hwtest'
```

Windows 上脚本路径示例：`C:\Users\Jay\OpenLogi-hwtest\windows\`  
macOS 上：`~/OpenLogi-hwtest/macos/`

### Preflight 要不要事先准备安装包？

**不需要。** Preflight 是只读的：不下载、不解压、不改 Options+/防火墙。它只**报告** artifact 参数指向的文件是否存在，或是否提供了下载 token。

正式 `Run` 才需要下面之一：

| 平台 | Actions artifact 名（run [39235760610](https://github.com/JayHome137/OpenLogi/actions/runs/39235760610)） |
|------|------|
| Windows | `OpenLogi-windows-x86_64`（便携 zip；外层是 Actions 包装 zip，内含 `OpenLogi.exe` / `openlogi-agent.exe` / `bin\openlogi.exe`） |
| macOS Apple Silicon | `OpenLogi-macos-dmg-arm64` |
| macOS Intel | `OpenLogi-macos-dmg-x86_64` |

Mac Mini 架构未知时：先在该机 `uname -m`（`arm64` 或 `x86_64`），Preflight/`Run` 在给 `--download-token` 时会按 `uname -m` 自动选对应 DMG artifact；若用本地 `--artifact`，请自己选对文件。

下载 artifact **必须**有 GitHub token（Actions artifact API）；不要把 token 写进脚本。可用参数 `-DownloadToken` / `--download-token`，或先用 token 在别处下好再传本地路径。

## 流程（Run）

1. **预快照** → JSON（服务启动类型/状态、进程、计划任务、Run 键、macOS launchctl + `print-disabled`、Login Items/`sfltool dumpbtm` 只读、可读的 TCC、防火墙、OpenLogi 目录是否已存在等）。
2. **先挂看门狗**（默认 5 分钟），**再**动 Options+。
3. 停 Options+（Windows：`OptionsPlusUpdaterService`→Manual + stop + 杀 `logioptionsplus*` 等；macOS：对发现到的 `com.logi.*` 做 `disable`+`bootout` + pkill）。观察是否自行拉起。
4. 解压/安装 OpenLogi 测试包，加防火墙（仅 Windows 入站 UDP 42424 + mDNS 5353，组名 `OpenLogi-HwTest`），在**用户交互会话**启动 agent，设 `OPENLOGI_LOG=info,openlogi_agent_core=debug,openlogi_flow=debug,openlogi_device=debug,openlogi_hid=debug`。
5. `openlogi flow enable` / `pair-start`（若给了地址）；**SAS 确认不自动点**（见下）。
6. 尝试注入光标到边缘；**同时说明真实限制**。从 `agent.<date>.log` 解析真实日志行计时。
7. **清理 + 按快照幂等恢复** → 后快照 → 逐项 diff（PASS/FAIL）→ 写入结果日志 → 删掉其余一切。

## 看门狗（Failsafe）

| | Windows | macOS |
|--|---------|-------|
| 形态 | 独立计划任务 `OpenLogiHwTest-Watchdog`，**SYSTEM**，一次性触发（+ AtStartup 备份触发） | **分离 nohup 进程** + **LaunchDaemon** `com.openlogi.hwtest.watchdog`（`StartCalendarInterval` + `LaunchOnlyOnce`） |
| 注册时机 | Options+ 被改动**之前** | 同左 |
| 触发后 | 杀主脚本 → **杀 OpenLogi（释放钩子）** → 按预快照恢复 Options+ → 删防火墙/文件/任务 → 后快照 diff → **任务自删** | 同左（恢复后卸 LaunchDaemon / 杀分离进程） |
| 幂等 | 全局 Mutex；与主脚本 finally、Emergency-Restore 同一 `Invoke-FullRestore` | mkdir 锁；同一 `full_restore` |
| 人工 | `Emergency-Restore.ps1` | `sudo ./emergency-restore.sh` |



## macOS Options+ 停法（已按 Mac Mini 实机修正）

- **不用** `launchctl disable` / `enable`（保留 `print-disabled` 覆盖原样）。
- **有 plist 的作业**（`com.logi.cp-dev-mgr`、`com.logi.optionsplus.updater`）：`bootout` 停止 → 测完 `bootstrap` + `kickstart`。
- **LogiPluginService**（`application.com.logi.pluginservice.<数字>`）：RunningBoard 拉起的 app job，`launchctl` 里 path 为 `(submitted by runningboardd.N)`，**没有 plist**，`bootout`+`bootstrap` **无法恢复**。
  - **停**：只对白名单进程 quit/kill（`LogiPluginService` / `Native` / `Ext`），**不** bootout 该 label。
  - **恢复**：快照记下测前是否在跑；若在跑且当前没有进程，则在控制台用户 GUI 会话里  
    `launchctl asuser <uid> sudo -u <user> open -g -j -a /Applications/Utilities/LogiPluginService.app`  
    （root/看门狗 LaunchDaemon 同此；非 root 直接 `open -g -j`）。然后核对进程回来。  
    新的 `application.*` 实例号会变，**diff 按规范化标签 `application.com.logi.pluginservice.*` + `app.LogiPluginService.running` 比较，不比精确 label 字符串**。
  - **cp-dev-mgr 会不会自己再拉起 PluginService：未知**。恢复是幂等的——若进程已在则不再 `open`，避免双开。
- **永不碰**：`com.logitech.LogiRightSight.Agent`、`com.logi.optionsplus.logivoice`、`com.logitech.manager.daemon`。
- `com.logi.optionsplus` 只是 LaunchAgents **文件名**，不是 launchd label。
- 进程白名单；**禁止** `pgrep -i logi`；硬拒绝 loginwindow/logind/WindowServer/launchd 及 `/System`、`/usr`。

离线校验：`bash macos/test-discovery.sh`

## 屏幕布局（GM 默认）

Mac Mini 的屏幕在 Jay-Alienware **左侧**：

| 主机 | 默认跨越边 | 对端 |
|------|------------|------|
| Windows（Jay-Alienware） | **left** | Mac Mini |
| macOS（Mac Mini） | **right** | Jay-Alienware |

配置写在真实 schema 的 `[[flow.layout]]`（`crates/openlogi-core/src/config/flow.rs`）：

```toml
[[flow.layout]]
edge = "left"    # 或 "right" / "top" / "bottom"
peer = "<对端在 [[flow.peers]] 里的 name>"
```

- `peer` 必须等于配对后出现的 `[[flow.peers]].name`（一般是对端 hostname；`flow enable` 在 layout 引用未知 peer 时会校验失败）。
- 脚本在配对之后写入/替换 `[[flow.layout]]`，再执行 `openlogi flow enable` 从磁盘重载（CLI **没有**单独的 layout 子命令；IPC 有 `flow_set_layout` 但未暴露）。
- **默认**：Windows `-FlowEdge left`，macOS `--flow-edge right`。可用 `-FlowEdge` / `--flow-edge` 与 `-PeerName` / `--peer-name` 覆盖。
- 已有用户 `config.toml`：与其它 OpenLogi 目录一样，测试前整目录备份，清理时原样恢复；若测试前不存在则测完删除。

## 两机协调与配对

Flow **必须两台同时跑 OpenLogi**（不能和 Options+ Flow 互通）。建议：

1. 两边先 `-Mode Preflight` / `--mode preflight`，确认服务名、artifact、管理员权限。
2. 约定同一个 `--start-at-epoch-ms` / `-StartAtEpochMs`（Unix 毫秒，两边挂钟大致同步即可）。
3. 一台 `--peer-address` 指另一台 IP；另一台可只 `flow enable`，或也 `pair-start`。
4. **SAS 六位码**：两边日志/`openlogi flow status` 出现 `Prompted` 后，需要**人眼核对一致**，再在两边执行：
   ```text
   openlogi flow confirm
   ```
   脚本**不会**自动 confirm（避免在无人核对时建立信任）。Jay 离开前若已配对过且 `~/.config/openlogi` 保留了 peer，可跳过；但本套件默认测完会删掉**测试新建**的配置目录，下次仍要配对。
5. 布局与 `[[flow.devices]]`：当前 CLI **没有**“写 layout / devices”的子命令（IPC 有 `flow_set_layout`，CLI 未暴露）。需要**事先**在两边 `config.toml` 写好 `[flow]`、`[[flow.layout]]`、`[[flow.devices]]`（见 checklist §4），或测中途人工改。脚本只负责 enable/pair/status 与日志计时。

## 计时依据的真实日志（不编造）

来自 `crates/openlogi-agent-core`（及 probe）：

| 日志文案 | 含义 |
|----------|------|
| `Flow runtime armed` | Flow 网络侧就绪 |
| `Flow handoff completed`（含 `outcome=`） | 发送方收到到达结果；`outcome`：1=Arrived, 2=Partial, 3=Timeout, 4=Cancelled（`flow.v1.proto`） |
| `Flow incoming handoff finished`（`arrived`/`requested`） | 接收方完成等待 |
| `Flow arrival acknowledgment timed out` 等 | 失败路径 |
| `BT-direct / wired device recognised` | 蓝牙直连设备识别 |

**没有**单独的 “edge crossed” info 日志；发送方在边沿触发后直接走 handoff。脚本用「边沿相关 warn/debug → `Flow handoff completed`」估跨越耗时；接收侧用 `Flow incoming handoff finished`。agent 日志在：

- Windows：`%USERPROFILE%\.local\state\openlogi\agent.YYYY-MM-DD.log`
- macOS：`~/.local/state\openlogi\agent.YYYY-MM-DD.log`

（XDG；见 `crates/openlogi-core/src/paths.rs`、`openlogi-agent/src/logging.rs`。）

## 输入注入的诚实限制

| 平台 | 做法 | 结果 |
|------|------|------|
| Windows | `SendInput` 绝对移动（用户会话任务） | OpenLogi 的 `WH_MOUSE_LL` **直接丢弃** `LLMHF_INJECTED` 事件（`openlogi-hook/src/windows/hook.rs`），**合成移动不会触发 Flow**。探测只用来证实这一点；**必须人手推鼠标**。 |
| macOS | `CGEvent` + `hidSystemState`（`inject.swift`） | 点击/滚轮会跳过 `SYNTHETIC_EVENT_USER_DATA`；**MouseMoved 不走该过滤**，但是否进入 HID tap 依赖环境。另：**辅助功能 / 输入监控** 在非 MDM 机器上**无法由脚本授予**，必须用户点允许。无授权则跳过注入。 |

**无法自动化、需人工的部分：**

- macOS Accessibility、Input Monitoring、Local Network 的首次授权（未签名包每次换构建可能要重授）。
- SAS 配对确认。
- Windows 上可靠的边沿跨越（必须真实鼠标）；macOS 上建议同样用真实鼠标。
- `[[flow.devices]]` / layout 的初次配置（无对应 CLI）。
- SmartScreen / Gatekeeper「仍要运行 / 仍要打开」。
- Options+「允许在后台」开关若只用 GUI 方法 A；本套件 macOS 走 launchctl 方法 B。

## 二进制与 CLI（仓库核实）

| 角色 | Windows 便携包 | macOS.app |
|------|----------------|-----------|
| GUI | `OpenLogi.exe` | `OpenLogi.app`（id `org.openlogi.openlogi`） |
| Agent | `openlogi-agent.exe` | `Contents/Library/LoginItems/OpenLogi Agent.app`（`org.openlogi.agent`） |
| Overlay | `openlogi-overlay.exe` | LoginItems 内 Overlay |
| CLI | `bin\openlogi.exe` | `Contents/MacOS/openlogi` |

常用命令：`openlogi api status`、`openlogi api devices`、`openlogi flow status|enable|disable|pair-start|listen|confirm|reject|cancel`。  
**没有** CLI 直接 `ChangeHost`；切换只由 Flow handoff 路径调用 `openlogi_hid`/`ChangeHost 0x1814`。

配置：`~/.config/openlogi/config.toml`（Windows 同为 `%USERPROFILE%\.config\openlogi`）。默认 Flow UDP **42424**，mDNS `_openlogi-flow._udp`。

## 未在真机核实的名称 / 路径

请在 Jay-Alienware / Mac Mini 上以 Preflight 输出为准：

**Windows：** `OptionsPlusUpdaterService`；进程 `logioptionsplus_agent.exe`、`logioptionsplus.exe`、`logioptionsplus_updater.exe`、`logioptionsplus_appbroker.exe`、`logi_crashpad_handler.exe`、`LogiPluginService`；是否有 Logi 计划任务 / Run 键（指南写明公开资料未见）。

**macOS：** `com.logi.cp-dev-mgr`、`com.logi.optionsplus`、`com.logi.optionsplus.updater`；`com.logi.cp-dev-mgr` 的 plist 实际路径（可能是 SMAppService）；Login Items「允许在后台」条目；系统扩展 `com.logi.options.hidfilter`（本套件**不卸载**）；Options+ 停掉后是否自行拉起。

## 残留风险

1. **输入钩子**：若看门狗/恢复失败且 OpenLogi 未杀净，可能影响鼠标键盘 → 看门狗会先杀 OpenLogi；物理 Easy-Switch 键始终可切回通道。
2. **`launchctl disable` 持久**：macOS 若恢复中断，Options+ 可能起不来 → 立刻跑 `emergency-restore.sh`；必要时注销/重启。
3. **未签名包**：SmartScreen / Gatekeeper；TCC 与 ad-hoc 签名绑定，换构建要重授。
4. **蓝牙重连 10–30s**：handoff 等待上限约 30s，超时是 `Timeout`，属预期（checklist）。
5. **OpenLogi 可能改 DPI/SmartShift**：恢复 Options+ 后通常会写回，**未核实**；不对就在 Options+ 里重设。
6. **默认 `launch_at_login=true`**：Windows 会写 `HKCU\...\Run\OpenLogiAgent`；清理时会停进程并删测试目录，若 agent 未自己清 Run 键，diff 会 FAIL 标出。
7. **屏幕锁定 / 无控制台会话**：注入与 GUI 无效；脚本会警告。
8. **Public 网络配置文件**：Windows 防火墙规则只加 Private。
9. **两机版本必须同为 bd04518f 构建**：旧对端会把 30s 等待当成超限。

## 语法检查

本 box 上只做 `bash -n` / `shellcheck` 与（若已安装）`pwsh` 的 `Parser::ParseFile`，**不执行**测试逻辑。
