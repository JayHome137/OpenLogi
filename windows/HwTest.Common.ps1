# OpenLogi Flow hardware test - shared Windows library (dot-sourced).
# Windows PowerShell 5.1 compatible. Never run directly.
#
# Facts taken from the OpenLogi repo (openlogi-custom @ bd04518f / bbe9a2fe):
#   portable zip layout   .github/workflows/build.yml "Collect signed portable zip artifact"
#   config/state/data     crates/openlogi-core/src/paths.rs (XDG layout also on Windows)
#   agent log file        crates/openlogi-agent/src/logging.rs  (agent.<date>.log, UTC RFC3339 timestamps)
#   Run key               crates/openlogi-agent/src/autostart/windows.rs (HKCU\...\Run\OpenLogiAgent)
#   IPC pipe              crates/openlogi-ipc/src/transport.rs (\\.\pipe\openlogi-agent.sock)
#   Flow log lines        crates/openlogi-agent-core/src/flow/handoff.rs, flow/handoff/sender.rs
# Options+ names come from the Chinese guide and are NOT verified on Jay-Alienware.

Set-StrictMode -Version 2.0

$script:HT = @{
    WorkRoot          = (Join-Path $env:ProgramData 'OpenLogi-hwtest')
    TaskPrefix        = 'OpenLogiHwTest-'
    WatchdogTask      = 'OpenLogiHwTest-Watchdog'
    FirewallGroup     = 'OpenLogi-HwTest'
    ResultName        = 'OpenLogi-test-result.log'
    PkgName           = 'OpenLogi-hwtest-pkg'
    Repo              = 'JayHome137/OpenLogi'
    RunId             = '39235760610'
    ArtifactName      = 'OpenLogi-windows-x86_64'
    MutexName         = 'Global\OpenLogiHwTestRestore'
    # Guide 2.1 / 2.3 (unverified on the real machine)
    OptionsPlusServices        = @('OptionsPlusUpdaterService')
    OptionsPlusProcessPatterns = @('logioptionsplus*', 'LogiPluginService*', 'logi_crashpad_handler')
    # Background processes the restore may start in the user session if the service did not bring them back.
    OptionsPlusUserRestart     = @('logioptionsplus_agent', 'LogiPluginService')
    OpenLogiProcessNames       = @('OpenLogi', 'openlogi-agent', 'openlogi-overlay', 'openlogi')
    LogFilter                  = 'info,openlogi_agent_core=debug,openlogi_flow=debug,openlogi_device=debug,openlogi_hid=debug'
    CleanupReserveSec          = 90
}

# Real log messages emitted by the agent (see header for source files).
$script:FlowEventPatterns = @(
    'Flow runtime armed',
    'Flow handoff completed',
    'Flow incoming handoff finished',
    'Flow arrival acknowledgment timed out',
    'Flow host switch failed after receiver acceptance',
    'Flow edge has no online configured devices to hand off',
    'Flow edge ignored because the peer still reports one target device as held',
    'Flow edge ignored while peer is disconnected',
    'Flow handoff rejected',
    'Flow handoff request timed out',
    'Flow handoff request failed',
    'Flow handoff cancelled by peer',
    'Flow peer returned an invalid handoff acceptance',
    'Flow device arrived but cursor positioning failed',
    'Flow released modifier keys the departed keyboard left down',
    'invalid Flow configuration',
    'Flow runtime failed to start',
    'Flow mDNS advertisement unavailable',
    'Flow mDNS browsing unavailable',
    'BT-direct / wired device recognised',
    'agent panicked'
)
# proto/flow.v1.proto enum HandoffOutcome
$script:OutcomeNames = @{ '0' = 'Unspecified'; '1' = 'Arrived'; '2' = 'Partial'; '3' = 'Timeout'; '4' = 'Cancelled' }

$script:ResultLog = $null
$script:Ctx = $null

# ----------------------------------------------------------------------------- logging / time
function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Format-Ms([long]$Ms) {
    if ($Ms -le 0) { return 'n/a' }
    [DateTimeOffset]::FromUnixTimeMilliseconds($Ms).ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}
function Write-R {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $Message
    Write-Host $line
    if ($script:ResultLog) {
        try { Add-Content -LiteralPath $script:ResultLog -Value $line -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "  (result log write failed: $_)" }
    }
}
function Write-Section([string]$Title) { Write-R ('==== ' + $Title + ' ====') 'SECT' }

# ----------------------------------------------------------------------------- identity / paths
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-IsSystem { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18' }
function Get-ConsoleUser {
    try { return (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { return $null }
}
function Get-UserSid([string]$User) {
    try { return (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}
function Get-ProfilePath([string]$Sid) {
    try { return (Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $Sid) -ErrorAction Stop).LocalPath } catch { return $null }
}
function Get-UserEnvValue([string]$Sid, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath ("Registry::HKEY_USERS\{0}\Environment" -f $Sid) -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function Test-ScreenLocked {
    # LogonUI.exe runs in the console session while the workstation is locked (heuristic).
    $p = Get-Process -Name LogonUI -ErrorAction SilentlyContinue
    return [bool]$p
}

# Builds the context (target user, paths). Same rules as crates/openlogi-core/src/paths.rs:
# XDG_*_HOME if set (absolute) else ~/.config, ~/.local/state, ~/.local/share; app dir "openlogi".
function New-HwContext {
    param([string]$TargetUser)
    if (-not $TargetUser) { $TargetUser = Get-ConsoleUser }
    $sid = if ($TargetUser) { Get-UserSid $TargetUser } else { $null }
    $profileDir = if ($sid) { Get-ProfilePath $sid } else { $null }
    $c = [ordered]@{
        TargetUser = $TargetUser; Sid = $sid; Profile = $profileDir
        WorkRoot = $HT.WorkRoot; SuiteDir = (Join-Path $HT.WorkRoot 'suite')
        StatePath = (Join-Path $HT.WorkRoot 'state.json')
        PrePath = (Join-Path $HT.WorkRoot 'snapshot-pre.json'); PostPath = (Join-Path $HT.WorkRoot 'snapshot-post.json')
        BackupDir = (Join-Path $HT.WorkRoot 'backup')
        ResultLog = $null; PkgDir = $null; IoDir = $null
        ConfigDir = $null; StateDir = $null; DataDir = $null; ParentDirs = @(); ExtraDirs = @()
        MainPid = $PID; StartedMs = (Get-NowMs); DeadlineMs = 0; Completed = $false
        Port = 42424
        Actions = [ordered]@{ servicesChanged = @(); tasksDisabled = @(); firewallRules = @(); userTasks = @(); backups = @(); killed = @() }
    }
    if ($profileDir) {
        $cfgHome = Get-UserEnvValue $sid 'XDG_CONFIG_HOME'; if (-not $cfgHome -or -not [IO.Path]::IsPathRooted($cfgHome)) { $cfgHome = Join-Path $profileDir '.config' }
        $stHome = Get-UserEnvValue $sid 'XDG_STATE_HOME'; if (-not $stHome -or -not [IO.Path]::IsPathRooted($stHome)) { $stHome = Join-Path $profileDir '.local\state' }
        $dtHome = Get-UserEnvValue $sid 'XDG_DATA_HOME'; if (-not $dtHome -or -not [IO.Path]::IsPathRooted($dtHome)) { $dtHome = Join-Path $profileDir '.local\share' }
        $c.ConfigDir = Join-Path $cfgHome 'openlogi'
        $c.StateDir = Join-Path $stHome 'openlogi'
        $c.DataDir = Join-Path $dtHome 'openlogi'
        # Parents the agent may create (create_dir_all); removed again only if the test created them and they are empty.
        $c.ParentDirs = @($cfgHome, (Join-Path $profileDir '.local'), $stHome, $dtHome)
        # Other places an OpenLogi build could write (not known to be used; checked so the diff would show it).
        $c.ExtraDirs = @((Join-Path $profileDir 'AppData\Roaming\OpenLogi'), (Join-Path $profileDir 'AppData\Local\OpenLogi'),
            (Join-Path $profileDir 'AppData\Local\org.openlogi.openlogi'), (Join-Path $profileDir 'AppData\Local\Programs\OpenLogi'),
            (Join-Path $cfgHome 'openlogi-dev'))
        $c.ResultLog = Join-Path $profileDir $HT.ResultName
        $c.PkgDir = Join-Path $profileDir $HT.PkgName
        $c.IoDir = Join-Path $c.PkgDir 'io'
    }
    return $c
}

function Save-State {
    if (-not $script:Ctx) { return }
    if (-not (Test-Path -LiteralPath $HT.WorkRoot)) { return }
    ($script:Ctx | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:Ctx.StatePath -Encoding UTF8
}
function Read-State {
    $p = Join-Path $HT.WorkRoot 'state.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    # convert to hashtable-like ordered dictionary for uniform access
    $h = [ordered]@{}
    foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
    $a = [ordered]@{}
    foreach ($k in @('servicesChanged', 'tasksDisabled', 'firewallRules', 'userTasks', 'backups', 'killed')) {
        $v = $null; if ($o.Actions -and ($o.Actions.PSObject.Properties.Name -contains $k)) { $v = $o.Actions.$k }
        $a[$k] = @($v | Where-Object { $_ -ne $null })
    }
    $h.Actions = $a
    $h.ParentDirs = @($h.ParentDirs); $h.ExtraDirs = @($h.ExtraDirs)
    return $h
}
function Add-StateAction([string]$Kind, $Value) {
    $script:Ctx.Actions[$Kind] = @($script:Ctx.Actions[$Kind]) + @($Value)
    Save-State
}

# ----------------------------------------------------------------------------- snapshot
function Get-ServiceStartType([string]$Name) {
    $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
    if (-not $svc) { return 'Absent' }
    $mode = [string]$svc.StartMode   # Auto / Manual / Disabled / Boot / System
    if ($mode -eq 'Auto') {
        $d = $null
        try { $d = (Get-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $Name) -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart } catch {}
        if ($d -eq 1) { return 'AutomaticDelayed' } else { return 'Automatic' }
    }
    return $mode
}
function Get-LogiServices {
    @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            ($_.Name -match 'logi|OptionsPlus' -or $_.DisplayName -match 'logi') -and $_.Name -notmatch 'openlogi'
        } | Sort-Object Name)
}
function Get-LogiProcesses {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'logi' -and $_.Name -notmatch 'openlogi' })
}
function Get-OptionsPlusTargetProcesses {
    $out = @()
    foreach ($pat in $HT.OptionsPlusProcessPatterns) { $out += @(Get-Process -Name $pat -ErrorAction SilentlyContinue) }
    @($out | Sort-Object Id -Unique)
}
function Get-OpenLogiProcesses {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'openlogi' })
}
function Get-LogiTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'logi' -or $_.TaskPath -match 'logi' })
}
function Get-DirManifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $root = (Resolve-Path -LiteralPath $Path).Path
    $lines = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length)
        if ($f.PSIsContainer) { $lines += ('D ' + $rel) }
        else {
            $h = ''; try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $h = 'unreadable' }
            $lines += ('F {0} {1} {2}' -f $rel, $f.Length, $h)
        }
    }
    'present' + "`n" + (($lines | Sort-Object) -join "`n")
}
function Get-RunKeyValues([string]$Sid) {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
    if ($Sid) {
        $keys += @(("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Run" -f $Sid),
            ("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\RunOnce" -f $Sid),
            ("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" -f $Sid))
    }
    $out = @()
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($n in $item.GetValueNames()) {
            $v = $item.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
            if ($v -is [byte[]]) { $v = ($v | ForEach-Object { $_.ToString('x2') }) -join '' }
            $s = '{0}\{1}={2}' -f ($k -replace '^Registry::', ''), $n, $v
            if ($s -match 'logi') { $out += $s }
        }
    }
    @($out | Sort-Object)
}
function Get-StartupFolderItems([string]$ProfileDir) {
    $dirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")
    if ($ProfileDir) { $dirs += (Join-Path $ProfileDir 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') }
    $out = @()
    foreach ($d in $dirs) { if (Test-Path -LiteralPath $d) { $out += @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'logi' } | ForEach-Object { $_.FullName }) } }
    @($out | Sort-Object)
}
function Get-OpenLogiFirewallRules {
    $rules = @()
    $rules += @(Get-NetFirewallRule -Group $HT.FirewallGroup -ErrorAction SilentlyContinue)
    $rules += @(Get-NetFirewallRule -DisplayName '*OpenLogi*' -ErrorAction SilentlyContinue)
    $rules += @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -like '*openlogi*' } | Get-NetFirewallRule -ErrorAction SilentlyContinue)
    $seen = @{}
    $out = @()
    foreach ($r in $rules) {
        if (-not $r -or $seen.ContainsKey($r.Name)) { continue }
        $seen[$r.Name] = $true
        $prog = ''; try { $prog = ($r | Get-NetFirewallApplicationFilter -ErrorAction Stop).Program } catch {}
        $out += ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $r.Name, $r.DisplayName, $r.Group, $r.Enabled, $r.Direction, $r.Action, $r.Profile, $prog)
    }
    @($out | Sort-Object)
}

# Snapshot = ordered map key -> { value = normalized string; info = $true for informational (not part of pass/fail) }
function Get-Snapshot {
    param($C)
    $items = [ordered]@{}
    $add = { param($k, $v, $info) $items[$k] = [ordered]@{ value = [string]$v; info = [bool]$info } }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    & $add 'info.os' ('{0} {1} build {2}' -f $os.Caption, $os.Version, $os.BuildNumber) $true
    & $add 'info.consoleUser' (Get-ConsoleUser) $true
    & $add 'info.screenLocked' (Test-ScreenLocked) $true

    $svcs = Get-LogiServices
    & $add 'svc.names' (($svcs | ForEach-Object { $_.Name }) -join "`n") $false
    foreach ($s in $svcs) {
        & $add ("svc.{0}.starttype" -f $s.Name) (Get-ServiceStartType $s.Name) $false
        & $add ("svc.{0}.status" -f $s.Name) ([string]$s.State) $false
        & $add ("svc.{0}.imagepath" -f $s.Name) ([string]$s.PathName) $false
        $qf = (& sc.exe qfailure $s.Name 2>&1 | Where-Object { $_ -match 'RESET_PERIOD|REBOOT_MESSAGE|COMMAND_LINE|FAILURE_ACTIONS|RESTART|RUN PROCESS|REBOOT' } | ForEach-Object { ($_ -replace '\s+', ' ').Trim() }) -join "`n"
        & $add ("svc.{0}.failureactions" -f $s.Name) $qf $false
    }
    foreach ($n in $HT.OptionsPlusServices) { if (-not ($svcs | Where-Object { $_.Name -eq $n })) { & $add ("svc.{0}.starttype" -f $n) 'Absent' $false } }

    $lp = Get-LogiProcesses
    & $add 'proc.logi.names' ((@($lp | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join "`n") $false
    & $add 'info.proc.logi.paths' ((@($lp | ForEach-Object { '{0}={1}' -f $_.Name, $(try { $_.Path } catch { '' }) }) | Sort-Object -Unique) -join "`n") $true
    & $add 'proc.openlogi.names' ((@(Get-OpenLogiProcesses | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join "`n") $false

    & $add 'tasks.logi' ((@(Get-LogiTasks | ForEach-Object { '{0}{1}={2}' -f $_.TaskPath, $_.TaskName, $_.State }) | Sort-Object) -join "`n") $false
    & $add 'tasks.hwtest' ((@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like ($HT.TaskPrefix + '*') } | ForEach-Object { $_.TaskName }) | Sort-Object) -join "`n") $false
    & $add 'autostart.runkeys' ((Get-RunKeyValues $C.Sid) -join "`n") $false
    & $add 'autostart.startupfolders' ((Get-StartupFolderItems $C.Profile) -join "`n") $false

    & $add 'firewall.openlogi' ((Get-OpenLogiFirewallRules) -join "`n") $false
    & $add 'net.udp.listeners' ((@(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $C.Port } | ForEach-Object { $(try { (Get-Process -Id $_.OwningProcess -ErrorAction Stop).Name } catch { 'pid' + $_.OwningProcess }) }) | Sort-Object -Unique) -join "`n") $false
    & $add 'info.net.profiles' ((@(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { '{0}={1}' -f $_.InterfaceAlias, $_.NetworkCategory })) -join "`n") $true

    if ($C.Sid) {
        & $add 'env.user.OPENLOGI_LOG' ([string](Get-UserEnvValue $C.Sid 'OPENLOGI_LOG')) $false
        & $add 'env.user.OPENLOGI_PROFILE' ([string](Get-UserEnvValue $C.Sid 'OPENLOGI_PROFILE')) $false
    }
    $menv = $null; try { $menv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name OPENLOGI_LOG -ErrorAction Stop).OPENLOGI_LOG } catch {}
    & $add 'env.machine.OPENLOGI_LOG' ([string]$menv) $false

    foreach ($d in @($C.ConfigDir, $C.StateDir, $C.DataDir)) { if ($d) { & $add ('dir.openlogi:' + $d) (Get-DirManifest $d) $false } }
    foreach ($d in @($C.ParentDirs + $C.ExtraDirs + @($C.PkgDir))) { if ($d) { & $add ('path.exists:' + $d) (Test-Path -LiteralPath $d) $false } }

    $bt = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '046D' -and ($_.Class -match 'Bluetooth|HIDClass|Mouse|Keyboard') } |
        ForEach-Object { '{0}|{1}|{2}' -f $_.Class, $_.FriendlyName, $_.Status } | Sort-Object -Unique)
    & $add 'info.logitech.pnp' ($bt -join "`n") $true
    return $items
}
function Save-Snapshot($Items, [string]$Path) {
    $o = [ordered]@{ takenAt = (Get-Date).ToString('o'); host = $env:COMPUTERNAME; items = $Items }
    ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Read-Snapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $items = [ordered]@{}
    foreach ($p in $o.items.PSObject.Properties) { $items[$p.Name] = [ordered]@{ value = [string]$p.Value.value; info = [bool]$p.Value.info } }
    return $items
}
function Get-SnapValue($Snap, [string]$Key) { if ($Snap -and $Snap.Contains($Key)) { return $Snap[$Key].value } return $null }
function Get-SnapLines($Snap, [string]$Key) { $v = Get-SnapValue $Snap $Key; if (-not $v) { return @() } return @($v -split "`n" | Where-Object { $_ -ne '' }) }

function Compare-Snapshots($Pre, $Post) {
    Write-Section 'STATE DIFF (pre vs post)'
    $fail = 0; $pass = 0
    $keys = @($Pre.Keys) + @($Post.Keys | Where-Object { -not $Pre.Contains($_) })
    foreach ($k in $keys) {
        $a = if ($Pre.Contains($k)) { $Pre[$k].value } else { '<missing>' }
        $b = if ($Post.Contains($k)) { $Post[$k].value } else { '<missing>' }
        $info = ($Pre.Contains($k) -and $Pre[$k].info) -or ($Post.Contains($k) -and $Post[$k].info)
        if ($a -ceq $b) { if (-not $info) { $pass++ }; Write-R ('{0} {1}' -f $(if ($info) { 'INFO-SAME' } else { 'PASS' }), $k) 'DIFF'; continue }
        if ($info) { Write-R ('INFO-CHANGED {0}' -f $k) 'DIFF' } else { $fail++; Write-R ('FAIL {0}' -f $k) 'DIFF' }
        Write-R ('    pre : ' + ($a -replace "`n", ' | ')) 'DIFF'
        Write-R ('    post: ' + ($b -replace "`n", ' | ')) 'DIFF'
    }
    $verdict = if ($fail -eq 0) { 'PASS' } else { 'FAIL' }
    Write-R ('DIFF RESULT: {0} ({1} items equal, {2} differ; INFO items not counted)' -f $verdict, $pass, $fail) 'DIFF'
    return ($fail -eq 0)
}

# ----------------------------------------------------------------------------- user-session execution
# Agent and SendInput must run in the interactive (console) session of the target user, non-elevated.
# A temporary scheduled task with LogonType Interactive does that even when this script runs over SSH (session 0).
function Invoke-UserTask {
    param([string]$Name, [string]$ScriptPath, [string[]]$Arguments = @(), [switch]$Wait, [int]$TimeoutSec = 60)
    $taskName = $HT.TaskPrefix + 'User-' + $Name
    $quoted = @($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $ScriptPath, $quoted
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId $script:Ctx.TargetUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Add-StateAction 'userTasks' $taskName
    Start-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    $ok = $true
    if ($Wait) {
        $t0 = Get-Date
        Start-Sleep -Milliseconds 700
        while ((Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue).State -eq 'Running') {
            if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) { $ok = $false; Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue; break }
            Start-Sleep -Milliseconds 300
        }
    }
    else { Start-Sleep -Seconds 2 }
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    return $ok
}
function Remove-HwTestUserTasks {
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like ($HT.TaskPrefix + 'User-*') })) {
        Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------------- watchdog
function Register-Watchdog {
    param([long]$DeadlineMs)
    $at = [DateTimeOffset]::FromUnixTimeMilliseconds($DeadlineMs).LocalDateTime
    $script_ = Join-Path $script:Ctx.SuiteDir 'Watchdog.ps1'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script_)
    $t1 = New-ScheduledTaskTrigger -Once -At $at
    $t1.EndBoundary = $at.AddDays(7).ToString('s')
    $t2 = New-ScheduledTaskTrigger -AtStartup          # machine rebooted mid-test: restore right after boot
    $t2.Delay = 'PT1M'
    $t2.EndBoundary = $at.AddDays(7).ToString('s')
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -DeleteExpiredTaskAfter (New-TimeSpan -Days 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $chk = Get-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -ErrorAction Stop
    Write-R ('Watchdog task {0} registered (SYSTEM, one-shot at {1}, plus at-startup trigger). State={2}' -f $HT.WatchdogTask, $at.ToString('yyyy-MM-ddTHH:mm:ss'), $chk.State)
}
function Unregister-Watchdog {
    if (Get-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
        Write-R 'Watchdog task removed.'
    }
}

# ----------------------------------------------------------------------------- Options+ stop / restore
function Stop-OptionsPlus {
    param($Pre)
    Write-Section 'STOP Options+'
    foreach ($n in $HT.OptionsPlusServices) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { Write-R ("Service {0} not present - skipped" -f $n) 'WARN'; continue }
        Add-StateAction 'servicesChanged' $n
        Set-Service -Name $n -StartupType Manual -ErrorAction Continue
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $n -Force -ErrorAction Continue
            try { $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30)) } catch { Write-R ("Service {0} did not reach Stopped in 30s: {1}" -f $n, $_) 'ERROR' }
        }
        Write-R ("Service {0}: StartType={1} Status={2}" -f $n, (Get-ServiceStartType $n), (Get-Service -Name $n).Status)
    }
    foreach ($t in Get-LogiTasks) {
        if ($t.TaskName -match 'openlogi' -or $t.TaskName -like ($HT.TaskPrefix + '*')) { continue }
        if ($t.State -ne 'Disabled') {
            Add-StateAction 'tasksDisabled' ('{0}|{1}' -f $t.TaskPath, $t.TaskName)
            Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Continue | Out-Null
            Write-R ("Scheduled task disabled: {0}{1}" -f $t.TaskPath, $t.TaskName)
        }
    }
    Stop-OptionsPlusProcesses 'initial'
}
function Stop-OptionsPlusProcesses([string]$Why) {
    foreach ($p in Get-OptionsPlusTargetProcesses) {
        $parent = ''
        try { $pp = (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $p.Id)).ParentProcessId; $parent = '{0}({1})' -f (Get-Process -Id $pp -ErrorAction Stop).Name, $pp } catch { $parent = '?' }
        Write-R ("Kill [{0}] {1} pid={2} parent={3}" -f $Why, $p.Name, $p.Id, $parent) $(if ($Why -eq 'initial') { 'INFO' } else { 'RESPAWN' })
        Add-StateAction 'killed' $p.Name
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
function Watch-OptionsPlusRespawn([int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds); $n = 0
    while ((Get-Date) -lt $end) {
        $ps = Get-OptionsPlusTargetProcesses
        if ($ps.Count -gt 0) { $n += $ps.Count; Stop-OptionsPlusProcesses 'respawn' }
        Start-Sleep -Seconds 2
    }
    Write-R ("Respawn check ({0}s): {1} respawned Options+ process(es)" -f $Seconds, $n)
}
function ConvertTo-ScStart([string]$t) {
    switch ($t) { 'Automatic' { 'auto' } 'AutomaticDelayed' { 'delayed-auto' } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { $null } }
}
# Idempotent: drives the current state toward the pre-snapshot. Safe to run any number of times.
function Restore-OptionsPlus {
    param($Pre)
    Write-Section 'RESTORE Options+'
    $names = @(Get-SnapLines $Pre 'svc.names') + @($HT.OptionsPlusServices)
    foreach ($n in ($names | Sort-Object -Unique)) {
        $want = Get-SnapValue $Pre ("svc.{0}.starttype" -f $n)
        $wantStatus = Get-SnapValue $Pre ("svc.{0}.status" -f $n)
        if (-not $Pre) { $want = 'Automatic'; $wantStatus = 'Running' }   # emergency fallback per guide 2.2 ("normally AUTO_START")
        if (-not $want -or $want -eq 'Absent') { continue }
        if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { Write-R ("Service {0} missing now" -f $n) 'ERROR'; continue }
        $cur = Get-ServiceStartType $n
        if ($cur -ne $want) {
            $m = ConvertTo-ScStart $want
            if ($m) { $o = & sc.exe config $n start= $m 2>&1; Write-R ("sc config {0} start= {1}: {2}" -f $n, $m, (($o | Out-String).Trim() -replace '\s+', ' ')) }
        }
        if ($wantStatus -eq 'Running' -and (Get-Service -Name $n).Status -ne 'Running') {
            Start-Service -Name $n -ErrorAction Continue
            try { (Get-Service -Name $n).WaitForStatus('Running', (New-TimeSpan -Seconds 30)) } catch { Write-R ("Service {0} not Running after 30s" -f $n) 'ERROR' }
        }
        Write-R ("Service {0}: StartType={1} (want {2}) Status={3} (want {4})" -f $n, (Get-ServiceStartType $n), $want, (Get-Service -Name $n).Status, $wantStatus)
    }
    $st = $script:Ctx
    foreach ($t in @($st.Actions.tasksDisabled)) {
        $parts = ([string]$t) -split '\|', 2
        Enable-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction Continue | Out-Null
        Write-R ("Scheduled task re-enabled: {0}{1}" -f $parts[0], $parts[1])
    }
    # Background processes that were running before: wait for the service to bring them back, else start them as the user.
    $wantProcs = @(Get-SnapLines $Pre 'proc.logi.names')
    $paths = @{}
    foreach ($l in (Get-SnapLines $Pre 'info.proc.logi.paths')) { $kv = $l -split '=', 2; if ($kv.Count -eq 2 -and $kv[1]) { $paths[$kv[0]] = $kv[1] } }
    $need = @($HT.OptionsPlusUserRestart | Where-Object { $wantProcs -contains $_ })
    if ($need.Count -gt 0) {
        $end = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $end) {
            $missing = @($need | Where-Object { -not (Get-Process -Name $_ -ErrorAction SilentlyContinue) })
            if ($missing.Count -eq 0) { break }
            Start-Sleep -Seconds 3
        }
        foreach ($m in @($need | Where-Object { -not (Get-Process -Name $_ -ErrorAction SilentlyContinue) })) {
            if ($paths.ContainsKey($m) -and (Test-Path -LiteralPath $paths[$m]) -and $st.TargetUser -and (Get-ConsoleUser)) {
                Write-R ("{0} not back after 45s - starting it in the user session: {1}" -f $m, $paths[$m]) 'WARN'
                $helper = Join-Path $st.SuiteDir 'UserSide.ps1'
                Invoke-UserTask -Name ('Restore-' + $m) -ScriptPath $helper -Arguments @('-Action', 'StartProcess', '-Exe', $paths[$m]) -Wait -TimeoutSec 30 | Out-Null
            }
            else { Write-R ("{0} was running before but is not running now and cannot be started automatically" -f $m) 'ERROR' }
        }
    }
    Write-R ('Logi processes now: ' + ((@(Get-LogiProcesses | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '))
}

# ----------------------------------------------------------------------------- OpenLogi stop / cleanup
function Stop-OpenLogi {
    foreach ($n in $HT.OpenLogiProcessNames) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            Write-R ("Kill OpenLogi process {0} pid={1}" -f $p.Name, $p.Id)
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 800
    $left = Get-OpenLogiProcesses
    if ($left.Count -gt 0) { Write-R ('OpenLogi processes still alive: ' + (($left | ForEach-Object { $_.Name + ':' + $_.Id }) -join ', ')) 'ERROR' }
}
function Add-TestFirewallRules {
    param([string]$AgentExe, [int]$Port, [string]$FwProfile)
    $prof = if ($FwProfile -eq 'Any') { 'Any' } else { $FwProfile }
    foreach ($r in @(@{ n = 'OpenLogiHwTest-UDP-' + $Port; d = 'OpenLogi HW test - Flow UDP ' + $Port; p = $Port }, @{ n = 'OpenLogiHwTest-mDNS-5353'; d = 'OpenLogi HW test - mDNS UDP 5353'; p = 5353 })) {
        New-NetFirewallRule -Name $r.n -DisplayName $r.d -Group $HT.FirewallGroup -Direction Inbound -Action Allow -Protocol UDP -LocalPort $r.p -Profile $prof -Program $AgentExe -ErrorAction Stop | Out-Null
        Add-StateAction 'firewallRules' $r.n
        Write-R ("Firewall rule added: {0} (profile {1}, program {2})" -f $r.n, $prof, $AgentExe)
    }
}
function Remove-TestFirewallRules {
    param($Pre)
    $preNames = @{}
    foreach ($l in (Get-SnapLines $Pre 'firewall.openlogi')) { $preNames[($l -split '\|')[0]] = $true }
    foreach ($l in (Get-OpenLogiFirewallRules)) {
        $name = ($l -split '\|')[0]
        if ($preNames.ContainsKey($name)) { continue }   # existed before the test -> keep
        Remove-NetFirewallRule -Name $name -ErrorAction Continue
        Write-R ("Firewall rule removed: {0}" -f $l)
    }
}
function Remove-PathSafe([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    for ($i = 0; $i -lt 5; $i++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { Write-R ("Removed {0}" -f $Path); return }
        Start-Sleep -Seconds 1
    }
    Write-R ("Could not remove {0}" -f $Path) 'ERROR'
}
function Backup-ExistingOpenLogiDirs {
    foreach ($d in @($script:Ctx.ConfigDir, $script:Ctx.StateDir, $script:Ctx.DataDir)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            $dst = Join-Path $script:Ctx.BackupDir ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($d)).Replace('/', '_'))
            & robocopy.exe $d $dst /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw ("backup of {0} failed (robocopy {1})" -f $d, $LASTEXITCODE) }
            Add-StateAction 'backups' ('{0}|{1}' -f $d, $dst)
            Write-R ("Pre-existing OpenLogi dir backed up: {0}" -f $d) 'WARN'
        }
    }
}
function Remove-TestFiles {
    param($Pre)
    Write-Section 'CLEANUP files'
    Remove-PathSafe $script:Ctx.PkgDir
    foreach ($d in @($script:Ctx.ConfigDir, $script:Ctx.StateDir, $script:Ctx.DataDir) + @($script:Ctx.ExtraDirs)) {
        if (-not $d) { continue }
        $preVal = Get-SnapValue $Pre ('dir.openlogi:' + $d)
        if (-not $preVal) { $preVal = Get-SnapValue $Pre ('path.exists:' + $d) }
        $backup = @($script:Ctx.Actions.backups | Where-Object { ([string]$_).StartsWith($d + '|') }) | Select-Object -First 1
        if ($backup) {
            $src = (([string]$backup) -split '\|', 2)[1]
            Remove-PathSafe $d
            & robocopy.exe $src $d /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            Write-R ("Restored pre-existing {0} from backup (robocopy exit {1})" -f $d, $LASTEXITCODE)
        }
        elseif ($preVal -eq 'absent' -or $preVal -eq 'False') { Remove-PathSafe $d }
        elseif (-not $Pre) { Write-R ("No snapshot: leaving {0} in place (cannot tell whether it pre-existed)" -f $d) 'WARN' }
    }
    # Parents created by the test (e.g. %USERPROFILE%\.local) - deepest first, only if empty.
    foreach ($d in @($script:Ctx.ParentDirs | Sort-Object { $_.Length } -Descending)) {
        if ((Get-SnapValue $Pre ('path.exists:' + $d)) -eq 'False' -and (Test-Path -LiteralPath $d)) {
            if (@(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-PathSafe $d }
            else { Write-R ("{0} was created during the test but is not empty - left in place" -f $d) 'WARN' }
        }
    }
}

# ----------------------------------------------------------------------------- full restore (main, watchdog, emergency)
function Invoke-FullRestore {
    param([string]$Reason, [switch]$FromWatchdog)
    $mutex = New-Object Threading.Mutex($false, $HT.MutexName)
    $got = $false
    try { $got = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) } catch [Threading.AbandonedMutexException] { $got = $true }
    try {
        Write-Section ("FULL RESTORE ({0})" -f $Reason)
        $pre = Read-Snapshot $script:Ctx.PrePath
        if (-not $pre) { Write-R 'Pre-snapshot not found - using guide defaults (OptionsPlusUpdaterService -> Automatic, Running)' 'WARN' }
        Stop-OpenLogi                 # releases the WH_MOUSE_LL / keyboard hooks first
        Remove-HwTestUserTasks
        Restore-OptionsPlus $pre
        Remove-TestFirewallRules $pre
        Remove-TestFiles $pre
        if (-not $FromWatchdog) { Unregister-Watchdog }
        $script:Ctx.Completed = $true; Save-State
        if ($pre) {
            Start-Sleep -Seconds 5
            $post = Get-Snapshot $script:Ctx
            # the watchdog task itself is still registered while the watchdog runs; it removes itself last
            if ($FromWatchdog -and $post.Contains('tasks.hwtest')) { $post['tasks.hwtest'].value = (@(Get-SnapLines $post 'tasks.hwtest') | Where-Object { $_ -ne $HT.WatchdogTask }) -join "`n" }
            Save-Snapshot $post $script:Ctx.PostPath
            $ok = Compare-Snapshots $pre $post
            Write-R ("OVERALL STATE RESTORE: {0}" -f $(if ($ok) { 'PASS' } else { 'FAIL - see FAIL lines above' })) $(if ($ok) { 'INFO' } else { 'ERROR' })
        }
        Remove-PathSafe $script:Ctx.WorkRoot
        if (Test-Path -LiteralPath $script:Ctx.WorkRoot) { Write-R ('Work dir still present: ' + $script:Ctx.WorkRoot) 'ERROR' }
        Write-R ("Only remaining test file: {0}" -f $script:Ctx.ResultLog)
    }
    finally { if ($got) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

# ----------------------------------------------------------------------------- agent CLI / log parsing
function Invoke-Cli {
    param([string[]]$CliArgs, [int]$TimeoutSec = 15)
    $cli = Join-Path $script:Ctx.PkgDir 'bin\openlogi.exe'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cli
    $psi.Arguments = (@($CliArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['USERPROFILE'] = $script:Ctx.Profile
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' } }
    [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}
function Get-CliJson([string[]]$CliArgs) {
    $r = Invoke-Cli $CliArgs
    if (-not $r.Out) { return $null }
    try { return ($r.Out | ConvertFrom-Json) } catch { return $null }
}
function Get-AgentEvents {
    param([long]$SinceMs)
    $res = @()
    $dir = $script:Ctx.StateDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $res }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'agent*.log' -File -ErrorAction SilentlyContinue)) {
        $fs = $null
        try {
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            $sr = New-Object IO.StreamReader($fs)
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line -notmatch '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s+([A-Z]+)\s+(.*)$') { continue }
                $ts = $Matches[1]; $lvl = $Matches[2]; $rest = $Matches[3]
                $ev = $null
                foreach ($pat in $script:FlowEventPatterns) { if ($rest.Contains($pat)) { $ev = $pat; break } }
                if (-not $ev) { continue }
                $ms = [DateTimeOffset]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeMilliseconds()
                if ($ms -lt $SinceMs) { continue }
                $fields = @{}
                foreach ($m in [regex]::Matches($rest, '(\w+)=("[^"]*"|\S+)')) { $fields[$m.Groups[1].Value] = $m.Groups[2].Value.Trim('"') }
                $res += [pscustomobject]@{ Ms = $ms; Level = $lvl; Event = $ev; Fields = $fields; Line = $line }
            }
        }
        catch {} finally { if ($fs) { $fs.Dispose() } }
    }
    @($res | Sort-Object Ms)
}
function Format-Event($e) {
    $f = @($e.Fields.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $e.Fields[$_] }) -join ' '
    if ($e.Fields.ContainsKey('outcome')) { $f += ' (' + $script:OutcomeNames[[string]$e.Fields['outcome']] + ')' }
    '{0} {1} "{2}" {3}' -f (Format-Ms $e.Ms), $e.Level, $e.Event, $f
}

# ----------------------------------------------------------------------------- Flow layout in config.toml (schema: crates/openlogi-core/src/config/flow.rs)
# [[flow.layout]] { edge = "left"|"right"|"top"|"bottom", peer = "<[[flow.peers]].name>" }
# Layout peers must already exist (UnknownLayoutPeer otherwise). After writing, call `openlogi flow enable` to reload from disk.
function Set-OpenLogiFlowLayout {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][ValidateSet('left', 'right', 'top', 'bottom')][string]$Edge,
        [Parameter(Mandatory = $true)][string]$Peer,
        [int]$Port = 42424
    )
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $layoutBlock = @"
[[flow.layout]]
edge = "$Edge"
peer = "$Peer"
"@
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $fresh = @"
schema_version = 8

[flow]
enabled = true
port = $Port

$layoutBlock
"@
        Set-Content -LiteralPath $ConfigPath -Value $fresh -Encoding UTF8
        Write-R ("Wrote new config.toml with [[flow.layout]] edge={0} peer={1}" -f $Edge, $Peer)
        return
    }
    $text = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    if ($null -eq $text) { $text = '' }
    # Drop every existing [[flow.layout]] table (until the next TOML table header).
    $text = [regex]::Replace($text, '(?ms)^\[\[flow\.layout\]\][^\r\n]*\r?\n(?:^(?!\[).*\r?\n)*', '')
    # Ensure [flow] exists; do not invent peers/devices (pairing owns those).
    if ($text -notmatch '(?m)^\[flow\]\s*$') {
        $text = $text.TrimEnd() + "`r`n`r`n[flow]`r`nenabled = true`r`nport = $Port`r`n"
    }
    else {
        # Best-effort: make sure enabled/port are present under [flow] (leave other keys alone).
        if ($text -notmatch '(?m)^enabled\s*=') {
            $text = [regex]::Replace($text, '(?m)^\[flow\]\s*$', "[flow]`r`nenabled = true")
        }
        if ($text -notmatch '(?m)^port\s*=') {
            $text = [regex]::Replace($text, '(?m)^\[flow\]\s*$', "[flow]`r`nport = $Port")
        }
    }
    $text = $text.TrimEnd() + "`r`n`r`n" + $layoutBlock + "`r`n"
    Set-Content -LiteralPath $ConfigPath -Value $text -Encoding UTF8
    Write-R ("Updated config.toml [[flow.layout]] edge={0} peer={1} at {2}" -f $Edge, $Peer, $ConfigPath)
}

function Resolve-FlowPeerName {
    param([string]$Preferred)
    if ($Preferred) { return $Preferred }
    # `openlogi flow status` prints FlowStatus JSON (enabled/peers/pairing), not the api envelope.
    $fs = $null
    $r = Invoke-Cli @('flow', 'status')
    if ($r.Out) { try { $fs = $r.Out | ConvertFrom-Json } catch {} }
    if ($fs -and $fs.peers) {
        $list = @($fs.peers)
        if ($list.Count -gt 0 -and $list[0].name) { return [string]$list[0].name }
    }
    return $null
}

function Apply-FlowLayoutAndReload {
    param([string]$Edge, [string]$PeerNamePreferred, [int]$Port)
    $peer = Resolve-FlowPeerName -Preferred $PeerNamePreferred
    if (-not $peer) {
        Write-R ('No Flow peer name available yet (pass -PeerName or finish pairing). Layout NOT written. GM default for this host: edge={0} -> peer=<Mac>' -f $Edge) 'WARN'
        return $false
    }
    $cfg = Join-Path $script:Ctx.ConfigDir 'config.toml'
    Set-OpenLogiFlowLayout -ConfigPath $cfg -Edge $Edge -Peer $peer -Port $Port
    # flow enable reloads config.toml from disk (server.rs flow_set_enabled -> ConfigFile::load_or_default).
    $r = Invoke-Cli @('flow', 'enable')
    Write-R ('flow enable (reload after layout): code={0} out={1} err={2}' -f $r.Code, ($r.Out.Trim()), ($r.Err.Trim()))
    if ($r.Code -ne 0) {
        Write-R 'Layout reload failed — peer name in [[flow.layout]] must match [[flow.peers]].name exactly (hostname of the other machine after pairing).' 'ERROR'
        return $false
    }
    return $true
}

