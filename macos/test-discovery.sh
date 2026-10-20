#!/usr/bin/env bash
# Offline harness for the macOS helpers (runs on Linux with bash 5 AND a locally built bash 3.2.57).
#   bash macos/test-discovery.sh            /path/to/bash-3.2 macos/test-discovery.sh
# Uses recorded/synthetic launchctl + ps dumps. Mutating helpers run in DRY mode (HT_DRY_*): they record what
# they WOULD touch, so the tests prove that non-allowlisted items are never touched.
# shellcheck disable=SC2317  # stub functions (date/ps/launchctl overrides) are invoked indirectly
DIR="$(cd "$(dirname "$0")" && pwd)"
TMPW="$(mktemp -d /tmp/ol-hwtest-harness.XXXXXX)"
export HT_WORK="$TMPW/work"
mkdir -p "$HT_WORK"
# shellcheck source=common.sh
source "$DIR/common.sh"
set +e
DATA="$DIR/testdata"
FAIL=0; PASSN=0
pass() { echo "PASS: $*"; PASSN=$((PASSN + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
ok()   { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
notok(){ local d="$1"; shift; if "$@"; then fail "$d"; else pass "$d"; fi; }
eq()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (want [$3] got [$2])"; fi; }
has()  { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
echo "bash: $BASH_VERSION"

export HT_TARGET_UID=502 HT_TARGET_USER=jayboy137 HT_HOME=/Users/jayboy137
export HT_CONFIG_HOME=/Users/jayboy137/.config HT_STATE_HOME=/Users/jayboy137/.local/state HT_DATA_HOME=/Users/jayboy137/.local/share
export HT_CONFIG_DIR="$HT_CONFIG_HOME/openlogi" HT_STATE_DIR="$HT_STATE_HOME/openlogi" HT_DATA_DIR="$HT_DATA_HOME/openlogi"
export HT_RESULT="$TMPW/result.log"
ok "allowlist loads (single source: allowlist.json)" al_load
( HT_ALLOWLIST=/nonexistent; HT_COMMON_DIR=/nonexistent; al_load ) 2>/dev/null; eq "missing allowlist fails closed" "$?" 1

echo "=== launchctl discovery (info only) ==="
export HT_LAUNCHCTL_PRINT_FILE="$DATA/launchctl-print-gui.txt"
GUI="$(list_logi_labels gui/502)"
ok "found com.logi.cp-dev-mgr" has "$GUI" com.logi.cp-dev-mgr
ok "found plugin service label" has "$GUI" application.com.logi.pluginservice.99ABC
notok "no invented com.logi.optionsplus label" has "$GUI" com.logi.optionsplus
export HT_LAUNCHCTL_PRINT_FILE="$DATA/launchctl-print-system.txt"
ok "found updater" has "$(list_logi_labels system)" com.logi.optionsplus.updater
unset HT_LAUNCHCTL_PRINT_FILE
export HT_LAUNCHCTL_DISABLED_FILE="$DATA/launchctl-print-disabled-gui.txt"
DIS="$(print_disabled_map gui/502)"
ok "logivoice override read" has "$DIS" "com.logi.optionsplus.logivoice	disabled"
ok "cp-dev-mgr override read" has "$DIS" "com.logi.cp-dev-mgr	enabled"
unset HT_LAUNCHCTL_DISABLED_FILE

echo "=== label classification (exact allowlist) ==="
ok "stop target cp-dev-mgr" label_is_stop_target com.logi.cp-dev-mgr
ok "stop target updater" label_is_stop_target com.logi.optionsplus.updater
notok "plugin label is not a bootout target" label_is_stop_target application.com.logi.pluginservice.99ABC
ok "plugin label = RunningBoard app (only dynamic id)" label_is_runningboard_app application.com.logi.pluginservice.107432213.107432218
notok "look-alike application.com.logi.pluginservicex is not the RB app" label_is_runningboard_app application.com.logi.pluginservicex.1
ok "never-touch RightSight" label_is_never_touch com.logitech.LogiRightSight.Agent
notok "RightSight not a stop target" label_is_stop_target com.logitech.LogiRightSight.Agent
notok "logivoice not a stop target" label_is_stop_target com.logi.optionsplus.logivoice
notok "manager.daemon not a stop target" label_is_stop_target com.logitech.manager.daemon
notok "com.logi.optionsplus (plist filename) not a target" label_is_stop_target com.logi.optionsplus
notok "prefix com.logi.* no longer matches (com.logi.other)" label_is_stop_target com.logi.other

echo "=== processes: exact paths, own-process exclusion ==="
export HT_PS_FILE="$DATA/ps-axww-ppid.txt" HT_MAIN_PID=9000
echo 9100 >"$HT_WORK/watchdog.pid"
OWN="$(own_pids)"
for p in 9000 9001 9002 9100 9101; do ok "own pid $p excluded (main tree / watchdog)" has "$OWN" "$p"; done
notok "unrelated pid 9200 (vim notes-openlogi.txt) not 'own'" has "$OWN" 9200
OP="$(list_optionsplus_procs | awk -F '\t' '{print $1}' | sort -n | tr '\n' ' ')"
eq "Options+ procs = exactly the allowlisted paths" "$OP" "777 4242 5555 5556 5557 6000 "
OL="$(list_openlogi_procs | awk -F '\t' '{print $1}' | sort -n | tr '\n' ' ')"
eq "OpenLogi procs = exact bundle paths only (no /tmp or dev build, no own scripts)" "$OL" "7000 7001 "
MM="$(list_optionsplus_path_mismatch | awk -F '\t' '{print $1}' | sort -n | tr '\n' ' ')"
eq "path-mismatch precheck flags look-alike names" "$MM" "6200 "
ok "GUI detected (exact main executable)" gui_running
ok "LogiPluginService detected" logi_plugin_service_running
HT_PS_FILE="$DATA/ps-axww.txt"
eq "old 'pid command' ps format still parsed" "$(list_optionsplus_procs | awk -F '\t' '{print $1}' | sort -n | tr '\n' ' ')" "777 4242 5555 5556 5557 6000 "
HT_PS_FILE="$DATA/ps-axww-ppid.txt"

echo "=== kill guard (dry) ==="
export HT_DRY_KILL="$TMPW/kills"; : >"$HT_DRY_KILL"
ok "kill allowlisted agent 4242" safe_kill_pid 4242 test op-procs
for p in 100 101 102 1 6100 6200 6300 6400 6001 7002 7003 9000 9100 9101 9200; do
  notok "refuse to kill pid $p" safe_kill_pid "$p" test op-procs 2>/dev/null
done
notok "OpenLogi kill list refuses own watchdog 9101" safe_kill_pid 9101 test ol-procs 2>/dev/null
: >"$HT_DRY_KILL"; kill_allowlisted op-procs test 2>/dev/null
eq "kill_allowlisted touches only allowlisted pids" "$(sort -n "$HT_DRY_KILL" | tr '\n' ' ')" "777 4242 5555 5556 5557 6000 "
: >"$HT_DRY_KILL"; kill_allowlisted ol-procs test 2>/dev/null
eq "OpenLogi stop touches only 7000 7001" "$(sort -n "$HT_DRY_KILL" | tr '\n' ' ')" "7000 7001 "
unset HT_DRY_KILL

echo "=== launchctl guard (dry) ==="
export HT_DRY_LAUNCHCTL="$TMPW/lctl"; : >"$HT_DRY_LAUNCHCTL"
ok "bootout gui/502/com.logi.cp-dev-mgr allowed" lctl bootout gui/502 com.logi.cp-dev-mgr
ok "bootout system/com.logi.optionsplus.updater allowed" lctl bootout system com.logi.optionsplus.updater
notok "bootout RightSight refused" lctl bootout gui/502 com.logitech.LogiRightSight.Agent 2>/dev/null
notok "bootout logivoice refused" lctl bootout gui/502 com.logi.optionsplus.logivoice 2>/dev/null
notok "bootout plugin RB job refused" lctl bootout gui/502 application.com.logi.pluginservice.99ABC 2>/dev/null
notok "wrong domain refused (updater in gui)" lctl bootout gui/502 com.logi.optionsplus.updater 2>/dev/null
notok "wrong uid refused (gui/501)" lctl bootout gui/501 com.logi.cp-dev-mgr 2>/dev/null
notok "kickstart updater not allowed (not in its actions)" lctl kickstart system com.logi.optionsplus.updater 2>/dev/null
notok "bootstrap OpenLogi agent service not allowed (bootout only)" lctl bootstrap gui/502 org.openlogi.agent.service 2>/dev/null
eq "only the 2 allowed launchctl calls were made" "$(tr '\n' ';' <"$HT_DRY_LAUNCHCTL")" "bootout gui/502/com.logi.cp-dev-mgr;bootout system/com.logi.optionsplus.updater;"
unset HT_DRY_LAUNCHCTL

echo "=== file removal guard (dry) ==="
export HT_DRY_RM="$TMPW/rm"; : >"$HT_DRY_RM"
mkdir -p "$TMPW/fake"
for p in /Applications/OpenLogi.app /Users/jayboy137/.config/openlogi /Users/jayboy137/.local/state/openlogi /Users/jayboy137/.config; do
  ok "allowlisted path accepted: $p" al_path_removable "$p"
done
for p in / /Users/jayboy137 /Users/jayboy137/Documents /Applications/logioptionsplus.app "/Applications/OpenLogi.app/../logioptionsplus.app" /Applications/OpenLogi.app/ /Users/jayboy137/.config/openlogi2 "$TMPW/fake"; do
  notok "non-allowlisted path refused: $p" al_path_removable "$p"
done
notok "rm_safe refuses $TMPW/fake" rm_safe "$TMPW/fake" 2>/dev/null
ok "rm_safe really did not remove it" test -d "$TMPW/fake"
eq "dry rm log empty" "$(cat "$HT_DRY_RM")" ""
unset HT_DRY_RM

echo "=== open guard (dry) ==="
export HT_DRY_OPEN="$TMPW/open"; : >"$HT_DRY_OPEN"
ok "open LogiPluginService.app allowed" _open_bundle_as_user /Applications/Utilities/LogiPluginService.app
ok "open logioptionsplus.app allowed" _open_bundle_as_user /Applications/logioptionsplus.app
notok "open Safari refused" _open_bundle_as_user /Applications/Safari.app 2>/dev/null
eq "open log" "$(tr '\n' ';' <"$HT_DRY_OPEN")" "/Applications/Utilities/LogiPluginService.app;/Applications/logioptionsplus.app;"
unset HT_DRY_OPEN

echo "=== lease ==="
N=1800000000000; L=$((N + 20 * 60000)); C=$((N + 120 * 60000))
eq "no state -> exit" "$(lease_decision "$N" "$L" "$C" 0 1 0)" exit-nostate
eq "completed -> exit" "$(lease_decision "$N" "$L" "$C" 1 1 1)" exit-completed
eq "alive + valid lease -> wait" "$(lease_decision "$N" "$L" "$C" 0 1 1)" wait
eq "main dead -> fire" "$(lease_decision "$N" "$L" "$C" 0 0 1)" fire-main-dead
eq "lease expired (main hung) -> fire" "$(lease_decision "$L" "$L" "$C" 0 1 1)" fire-lease-expired
eq "hard cap beats a fresh lease" "$(lease_decision "$C" $((C + 999)) "$C" 0 1 1)" fire-hardcap
eq "no lease written yet -> fire" "$(lease_decision "$N" 0 "$C" 0 1 1)" fire-lease-expired
eq "renewal = now + 20 min" "$(next_lease_until "$N" 20 "$C")" "$L"
eq "renewal capped at hard cap" "$(next_lease_until $((C - 60000)) 20 "$C")" "$C"
HT_HARDCAP_MS=$(( $(now_ms) + 120 * 60000 )); HT_LEASE_MIN=20; HT_MAIN_PID=$$
lease_renew test-phase
read -r LU LC <<<"$(read_lease "$(lease_path)")"
eq "lease file hard cap" "$LC" "$HT_HARDCAP_MS"
D=$(( LU - $(now_ms) )); ok "lease file ~20 min ahead" test "$D" -gt 1190000 -a "$D" -le 1200000
lease_renew tocap-phase tocap; read -r LU LC <<<"$(read_lease "$(lease_path)")"
eq "blocking read pushes lease to hard cap" "$LU" "$HT_HARDCAP_MS"
ok "lease_status text mentions hard cap" sh -c "printf '%s' \"\$1\" | grep -q '硬上限'" _ "$(lease_status)"
HT_MAIN_LSTART="$(proc_lstart $$)"; ok "main_alive for this shell" main_alive
HT_MAIN_LSTART="Mon Jan  1 00:00:00 2001"; notok "PID reuse detected via start time" main_alive
HT_MAIN_PID=999999; HT_MAIN_LSTART=""; notok "dead pid -> not alive" main_alive

echo "=== watchdog.sh (offline, non-firing paths) ==="
rm -f "$HT_WORK/state.json"
HT_WORK="$HT_WORK" "$BASH" "$DIR/watchdog.sh" --tick >/dev/null 2>&1; eq "watchdog: no state -> exit 10" "$?" 10
HT_MAIN_PID=$$; HT_MAIN_LSTART="$(proc_lstart $$)"; HT_STARTED_MS=1; HT_COMPLETED=0; save_state
lease_renew watchdog-test
HT_WORK="$HT_WORK" "$BASH" "$DIR/watchdog.sh" --tick >/dev/null 2>&1; eq "watchdog: alive + lease valid -> wait (exit 0)" "$?" 0
HT_COMPLETED=1 save_state
HT_WORK="$HT_WORK" "$BASH" "$DIR/watchdog.sh" --tick >/dev/null 2>&1; eq "watchdog: completed -> exit 10" "$?" 10
rm -f "$HT_WORK/state.json"

echo "=== state files (run-1 compatibility) ==="
SE="$(state_env_lines "$DATA/run1-state.json")"
ok "run-1 deadline becomes hard cap" sh -c "printf '%s\n' \"\$1\" | grep -qx 'export HT_HARDCAP_MS=1792400900000'" _ "$SE"
ok "run-1: GUI pre-state unknown (left alone)" sh -c "printf '%s\n' \"\$1\" | grep -qx 'export HT_GUI_STATE_KNOWN=0'" _ "$SE"
ok "run-1: config home derived" sh -c "printf '%s\n' \"\$1\" | grep -qx 'export HT_CONFIG_HOME=/Users/jayboy137/.config'" _ "$SE"
( eval "$SE"; [[ "$HT_ACT_DISABLED_JSON" == *'gui/502/com.logi.cp-dev-mgr'* ]] ); eq "run-1 stopped jobs carried over" "$?" 0

echo "=== snapshot diff ==="
compare_snapshots "$DATA/run1-snapshot-pre.json" "$DATA/run2-snapshot-post.json" >"$TMPW/diff1" 2>&1; eq "run-1 pre (PIDs) vs run-2 post (name=path) -> PASS" "$?" 0
grep -q 'INFO-CHANGED launchd.gui.labels' "$TMPW/diff1"; eq "old-only keys downgraded to info" "$?" 0
python3 - "$DATA/run2-snapshot-post.json" "$TMPW/post-bad.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["items"]["proc.optionsplus"]["value"] = ""
json.dump(d, open(sys.argv[2], "w"))
PY
compare_snapshots "$DATA/run2-snapshot-post.json" "$TMPW/post-bad.json" >/dev/null 2>&1; eq "missing Options+ process -> FAIL" "$?" 1

echo "=== flow status parsing ==="
eq "Prompted" "$(parse_flow_status <"$DATA/flow-prompted.json")" "$(printf 'Prompted\t123456\tJay-Alienware\t1\t0\t\t0\t')"
eq "Paired" "$(parse_flow_status <"$DATA/flow-paired.json")" "$(printf 'Paired\t\tJay-Alienware\t0\t0\t\t1\tJay-Alienware')"
eq "Failed" "$(parse_flow_status <"$DATA/flow-failed.json")" "$(printf 'Failed\t\t\t0\t0\tConnection: could not connect to 192.168.1.9:42424\t0\t')"
eq "None" "$(parse_flow_status <"$DATA/flow-none.json" | cut -f1)" None
eq "null pairing" "$(printf '%s' '{"enabled":true,"peers":[],"pairing":null}' | parse_flow_status | cut -f1)" None
eq "agent down (empty)" "$(printf '' | parse_flow_status | cut -f1)" Unavailable
eq "fmt_sas" "$(fmt_sas 123456)" "123 456"

echo "=== human gates (scripted input; no countdowns) ==="
export HT_GATE_READ_SEC=1 HT_GATE_SLEEP=0 HT_GATE_MAX_ITER=20
unset HT_HARDCAP_MS
run_gate() {  # run_gate INPUT CMDS CHECKFN AUTO
  printf '%b' "$1" >"$TMPW/gate.in"
  exec 9<"$TMPW/gate.in"
  HT_GATE_FD=9 gate "T" "p" 1 "$4" "$2" "$3" -- "line" 2>/dev/null
  local rc=$?
  exec 9<&-
  echo "$rc:$GATE_RESULT"
}
chk_ok() { echo fine; return 0; }
chk_no() { echo "not yet"; return 1; }
eq "skip" "$(run_gate 'skip\n' '' chk_no 0)" "0:skip"
eq "command y" "$(run_gate 'y\n' 'y n' chk_no 0)" "0:y"
eq "Enter + check ok -> done" "$(run_gate '\n' '' chk_ok 0)" "0:done"
eq "Enter + check failing keeps waiting, then skip" "$(run_gate '\n\nskip\n' '' chk_no 0)" "0:skip"
eq "unknown input ignored, then N" "$(run_gate 'foo\nn\n' 'y n' chk_no 0)" "0:n"
eq "auto-continue when check passes (no key needed)" "$(run_gate '' '' chk_ok 1)" "0:done"
eq "no input + failing check never auto-passes (guard stops test)" "$(run_gate '' '' chk_no 1)" "3:max"
eq "Enter without check -> done" "$(run_gate '\n' '' '' 0)" "0:done"
( run_gate 'abort\n' '' chk_no 0 >/dev/null ); eq "abort exits 130 (EXIT trap restores)" "$?" 130
( HT_HARDCAP_MS=1000; run_gate '' '' chk_no 0 >/dev/null ); eq "hard cap passed at a gate -> abort 130" "$?" 130
( HT_HARDCAP_MS=$(( $(now_ms) + 600000 )); run_gate 'ABORT\n' '' chk_no 0 >/dev/null ); eq "ABORT case-insensitive" "$?" 130

rm -rf "$TMPW"
echo
echo "PASSED: $PASSN   FAILED: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then echo "ALL HARNESS CHECKS PASSED"; exit 0; fi
echo "HARNESS FAILURES: $FAIL"; exit 1
