#!/usr/bin/env bash
# Manual emergency restore. Run with sudo:
#   sudo /path/to/emergency-restore.sh [--delete-openlogi-dirs]
# Idempotent. Prefer this if the main test or watchdog left Options+ disabled.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DELETE_DIRS=0
[[ "${1:-}" == "--delete-openlogi-dirs" ]] && DELETE_DIRS=1
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 2
fi
# Prefer installed suite copy.
if [[ -f "/Library/Application Support/OpenLogi-hwtest/suite/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "/Library/Application Support/OpenLogi-hwtest/suite/common.sh"
else
  # shellcheck source=/dev/null
  source "$DIR/common.sh"
fi
export HT_COMMON="$DIR/common.sh"

if [[ -f "$(state_path)" ]]; then
  load_state_env
  write_r WARN "EMERGENCY RESTORE (manual) using saved state"
  if [[ -n "${HT_MAIN_PID:-}" && "$HT_MAIN_PID" != "$$" ]] && kill -0 "$HT_MAIN_PID" 2>/dev/null; then
    kill "$HT_MAIN_PID" 2>/dev/null || true
  fi
  full_restore "emergency"
  exit 0
fi

# No saved state: guide defaults.
init_context "$(console_user)"
write_r WARN "EMERGENCY RESTORE WITHOUT saved state - bootstrap known plists only (no enable/disable)"
stop_openlogi || true
# No saved state: bootstrap known plists only — do NOT launchctl enable/disable (preserve overrides).
export HT_GUI_LABELS_JSON='["com.logi.cp-dev-mgr"]'
export HT_SYS_LABELS_JSON='["com.logi.optionsplus.updater"]'
export HT_GUI_JOBS_JSON='{"com.logi.cp-dev-mgr":"/Library/LaunchAgents/com.logi.optionsplus.plist"}'
export HT_SYS_JOBS_JSON='{"com.logi.optionsplus.updater":"/Library/LaunchDaemons/com.logi.optionsplus.updater.plist"}'
export HT_DISABLED_BEFORE_JSON='{}'
export HT_ACT_DISABLED_JSON='["gui/'"$HT_TARGET_UID"'/com.logi.cp-dev-mgr","system/com.logi.optionsplus.updater"]'
export HT_ACT_BACKUPS_JSON='[]'
# No snapshot: unknown if LogiPluginService was running. Best-effort relaunch if absent
# (idempotent). Whether cp-dev-mgr relaunches it after bootstrap is also UNKNOWN.
export HT_PLUGIN_WAS_RUNNING=1
restore_options_plus || true
if [[ "$DELETE_DIRS" -eq 1 ]]; then
  rm -rf "$HT_CONFIG_DIR" "$HT_STATE_DIR" "$HT_DATA_DIR" 2>/dev/null || true
  [[ -d "$HT_APP" ]] && rm -rf "$HT_APP"
else
  write_r WARN "Left OpenLogi dirs/app in place (pass --delete-openlogi-dirs to remove)"
fi
uninstall_watchdog || true
rm -rf "$HT_WORK" 2>/dev/null || true
write_r INFO "Emergency restore finished. Options+ allowlisted procs:"
list_optionsplus_procs | while IFS= read -r line; do write_r INFO "  $line"; done
