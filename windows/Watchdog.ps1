# Failsafe watchdog. Executed by the one-shot SYSTEM scheduled task "OpenLogiHwTest-Watchdog"
# (registered by Invoke-OpenLogiFlowTest.ps1 BEFORE Options+ is touched). Runs from the
# protected copy in C:\ProgramData\OpenLogi-hwtest\suite. Idempotent.
# 1) kill the main test script  2) kill OpenLogi (releases input hooks)  3) restore Options+
# 4) remove firewall rules / files / tasks  5) post-snapshot diff  6) delete itself.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'HwTest.Common.ps1')

$state = Read-State
if (-not $state) {
    # Nothing to restore (already cleaned up). Remove ourselves and leave.
    Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}
$script:Ctx = $state
$script:ResultLog = $state.ResultLog
if ($state.Completed) {
    Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}
Write-R ('WATCHDOG FIRED (deadline {0}). Main script pid {1}.' -f (Format-Ms ([long]$state.DeadlineMs)), $state.MainPid) 'ERROR'
try {
    $mp = Get-Process -Id ([int]$state.MainPid) -ErrorAction SilentlyContinue
    if ($mp -and $mp.Name -match '^(powershell|pwsh)$') { Stop-Process -Id $mp.Id -Force -ErrorAction SilentlyContinue; Write-R ('Killed main test script pid {0}' -f $mp.Id) 'WARN' }
}
catch {}
try { Invoke-FullRestore -Reason 'watchdog' -FromWatchdog }
catch { Write-R ('Watchdog restore error: ' + $_) 'ERROR' }
Write-R 'Watchdog done; deleting watchdog task.'
Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
