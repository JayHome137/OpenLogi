<#
.SYNOPSIS
  Automated OpenLogi Flow hardware test for Windows (host Jay-Alienware). Writes one result log.
.DESCRIPTION
  Modes:
    -Mode Preflight  Read-only. Changes nothing. Checks admin/OS, services/processes/tasks, artifact, what a real run would do.
    -Mode Run        Snapshot -> arm SYSTEM watchdog -> stop Options+ -> run OpenLogi + Flow -> measure -> restore -> cleanup -> diff.
    -Mode Restore    Idempotent full restore to the pre-snapshot (same path as the watchdog). For recovery.
  Artifact: -ArtifactZip, OR -DownloadTokenSecure (Read-Host -AsSecureString), OR env OPENLOGI_GH_TOKEN / GITHUB_TOKEN. Plain -DownloadToken still accepted but wiped after use.
  OpenLogi-windows-x86_64 from Actions run 39235760610. Never hardcode a token.
  Flow needs BOTH machines up. Coordinate with the macOS run via -StartAtEpochMs (shared wall-clock T0).
.NOTES
  Run from an ELEVATED PowerShell. Windows PowerShell 5.1 or PowerShell 7.
#>
[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Run', 'Restore')][string]$Mode = 'Preflight',
    [string]$ArtifactZip,
    [string]$DownloadToken,                    # plain string (discouraged; wiped after download)
    [SecureString]$DownloadTokenSecure,        # preferred: Read-Host -AsSecureString
    [string]$TargetUser,
    [int]$Port = 42424,
    [ValidateSet('left', 'right', 'top', 'bottom')][string]$FlowEdge = 'left',  # GM: Mac Mini is LEFT of Alienware
    [string]$PeerName,   # [[flow.peers]].name / [[flow.layout]].peer (usually the Mac's hostname after pairing)
    [string]$PeerAddress,
    [long]$StartAtEpochMs = 0,
    [int]$WatchdogMinutes = 15,   # 5 is tight for first-run TCC + SAS + BT handoff; 15 recommended
    [int]$RespawnWatchSec = 20,
    [int]$HumanGateSec = 180,     # pause after pair-start for SAS confirm + mouse prep
    [int]$MeasureWaitSec = 180,   # poll agent log for N real-mouse crossings
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

# Resolve GitHub token: SecureString > -DownloadToken > env OPENLOGI_GH_TOKEN / GITHUB_TOKEN.
# Never log the value. Cleared in Clear-DownloadToken after artifact resolve.
function Get-DownloadTokenPlain {
    if ($DownloadTokenSecure) { return (ConvertFrom-SecureStringPlain $DownloadTokenSecure) }
    if ($DownloadToken) { return $DownloadToken }
    if ($env:OPENLOGI_GH_TOKEN) { return $env:OPENLOGI_GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    return $null
}
function Clear-DownloadToken {
    $script:ResolvedToken = $null
    $DownloadToken = $null
    if ($DownloadTokenSecure) {
        try { $DownloadTokenSecure.Dispose() } catch {}
    }
    Remove-Item Env:OPENLOGI_GH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
}

function Resolve-ArtifactZip {
    param([string]$Zip, [string]$Token, [string]$DestDir)
    if ($Zip) {
        if (-not (Test-Path -LiteralPath $Zip)) { throw "ArtifactZip not found: $Zip" }
        return (Resolve-Path -LiteralPath $Zip).Path
    }
    if (-not $Token) { throw 'Provide -ArtifactZip <path> or -DownloadToken <github token>.' }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $hdr = @{
        Authorization = "Bearer $Token"
        'User-Agent' = 'openlogi-hwtest'
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $api = "https://api.github.com/repos/$($HT.Repo)/actions/runs/$($HT.RunId)/artifacts"
    $list = Invoke-RestMethod -Uri $api -Headers $hdr
    $art = $list.artifacts | Where-Object { $_.name -eq $HT.ArtifactName } | Select-Object -First 1
    if (-not $art) { throw "Artifact $($HT.ArtifactName) not found in run $($HT.RunId)." }
    $outer = Join-Path $DestDir 'artifact.zip'
    Invoke-WebRequest -Uri $art.archive_download_url -Headers $hdr -OutFile $outer
    return $outer
}

function Expand-Portable {
    param([string]$OuterZip, [string]$Dest)
    $tmp = Join-Path $script:Ctx.WorkRoot 'extract'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $OuterZip -DestinationPath $tmp -Force
    $inner = Get-ChildItem -LiteralPath $tmp -Filter '*.zip' -Recurse | Select-Object -First 1
    if ($inner) {
        Expand-Archive -LiteralPath $inner.FullName -DestinationPath $Dest -Force
    }
    else {
        Copy-Item -Path (Join-Path $tmp '*') -Destination $Dest -Recurse -Force
    }
    $exe = Get-ChildItem -LiteralPath $Dest -Filter 'OpenLogi.exe' -Recurse | Select-Object -First 1
    if (-not $exe) { throw 'OpenLogi.exe not found in the portable package.' }
    $root = Split-Path -Parent $exe.FullName
    Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
        try { Unblock-File -LiteralPath $_.FullName } catch {}
    }
    return $root
}

# =====================================================================================
if ($Mode -eq 'Restore') {
    if (-not (Test-IsAdmin)) { throw 'Restore needs an elevated PowerShell.' }
    $st = Read-State
    if (-not $st) { Write-Host 'No saved state. Use Emergency-Restore.ps1.'; exit 1 }
    $script:Ctx = $st
    $script:ResultLog = $st.ResultLog
    Invoke-FullRestore -Reason 'manual Restore mode'
    exit 0
}

$script:Ctx = New-HwContext -TargetUser $TargetUser
$script:Ctx.Port = $Port
$C = $script:Ctx

Write-Host ('OpenLogi Flow HW test - Mode={0} - host {1} - target user {2}' -f $Mode, $env:COMPUTERNAME, $C.TargetUser)

# ----------------------------------------------------------------- PREFLIGHT (read-only)
if ($Mode -eq 'Preflight') {
    $report = [ordered]@{}
    $report['elevated'] = Test-IsAdmin
    $report['runningAsSystem'] = Test-IsSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $report['os'] = '{0} {1} build {2}' -f $os.Caption, $os.Version, $os.BuildNumber
    $report['targetUser'] = $C.TargetUser
    $report['targetUserResolved'] = [bool]$C.Profile
    $report['consoleSessionPresent'] = [bool](Get-ConsoleUser)
    $report['screenLocked'] = Test-ScreenLocked
    $report['profileDir'] = $C.Profile
    $report['resultLog'] = $C.ResultLog
    $report['configDir'] = $C.ConfigDir
    $report['stateDir(logs)'] = $C.StateDir
    foreach ($n in $HT.OptionsPlusServices) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($svc) {
            $report["service:$n"] = '{0} / {1} (UNVERIFIED name)' -f $svc.Status, (Get-ServiceStartType $n)
        }
        else {
            $report["service:$n"] = 'ABSENT (UNVERIFIED name - confirm on machine)'
        }
    }
    $report['logiServices'] = (@(Get-LogiServices | ForEach-Object { $_.Name }) -join ', ')
    $report['logiProcesses'] = (@(Get-LogiProcesses | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', ')
    $report['optionsPlusTargetProcs'] = (@(Get-OptionsPlusTargetProcesses | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', ')
    $report['logiScheduledTasks'] = (@(Get-LogiTasks | ForEach-Object { $_.TaskName }) -join ', ')
    $report['openLogiRunningNow'] = (@(Get-OpenLogiProcesses | ForEach-Object { $_.Name }) -join ', ')
    $report['existingOpenLogiConfig'] = (Test-Path -LiteralPath $C.ConfigDir)
    $report['existingOpenLogiState'] = (Test-Path -LiteralPath $C.StateDir)
    $report['netProfiles'] = (@(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { '{0}={1}' -f $_.InterfaceAlias, $_.NetworkCategory }) -join ', ')
    $report['existingOpenLogiFirewall'] = (@(Get-OpenLogiFirewallRules).Count)
    $report['watchdogTaskExists'] = [bool](Get-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -ErrorAction SilentlyContinue)
    $report['savedStateExists'] = (Test-Path -LiteralPath $C.StatePath)
    if ($ArtifactZip) {
        if (Test-Path -LiteralPath $ArtifactZip) { $report['artifact'] = 'present: ' + $ArtifactZip }
        else { $report['artifact'] = 'MISSING: ' + $ArtifactZip }
    }
    elseif ($DownloadToken -or $DownloadTokenSecure -or $env:OPENLOGI_GH_TOKEN -or $env:GITHUB_TOKEN) {
        $report['artifact'] = 'will download ' + $HT.ArtifactName + ' from run ' + $HT.RunId + ' (token via SecureString/env; not logged)'
    }
    else {
        $report['artifact'] = 'NONE (pass -ArtifactZip or -DownloadTokenSecure / env OPENLOGI_GH_TOKEN for a real run)'
    }
    $report['logitechBtHidPresent'] = (@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '046D' }).Count)

    Write-Host ''
    Write-Host '==== PREFLIGHT (read-only; nothing changed) ===='
    foreach ($k in $report.Keys) { Write-Host ('  {0,-26}: {1}' -f $k, $report[$k]) }
    Write-Host ''
    Write-Host 'A real run (-Mode Run) WOULD:'
    Write-Host ('  1. Snapshot state to {0}' -f $C.PrePath)
    Write-Host ('  2. Register SYSTEM one-shot watchdog "{0}" (+{1} min) BEFORE touching Options+' -f $HT.WatchdogTask, $WatchdogMinutes)
    Write-Host ('  3. Set {0} -> Manual, stop it, kill {1}' -f ($HT.OptionsPlusServices -join ','), ($HT.OptionsPlusProcessPatterns -join ','))
    Write-Host ('  4. Extract portable OpenLogi to {0}, add firewall rules (UDP {1}, mDNS 5353), start agent in the user session' -f $C.PkgDir, $Port)
    Write-Host ('  5. Enable Flow, pair, write [[flow.layout]] edge=left -> Mac (GM; override -FlowEdge/-PeerName), measure crossings -> {0}' -f $C.ResultLog)
    Write-Host ('  6. Stop OpenLogi, restore Options+, remove firewall/tasks/files, post-snapshot diff, keep only {0}' -f $C.ResultLog)
    if (-not (Test-IsAdmin)) {
        Write-Host ''
        Write-Host 'NOTE: not elevated - a real run needs an elevated PowerShell.'
    }
    exit 0
}

# ----------------------------------------------------------------- RUN
if (-not (Test-IsAdmin)) { throw 'Run mode needs an elevated (Administrator) PowerShell.' }
if (-not $C.Profile) {
    throw "Could not resolve target user profile (user '$($C.TargetUser)'). Pass -TargetUser DOMAIN\user who is logged in at the console."
}
if (-not (Get-ConsoleUser)) {
    throw 'No interactive console session detected. OpenLogi needs the user logged in (not locked at a password prompt).'
}
if ((Test-ScreenLocked) -and -not $AllowLockedSession) {
    Write-Host 'WARN: Console session appears LOCKED - SendInput and the tray UI may not work. Continuing. Pass -AllowLockedSession to silence.'
}

New-Item -ItemType Directory -Force -Path $C.WorkRoot, $C.SuiteDir, $C.BackupDir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $C.SuiteDir -Force
$C.DeadlineMs = (Get-NowMs) + ($WatchdogMinutes * 60000)
$script:ResultLog = $C.ResultLog
Save-State

try {
    '' | Set-Content -LiteralPath $C.ResultLog -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Section 'OpenLogi Flow HW test START (Windows)'
    Write-R ('host={0} user={1} mode=Run port={2} edge={3} watchdog={4}min' -f $env:COMPUTERNAME, $C.TargetUser, $Port, $FlowEdge, $WatchdogMinutes)
    Write-R ('build: run {0} commit bd04518f, artifact {1} (portable, UNSIGNED)' -f $HT.RunId, $HT.ArtifactName)

    Write-Section 'PRE-SNAPSHOT'
    $pre = Get-Snapshot $C
    Save-Snapshot $pre $C.PrePath
    Write-R ('Pre-snapshot saved: {0} items -> {1}' -f $pre.Count, $C.PrePath)

    Write-Section 'ARM WATCHDOG'
    Register-Watchdog -DeadlineMs $C.DeadlineMs

    Backup-ExistingOpenLogiDirs

    Write-Section 'ARTIFACT'
    $script:ResolvedToken = Get-DownloadTokenPlain
    try {
        $outer = Resolve-ArtifactZip -Zip $ArtifactZip -Token $script:ResolvedToken -DestDir (Join-Path $C.WorkRoot 'dl')
    }
    finally {
        Clear-DownloadToken
    }
    Write-R ('Artifact: {0} sha256={1}' -f $outer, (Get-FileHash -LiteralPath $outer -Algorithm SHA256).Hash)
    New-Item -ItemType Directory -Force -Path $C.PkgDir, $C.IoDir | Out-Null
    $root = Expand-Portable -OuterZip $outer -Dest $C.PkgDir
    $agentExe = Join-Path $root 'openlogi-agent.exe'
    $C.PkgDir = $root
    Save-State
    Write-R ('Portable package: {0}' -f $root)
    Write-R ('  OpenLogi.exe sha256={0}' -f (Get-FileHash -LiteralPath (Join-Path $root 'OpenLogi.exe') -Algorithm SHA256).Hash)
    Write-R ('  openlogi-agent.exe sha256={0}' -f (Get-FileHash -LiteralPath $agentExe -Algorithm SHA256).Hash)

    Stop-OptionsPlus $pre
    Start-Sleep -Seconds 2
    Watch-OptionsPlusRespawn $RespawnWatchSec

    Write-Section 'FIREWALL'
    $prof = $null
    $ncp = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ncp) { $prof = $ncp.NetworkCategory }
    if ($prof -eq 'Public') {
        Write-R 'Active network is Public - adding rules for Private only; Flow may be blocked until the network is set to Private.' 'WARN'
    }
    Add-TestFirewallRules -AgentExe $agentExe -Port $Port -FwProfile 'Private'

    Write-Section 'START OPENLOGI AGENT (user session)'
    $agentOut = Join-Path $C.IoDir 'startagent.json'
    Remove-Item -LiteralPath $agentOut -ErrorAction SilentlyContinue
    Invoke-UserTask -Name 'StartAgent' -ScriptPath (Join-Path $C.SuiteDir 'UserSide.ps1') `
        -Arguments @('-Action', 'StartAgent', '-Exe', $agentExe, '-LogFilter', $HT.LogFilter, '-OutFile', $agentOut) `
        -Wait -TimeoutSec 30 | Out-Null
    Start-Sleep -Seconds 5
    if (Test-Path -LiteralPath $agentOut) {
        Write-R ('Agent launch result: ' + ((Get-Content -LiteralPath $agentOut -Raw).Trim()))
    }
    $agentProc = Get-Process -Name 'openlogi-agent' -ErrorAction SilentlyContinue
    if (-not $agentProc) {
        Write-R 'openlogi-agent is not running after launch - check SmartScreen and the user session.' 'ERROR'
    }
    else {
        Write-R ('openlogi-agent running pid={0}' -f ($agentProc.Id -join ','))
    }

    Write-Section 'AGENT STATUS / DEVICES'
    Start-Sleep -Seconds 3
    $status = Get-CliJson @('api', 'status')
    if ($status) {
        Write-R ('api status: ' + (($status | ConvertTo-Json -Depth 6 -Compress)))
    }
    else {
        Write-R 'api status returned no JSON (agent not reachable over the named pipe).' 'ERROR'
    }
    $devs = Get-CliJson @('api', 'devices')
    if ($devs -and $devs.ok) {
        Write-R ('inventory: ' + $devs.data.inventory)
        foreach ($d in @($devs.data.devices)) {
            Write-R ('  device id={0} name={1} kind={2} online={3}' -f $d.id, $d.name, $d.kind, $d.online)
        }
        if (-not (@($devs.data.devices) | Where-Object { $_.id -match '^(serial:|unit:)' })) {
            Write-R 'No device exposes a serial:/unit: id - Bluetooth-direct Flow mapping needs one (checklist 3). Switching may fail.' 'WARN'
        }
    }
    else {
        Write-R 'api devices returned nothing usable.' 'WARN'
    }

    if ($StartAtEpochMs -gt 0) {
        $waitMs = $StartAtEpochMs - (Get-NowMs)
        if ($waitMs -gt 0) {
            $maxWait = [Math]::Max(0, $C.DeadlineMs - (Get-NowMs) - $HT.CleanupReserveSec * 1000)
            if ($waitMs -gt $maxWait) { $waitMs = $maxWait }
            Write-R ('Coordinated start: waiting {0} ms until T0={1}' -f $waitMs, (Format-Ms $StartAtEpochMs))
            Start-Sleep -Milliseconds $waitMs
        }
    }

    Write-Section 'FLOW ENABLE / PAIR'
    $fe = Invoke-Cli @('flow', 'enable')
    Write-R ('flow enable: code={0} out={1} err={2}' -f $fe.Code, ($fe.Out.Trim()), ($fe.Err.Trim()))
    if ($PeerAddress) {
        $pr = Invoke-Cli @('flow', 'pair-start', $PeerAddress) 30
        Write-R ('flow pair-start {0}: code={1} out={2} err={3}' -f $PeerAddress, $pr.Code, ($pr.Out.Trim()), ($pr.Err.Trim()))
        Start-Sleep -Seconds 3
        $fs = Get-CliJson @('flow', 'status')
        if ($fs) { Write-R ('flow status after pair-start: ' + (($fs | ConvertTo-Json -Depth 6 -Compress))) }
        Write-R 'SAS confirmation is a HUMAN step: verify the 6-digit code matches on both machines, then run `openlogi flow confirm` on BOTH (see RUNBOOK). This script does NOT auto-confirm.' 'WARN'
    }
    else {
        Write-R 'No -PeerAddress given: pairing (incl. SAS confirmation) must be done manually on both machines before crossings can occur. See RUNBOOK.' 'WARN'
    }

    if ($HumanGateSec -gt 0) {
        Write-Section ('HUMAN GATE ({0}s): confirm SAS on BOTH machines, grant any TCC prompts, prepare to move the real mouse' -f $HumanGateSec)
        Write-R ('Sleeping {0}s — do: openlogi flow confirm (both) + Accessibility/Input Monitoring/Local Network on Mac if prompted.' -f $HumanGateSec) 'WARN'
        Start-Sleep -Seconds $HumanGateSec
    }

    Write-Section 'FLOW LAYOUT (GM: Mac Mini is LEFT of Jay-Alienware)'
    Write-R ('Defaults: this host edge={0} -> peer (Mac). Override with -FlowEdge / -PeerName. Schema: [[flow.layout]] edge + peer (openlogi-core config/flow.rs).' -f $FlowEdge)
    # Existing user config.toml was backed up with the config dir; cleanup restores it.
    [void](Apply-FlowLayoutAndReload -Edge $FlowEdge -PeerNamePreferred $PeerName -Port $Port)

    Write-Section 'FLOW CROSSING MEASUREMENT'
    $measureStart = Get-NowMs
    if ($SkipInjection) {
        Write-R ('SendInput injection skipped (-SkipInjection). Perform real-mouse crossings now; waiting {0}s.' -f $MeasureWaitSec) 'WARN'
        Start-Sleep -Seconds $MeasureWaitSec
    }
    else {
        Write-R 'Attempting SendInput motion to the edge. NOTE: OpenLogi drops INJECTED mouse motion before the edge detector (openlogi-hook/src/windows/hook.rs), so a crossing is NOT expected from synthetic input; a HUMAN must move the real mouse.' 'WARN'
        $injOut = Join-Path $C.IoDir 'inject.json'
        Remove-Item -LiteralPath $injOut -ErrorAction SilentlyContinue
        Invoke-UserTask -Name 'Inject' -ScriptPath (Join-Path $C.SuiteDir 'UserSide.ps1') `
            -Arguments @('-Action', 'Inject', '-Edge', $FlowEdge, '-OutFile', $injOut) `
            -Wait -TimeoutSec 40 | Out-Null
        if (Test-Path -LiteralPath $injOut) {
            Write-R ('Injection probe: ' + ((Get-Content -LiteralPath $injOut -Raw).Trim()))
        }
        Write-R ('Now move the REAL mouse across Alienware LEFT edge to Mac (and back from Mac RIGHT) several times; waiting up to {0}s for crossings in the log.' -f $MeasureWaitSec) 'WARN'
        $deadline = (Get-Date).AddSeconds($MeasureWaitSec)
        while ((Get-Date) -lt $deadline) {
            $hit = @(Get-AgentEvents -SinceMs $measureStart | Where-Object { $_.Event -match 'handoff (completed|finished)|edge|rejected|timed out' })
            if ($hit.Count -gt 0) { break }
            Start-Sleep -Seconds 2
        }
    }

    Write-Section 'FLOW EVENTS (from agent log, UTC->local)'
    $events = Get-AgentEvents -SinceMs $measureStart
    if (-not $events -or $events.Count -eq 0) {
        Write-R 'No Flow events found in the agent log for this window. (No crossing happened, or the agent did not log.)' 'WARN'
    }
    $pendingSwitch = $null
    foreach ($e in $events) {
        Write-R (Format-Event $e) 'EVENT'
        if ($e.Event -eq 'Flow runtime armed') { $pendingSwitch = $null }
        if ($e.Event -match 'edge') { $pendingSwitch = $e }
        if ($e.Event -eq 'Flow handoff completed' -and $pendingSwitch) {
            $dur = $e.Ms - $pendingSwitch.Ms
            $oc = $script:OutcomeNames[[string]$e.Fields['outcome']]
            Write-R ('  CROSSING DURATION (sender edge->handoff completed): {0} ms  [start={1} end={2} outcome={3}]' -f $dur, (Format-Ms $pendingSwitch.Ms), (Format-Ms $e.Ms), $oc) 'TIMING'
            $pendingSwitch = $null
        }
        if ($e.Event -eq 'Flow incoming handoff finished') {
            $oc = $script:OutcomeNames[[string]$e.Fields['outcome']]
            Write-R ('  RECEIVER arrival: outcome={0} arrived={1}/{2} at {3}' -f $oc, $e.Fields['arrived'], $e.Fields['requested'], (Format-Ms $e.Ms)) 'TIMING'
        }
    }
    $fsFinal = Get-CliJson @('flow', 'status')
    if ($fsFinal) {
        Write-R ('Final flow status: ' + (($fsFinal | ConvertTo-Json -Depth 6 -Compress)))
    }
}
catch {
    Write-R ('RUN ERROR: ' + ($_ | Out-String)) 'ERROR'
}
finally {
    try { Invoke-FullRestore -Reason 'main run end' } catch { Write-R ('Restore error: ' + $_) 'ERROR' }
    Write-Section 'DONE'
    Write-R ('Result log: {0}' -f $C.ResultLog)
}
