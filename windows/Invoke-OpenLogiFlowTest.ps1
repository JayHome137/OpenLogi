<#
.SYNOPSIS
  OpenLogi Flow hardware test for Windows (host Jay-Alienware, 192.168.1.9). Writes one result log.
.DESCRIPTION
  Modes:
    -Mode Preflight  Read-only. Changes nothing. Checks admin/OS, services/processes/tasks against allowlist.json.
    -Mode Run        Snapshot -> lease watchdog -> stop Options+ -> OpenLogi + Flow (READY) -> pairing (SAS gate)
                     -> real-mouse measurement gate -> restore -> diff. Every human step waits for Enter / skip / abort.
    -Mode Restore    Idempotent full restore to the pre-snapshot (same code path as the watchdog). For recovery.
  START ORDER: Windows FIRST. Start the Mac only after this window shows "READY: listening on UDP 42424".
  Pairing roles (from the OpenLogi source): Windows = responder (`openlogi flow listen`), Mac = initiator (`flow pair-start 192.168.1.9`).
  Artifact: -ArtifactZip, OR -DownloadTokenSecure (Read-Host -AsSecureString), OR env OPENLOGI_GH_TOKEN / GITHUB_TOKEN. Never hardcode a token.
.NOTES
  Run from an ELEVATED Windows PowerShell 5.1 console window (not ISE). Files are UTF-8 with BOM (needed for Chinese text in 5.1).
#>
[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Run', 'Restore')][string]$Mode = 'Preflight',
    [string]$ArtifactZip,
    [string]$ArtifactRunId,
    [string]$ExpectedSha,
    [string]$DownloadToken,                    # plain string (discouraged; wiped after download)
    [SecureString]$DownloadTokenSecure,        # preferred: Read-Host -AsSecureString
    [string]$TargetUser,
    [int]$Port = 42424,
    [ValidateSet('left', 'right', 'top', 'bottom')][string]$FlowEdge = 'left',  # GM: Mac Mini is LEFT of Alienware
    [string]$PeerName,                          # [[flow.layout]].peer override (normally taken from the pairing result)
    [ValidateSet('Listen', 'Initiate', 'Skip')][string]$PairRole = 'Listen',
    [string]$PeerAddress,                       # only for -PairRole Initiate
    [int]$LeaseMinutes = 20,
    [int]$HardCapMinutes = 120,
    [int]$WatchdogMinutes = 0,                  # DEPRECATED (run 1): mapped to -LeaseMinutes
    [int]$RespawnWatchSec = 20,
    [int]$HumanGateSec = 0,                     # DEPRECATED (run 1): ignored, gates wait for Enter
    [int]$MeasureWaitSec = 0,                   # DEPRECATED (run 1): ignored
    [long]$StartAtEpochMs = 0,                  # DEPRECATED (run 1): ignored, replaced by READY handshake
    [switch]$SkipInjection,
    [switch]$AllowLockedSession
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HwTest.Common.ps1')

function ConvertFrom-SecureStringPlain {
    param([SecureString]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Get-DownloadTokenPlain {
    if ($DownloadTokenSecure) { return (ConvertFrom-SecureStringPlain $DownloadTokenSecure) }
    if ($DownloadToken) { return $DownloadToken }
    if ($env:OPENLOGI_GH_TOKEN) { return $env:OPENLOGI_GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    return $null
}
function Clear-DownloadToken {
    $script:ResolvedToken = $null
    Set-Variable -Name DownloadToken -Value $null -Scope Script -ErrorAction SilentlyContinue
    if ($DownloadTokenSecure) { try { $DownloadTokenSecure.Dispose() } catch {} }
    Remove-Item Env:OPENLOGI_GH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
}
function Resolve-ArtifactZip {
    param([string]$Zip, [string]$Token, [string]$DestDir)
    if ($Zip) {
        if (-not (Test-Path -LiteralPath $Zip)) { throw "ArtifactZip not found: $Zip" }
        return (Resolve-Path -LiteralPath $Zip).Path
    }
    if (-not $Token) { throw 'Provide -ArtifactZip <path> or -DownloadTokenSecure (GitHub PAT).' }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $hdr = @{ Authorization = "Bearer $Token"; 'User-Agent' = 'openlogi-hwtest'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $api = "https://api.github.com/repos/$($HT.Repo)/actions/runs/$($HT.RunId)/artifacts"
    $list = Invoke-RestMethod -Uri $api -Headers $hdr -UseBasicParsing
    $art = @(@(Get-Prop $list 'artifacts') | Where-Object { [string](Get-Prop $_ 'name') -eq $HT.ArtifactName }) | Select-Object -First 1
    if (-not $art) { throw "Artifact $($HT.ArtifactName) not found in run $($HT.RunId)." }
    $outer = Join-Path $DestDir 'artifact.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # 5.1 progress bar makes downloads very slow
    try { Invoke-WebRequest -Uri (Get-Prop $art 'archive_download_url') -Headers $hdr -OutFile $outer -UseBasicParsing } finally { $ProgressPreference = $pp }
    return $outer
}
function Expand-Portable {
    param([string]$OuterZip, [string]$Dest)
    $tmp = Join-Path $script:Ctx.WorkRoot 'extract'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $OuterZip -DestinationPath $tmp -Force
    $inner = @(Get-ChildItem -LiteralPath $tmp -Filter '*.zip' -Recurse) | Select-Object -First 1
    if ($inner) { Expand-Archive -LiteralPath $inner.FullName -DestinationPath $Dest -Force }
    else { Copy-Item -Path (Join-Path $tmp '*') -Destination $Dest -Recurse -Force }
    $exe = @(Get-ChildItem -LiteralPath $Dest -Filter 'OpenLogi.exe' -Recurse) | Select-Object -First 1
    if (-not $exe) { throw 'OpenLogi.exe not found in the portable package.' }
    $root = Split-Path -Parent $exe.FullName
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File)) { try { Unblock-File -LiteralPath $f.FullName } catch {} }
    return $root
}
function Show-Failed([string]$Why) {
    Write-Banner -Color 'Red' -Level 'ERROR' -Lines @(
        'FAILED  FAILED  FAILED  (Windows / Jay-Alienware .9)',
        ('原因: ' + $Why),
        '>> 不要再启动 Mac 端脚本。如果 Mac 端已经在运行: 在 Mac 终端窗口输入 abort 然后回车。',
        '>> 本窗口现在自动恢复 Options+ 并清理(不用关窗口, 等它显示 DONE)。')
}

# =====================================================================================
if ($WatchdogMinutes -gt 0) { $LeaseMinutes = $WatchdogMinutes; Write-Host "NOTE: -WatchdogMinutes is deprecated; used as -LeaseMinutes $LeaseMinutes" -ForegroundColor Yellow }
if ($HumanGateSec -gt 0 -or $MeasureWaitSec -gt 0 -or $StartAtEpochMs -gt 0) { Write-Host 'NOTE: -HumanGateSec / -MeasureWaitSec / -StartAtEpochMs are ignored in run 2 (gates wait for Enter; READY handshake replaces T0).' -ForegroundColor Yellow }
$HT.LeaseMinutes = $LeaseMinutes
$HT.HardCapMinutes = $HardCapMinutes
$HT.RunId = $ArtifactRunId
[void](Import-HwAllowlist)

if ($Mode -eq 'Restore') {
    if (-not (Test-IsAdmin)) { throw 'Restore needs an elevated PowerShell.' }
    $st = Read-State
    if (-not $st) { Write-Host 'No saved state. Use Emergency-Restore.ps1.'; exit 1 }
    $script:Ctx = $st
    $script:ResultLog = $st.ResultLog
    $ok = Invoke-FullRestore -Reason 'manual Restore mode'
    if ($ok) { exit 0 } else { exit 3 }
}

$script:Ctx = New-HwContext -TargetUser $TargetUser
$script:Ctx.Port = $Port
$C = $script:Ctx
Write-Host ('OpenLogi Flow HW test - Mode={0} - host {1} - target user {2} - allowlist {3}' -f $Mode, $env:COMPUTERNAME, $C.TargetUser, $script:ALPath)

# ----------------------------------------------------------------- PREFLIGHT (read-only)
if ($Mode -eq 'Preflight') {
    $report = [ordered]@{}
    $report['elevated'] = Test-IsAdmin
    $report['psVersion'] = $PSVersionTable.PSVersion.ToString()
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    $report['os'] = '{0} {1} build {2}' -f (Get-Prop $os 'Caption'), (Get-Prop $os 'Version'), (Get-Prop $os 'BuildNumber')
    $report['targetUser'] = $C.TargetUser
    $report['profileDir'] = $C.Profile
    $report['consoleSessionPresent'] = [bool](Get-ConsoleUser)
    $report['screenLocked'] = Test-ScreenLocked
    $report['resultLog'] = $C.ResultLog
    $report['artifactRunId'] = $ArtifactRunId
    $report['expectedSha'] = $ExpectedSha
    $report['configDir'] = $C.ConfigDir
    $report['leftoverStateFromEarlierRun'] = (Test-Path -LiteralPath $C.StatePath)
    $report['watchdogTaskExists'] = [bool](Get-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -ErrorAction SilentlyContinue)
    foreach ($e in (Get-AL 'services')) {
        $n = [string](Get-Prop $e 'name')
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) { $report["service:$n"] = '{0} / {1}' -f (Get-Prop $svc 'Status'), (Get-ServiceStartType $n) } else { $report["service:$n"] = 'ABSENT' }
        $wantImg = [string](Get-Prop $e 'imagePath')
        if ($svc -and $wantImg) {
            $img = ''; try { $img = [string](Get-Prop (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n) -Name ImagePath -ErrorAction Stop) 'ImagePath') } catch { $img = '' }
            $report["service:$n ImagePath"] = $img + $(if ($img -ieq $wantImg) { '  [matches allowlist]' } else { '  [DIFFERS from allowlist - info only, send to GM]' })
        }
    }
    foreach ($e in (Get-AL 'scheduledTasksRepairEnableOnly')) {
        $full = [string](Get-Prop $e 'path'); $i = $full.LastIndexOf('\')
        $t = Get-ScheduledTask -TaskPath $full.Substring(0, $i + 1) -TaskName $full.Substring($i + 1) -ErrorAction SilentlyContinue | Select-Object -First 1
        $s = 'Absent'; if ($t) { $s = [string](Get-Prop $t 'State') }
        $report["task:$full"] = $s + $(if ($s -eq 'Disabled') { '  <-- unexpected (was Ready before run 1): see README, Emergency-Restore.ps1 -RepairLoginCheck' } else { '' })
    }
    $report['logiScheduledTaskCandidates'] = (@(Get-LogiTasks | ForEach-Object { '{0} [{1}]' -f (Get-TaskFullPath $_), $(if (Test-TaskDisableAllowed (Get-TaskFullPath $_)) { 'allowlisted' } else { 'NOT in allowlist -> not touched' }) }) -join '; ')
    $report['logiServices(info)'] = (@(Get-LogiServices | ForEach-Object { Get-Prop $_ 'Name' }) -join ', ')
    $report['openLogiRunningNow'] = (@(Get-OpenLogiProcessInfo $C | ForEach-Object { $_.Name + '=' + $_.Path }) -join ', ')
    $report['existingOpenLogiConfig'] = (Test-Path -LiteralPath $C.ConfigDir)
    $report['netProfiles'] = (@(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { '{0}={1}' -f (Get-Prop $_ 'InterfaceAlias'), (Get-Prop $_ 'NetworkCategory') }) -join ', ')
    $report['udp42424InUse'] = ((Get-UdpListenerOwners $Port) -join ', ')
    if ($ArtifactZip) { $report['artifact'] = $(if (Test-Path -LiteralPath $ArtifactZip) { 'present: ' + $ArtifactZip } else { 'MISSING: ' + $ArtifactZip }) }
    elseif ($DownloadToken -or $DownloadTokenSecure -or $env:OPENLOGI_GH_TOKEN -or $env:GITHUB_TOKEN) { $report['artifact'] = 'will download ' + $HT.ArtifactName + ' from run ' + $HT.RunId + ' (token not logged)' }
    else { $report['artifact'] = 'NONE (pass -ArtifactZip or -DownloadTokenSecure for a real run)' }
    $report['logitechBtHidPresent'] = (Get-Count (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'InstanceId') -match '046D' }))

    Write-Host ''
    Write-Host '==== PREFLIGHT (read-only; nothing changed) ===='
    foreach ($k in @($report.Keys)) { Write-Host ('  {0,-40}: {1}' -f $k, $report[$k]) }
    Write-Host ''
    Write-Host '==== Options+ processes vs allowlist.json (exact name + exact path) ===='
    $bad = 0
    foreach ($p in @(Get-OptionsPlusProcessInfo)) {
        $tag = 'OK (allowlisted)'
        if ($p.Unreadable) { $tag = 'PATH UNREADABLE -> will NOT be stopped (does not block the run)' }
        elseif ($p.Mismatch) { $tag = 'PATH NOT IN ALLOWLIST -> a run would STOP before touching anything'; $bad++ }
        Write-Host ('  {0,-28} pid {1,-6} {2}  [{3}]' -f $p.Name, $p.Id, $p.Path, $tag)
    }
    foreach ($p in @(Get-LogiProcesses)) {
        $nm = [string](Get-Prop $p 'Name')
        if (-not (@(Get-AL 'optionsPlusProcesses') | Where-Object { [string](Get-Prop $_ 'name') -ieq $nm })) { Write-Host ('  {0,-28} pid {1,-6} {2}  [not in allowlist - never touched]' -f $nm, (Get-Prop $p 'Id'), (Get-ProcPath $p)) }
    }
    $guiN = @(Get-OptionsPlusGuiProcesses).Count
    if ($guiN -gt 0) { Write-Host ('  Options+ window (logioptionsplus) is OPEN ({0}) - close it before -Mode Run (the script never kills it).' -f $guiN) -ForegroundColor Yellow }
    else { Write-Host '  Options+ window (logioptionsplus): not running - OK' }
    Write-Host ''
    Write-Host ('A real run (-Mode Run) WOULD: snapshot -> lease watchdog ({0} min lease, {1} min hard cap) -> stop allowlisted Options+ items -> extract OpenLogi to {2}' -f $LeaseMinutes, $HardCapMinutes, $C.PkgDir)
    Write-Host ('  -> firewall rules {0} -> agent in user session -> flow enable -> READY (UDP {1}) -> flow listen -> SAS gate -> layout edge={2} -> measurement gate -> restore -> diff' -f ((Get-HwTestFirewallRuleNames $C) -join ','), $Port, $FlowEdge)
    if ($bad -gt 0) { Write-Host ('PREFLIGHT RESULT: BLOCKED - {0} Options+ process path(s) not in allowlist.json. Send this output to GM; do not run.' -f $bad) -ForegroundColor Red; exit 4 }
    if (-not (Test-IsAdmin)) { Write-Host 'NOTE: not elevated - a real run needs an elevated PowerShell.' -ForegroundColor Yellow }
    Write-Host 'PREFLIGHT RESULT: OK' -ForegroundColor Green
    exit 0
}

# ----------------------------------------------------------------- RUN: pre-checks (nothing touched yet)
if (-not (Test-IsAdmin)) { throw 'Run mode needs an elevated (Administrator) PowerShell.' }
if (-not $ArtifactRunId -or -not $ExpectedSha -or $ExpectedSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Run mode requires -ArtifactRunId and -ExpectedSha (40-character commit SHA) for the exact build.'
}
$runInfo = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/actions/runs/{1}" -f $HT.Repo, $ArtifactRunId) -Headers @{ 'User-Agent' = 'openlogi-hwtest'; Accept = 'application/vnd.github+json' } -UseBasicParsing
if (-not (Test-BuildRunProvenance $runInfo $ExpectedSha)) {
    throw ("Build run provenance mismatch: workflow={0}, branch={1}, status={2}, conclusion={3}, head_sha={4}; expected Build/openlogi-custom/{5}." -f $runInfo.name, $runInfo.head_branch, $runInfo.status, $runInfo.conclusion, $runInfo.head_sha, $ExpectedSha)
}
if (-not $C.Profile) { Show-Failed ("Could not resolve target user profile (user '{0}'). Pass -TargetUser COMPUTER\user." -f $C.TargetUser); exit 1 }
if (-not (Get-ConsoleUser)) { Show-Failed 'No interactive console session detected.'; exit 1 }
if (Test-Path -LiteralPath $C.StatePath) {
    Show-Failed ('Leftover state from an earlier run: {0}. Run Emergency-Restore.ps1 first (it repairs run-1 leftovers), then start again.' -f $C.StatePath)
    exit 1
}
$opInfo = @(Get-OptionsPlusProcessInfo)
foreach ($u in @($opInfo | Where-Object { $_.Unreadable })) { Write-Host ('WARN: {0} pid {1}: executable path unreadable even elevated - it will NOT be stopped (the service stop normally ends it).' -f $u.Name, $u.Id) -ForegroundColor Yellow }
$blocked = @($opInfo | Where-Object { $_.Mismatch })
if ($blocked.Count -gt 0) {
    Show-Failed ('Options+ process path(s) not in allowlist.json: ' + ((@($blocked | ForEach-Object { $_.Name + '=' + $_.Path })) -join '; ') + '. Nothing was changed.')
    exit 1
}
# Ask for the PAT up front (hidden input), BEFORE anything is changed; it is only kept as a SecureString.
if (-not $ArtifactZip -and -not $DownloadToken -and -not $DownloadTokenSecure -and -not $env:OPENLOGI_GH_TOKEN -and -not $env:GITHUB_TOKEN) {
    $DownloadTokenSecure = Read-Host -AsSecureString '粘贴 GitHub PAT 后回车 (输入不显示; 只用于下载 build artifact)'
    if (-not $DownloadTokenSecure -or $DownloadTokenSecure.Length -eq 0) { Show-Failed 'No PAT entered and no -ArtifactZip. Nothing was changed.'; exit 1 }
}
# GATE W0 (nothing changed yet): the Options+ WINDOW is never killed by the script (it would not be restarted).
# ORDER MATTERS: the pre-snapshot (Options+ processes + service state = the restore/diff baseline) is taken only
# AFTER W0 passes. If Jay's tray "退出" also stops background processes (UNVERIFIED), that post-W0 state is the
# baseline: no false diff FAILs, and restore does not restart what Jay deliberately quit.
while (@(Get-OptionsPlusGuiProcesses).Count -gt 0) {
    Write-Banner -Color 'Yellow' -Lines @('GATE W0 (Windows .9): 请先关掉 Options+ 窗口',
        '关掉 Options+ 窗口；如果还卡在这里，右下角托盘里右键 Options+ 图标 > 退出。(脚本不会替你关它。)',
        '关掉后在这里按回车重新检查; 输入 abort 回车 = 退出 (什么都没改)。')
    $ans = Read-Host '回车 = 重新检查 / abort'
    if ($ans -and $ans.Trim() -ieq 'abort') { Write-Host 'Aborted at gate W0 - nothing was changed.' -ForegroundColor Yellow; exit 1 }
}
if ((Test-ScreenLocked) -and -not $AllowLockedSession) { Write-Host 'WARN: Console session appears LOCKED - the agent UI/hooks may not work.' -ForegroundColor Yellow }

New-Item -ItemType Directory -Force -Path $C.WorkRoot, $C.SuiteDir, $C.BackupDir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $C.SuiteDir -Force
Copy-Item -LiteralPath $script:ALPath -Destination (Join-Path $C.SuiteDir 'allowlist.json') -Force
$C.HardCapMs = (Get-NowMs) + [long]$HardCapMinutes * 60000
$script:ResultLog = $C.ResultLog
Save-State
Update-Lease -Phase 'start' -Quiet

$script:Failed = $false
$script:ReadyShown = $false
try {
    '' | Set-Content -LiteralPath $C.ResultLog -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Section 'OpenLogi Flow HW test START (Windows, run 2)'
    Write-R ('host={0} user={1} port={2} edge={3} role={4} lease={5}min hardcap={6}min' -f $env:COMPUTERNAME, $C.TargetUser, $Port, $FlowEdge, $PairRole, $LeaseMinutes, $HardCapMinutes)
    Write-R ('build: run {0} expected commit {1}, artifact {2} (select local ZIP from this exact run)' -f $HT.RunId, $ExpectedSha, $HT.ArtifactName)
    Write-Banner -Color 'Yellow' -Lines @('Windows 端已开始。在本窗口出现绿色 READY 之前, 不要启动 Mac 端脚本。', (Format-LeaseStatus))

    Write-Section 'PRE-SNAPSHOT'
    $pre = Get-Snapshot $C
    Save-Snapshot $pre $C.PrePath
    Write-R ('Pre-snapshot saved: {0} items -> {1}' -f $pre.Count, $C.PrePath)

    Write-Section 'ARM WATCHDOG (lease)'
    Register-Watchdog
    Update-Lease -Phase 'watchdog-armed'
    Backup-ExistingOpenLogiDirs

    Write-Section 'ARTIFACT'
    $script:ResolvedToken = Get-DownloadTokenPlain
    try { $outer = Resolve-ArtifactZip -Zip $ArtifactZip -Token $script:ResolvedToken -DestDir (Join-Path $C.WorkRoot 'dl') }
    finally { Clear-DownloadToken }
    Write-R ('Artifact: {0} sha256={1}' -f $outer, (Get-FileHash -LiteralPath $outer -Algorithm SHA256).Hash)
    New-Item -ItemType Directory -Force -Path $C.PkgDir, $C.IoDir | Out-Null
    $root = Expand-Portable -OuterZip $outer -Dest $C.PkgDir
    $C.PkgRoot = $root
    $agentExe = Join-Path $root 'openlogi-agent.exe'
    Save-State
    Update-Lease -Phase 'artifact-ready'
    Write-R ('Portable package root: {0}' -f $root)
    foreach ($f in @('OpenLogi.exe', 'openlogi-agent.exe', 'openlogi-overlay.exe', 'bin\openlogi.exe')) {
        $fp = Join-Path $root $f
        if (Test-Path -LiteralPath $fp) { Write-R ('  {0} sha256={1}' -f $f, (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash) } else { Write-R ('  {0} MISSING' -f $f) 'WARN' }
    }

    Stop-OptionsPlus $pre
    Start-Sleep -Seconds 2
    [void](Watch-OptionsPlusRespawn $RespawnWatchSec)
    Update-Lease -Phase 'optionsplus-stopped'

    Write-Section 'FIREWALL'
    $ncp = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($ncp -and [string](Get-Prop $ncp 'NetworkCategory') -eq 'Public') { Write-R 'Active network is Public - test rules are for Private only; Flow may be blocked until the network is set to Private.' 'WARN' }
    Add-TestFirewallRules -AgentExe $agentExe -Port $Port -FwProfile 'Private'

    Write-Section 'START OPENLOGI AGENT (user session)'
    $agentOut = Join-Path $C.IoDir 'startagent.json'
    $startAgent = {
        Remove-Item -LiteralPath $agentOut -ErrorAction SilentlyContinue
        [void](Invoke-UserTask -Name 'StartAgent' -ScriptPath (Join-Path $C.SuiteDir 'UserSide.ps1') -Arguments @('-Action', 'StartAgent', '-Exe', $agentExe, '-LogFilter', $HT.LogFilter, '-OutFile', $agentOut) -Wait -TimeoutSec 30)
        Start-Sleep -Seconds 5
        if (Test-Path -LiteralPath $agentOut) { Write-R ('Agent launch result: ' + ((Get-Content -LiteralPath $agentOut -Raw).Trim())) }
    }
    & $startAgent
    $agentRunning = { $a = @(Get-OpenLogiProcessInfo $C | Where-Object { $_.Name -eq 'openlogi-agent' -and $_.Allowed }); @{ Done = ($a.Count -gt 0); Status = $(if ($a.Count -gt 0) { 'openlogi-agent 运行中 pid=' + ((@($a | ForEach-Object { $_.Id })) -join ',') } else { 'openlogi-agent 没有在运行' }) } }
    if (-not (& $agentRunning).Done) {
        while ($true) {
            $g = Wait-HumanGate -Title 'GATE W1 (Windows .9): OpenLogi agent 没有启动' -Phase 'gate-agent' -Check $agentRunning -AutoContinue -Commands @('retry') -Lines @(
                '可能是 SmartScreen 拦截了未签名程序。在 Alienware 屏幕上找蓝色窗口 "Windows 已保护你的电脑":',
                '  点 "更多信息" -> 点 "仍要运行"。然后在这里输入 retry 回车, 脚本会重新启动 agent。',
                '如果出现 "Windows 安全中心警报 / 防火墙已阻止此应用的部分功能": 只勾 "专用网络", 点 "允许访问"。',
                '没有任何窗口? 输入 abort 回车(会自动恢复), 把结果日志发给 GM。')
            if ($g -eq 'retry') { & $startAgent; continue }
            break
        }
    }
    if (-not (& $agentRunning).Done) { throw 'openlogi-agent is not running.' }
    Write-R (& $agentRunning).Status

    Write-Section 'AGENT STATUS / DEVICES'
    Start-Sleep -Seconds 3
    $status = Get-CliJson @('api', 'status')
    if ($status) { Write-R ('api status: ' + ($status | ConvertTo-Json -Depth 6 -Compress)) } else { Write-R 'api status returned no JSON (agent not reachable over the named pipe).' 'ERROR' }
    $devs = Get-CliJson @('api', 'devices')
    $devData = Get-Prop $devs 'data'
    if ((Get-Prop $devs 'ok') -and $devData) {
        Write-R ('inventory: ' + [string](Get-Prop $devData 'inventory'))
        foreach ($d in @(Get-Prop $devData 'devices')) { if ($d) { Write-R ('  device id={0} name={1} kind={2} online={3}' -f (Get-Prop $d 'id'), (Get-Prop $d 'name'), (Get-Prop $d 'kind'), (Get-Prop $d 'online')) } }
        if ((Get-Count (@(Get-Prop $devData 'devices') | Where-Object { [string](Get-Prop $_ 'id') -match '^(serial:|unit:)' })) -eq 0) { Write-R 'No device exposes a serial:/unit: id - Bluetooth-direct Flow mapping needs one. Switching may fail.' 'WARN' }
    }
    else { Write-R 'api devices returned nothing usable.' 'WARN' }
    Update-Lease -Phase 'agent-up'

    Write-Section 'FLOW ENABLE'
    $fe = Invoke-Cli @('flow', 'enable')
    Write-R ('flow enable: code={0} out={1} err={2}' -f $fe.Code, $fe.Out.Trim(), $fe.Err.Trim())
    if ($fe.Code -ne 0) { throw ('openlogi flow enable failed: ' + $fe.Err.Trim()) }
    $owners = @()
    for ($i = 0; $i -lt 20; $i++) { $owners = @(Get-UdpListenerOwners $Port); if ($owners -contains 'openlogi-agent') { break }; Start-Sleep -Seconds 1 }
    if (-not ($owners -contains 'openlogi-agent')) { throw ('openlogi-agent is not listening on UDP {0} after flow enable (owners: {1}).' -f $Port, ($owners -join ',')) }

    # ------------------------------------------------------------- PAIRING (Windows = responder by default)
    Write-Section ('FLOW PAIRING (role {0})' -f $PairRole)
    $pairedName = ''
    $fs0 = Get-FlowState
    if ((Get-Count $fs0.Peers) -gt 0) { $pairedName = [string](@($fs0.Peers)[0]); Write-R ('Already paired with: {0} - pairing skipped' -f $pairedName) }
    $armListen = {
        $r = Invoke-Cli @('flow', 'listen')
        Write-R ('flow listen: code={0} out={1} err={2}' -f $r.Code, $r.Out.Trim(), $r.Err.Trim())
        return ($r.Code -eq 0)
    }
    $attempt = 0
    while (-not $pairedName -and $PairRole -ne 'Skip') {
        $attempt++
        Update-Lease -Phase ('pairing-attempt-' + $attempt)
        if ($PairRole -eq 'Listen') {
            $listenOk = $false
            for ($li = 0; $li -lt 3 -and -not $listenOk; $li++) { $listenOk = [bool](& $armListen); if (-not $listenOk) { Start-Sleep -Seconds 3 } }
            if (-not $listenOk -and -not $script:ReadyShown) { throw 'openlogi flow listen failed 3 times (non-zero exit) - not READY.' }
            if (-not $script:ReadyShown) {
                $script:ReadyShown = $true
                Write-R ('READY: listening on UDP {0}' -f $Port) 'GATE'
                Write-Banner -Color 'Green' -Level 'GATE' -Lines @(
                    ('READY: listening on UDP {0}   (Windows / Jay-Alienware 192.168.1.9)' -f $Port),
                    '>> 现在去 Mac mini (192.168.1.8) 启动 Mac 端脚本(RUNBOOK 第 4 步)。',
                    '>> 本窗口会自动等 Mac 连进来, 不用按任何键。')
            }
            $waitCheck = {
                $s = Get-FlowState
                if ($s.Phase -eq 'Prompted') { return @{ Done = $true; Status = ('Mac 已连上, 配对码 ' + (Format-Sas $s.Sas)) } }
                if ((Get-Count $s.Peers) -gt 0) { return @{ Done = $true; Status = 'already paired' } }
                if ($s.Phase -eq 'Connecting') { return @{ Done = $false; Status = '正在监听, 等 Mac 发起配对 (每 120 秒自动续开监听窗口)' } }
                [void](& $armListen)
                return @{ Done = $false; Status = ('监听窗口已结束(' + $s.Phase + ' ' + $s.Failure + '), 已重新打开') }
            }
            $g = Wait-HumanGate -Title 'GATE W2 (Windows .9): 等待 Mac 发起配对' -Phase 'gate-wait-peer' -Check $waitCheck -AutoContinue -PollSec 3 -Lines @(
                '在 Mac mini (.8) 上: 打开 "终端", 粘贴 RUNBOOK 第 4 步的命令并回车, 按提示做 Mac 的授权步骤。',
                'Mac 端会自动连到 192.168.1.9:42424。连上后本窗口会自动显示 6 位配对码。',
                '这一步通常 3-10 分钟(Mac 下载+安装+授权)。没有倒计时, 慢慢来。')
            if ($g -eq 'skip') { Write-R 'Pairing skipped by user.' 'WARN'; break }
        }
        else {
            if (-not $PeerAddress) { throw '-PairRole Initiate needs -PeerAddress' }
            $initCheck = {
                $s = Get-FlowState
                if ($s.Phase -eq 'Prompted') { return @{ Done = $true; Status = ('connected, SAS ' + (Format-Sas $s.Sas)) } }
                $r = Invoke-Cli @('flow', 'pair-start', $PeerAddress) 30
                return @{ Done = $false; Status = ('pair-start {0}: code={1} {2}{3}' -f $PeerAddress, $r.Code, $r.Out.Trim(), $r.Err.Trim()) }
            }
            $g = Wait-HumanGate -Title ('GATE W2 (Windows .9): 连接 ' + $PeerAddress) -Phase 'gate-wait-peer' -Check $initCheck -AutoContinue -PollSec 10 -Lines @('对端必须先在运行 `openlogi flow listen`(对端脚本 READY 之后)。')
            if ($g -eq 'skip') { break }
        }
        # ---- SAS gate
        $outcome = ''
        while ($true) {
            $s = Get-FlowState
            $sasCheck = {
                $s = Get-FlowState
                if ($s.Phase -eq 'Paired' -or ((Get-Count $s.Peers) -gt 0 -and $s.Phase -ne 'Prompted')) { return @{ Done = $true; Status = ('配对完成: ' + $s.PeerName) } }
                if ($s.Phase -eq 'Failed') { return @{ Done = $true; Status = ('FAILED: ' + $s.Failure) } }
                return @{ Done = $false; Status = ('本机已确认={0}  Mac已确认={1}' -f $s.LocalConfirmed, $s.PeerConfirmed) }
            }
            $g = Wait-HumanGate -Title ('GATE W3 (Windows .9): 核对配对码  ' + (Format-Sas $s.Sas)) -Phase 'gate-sas' -Check $sasCheck -AutoContinue -PollSec 2 -Commands @('y', 'n') -Lines @(
                ('本窗口的配对码: ' + (Format-Sas $s.Sas) + '   对方名字: ' + $s.PeerName),
                '看 Mac 终端窗口里的 6 位码, 和上面这个一模一样吗?',
                '  一样: 在【本窗口】输入 y 回车, 然后在【Mac 终端窗口】也输入 y 回车(两边都要)。',
                '  不一样: 输入 n 回车(拒绝, 然后重试)。',
                '注意: 配对码出现后 120 秒内两边都要确认, 否则超时, 脚本会让你重试。')
            if ($g -eq 'y') { $r = Invoke-Cli @('flow', 'confirm'); Write-R ('flow confirm: code={0} out={1} err={2}' -f $r.Code, $r.Out.Trim(), $r.Err.Trim()); continue }
            if ($g -eq 'n') { $r = Invoke-Cli @('flow', 'reject'); Write-R ('flow reject: code={0} {1}{2}' -f $r.Code, $r.Out.Trim(), $r.Err.Trim()) 'WARN'; $outcome = 'failed'; break }
            if ($g -eq 'skip') { $outcome = 'skip'; break }
            $s = Get-FlowState
            if ($s.Phase -eq 'Failed') { Write-R ('Pairing failed: ' + $s.Failure) 'WARN'; $outcome = 'failed'; break }
            $pairedName = $s.PeerName
            if (-not $pairedName -and (Get-Count $s.Peers) -gt 0) { $pairedName = [string](@($s.Peers)[0]) }
            $outcome = 'paired'; break
        }
        if ($outcome -eq 'skip') { break }
        if ($outcome -eq 'failed') {
            [void](Wait-HumanGate -Title 'GATE W3b (Windows .9): 配对没有成功' -Phase 'gate-pair-retry' -Lines @(
                    '回车 = 重新开始配对(Windows 重新监听), 然后在 Mac 窗口 (GATE M4b) 也按回车。',
                    'abort = 结束测试并自动恢复。'))
            continue
        }
    }
    if ($pairedName) { Write-R ('PAIRED with peer name: {0}' -f $pairedName) 'GATE' } else { Write-R 'No paired peer - crossings cannot happen; continuing to measurement only for logs.' 'WARN' }
    Update-Lease -Phase 'paired'

    Write-Section 'FLOW LAYOUT (GM: Mac Mini is LEFT of Jay-Alienware)'
    $peerForLayout = $PeerName; if (-not $peerForLayout) { $peerForLayout = $pairedName }
    [void](Apply-FlowLayoutAndReload -Edge $FlowEdge -PeerName $peerForLayout -Port $Port)

    Write-Section 'FLOW CROSSING MEASUREMENT'
    $measureStart = Get-NowMs
    if (-not $SkipInjection) {
        Write-R 'SendInput probe (OpenLogi drops LLMHF_INJECTED motion, so this is NOT expected to cross; real mouse needed).' 'WARN'
        $injOut = Join-Path $C.IoDir 'inject.json'
        Remove-Item -LiteralPath $injOut -ErrorAction SilentlyContinue
        [void](Invoke-UserTask -Name 'Inject' -ScriptPath (Join-Path $C.SuiteDir 'UserSide.ps1') -Arguments @('-Action', 'Inject', '-Edge', $FlowEdge, '-OutFile', $injOut) -Wait -TimeoutSec 40)
        if (Test-Path -LiteralPath $injOut) { Write-R ('Injection probe: ' + ((Get-Content -LiteralPath $injOut -Raw).Trim())) }
    }
    $measureCheck = {
        $ev = @(Get-AgentEvents -SinceMs $measureStart)
        $out = @($ev | Where-Object { $_.Event -eq 'Flow handoff completed' }).Count
        $inc = @($ev | Where-Object { $_.Event -eq 'Flow incoming handoff finished' }).Count
        $bad = @($ev | Where-Object { $_.Event -match 'timed out|rejected|failed|ignored|cancelled|invalid' }).Count
        @{ Done = $true; Status = ('Alienware->Mac 完成 {0} 次 | Mac->Alienware 到达 {1} 次 | 失败/忽略 {2} 次' -f $out, $inc, $bad) }
    }
    [void](Wait-HumanGate -Title 'GATE W4 (两台机器): 鼠标跨屏与键盘跟随' -Phase 'gate-measure' -Check $measureCheck -PollSec 5 -Lines @(
            '用 Logitech 真鼠标(不要用触控板/别的鼠标):',
            '  1) 在 Alienware 上把光标一直往【左边缘】推 -> 光标应出现在 Mac 屏幕上(蓝牙切换常要 10-30 秒)。',
            '  2) 在 Mac 上把光标一直往【右边缘】推 -> 回到 Alienware。',
            '  至少来回 3 次。下面的状态行会显示已检测到的次数。',
            '  3) 若测试键盘已连接到同一 Logitech 接收器/设备组，在两台上分别打开文本输入框；鼠标切换后在当前端输入唯一短文本，确认键盘输入跟随鼠标所在端，反向再测一次。',
            '  4) 记录键盘型号、连接方式、两端结果；若没有可配置键盘，明确记为未测试。',
            '做完后在【本窗口】按回车结束测量(Mac 窗口也按回车)。'))

    Write-Section 'FLOW EVENTS (from agent log, UTC->local)'
    $events = @(Get-AgentEvents -SinceMs $measureStart)
    if ($events.Count -eq 0) { Write-R 'No Flow events found in the agent log for this window.' 'WARN' }
    $pendingSwitch = $null
    foreach ($e in $events) {
        Write-R (Format-Event $e) 'EVENT'
        if ($e.Event -eq 'Flow runtime armed') { $pendingSwitch = $null }
        if ($e.Event -match 'edge') { $pendingSwitch = $e }
        if ($e.Event -eq 'Flow handoff completed' -and $pendingSwitch) {
            $dur = $e.Ms - $pendingSwitch.Ms
            Write-R ('  CROSSING DURATION (sender edge->handoff completed): {0} ms  [start={1} end={2} outcome={3}]' -f $dur, (Format-Ms $pendingSwitch.Ms), (Format-Ms $e.Ms), $script:OutcomeNames[[string]$e.Fields['outcome']]) 'TIMING'
            $pendingSwitch = $null
        }
        if ($e.Event -eq 'Flow incoming handoff finished') {
            Write-R ('  RECEIVER arrival: outcome={0} arrived={1}/{2} at {3}' -f $script:OutcomeNames[[string]$e.Fields['outcome']], $e.Fields['arrived'], $e.Fields['requested'], (Format-Ms $e.Ms)) 'TIMING'
        }
    }
    $fsFinal = Get-CliJson @('flow', 'status')
    if ($fsFinal) { Write-R ('Final flow status: ' + ($fsFinal | ConvertTo-Json -Depth 6 -Compress)) }
}
catch [System.OperationCanceledException] {
    Write-R ('ABORTED by user: ' + $_.Exception.Message) 'WARN'
    Write-Banner -Color 'Yellow' -Lines @('已中止(abort)。正在自动恢复 Options+ 并清理, 请等到出现 DONE。', '如果 Mac 端还在运行, 在 Mac 终端输入 abort 回车。')
}
catch {
    $script:Failed = $true
    Write-R ('RUN ERROR: ' + ($_ | Out-String)) 'ERROR'
    Show-Failed ([string]$_.Exception.Message)
}
finally {
    $rok = $false
    try { $rok = Invoke-FullRestore -Reason 'main run end' } catch { Write-R ('Restore error: ' + $_) 'ERROR' }
    Write-Section 'DONE'
    $diffTxt = 'n/a'; if ($null -ne $script:DiffOk) { $diffTxt = $(if ($script:DiffOk) { 'PASS' } else { 'FAIL' }) }
    $col = 'Green'; if (-not $rok -or $script:Failed -or $script:DiffOk -eq $false) { $col = 'Red' }
    Write-Banner -Color $col -Lines @(
        ('DONE (Windows). 测试{0}; 恢复={1}; 状态对比={2}' -f $(if ($script:Failed) { '失败' } else { '结束' }), $(if ($rok) { '全部成功' } else { '有错误, 见 RESTORE SUMMARY' }), $diffTxt),
        ('结果日志: {0}' -f $C.ResultLog))
}
