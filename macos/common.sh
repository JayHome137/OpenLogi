#!/usr/bin/env bash
# OpenLogi Flow hardware test - shared macOS helpers (sourced; never run directly).
# Must work under `bash script.sh` (Mac login shell is zsh — do not rely on zsh).
# Options+ facts verified on Jay's Mac Mini (macOS 27.0.1 arm64, user jayboy137 uid 502).
set -euo pipefail

HT_WORK="${HT_WORK:-/Library/Application Support/OpenLogi-hwtest}"
HT_USER_WORK="${HT_USER_WORK:-$HOME/Library/Application Support/OpenLogi-hwtest}"
HT_RESULT="${HT_RESULT:-$HOME/OpenLogi-test-result.log}"
HT_APP="/Applications/OpenLogi.app"
HT_CLI="$HT_APP/Contents/MacOS/openlogi"
HT_AGENT_BIN="$HT_APP/Contents/Library/LoginItems/OpenLogi Agent.app/Contents/MacOS/openlogi-agent"
HT_AGENT_BUNDLE="$HT_APP/Contents/Library/LoginItems/OpenLogi Agent.app"
HT_APP_BUNDLE_ID="org.openlogi.openlogi"
HT_AGENT_BUNDLE_ID="org.openlogi.agent"
HT_OVERLAY_BUNDLE_ID="org.openlogi.overlay"
HT_AGENT_SERVICE="org.openlogi.agent.service"
HT_FIREWALL="/usr/libexec/ApplicationFirewall/socketfilterfw"
HT_REPO="JayHome137/OpenLogi"
HT_RUN_ID="39235760610"
HT_ARTIFACT_ARM64="OpenLogi-macos-dmg-arm64"
HT_ARTIFACT_X86="OpenLogi-macos-dmg-x86_64"
HT_PORT="${HT_PORT:-42424}"
HT_LOG_FILTER='info,openlogi_agent_core=debug,openlogi_flow=debug,openlogi_device=debug,openlogi_hid=debug'
HT_MUTEX="/tmp/OpenLogiHwTestRestore.lock"
HT_CLEANUP_RESERVE_SEC=90
HT_WATCHDOG_PLIST="/Library/LaunchDaemons/com.openlogi.hwtest.watchdog.plist"
HT_WATCHDOG_LABEL="com.openlogi.hwtest.watchdog"

# Verified on Jay's Mac Mini. com.logi.optionsplus is a *plist filename*, NOT a launchd label.
# Launchd labels we expect (discovery is authoritative; this is the expected set for preflight):
#   gui:  com.logi.cp-dev-mgr
#   sys:  com.logi.optionsplus.updater
#   app:  application.com.logi.pluginservice.<numbers>  (LogiPluginService.app)
# Do NOT touch: com.logitech.LogiRightSight.Agent, com.logi.optionsplus.logivoice, com.logitech.manager.daemon
HT_EXPECTED_GUI_LABELS=(com.logi.cp-dev-mgr)
HT_EXPECTED_SYS_LABELS=(com.logi.optionsplus.updater)
HT_NEVER_TOUCH_LABELS=(com.logitech.LogiRightSight.Agent com.logi.optionsplus.logivoice com.logitech.manager.daemon)

# Exact process basenames we may kill (allowlist). Never loginwindow/logind/etc.
HT_LOGI_PROC_NAMES=(
  logioptionsplus
  logioptionsplus_agent
  logioptionsplus_updater
  LogiPluginService
  LogiPluginServiceNative
  LogiPluginServiceExt
)

# Path prefixes that identify Options+ binaries (spaces OK; matched as prefix of full path/command).
HT_LOGI_PATH_PREFIXES=(
  "/Library/Application Support/Logitech.localized/"
  "/Applications/logioptionsplus.app/"
  "/Applications/Utilities/LogiPluginService.app/"
)

# Known plist paths for bootstrap after bootout (label_path is preferred when available).
HT_PLIST_CP_DEV_MGR="/Library/LaunchAgents/com.logi.optionsplus.plist"
HT_PLIST_UPDATER="/Library/LaunchDaemons/com.logi.optionsplus.updater.plist"
HT_APP_OPTIONS_PLUS="/Applications/logioptionsplus.app"
HT_APP_PLUGIN_SERVICE="/Applications/Utilities/LogiPluginService.app"

# Real agent log messages (crates/openlogi-agent-core/src/flow/*, openlogi-device/src/inventory/probe/direct.rs).
HT_EVENT_PATTERNS=(
  "Flow runtime armed"
  "Flow handoff completed"
  "Flow incoming handoff finished"
  "Flow arrival acknowledgment timed out"
  "Flow host switch failed after receiver acceptance"
  "Flow edge has no online configured devices to hand off"
  "Flow edge ignored because the peer still reports one target device as held"
  "Flow edge ignored while peer is disconnected"
  "Flow handoff rejected"
  "Flow handoff request timed out"
  "Flow handoff request failed"
  "Flow handoff cancelled by peer"
  "Flow peer returned an invalid handoff acceptance"
  "Flow device arrived but cursor positioning failed"
  "Flow released modifier keys the departed keyboard left down"
  "invalid Flow configuration"
  "Flow runtime failed to start"
  "Flow mDNS advertisement unavailable"
  "Flow mDNS browsing unavailable"
  "BT-direct / wired device recognised"
  "agent panicked"
)

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
fmt_ms() {
  local ms="${1:-0}"
  python3 - "$ms" <<'PY'
import sys, datetime
ms = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ms/1000.0).astimezone().isoformat(timespec="milliseconds"))
PY
}
is_root() { [[ "$(id -u)" -eq 0 ]]; }
console_user() { /usr/bin/stat -f%Su /dev/console 2>/dev/null || true; }
console_uid() { /usr/bin/id -u "$(console_user)" 2>/dev/null || true; }

# write_r LEVEL MESSAGE
write_r() {
  local lvl="$1"; shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$lvl] $*"
  printf '%s\n' "$line" >&2
  if [[ -n "${HT_RESULT:-}" ]]; then
    mkdir -p "$(dirname "$HT_RESULT")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$HT_RESULT" 2>/dev/null || true
  fi
}
section() { write_r SECT "==== $* ===="; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1"; }

# State JSON helpers (python for portable JSON).
state_path() { echo "$HT_WORK/state.json"; }
save_state() {
  python3 - "$HT_WORK/state.json" <<'PY'
import json, os, sys
path = sys.argv[1]
state = {
  "targetUser": os.environ.get("HT_TARGET_USER", ""),
  "targetUid": os.environ.get("HT_TARGET_UID", ""),
  "home": os.environ.get("HT_HOME", ""),
  "resultLog": os.environ.get("HT_RESULT", ""),
  "configDir": os.environ.get("HT_CONFIG_DIR", ""),
  "stateDir": os.environ.get("HT_STATE_DIR", ""),
  "dataDir": os.environ.get("HT_DATA_DIR", ""),
  "parentDirs": json.loads(os.environ.get("HT_PARENT_DIRS_JSON", "[]")),
  "extraDirs": json.loads(os.environ.get("HT_EXTRA_DIRS_JSON", "[]")),
  "appExisted": os.environ.get("HT_APP_EXISTED", "0") == "1",
  "mainPid": int(os.environ.get("HT_MAIN_PID", "0") or 0),
  "startedMs": int(os.environ.get("HT_STARTED_MS", "0") or 0),
  "deadlineMs": int(os.environ.get("HT_DEADLINE_MS", "0") or 0),
  "completed": os.environ.get("HT_COMPLETED", "0") == "1",
  "port": int(os.environ.get("HT_PORT", "42424")),
  "guiLabels": json.loads(os.environ.get("HT_GUI_LABELS_JSON", "[]")),
  "sysLabels": json.loads(os.environ.get("HT_SYS_LABELS_JSON", "[]")),
  "guiJobs": json.loads(os.environ.get("HT_GUI_JOBS_JSON", "{}")),
  "sysJobs": json.loads(os.environ.get("HT_SYS_JOBS_JSON", "{}")),
  "disabledBefore": json.loads(os.environ.get("HT_DISABLED_BEFORE_JSON", "{}")),
  "pluginWasRunning": os.environ.get("HT_PLUGIN_WAS_RUNNING", "0") == "1",
  "actions": {
    "labelsDisabled": json.loads(os.environ.get("HT_ACT_DISABLED_JSON", "[]")),
    "backups": json.loads(os.environ.get("HT_ACT_BACKUPS_JSON", "[]")),
  },
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}
load_state_env() {
  # Exports HT_* from state.json into the environment of the caller.
  eval "$(python3 - "$(state_path)" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
with open(path, encoding="utf-8") as f:
    s = json.load(f)
def j(v): return json.dumps(v, ensure_ascii=False)
print(f'export HT_TARGET_USER={j(s.get("targetUser",""))}')
print(f'export HT_TARGET_UID={j(s.get("targetUid",""))}')
print(f'export HT_HOME={j(s.get("home",""))}')
print(f'export HT_RESULT={j(s.get("resultLog",""))}')
print(f'export HT_CONFIG_DIR={j(s.get("configDir",""))}')
print(f'export HT_STATE_DIR={j(s.get("stateDir",""))}')
print(f'export HT_DATA_DIR={j(s.get("dataDir",""))}')
print(f'export HT_PARENT_DIRS_JSON={j(s.get("parentDirs",[]))}')
print(f'export HT_EXTRA_DIRS_JSON={j(s.get("extraDirs",[]))}')
print(f'export HT_APP_EXISTED={"1" if s.get("appExisted") else "0"}')
print(f'export HT_MAIN_PID={int(s.get("mainPid") or 0)}')
print(f'export HT_STARTED_MS={int(s.get("startedMs") or 0)}')
print(f'export HT_DEADLINE_MS={int(s.get("deadlineMs") or 0)}')
print(f'export HT_COMPLETED={"1" if s.get("completed") else "0"}')
print(f'export HT_PORT={int(s.get("port") or 42424)}')
print(f'export HT_GUI_LABELS_JSON={j(s.get("guiLabels",[]))}')
print(f'export HT_SYS_LABELS_JSON={j(s.get("sysLabels",[]))}')
print(f'export HT_GUI_JOBS_JSON={j(s.get("guiJobs",{}))}')
print(f'export HT_SYS_JOBS_JSON={j(s.get("sysJobs",{}))}')
print(f'export HT_DISABLED_BEFORE_JSON={j(s.get("disabledBefore",{}))}')
print(f'export HT_PLUGIN_WAS_RUNNING={"1" if s.get("pluginWasRunning") else "0"}')
act = s.get("actions") or {}
print(f'export HT_ACT_DISABLED_JSON={j(act.get("labelsDisabled",[]))}')
print(f'export HT_ACT_BACKUPS_JSON={j(act.get("backups",[]))}')
PY
)"
}

init_context() {
  # Prefer an explicit user; else console user; else the invoking account (SSH preflight).
  local user="${1:-}"
  if [[ -z "$user" ]]; then
    user="$(console_user)"
  fi
  if [[ -z "$user" || "$user" == "root" || "$user" == "loginwindow" ]]; then
    user="$(/usr/bin/id -un)"
  fi
  local home uid
  home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [[ -n "$home" ]] || home="$(eval echo "~$user")"
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
  # Over SSH, gui/$(id -u) is the domain that works for print / print-disabled.
  if [[ -z "$uid" ]]; then uid="$(/usr/bin/id -u)"; fi
  export HT_TARGET_USER="$user" HT_TARGET_UID="$uid" HT_HOME="$home"
  export HT_RESULT="${home}/OpenLogi-test-result.log"
  # XDG layout (crates/openlogi-core/src/paths.rs). Respect absolute XDG_*_HOME if set for the user.
  local cfg_home st_home dt_home
  cfg_home="$(launchctl asuser "$uid" /usr/bin/printenv XDG_CONFIG_HOME 2>/dev/null || true)"
  st_home="$(launchctl asuser "$uid" /usr/bin/printenv XDG_STATE_HOME 2>/dev/null || true)"
  dt_home="$(launchctl asuser "$uid" /usr/bin/printenv XDG_DATA_HOME 2>/dev/null || true)"
  [[ -n "$cfg_home" && "$cfg_home" = /* ]] || cfg_home="$home/.config"
  [[ -n "$st_home" && "$st_home" = /* ]] || st_home="$home/.local/state"
  [[ -n "$dt_home" && "$dt_home" = /* ]] || dt_home="$home/.local/share"
  export HT_CONFIG_DIR="$cfg_home/openlogi"
  export HT_STATE_DIR="$st_home/openlogi"
  export HT_DATA_DIR="$dt_home/openlogi"
  export HT_PARENT_DIRS_JSON
  HT_PARENT_DIRS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
    "$cfg_home" "$home/.local" "$st_home" "$dt_home")"
  export HT_EXTRA_DIRS_JSON
  HT_EXTRA_DIRS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
    "$cfg_home/openlogi-dev" "$home/Library/Application Support/OpenLogi" \
    "$home/Library/Caches/org.openlogi.openlogi" "$home/Library/Preferences/org.openlogi.openlogi.plist")"
  export HT_APP_EXISTED="0"
  [[ -d "$HT_APP" ]] && HT_APP_EXISTED=1
  export HT_MAIN_PID=$$ HT_STARTED_MS="$(now_ms)" HT_COMPLETED=0
}

# -------- snapshot helpers --------
# Label regex: Options+ / Logitech launchd labels (BSD awk; no gawk-only features).
# NOTE: variable must NOT be named `in` — reserved in one-true-awk / BSD awk.
_HT_LABEL_RE='(com\.logi\.[A-Za-z0-9._-]+|com\.logitech\.[A-Za-z0-9._-]+|application\.com\.logi\.pluginservice\.[A-Za-z0-9._-]+)'

list_logi_labels() {
  # Args: domain  (e.g. gui/502 or system). Reads launchctl print; portable BSD awk.
  # Offline harness: set HT_LAUNCHCTL_PRINT_FILE to a sample dump (domain arg ignored).
  local domain="${1:-}"
  local src cleanup=0
  if [[ -n "${HT_LAUNCHCTL_PRINT_FILE:-}" && -f "$HT_LAUNCHCTL_PRINT_FILE" ]]; then
    src="$HT_LAUNCHCTL_PRINT_FILE"
  else
    src="$(mktemp /tmp/ht-lctl.XXXXXX)"
    cleanup=1
    launchctl print "$domain" >"$src" 2>/dev/null || true
  fi
  awk '
    /services =/ { in_svc = 1; next }
    /^=+/ {
      if (in_svc && $0 !~ /services =/) in_svc = 0
    }
    in_svc {
      if (match($0, /(com\.logi\.[A-Za-z0-9._-]+|com\.logitech\.[A-Za-z0-9._-]+|application\.com\.logi\.pluginservice\.[A-Za-z0-9._-]+)/))
        print substr($0, RSTART, RLENGTH)
    }
  ' "$src" | sort -u
  if [[ "$cleanup" -eq 1 ]]; then rm -f "$src"; fi
}

label_path() {
  local target="$1"
  local src cleanup=0
  if [[ -n "${HT_LAUNCHCTL_PRINT_TARGET_FILE:-}" && -f "$HT_LAUNCHCTL_PRINT_TARGET_FILE" ]]; then
    src="$HT_LAUNCHCTL_PRINT_TARGET_FILE"
  else
    src="$(mktemp /tmp/ht-lctl-t.XXXXXX)"
    cleanup=1
    launchctl print "$target" >"$src" 2>/dev/null || true
  fi
  # path may contain spaces: print everything after the first "path = "
  awk '/^[[:space:]]+path = /{sub(/^[[:space:]]+path = /,""); print; exit}' "$src"
  if [[ "$cleanup" -eq 1 ]]; then rm -f "$src"; fi
}

print_disabled_map() {
  # Output: label<TAB>enabled|disabled for com.logi.* / com.logitech.* / application.com.logi.pluginservice.*
  local domain="$1"
  local src cleanup=0
  if [[ -n "${HT_LAUNCHCTL_DISABLED_FILE:-}" && -f "$HT_LAUNCHCTL_DISABLED_FILE" ]]; then
    src="$HT_LAUNCHCTL_DISABLED_FILE"
  else
    src="$(mktemp /tmp/ht-lctl-d.XXXXXX)"
    cleanup=1
    launchctl print-disabled "$domain" >"$src" 2>/dev/null || true
  fi
  # Typical line: "	\"com.logi.cp-dev-mgr\" => enabled"
  awk '
    {
      if (match($0, /(com\.logi\.[A-Za-z0-9._-]+|com\.logitech\.[A-Za-z0-9._-]+|application\.com\.logi\.pluginservice\.[A-Za-z0-9._-]+)/)) {
        lab = substr($0, RSTART, RLENGTH)
        state = "unknown"
        if ($0 ~ /disabled/) state = "disabled"
        else if ($0 ~ /enabled/) state = "enabled"
        print lab "\t" state
      }
    }
  ' "$src" | sort -u
  if [[ "$cleanup" -eq 1 ]]; then rm -f "$src"; fi
}

label_is_never_touch() {
  local L="$1" x
  for x in "${HT_NEVER_TOUCH_LABELS[@]}"; do
    [[ "$L" == "$x" ]] && return 0
  done
  return 1
}

# RunningBoard app job (NOT plist-backed). Path from launchctl is
# "(submitted by runningboardd.N)". bootout cannot be undone with bootstrap.
label_is_plugin_app_job() {
  case "$1" in
    application.com.logi.pluginservice.*) return 0 ;;
    *) return 1 ;;
  esac
}

# Normalize launchd label for snapshots/diffs (plugin instance numbers change on each launch).
normalize_launchd_label() {
  case "$1" in
    application.com.logi.pluginservice.*) printf '%s
' 'application.com.logi.pluginservice.*' ;;
    *) printf '%s
' "$1" ;;
  esac
}

# Labels we bootout for the test (plist-backed only). Never RightSight / LogiVoice / manager.daemon.
# LogiPluginService application.* jobs are STOPPED BY PROCESS KILL ONLY — never bootout.
label_is_stop_target() {
  local L="$1"
  label_is_never_touch "$L" && return 1
  label_is_plugin_app_job "$L" && return 1
  case "$L" in
    com.logi.cp-dev-mgr) return 0 ;;
    com.logi.optionsplus.updater) return 0 ;;
    com.logi.optionsplus) return 1 ;;
    com.logi.*) return 0 ;;
    *) return 1 ;;
  esac
}

# True if any LogiPluginService main process is running (allowlist).
logi_plugin_service_running() {
  list_optionsplus_procs | awk -F '	' '$2 == "LogiPluginService" { found = 1 } END { exit !found }'
}

# Idempotent relaunch into the console user's GUI session (root-safe for watchdog LaunchDaemon).
# Unknown whether cp-dev-mgr relaunches the plugin on its own after bootstrap — we only open if absent.
ensure_logi_plugin_service() {
  local uid="${HT_TARGET_UID:-$(id -u)}" user="${HT_TARGET_USER:-$(id -un)}"
  if [[ "${HT_PLUGIN_WAS_RUNNING:-0}" != "1" ]]; then
    write_r INFO "LogiPluginService was not running pre-test — not launching"
    return 0
  fi
  if logi_plugin_service_running; then
    write_r INFO "LogiPluginService already running — skip relaunch (idempotent; may have been pulled up by Options+ agent)"
    return 0
  fi
  if [[ ! -d "$HT_APP_PLUGIN_SERVICE" ]]; then
    write_r ERROR "LogiPluginService.app missing at $HT_APP_PLUGIN_SERVICE"
    return 1
  fi
  write_r INFO "Relaunching LogiPluginService.app via open -g -j in gui/$uid (RunningBoard; label number will differ)"
  if [[ "$(id -u)" -eq 0 ]]; then
    # Watchdog / sudo run: asuser + sudo -u so Aqua/RunningBoard sees the real console user.
    launchctl asuser "$uid" /usr/bin/sudo -u "$user" /usr/bin/open -g -j -a "$HT_APP_PLUGIN_SERVICE" 2>/dev/null       || launchctl asuser "$uid" /usr/bin/open -g -j -a "$HT_APP_PLUGIN_SERVICE" 2>/dev/null       || true
  else
    /usr/bin/open -g -j -a "$HT_APP_PLUGIN_SERVICE" 2>/dev/null || true
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 1
    if logi_plugin_service_running; then
      write_r INFO "LogiPluginService verified running after relaunch"
      return 0
    fi
  done
  write_r ERROR "LogiPluginService did not reappear within 12s after open"
  return 1
}

# -------- process allowlist / hard kill guard --------
ht_proc_is_forbidden() {
  local name="$1" path="$2"
  case "$name" in
    loginwindow|logind|WindowServer|launchd|kernel_task|launchservicesd) return 0 ;;
  esac
  case "$path" in
    /System/*|/usr/*|/bin/*|/sbin/*) return 0 ;;
  esac
  [[ "$path" == "/Library/Application" ]] && return 0
  return 1
}

ht_proc_is_optionsplus() {
  local name="$1" cmd="$2"
  case "$name" in
    openlogi*|OpenLogi*) return 1 ;;
  esac
  local n
  for n in "${HT_LOGI_PROC_NAMES[@]}"; do
    [[ "$name" == "$n" ]] && return 0
  done
  local pfx
  for pfx in "${HT_LOGI_PATH_PREFIXES[@]}"; do
    case "$cmd" in
      "$pfx"*) return 0 ;;
    esac
  done
  return 1
}

# List Options+ processes: PID<TAB>basename<TAB>full command (spaces preserved).
# Uses `ps axww`, never `pgrep -i logi`. Offline harness: set HT_PS_FILE.
list_optionsplus_procs() {
  local psfile="${HT_PS_FILE:-}"
  local cleanup=0
  if [[ -z "$psfile" ]]; then
    psfile="$(mktemp /tmp/ht-ps.XXXXXX)"
    cleanup=1
    /bin/ps axww -o pid= -o command= >"$psfile" 2>/dev/null || true
  fi
  python3 - "$psfile" <<'PY'
import sys
allow_names = {
  "logioptionsplus", "logioptionsplus_agent", "logioptionsplus_updater",
  "LogiPluginService", "LogiPluginServiceNative", "LogiPluginServiceExt",
}
allow_prefixes = [
  "/Library/Application Support/Logitech.localized/",
  "/Applications/logioptionsplus.app/",
  "/Applications/Utilities/LogiPluginService.app/",
]
forbidden_names = {"loginwindow", "logind", "WindowServer", "launchd", "kernel_task", "launchservicesd"}

def basename_of(cmd: str) -> str:
  cmd = cmd.strip()
  if not cmd:
    return ""
  for pfx in allow_prefixes:
    if cmd.startswith(pfx):
      rest = cmd.split(" -", 1)[0].rstrip("/")
      return rest.rsplit("/", 1)[-1]
  tok = cmd.split(None, 1)[0]
  return tok.rsplit("/", 1)[-1]

def is_forbidden(name, cmd):
  if name in forbidden_names:
    return True
  if name.startswith(("openlogi", "OpenLogi")):
    return True
  if cmd.startswith(("/System/", "/usr/", "/bin/", "/sbin/")):
    return True
  if cmd.strip() == "/Library/Application":
    return True
  return False

def is_optionsplus(name, cmd):
  if is_forbidden(name, cmd):
    return False
  if name in allow_names:
    return True
  return any(cmd.startswith(pfx) for pfx in allow_prefixes)

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
  line = line.rstrip("\n")
  if not line.strip():
    continue
  s = line.lstrip()
  parts = s.split(None, 1)
  if len(parts) < 2 or not parts[0].isdigit():
    continue
  pid, cmd = parts[0], parts[1]
  name = basename_of(cmd)
  if is_optionsplus(name, cmd):
    print(f"{pid}\t{name}\t{cmd}")
PY
  if [[ "$cleanup" -eq 1 ]]; then rm -f "$psfile"; fi
}

safe_kill_pid() {
  local pid="$1" why="${2:-kill}"
  local line name cmd
  line="$(list_optionsplus_procs | awk -F '\t' -v p="$pid" '$1 == p { print; exit }')"
  if [[ -z "$line" ]]; then
    return 1
  fi
  name="$(printf '%s\n' "$line" | awk -F '\t' '{ print $2 }')"
  cmd="$(printf '%s\n' "$line" | awk -F '\t' '{ print $3 }')"
  # Reconstruct cmd if tabs in path (rare): fields 3..NF
  cmd="$(printf '%s\n' "$line" | awk -F '\t' '{ s=$3; for (i=4;i<=NF;i++) s=s "\t" $i; print s }')"
  if ht_proc_is_forbidden "$name" "$cmd"; then
    write_r ERROR "REFUSING to kill forbidden process pid=$pid name=$name path=$cmd"
    return 1
  fi
  if ! ht_proc_is_optionsplus "$name" "$cmd"; then
    write_r ERROR "REFUSING to kill non-Options+ process pid=$pid name=$name"
    return 1
  fi
  write_r INFO "safe_kill [$why] pid=$pid name=$name cmd=$cmd"
  kill "$pid" 2>/dev/null || true
  sleep 0.2
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  return 0
}

manifest_dir() {
  local d="$1"
  if [[ ! -e "$d" ]]; then echo "absent"; return; fi
  python3 - "$d" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
lines = ["present"]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort(); filenames.sort()
    rel = os.path.relpath(dirpath, root)
    if rel != ".":
        lines.append("D /" + rel)
    for name in filenames:
        path = os.path.join(dirpath, name)
        relf = "/" + os.path.relpath(path, root)
        try:
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            lines.append(f"F {relf} {os.path.getsize(path)} {h.hexdigest()}")
        except OSError:
            lines.append(f"F {relf} unreadable")
print("\n".join(lines))
PY
}

take_snapshot() {
  local out="$1"
  python3 - "$out" <<'PY'
import json, os, platform, subprocess, sys, datetime

out = sys.argv[1]
items = {}

def add(k, v, info=False):
    items[k] = {"value": "" if v is None else str(v), "info": bool(info)}

def run(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return ""

add("info.os", f"{platform.system()} {platform.mac_ver()[0]} {platform.machine()}", True)
add("info.consoleUser", os.environ.get("HT_TARGET_USER", ""), True)
add("info.sip", run(["csrutil", "status"]).strip(), True)
add("info.firewall.global", run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"]).strip(), True)

# Labels (gui + system). Plugin application.* instance numbers are normalized for diffs.
uid = os.environ.get("HT_TARGET_UID", "")

def norm_label(lab: str) -> str:
    if lab.startswith("application.com.logi.pluginservice."):
        return "application.com.logi.pluginservice.*"
    return lab

def norm_jobs(jobs: dict) -> dict:
    out = {}
    for k, v in jobs.items():
        nk = norm_label(k)
        # Prefer a real path over RunningBoard "(submitted by runningboardd...)" noise.
        if nk not in out or (str(out[nk]).startswith("(") and v and not str(v).startswith("(")):
            out[nk] = v
    return out

gui = sorted({norm_label(x) for x in json.loads(os.environ.get("HT_GUI_LABELS_JSON", "[]"))})
sysl = sorted({norm_label(x) for x in json.loads(os.environ.get("HT_SYS_LABELS_JSON", "[]"))})
add("launchd.gui.labels", "\n".join(gui))
add("launchd.sys.labels", "\n".join(sysl))
jobs_g = norm_jobs(json.loads(os.environ.get("HT_GUI_JOBS_JSON", "{}")))
jobs_s = norm_jobs(json.loads(os.environ.get("HT_SYS_JOBS_JSON", "{}")))
add("launchd.gui.jobs", "\n".join(f"{k}\t{v}" for k, v in sorted(jobs_g.items())))
add("launchd.sys.jobs", "\n".join(f"{k}\t{v}" for k, v in sorted(jobs_s.items())))
dis = json.loads(os.environ.get("HT_DISABLED_BEFORE_JSON", "{}"))
add("launchd.disabled", "\n".join(f"{k}\t{v}" for k, v in sorted(dis.items())))

# Processes — Options+ allowlist only (never pgrep -i logi; excludes loginwindow/logind)
procs = []
try:
    env = os.environ.copy()
    env["HT_COMMON"] = os.environ.get("HT_COMMON", "")
    # Call list_optionsplus_procs from the sourced helpers via bash
    common = os.environ.get("HT_COMMON", "")
    if common:
        outp = subprocess.check_output(
            ["bash", "-c", f'source "{common}"; list_optionsplus_procs'],
            text=True, stderr=subprocess.DEVNULL, env=env,
        )
        procs = [l.strip() for l in outp.splitlines() if l.strip()]
except Exception:
    pass
add("proc.optionsplus.allowlist", "\n".join(sorted(procs)))
# Stable identity: compare by process/app path, not application.com.logi.pluginservice.<N> label.
plugin_running = any(p.split("\t")[1] == "LogiPluginService" for p in procs if "\t" in p)
add("app.LogiPluginService.running", "true" if plugin_running else "false")
add("app.LogiPluginService.path", "/Applications/Utilities/LogiPluginService.app")
openp = []
try:
    outp = subprocess.check_output(["/bin/ps", "axww", "-o", "pid=", "-o", "command="], text=True, stderr=subprocess.DEVNULL)
    for line in outp.splitlines():
        s = line.lstrip()
        if "openlogi" in s.lower() or "OpenLogi" in s:
            openp.append(s.strip())
except Exception:
    pass
add("proc.openlogi", "\n".join(sorted(openp)))

# Paths
for key, envk in (("dir.config", "HT_CONFIG_DIR"), ("dir.state", "HT_STATE_DIR"), ("dir.data", "HT_DATA_DIR")):
    d = os.environ.get(envk, "")
    if d:
        # call manifest_dir via python inline
        if not os.path.exists(d):
            add(f"dir.openlogi:{d}", "absent")
        else:
            # reuse simple presence + mtime listing
            lines = ["present"]
            for dp, dns, fns in os.walk(d):
                dns.sort(); fns.sort()
                rel = os.path.relpath(dp, d)
                if rel != ".": lines.append("D /" + rel)
                for n in fns:
                    p = os.path.join(dp, n)
                    try:
                        import hashlib
                        h = hashlib.sha256(open(p,"rb").read()).hexdigest()
                        lines.append(f"F /{os.path.relpath(p,d)} {os.path.getsize(p)} {h}")
                    except Exception:
                        lines.append(f"F /{os.path.relpath(p,d)} unreadable")
            add(f"dir.openlogi:{d}", "\n".join(lines))

extra = json.loads(os.environ.get("HT_EXTRA_DIRS_JSON", "[]"))
parents = json.loads(os.environ.get("HT_PARENT_DIRS_JSON", "[]"))
for d in parents + extra + ["/Applications/OpenLogi.app"]:
    add(f"path.exists:{d}", str(os.path.exists(d)))

# BTM / Login Items (read-only dump of com.logi / org.openlogi lines)
btm = run(["sfltool", "dumpbtm"])
btm_lines = []
for line in btm.splitlines():
    low = line.lower()
    if "com.logi" in low or "org.openlogi" in low or "logitech" in low:
        btm_lines.append(line.rstrip())
add("info.btm.logi_openlogi", "\n".join(btm_lines), True)

# TCC DB readable summary (SIP may block; report what we can)
tcc_paths = [
    f"{os.environ.get('HT_HOME','')}/Library/Application Support/com.apple.TCC/TCC.db",
    "/Library/Application Support/com.apple.TCC/TCC.db",
]
tcc_rows = []
for db in tcc_paths:
    if not os.path.exists(db):
        continue
    try:
        q = "SELECT service, client, auth_value FROM access WHERE client LIKE '%openlogi%' OR client LIKE '%logi%';"
        outp = subprocess.check_output(["sqlite3", db, q], text=True, stderr=subprocess.DEVNULL)
        for line in outp.splitlines():
            tcc_rows.append(f"{db}|{line}")
    except Exception as e:
        tcc_rows.append(f"{db}|UNREADABLE:{e}")
add("info.tcc.readable", "\n".join(tcc_rows) if tcc_rows else "none-or-blocked", True)

# System extensions (info only; we never unload com.logi.options.hidfilter)
add("info.systemextensions", run(["systemextensionsctl", "list"]).strip(), True)

# Firewall apps mentioning OpenLogi / Logi
fw = run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--listapps"])
fw_lines = [l.rstrip() for l in fw.splitlines() if "openlogi" in l.lower() or "logi" in l.lower()]
add("firewall.apps.logi_openlogi", "\n".join(fw_lines))

# UDP listeners on Flow port
udp = run(["lsof", "-nP", f"-iUDP:{os.environ.get('HT_PORT','42424')}"])
add("net.udp.listeners", "\n".join(l for l in udp.splitlines() if l.strip()))

doc = {
    "takenAt": datetime.datetime.now().astimezone().isoformat(timespec="milliseconds"),
    "host": platform.node(),
    "items": items,
}
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(len(items))
PY
}

compare_snapshots() {
  local pre="$1" post="$2"
  python3 - "$pre" "$post" <<'PY'
import json, sys
pre = json.load(open(sys.argv[1], encoding="utf-8"))["items"]
post = json.load(open(sys.argv[2], encoding="utf-8"))["items"]

def norm_label_blob(val: str) -> str:
    lines = []
    for line in (val or "").splitlines():
        line = line.strip()
        if not line:
            continue
        if "\t" in line:
            lab, rest = line.split("\t", 1)
            if lab.startswith("application.com.logi.pluginservice."):
                lab = "application.com.logi.pluginservice.*"
            if rest.startswith("(submitted by runningboardd"):
                rest = "(submitted by runningboardd)"
            line = lab + "\t" + rest
        elif line.startswith("application.com.logi.pluginservice."):
            line = "application.com.logi.pluginservice.*"
        lines.append(line)
    return "\n".join(sorted(set(lines)))

for key in ("launchd.gui.labels", "launchd.sys.labels", "launchd.gui.jobs", "launchd.sys.jobs"):
    for side in (pre, post):
        if key in side:
            side[key] = dict(side[key])
            side[key]["value"] = norm_label_blob(side[key].get("value", ""))

keys = sorted(set(pre) | set(post))
fail = passn = 0
print(f"{__import__('datetime').datetime.now().astimezone().isoformat(timespec='milliseconds')} [SECT] ==== STATE DIFF (pre vs post) ====")
for k in keys:
    a = pre.get(k, {}).get("value", "<missing>")
    b = post.get(k, {}).get("value", "<missing>")
    info = (pre.get(k, {}) or {}).get("info") or (post.get(k, {}) or {}).get("info")
    if a == b:
        if not info: passn += 1
        tag = "INFO-SAME" if info else "PASS"
        print(f"... [DIFF] {tag} {k}")
        continue
    if info:
        print(f"... [DIFF] INFO-CHANGED {k}")
    else:
        fail += 1
        print(f"... [DIFF] FAIL {k}")
    print(f"... [DIFF]     pre : {a.replace(chr(10),' | ')}")
    print(f"... [DIFF]     post: {b.replace(chr(10),' | ')}")
verdict = "PASS" if fail == 0 else "FAIL"
print(f"... [DIFF] DIFF RESULT: {verdict} ({passn} items equal, {fail} differ; INFO items not counted)")
sys.exit(0 if fail == 0 else 1)
PY
}

# -------- Options+ stop / restore --------
# CHOICE (documented):
# 1) NEVER launchctl disable/enable — preserves print-disabled overrides.
# 2) Plist-backed jobs (com.logi.cp-dev-mgr, com.logi.optionsplus.updater): bootout to stop,
#    bootstrap + kickstart to restore.
# 3) LogiPluginService (application.com.logi.pluginservice.<N>): RunningBoard app job;
#    launchctl path is "(submitted by runningboardd.N)". NOT plist-backed — bootout cannot be
#    undone with bootstrap. STOP by quitting/killing allowlisted processes only; RESTORE by
#    `open -g -j` the .app in the console user's GUI session if it was running pre-test.
#    Whether cp-dev-mgr relaunches it after bootstrap is UNKNOWN — restore is idempotent and
#    only opens when LogiPluginService is absent.

discover_logi_jobs() {
  local uid="$HT_TARGET_UID"
  local tmp gui_file sys_file
  tmp="$(mktemp -d /tmp/ht-discover.XXXXXX)"
  gui_file="$tmp/gui.txt"; sys_file="$tmp/sys.txt"
  list_logi_labels "gui/$uid" >"$gui_file" 2>/dev/null || true
  list_logi_labels "system" >"$sys_file" 2>/dev/null || true
  for pl in /Library/LaunchAgents/com.logi.*.plist /Library/LaunchAgents/com.logitech.*.plist \
            /Library/LaunchDaemons/com.logi.*.plist /Library/LaunchDaemons/com.logitech.*.plist; do
    [[ -f "$pl" ]] || continue
    /usr/libexec/PlistBuddy -c 'Print :Label' "$pl" 2>/dev/null || true
  done | while IFS= read -r L; do
    [[ -z "$L" ]] && continue
    case "$L" in
      com.logi.*|com.logitech.*|application.com.logi.pluginservice.*)
        if [[ "$L" == com.logi.optionsplus.updater ]]; then
          echo "$L" >>"$sys_file"
        else
          echo "$L" >>"$gui_file"
        fi
        ;;
    esac
  done
  sort -u "$gui_file" -o "$gui_file"
  sort -u "$sys_file" -o "$sys_file"
  if [[ ! -s "$gui_file" && ! -s "$sys_file" ]]; then
    printf '%s\n' "${HT_EXPECTED_GUI_LABELS[@]}" >"$gui_file"
    printf '%s\n' "${HT_EXPECTED_SYS_LABELS[@]}" >"$sys_file"
    write_r WARN "No live labels found; using expected set from Mac Mini verification"
  fi
  : >"$tmp/gui-jobs.tsv"; : >"$tmp/sys-jobs.tsv"
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "$L" ]] && continue
    P="$(label_path "gui/$uid/$L" || true)"
    if [[ -z "$P" && "$L" == "com.logi.cp-dev-mgr" && -f "$HT_PLIST_CP_DEV_MGR" ]]; then
      P="$HT_PLIST_CP_DEV_MGR"
    fi
    printf '%s\t%s\n' "$L" "$P" >>"$tmp/gui-jobs.tsv"
  done <"$gui_file"
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "$L" ]] && continue
    P="$(label_path "system/$L" || true)"
    if [[ -z "$P" && "$L" == "com.logi.optionsplus.updater" && -f "$HT_PLIST_UPDATER" ]]; then
      P="$HT_PLIST_UPDATER"
    fi
    printf '%s\t%s\n' "$L" "$P" >>"$tmp/sys-jobs.tsv"
  done <"$sys_file"
  export HT_GUI_LABELS_JSON HT_SYS_LABELS_JSON HT_GUI_JOBS_JSON HT_SYS_JOBS_JSON HT_DISABLED_BEFORE_JSON HT_STOP_TARGETS_JSON HT_PLUGIN_WAS_RUNNING
  HT_GUI_LABELS_JSON="$(python3 -c 'import json,sys; print(json.dumps([l.strip() for l in open(sys.argv[1]) if l.strip()]))' "$gui_file")"
  HT_SYS_LABELS_JSON="$(python3 -c 'import json,sys; print(json.dumps([l.strip() for l in open(sys.argv[1]) if l.strip()]))' "$sys_file")"
  HT_GUI_JOBS_JSON="$(python3 -c 'import json,sys; d={}
for line in open(sys.argv[1]):
  line=line.rstrip("\n")
  if not line: continue
  a,b=line.split("\t",1) if "\t" in line else (line,"")
  d[a]=b
print(json.dumps(d))' "$tmp/gui-jobs.tsv")"
  HT_SYS_JOBS_JSON="$(python3 -c 'import json,sys; d={}
for line in open(sys.argv[1]):
  line=line.rstrip("\n")
  if not line: continue
  a,b=line.split("\t",1) if "\t" in line else (line,"")
  d[a]=b
print(json.dumps(d))' "$tmp/sys-jobs.tsv")"
  HT_DISABLED_BEFORE_JSON="$(
    {
      print_disabled_map "gui/$uid" || true
      print_disabled_map "system" || true
    } | python3 -c 'import sys,json; d={}
for line in sys.stdin:
  line=line.strip()
  if not line: continue
  parts=line.split("\t",1)
  d[parts[0]] = parts[1] if len(parts)>1 else "?"
print(json.dumps(d))'
  )"
  HT_STOP_TARGETS_JSON="$(
    {
      cat "$gui_file"
      cat "$sys_file"
    } | while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      if label_is_stop_target "$L"; then echo "$L"; fi
    done | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
  )"
  # Record whether LogiPluginService was running (for restore). Snapshot also records this.
  if logi_plugin_service_running; then HT_PLUGIN_WAS_RUNNING=1; else HT_PLUGIN_WAS_RUNNING=0; fi
  export HT_PLUGIN_WAS_RUNNING
  rm -rf "$tmp"
}

stop_options_plus() {
  section "STOP Options+ (bootout plist jobs; kill LogiPluginService processes — no bootout of application.*)"
  local uid="$HT_TARGET_UID" L
  write_r INFO "Policy: bootout only plist-backed stop-targets. LogiPluginService = process kill only (RunningBoard)."
  write_r INFO "NOT calling launchctl disable/enable. NOT bootout'ing application.com.logi.pluginservice.*"
  # Record pre-stop plugin state (also set in discover; refresh here).
  if logi_plugin_service_running; then HT_PLUGIN_WAS_RUNNING=1; else HT_PLUGIN_WAS_RUNNING=0; fi
  export HT_PLUGIN_WAS_RUNNING
  write_r INFO "LogiPluginService was_running_pre_stop=$HT_PLUGIN_WAS_RUNNING"
  # Quit Options+ UI
  if [[ "$(id -u)" -eq 0 ]]; then
    launchctl asuser "$uid" /usr/bin/osascript -e 'tell application id "com.logi.optionsplus" to quit' 2>/dev/null || true
  else
    /usr/bin/osascript -e 'tell application id "com.logi.optionsplus" to quit' 2>/dev/null || true
  fi
  sleep 1
  local -a stopped=()
  for L in $(python3 -c 'import json,os; print("\n".join(json.loads(os.environ.get("HT_GUI_LABELS_JSON","[]"))))'); do
    [[ -z "$L" ]] && continue
    if label_is_plugin_app_job "$L"; then
      write_r INFO "skip bootout (RunningBoard app job — kill processes instead): gui/$uid/$L"
      continue
    fi
    label_is_stop_target "$L" || { write_r INFO "skip (never-touch or non-target): gui/$uid/$L"; continue; }
    write_r INFO "bootout gui/$uid/$L"
    launchctl bootout "gui/$uid/$L" 2>/dev/null || true
    stopped+=("gui/$uid/$L")
  done
  for L in $(python3 -c 'import json,os; print("\n".join(json.loads(os.environ.get("HT_SYS_LABELS_JSON","[]"))))'); do
    [[ -z "$L" ]] && continue
    label_is_stop_target "$L" || { write_r INFO "skip (never-touch or non-target): system/$L"; continue; }
    write_r INFO "bootout system/$L"
    if [[ "$(id -u)" -eq 0 ]]; then
      launchctl bootout "system/$L" 2>/dev/null || true
    else
      write_r WARN "not root — cannot bootout system/$L; will rely on process kill (may respawn)"
    fi
    stopped+=("system/$L")
  done
  export HT_ACT_DISABLED_JSON
  if [[ ${#stopped[@]} -eq 0 ]]; then
    HT_ACT_DISABLED_JSON='[]'
  else
    HT_ACT_DISABLED_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${stopped[@]}")"
  fi
  # Kills allowlisted Options+ procs including LogiPluginService{,Native,Ext}.
  kill_logi_procs "initial"
  save_state
}

kill_logi_procs() {
  local why="$1" line pid
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    pid="$(printf '%s\n' "$line" | awk -F '\t' '{ print $1 }')"
    safe_kill_pid "$pid" "$why" || true
  done < <(list_optionsplus_procs)
}

watch_respawn() {
  local sec="$1" end n=0
  end=$(( $(date +%s) + sec ))
  while [[ $(date +%s) -lt $end ]]; do
    if list_optionsplus_procs | grep -q .; then
      kill_logi_procs "respawn"
      n=$((n+1))
    fi
    sleep 2
  done
  write_r INFO "Respawn check (${sec}s): $n rounds with Options+ allowlisted processes"
}

restore_options_plus() {
  section "RESTORE Options+ (bootstrap plist jobs; open LogiPluginService.app if needed)"
  local uid="$HT_TARGET_UID" L P
  write_r INFO "Policy: bootstrap + kickstart for bootout targets; ensure_logi_plugin_service for RunningBoard app."
  for target in $(python3 -c 'import json,os; print("\n".join(json.loads(os.environ.get("HT_ACT_DISABLED_JSON","[]"))))'); do
    [[ -z "$target" ]] && continue
    case "$target" in
      gui/*)
        L="$(printf '%s\n' "$target" | awk -F/ '{ print $3 }')"
        if label_is_plugin_app_job "$L"; then
          write_r INFO "skip bootstrap of RunningBoard label $L (restored via open .app)"
          continue
        fi
        P="$(python3 -c 'import json,os,sys; print(json.loads(os.environ.get("HT_GUI_JOBS_JSON","{}")).get(sys.argv[1],""))' "$L")"
        if [[ -z "$P" || ! -f "$P" ]]; then
          if [[ "$L" == "com.logi.cp-dev-mgr" && -f "$HT_PLIST_CP_DEV_MGR" ]]; then P="$HT_PLIST_CP_DEV_MGR"; fi
        fi
        if [[ -n "$P" && -f "$P" ]]; then
          write_r INFO "bootstrap gui/$uid <- $P (label $L)"
          launchctl bootstrap "gui/$uid" "$P" 2>/dev/null || true
        else
          write_r WARN "no plist for $L — kickstart only"
        fi
        launchctl kickstart "gui/$uid/$L" 2>/dev/null || true
        ;;
      system/*)
        L="${target#system/}"
        P="$(python3 -c 'import json,os,sys; print(json.loads(os.environ.get("HT_SYS_JOBS_JSON","{}")).get(sys.argv[1],""))' "$L")"
        if [[ -z "$P" || ! -f "$P" ]]; then
          if [[ "$L" == "com.logi.optionsplus.updater" && -f "$HT_PLIST_UPDATER" ]]; then P="$HT_PLIST_UPDATER"; fi
        fi
        if [[ -n "$P" && -f "$P" ]]; then
          write_r INFO "bootstrap system <- $P (label $L)"
          if [[ "$(id -u)" -eq 0 ]]; then
            launchctl bootstrap system "$P" 2>/dev/null || true
          else
            write_r WARN "not root — cannot bootstrap system/$L"
          fi
        fi
        ;;
    esac
  done
  # Give cp-dev-mgr a moment; it is UNKNOWN whether the agent relaunches LogiPluginService.
  sleep 3
  ensure_logi_plugin_service || true
  # Open Options+ UI
  if [[ "$(id -u)" -eq 0 ]]; then
    launchctl asuser "$uid" /usr/bin/open -b com.logi.optionsplus 2>/dev/null || true
  else
    /usr/bin/open -b com.logi.optionsplus 2>/dev/null || true
  fi
  sleep 2
  write_r INFO "Options+ allowlisted processes now:"
  list_optionsplus_procs | while IFS= read -r line; do write_r INFO "  $line"; done
  if [[ "${HT_PLUGIN_WAS_RUNNING:-0}" == "1" ]]; then
    if logi_plugin_service_running; then
      write_r INFO "VERIFY LogiPluginService: running (ok)"
    else
      write_r ERROR "VERIFY LogiPluginService: NOT running (was running pre-test)"
    fi
  fi
}

# Pretty-print discovered labels / procs for preflight (SSH-safe).
preflight_print_discovery() {
  local uid="${1:-$(id -u)}"
  local L P
  echo "  --- launchd labels (gui/$uid) ---"
  while IFS= read -r L; do
    [[ -z "$L" ]] && continue
    P="$(label_path "gui/$uid/$L" || true)"
    printf '  LABEL gui/%s/%s\n' "$uid" "$L"
    printf '    path: %s\n' "${P:-<unknown>}"
    if label_is_never_touch "$L"; then echo "    action: NEVER-TOUCH"
    elif label_is_plugin_app_job "$L"; then echo "    action: STOP(kill processes only; RunningBoard — no bootout)"
    elif label_is_stop_target "$L"; then echo "    action: STOP(bootout)"
    else echo "    action: observe-only"
    fi
  done < <(list_logi_labels "gui/$uid")
  echo "  --- launchd labels (system) ---"
  while IFS= read -r L; do
    [[ -z "$L" ]] && continue
    P="$(label_path "system/$L" || true)"
    printf '  LABEL system/%s\n' "$L"
    printf '    path: %s\n' "${P:-<unknown>}"
    if label_is_never_touch "$L"; then echo "    action: NEVER-TOUCH"
    elif label_is_stop_target "$L"; then echo "    action: STOP(bootout)"
    else echo "    action: observe-only"
    fi
  done < <(list_logi_labels "system")
  echo "  --- print-disabled (gui/$uid) ---"
  print_disabled_map "gui/$uid" | while IFS= read -r line; do echo "  OVERRIDE $line"; done
  echo "  --- print-disabled (system) ---"
  print_disabled_map "system" | while IFS= read -r line; do echo "  OVERRIDE $line"; done
  echo "  --- Options+ processes (allowlist; paths may contain spaces) ---"
  list_optionsplus_procs | while IFS= read -r line; do
    echo "  PROC $line"
  done
  if logi_plugin_service_running; then
    echo "  LogiPluginService: RUNNING (restore will relaunch via open -g -j if stopped)"
  else
    echo "  LogiPluginService: not running"
  fi
  echo "  --- expected labels (Mac Mini verified) ---"
  echo "  expected gui: ${HT_EXPECTED_GUI_LABELS[*]}"
  echo "  expected sys: ${HT_EXPECTED_SYS_LABELS[*]}"
  echo "  never-touch:  ${HT_NEVER_TOUCH_LABELS[*]}"
  echo "  note: com.logi.optionsplus is a LaunchAgents *filename*, not a launchd label"
  echo "  note: application.com.logi.pluginservice.* is RunningBoard — stop=kill, restore=open .app"
}


# -------- OpenLogi stop / cleanup --------
stop_openlogi() {
  section "STOP OpenLogi"
  local uid="$HT_TARGET_UID"
  # Prefer a clean quit so SMAppService / launch_at_login can clear itself.
  launchctl asuser "$uid" /usr/bin/osascript -e 'tell application id "org.openlogi.openlogi" to quit' 2>/dev/null || true
  sleep 1
  launchctl bootout "gui/$uid/$HT_AGENT_SERVICE" 2>/dev/null || true
  pkill -x openlogi-agent 2>/dev/null || true
  pkill -x openlogi-desktop 2>/dev/null || true
  pkill -x openlogi-overlay 2>/dev/null || true
  pkill -x openlogi 2>/dev/null || true
  pkill -f 'OpenLogi\.app' 2>/dev/null || true
  sleep 1
  if pgrep -lf -i openlogi >/dev/null 2>&1; then
    write_r ERROR "OpenLogi processes still alive: $(pgrep -lf -i openlogi | tr '\n' ' ')"
  else
    write_r INFO "No OpenLogi processes remain (hooks released)."
  fi
}

remove_test_files() {
  section "CLEANUP files"
  local pre="$HT_WORK/snapshot-pre.json"
  # Remove app only if we installed it.
  if [[ "${HT_APP_EXISTED:-0}" != "1" && -d "$HT_APP" ]]; then
    write_r INFO "Removing test-installed $HT_APP"
    rm -rf "$HT_APP"
  fi
  # Config/state/data: restore from backup if pre-existing, else delete if absent before.
  python3 - "$pre" <<'PY'
import json, os, shutil, subprocess, sys
pre_path = sys.argv[1]
pre = {}
if os.path.exists(pre_path):
    pre = json.load(open(pre_path, encoding="utf-8")).get("items", {})
backups = json.loads(os.environ.get("HT_ACT_BACKUPS_JSON", "[]"))
backup_map = {}
for b in backups:
    if "|" in b:
        a,b2 = b.split("|",1); backup_map[a]=b2
dirs = [os.environ.get("HT_CONFIG_DIR",""), os.environ.get("HT_STATE_DIR",""), os.environ.get("HT_DATA_DIR","")]
extras = json.loads(os.environ.get("HT_EXTRA_DIRS_JSON","[]"))
for d in dirs + extras:
    if not d: continue
    key = f"dir.openlogi:{d}"
    pre_val = (pre.get(key) or {}).get("value") or (pre.get(f"path.exists:{d}") or {}).get("value")
    if d in backup_map:
        if os.path.exists(d): shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(backup_map[d], d)
        print(f"restored {d}")
    elif pre_val in ("absent", "False", None) or (pre_val == "False"):
        if os.path.exists(d):
            if d.endswith(".plist") and os.path.isfile(d):
                os.remove(d)
            else:
                shutil.rmtree(d, ignore_errors=True)
            print(f"removed {d}")
# empty parents deepest first
parents = sorted(json.loads(os.environ.get("HT_PARENT_DIRS_JSON","[]")), key=len, reverse=True)
for d in parents:
    pre_val = (pre.get(f"path.exists:{d}") or {}).get("value")
    if pre_val == "False" and os.path.isdir(d) and not os.listdir(d):
        os.rmdir(d); print(f"removed empty parent {d}")
PY
}

reset_tcc_for_openlogi() {
  section "TCC reset for OpenLogi"
  # Only OpenLogi's bundle IDs. Accessibility / ListenEvent (Input Monitoring).
  # Local Network cannot be reset via tccutil (guide 4.4).
  for svc in Accessibility ListenEvent; do
    for bid in "$HT_APP_BUNDLE_ID" "$HT_AGENT_BUNDLE_ID" "$HT_OVERLAY_BUNDLE_ID"; do
      if tccutil reset "$svc" "$bid" 2>/dev/null; then
        write_r INFO "tccutil reset $svc $bid"
      else
        write_r WARN "tccutil reset $svc $bid failed or no grant present"
      fi
    done
  done
}

# -------- watchdog registration --------
install_watchdog() {
  local deadline_ms="$1" suite_dir="$2"
  local fire_epoch=$(( deadline_ms / 1000 ))
  local watch_script="$suite_dir/watchdog.sh"
  # Detached process (survives script death even without launchd).
  nohup /bin/bash -c "
    while [[ \$(date +%s) -lt $fire_epoch ]]; do
      if [[ -f '$HT_WORK/COMPLETED' ]]; then exit 0; fi
      sleep 5
    done
    exec /bin/bash '$watch_script'
  " >/dev/null 2>&1 &
  disown || true
  echo $! >"$HT_WORK/watchdog.pid"
  write_r INFO "Detached watchdog pid $(cat "$HT_WORK/watchdog.pid") (fires at epoch $fire_epoch)"

  # One-shot LaunchDaemon as a second failsafe (survives reboot / logout of the tester).
  mkdir -p /Library/LaunchDaemons
  cat >"$HT_WATCHDOG_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$HT_WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$watch_script</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Year</key><integer>$(date -r "$fire_epoch" +%Y)</integer>
    <key>Month</key><integer>$(date -r "$fire_epoch" +%-m)</integer>
    <key>Day</key><integer>$(date -r "$fire_epoch" +%-d)</integer>
    <key>Hour</key><integer>$(date -r "$fire_epoch" +%-H)</integer>
    <key>Minute</key><integer>$(date -r "$fire_epoch" +%-M)</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>LaunchOnlyOnce</key><true/>
  <key>StandardOutPath</key><string>$HT_WORK/watchdog.out</string>
  <key>StandardErrorPath</key><string>$HT_WORK/watchdog.err</string>
</dict>
</plist>
PLIST
  launchctl bootout system "$HT_WATCHDOG_PLIST" 2>/dev/null || true
  launchctl bootstrap system "$HT_WATCHDOG_PLIST"
  write_r INFO "LaunchDaemon $HT_WATCHDOG_LABEL installed (StartCalendarInterval at $(fmt_ms "$deadline_ms"))"
}

uninstall_watchdog() {
  if [[ -f "$HT_WORK/watchdog.pid" ]]; then
    local pid; pid="$(cat "$HT_WORK/watchdog.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$HT_WORK/watchdog.pid"
  fi
  if [[ -f "$HT_WATCHDOG_PLIST" ]]; then
    launchctl bootout system "$HT_WATCHDOG_PLIST" 2>/dev/null || true
    rm -f "$HT_WATCHDOG_PLIST"
    write_r INFO "Watchdog LaunchDaemon removed"
  fi
}

# -------- full restore --------
full_restore() {
  local reason="$1"
  (
    # flock-like mutex via mkdir
    local waited=0
    while ! mkdir "$HT_MUTEX" 2>/dev/null; do
      sleep 1; waited=$((waited+1))
      if (( waited > 300 )); then write_r ERROR "Could not acquire restore mutex"; break; fi
    done
    trap 'rmdir "$HT_MUTEX" 2>/dev/null || true' EXIT
    section "FULL RESTORE ($reason)"
    stop_openlogi
    restore_options_plus
    remove_test_files
    reset_tcc_for_openlogi
    # Firewall: we do not add permanent rules (macOS Application Firewall is per-app prompts).
    # Nothing to remove beyond what we left alone.
    export HT_COMPLETED=1
    touch "$HT_WORK/COMPLETED" 2>/dev/null || true
    save_state
    if [[ -f "$HT_WORK/snapshot-pre.json" ]]; then
      sleep 5
      # Re-discover current labels for post snapshot
      discover_logi_jobs || true
      take_snapshot "$HT_WORK/snapshot-post.json" || true
      # Diff into the result log
      compare_snapshots "$HT_WORK/snapshot-pre.json" "$HT_WORK/snapshot-post.json" 2>&1 | while IFS= read -r line; do
        # strip leading placeholder
        line="${line#... }"
        write_r DIFF "${line#\[DIFF\] }"
      done || write_r ERROR "Post-snapshot DIFF reported differences (see FAIL lines)"
    fi
    uninstall_watchdog
    # Remove work dirs except the result log.
    rm -rf "$HT_WORK" "$HT_USER_WORK" 2>/dev/null || true
    write_r INFO "Only remaining test file: $HT_RESULT"
  )
}

# -------- CLI / log parsing --------
cli() {
  local uid="$HT_TARGET_UID"
  launchctl asuser "$uid" env OPENLOGI_LOG="$HT_LOG_FILTER" "$HT_CLI" "$@"
}
parse_agent_events() {
  local since_ms="$1"
  python3 - "$HT_STATE_DIR" "$since_ms" <<'PY'
import os, re, sys, glob, datetime
state_dir, since = sys.argv[1], int(sys.argv[2])
patterns = [
  "Flow runtime armed","Flow handoff completed","Flow incoming handoff finished",
  "Flow arrival acknowledgment timed out","Flow host switch failed after receiver acceptance",
  "Flow edge has no online configured devices to hand off",
  "Flow edge ignored because the peer still reports one target device as held",
  "Flow edge ignored while peer is disconnected","Flow handoff rejected",
  "Flow handoff request timed out","Flow handoff request failed",
  "Flow handoff cancelled by peer","Flow peer returned an invalid handoff acceptance",
  "Flow device arrived but cursor positioning failed",
  "Flow released modifier keys the departed keyboard left down",
  "invalid Flow configuration","Flow runtime failed to start",
  "Flow mDNS advertisement unavailable","Flow mDNS browsing unavailable",
  "BT-direct / wired device recognised","agent panicked",
]
outcome = {"0":"Unspecified","1":"Arrived","2":"Partial","3":"Timeout","4":"Cancelled"}
rx = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s+(\w+)\s+(.*)$")
field_rx = re.compile(r'(\w+)=("(?:\\.|[^"])*"|\S+)')
events = []
for path in sorted(glob.glob(os.path.join(state_dir, "agent*.log"))):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = rx.match(line.rstrip("\n"))
                if not m: continue
                ts, lvl, rest = m.group(1), m.group(2), m.group(3)
                ev = next((p for p in patterns if p in rest), None)
                if not ev: continue
                ms = int(datetime.datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp()*1000)
                if ms < since: continue
                fields = {a: b.strip('"') for a,b in field_rx.findall(rest)}
                events.append((ms, lvl, ev, fields, line.rstrip()))
    except OSError:
        pass
events.sort()
pending = None
for ms, lvl, ev, fields, line in events:
    local = datetime.datetime.fromtimestamp(ms/1000).astimezone().isoformat(timespec="milliseconds")
    fstr = " ".join(f"{k}={v}" for k,v in sorted(fields.items()))
    if "outcome" in fields:
        fstr += f" ({outcome.get(str(fields['outcome']), '?')})"
    print(f"EVENT\t{local}\t{lvl}\t{ev}\t{fstr}")
    if "edge" in ev.lower():
        pending = ms
    if ev == "Flow handoff completed" and pending is not None:
        print(f"TIMING\tCROSSING DURATION (sender edge->handoff completed): {ms-pending} ms start={pending} end={ms} outcome={outcome.get(str(fields.get('outcome')),'?')}")
        pending = None
    if ev == "Flow incoming handoff finished":
        print(f"TIMING\tRECEIVER arrival: outcome={outcome.get(str(fields.get('outcome')),'?')} arrived={fields.get('arrived')} requested={fields.get('requested')} at={ms}")
PY
}

# -------- Flow layout in ~/.config/openlogi/config.toml --------
# Schema: crates/openlogi-core/src/config/flow.rs — [[flow.layout]] { edge, peer }
# peer must match an existing [[flow.peers]].name (set after SAS pairing). Reload via `openlogi flow enable`.
set_openlogi_flow_layout() {
  local config_path="$1" edge="$2" peer="$3" port="${4:-42424}"
  mkdir -p "$(dirname "$config_path")"
  local layout_block
  layout_block=$(printf '[[flow.layout]]\nedge = "%s"\npeer = "%s"\n' "$edge" "$peer")
  if [[ ! -f "$config_path" ]]; then
    cat >"$config_path" <<CFG
schema_version = 8

[flow]
enabled = true
port = ${port}

${layout_block}
CFG
    write_r INFO "Wrote new config.toml with [[flow.layout]] edge=$edge peer=$peer"
    return 0
  fi
  python3 - "$config_path" "$edge" "$peer" "$port" <<'PY'
import pathlib, re, sys
path, edge, peer, port = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
text = path.read_text(encoding="utf-8")
text = re.sub(r"(?m)^\[\[flow\.layout\]\][^\n]*\n(?:^(?!\[).*\n)*", "", text)
if not re.search(r"(?m)^\[flow\]\s*$", text):
    text = text.rstrip() + f"\n\n[flow]\nenabled = true\nport = {port}\n"
else:
    if not re.search(r"(?m)^enabled\s*=", text):
        text = re.sub(r"(?m)^\[flow\]\s*$", "[flow]\nenabled = true", text, count=1)
    if not re.search(r"(?m)^port\s*=", text):
        text = re.sub(r"(?m)^\[flow\]\s*$", f"[flow]\nport = {port}", text, count=1)
text = text.rstrip() + f'\n\n[[flow.layout]]\nedge = "{edge}"\npeer = "{peer}"\n'
path.write_text(text, encoding="utf-8")
print(f"updated {path}")
PY
  write_r INFO "Updated config.toml [[flow.layout]] edge=$edge peer=$peer at $config_path"
}

resolve_flow_peer_name() {
  local preferred="${1:-}"
  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return 0
  fi
  local out
  out="$(cli flow status 2>/dev/null || true)"
  printf '%s' "$out" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
if not raw: sys.exit(1)
try: d=json.loads(raw)
except Exception: sys.exit(1)
peers=d.get("peers") or []
if peers and peers[0].get("name"):
  print(peers[0]["name"]); sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

apply_flow_layout_and_reload() {
  local edge="$1" preferred="$2" port="${3:-42424}"
  local peer
  peer="$(resolve_flow_peer_name "$preferred" || true)"
  if [[ -z "$peer" ]]; then
    write_r WARN "No Flow peer name available yet (pass --peer-name or finish pairing). Layout NOT written. GM default for this host: edge=$edge -> peer=<Alienware>"
    return 1
  fi
  set_openlogi_flow_layout "$HT_CONFIG_DIR/config.toml" "$edge" "$peer" "$port"
  write_r INFO "flow enable (reload after layout): $(cli flow enable 2>&1 || true)"
  return 0
}
