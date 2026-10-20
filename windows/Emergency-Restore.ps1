<#
.SYNOPSIS
  Manual emergency restore for the OpenLogi Flow hardware test (Windows). Run in an elevated PowerShell:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Emergency-Restore.ps1
  - With a saved test state (C:\ProgramData\OpenLogi-hwtest\state.json + snapshot-pre.json): full restore to the snapshot,
    same code path as the watchdog.
  - Without it: kills OpenLogi, sets OptionsPlusUpdaterService back to Automatic and starts it (guide default),
    removes OpenLogiHwTest-* scheduled tasks and the OpenLogi-HwTest firewall group. It does NOT delete
    OpenLogi config/log dirs (it cannot know whether they existed before) unless -DeleteOpenLogiDirs is given.
  Idempotent: safe to run repeatedly, also while/after the watchdog ran.
#>
param([switch]$DeleteOpenLogiDirs, [string]$TargetUser)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'HwTest.Common.ps1')
if (-not (Test-IsAdmin)) { Write-Host 'Run this from an elevated (Administrator) PowerShell.'; exit 2 }

$state = Read-State
if ($state) {
    $script:Ctx = $state
    $script:ResultLog = $state.ResultLog
    Write-R 'EMERGENCY RESTORE (manual) using saved state' 'WARN'
    try {
        $mp = Get-Process -Id ([int]$state.MainPid) -ErrorAction SilentlyContinue
        if ($mp -and $mp.Id -ne $PID -and $mp.Name -match '^(powershell|pwsh)$') { Stop-Process -Id $mp.Id -Force; Write-R ('Killed main test script pid {0}' -f $mp.Id) }
    }
    catch {}
    Invoke-FullRestore -Reason 'emergency'
    Unregister-Watchdog
    exit 0
}

$script:Ctx = New-HwContext -TargetUser $TargetUser
$script:ResultLog = $script:Ctx.ResultLog
Write-R 'EMERGENCY RESTORE (manual) WITHOUT saved state - guide defaults' 'WARN'
Stop-OpenLogi
Remove-HwTestUserTasks
Restore-OptionsPlus $null
Get-NetFirewallRule -Group $HT.FirewallGroup -ErrorAction SilentlyContinue | ForEach-Object { Write-R ('Remove firewall rule ' + $_.Name); $_ | Remove-NetFirewallRule }
Remove-PathSafe $script:Ctx.PkgDir
foreach ($d in @($script:Ctx.ConfigDir, $script:Ctx.StateDir, $script:Ctx.DataDir)) {
    if ($d -and (Test-Path -LiteralPath $d)) {
        if ($DeleteOpenLogiDirs) { Remove-PathSafe $d } else { Write-R ('Left in place (use -DeleteOpenLogiDirs to remove): ' + $d) 'WARN' }
    }
}
Unregister-Watchdog
Remove-PathSafe $HT.WorkRoot
Write-R ('Logi processes now: ' + ((@(Get-LogiProcesses | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '))
