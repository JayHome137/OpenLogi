# OpenLogi Flow hardware test - shared Windows library (dot-sourced).
# Windows PowerShell 5.1 compatible (no ternary / ?? / -AsHashtable / 3-arg Join-Path). Never run directly.
#
# RUN 2 RULES (see CHANGES-run2.md):
#   * Every pipeline / function result is wrapped in @() before .Count or indexing (StrictMode-safe).
#   * Properties of objects that may be $null or lack the member are read through Get-Prop.
#   * MUTATING actions only touch items listed by exact name/path in ..\allowlist.json (Get-AL).
#     Regex/substring matching is used ONLY for read-only reporting (snapshots, preflight).
#   * Restore is best-effort per item: every item has its own try/catch, a summary is printed at the end.
#   * Watchdog = crash failsafe with a renewable lease (lease.json) + absolute hard cap.
#
# Facts taken from the OpenLogi repo (openlogi-custom @ bd04518f):
#   portable zip layout   .github/workflows/build.yml "Collect signed portable zip artifact"
#                         (OpenLogi.exe, openlogi-overlay.exe, openlogi-agent.exe, bin\openlogi.exe)
#   config/state/data     crates/openlogi-core/src/paths.rs (XDG layout also on Windows)
#   agent log file        crates/openlogi-agent/src/logging.rs  (agent.<date>.log, UTC RFC3339 timestamps)
#   Run key               crates/openlogi-agent/src/autostart/windows.rs (HKCU\...\Run\OpenLogiAgent)
#   Flow CLI              crates/openlogi-cli/src/cmd/flow.rs (status|enable|disable|pair-start|listen|confirm|reject|cancel)
#   Pairing               crates/openlogi-agent-core/src/flow/runtime.rs: the RESPONDER must run `flow listen`
#                         (120 s window) or the initiator's TLS handshake is rejected ("could not connect").
#   FlowStatus JSON       crates/openlogi-ipc/src/ipc.rs (serde externally tagged enums)

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
    LogFilter         = 'info,openlogi_agent_core=debug,openlogi_flow=debug,openlogi_device=debug,openlogi_hid=debug'
    LeaseMinutes      = 20      # lease renewed at every phase and every minute while waiting at a gate
    HardCapMinutes    = 120     # absolute: restore happens after this regardless of lease
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
$script:AL = $null
$script:ALPath = $null
$script:DiffOk = $null
$script:RestoreResults = New-Object System.Collections.ArrayList

# ----------------------------------------------------------------------------- StrictMode-safe helpers
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}
# NOTE: @($null).Count is 1 in PowerShell (5.1 and 7) - an empty command result passed as an argument arrives as $null.
function Get-Count { param($Value) if ($null -eq $Value) { return 0 } return @($Value).Count }

# ----------------------------------------------------------------------------- logging / time
function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Format-Ms([long]$Ms) {
    if ($Ms -le 0) { return 'n/a' }
    [DateTimeOffset]::FromUnixTimeMilliseconds($Ms).ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}
function Write-R {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $Message
    $color = 'Gray'
    switch ($Level) { 'ERROR' { $color = 'Red' } 'WARN' { $color = 'Yellow' } 'SECT' { $color = 'Cyan' } 'GATE' { $color = 'Green' } }
    Write-Host $line -ForegroundColor $color
    if ($script:ResultLog) {
        try { Add-Content -LiteralPath $script:ResultLog -Value $line -Encoding UTF8 -ErrorAction Stop } catch { Write-Host "  (result log write failed: $_)" }
    }
}
function Write-Section([string]$Title) { Write-R ('==== ' + $Title + ' ====') 'SECT' }
function Write-Banner {
    param([string[]]$Lines, [string]$Color = 'Green', [string]$Level = 'INFO')
    $bar = ('#' * 78)
    Write-Host ''
    Write-Host $bar -ForegroundColor $Color
    foreach ($l in @($Lines)) { Write-Host ('##  ' + $l) -ForegroundColor $Color }
    Write-Host $bar -ForegroundColor $Color
    Write-Host ''
    if ($script:ResultLog) {
        foreach ($l in @($Lines)) { try { Add-Content -LiteralPath $script:ResultLog -Value ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $l) -Encoding UTF8 } catch {} }
    }
}

# ----------------------------------------------------------------------------- allowlist (single data source)
function Get-HwAllowlistPath {
    $cands = @((Join-Path $PSScriptRoot 'allowlist.json'), (Join-Path (Split-Path -Parent $PSScriptRoot) 'allowlist.json'))
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
function Import-HwAllowlist {
    param([string]$Path)
    if (-not $Path) { $Path = Get-HwAllowlistPath }
    if (-not $Path) { throw 'allowlist.json not found next to the scripts or one level up - refusing to run (fail closed).' }
    $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $w = Get-Prop $o 'windows'
    if (-not $w) { throw "allowlist.json has no 'windows' section: $Path" }
    $script:AL = $w
    $script:ALPath = $Path
    return $w
}
function Get-AL([string]$Key) {
    if (-not $script:AL) { [void](Import-HwAllowlist) }
    return @(@(Get-Prop $script:AL $Key) | Where-Object { $null -ne $_ })
}
# Resolve {Token}s from the test context. Returns $null if a token has no value (item is then skipped).
function Resolve-AlToken {
    param([string]$Template, $C)
    $map = @{
        '{Profile}' = (Get-Prop $C 'Profile'); '{Sid}' = (Get-Prop $C 'Sid'); '{WorkRoot}' = $HT.WorkRoot
        '{ConfigHome}' = (Get-Prop $C 'ConfigHome'); '{StateHome}' = (Get-Prop $C 'StateHome'); '{DataHome}' = (Get-Prop $C 'DataHome')
        '{PkgRoot}' = (Get-Prop $C 'PkgRoot'); '{Port}' = [string](Get-Prop $C 'Port')
    }
    $out = $Template
    foreach ($k in @($map.Keys)) {
        if ($out.Contains($k)) {
            $v = [string]$map[$k]
            if (-not $v) { return $null }
            $out = $out.Replace($k, $v)
        }
    }
    return $out
}
function Get-AllowedPaths([string]$Key, $C) {
    @(foreach ($t in (Get-AL $Key)) { $r = Resolve-AlToken ([string]$t) $C; if ($r) { $r } })
}
function Test-InList([string]$Value, $List) {
    if (-not $Value -or $null -eq $List) { return $false }   # '' never matches; @($null) would otherwise yield one '' entry
    foreach ($x in @($List)) { if ([string]$x -ieq $Value) { return $true } }
    return $false
}

# ----------------------------------------------------------------------------- identity / paths
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-IsSystem { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18' }
function Get-ConsoleUser {
    try { return [string](Get-Prop (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1) 'UserName') } catch { return $null }
}
function Get-UserSid([string]$User) {
    try { return (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}
function Get-ProfilePath([string]$Sid) {
    try { return [string](Get-Prop (Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $Sid) -ErrorAction Stop | Select-Object -First 1) 'LocalPath') } catch { return $null }
}
function Get-UserEnvValue([string]$Sid, [string]$Name) {
    try { return Get-Prop (Get-ItemProperty -LiteralPath ("Registry::HKEY_USERS\{0}\Environment" -f $Sid) -Name $Name -ErrorAction Stop) $Name } catch { return $null }
}
function Test-ScreenLocked {
    # LogonUI.exe runs in the console session while the workstation is locked (heuristic, read-only).
    return ((Get-Count (Get-Process -Name LogonUI -ErrorAction SilentlyContinue)) -gt 0)
}

# Context (target user, paths). Same rules as crates/openlogi-core/src/paths.rs.
function New-HwContext {
    param([string]$TargetUser)
    if (-not $TargetUser) { $TargetUser = Get-ConsoleUser }
    $sid = $null; if ($TargetUser) { $sid = Get-UserSid $TargetUser }
    $profileDir = $null; if ($sid) { $profileDir = Get-ProfilePath $sid }
    $c = [ordered]@{
        Version = 2
        TargetUser = $TargetUser; Sid = $sid; Profile = $profileDir
        WorkRoot = $HT.WorkRoot; SuiteDir = (Join-Path $HT.WorkRoot 'suite')
        StatePath = (Join-Path $HT.WorkRoot 'state.json'); LeasePath = (Join-Path $HT.WorkRoot 'lease.json')
        PrePath = (Join-Path $HT.WorkRoot 'snapshot-pre.json'); PostPath = (Join-Path $HT.WorkRoot 'snapshot-post.json')
        BackupDir = (Join-Path $HT.WorkRoot 'backup')
        ResultLog = $null; PkgDir = $null; PkgRoot = $null; IoDir = $null
        ConfigHome = $null; StateHome = $null; DataHome = $null
        ConfigDir = $null; StateDir = $null; DataDir = $null; ParentDirs = @(); ExtraDirs = @()
        MainPid = $PID; MainStartUtc = ''
        StartedMs = (Get-NowMs); DeadlineMs = 0; HardCapMs = 0; Completed = $false
        Port = 42424
        Actions = [ordered]@{ servicesChanged = @(); tasksDisabled = @(); firewallRules = @(); userTasks = @(); backups = @(); killed = @() }
    }
    try { $c.MainStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') } catch {}
    if ($profileDir) {
        $cfgHome = Get-UserEnvValue $sid 'XDG_CONFIG_HOME'; if (-not $cfgHome -or -not [IO.Path]::IsPathRooted($cfgHome)) { $cfgHome = Join-Path $profileDir '.config' }
        $stHome = Get-UserEnvValue $sid 'XDG_STATE_HOME'; if (-not $stHome -or -not [IO.Path]::IsPathRooted($stHome)) { $stHome = Join-Path $profileDir '.local\state' }
        $dtHome = Get-UserEnvValue $sid 'XDG_DATA_HOME'; if (-not $dtHome -or -not [IO.Path]::IsPathRooted($dtHome)) { $dtHome = Join-Path $profileDir '.local\share' }
        $c.ConfigHome = $cfgHome; $c.StateHome = $stHome; $c.DataHome = $dtHome
        $c.ConfigDir = Join-Path $cfgHome 'openlogi'
        $c.StateDir = Join-Path $stHome 'openlogi'
        $c.DataDir = Join-Path $dtHome 'openlogi'
        $c.ResultLog = Join-Path $profileDir $HT.ResultName
        $c.PkgDir = Join-Path $profileDir $HT.PkgName
        $c.IoDir = Join-Path $c.PkgDir 'io'
        $c.ParentDirs = @(Get-AllowedPaths 'pathsRemoveIfCreatedAndEmpty' $c)
        $skip = @($c.ConfigDir, $c.StateDir, $c.DataDir, $HT.WorkRoot, $c.PkgDir)
        $c.ExtraDirs = @(Get-AllowedPaths 'pathsRemoveIfAbsentBefore' $c | Where-Object { -not (Test-InList $_ $skip) })
    }
    return $c
}

function Save-State {
    if (-not $script:Ctx) { return }
    if (-not (Test-Path -LiteralPath $HT.WorkRoot)) { return }
    $p = Join-Path $HT.WorkRoot 'state.json'
    $tmp = $p + '.tmp'
    ($script:Ctx | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $p -Force
}
# Reads state.json (also run-1 state files, which lack the v2 keys -> defaults filled in).
function Read-State {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $HT.WorkRoot 'state.json' }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $h = [ordered]@{}
    foreach ($pr in @($o.PSObject.Properties)) { $h[$pr.Name] = $pr.Value }
    $a = [ordered]@{}
    $act = Get-Prop $o 'Actions'
    foreach ($k in @('servicesChanged', 'tasksDisabled', 'firewallRules', 'userTasks', 'backups', 'killed')) {
        $a[$k] = @(@(Get-Prop $act $k) | Where-Object { $null -ne $_ })
    }
    $h['Actions'] = $a
    foreach ($k in @('ParentDirs', 'ExtraDirs')) { $h[$k] = @(@(Get-Prop $o $k) | Where-Object { $null -ne $_ }) }
    $defaults = [ordered]@{
        Version = 1; TargetUser = $null; Sid = $null; Profile = $null; WorkRoot = $HT.WorkRoot; SuiteDir = (Join-Path $HT.WorkRoot 'suite')
        StatePath = $Path; LeasePath = (Join-Path $HT.WorkRoot 'lease.json'); PrePath = (Join-Path $HT.WorkRoot 'snapshot-pre.json')
        PostPath = (Join-Path $HT.WorkRoot 'snapshot-post.json'); BackupDir = (Join-Path $HT.WorkRoot 'backup')
        ResultLog = $null; PkgDir = $null; PkgRoot = $null; IoDir = $null; ConfigHome = $null; StateHome = $null; DataHome = $null
        ConfigDir = $null; StateDir = $null; DataDir = $null; MainPid = 0; MainStartUtc = ''; StartedMs = 0; DeadlineMs = 0; HardCapMs = 0
        Completed = $false; Port = 42424
    }
    foreach ($k in @($defaults.Keys)) { if (-not $h.Contains($k)) { $h[$k] = $defaults[$k] } }
    # run-1 states: PkgDir pointed at the extracted root; derive missing XDG homes from the dirs.
    if (-not $h['PkgRoot'] -and $h['PkgDir']) { $h['PkgRoot'] = $h['PkgDir'] }
    if (-not $h['ConfigHome'] -and $h['ConfigDir']) { $h['ConfigHome'] = Split-Path -Parent ([string]$h['ConfigDir']) }
    if (-not $h['StateHome'] -and $h['StateDir']) { $h['StateHome'] = Split-Path -Parent ([string]$h['StateDir']) }
    if (-not $h['DataHome'] -and $h['DataDir']) { $h['DataHome'] = Split-Path -Parent ([string]$h['DataDir']) }
    # run-1 PkgDir was overwritten with the extracted root; the allowlisted package dir is {Profile}\OpenLogi-hwtest-pkg.
    if ($h['Profile']) { $h['PkgDir'] = ([string]$h['Profile']).TrimEnd('\') + '\' + $HT.PkgName }
    return $h
}
function Add-StateAction([string]$Kind, $Value) {
    $script:Ctx.Actions[$Kind] = @(@($script:Ctx.Actions[$Kind]) + @($Value))
    Save-State
}

# ----------------------------------------------------------------------------- lease / watchdog decision
# Pure decision function (unit-tested). Order: no state > completed > hard cap > main dead > lease.
function Get-LeaseDecision {
    param([long]$NowMs, [long]$LeaseUntilMs, [long]$HardCapMs, [bool]$Completed, [bool]$MainAlive, [bool]$StateExists)
    if (-not $StateExists) { return 'exit-nostate' }
    if ($Completed) { return 'exit-completed' }
    if ($HardCapMs -gt 0 -and $NowMs -ge $HardCapMs) { return 'fire-hardcap' }
    if (-not $MainAlive) { return 'fire-main-dead' }
    if ($LeaseUntilMs -le 0 -or $NowMs -ge $LeaseUntilMs) { return 'fire-lease-expired' }
    return 'wait'
}
function Get-NextLeaseUntil {
    param([long]$NowMs, [int]$LeaseMinutes, [long]$HardCapMs)
    $l = $NowMs + [long]$LeaseMinutes * 60000
    if ($HardCapMs -gt 0 -and $l -gt $HardCapMs) { $l = $HardCapMs }
    return $l
}
function Read-Lease {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $HT.WorkRoot 'lease.json' }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
    return [pscustomobject]@{ LeaseUntilMs = [long](Get-Prop $o 'leaseUntilMs'); HardCapMs = [long](Get-Prop $o 'hardCapMs'); Phase = [string](Get-Prop $o 'phase'); RenewedMs = [long](Get-Prop $o 'renewedMs') }
}
function Update-Lease {
    param([string]$Phase = '', [switch]$Quiet, [switch]$ToHardCap)
    if (-not $script:Ctx -or -not (Get-Prop $script:Ctx 'HardCapMs')) { return }
    $now = Get-NowMs
    if ($ToHardCap) { $until = [long]$script:Ctx.HardCapMs } else { $until = Get-NextLeaseUntil -NowMs $now -LeaseMinutes $HT.LeaseMinutes -HardCapMs ([long]$script:Ctx.HardCapMs) }
    $script:Ctx.DeadlineMs = $until
    $o = [ordered]@{ leaseUntilMs = $until; hardCapMs = [long]$script:Ctx.HardCapMs; renewedMs = $now; phase = $Phase; mainPid = $script:Ctx.MainPid }
    $p = [string]$script:Ctx.LeasePath
    if ($p -and (Test-Path -LiteralPath (Split-Path -Parent $p))) {
        $tmp = $p + '.tmp'
        ($o | ConvertTo-Json) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $p -Force
    }
    if (-not $Quiet) { Write-R ('Lease renewed (phase {0}). {1}' -f $Phase, (Format-LeaseStatus)) }
}
function Format-LeaseStatus {
    if (-not $script:Ctx -or -not (Get-Prop $script:Ctx 'HardCapMs')) { return 'lease: n/a' }
    $now = Get-NowMs
    $l = [Math]::Max([long]0, [long]$script:Ctx.DeadlineMs - $now) / 60000.0   # [long]0: an int 0 picks Max(int,int) -> overflow
    $h = [Math]::Max([long]0, [long]$script:Ctx.HardCapMs - $now) / 60000.0
    $capAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$script:Ctx.HardCapMs).ToLocalTime().ToString('HH:mm')
    return ('看门狗租约剩余 {0:N1} 分钟(脚本活着就每分钟自动续期) | 硬上限剩余 {1:N0} 分钟(到 {2} 无论如何自动恢复)' -f $l, $h, $capAt)
}
function Assert-HardCap {
    if ($script:Ctx -and (Get-Prop $script:Ctx 'HardCapMs') -and (Get-NowMs) -ge [long]$script:Ctx.HardCapMs) { throw 'HARD CAP reached - aborting test and restoring.' }
}
function Test-MainAlive {
    param($State)
    $mp = [int](Get-Prop $State 'MainPid')
    if ($mp -le 0) { return $false }
    $p = Get-Process -Id $mp -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $false }
    if ([string](Get-Prop $p 'Name') -notmatch '^(powershell|pwsh)$') { return $false }
    $want = [string](Get-Prop $State 'MainStartUtc')
    if ($want) {
        try {
            $st = Get-Prop $p 'StartTime'
            if ($st -and ([Math]::Abs(($st.ToUniversalTime() - [DateTime]::Parse($want).ToUniversalTime()).TotalSeconds) -gt 2)) { return $false }
        }
        catch {}
    }
    return $true
}

# ----------------------------------------------------------------------------- human gates (no countdowns)
$script:GateBuffer = ''
$script:GateConsoleOk = $null
# Returns a complete input line when Enter was pressed, otherwise $null (non-blocking). Mocked in tests.
function Read-GateKeyLine {
    if ($null -eq $script:GateConsoleOk) {
        try { [void][Console]::KeyAvailable; $script:GateConsoleOk = $true } catch { $script:GateConsoleOk = $false }
    }
    if (-not $script:GateConsoleOk) {
        # Non-interactive host (ISE / redirected stdin): blocking Read-Host. Lease is pushed to the hard cap first.
        Update-Lease -Phase 'gate-blocking-read' -ToHardCap -Quiet
        Write-R 'Console has no key polling (ISE/redirected?) - lease extended to the hard cap while waiting for input.' 'WARN'
        return [string](Read-Host '>')
    }
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ''; $line = $script:GateBuffer; $script:GateBuffer = ''; return $line }
        if ($k.Key -eq 'Backspace') { if ($script:GateBuffer.Length -gt 0) { $script:GateBuffer = $script:GateBuffer.Substring(0, $script:GateBuffer.Length - 1); Write-Host "`b `b" -NoNewline }; continue }
        if ($k.KeyChar -ne [char]0) { $script:GateBuffer += $k.KeyChar; Write-Host $k.KeyChar -NoNewline }
    }
    return $null
}
function Start-GateSleep([int]$Ms) { Start-Sleep -Milliseconds $Ms }   # separate so tests can mock it
# Generic interactive gate. Never counts down; renews the lease every minute.
# $Check returns @{ Done = bool; Status = string }. Returns 'done' | 'skip' | one of $Commands.
# Throws System.OperationCanceledException on 'abort'.
function Wait-HumanGate {
    param(
        [string]$Title, [string[]]$Lines = @(), [scriptblock]$Check, [int]$PollSec = 5,
        [string[]]$Commands = @(), [switch]$AutoContinue, [string]$Phase = 'gate', [int]$MaxIterations = 0
    )
    $extra = ''; if ((Get-Count $Commands) -gt 0) { $extra = '   其它命令: ' + ($Commands -join ' / ') }
    Write-Banner -Lines (@($Title, '') + @($Lines) + @('', (Format-LeaseStatus), ('输入: [回车]=我做完了,重新检查   skip=跳过此步   abort=中止测试并自动恢复' + $extra))) -Color 'Green' -Level 'GATE'
    Write-R ('GATE OPEN: {0}' -f $Title) 'GATE'
    Update-Lease -Phase $Phase -Quiet
    $lastRenew = Get-NowMs; $lastCheck = 0; $lastStatus = ''; $i = 0
    while ($true) {
        $i++
        if ($MaxIterations -gt 0 -and $i -gt $MaxIterations) { throw 'Wait-HumanGate: MaxIterations exceeded (test guard)' }
        Assert-HardCap
        $now = Get-NowMs
        if (($now - $lastRenew) -ge 60000) { Update-Lease -Phase $Phase -Quiet; $lastRenew = $now; Write-Host ('  .. 仍在等待 [{0}] - {1}' -f $Title, (Format-LeaseStatus)) -ForegroundColor DarkGray }
        if ($Check -and ($now - $lastCheck) -ge ($PollSec * 1000)) {
            $lastCheck = $now
            $r = $null; try { $r = & $Check } catch { $r = @{ Done = $false; Status = ('check error: ' + $_.Exception.Message) } }
            $st = [string](Get-Prop $r 'Status')
            if ($st -and $st -ne $lastStatus) { Write-R ('  status: ' + $st) 'GATE'; $lastStatus = $st }
            if ($AutoContinue -and (Get-Prop $r 'Done')) { Write-R ('GATE PASSED (auto-detected): {0}' -f $Title) 'GATE'; return 'done' }
        }
        $line = Read-GateKeyLine
        if ($null -eq $line) { Start-GateSleep 200; continue }
        $cmd = ([string]$line).Trim().ToLowerInvariant()
        if ($cmd -eq 'abort') { Write-R ('GATE ABORT by user: {0}' -f $Title) 'ERROR'; throw (New-Object System.OperationCanceledException ('aborted by user at gate: ' + $Title)) }
        if ($cmd -eq 'skip') { Write-R ('GATE SKIPPED by user: {0}' -f $Title) 'WARN'; return 'skip' }
        if ($cmd -and (Test-InList $cmd $Commands)) { Write-R ('GATE command: {0}' -f $cmd) 'GATE'; return $cmd }
        if ($cmd) { Write-Host ('  未知输入 "{0}"。可用: 回车 / skip / abort {1}' -f $cmd, ($Commands -join ' ')) -ForegroundColor Yellow; continue }
        if (-not $Check) { Write-R ('GATE PASSED (Enter): {0}' -f $Title) 'GATE'; return 'done' }
        $r = $null; try { $r = & $Check } catch { $r = @{ Done = $false; Status = ('check error: ' + $_.Exception.Message) } }
        $lastCheck = Get-NowMs
        if (Get-Prop $r 'Done') { Write-R ('GATE PASSED: {0}' -f $Title) 'GATE'; return 'done' }
        Write-Host ('  还没满足: {0}  (完成后再按回车; 或输入 skip / abort)' -f [string](Get-Prop $r 'Status')) -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------------------- read-only discovery
function Get-ServiceStartType([string]$Name) {
    $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $svc) { return 'Absent' }
    $mode = [string](Get-Prop $svc 'StartMode')   # Auto / Manual / Disabled / Boot / System
    if ($mode -eq 'Auto') {
        $d = $null
        try { $d = Get-Prop (Get-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $Name) -Name DelayedAutostart -ErrorAction Stop) 'DelayedAutostart' } catch {}
        if ($d -eq 1) { return 'AutomaticDelayed' } else { return 'Automatic' }
    }
    return $mode
}
function Get-LogiServices {
    # read-only report (regex OK here); mutations use Get-AL 'services' only
    @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            ([string](Get-Prop $_ 'Name') -match 'logi|OptionsPlus' -or [string](Get-Prop $_ 'DisplayName') -match 'logi') -and [string](Get-Prop $_ 'Name') -notmatch 'openlogi'
        } | Sort-Object Name)
}
function Get-ProcPath($P) { try { return [string](Get-Prop $P 'Path') } catch { return '' } }
function Get-LogiProcesses {
    # read-only report
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'Name') -match 'logi' -and [string](Get-Prop $_ 'Name') -notmatch 'openlogi' })
}
# Options+ processes by EXACT allowlisted name. Each result has .Allowed = exact path match.
function Get-OptionsPlusProcessInfo {
    $out = @()
    foreach ($e in (Get-AL 'optionsPlusProcesses')) {
        $name = [string](Get-Prop $e 'name')
        $paths = @(Get-Prop $e 'paths')
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ([string](Get-Prop $p 'Name') -ine $name) { continue }   # defensive: no wildcard semantics
            $path = Get-ProcPath $p
            $out += [pscustomobject]@{ Id = [int](Get-Prop $p 'Id'); Name = $name; Path = $path; Allowed = [bool]($path -and (Test-InList $path $paths)) }
        }
    }
    @($out | Sort-Object Id -Unique)
}
function Get-OptionsPlusTargetProcesses { @(Get-OptionsPlusProcessInfo | Where-Object { $_.Allowed }) }
# OpenLogi processes by exact name; Allowed only if the path equals the allowlisted path under {PkgRoot}.
function Get-OpenLogiProcessInfo {
    param($C)
    if (-not $C) { $C = $script:Ctx }
    $out = @()
    foreach ($e in (Get-AL 'openLogiProcesses')) {
        $name = [string](Get-Prop $e 'name')
        $want = Resolve-AlToken ([string](Get-Prop $e 'path')) $C
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ([string](Get-Prop $p 'Name') -ine $name) { continue }
            $path = Get-ProcPath $p
            $out += [pscustomobject]@{ Id = [int](Get-Prop $p 'Id'); Name = $name; Path = $path; Allowed = [bool]($want -and $path -and ($path -ieq $want)) }
        }
    }
    @($out | Sort-Object Id -Unique)
}

# --- scheduled tasks
function Get-TaskFullPath($T) { return ([string](Get-Prop $T 'TaskPath') + [string](Get-Prop $T 'TaskName')) }
function Test-IsMicrosoftTaskPath([string]$FullPath) { return $FullPath.StartsWith('\Microsoft\', [StringComparison]::OrdinalIgnoreCase) }
# READ-ONLY classifier (reporting/snapshot). Logitech/Options+ only; never anything under \Microsoft\.
function Test-IsLogiTaskCandidate {
    param($T)
    $full = Get-TaskFullPath $T
    if (-not $full -or (Test-IsMicrosoftTaskPath $full)) { return $false }
    if ($full -match '(?i)logitech|logioptionsplus|logi options') { return $true }
    foreach ($a in @(Get-Prop $T 'Actions')) {
        $exe = [string](Get-Prop $a 'Execute')
        if ($exe -match '(?i)\\Program Files( \(x86\))?\\LogiOptionsPlus\\') { return $true }
    }
    return $false
}
function Get-LogiTasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { Test-IsLogiTaskCandidate $_ }) }
# MUTATION gate for disabling: exact allowlist entry AND not \Microsoft\ (hard denylist).
function Test-TaskDisableAllowed([string]$FullPath) {
    if (Test-IsMicrosoftTaskPath $FullPath) { return $false }
    return (Test-InList $FullPath (Get-AL 'scheduledTasksDisable'))
}
# MUTATION gate for re-enabling a task the test recorded as disabled.
function Test-TaskReEnableAllowed([string]$FullPath) {
    if (Test-InList $FullPath (Get-AL 'scheduledTasksDisable')) { return (-not (Test-IsMicrosoftTaskPath $FullPath)) }
    foreach ($e in (Get-AL 'scheduledTasksRepairEnableOnly')) { if ([string](Get-Prop $e 'path') -ieq $FullPath) { return $true } }
    return $false
}
function Test-OwnTaskAllowed([string]$TaskName) { return (Test-InList ('\' + $TaskName) (Get-AL 'ownScheduledTasks')) }

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
    'present' + "`n" + ((@($lines) | Sort-Object) -join "`n")
}
function Get-RunKeyValues([string]$Sid) {
    # read-only report
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
        foreach ($n in @($item.GetValueNames())) {
            $v = $item.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
            if ($v -is [byte[]]) { $v = (@($v) | ForEach-Object { $_.ToString('x2') }) -join '' }
            $s = '{0}\{1}={2}' -f ($k -replace '^Registry::', ''), $n, $v
            if ($s -match 'logi') { $out += $s }
        }
    }
    @($out | Sort-Object)
}
function Get-AllowedRegistryValueState {
    param($Entry, $C)
    $key = Resolve-AlToken ([string](Get-Prop $Entry 'key')) $C
    $name = [string](Get-Prop $Entry 'value')
    if (-not $key) { return $null }
    $val = '<absent>'
    try {
        $item = Get-Item -LiteralPath ('Registry::' + $key) -ErrorAction Stop
        if (@($item.GetValueNames()) -contains $name) {
            $v = $item.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            if ($v -is [byte[]]) { $v = (@($v) | ForEach-Object { $_.ToString('x2') }) -join '' }
            $val = [string]$v
        }
    }
    catch {}
    return [pscustomobject]@{ Key = $key; Name = $name; Value = $val }
}
function Get-StartupFolderItems([string]$ProfileDir) {
    $dirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")
    if ($ProfileDir) { $dirs += (Join-Path $ProfileDir 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') }
    $out = @()
    foreach ($d in $dirs) { if (Test-Path -LiteralPath $d) { $out += @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'logi' } | ForEach-Object { $_.FullName }) } }
    @($out | Sort-Object)
}
function Get-HwTestFirewallRuleNames { param($C) @(Get-AllowedPaths 'firewallRules' $C) }
function Get-ExistingHwTestFirewallRules {
    param($C)
    $out = @()
    foreach ($n in @(Get-HwTestFirewallRuleNames $C)) {
        $r = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($r) { $out += ('{0}|{1}|{2}' -f $n, (Get-Prop $r 'Enabled'), (Get-Prop $r 'Profile')) }
    }
    @($out | Sort-Object)
}
function Get-OpenLogiFirewallRules {
    # read-only report of ANY rule that mentions OpenLogi (incl. ones Windows created from a firewall prompt)
    $rules = @()
    $rules += @(Get-NetFirewallRule -DisplayName '*OpenLogi*' -ErrorAction SilentlyContinue)
    $rules += @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'Program') -like '*openlogi*' } | Get-NetFirewallRule -ErrorAction SilentlyContinue)
    $seen = @{}
    $out = @()
    foreach ($r in @($rules)) {
        if (-not $r) { continue }
        $n = [string](Get-Prop $r 'Name')
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        $prog = ''; try { $prog = [string](Get-Prop ($r | Get-NetFirewallApplicationFilter -ErrorAction Stop | Select-Object -First 1) 'Program') } catch {}
        $out += ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $n, (Get-Prop $r 'DisplayName'), (Get-Prop $r 'Enabled'), (Get-Prop $r 'Direction'), (Get-Prop $r 'Action'), (Get-Prop $r 'Profile'), $prog)
    }
    @($out | Sort-Object)
}

# Snapshot = ordered map key -> { value = normalized string; info = $true for informational (not part of pass/fail) }
function Get-Snapshot {
    param($C)
    $items = [ordered]@{}
    $add = { param($k, $v, $info) $items[$k] = [ordered]@{ value = [string]$v; info = [bool]$info } }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    & $add 'info.os' ('{0} {1} build {2}' -f (Get-Prop $os 'Caption'), (Get-Prop $os 'Version'), (Get-Prop $os 'BuildNumber')) $true
    & $add 'info.consoleUser' (Get-ConsoleUser) $true
    & $add 'info.screenLocked' (Test-ScreenLocked) $true

    $svcs = @(Get-LogiServices)
    & $add 'info.svc.logi.names' ((@($svcs | ForEach-Object { Get-Prop $_ 'Name' })) -join "`n") $true
    foreach ($e in (Get-AL 'services')) {
        $n = [string](Get-Prop $e 'name')
        & $add ("svc.{0}.starttype" -f $n) (Get-ServiceStartType $n) $false
        $s = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $n) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($s) {
            & $add ("svc.{0}.status" -f $n) ([string](Get-Prop $s 'State')) $false
            & $add ("svc.{0}.imagepath" -f $n) ([string](Get-Prop $s 'PathName')) $false
            $qf = (@(& sc.exe qfailure $n 2>&1 | Where-Object { $_ -match 'RESET_PERIOD|REBOOT_MESSAGE|COMMAND_LINE|FAILURE_ACTIONS|RESTART|RUN PROCESS|REBOOT' } | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })) -join "`n"
            & $add ("svc.{0}.failureactions" -f $n) $qf $false
        }
    }

    $opi = @(Get-OptionsPlusProcessInfo)
    & $add 'proc.optionsplus' ((@($opi | ForEach-Object { '{0}={1}' -f $_.Name, $_.Path }) | Sort-Object -Unique) -join "`n") $false
    & $add 'info.proc.logi.other' ((@(Get-LogiProcesses | ForEach-Object { '{0}={1}' -f (Get-Prop $_ 'Name'), (Get-ProcPath $_) }) | Sort-Object -Unique) -join "`n") $true
    & $add 'proc.openlogi.names' ((@(Get-OpenLogiProcessInfo $C | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join "`n") $false

    & $add 'tasks.logi' ((@(Get-LogiTasks | ForEach-Object { '{0}={1}' -f (Get-TaskFullPath $_), (Get-Prop $_ 'State') }) | Sort-Object) -join "`n") $false
    foreach ($e in (Get-AL 'scheduledTasksRepairEnableOnly')) {
        $full = [string](Get-Prop $e 'path'); $i = $full.LastIndexOf('\')
        $t = Get-ScheduledTask -TaskPath $full.Substring(0, $i + 1) -TaskName $full.Substring($i + 1) -ErrorAction SilentlyContinue | Select-Object -First 1
        $state = 'Absent'; if ($t) { $state = [string](Get-Prop $t 'State') }
        & $add ('task.state:' + $full) $state $false
    }
    $own = @()
    foreach ($tn in (Get-AL 'ownScheduledTasks')) { $n = ([string]$tn).TrimStart('\'); if (Get-ScheduledTask -TaskPath '\' -TaskName $n -ErrorAction SilentlyContinue) { $own += $n } }
    & $add 'tasks.hwtest' ((@($own) | Sort-Object) -join "`n") $false
    & $add 'info.autostart.runkeys.logi' ((@(Get-RunKeyValues $C.Sid)) -join "`n") $true
    foreach ($e in (Get-AL 'registryValuesRemoveIfAbsentBefore')) {
        $rv = Get-AllowedRegistryValueState $e $C
        if ($rv) { & $add ('reg:{0}\{1}' -f $rv.Key, $rv.Name) $rv.Value $false }
    }
    & $add 'info.autostart.startupfolders' ((@(Get-StartupFolderItems $C.Profile)) -join "`n") $true

    & $add 'firewall.hwtest' ((@(Get-ExistingHwTestFirewallRules $C)) -join "`n") $false
    & $add 'info.firewall.openlogi.any' ((@(Get-OpenLogiFirewallRules)) -join "`n") $true
    & $add 'net.udp.listeners' ((@(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { (Get-Prop $_ 'LocalPort') -eq $C.Port } | ForEach-Object { $op = Get-Prop $_ 'OwningProcess'; $(try { (Get-Process -Id $op -ErrorAction Stop).Name } catch { 'pid' + $op }) }) | Sort-Object -Unique) -join "`n") $false
    & $add 'info.net.profiles' ((@(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { '{0}={1}' -f (Get-Prop $_ 'InterfaceAlias'), (Get-Prop $_ 'NetworkCategory') })) -join "`n") $true

    if ($C.Sid) {
        & $add 'env.user.OPENLOGI_LOG' ([string](Get-UserEnvValue $C.Sid 'OPENLOGI_LOG')) $false
        & $add 'env.user.OPENLOGI_PROFILE' ([string](Get-UserEnvValue $C.Sid 'OPENLOGI_PROFILE')) $false
    }
    $menv = $null; try { $menv = Get-Prop (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name OPENLOGI_LOG -ErrorAction Stop) 'OPENLOGI_LOG' } catch {}
    & $add 'env.machine.OPENLOGI_LOG' ([string]$menv) $false

    foreach ($d in @($C.ConfigDir, $C.StateDir, $C.DataDir)) { if ($d) { & $add ('dir.openlogi:' + $d) (Get-DirManifest $d) $false } }
    foreach ($d in @(@($C.ParentDirs) + @($C.ExtraDirs) + @($C.PkgDir))) { if ($d) { & $add ('path.exists:' + $d) (Test-Path -LiteralPath $d) $false } }

    $bt = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'InstanceId') -match '046D' -and ([string](Get-Prop $_ 'Class') -match 'Bluetooth|HIDClass|Mouse|Keyboard') } |
        ForEach-Object { '{0}|{1}|{2}' -f (Get-Prop $_ 'Class'), (Get-Prop $_ 'FriendlyName'), (Get-Prop $_ 'Status') } | Sort-Object -Unique)
    & $add 'info.logitech.pnp' ($bt -join "`n") $true
    return $items
}
function Save-Snapshot($Items, [string]$Path) {
    $o = [ordered]@{ takenAt = (Get-Date).ToString('o'); host = $env:COMPUTERNAME; items = $Items }
    ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Read-Snapshot([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $items = [ordered]@{}
    $it = Get-Prop $o 'items'
    if ($null -eq $it) { return $items }
    foreach ($p in @($it.PSObject.Properties)) { $items[$p.Name] = [ordered]@{ value = [string](Get-Prop $p.Value 'value'); info = [bool](Get-Prop $p.Value 'info') } }
    return $items
}
function Get-SnapValue($Snap, [string]$Key) { if ($Snap -and $Snap.Contains($Key)) { return $Snap[$Key].value } return $null }
function Get-SnapLines($Snap, [string]$Key) { $v = Get-SnapValue $Snap $Key; if (-not $v) { return @() } return @($v -split "`n" | Where-Object { $_ -ne '' }) }
# Normalization: run-1 snapshots listed \Microsoft\ tasks in tasks.logi (wrong matcher) -> drop them on both sides.
function Get-NormalizedSnapValue([string]$Key, [string]$Value) {
    if ($Key -eq 'tasks.logi') { return ((@($Value -split "`n" | Where-Object { $_ -ne '' -and -not $_.StartsWith('\Microsoft\', [StringComparison]::OrdinalIgnoreCase) })) -join "`n") }
    return $Value
}
function Compare-Snapshots($Pre, $Post) {
    Write-Section 'STATE DIFF (pre vs post)'
    $fail = 0; $pass = 0
    $keys = @(@($Pre.Keys) + @(@($Post.Keys) | Where-Object { -not $Pre.Contains($_) }))
    foreach ($k in $keys) {
        $a = '<missing>'; if ($Pre.Contains($k)) { $a = Get-NormalizedSnapValue $k $Pre[$k].value }
        $b = '<missing>'; if ($Post.Contains($k)) { $b = Get-NormalizedSnapValue $k $Post[$k].value }
        $info = ($Pre.Contains($k) -and $Pre[$k].info) -or ($Post.Contains($k) -and $Post[$k].info)
        if ($a -ceq $b) { if (-not $info) { $pass++ }; $tag = 'PASS'; if ($info) { $tag = 'INFO-SAME' }; Write-R ('{0} {1}' -f $tag, $k) 'DIFF'; continue }
        if ($info) { Write-R ('INFO-CHANGED {0}' -f $k) 'DIFF' } else { $fail++; Write-R ('FAIL {0}' -f $k) 'DIFF' }
        Write-R ('    pre : ' + ($a -replace "`n", ' | ')) 'DIFF'
        Write-R ('    post: ' + ($b -replace "`n", ' | ')) 'DIFF'
    }
    $verdict = 'FAIL'; if ($fail -eq 0) { $verdict = 'PASS' }
    Write-R ('DIFF RESULT: {0} ({1} items equal, {2} differ; INFO items not counted)' -f $verdict, $pass, $fail) 'DIFF'
    return ($fail -eq 0)
}

# ----------------------------------------------------------------------------- user-session execution
# Agent and SendInput must run in the interactive (console) session of the target user, non-elevated.
function Invoke-UserTask {
    param([string]$Name, [string]$ScriptPath, [string[]]$Arguments = @(), [switch]$Wait, [int]$TimeoutSec = 60)
    $taskName = $HT.TaskPrefix + 'User-' + $Name
    if (-not (Test-OwnTaskAllowed $taskName)) { throw ("Scheduled task \{0} is not in allowlist.json ownScheduledTasks - refusing to create it." -f $taskName) }
    $quoted = (@($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' })) -join ' '
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
        while ([string](Get-Prop (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -First 1) 'State') -eq 'Running') {
            if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) { $ok = $false; Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue; break }
            Start-Sleep -Milliseconds 300
        }
    }
    else { Start-Sleep -Seconds 2 }
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    return $ok
}
function Remove-HwTestUserTasks {
    foreach ($tn in (Get-AL 'ownScheduledTasks')) {
        $n = ([string]$tn).TrimStart('\')
        if ($n -ieq $HT.WatchdogTask) { continue }
        try {
            if (Get-ScheduledTask -TaskPath '\' -TaskName $n -ErrorAction SilentlyContinue) {
                Stop-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction Stop
                Add-RestoreResult ('task-remove \' + $n) 'OK' ''
            }
        }
        catch { Add-RestoreResult ('task-remove \' + $n) 'ERROR' $_.Exception.Message }
    }
}

# ----------------------------------------------------------------------------- watchdog (lease model)
# Repeating SYSTEM task: runs Watchdog.ps1 every minute; Watchdog.ps1 exits immediately while the lease is fresh
# and the main script is alive. Fires (restore) if lease expired / main died / hard cap reached. Also at startup.
function Register-Watchdog {
    if (-not (Test-OwnTaskAllowed $HT.WatchdogTask)) { throw 'watchdog task not in allowlist' }
    $start = (Get-Date).AddMinutes(1)
    $capMin = [int][Math]::Ceiling(([long]$script:Ctx.HardCapMs - (Get-NowMs)) / 60000.0) + 30
    $script_ = Join-Path $script:Ctx.SuiteDir 'Watchdog.ps1'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script_)
    $t1 = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Minutes $capMin)
    $t2 = New-ScheduledTaskTrigger -AtStartup          # machine rebooted mid-test: restore right after boot
    $t2.Delay = 'PT1M'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $chk = Get-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -ErrorAction Stop | Select-Object -First 1
    Write-R ('Watchdog task {0} registered (SYSTEM, checks lease every 1 min for {1} min, plus at-startup). State={2}' -f $HT.WatchdogTask, $capMin, (Get-Prop $chk 'State'))
}
function Unregister-Watchdog {
    if (Get-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
        Write-R 'Watchdog task removed.'
    }
}

# ----------------------------------------------------------------------------- restore bookkeeping
function Reset-RestoreResults { $script:RestoreResults = New-Object System.Collections.ArrayList }
function Add-RestoreResult([string]$Item, [string]$Status, [string]$Detail) {
    [void]$script:RestoreResults.Add([pscustomobject]@{ Item = $Item; Status = $Status; Detail = $Detail })
    $lvl = 'INFO'; if ($Status -eq 'ERROR') { $lvl = 'ERROR' } elseif ($Status -eq 'WARN' -or $Status -eq 'LEFTOVER') { $lvl = 'WARN' }
    Write-R ('restore[{0}] {1} {2}' -f $Status, $Item, $Detail) $lvl
}
# Runs one restore step; an exception is recorded and the caller continues with the next step.
function Invoke-RestoreStep {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action; Add-RestoreResult ('step ' + $Name) 'OK' '' }
    catch { Add-RestoreResult ('step ' + $Name) 'ERROR' ($_.Exception.Message) }
}
function Write-RestoreSummary {
    Write-Section 'RESTORE SUMMARY'
    $all = @($script:RestoreResults)
    $err = @($all | Where-Object { $_.Status -eq 'ERROR' })
    $left = @($all | Where-Object { $_.Status -eq 'LEFTOVER' -or $_.Status -eq 'WARN' })
    $okn = @($all | Where-Object { $_.Status -eq 'OK' })
    foreach ($r in $all) { if ($r.Status -ne 'OK') { Write-R ('  {0,-8} {1} {2}' -f $r.Status, $r.Item, $r.Detail) } }
    $lvl = 'INFO'; if ($err.Count -gt 0) { $lvl = 'ERROR' }
    Write-R ('RESTORE SUMMARY: {0} ok, {1} error(s), {2} warning/leftover(s)' -f $okn.Count, $err.Count, $left.Count) $lvl
    return ($err.Count -eq 0)
}

# ----------------------------------------------------------------------------- Options+ stop / restore
function Stop-OptionsPlus {
    param($Pre)
    Write-Section 'STOP Options+ (allowlist only)'
    foreach ($e in (Get-AL 'services')) {
        $n = [string](Get-Prop $e 'name')
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $svc) { Write-R ("Service {0} not present - skipped" -f $n) 'WARN'; continue }
        Add-StateAction 'servicesChanged' $n
        Set-Service -Name $n -StartupType Manual -ErrorAction Continue
        if ([string](Get-Prop $svc 'Status') -ne 'Stopped') {
            Stop-Service -Name $n -Force -ErrorAction Continue
            try { $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30)) } catch { Write-R ("Service {0} did not reach Stopped in 30s: {1}" -f $n, $_) 'ERROR' }
        }
        Write-R ("Service {0}: StartType={1} Status={2}" -f $n, (Get-ServiceStartType $n), (Get-Prop (Get-Service -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1) 'Status'))
    }
    foreach ($t in @(Get-LogiTasks)) {
        $full = Get-TaskFullPath $t
        if (-not (Test-TaskDisableAllowed $full)) { Write-R ("Scheduled task observed but NOT in allowlist (not touched): {0} state={1}" -f $full, (Get-Prop $t 'State')) 'WARN'; continue }
        if ([string](Get-Prop $t 'State') -ne 'Disabled') {
            Add-StateAction 'tasksDisabled' ('{0}|{1}' -f (Get-Prop $t 'TaskPath'), (Get-Prop $t 'TaskName'))
            Disable-ScheduledTask -TaskPath (Get-Prop $t 'TaskPath') -TaskName (Get-Prop $t 'TaskName') -ErrorAction Continue | Out-Null
            Write-R ("Scheduled task disabled: {0}" -f $full)
        }
    }
    [void](Stop-OptionsPlusProcesses 'initial')
}
function Stop-OptionsPlusProcesses([string]$Why) {
    $n = 0
    foreach ($p in @(Get-OptionsPlusProcessInfo)) {
        if (-not $p.Allowed) { Write-R ("NOT killing {0} pid={1}: path '{2}' is not in allowlist.json" -f $p.Name, $p.Id, $p.Path) 'WARN'; continue }
        $parent = '?'
        try { $pp = Get-Prop (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $p.Id) | Select-Object -First 1) 'ParentProcessId'; $parent = '{0}({1})' -f (Get-Process -Id $pp -ErrorAction Stop).Name, $pp } catch {}
        $lvl = 'RESPAWN'; if ($Why -eq 'initial') { $lvl = 'INFO' }
        Write-R ("Kill [{0}] {1} pid={2} path={3} parent={4}" -f $Why, $p.Name, $p.Id, $p.Path, $parent) $lvl
        Add-StateAction 'killed' $p.Name
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $n++
    }
    return $n
}
# Run-1 crash site (`$ps.Count` on a scalar/null under StrictMode) - now array-safe.
function Watch-OptionsPlusRespawn([int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds); $n = 0
    while ((Get-Date) -lt $end) {
        $ps = @(Get-OptionsPlusTargetProcesses)
        if ($ps.Count -gt 0) { $n += $ps.Count; [void](Stop-OptionsPlusProcesses 'respawn') }
        Start-Sleep -Seconds 2
    }
    Write-R ("Respawn check ({0}s): {1} respawned Options+ process(es)" -f $Seconds, $n)
    return $n
}
function ConvertTo-ScStart([string]$t) {
    switch ($t) { 'Automatic' { return 'auto' } 'AutomaticDelayed' { return 'delayed-auto' } 'Manual' { return 'demand' } 'Disabled' { return 'disabled' } default { return $null } }
}
# Idempotent, best-effort per item: drives current state toward the pre-snapshot.
function Restore-OptionsPlus {
    param($Pre)
    Write-Section 'RESTORE Options+'
    foreach ($e in (Get-AL 'services')) {
        $n = [string](Get-Prop $e 'name')
        try {
            $want = Get-SnapValue $Pre ("svc.{0}.starttype" -f $n)
            $wantStatus = Get-SnapValue $Pre ("svc.{0}.status" -f $n)
            if (-not $Pre) { $want = 'Automatic'; $wantStatus = 'Running' }   # no snapshot: run-1 log shows Automatic/Running
            if (-not $want -or $want -eq 'Absent') { Add-RestoreResult ("service " + $n) 'OK' 'absent before - nothing to do'; continue }
            if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { Add-RestoreResult ("service " + $n) 'ERROR' 'missing now'; continue }
            $cur = Get-ServiceStartType $n
            if ($cur -ne $want) {
                $m = ConvertTo-ScStart $want
                if ($m) { $o = & sc.exe config $n start= $m 2>&1; Write-R ("sc config {0} start= {1}: {2}" -f $n, $m, ((@($o) | Out-String).Trim() -replace '\s+', ' ')) }
            }
            if ($wantStatus -eq 'Running' -and [string](Get-Prop (Get-Service -Name $n | Select-Object -First 1) 'Status') -ne 'Running') {
                Start-Service -Name $n -ErrorAction Stop
                (Get-Service -Name $n | Select-Object -First 1).WaitForStatus('Running', (New-TimeSpan -Seconds 30))
            }
            $gotT = Get-ServiceStartType $n; $gotS = [string](Get-Prop (Get-Service -Name $n | Select-Object -First 1) 'Status')
            $ok = ($gotT -eq $want) -and (-not $wantStatus -or $gotS -eq $wantStatus)
            $stt = 'ERROR'; if ($ok) { $stt = 'OK' }
            Add-RestoreResult ("service " + $n) $stt ("StartType={0} (want {1}) Status={2} (want {3})" -f $gotT, $want, $gotS, $wantStatus)
        }
        catch { Add-RestoreResult ("service " + $n) 'ERROR' $_.Exception.Message }
    }
    foreach ($t in @($script:Ctx.Actions.tasksDisabled)) {
        $parts = @(([string]$t) -split '\|', 2)
        if ($parts.Count -ne 2) { Add-RestoreResult ('task ' + $t) 'ERROR' 'malformed state entry'; continue }
        $full = $parts[0] + $parts[1]
        if (-not (Test-TaskReEnableAllowed $full)) { Add-RestoreResult ('task ' + $full) 'ERROR' 'recorded as disabled but not in allowlist - NOT touched; check manually'; continue }
        try {
            Enable-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction Stop | Out-Null
            $st = [string](Get-Prop (Get-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction Stop | Select-Object -First 1) 'State')
            $stt = 'ERROR'; if ($st -and $st -ne 'Disabled') { $stt = 'OK' }
            Add-RestoreResult ('task re-enable ' + $full) $stt ('state=' + $st)
        }
        catch { Add-RestoreResult ('task re-enable ' + $full) 'ERROR' $_.Exception.Message }
    }
    # Background processes that were running before: wait for the service to bring them back, else start them as the user.
    try {
        $preProcs = @(Get-SnapLines $Pre 'proc.optionsplus')
        if ($preProcs.Count -eq 0) { $preProcs = @(Get-SnapLines $Pre 'info.proc.logi.paths') }   # run-1 snapshot key
        $need = @()
        foreach ($e in (Get-AL 'optionsPlusProcesses')) {
            if (-not (Get-Prop $e 'restartInUserSession')) { continue }
            $nm = [string](Get-Prop $e 'name')
            foreach ($l in $preProcs) {
                $kv = @(([string]$l) -split '=', 2)
                if ($kv.Count -eq 2 -and $kv[0] -ieq $nm -and (Test-InList $kv[1] @(Get-Prop $e 'paths'))) { $need += [pscustomobject]@{ Name = $nm; Path = $kv[1] } }
            }
        }
        if ($need.Count -gt 0) {
            $end = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $end) {
                $missing = @($need | Where-Object { (Get-Count (Get-Process -Name $_.Name -ErrorAction SilentlyContinue)) -eq 0 })
                if ($missing.Count -eq 0) { break }
                Start-Sleep -Seconds 3
            }
            foreach ($m in @($need | Where-Object { (Get-Count (Get-Process -Name $_.Name -ErrorAction SilentlyContinue)) -eq 0 })) {
                try {
                    if ((Test-Path -LiteralPath $m.Path) -and $script:Ctx.TargetUser -and (Get-ConsoleUser)) {
                        Write-R ("{0} not back after 45s - starting it in the user session: {1}" -f $m.Name, $m.Path) 'WARN'
                        $helper = Join-Path ([string]$script:Ctx.SuiteDir) 'UserSide.ps1'
                        if (-not (Test-Path -LiteralPath $helper)) { $helper = Join-Path $PSScriptRoot 'UserSide.ps1' }
                        [void](Invoke-UserTask -Name ('Restore-' + $m.Name) -ScriptPath $helper -Arguments @('-Action', 'StartProcess', '-Exe', $m.Path) -Wait -TimeoutSec 30)
                        Start-Sleep -Seconds 3
                    }
                    $back = (Get-Count (Get-Process -Name $m.Name -ErrorAction SilentlyContinue)) -gt 0
                    if ($back) { Add-RestoreResult ('process ' + $m.Name) 'OK' 'running again' } else { Add-RestoreResult ('process ' + $m.Name) 'ERROR' 'was running before, not running now' }
                }
                catch { Add-RestoreResult ('process ' + $m.Name) 'ERROR' $_.Exception.Message }
            }
        }
    }
    catch { Add-RestoreResult 'Options+ processes' 'ERROR' $_.Exception.Message }
    Write-R ('Options+ processes now: ' + ((@(Get-OptionsPlusProcessInfo | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '))
}

# ----------------------------------------------------------------------------- OpenLogi stop / cleanup
function Stop-OpenLogi {
    $C = $script:Ctx
    $pr = [string](Get-Prop $C 'PkgRoot')
    if ($C -and (-not $pr -or -not (Test-Path -LiteralPath $pr)) -and (Get-Prop $C 'PkgDir') -and (Test-Path -LiteralPath $C.PkgDir)) {
        $exe = Get-ChildItem -LiteralPath $C.PkgDir -Filter 'OpenLogi.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { $C.PkgRoot = Split-Path -Parent $exe.FullName }
    }
    foreach ($p in @(Get-OpenLogiProcessInfo $C)) {
        if (-not $p.Allowed) { Add-RestoreResult ('openlogi process ' + $p.Name + ' pid ' + $p.Id) 'LEFTOVER' ("path '{0}' is not the test package - NOT killed" -f $p.Path); continue }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Add-RestoreResult ('kill ' + $p.Name + ' pid ' + $p.Id) 'OK' $p.Path }
        catch { Add-RestoreResult ('kill ' + $p.Name + ' pid ' + $p.Id) 'ERROR' $_.Exception.Message }
    }
    Start-Sleep -Milliseconds 800
    $left = @(Get-OpenLogiProcessInfo $C | Where-Object { $_.Allowed })
    if ($left.Count -gt 0) { Add-RestoreResult 'openlogi processes' 'ERROR' ('still alive: ' + ((@($left | ForEach-Object { $_.Name + ':' + $_.Id })) -join ', ')) }
}
function Add-TestFirewallRules {
    param([string]$AgentExe, [int]$Port, [string]$FwProfile)
    $names = @(Get-HwTestFirewallRuleNames $script:Ctx)
    $defs = @(@{ n = ('OpenLogiHwTest-UDP-' + $Port); d = 'OpenLogi HW test - Flow UDP ' + $Port; p = $Port }, @{ n = 'OpenLogiHwTest-mDNS-5353'; d = 'OpenLogi HW test - mDNS UDP 5353'; p = 5353 })
    foreach ($r in $defs) {
        if (-not (Test-InList $r.n $names)) { throw ("firewall rule {0} not in allowlist" -f $r.n) }
        New-NetFirewallRule -Name $r.n -DisplayName $r.d -Group $HT.FirewallGroup -Direction Inbound -Action Allow -Protocol UDP -LocalPort $r.p -Profile $FwProfile -Program $AgentExe -ErrorAction Stop | Out-Null
        Add-StateAction 'firewallRules' $r.n
        Write-R ("Firewall rule added: {0} (profile {1}, program {2})" -f $r.n, $FwProfile, $AgentExe)
    }
}
function Remove-TestFirewallRules {
    param($Pre)
    $preNames = @{}
    foreach ($l in @(Get-SnapLines $Pre 'firewall.hwtest')) { $preNames[(@($l -split '\|'))[0]] = $true }
    $mine = @(Get-HwTestFirewallRuleNames $script:Ctx)
    foreach ($n in $mine) {
        try {
            if ($preNames.ContainsKey($n)) { Add-RestoreResult ('firewall ' + $n) 'OK' 'existed before - kept'; continue }
            if (Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $n -ErrorAction Stop; Add-RestoreResult ('firewall remove ' + $n) 'OK' '' }
        }
        catch { Add-RestoreResult ('firewall remove ' + $n) 'ERROR' $_.Exception.Message }
    }
    # Report (never delete) other OpenLogi rules, e.g. created by a Windows firewall prompt.
    $preAny = @(Get-SnapLines $Pre 'info.firewall.openlogi.any')
    foreach ($l in @(Get-OpenLogiFirewallRules)) {
        $n = (@($l -split '\|'))[0]
        if (Test-InList $n $mine) { continue }
        if (@($preAny | Where-Object { (@($_ -split '\|'))[0] -eq $n }).Count -gt 0) { continue }
        Add-RestoreResult ('firewall rule not created by script: ' + $l) 'LEFTOVER' 'not in allowlist - remove manually if unwanted (RUNBOOK)'
    }
}
function Restore-RegistryValues {
    param($Pre)
    foreach ($e in (Get-AL 'registryValuesRemoveIfAbsentBefore')) {
        try {
            $rv = Get-AllowedRegistryValueState $e $script:Ctx
            if (-not $rv) { continue }
            $preVal = Get-SnapValue $Pre ('reg:{0}\{1}' -f $rv.Key, $rv.Name)
            if ($preVal -eq '<absent>' -and $rv.Value -ne '<absent>') {
                Remove-ItemProperty -LiteralPath ('Registry::' + $rv.Key) -Name $rv.Name -ErrorAction Stop
                Add-RestoreResult ('registry remove {0}\{1}' -f $rv.Key, $rv.Name) 'OK' ('was: ' + $rv.Value)
            }
            elseif (-not $preVal -and $rv.Value -ne '<absent>') { Add-RestoreResult ('registry {0}\{1}' -f $rv.Key, $rv.Name) 'LEFTOVER' 'not in snapshot - cannot tell if it pre-existed; left in place' }
        }
        catch { Add-RestoreResult ('registry ' + [string](Get-Prop $e 'value')) 'ERROR' $_.Exception.Message }
    }
}
function Test-PathAllowed([string]$Path) {
    $all = @(Get-AllowedPaths 'pathsRemoveIfAbsentBefore' $script:Ctx) + @(Get-AllowedPaths 'pathsRemoveIfCreatedAndEmpty' $script:Ctx)
    return (Test-InList $Path $all)
}
function Remove-PathSafe([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-PathAllowed $Path)) { Add-RestoreResult ('remove ' + $Path) 'ERROR' 'path not in allowlist - refused'; return }
    for ($i = 0; $i -lt 5; $i++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { Add-RestoreResult ('remove ' + $Path) 'OK' ''; return }
        Start-Sleep -Seconds 1
    }
    Add-RestoreResult ('remove ' + $Path) 'ERROR' 'could not remove (in use?)'
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
    if ($script:Ctx.PkgDir) { try { Remove-PathSafe $script:Ctx.PkgDir } catch { Add-RestoreResult ('remove ' + $script:Ctx.PkgDir) 'ERROR' $_.Exception.Message } }
    foreach ($d in @(@($script:Ctx.ConfigDir, $script:Ctx.StateDir, $script:Ctx.DataDir) + @($script:Ctx.ExtraDirs))) {
        if (-not $d) { continue }
        try {
            $preVal = Get-SnapValue $Pre ('dir.openlogi:' + $d)
            if (-not $preVal) { $preVal = Get-SnapValue $Pre ('path.exists:' + $d) }
            $backup = @(@($script:Ctx.Actions.backups) | Where-Object { ([string]$_).StartsWith($d + '|') }) | Select-Object -First 1
            if ($backup) {
                $src = (@(([string]$backup) -split '\|', 2))[1]
                if (-not (Test-PathAllowed $d)) { Add-RestoreResult ('restore ' + $d) 'ERROR' 'not in allowlist'; continue }
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
                & robocopy.exe $src $d /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                $rc = $LASTEXITCODE; $stt = 'ERROR'; if ($rc -lt 8) { $stt = 'OK' }
                Add-RestoreResult ('restore pre-existing ' + $d) $stt ('robocopy exit ' + $rc)
            }
            elseif ($preVal -eq 'absent' -or $preVal -eq 'False') { Remove-PathSafe $d }
            elseif (-not $Pre -and (Test-Path -LiteralPath $d)) { Add-RestoreResult ('keep ' + $d) 'LEFTOVER' 'no snapshot: cannot tell whether it pre-existed' }
        }
        catch { Add-RestoreResult ('cleanup ' + $d) 'ERROR' $_.Exception.Message }
    }
    foreach ($d in @(@($script:Ctx.ParentDirs) | Sort-Object { $_.Length } -Descending)) {
        try {
            if ((Get-SnapValue $Pre ('path.exists:' + $d)) -eq 'False' -and (Test-Path -LiteralPath $d)) {
                if ((Get-Count (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) -eq 0) { Remove-PathSafe $d }
                else { Add-RestoreResult ('keep ' + $d) 'LEFTOVER' 'created during the test but not empty' }
            }
        }
        catch { Add-RestoreResult ('cleanup ' + $d) 'ERROR' $_.Exception.Message }
    }
}

# ----------------------------------------------------------------------------- full restore (main, watchdog, emergency)
function Invoke-FullRestore {
    param([string]$Reason, [switch]$FromWatchdog)
    Reset-RestoreResults
    $mutex = $null; $got = $false
    try { $mutex = New-Object Threading.Mutex($false, $HT.MutexName); $got = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] { $got = $true }
    catch { Write-R ('mutex unavailable: ' + $_.Exception.Message) 'WARN' }
    $ok = $false
    try {
        Write-Section ("FULL RESTORE ({0})" -f $Reason)
        $pre = $null
        try { $pre = Read-Snapshot ([string]$script:Ctx.PrePath) } catch { Add-RestoreResult 'read pre-snapshot' 'ERROR' $_.Exception.Message }
        if (-not $pre) { Write-R 'Pre-snapshot not found - using defaults (OptionsPlusUpdaterService -> Automatic, Running)' 'WARN' }
        Invoke-RestoreStep 'stop OpenLogi (releases input hooks)' { Stop-OpenLogi }
        Invoke-RestoreStep 'remove own user tasks' { Remove-HwTestUserTasks }
        Invoke-RestoreStep 'restore Options+' { Restore-OptionsPlus $pre }
        Invoke-RestoreStep 'firewall' { Remove-TestFirewallRules $pre }
        Invoke-RestoreStep 'registry' { Restore-RegistryValues $pre }
        Invoke-RestoreStep 'files' { Remove-TestFiles $pre }
        if (-not $FromWatchdog) { Invoke-RestoreStep 'unregister watchdog' { Unregister-Watchdog } }
        try { $script:Ctx.Completed = $true; Save-State } catch {}
        if ($pre) {
            Invoke-RestoreStep 'post-snapshot diff' {
                Start-Sleep -Seconds 5
                $post = Get-Snapshot $script:Ctx
                if ($FromWatchdog -and $post.Contains('tasks.hwtest')) { $post['tasks.hwtest'].value = (@(Get-SnapLines $post 'tasks.hwtest') | Where-Object { $_ -ne $HT.WatchdogTask }) -join "`n" }
                Save-Snapshot $post ([string]$script:Ctx.PostPath)
                $script:DiffOk = Compare-Snapshots $pre $post
                if ($script:DiffOk) { Write-R 'OVERALL STATE RESTORE: PASS' } else { Write-R 'OVERALL STATE RESTORE: FAIL - see FAIL lines above' 'ERROR' }
            }
        }
        Invoke-RestoreStep 'remove work dir' {
            if (Test-Path -LiteralPath $HT.WorkRoot) {
                Remove-Item -LiteralPath $HT.WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $HT.WorkRoot) { throw ('Work dir still present: ' + $HT.WorkRoot) }
            }
        }
        $ok = Write-RestoreSummary
        Write-R ("Only remaining test file: {0}" -f $script:Ctx.ResultLog)
    }
    finally { if ($mutex) { if ($got) { try { $mutex.ReleaseMutex() } catch {} }; $mutex.Dispose() } }
    return $ok
}

# ----------------------------------------------------------------------------- agent CLI / Flow status
function Invoke-Cli {
    param([string[]]$CliArgs, [int]$TimeoutSec = 20)
    $cli = Join-Path ([string]$script:Ctx.PkgRoot) 'bin\openlogi.exe'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cli
    $psi.Arguments = (@($CliArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })) -join ' '
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['USERPROFILE'] = [string]$script:Ctx.Profile
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' } }
    [pscustomobject]@{ Code = $p.ExitCode; Out = [string]$outTask.Result; Err = [string]$errTask.Result }
}
function Get-CliJson([string[]]$CliArgs) {
    $r = Invoke-Cli $CliArgs
    if (-not $r.Out) { return $null }
    try { return ($r.Out | ConvertFrom-Json) } catch { return $null }
}
# Parse `openlogi flow status` JSON (FlowStatus; serde externally-tagged FlowPairingPhase). Pure (unit-tested).
function ConvertFrom-FlowStatus {
    param($Fs)
    $r = [ordered]@{ Enabled = $false; Phase = 'None'; Sas = ''; PeerName = ''; Address = ''; LocalConfirmed = $false; PeerConfirmed = $false; Failure = ''; Peers = @(); ConnectedPeers = @() }
    if ($null -eq $Fs) { $r.Phase = 'Unavailable'; return [pscustomobject]$r }
    $r.Enabled = [bool](Get-Prop $Fs 'enabled')
    foreach ($p in @(Get-Prop $Fs 'peers')) {
        if ($null -eq $p) { continue }
        $r.Peers += [string](Get-Prop $p 'name')
        if ([string](Get-Prop $p 'state') -eq 'Connected') { $r.ConnectedPeers += [string](Get-Prop $p 'name') }
    }
    $ph = Get-Prop $Fs 'pairing'
    if ($null -eq $ph) { return [pscustomobject]$r }
    if ($ph -is [string]) { $r.Phase = $ph; return [pscustomobject]$r }
    foreach ($k in @('Connecting', 'Prompted', 'Paired', 'Failed')) {
        $v = Get-Prop $ph $k
        if ($null -eq $v) { continue }
        $r.Phase = $k
        if ($k -eq 'Prompted') { $r.Sas = [string](Get-Prop $v 'sas'); $r.PeerName = [string](Get-Prop $v 'machine_name'); $r.LocalConfirmed = [bool](Get-Prop $v 'local_confirmed'); $r.PeerConfirmed = [bool](Get-Prop $v 'peer_confirmed') }
        if ($k -eq 'Paired') { $r.PeerName = [string](Get-Prop $v 'name') }
        if ($k -eq 'Connecting') { $r.Address = [string](Get-Prop $v 'address') }
        if ($k -eq 'Failed') {
            if ($v -is [string]) { $r.Failure = $v }
            else { $f = @($v.PSObject.Properties); if ($f.Count -gt 0) { $r.Failure = $f[0].Name + ': ' + [string](Get-Prop $f[0].Value 'message') } }
        }
    }
    return [pscustomobject]$r
}
function Get-FlowState { ConvertFrom-FlowStatus (Get-CliJson @('flow', 'status')) }
function Format-Sas([string]$Sas) { if ($Sas.Length -eq 6) { return $Sas.Substring(0, 3) + ' ' + $Sas.Substring(3) } return $Sas }
function Get-UdpListenerOwners([int]$Port) {
    @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | ForEach-Object { $op = Get-Prop $_ 'OwningProcess'; $(try { (Get-Process -Id $op -ErrorAction Stop).Name } catch { 'pid' + $op }) } | Sort-Object -Unique)
}

# ----------------------------------------------------------------------------- agent log parsing
function ConvertFrom-AgentLogLine([string]$Line) {
    if ($Line -notmatch '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s+([A-Z]+)\s+(.*)$') { return $null }
    $ts = $Matches[1]; $lvl = $Matches[2]; $rest = $Matches[3]
    $ev = $null
    foreach ($pat in $script:FlowEventPatterns) { if ($rest.Contains($pat)) { $ev = $pat; break } }
    if (-not $ev) { return $null }
    $ms = [DateTimeOffset]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeMilliseconds()
    $fields = @{}
    foreach ($m in @([regex]::Matches($rest, '(\w+)=("[^"]*"|\S+)'))) { $fields[$m.Groups[1].Value] = $m.Groups[2].Value.Trim('"') }
    return [pscustomobject]@{ Ms = $ms; Level = $lvl; Event = $ev; Fields = $fields; Line = $Line }
}
function Get-AgentEvents {
    param([long]$SinceMs)
    $res = @()
    $dir = [string]$script:Ctx.StateDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'agent*.log' -File -ErrorAction SilentlyContinue)) {
        $fs = $null
        try {
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            $sr = New-Object IO.StreamReader($fs)
            while ($null -ne ($line = $sr.ReadLine())) {
                $ev = ConvertFrom-AgentLogLine $line
                if ($null -eq $ev -or $ev.Ms -lt $SinceMs) { continue }
                $res += $ev
            }
        }
        catch {} finally { if ($fs) { $fs.Dispose() } }
    }
    @($res | Sort-Object Ms)
}
function Format-Event($e) {
    $f = (@($e.Fields.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $e.Fields[$_] })) -join ' '
    if ($e.Fields.ContainsKey('outcome')) { $f += ' (' + $script:OutcomeNames[[string]$e.Fields['outcome']] + ')' }
    '{0} {1} "{2}" {3}' -f (Format-Ms $e.Ms), $e.Level, $e.Event, $f
}

# ----------------------------------------------------------------------------- Flow layout in config.toml (schema: crates/openlogi-core/src/config/flow.rs)
# [[flow.layout]] { edge = "left"|"right"|"top"|"bottom", peer = "<[[flow.peers]].name>" }; reload with `openlogi flow enable`.
function Set-OpenLogiFlowLayout {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][ValidateSet('left', 'right', 'top', 'bottom')][string]$Edge,
        [Parameter(Mandatory = $true)][string]$Peer,
        [int]$Port = 42424
    )
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $layoutBlock = "[[flow.layout]]`r`nedge = `"$Edge`"`r`npeer = `"$Peer`""
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $fresh = "schema_version = 8`r`n`r`n[flow]`r`nenabled = true`r`nport = $Port`r`n`r`n$layoutBlock`r`n"
        Set-Content -LiteralPath $ConfigPath -Value $fresh -Encoding UTF8
        Write-R ("Wrote new config.toml with [[flow.layout]] edge={0} peer={1}" -f $Edge, $Peer)
        return
    }
    $text = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    if ($null -eq $text) { $text = '' }
    $text = [regex]::Replace($text, '(?ms)^\[\[flow\.layout\]\][^\r\n]*\r?\n(?:^(?!\[).*\r?\n)*', '')
    if ($text -notmatch '(?m)^\[flow\]\s*$') {
        $text = $text.TrimEnd() + "`r`n`r`n[flow]`r`nenabled = true`r`nport = $Port`r`n"
    }
    else {
        if ($text -notmatch '(?m)^enabled\s*=') { $text = [regex]::Replace($text, '(?m)^\[flow\]\s*$', "[flow]`r`nenabled = true") }
        if ($text -notmatch '(?m)^port\s*=') { $text = [regex]::Replace($text, '(?m)^\[flow\]\s*$', "[flow]`r`nport = $Port") }
    }
    $text = $text.TrimEnd() + "`r`n`r`n" + $layoutBlock + "`r`n"
    Set-Content -LiteralPath $ConfigPath -Value $text -Encoding UTF8
    Write-R ("Updated config.toml [[flow.layout]] edge={0} peer={1} at {2}" -f $Edge, $Peer, $ConfigPath)
}
function Apply-FlowLayoutAndReload {
    param([string]$Edge, [string]$PeerName, [int]$Port)
    if (-not $PeerName) {
        $st = Get-FlowState
        if ((Get-Count $st.Peers) -gt 0) { $PeerName = [string](@($st.Peers)[0]) }
    }
    if (-not $PeerName) { Write-R ('No Flow peer name available (pairing not completed). Layout NOT written. GM default: edge={0} -> peer=<Mac>' -f $Edge) 'WARN'; return $false }
    $cfg = Join-Path ([string]$script:Ctx.ConfigDir) 'config.toml'
    Set-OpenLogiFlowLayout -ConfigPath $cfg -Edge $Edge -Peer $PeerName -Port $Port
    $r = Invoke-Cli @('flow', 'enable')
    Write-R ('flow enable (reload after layout): code={0} out={1} err={2}' -f $r.Code, $r.Out.Trim(), $r.Err.Trim())
    if ($r.Code -ne 0) { Write-R 'Layout reload failed - peer name in [[flow.layout]] must match [[flow.peers]].name exactly.' 'ERROR'; return $false }
    return $true
}
