# Pester tests for HwTest.Common.ps1 (offline, on Linux pwsh 7.4 with Set-StrictMode -Version Latest).
# Windows-only cmdlets are stubbed and mocked; NOTHING here touches a real service/task/process/firewall.
# NOTE: this is the closest offline equivalent of Windows PowerShell 5.1; it is not 5.1 itself.
BeforeAll {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('olhw-pester-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:ProgramData = Join-Path $root 'ProgramData'
    if (-not $env:SystemRoot) { $env:SystemRoot = Join-Path $root 'Windows' }
    New-Item -ItemType Directory -Path $env:ProgramData | Out-Null
    # Stubs so Pester can mock commands that do not exist on Linux.
    foreach ($n in @('Get-ScheduledTask', 'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask',
            'Start-ScheduledTask', 'Stop-ScheduledTask', 'New-ScheduledTaskAction', 'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet',
            'Get-Service', 'Set-Service', 'Stop-Service', 'Start-Service', 'Get-CimInstance', 'Get-NetFirewallRule', 'Remove-NetFirewallRule',
            'New-NetFirewallRule', 'Get-NetFirewallApplicationFilter', 'Get-NetUDPEndpoint')) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
            Set-Item -Path ('function:global:' + $n) -Value {
                [CmdletBinding(SupportsShouldProcess = $true)]
                param($TaskPath, $TaskName, $Name, $DisplayName, [Parameter(ValueFromPipeline = $true)]$InputObject, $StartupType, [switch]$Force,
                    $Filter, $ClassName, $LocalPort, $Action, $Principal, $Settings, $Trigger, $Execute, $Argument, $UserId, $LogonType,
                    $RunLevel, $Program, $Direction, $Protocol, $Profile, $Group, $Description, $Enabled)
            }
        }
    }
    . (Join-Path $PSScriptRoot '..\HwTest.Common.ps1')
    Set-StrictMode -Version Latest          # stricter than production (2.0) on purpose
    [void](Import-HwAllowlist)
    $script:TestRoot = $root
    $script:ResultLog = Join-Path $root 'result.log'
    function New-TestCtx {
        $c = [ordered]@{
            Version = 2; TargetUser = 'JAY-ALIENWARE\jay'; Sid = 'S-1-5-21-1-2-3-1001'; Profile = 'C:\Users\jay'
            WorkRoot = $HT.WorkRoot; SuiteDir = (Join-Path $HT.WorkRoot 'suite'); StatePath = (Join-Path $HT.WorkRoot 'state.json')
            LeasePath = (Join-Path $HT.WorkRoot 'lease.json'); PrePath = (Join-Path $HT.WorkRoot 'snapshot-pre.json'); PostPath = (Join-Path $HT.WorkRoot 'snapshot-post.json')
            BackupDir = (Join-Path $HT.WorkRoot 'backup'); ResultLog = $script:ResultLog
            PkgDir = 'C:\Users\jay\OpenLogi-hwtest-pkg'; PkgRoot = 'C:\Users\jay\OpenLogi-hwtest-pkg\OpenLogi'; IoDir = $null
            ConfigHome = 'C:\Users\jay\.config'; StateHome = 'C:\Users\jay\.local\state'; DataHome = 'C:\Users\jay\.local\share'
            ConfigDir = 'C:\Users\jay\.config\openlogi'; StateDir = 'C:\Users\jay\.local\state\openlogi'; DataDir = 'C:\Users\jay\.local\share\openlogi'
            ParentDirs = @(); ExtraDirs = @(); MainPid = $PID; MainStartUtc = ''; StartedMs = 1; DeadlineMs = 0; HardCapMs = 0; Completed = $false; Port = 42424
            Actions = [ordered]@{ servicesChanged = @(); tasksDisabled = @(); firewallRules = @(); userTasks = @(); backups = @(); killed = @() }
        }
        return $c
    }
    function New-FakeProc([string]$Name, [int]$Id, [string]$Path) { [pscustomobject]@{ Name = $Name; Id = $Id; Path = $Path } }
    function New-FakeTask([string]$TaskPath, [string]$TaskName, [string]$Exe, [string]$State = 'Ready') {
        [pscustomobject]@{ TaskPath = $TaskPath; TaskName = $TaskName; State = $State; Actions = @([pscustomobject]@{ Execute = $Exe }) }
    }
    $script:AgentPath = 'C:\Program Files\LogiOptionsPlus\logioptionsplus_agent.exe'
    $script:PluginPath = 'C:\Program Files\Logi\LogiPluginService\LogiPluginService.exe'
}
AfterAll { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'StrictMode helpers (run-1 crash class)' {
    It 'Get-Count handles $null, scalar, array' {
        Get-Count $null | Should -Be 0
        Get-Count ([pscustomobject]@{ a = 1 }) | Should -Be 1
        Get-Count @(1, 2, 3) | Should -Be 3
    }
    It 'Get-Count of an EMPTY command result is 0 (was 1 before run 2: @($null).Count = 1)' {
        function Get-Nothing { }
        Get-Count (Get-Nothing) | Should -Be 0
        Mock Get-Process { }
        Get-Count (Get-Process -Name 'logioptionsplus_agent' -ErrorAction SilentlyContinue) | Should -Be 0
    }
    It 'Get-AL returns no phantom $null entries for empty / missing keys' {
        @(Get-AL 'scheduledTasksDisable').Count | Should -Be 0
        @(Get-AL 'noSuchKey').Count | Should -Be 0
        @(Get-AL 'services').Count | Should -Be 1
    }
    It 'Get-Prop never throws on missing properties' {
        Get-Prop $null 'x' | Should -BeNullOrEmpty
        Get-Prop ([pscustomobject]@{ a = 1 }) 'missing' | Should -BeNullOrEmpty
        Get-Prop @{ a = 2 } 'a' | Should -Be 2
    }
    It 'reproduces the run-1 crash: .Count on a single real Process object throws under StrictMode' {
        $one = Get-Process -Id $PID
        { $null = $one.Count } | Should -Throw '*Count*'
        Get-Count $one | Should -Be 1
        @($one).Count | Should -Be 1
    }
    It 'Test-InList: empty value / null list never match' {
        Test-InList '' @('') | Should -BeFalse
        Test-InList 'x' $null | Should -BeFalse
        Test-InList 'A' @('a') | Should -BeTrue
    }
}

Describe 'Watch-OptionsPlusRespawn (0 / 1 / many processes)' {
    BeforeEach {
        $script:Ctx = New-TestCtx
        Mock Start-Sleep { [Threading.Thread]::Sleep(300) }
        Mock Stop-Process { }
        Mock Get-CimInstance { $null }
        Mock Save-State { }
    }
    It 'returns 0 when Get-Process returns nothing' {
        Mock Get-Process { $null }
        Watch-OptionsPlusRespawn 1 | Should -Be 0
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
    It 'handles a SINGLE respawned process (scalar, the run-1 crash)' {
        Mock Get-Process { New-FakeProc 'logioptionsplus_agent' 4242 $script:AgentPath } -ParameterFilter { $Name -eq 'logioptionsplus_agent' }
        Mock Get-Process { $null } -ParameterFilter { $Name -ne 'logioptionsplus_agent' }
        (Watch-OptionsPlusRespawn 1) | Should -BeGreaterThan 0
        Should -Invoke Stop-Process -ParameterFilter { $Id -eq 4242 }
    }
    It 'handles MANY processes and never kills a non-allowlisted path' {
        Mock Get-Process { @((New-FakeProc 'logioptionsplus_agent' 4242 $script:AgentPath), (New-FakeProc 'logioptionsplus_agent' 6666 'C:\Users\jay\Downloads\logioptionsplus_agent.exe')) } -ParameterFilter { $Name -eq 'logioptionsplus_agent' }
        Mock Get-Process { New-FakeProc 'LogiPluginService' 5555 $script:PluginPath } -ParameterFilter { $Name -eq 'LogiPluginService' }
        Mock Get-Process { $null } -ParameterFilter { $Name -ne 'logioptionsplus_agent' -and $Name -ne 'LogiPluginService' }
        (Watch-OptionsPlusRespawn 1) | Should -BeGreaterThan 1
        Should -Invoke Stop-Process -ParameterFilter { $Id -eq 4242 }
        Should -Invoke Stop-Process -ParameterFilter { $Id -eq 5555 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 6666 }
    }
}

Describe 'Scheduled task matching (run-1 LoginCheck bug)' {
    BeforeAll {
        $script:LoginCheck = New-FakeTask '\Microsoft\Windows\PushToInstall\' 'LoginCheck' 'C:\Windows\system32\sc.exe'
        $script:LogiTask = New-FakeTask '\LogiOptionsPlus\' 'UpdaterTask' 'C:\Program Files\LogiOptionsPlus\logioptionsplus_updater.exe'
        $script:MsLogi = New-FakeTask '\Microsoft\Windows\Logitech\' 'Fake' 'C:\Program Files\LogiOptionsPlus\x.exe'
        $script:ByExe = New-FakeTask '\Vendor\' 'Helper' 'C:\Program Files\LogiOptionsPlus\helper.exe'
        $script:Login2 = New-FakeTask '\Other\' 'UserLoginSync' 'C:\x\login.exe'
    }
    It 'zero tasks -> empty array' {
        Mock Get-ScheduledTask { $null }
        @(Get-LogiTasks).Count | Should -Be 0
    }
    It 'one task (scalar) -> one result' {
        Mock Get-ScheduledTask { $script:LogiTask }
        @(Get-LogiTasks).Count | Should -Be 1
    }
    It 'excludes \Microsoft\Windows\PushToInstall\LoginCheck and includes \LogiOptionsPlus\' {
        Mock Get-ScheduledTask { @($script:LoginCheck, $script:LogiTask, $script:MsLogi, $script:ByExe, $script:Login2) }
        $names = @(Get-LogiTasks | ForEach-Object { Get-TaskFullPath $_ })
        $names | Should -Contain '\LogiOptionsPlus\UpdaterTask'
        $names | Should -Contain '\Vendor\Helper'
        $names | Should -Not -Contain '\Microsoft\Windows\PushToInstall\LoginCheck'
        $names | Should -Not -Contain '\Microsoft\Windows\Logitech\Fake'
        $names | Should -Not -Contain '\Other\UserLoginSync'
    }
    It 'never allows disabling anything under \Microsoft\ or not in the allowlist' {
        Test-TaskDisableAllowed '\Microsoft\Windows\PushToInstall\LoginCheck' | Should -BeFalse
        Test-TaskDisableAllowed '\LogiOptionsPlus\UpdaterTask' | Should -BeFalse   # observed but not allowlisted (allowlist is empty)
    }
    It 'allows re-enabling LoginCheck only via the repair list (run-1 damage)' {
        Test-TaskReEnableAllowed '\Microsoft\Windows\PushToInstall\LoginCheck' | Should -BeTrue
        Test-TaskReEnableAllowed '\Microsoft\Windows\Other\Task' | Should -BeFalse
    }
}

Describe 'Stop-OptionsPlus touches only allowlisted items' {
    BeforeEach {
        $script:Ctx = New-TestCtx
        Mock Save-State { }
        Mock Get-CimInstance { $null }
        Mock Get-ServiceStartType { 'Manual' }
        Mock Get-Service { [pscustomobject]@{ Name = 'OptionsPlusUpdaterService'; Status = 'Stopped' } } -ParameterFilter { $Name -eq 'OptionsPlusUpdaterService' }
        Mock Get-Service { [pscustomobject]@{ Name = 'Other'; Status = 'Running' } } -ParameterFilter { $Name -ne 'OptionsPlusUpdaterService' }
        Mock Set-Service { }
        Mock Stop-Service { }
        Mock Disable-ScheduledTask { }
        Mock Stop-Process { }
        Mock Get-ScheduledTask { @($script:LoginCheck, $script:LogiTask) }
        Mock Get-Process { @((New-FakeProc 'logioptionsplus_agent' 4242 $script:AgentPath), (New-FakeProc 'logioptionsplus_agent' 6666 'D:\elsewhere\logioptionsplus_agent.exe')) } -ParameterFilter { $Name -eq 'logioptionsplus_agent' }
        Mock Get-Process { $null } -ParameterFilter { $Name -ne 'logioptionsplus_agent' }
    }
    It 'changes only OptionsPlusUpdaterService, disables no task, kills only the allowlisted path' {
        Stop-OptionsPlus $null
        Should -Invoke Set-Service -Times 1 -Exactly
        Should -Invoke Set-Service -Times 0 -Exactly -ParameterFilter { $Name -ne 'OptionsPlusUpdaterService' }
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 6666 }
    }
}

Describe 'Restore is best-effort per item' {
    BeforeEach {
        $script:Ctx = New-TestCtx
        Reset-RestoreResults
        Mock Save-State { }
    }
    It 'Invoke-FullRestore continues past a failing step and reports it' {
        Mock Read-Snapshot { $null }
        Mock Stop-OpenLogi { throw 'injected failure' }
        Mock Remove-HwTestUserTasks { }
        Mock Restore-OptionsPlus { }
        Mock Remove-TestFirewallRules { }
        Mock Restore-RegistryValues { }
        Mock Remove-TestFiles { }
        Mock Unregister-Watchdog { }
        $ok = Invoke-FullRestore -Reason 'test'
        $ok | Should -BeFalse
        Should -Invoke Restore-OptionsPlus -Times 1 -Exactly
        Should -Invoke Remove-TestFirewallRules -Times 1 -Exactly
        Should -Invoke Remove-TestFiles -Times 1 -Exactly
        Should -Invoke Unregister-Watchdog -Times 1 -Exactly
        @($script:RestoreResults | Where-Object { $_.Status -eq 'ERROR' -and $_.Detail -match 'injected failure' }).Count | Should -Be 1
    }
    It 'Restore-OptionsPlus: a service error does not stop task repair; non-allowlisted task is NOT enabled' {
        $script:Ctx.Actions.tasksDisabled = @('\Microsoft\Windows\PushToInstall\|LoginCheck', '\Microsoft\Windows\Defrag\|ScheduledDefrag')
        Mock Get-ServiceStartType { throw 'service query failed' }
        Mock Get-Service { [pscustomobject]@{ Name = 'OptionsPlusUpdaterService'; Status = 'Stopped' } }
        Mock Enable-ScheduledTask { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskPath = $TaskPath; TaskName = $TaskName; State = 'Ready' } }
        Mock Get-Process { $null }
        Restore-OptionsPlus $null
        Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LoginCheck' }
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskName -eq 'ScheduledDefrag' }
        @($script:RestoreResults | Where-Object { $_.Status -eq 'ERROR' -and $_.Item -like 'service*' }).Count | Should -Be 1
        @($script:RestoreResults | Where-Object { $_.Status -eq 'OK' -and $_.Item -like '*LoginCheck' }).Count | Should -Be 1
    }
}

Describe 'Allowlist enforcement (non-allowlisted items are never touched)' {
    BeforeEach { $script:Ctx = New-TestCtx; Reset-RestoreResults; Mock Save-State { } }
    It 'Remove-PathSafe refuses paths that are not allowlisted' {
        $victim = Join-Path $script:TestRoot 'victim'
        New-Item -ItemType Directory -Path $victim | Out-Null
        Remove-PathSafe $victim
        Test-Path -LiteralPath $victim | Should -BeTrue
        @($script:RestoreResults | Where-Object { $_.Status -eq 'ERROR' -and $_.Detail -match 'not in allowlist' }).Count | Should -Be 1
    }
    It 'Test-PathAllowed: exact allowlisted paths only' {
        Test-PathAllowed 'C:\Users\jay\.config\openlogi' | Should -BeTrue
        Test-PathAllowed 'C:\Users\jay\OpenLogi-hwtest-pkg' | Should -BeTrue
        Test-PathAllowed 'C:\Users\jay' | Should -BeFalse
        Test-PathAllowed 'C:\Users\jay\.config\openlogi2' | Should -BeFalse
        Test-PathAllowed 'C:\Program Files\LogiOptionsPlus' | Should -BeFalse
    }
    It 'Invoke-UserTask refuses a task name not in ownScheduledTasks' {
        Mock Register-ScheduledTask { }
        { Invoke-UserTask -Name 'Evil' -ScriptPath 'x.ps1' } | Should -Throw '*not in allowlist*'
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
    It 'Stop-OpenLogi kills only the test package path; other OpenLogi builds are LEFTOVER' {
        Mock Get-Process { @((New-FakeProc 'openlogi-agent' 7000 'C:\Users\jay\OpenLogi-hwtest-pkg\OpenLogi\openlogi-agent.exe'), (New-FakeProc 'openlogi-agent' 7003 'C:\dev\OpenLogi\target\release\openlogi-agent.exe')) } -ParameterFilter { $Name -eq 'openlogi-agent' }
        Mock Get-Process { $null } -ParameterFilter { $Name -ne 'openlogi-agent' }
        Mock Stop-Process { }
        Mock Start-Sleep { }
        $script:Ctx.PkgRoot = Join-Path $script:TestRoot 'pkgroot'
        New-Item -ItemType Directory -Path $script:Ctx.PkgRoot -Force | Out-Null
        $script:Ctx.PkgRoot = 'C:\Users\jay\OpenLogi-hwtest-pkg\OpenLogi'
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\Users\jay\OpenLogi-hwtest-pkg\OpenLogi' }
        Stop-OpenLogi
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 7000 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 7003 }
        @($script:RestoreResults | Where-Object { $_.Status -eq 'LEFTOVER' }).Count | Should -Be 1
    }
    It 'Remove-TestFirewallRules removes only exact own rule names' {
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $Name -eq 'OpenLogiHwTest-UDP-42424' }
        Mock Get-NetFirewallRule { $null } -ParameterFilter { $Name -ne 'OpenLogiHwTest-UDP-42424' }
        Mock Get-OpenLogiFirewallRules { @('OpenLogiHwTest-UDP-42424|x|True|Inbound|Allow|Private|', 'TCP Query User{ABC}C:\x\openlogi-agent.exe|openlogi-agent|True|Inbound|Allow|Private|C:\x\openlogi-agent.exe') }
        Mock Remove-NetFirewallRule { }
        Remove-TestFirewallRules $null
        Should -Invoke Remove-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenLogiHwTest-UDP-42424' }
        Should -Invoke Remove-NetFirewallRule -Times 0 -Exactly -ParameterFilter { $Name -ne 'OpenLogiHwTest-UDP-42424' }
        @($script:RestoreResults | Where-Object { $_.Status -eq 'LEFTOVER' -and $_.Item -match 'Query User' }).Count | Should -Be 1
    }
}

Describe 'Lease watchdog' {
    BeforeEach { $script:Ctx = New-TestCtx }
    It 'decision table' {
        $n = 1800000000000; $l = $n + 1200000; $c = $n + 7200000
        Get-LeaseDecision -NowMs $n -LeaseUntilMs $l -HardCapMs $c -Completed $false -MainAlive $true -StateExists $false | Should -Be 'exit-nostate'
        Get-LeaseDecision -NowMs $n -LeaseUntilMs $l -HardCapMs $c -Completed $true -MainAlive $true -StateExists $true | Should -Be 'exit-completed'
        Get-LeaseDecision -NowMs $n -LeaseUntilMs $l -HardCapMs $c -Completed $false -MainAlive $true -StateExists $true | Should -Be 'wait'
        Get-LeaseDecision -NowMs $n -LeaseUntilMs $l -HardCapMs $c -Completed $false -MainAlive $false -StateExists $true | Should -Be 'fire-main-dead'
        Get-LeaseDecision -NowMs $l -LeaseUntilMs $l -HardCapMs $c -Completed $false -MainAlive $true -StateExists $true | Should -Be 'fire-lease-expired'
        Get-LeaseDecision -NowMs $c -LeaseUntilMs ($c + 5) -HardCapMs $c -Completed $false -MainAlive $true -StateExists $true | Should -Be 'fire-hardcap'
    }
    It 'renewal is now+lease, capped at the hard cap' {
        Get-NextLeaseUntil -NowMs 1000 -LeaseMinutes 20 -HardCapMs 99999999 | Should -Be (1000 + 1200000)
        Get-NextLeaseUntil -NowMs 1000 -LeaseMinutes 20 -HardCapMs 5000 | Should -Be 5000
    }
    It 'Update-Lease writes lease.json that Read-Lease and the watchdog understand' {
        New-Item -ItemType Directory -Path $HT.WorkRoot -Force | Out-Null
        $script:Ctx.HardCapMs = (Get-NowMs) + 7200000
        Update-Lease -Phase 'gate-x' -Quiet
        $r = Read-Lease
        $r.HardCapMs | Should -Be $script:Ctx.HardCapMs
        ($r.LeaseUntilMs - (Get-NowMs)) | Should -BeGreaterThan 1190000
        $r.Phase | Should -Be 'gate-x'
        Update-Lease -Phase 'blocking' -ToHardCap -Quiet
        (Read-Lease).LeaseUntilMs | Should -Be $script:Ctx.HardCapMs
        Format-LeaseStatus | Should -Match '硬上限'
    }
    It 'expired lease + alive main -> fire (hung main is not trusted forever)' {
        $script:Ctx.HardCapMs = (Get-NowMs) + 7200000
        $lease = (Get-NowMs) - 1
        Get-LeaseDecision -NowMs (Get-NowMs) -LeaseUntilMs $lease -HardCapMs $script:Ctx.HardCapMs -Completed $false -MainAlive $true -StateExists $true | Should -Be 'fire-lease-expired'
    }
}

Describe 'Wait-HumanGate (no countdowns)' {
    BeforeEach {
        $script:Ctx = New-TestCtx
        $script:Ctx.HardCapMs = (Get-NowMs) + 7200000
        Mock Start-GateSleep { }
        Mock Update-Lease { }
        Mock Write-Banner { }
        $script:Inputs = New-Object System.Collections.Queue
        Mock Read-GateKeyLine { if ($script:Inputs.Count -gt 0) { return $script:Inputs.Dequeue() } return $null }
    }
    It 'skip' { $script:Inputs.Enqueue('skip'); Wait-HumanGate -Title 't' -MaxIterations 50 | Should -Be 'skip' }
    It 'listed command' { $script:Inputs.Enqueue('Y'); Wait-HumanGate -Title 't' -Commands @('y', 'n') -MaxIterations 50 | Should -Be 'y' }
    It 'abort throws OperationCanceledException' {
        $script:Inputs.Enqueue('abort')
        { Wait-HumanGate -Title 't' -MaxIterations 50 } | Should -Throw -ExceptionType ([System.OperationCanceledException])
    }
    It 'auto-continues when the check passes' {
        Wait-HumanGate -Title 't' -Check { @{ Done = $true; Status = 'ok' } } -AutoContinue -PollSec 0 -MaxIterations 50 | Should -Be 'done'
    }
    It 'Enter with failing check keeps waiting; never times out on its own' {
        $script:Inputs.Enqueue(''); $script:Inputs.Enqueue('')
        { Wait-HumanGate -Title 't' -Check { @{ Done = $false; Status = 'no' } } -PollSec 0 -MaxIterations 200 } | Should -Throw '*MaxIterations*'
    }
    It 'renews the lease when the gate opens' {
        $script:Inputs.Enqueue('skip')
        [void](Wait-HumanGate -Title 't' -MaxIterations 50)
        Should -Invoke Update-Lease -Times 1
    }
    It 'hard cap reached at a gate -> throws' {
        $script:Ctx.HardCapMs = 1000
        { Wait-HumanGate -Title 't' -MaxIterations 50 } | Should -Throw '*HARD CAP*'
    }
}

Describe 'Flow status parsing' {
    It 'Prompted' {
        $s = ConvertFrom-FlowStatus ('{"enabled":true,"peers":[],"pairing":{"Prompted":{"sas":"123456","machine_name":"Mac-mini","local_confirmed":false,"peer_confirmed":true}}}' | ConvertFrom-Json)
        $s.Phase | Should -Be 'Prompted'; $s.Sas | Should -Be '123456'; $s.PeerName | Should -Be 'Mac-mini'; $s.PeerConfirmed | Should -BeTrue
        Format-Sas $s.Sas | Should -Be '123 456'
    }
    It 'Paired with one peer (scalar array)' {
        $s = ConvertFrom-FlowStatus ('{"enabled":true,"peers":[{"name":"Mac-mini","state":"Connected"}],"pairing":{"Paired":{"name":"Mac-mini"}}}' | ConvertFrom-Json)
        $s.Phase | Should -Be 'Paired'; @($s.Peers).Count | Should -Be 1; @($s.ConnectedPeers)[0] | Should -Be 'Mac-mini'
    }
    It 'Failed / null / unavailable' {
        (ConvertFrom-FlowStatus ('{"enabled":true,"peers":[],"pairing":{"Failed":{"Timeout":{"message":"pairing window closed"}}}}' | ConvertFrom-Json)).Failure | Should -Match 'Timeout'
        (ConvertFrom-FlowStatus ('{"enabled":true,"peers":[],"pairing":null}' | ConvertFrom-Json)).Phase | Should -Be 'None'
        (ConvertFrom-FlowStatus $null).Phase | Should -Be 'Unavailable'
    }
}

Describe 'Run-1 state compatibility' {
    It 'Read-State maps the run-1 layout' {
        New-Item -ItemType Directory -Path $HT.WorkRoot -Force | Out-Null
        $p = Join-Path $script:TestRoot 'run1-state.json'
        @'
{"TargetUser":"JAY-ALIENWARE\\jay","Sid":"S-1-5-21-1","Profile":"C:\\Users\\jay","ResultLog":"C:\\Users\\jay\\OpenLogi-test-result.log",
 "PkgDir":"C:\\Users\\jay\\OpenLogi-hwtest-pkg\\OpenLogi","ConfigDir":"C:\\Users\\jay\\.config\\openlogi","StateDir":"C:\\Users\\jay\\.local\\state\\openlogi",
 "DataDir":"C:\\Users\\jay\\.local\\share\\openlogi","ParentDirs":["C:\\Users\\jay\\.config"],"ExtraDirs":[],"MainPid":1234,"StartedMs":1,"DeadlineMs":2,"Completed":false,"Port":42424,
 "Actions":{"servicesChanged":["OptionsPlusUpdaterService"],"tasksDisabled":["\\Microsoft\\Windows\\PushToInstall\\|LoginCheck"],"firewallRules":[],"userTasks":[],"backups":[],"killed":[]}}
'@ | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Read-State $p
        $s.PkgRoot | Should -Be 'C:\Users\jay\OpenLogi-hwtest-pkg\OpenLogi'
        $s.PkgDir | Should -BeLike '*OpenLogi-hwtest-pkg'
        $s.ConfigHome | Should -BeLike '*.config'
        $s.HardCapMs | Should -Be 0
        @($s.Actions.tasksDisabled).Count | Should -Be 1
        @($s.Actions.firewallRules).Count | Should -Be 0
    }
}
