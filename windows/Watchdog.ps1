# Crash failsafe (lease watchdog). Executed EVERY MINUTE by the SYSTEM scheduled task "OpenLogiHwTest-Watchdog"
# (registered by Invoke-OpenLogiFlowTest.ps1 BEFORE Options+ is touched; also runs 1 min after a reboot).
# Runs from the protected copy in C:\ProgramData\OpenLogi-hwtest\suite. Idempotent.
# It does NOTHING while the main script is alive and keeps renewing the lease (C:\ProgramData\OpenLogi-hwtest\lease.json).
# It restores when: the main script died / was closed, OR the lease expired (main hung), OR the absolute hard cap passed.
# Restore = kill main script -> kill OpenLogi -> restore Options+ (allowlist only) -> remove rules/files/tasks -> diff -> delete itself.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'HwTest.Common.ps1')
try { [void](Import-HwAllowlist) } catch { }   # allowlist missing -> restore functions refuse mutations (fail closed)

$state = Read-State
$lease = Read-Lease
$now = Get-NowMs
$leaseUntil = 0; $hardCap = 0
if ($lease) { $leaseUntil = [long]$lease.LeaseUntilMs; $hardCap = [long]$lease.HardCapMs }
if ($state -and $hardCap -le 0) { $hardCap = [long](Get-Prop $state 'HardCapMs') }
if ($state -and $leaseUntil -le 0) { $leaseUntil = [long](Get-Prop $state 'DeadlineMs') }   # run-1 state: DeadlineMs only
$alive = $false; if ($state) { $alive = Test-MainAlive $state }
$completed = $false; if ($state) { $completed = [bool](Get-Prop $state 'Completed') }
$decision = Get-LeaseDecision -NowMs $now -LeaseUntilMs $leaseUntil -HardCapMs $hardCap -Completed $completed -MainAlive $alive -StateExists ([bool]$state)

if ($decision -like 'exit-*') {
    Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}
if ($decision -eq 'wait') { exit 0 }

$script:Ctx = $state
$script:ResultLog = $state.ResultLog
Write-R ('WATCHDOG FIRED: {0}. lease until {1}, hard cap {2}, main pid {3} alive={4}.' -f $decision, (Format-Ms $leaseUntil), (Format-Ms $hardCap), (Get-Prop $state 'MainPid'), $alive) 'ERROR'
if ($alive) {
    try {
        Stop-Process -Id ([int]$state.MainPid) -Force -ErrorAction Stop
        Write-R ('Killed main test script pid {0}' -f $state.MainPid) 'WARN'
    }
    catch { Write-R ('Could not kill main pid {0}: {1}' -f $state.MainPid, $_.Exception.Message) 'ERROR' }
}
$ok = $false
try { $ok = Invoke-FullRestore -Reason ('watchdog: ' + $decision) -FromWatchdog }
catch { Write-R ('Watchdog restore error: ' + $_) 'ERROR' }
Write-R ('Watchdog done (restore ok={0}); deleting watchdog task.' -f $ok)
Unregister-ScheduledTask -TaskName $HT.WatchdogTask -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
