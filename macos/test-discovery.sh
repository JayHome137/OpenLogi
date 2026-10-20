#!/usr/bin/env bash
# Offline harness: feed real-shaped sample outputs into list_logi_labels + process matcher.
# Run on the Linux box: bash macos/test-discovery.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/common.sh"
DATA="$DIR/testdata"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== list_logi_labels (gui sample) ==="
export HT_LAUNCHCTL_PRINT_FILE="$DATA/launchctl-print-gui.txt"
GUI="$(list_logi_labels "gui/502")"
echo "$GUI"
echo "$GUI" | grep -qx 'com.logi.cp-dev-mgr' && pass "found com.logi.cp-dev-mgr" || fail "missing com.logi.cp-dev-mgr"
echo "$GUI" | grep -qx 'application.com.logi.pluginservice.99ABC' && pass "found plugin service label" || fail "missing plugin service"
echo "$GUI" | grep -qx 'com.logitech.LogiRightSight.Agent' && pass "found RightSight (observe)" || fail "missing RightSight"
echo "$GUI" | grep -q 'com.logi.optionsplus$' && fail "should NOT invent label com.logi.optionsplus" || pass "no false com.logi.optionsplus label"

echo "=== list_logi_labels (system sample) ==="
export HT_LAUNCHCTL_PRINT_FILE="$DATA/launchctl-print-system.txt"
SYS="$(list_logi_labels "system")"
echo "$SYS"
echo "$SYS" | grep -qx 'com.logi.optionsplus.updater' && pass "found updater" || fail "missing updater"

echo "=== print-disabled ==="
unset HT_LAUNCHCTL_PRINT_FILE
export HT_LAUNCHCTL_DISABLED_FILE="$DATA/launchctl-print-disabled-gui.txt"
DIS="$(print_disabled_map "gui/502")"
echo "$DIS"
echo "$DIS" | grep -q 'com.logi.optionsplus.logivoice	disabled' && pass "logivoice disabled" || fail "logivoice override"
echo "$DIS" | grep -q 'com.logi.cp-dev-mgr	enabled' && pass "cp-dev-mgr enabled override" || fail "cp-dev-mgr override"

echo "=== process allowlist ==="
unset HT_LAUNCHCTL_DISABLED_FILE
export HT_PS_FILE="$DATA/ps-axww.txt"
PROCS="$(list_optionsplus_procs)"
echo "$PROCS"
echo "$PROCS" | grep -q 'logioptionsplus_agent' && pass "agent process" || fail "agent process"
echo "$PROCS" | grep -q 'LogiPluginServiceExt' && pass "plugin ext" || fail "plugin ext"
echo "$PROCS" | grep -q 'loginwindow' && fail "loginwindow must be excluded" || pass "loginwindow excluded"
echo "$PROCS" | grep -q 'logind' && fail "logind must be excluded" || pass "logind excluded"
echo "$PROCS" | grep -q 'launchd' && fail "launchd must be excluded" || pass "launchd excluded"
echo "$PROCS" | grep -q 'openlogi' && fail "openlogi must be excluded" || pass "openlogi excluded"
# Truncated '/Library/Application' alone must not match
echo "$PROCS" | awk -F'\t' '$3=="/Library/Application"{exit 1}' && pass "truncated Application path excluded" || fail "truncated path matched"

echo "=== stop-target classification ==="
label_is_stop_target "com.logi.cp-dev-mgr" && pass "stop cp-dev-mgr" || fail "stop cp-dev-mgr"
label_is_stop_target "com.logi.optionsplus.updater" && pass "stop updater" || fail "stop updater"
label_is_plugin_app_job "application.com.logi.pluginservice.99ABC" && pass "plugin is RunningBoard app job" || fail "plugin app job"
label_is_plugin_app_job "application.com.logi.pluginservice.107432213.107432218" && pass "real Mini-shaped plugin label" || fail "Mini plugin label"
label_is_stop_target "application.com.logi.pluginservice.99ABC" && fail "must NOT bootout plugin label" || pass "plugin not a bootout target"
[[ "$(normalize_launchd_label application.com.logi.pluginservice.107432213.107432218)" == "application.com.logi.pluginservice.*" ]] && pass "normalize plugin label" || fail "normalize"
label_is_never_touch "com.logitech.LogiRightSight.Agent" && pass "never-touch RightSight" || fail "RightSight"
label_is_stop_target "com.logitech.LogiRightSight.Agent" && fail "must not stop RightSight" || pass "RightSight not a stop target"
label_is_stop_target "com.logi.optionsplus.logivoice" && fail "must not stop logivoice" || pass "logivoice not a stop target"
label_is_stop_target "com.logi.optionsplus" && fail "com.logi.optionsplus is not a real label" || pass "fake label not stop target"

echo "=== safe_kill refuses forbidden (dry: list only) ==="
# Ensure loginwindow pid 100 is NOT in allowlist output
echo "$PROCS" | awk -F'\t' '$1==100{exit 1}' && pass "pid 100 (loginwindow) not killable via list" || fail "pid 100 listed"


echo "=== plugin restore helpers ==="
type ensure_logi_plugin_service >/dev/null && pass "ensure_logi_plugin_service defined" || fail "ensure missing"
type logi_plugin_service_running >/dev/null && pass "logi_plugin_service_running defined" || fail "running helper missing"
echo "NOTE: whether cp-dev-mgr (logioptionsplus_agent) relaunches LogiPluginService after bootstrap is UNKNOWN; restore is idempotent."

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL HARNESS CHECKS PASSED"
  exit 0
else
  echo "HARNESS FAILURES: $FAIL"
  exit 1
fi
