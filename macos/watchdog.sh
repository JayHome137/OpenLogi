#!/usr/bin/env bash
# Failsafe watchdog: detached process and/or LaunchDaemon call this.
# Idempotent restore to the pre-snapshot; kills OpenLogi so hooks are released.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# Prefer the installed copy under /Library/... so we survive source-dir deletion.
if [[ -f "/Library/Application Support/OpenLogi-hwtest/suite/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "/Library/Application Support/OpenLogi-hwtest/suite/common.sh"
else
  # shellcheck source=/dev/null
  source "$DIR/common.sh"
fi
export HT_COMMON="$DIR/common.sh"

if [[ ! -f "$(state_path)" ]]; then
  uninstall_watchdog || true
  exit 0
fi
load_state_env
if [[ "${HT_COMPLETED:-0}" == "1" ]]; then
  uninstall_watchdog || true
  exit 0
fi
write_r ERROR "WATCHDOG FIRED (deadline $(fmt_ms "${HT_DEADLINE_MS:-0}")). Main pid ${HT_MAIN_PID:-?}."
if [[ -n "${HT_MAIN_PID:-}" ]] && kill -0 "$HT_MAIN_PID" 2>/dev/null; then
  kill "$HT_MAIN_PID" 2>/dev/null || true
  sleep 1
  kill -9 "$HT_MAIN_PID" 2>/dev/null || true
  write_r WARN "Killed main test script pid $HT_MAIN_PID"
fi
full_restore "watchdog" || write_r ERROR "Watchdog restore reported errors"
uninstall_watchdog || true
write_r INFO "Watchdog done."
