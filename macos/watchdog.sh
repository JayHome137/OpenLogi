#!/usr/bin/env bash
# Lease watchdog (crash failsafe). Called every 60 s by the LaunchDaemon com.openlogi.hwtest.watchdog
# (StartInterval 60, also at boot) and every 30 s by a detached loop, both from the protected copy in
# /Library/Application Support/OpenLogi-hwtest/suite. Usage: watchdog.sh --tick
# Does NOTHING while the main script is alive and renewing its lease (lease.json). Restores when:
#   main script died / window closed  |  lease expired (main hung)  |  absolute hard cap passed.
# Exit codes: 0 = still waiting (or fired), 10 = nothing left to watch (loop stops).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"
set +e
al_load || exit 1

self_remove() {
  [[ -f "$HT_WATCHDOG_PLIST" ]] && rm -f "$HT_WATCHDOG_PLIST"
  if [[ "${HT_FROM_LAUNCHD:-0}" == 1 ]] && lctl_loaded system "$HT_WATCHDOG_LABEL"; then
    lctl bootout system "$HT_WATCHDOG_LABEL"   # last action: launchd stops this very job
  fi
}

if [[ ! -f "$(state_path)" ]]; then self_remove; exit 10; fi
load_state_env
HT_USER_WORK="$HT_HOME/Library/Application Support/OpenLogi-hwtest"
read -r LEASE_UNTIL LEASE_CAP <<<"$(read_lease "$(lease_path)")"
[[ "${LEASE_CAP:-0}" -gt 0 ]] && HT_HARDCAP_MS="$LEASE_CAP"
ALIVE=0; main_alive && ALIVE=1
DECISION="$(lease_decision "$(now_ms)" "${LEASE_UNTIL:-0}" "${HT_HARDCAP_MS:-0}" "${HT_COMPLETED:-0}" "$ALIVE" 1)"
case "$DECISION" in
  wait) exit 0 ;;
  exit-*) self_remove; exit 10 ;;
esac

write_r ERROR "WATCHDOG FIRED: $DECISION (lease until $(fmt_ms "${LEASE_UNTIL:-0}"), hard cap $(fmt_ms "${HT_HARDCAP_MS:-0}"), main pid ${HT_MAIN_PID:-?} alive=$ALIVE)"
if [[ $ALIVE -eq 1 ]]; then
  kill -9 "$HT_MAIN_PID" 2>/dev/null && write_r WARN "Killed main test script pid $HT_MAIN_PID"
fi
full_restore "watchdog: $DECISION" || write_r ERROR "Watchdog restore reported errors (see RESTORE SUMMARY)"
write_r INFO "Watchdog done."
self_remove
exit 10
