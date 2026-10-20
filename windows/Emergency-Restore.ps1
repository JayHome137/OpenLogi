<#
.SYNOPSIS
  Manual emergency restore for the OpenLogi Flow hardware test (Windows, Jay-Alienware .9). Elevated PowerShell:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Emergency-Restore.ps1
  - With saved test state (C:\ProgramData\OpenLogi-hwtest\state.json + snapshot-pre.json; also a run-1 state):
    full restore to the snapshot, same code path as the watchdog. Re-enables a task ONLY if the state records that
    the test disabled it AND it is in allowlist.json (this repairs run 1's \Microsoft\Windows\PushToInstall\LoginCheck).
  - Without state: allowlist-only defaults: kill test OpenLogi processes (exact paths), remove own OpenLogiHwTest-* tasks
    (exact names), OptionsPlusUpdaterService -> Automatic + Running, remove own firewall rules (exact names).
    -RepairLoginCheck: also re-enable \Microsoft\Windows\PushToInstall\LoginCheck if it is Disabled (run-1 damage
    when the state file is gone). OpenLogi config/log dirs are only deleted with -DeleteOpenLogiDirs.
  Every item is attempted; failures are logged and summarised at the end. Idempotent.
#>
param([switch]$DeleteOpenLogiDirs, [switch]$RepairLoginCheck, [string]$TargetUser)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'HwTest.Common.ps1')
if (-not (Test-IsAdmin)) { Write-Host 'Run this from an elevated (Administrator) PowerShell.' -ForegroundColor Red; exit 2 }
[void](Import-HwAllowlist)

$state = Read-State
if ($state) {
    $script:Ctx = $state
    $script:ResultLog = $state.ResultLog
    if (-not $script:ResultLog) { $script:ResultLog = (New-HwContext -TargetUser $TargetUser).ResultLog }
    Write-R 'EMERGENCY RESTORE (manual) using saved state' 'WARN'
    if ((Test-MainAlive $state) -and [int]$state.MainPid -ne $PID) {
        try { Stop-Process -Id ([int]$state.MainPid) -Force -ErrorAction Stop; Write-R ('Killed main test script pid {0}' -f $state.MainPid) 'WARN' }
        catch { Write-R ('Could not kill main pid: ' + $_.Exception.Message) 'ERROR' }
    }
    $ok = $false
    try { $ok = Invoke-FullRestore -Reason 'emergency' } catch { Write-R ('restore error: ' + $_) 'ERROR' }
    try { Unregister-Watchdog } catch {}
    if ($ok) { exit 0 } else { exit 3 }
}

$script:Ctx = New-HwContext -TargetUser $TargetUser
$script:ResultLog = $script:Ctx.ResultLog
Reset-RestoreResults
Write-R 'EMERGENCY RESTORE (manual) WITHOUT saved state - allowlist-only defaults' 'WARN'
Invoke-RestoreStep 'stop OpenLogi test processes' { Stop-OpenLogi }
Invoke-RestoreStep 'remove own user tasks' { Remove-HwTestUserTasks }
Invoke-RestoreStep 'restore Options+ (defaults)' { Restore-OptionsPlus $null }
if ($RepairLoginCheck) {
    foreach ($e in (Get-AL 'scheduledTasksRepairEnableOnly')) {
        $full = [string](Get-Prop $e 'path'); $i = $full.LastIndexOf('\')
        Invoke-RestoreStep ('repair ' + $full) {
            $t = Get-ScheduledTask -TaskPath $full.Substring(0, $i + 1) -TaskName $full.Substring($i + 1) -ErrorAction Stop | Select-Object -First 1
            if ([string](Get-Prop $t 'State') -eq 'Disabled') { Enable-ScheduledTask -TaskPath $full.Substring(0, $i + 1) -TaskName $full.Substring($i + 1) -ErrorAction Stop | Out-Null }
            Add-RestoreResult ('task ' + $full) 'OK' ('state=' + [string](Get-Prop (Get-ScheduledTask -TaskPath $full.Substring(0, $i + 1) -TaskName $full.Substring($i + 1) | Select-Object -First 1) 'State'))
        }
    }
}
else {
    foreach ($e in (Get-AL 'scheduledTasksRepairEnableOnly')) {
        $full = [string](Get-Prop $e 'path'); $i = $full.LastIndexOf('\')
        $t = Get-ScheduledTask -TaskPath $full.Substring(0, $i + 1) -TaskName $full.Substring($i + 1) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($t -and [string](Get-Prop $t 'State') -eq 'Disabled') { Add-RestoreResult ('task ' + $full) 'WARN' 'Disabled (run-1 damage?) - re-run with -RepairLoginCheck to enable it' }
    }
}
Invoke-RestoreStep 'firewall (own rules only)' { Remove-TestFirewallRules $null }
Invoke-RestoreStep 'remove package dir' { if ($script:Ctx.PkgDir) { Remove-PathSafe $script:Ctx.PkgDir } }
foreach ($d in @($script:Ctx.ConfigDir, $script:Ctx.StateDir, $script:Ctx.DataDir)) {
    if ($d -and (Test-Path -LiteralPath $d)) {
        if ($DeleteOpenLogiDirs) { Invoke-RestoreStep ('remove ' + $d) { Remove-PathSafe $d } }
        else { Add-RestoreResult ('keep ' + $d) 'LEFTOVER' 'use -DeleteOpenLogiDirs to remove' }
    }
}
Invoke-RestoreStep 'unregister watchdog' { Unregister-Watchdog }
Invoke-RestoreStep 'remove work dir' { if (Test-Path -LiteralPath $HT.WorkRoot) { Remove-PathSafe $HT.WorkRoot } }
$ok = Write-RestoreSummary
Write-R ('Options+ processes now: ' + ((@(Get-OptionsPlusProcessInfo | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '))
if ($ok) { exit 0 } else { exit 3 }
