#!/usr/bin/env bash
# Offline test suite (Linux box). Runs every check and writes full logs to test-logs/.
# Usage: tools/run-offline-tests.sh [path-to-bash-3.2]
# shellcheck disable=SC2016,SC2086  # single-quoted pwsh/python code; file lists are intentionally word-split
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/test-logs"
BASH32="${1:-/tmp/bash-3.2.57/bash}"
mkdir -p "$LOG"
SUMMARY="$LOG/SUMMARY.txt"
: > "$SUMMARY"
cd "$ROOT" || exit 1
run() {   # run NAME LOGFILE CMD...
  local name="$1" lf="$2"; shift 2
  { echo "### $(date '+%Y-%m-%d %H:%M:%S %Z')"; echo "### cmd: $*"; echo; } > "$LOG/$lf"
  "$@" >> "$LOG/$lf" 2>&1
  local rc=$?
  echo "### exit=$rc" >> "$LOG/$lf"
  if [ $rc -eq 0 ]; then echo "PASS  $name  ($lf)" | tee -a "$SUMMARY"; else echo "FAIL  $name  rc=$rc  ($lf)" | tee -a "$SUMMARY"; fi
}
PS_FILES="windows/HwTest.Common.ps1 windows/Invoke-OpenLogiFlowTest.ps1 windows/Watchdog.ps1 windows/Emergency-Restore.ps1 windows/UserSide.ps1 windows/tests/HwTest.Tests.ps1 tools/Test-PsParse.ps1"
SH_FILES="macos/common.sh macos/run-openlogi-flow-test.sh macos/watchdog.sh macos/emergency-restore.sh macos/inject.sh macos/test-discovery.sh tools/run-offline-tests.sh"

{ echo "pwsh: $(pwsh -NoProfile -c '$PSVersionTable.PSVersion.ToString()')"; echo "PSScriptAnalyzer: $(pwsh -NoProfile -c '(Get-Module -ListAvailable PSScriptAnalyzer|Select -First 1).Version.ToString()')"
  echo "Pester: $(pwsh -NoProfile -c '(Get-Module -ListAvailable Pester|Sort Version -Desc|Select -First 1).Version.ToString()')"
  echo "bash: $BASH_VERSION"; echo "bash32: $("$BASH32" -c 'echo $BASH_VERSION' 2>/dev/null || echo missing)"; echo "shellcheck: $(shellcheck --version | sed -n 2p)"; echo "python3: $(python3 --version)"; } > "$LOG/tool-versions.txt"

run "json: allowlist.json + testdata parse" json.log python3 -c '
import json,glob,sys
for f in ["allowlist.json"]+glob.glob("macos/testdata/*.json"):
    json.load(open(f,encoding="utf-8")); print("ok", f)'
run "ps1: UTF-8 BOM present" bom.log bash -c 'rc=0; for f in '"$PS_FILES"'; do if head -c3 "$f" | od -An -tx1 | grep -q "ef bb bf"; then echo "BOM  $f"; else echo "NO-BOM $f"; rc=1; fi; done; exit $rc'
run "ps1: pwsh parser (0 errors)" ps-parse.log pwsh -NoProfile -File tools/Test-PsParse.ps1 $PS_FILES
run "ps1: PSScriptAnalyzer default + 5.1 Desktop compat (no Error, no compat findings)" pssa.log pwsh -NoProfile -c '
Import-Module PSScriptAnalyzer
$r = @(Invoke-ScriptAnalyzer -Path ./windows -Settings ./windows/tests/PSScriptAnalyzerSettings.psd1)
$r | Sort-Object ScriptName, Line | Format-Table -AutoSize -Wrap Severity, RuleName, ScriptName, Line, Message | Out-String -Width 220
$compat = @($r | Where-Object { $_.RuleName -like "PSUseCompatible*" }); $err = @($r | Where-Object { [string]$_.Severity -eq "Error" })
"TOTAL={0} compat={1} errors={2}" -f $r.Count, $compat.Count, $err.Count
exit ([int](($compat.Count + $err.Count) -gt 0))'
run "ps1: Pester (StrictMode Latest, mocks)" pester.log pwsh -NoProfile -c '
Import-Module Pester -MinimumVersion 5.0
$c = New-PesterConfiguration; $c.Run.Path = "./windows/tests"; $c.Output.Verbosity = "Detailed"; $c.Run.PassThru = $true
$r = Invoke-Pester -Configuration $c
"TOTAL passed={0} failed={1}" -f $r.PassedCount, $r.FailedCount; exit ([int]($r.FailedCount -gt 0))'
run "sh: bash -n (bash 5)" bash-n.log bash -c 'rc=0; for f in '"$SH_FILES"'; do bash -n "$f" && echo "ok $f" || rc=1; done; exit $rc'
if [ -x "$BASH32" ]; then
  run "sh: bash -n (bash 3.2.57)" bash32-n.log bash -c 'rc=0; for f in '"$SH_FILES"'; do "'"$BASH32"'" -n "$f" && echo "ok $f" || rc=1; done; exit $rc'
else echo "SKIP  bash 3.2 checks (no $BASH32)" | tee -a "$SUMMARY"; fi
run "sh: shellcheck (default severity)" shellcheck.log shellcheck -x -P macos $SH_FILES
run "sh: shellcheck -S style (all levels)" shellcheck-style.log shellcheck -x -P macos -S style $SH_FILES
run "sh: test-discovery.sh under bash 5" discovery-bash5.log bash macos/test-discovery.sh
if [ -x "$BASH32" ]; then run "sh: test-discovery.sh under bash 3.2.57" discovery-bash32.log "$BASH32" macos/test-discovery.sh; fi
run "secrets: no token-looking strings in tree" secrets.log bash -c '! grep -rnE "(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,})" --exclude-dir=.git --exclude-dir=test-logs .'
echo; cat "$SUMMARY"
! grep -q '^FAIL' "$SUMMARY"
