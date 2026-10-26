#!/usr/bin/env bash
# Manual emergency restore (Mac Mini .8). Run in Terminal:
#   sudo /bin/bash emergency-restore.sh [--delete-openlogi-dirs]
# - With saved state (also a run-1 state): full restore to the pre-snapshot (same code as the watchdog).
# - Without state: allowlist-only defaults: stop OpenLogi (exact paths), bootstrap the allowlisted Options+ jobs
#   if not loaded, start LogiPluginService if absent, unset OPENLOGI_LOG (run-1 leftover), remove watchdog + work dir.
#   OpenLogi.app / config dirs are only removed with --delete-openlogi-dirs. The Options+ GUI is left as it is.
# Every item is attempted; failures are listed in the RESTORE SUMMARY. Idempotent.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DELETE_DIRS=0
[[ "${1:-}" == "--delete-openlogi-dirs" ]] && DELETE_DIRS=1
if [[ "$(id -u)" -ne 0 ]]; then echo "Run with sudo:  sudo /bin/bash $0" >&2; exit 2; fi
# Always the code next to this file (NOT an older installed suite copy from run 1).
# shellcheck source=common.sh
source "$DIR/common.sh"
set +e
al_load || exit 2

if [[ -f "$(state_path)" ]]; then
  load_state_env
  HT_USER_WORK="$HT_HOME/Library/Application Support/OpenLogi-hwtest"
  write_r WARN "EMERGENCY RESTORE (manual) using saved state (format v${HT_STATE_VERSION:-1})"
  if main_alive && [[ "$HT_MAIN_PID" != "$$" ]]; then kill -9 "$HT_MAIN_PID" 2>/dev/null && write_r WARN "Killed main test script pid $HT_MAIN_PID"; fi
  if full_restore "emergency"; then exit 0; else exit 3; fi
fi

init_context "$(console_user)"
HT_USER_WORK="$HT_HOME/Library/Application Support/OpenLogi-hwtest"
write_r WARN "EMERGENCY RESTORE (manual) WITHOUT saved state - allowlist-only defaults"
_mutex_take
HT_RR_ERR=0; HT_RR_N=0; HT_RR_TEXT=""
HT_ACT_DISABLED_JSON="$(al_get launchd-optionsplus | awk -F '\t' '{print $1 "/" $2}' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
export HT_ACT_DISABLED_JSON HT_PLUGIN_WAS_RUNNING=1 HT_GUI_STATE_KNOWN=0
step "stop OpenLogi" stop_openlogi
step "restore Options+" restore_options_plus
for v in $(al_get env-unset); do
  if [[ -n "$(as_user launchctl getenv "$v" 2>/dev/null)" ]]; then
    launchctl asuser "$HT_TARGET_UID" launchctl unsetenv "$v"
    if [[ -z "$(as_user launchctl getenv "$v" 2>/dev/null)" ]]; then rr OK "launchctl unsetenv $v"; else rr ERROR "launchctl unsetenv $v" "still set"; fi
  fi
done
if [[ $DELETE_DIRS -eq 1 ]]; then
  for d in "$HT_APP" "$HT_CONFIG_DIR" "$HT_STATE_DIR" "$HT_DATA_DIR"; do rm_safe "$d" || true; done
  rr LEFTOVER "OpenLogi TCC permissions" "left unchanged; remove only newly added grants manually"
else
  for d in "$HT_APP" "$HT_CONFIG_DIR" "$HT_STATE_DIR" "$HT_DATA_DIR"; do [[ -e "$d" ]] && rr LEFTOVER "keep $d" "use --delete-openlogi-dirs to remove"; done
fi
step "watchdog" uninstall_watchdog
rm_safe "$HT_USER_WORK" || true
rm_safe "$HT_WORK" || true
rc=0; rr_summary || rc=3
write_r INFO "Options+ processes now: $(proc_names_running | tr '\n' ' ')"
_mutex_drop
exit $rc
