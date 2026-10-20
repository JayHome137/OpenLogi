#!/usr/bin/env bash
# OpenLogi Flow hardware test - shared macOS helpers (sourced; never run directly).
# Target: Jay's Mac Mini (192.168.1.8, macOS 27 arm64, user jayboy137). Run with /bin/bash (3.2) via sudo.
# bash 3.2 rules used here: no associative arrays, no mapfile, no ${v,,}, integer `read -t` only,
# never expand a possibly-empty array under `set -u`.
# EVERY mutation is limited to items listed in allowlist.json (exact labels / exact paths). See ALLOWLIST.md.
# shellcheck disable=SC2034  # constants below are used by the scripts that source this file
set -euo pipefail

HT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HT_WORK="${HT_WORK:-/Library/Application Support/OpenLogi-hwtest}"
HT_APP="/Applications/OpenLogi.app"
HT_CLI="$HT_APP/Contents/MacOS/openlogi"
HT_AGENT_BUNDLE="$HT_APP/Contents/Library/LoginItems/OpenLogi Agent.app"
HT_AGENT_BIN="$HT_AGENT_BUNDLE/Contents/MacOS/openlogi-agent"
HT_APP_BUNDLE_ID="org.openlogi.openlogi"
HT_AGENT_SERVICE="org.openlogi.agent.service"
HT_FIREWALL="/usr/libexec/ApplicationFirewall/socketfilterfw"
HT_REPO="JayHome137/OpenLogi"
HT_RUN_ID="39235760610"
HT_ARTIFACT_ARM64="OpenLogi-macos-dmg-arm64"
HT_ARTIFACT_X86="OpenLogi-macos-dmg-x86_64"
HT_PORT="${HT_PORT:-42424}"
HT_LOG_FILTER='info,openlogi_agent_core=debug,openlogi_flow=debug,openlogi_device=debug,openlogi_hid=debug'
HT_MUTEX="/tmp/OpenLogiHwTestRestore.lock"
HT_WATCHDOG_PLIST="/Library/LaunchDaemons/com.openlogi.hwtest.watchdog.plist"
HT_WATCHDOG_LABEL="com.openlogi.hwtest.watchdog"
HT_LEASE_MIN="${HT_LEASE_MIN:-20}"
HT_HARDCAP_MIN="${HT_HARDCAP_MIN:-120}"
# Markers identifying this suite's own processes (excluded from every process diff / "still alive" check).
HT_OWN_MARKERS="OpenLogi-hwtest|run-openlogi-flow-test|ol-hwtest|com.openlogi.hwtest"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
fmt_ms() {
  python3 - "${1:-0}" <<'PY'
import sys, datetime
ms = int(sys.argv[1])
print("-" if ms <= 0 else datetime.datetime.fromtimestamp(ms/1000.0).astimezone().strftime("%Y-%m-%d %H:%M:%S %z"))
PY
}
is_root() { [[ "$(id -u)" -eq 0 ]]; }
console_user() { /usr/bin/stat -f%Su /dev/console 2>/dev/null || true; }

write_r() {
  local lvl="$1"; shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$lvl] $*"
  printf '%s\n' "$line" >&2
  if [[ -n "${HT_RESULT:-}" ]]; then
    printf '%s\n' "$line" >>"$HT_RESULT" 2>/dev/null || true
  fi
}
section() { write_r SECT "==== $* ===="; }
# banner COLOR line...   (COLOR: red|green|yellow)
banner() {
  local col="$1"; shift
  local c='' r='' l
  if [[ -t 2 ]]; then
    r=$'\033[0m'
    case "$col" in red) c=$'\033[1;41;97m' ;; green) c=$'\033[1;42;30m' ;; *) c=$'\033[1;43;30m' ;; esac
  fi
  printf '\n%s%s%s\n' "$c" '========================================================================' "$r" >&2
  for l in "$@"; do printf '%s  %s  %s\n' "$c" "$l" "$r" >&2; [[ -n "${HT_RESULT:-}" ]] && printf '%s [BANNER] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$l" >>"$HT_RESULT" 2>/dev/null; done
  printf '%s%s%s\n\n' "$c" '========================================================================' "$r" >&2
}

# ------------------------------------------------------------------ allowlist (single source: allowlist.json)
al_locate() {
  local c
  for c in "${HT_ALLOWLIST:-}" "$HT_COMMON_DIR/allowlist.json" "$HT_COMMON_DIR/../allowlist.json"; do
    if [[ -n "$c" && -f "$c" ]]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}
# python_ok: on macOS /usr/bin/python3 is only a shim; WITHOUT Command Line Tools it pops an "install developer
# tools" dialog and fails. Check without executing it (xcode-select -p never prompts). UNVERIFIED on macOS 27.
python_ok() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  local p dev
  p="$(command -v python3 2>/dev/null)" || return 1
  [[ "$p" != /usr/bin/python3 ]] && return 0
  dev="$(/usr/bin/xcode-select -p 2>/dev/null)" || return 1
  [[ -n "$dev" && -x "$dev/usr/bin/python3" ]]
}
al_load() {
  local p
  if ! python_ok; then
    echo "FATAL: python3 not usable (macOS needs Command Line Tools: run  xcode-select --install  as the user, then retry). Nothing changed." >&2
    return 1
  fi
  if ! p="$(al_locate)"; then
    echo "FATAL: allowlist.json not found next to the scripts - refusing to change anything (fail closed)." >&2
    return 1
  fi
  if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "macos" in d' "$p" 2>/dev/null; then
    echo "FATAL: allowlist.json unreadable or has no macos section: $p" >&2
    return 1
  fi
  HT_ALLOWLIST="$p"; export HT_ALLOWLIST
}
# al_get KIND -> one item per line (TAB-separated fields). Tokens {uid} {home} {ConfigHome} {StateHome} {DataHome}
# are expanded from HT_TARGET_UID / HT_HOME / HT_CONFIG_HOME / HT_STATE_HOME / HT_DATA_HOME; an item whose token
# is empty is DROPPED (fail closed).
al_get() {
  python3 - "${HT_ALLOWLIST:?allowlist not loaded}" "$1" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["macos"]
kind = sys.argv[2]
tok = {"{uid}": os.environ.get("HT_TARGET_UID", ""), "{home}": os.environ.get("HT_HOME", ""),
       "{ConfigHome}": os.environ.get("HT_CONFIG_HOME", ""), "{StateHome}": os.environ.get("HT_STATE_HOME", ""),
       "{DataHome}": os.environ.get("HT_DATA_HOME", "")}
def ex(s):
    s = str(s)
    for k, v in tok.items():
        if k in s:
            if not v:
                return None
            s = s.replace(k, v)
    return s
out = []
if kind.startswith("launchd-"):
    role = kind.split("-", 1)[1]
    for j in d.get("launchdJobs", []):
        if role != "all" and j.get("role") != role:
            continue
        dom = ex(j["domain"])
        if dom is None:
            continue
        out.append("\t".join([dom, j["label"], j.get("plist", ""), ",".join(j.get("actions", []))]))
elif kind == "never-touch":
    out = list(d.get("neverTouchLabels", []))
elif kind == "op-procs":
    out = [p["name"] + "\t" + p["path"] for p in d.get("optionsPlusProcesses", [])]
elif kind == "ol-procs":
    out = [p["name"] + "\t" + p["path"] for p in d.get("openLogiProcesses", [])]
elif kind == "gui":
    g = d.get("optionsPlusGui", {})
    out = [g.get("bundlePath", "") + "\t" + g.get("bundleIdFallback", "") + "\t" + g.get("mainExecutable", "")]
elif kind == "rb-apps":
    out = [a["labelPrefix"] + "\t" + a["bundlePath"] for a in d.get("runningBoardApps", [])]
elif kind == "tcc-services":
    out = list(d.get("tccReset", {}).get("services", []))
elif kind == "tcc-bundles":
    out = list(d.get("tccReset", {}).get("bundleIds", []))
elif kind == "env-unset":
    out = list(d.get("launchdUserEnvUnsetIfAbsentBefore", []))
elif kind in ("paths-absent", "paths-empty", "paths-write"):
    key = {"paths-absent": "pathsRemoveIfAbsentBefore", "paths-empty": "pathsRemoveIfCreatedAndEmpty",
           "paths-write": "pathsWriteOnly"}[kind]
    out = [x for x in (ex(p) for p in d.get(key, [])) if x]
else:
    sys.stderr.write("al_get: unknown kind " + kind + "\n"); sys.exit(2)
for o in out:
    print(o)
PY
}
# al_has KIND EXACT_LINE  (exact, whole-line, case-sensitive)
al_has() { al_get "$1" | grep -Fxq -- "$2"; }
# launchd target allowed for ACTION?  al_launchd_allowed ACTION DOMAIN LABEL
al_launchd_allowed() {
  local action="$1" dom="$2" label="$3" d l p a
  while IFS=$'\t' read -r d l p a; do
    if [[ "$d" == "$dom" && "$l" == "$label" ]]; then
      case ",$a," in *",$action,"*) return 0 ;; esac
    fi
  done < <(al_get launchd-all)
  return 1
}
al_launchd_plist() {
  local dom="$1" label="$2" d l p a
  while IFS=$'\t' read -r d l p a; do
    if [[ "$d" == "$dom" && "$l" == "$label" ]]; then printf '%s\n' "$p"; return 0; fi
  done < <(al_get launchd-all)
  return 1
}
al_path_removable() {
  [[ -n "${1:-}" ]] || return 1
  al_has paths-absent "$1" || al_has paths-empty "$1"
}

# ------------------------------------------------------------------ context / state
state_path() { printf '%s\n' "$HT_WORK/state.json"; }
lease_path() { printf '%s\n' "$HT_WORK/lease.json"; }
save_state() {
  mkdir -p "$HT_WORK"
  python3 - "$(state_path)" <<'PY'
import json, os, sys
e = os.environ.get
def jl(k, d): 
    try: return json.loads(e(k, d) or d)
    except Exception: return json.loads(d)
state = {
  "version": 2,
  "targetUser": e("HT_TARGET_USER", ""), "targetUid": e("HT_TARGET_UID", ""), "home": e("HT_HOME", ""),
  "resultLog": e("HT_RESULT", ""),
  "configHome": e("HT_CONFIG_HOME", ""), "stateHome": e("HT_STATE_HOME", ""), "dataHome": e("HT_DATA_HOME", ""),
  "configDir": e("HT_CONFIG_DIR", ""), "stateDir": e("HT_STATE_DIR", ""), "dataDir": e("HT_DATA_DIR", ""),
  "appExisted": e("HT_APP_EXISTED", "0") == "1",
  "mainPid": int(e("HT_MAIN_PID", "0") or 0), "mainLstart": e("HT_MAIN_LSTART", ""),
  "startedMs": int(e("HT_STARTED_MS", "0") or 0), "hardCapMs": int(e("HT_HARDCAP_MS", "0") or 0),
  "completed": e("HT_COMPLETED", "0") == "1", "port": int(e("HT_PORT", "42424") or 42424),
  "pluginWasRunning": e("HT_PLUGIN_WAS_RUNNING", "0") == "1",
  "guiWasRunning": e("HT_GUI_WAS_RUNNING", "0") == "1",
  "actions": {"labelsDisabled": jl("HT_ACT_DISABLED_JSON", "[]"), "backups": jl("HT_ACT_BACKUPS_JSON", "[]")},
}
# pre-test running state is only written once it was really observed (unknown -> restore leaves GUI/plugin alone)
if e("HT_GUI_STATE_KNOWN", "0") != "1": state.pop("guiWasRunning")
if e("HT_PLUGIN_STATE_KNOWN", "0") != "1": state.pop("pluginWasRunning")
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2, ensure_ascii=False); f.write("\n")
os.replace(tmp, sys.argv[1])
PY
}
# Prints `export K=V` lines for a state file (run-1 and run-2 formats). Pure: testable offline.
state_env_lines() {
  python3 - "$1" <<'PY'
import json, os, sys, shlex
p = sys.argv[1]
if not os.path.exists(p):
    sys.exit(0)
s = json.load(open(p, encoding="utf-8"))
def q(v): return shlex.quote(str(v))
def parent(x): return os.path.dirname(x.rstrip("/")) if x else ""
act = s.get("actions") or {}
kv = {
  "HT_TARGET_USER": s.get("targetUser", ""), "HT_TARGET_UID": s.get("targetUid", ""), "HT_HOME": s.get("home", ""),
  "HT_RESULT": s.get("resultLog", ""),
  "HT_CONFIG_DIR": s.get("configDir", ""), "HT_STATE_DIR": s.get("stateDir", ""), "HT_DATA_DIR": s.get("dataDir", ""),
  "HT_CONFIG_HOME": s.get("configHome") or parent(s.get("configDir", "")),
  "HT_STATE_HOME": s.get("stateHome") or parent(s.get("stateDir", "")),
  "HT_DATA_HOME": s.get("dataHome") or parent(s.get("dataDir", "")),
  "HT_APP_EXISTED": "1" if s.get("appExisted") else "0",
  "HT_MAIN_PID": int(s.get("mainPid") or 0), "HT_MAIN_LSTART": s.get("mainLstart", ""),
  "HT_STARTED_MS": int(s.get("startedMs") or 0),
  # run-1 states only have deadlineMs: treat it as the hard cap (it already passed -> watchdog restores at once)
  "HT_HARDCAP_MS": int(s.get("hardCapMs") or s.get("deadlineMs") or 0),
  "HT_COMPLETED": "1" if s.get("completed") else "0", "HT_PORT": int(s.get("port") or 42424),
  "HT_PLUGIN_WAS_RUNNING": "1" if s.get("pluginWasRunning") else "0",
  "HT_GUI_WAS_RUNNING": "1" if s.get("guiWasRunning") else "0",
  "HT_GUI_STATE_KNOWN": "1" if "guiWasRunning" in s else "0",
  "HT_PLUGIN_STATE_KNOWN": "1" if "pluginWasRunning" in s else "0",
  "HT_ACT_DISABLED_JSON": json.dumps(act.get("labelsDisabled", [])),
  "HT_ACT_BACKUPS_JSON": json.dumps(act.get("backups", [])),
  "HT_STATE_VERSION": int(s.get("version") or 1),
}
for k, v in kv.items():
    print("export %s=%s" % (k, q(v)))
PY
}
load_state_env() { eval "$(state_env_lines "$(state_path)")"; }

init_context() {
  local user="${1:-}"
  [[ -n "$user" ]] || user="$(console_user)"
  if [[ -z "$user" || "$user" == "root" || "$user" == "loginwindow" ]]; then user="$(/usr/bin/id -un)"; fi
  local home uid
  home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$home" ]] || home="$(eval echo "~$user")"
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || /usr/bin/id -u)"
  export HT_TARGET_USER="$user" HT_TARGET_UID="$uid" HT_HOME="$home"
  export HT_RESULT="$home/OpenLogi-test-result.log"
  HT_USER_WORK="$home/Library/Application Support/OpenLogi-hwtest"
  local cfg st dt
  cfg="$(launchctl asuser "$uid" /usr/bin/printenv XDG_CONFIG_HOME 2>/dev/null || true)"
  st="$(launchctl asuser "$uid" /usr/bin/printenv XDG_STATE_HOME 2>/dev/null || true)"
  dt="$(launchctl asuser "$uid" /usr/bin/printenv XDG_DATA_HOME 2>/dev/null || true)"
  [[ -n "$cfg" && "$cfg" == /* ]] || cfg="$home/.config"
  [[ -n "$st" && "$st" == /* ]] || st="$home/.local/state"
  [[ -n "$dt" && "$dt" == /* ]] || dt="$home/.local/share"
  export HT_CONFIG_HOME="$cfg" HT_STATE_HOME="$st" HT_DATA_HOME="$dt"
  export HT_CONFIG_DIR="$cfg/openlogi" HT_STATE_DIR="$st/openlogi" HT_DATA_DIR="$dt/openlogi"
  export HT_APP_EXISTED=0
  [[ -d "$HT_APP" ]] && HT_APP_EXISTED=1
  export HT_MAIN_PID=$$ HT_COMPLETED=0
  HT_STARTED_MS="$(now_ms)"; export HT_STARTED_MS
  HT_MAIN_LSTART="$(proc_lstart $$)"; export HT_MAIN_LSTART
  export HT_ACT_DISABLED_JSON="${HT_ACT_DISABLED_JSON:-[]}" HT_ACT_BACKUPS_JSON="${HT_ACT_BACKUPS_JSON:-[]}"
}
proc_lstart() { /bin/ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//' || true; }
# run a command in the console user's GUI session as that user
as_user() {
  if is_root; then
    launchctl asuser "$HT_TARGET_UID" /usr/bin/sudo -u "$HT_TARGET_USER" "$@"
  else
    "$@"
  fi
}

# ------------------------------------------------------------------ lease / watchdog decision
# lease_decision NOW LEASE_UNTIL HARDCAP COMPLETED(0/1) MAIN_ALIVE(0/1) STATE_EXISTS(0/1)   -- pure, unit-tested
lease_decision() {
  local now="$1" until="$2" cap="$3" completed="$4" alive="$5" exists="$6"
  if [[ "$exists" != 1 ]]; then echo exit-nostate; return 0; fi
  if [[ "$completed" == 1 ]]; then echo exit-completed; return 0; fi
  if [[ "$cap" -gt 0 && "$now" -ge "$cap" ]]; then echo fire-hardcap; return 0; fi
  if [[ "$alive" != 1 ]]; then echo fire-main-dead; return 0; fi
  if [[ "$until" -le 0 || "$now" -ge "$until" ]]; then echo fire-lease-expired; return 0; fi
  echo wait
}
# next_lease_until NOW LEASE_MIN HARDCAP   -- pure
next_lease_until() {
  local l=$(( $1 + $2 * 60000 ))
  if [[ "$3" -gt 0 && "$l" -gt "$3" ]]; then l="$3"; fi
  echo "$l"
}
# read_lease -> "LEASE_UNTIL HARDCAP" (0 0 when missing/unreadable)
read_lease() {
  local p="${1:-$(lease_path)}"
  python3 - "$p" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(int(d.get("leaseUntilMs", 0)), int(d.get("hardCapMs", 0)))
except Exception:
    print(0, 0)
PY
}
# lease_renew PHASE [tocap]
lease_renew() {
  local phase="${1:-}" mode="${2:-}" now until
  [[ "${HT_HARDCAP_MS:-0}" -gt 0 ]] || return 0
  [[ -d "$HT_WORK" ]] || return 0
  now="$(now_ms)"
  if [[ "$mode" == tocap ]]; then until="$HT_HARDCAP_MS"; else until="$(next_lease_until "$now" "$HT_LEASE_MIN" "$HT_HARDCAP_MS")"; fi
  phase="$(printf '%s' "$phase" | tr -cd 'A-Za-z0-9._-')"
  printf '{"leaseUntilMs": %s, "hardCapMs": %s, "renewedMs": %s, "phase": "%s", "mainPid": %s}\n' \
    "$until" "$HT_HARDCAP_MS" "$now" "$phase" "${HT_MAIN_PID:-0}" >"$(lease_path).tmp"
  mv -f "$(lease_path).tmp" "$(lease_path)"
  HT_LEASE_UNTIL="$until"
}
lease_status() {
  [[ "${HT_HARDCAP_MS:-0}" -gt 0 ]] || { echo "lease: n/a (nothing changed yet)"; return 0; }
  local now l h cap
  now="$(now_ms)"
  l=$(( (${HT_LEASE_UNTIL:-0} - now) / 60000 )); [[ $l -lt 0 ]] && l=0
  h=$(( (HT_HARDCAP_MS - now) / 60000 )); [[ $h -lt 0 ]] && h=0
  cap="$(fmt_ms "$HT_HARDCAP_MS" | awk '{print $2}' | cut -c1-5)"
  echo "看门狗租约剩余 ${l} 分钟(脚本活着就每分钟自动续期) | 硬上限剩余 ${h} 分钟(到 ${cap} 无论如何自动恢复)"
}
main_alive() {
  local pid="${HT_MAIN_PID:-0}"
  [[ "$pid" -gt 0 ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -n "${HT_MAIN_LSTART:-}" ]]; then
    [[ "$(proc_lstart "$pid")" == "$HT_MAIN_LSTART" ]] || return 1
  fi
  return 0
}

# ------------------------------------------------------------------ processes (exact allowlisted paths only)
# ps dump: "pid ppid command" per line. Offline harness: HT_PS_FILE (also accepts old "pid command" lines).
ps_dump() {
  if [[ -n "${HT_PS_FILE:-}" ]]; then cat "$HT_PS_FILE"; else /bin/ps -axww -o pid= -o ppid= -o command= 2>/dev/null || true; fi
}
# Own processes: main script, its whole descendant tree, the watchdog loop, and anything carrying a suite marker.
own_pids() {
  local wd=""
  [[ -f "$HT_WORK/watchdog.pid" ]] && wd="$(cat "$HT_WORK/watchdog.pid" 2>/dev/null || true)"
  ps_dump | python3 -c "$_HT_OWN_PY" "${HT_MAIN_PID:-0}" "$$" "${wd:-0}" "${HT_OWN_PIDS_EXTRA:-}" "$HT_OWN_MARKERS"
}
_HT_OWN_PY="$(cat <<'PY'
import re, sys
roots = {a for a in sys.argv[1:4] if a and a != "0"} | set(sys.argv[4].split())
marker = re.compile(sys.argv[5])
rows = []
for line in sys.stdin:
    p = line.split(None, 2)
    if len(p) < 2 or not p[0].isdigit():
        continue
    if len(p) == 3 and p[1].isdigit():
        rows.append((p[0], p[1], p[2].rstrip("\n")))
    else:
        rows.append((p[0], "0", line.split(None, 1)[1].rstrip("\n")))
own = set(roots) | {pid for pid, _, cmd in rows if marker.search(cmd)}
changed = True
while changed:
    changed = False
    for pid, ppid, _ in rows:
        if ppid in own and pid not in own:
            own.add(pid); changed = True
for pid in sorted(own, key=int):
    print(pid)
PY
)"
# _match_procs KIND(op-procs|ol-procs) -> "pid<TAB>name<TAB>path" (exact path; own processes excluded)
_match_procs() {
  local kind="$1" al own
  al="$(al_get "$kind")"
  own="$(own_pids | tr '\n' ' ')"
  ps_dump | python3 -c '
import sys
allow = [l.split("\t", 1) for l in sys.argv[1].splitlines() if "\t" in l]
own = set(sys.argv[2].split())
for line in sys.stdin:
    p = line.split(None, 2)
    if len(p) < 2 or not p[0].isdigit():
        continue
    cmd = p[2] if (len(p) == 3 and p[1].isdigit()) else line.split(None, 1)[1]
    cmd = cmd.rstrip("\n")
    if p[0] in own:
        continue
    for name, path in allow:
        if cmd == path or cmd.startswith(path + " "):
            print(p[0] + "\t" + name + "\t" + path)
            break
' "$al" "$own"
}
list_optionsplus_procs() { _match_procs op-procs; }
list_openlogi_procs() { _match_procs ol-procs; }
# Processes whose executable BASENAME equals an allowlisted Options+ name but whose path is NOT allowlisted.
# Read-only precheck: a run refuses to start if this prints anything (allowlist is stale -> do not guess).
list_optionsplus_path_mismatch() {
  local al
  al="$(al_get op-procs)"
  ps_dump | python3 -c '
import sys, os
allow = [l.split("\t", 1) for l in sys.argv[1].splitlines() if "\t" in l]
names = {n for n, _ in allow}; paths = {p for _, p in allow}
for line in sys.stdin:
    p = line.split(None, 2)
    if len(p) < 2 or not p[0].isdigit():
        continue
    cmd = (p[2] if (len(p) == 3 and p[1].isdigit()) else line.split(None, 1)[1]).rstrip("\n")
    if any(cmd == x or cmd.startswith(x + " ") for x in paths):
        continue
    exe = cmd.split(" -", 1)[0].rstrip()
    if os.path.basename(exe) in names:
        print(p[0] + "\t" + os.path.basename(exe) + "\t" + cmd)
' "$al"
}
proc_names_running() { list_optionsplus_procs | awk -F '\t' '{print $2}' | sort -u; }
logi_plugin_service_running() { list_optionsplus_procs | awk -F '\t' '$2 == "LogiPluginService" { f = 1 } END { exit !f }'; }
gui_running() { list_optionsplus_procs | awk -F '\t' '$2 == "logioptionsplus" { f = 1 } END { exit !f }'; }
gui_info() { al_get gui | head -1; }
gui_bundle_id() {
  local bp bid main id
  IFS=$'\t' read -r bp bid main <<<"$(gui_info)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bp/Contents/Info.plist" 2>/dev/null || true)"
  printf '%s\n' "${id:-$bid}"
}

# safe_kill_pid PID WHY KIND   (KIND op-procs|ol-procs). Re-verifies the PID against the exact allowlist first.
safe_kill_pid() {
  local pid="$1" why="${2:-kill}" kind="${3:-op-procs}" line
  line="$(_match_procs "$kind" | awk -F '\t' -v p="$pid" '$1 == p { print; exit }')"
  if [[ -z "$line" ]]; then
    write_r WARN "safe_kill: pid $pid is not an allowlisted $kind process (or own process) - NOT killed"
    return 1
  fi
  write_r INFO "kill [$why] $line"
  if [[ -n "${HT_DRY_KILL:-}" ]]; then printf '%s\n' "$pid" >>"$HT_DRY_KILL"; return 0; fi
  kill "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [[ $i -lt ${HT_KILL_GRACE:-2} ]]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  return 0
}
kill_allowlisted() {
  local kind="$1" why="$2" pid
  for pid in $(_match_procs "$kind" | awk -F '\t' '{print $1}'); do
    safe_kill_pid "$pid" "$why" "$kind" || true
  done
}

# ------------------------------------------------------------------ launchd (exact allowlisted targets only)
# lctl ACTION DOMAIN LABEL     ACTION: bootout|bootstrap|kickstart
lctl() {
  local action="$1" dom="$2" label="$3" plist
  if ! al_launchd_allowed "$action" "$dom" "$label"; then
    write_r ERROR "REFUSED launchctl $action $dom/$label (not in allowlist.json)"
    return 1
  fi
  if [[ -n "${HT_DRY_LAUNCHCTL:-}" ]]; then printf '%s %s/%s\n' "$action" "$dom" "$label" >>"$HT_DRY_LAUNCHCTL"; return 0; fi
  case "$action" in
    bootout) launchctl bootout "$dom/$label" 2>/dev/null ;;
    kickstart) launchctl kickstart "$dom/$label" 2>/dev/null ;;
    bootstrap)
      plist="$(al_launchd_plist "$dom" "$label")"
      [[ -n "$plist" && -f "$plist" ]] || { write_r ERROR "bootstrap $dom/$label: plist missing: $plist"; return 1; }
      launchctl bootstrap "$dom" "$plist" 2>/dev/null ;;
    *) return 1 ;;
  esac
}
lctl_loaded() { launchctl print "$1/$2" >/dev/null 2>&1; }

# ------------------------------------------------------------------ restore bookkeeping (per item, never stops)
HT_RR_ERR=0; HT_RR_N=0; HT_RR_TEXT=""
rr() {  # rr STATUS NAME DETAIL    STATUS: OK|ERROR|WARN|LEFTOVER
  HT_RR_N=$((HT_RR_N + 1))
  [[ "$1" == ERROR ]] && HT_RR_ERR=$((HT_RR_ERR + 1))
  HT_RR_TEXT="${HT_RR_TEXT}  [$1] $2 ${3:+- $3}"$'\n'
  local lvl=INFO; [[ "$1" == ERROR ]] && lvl=ERROR; [[ "$1" == WARN || "$1" == LEFTOVER ]] && lvl=WARN
  write_r "$lvl" "RESTORE $1: $2 ${3:+- $3}"
  return 0
}
# step NAME CMD...  run one restore step; failure is recorded, never aborts the restore
step() {
  local name="$1"; shift
  local rc=0
  if "$@"; then rc=0; else rc=$?; fi
  if [[ $rc -eq 0 ]]; then rr OK "step $name"; else rr ERROR "step $name" "exit $rc"; fi
  return 0
}
rr_summary() {
  section "RESTORE SUMMARY ($HT_RR_N items, $HT_RR_ERR errors)"
  printf '%s' "$HT_RR_TEXT" | while IFS= read -r l; do [[ -n "$l" ]] && write_r SUM "$l"; done
  if [[ "$HT_RR_ERR" -eq 0 ]]; then write_r INFO "RESTORE: all items OK"; return 0; fi
  write_r ERROR "RESTORE: $HT_RR_ERR item(s) failed - see [ERROR] lines; run emergency-restore.sh, then tell GM"
  return 1
}

# ------------------------------------------------------------------ read-only launchd discovery (info / preflight only)
list_logi_labels() {
  local domain="${1:-}" src cleanup=0
  if [[ -n "${HT_LAUNCHCTL_PRINT_FILE:-}" && -f "$HT_LAUNCHCTL_PRINT_FILE" ]]; then src="$HT_LAUNCHCTL_PRINT_FILE"
  else src="$(mktemp /tmp/ol-hwtest-lctl.XXXXXX)"; cleanup=1; launchctl print "$domain" >"$src" 2>/dev/null || true; fi
  awk '
    /services =/ { in_svc = 1; next }
    /^=+/ { if (in_svc && $0 !~ /services =/) in_svc = 0 }
    in_svc { if (match($0, /(com\.logi\.[A-Za-z0-9._-]+|com\.logitech\.[A-Za-z0-9._-]+|application\.com\.logi\.pluginservice\.[A-Za-z0-9._-]+)/)) print substr($0, RSTART, RLENGTH) }
  ' "$src" | sort -u
  if [[ "$cleanup" -eq 1 ]]; then rm -f "$src"; fi
}
print_disabled_map() {
  local domain="$1" src cleanup=0
  if [[ -n "${HT_LAUNCHCTL_DISABLED_FILE:-}" && -f "$HT_LAUNCHCTL_DISABLED_FILE" ]]; then src="$HT_LAUNCHCTL_DISABLED_FILE"
  else src="$(mktemp /tmp/ol-hwtest-lctl.XXXXXX)"; cleanup=1; launchctl print-disabled "$domain" >"$src" 2>/dev/null || true; fi
  awk '{
      if (match($0, /"[^"]+"/)) {
        lab = substr($0, RSTART + 1, RLENGTH - 2); st = "unknown"
        if ($0 ~ /disabled/) st = "disabled"; else if ($0 ~ /enabled/) st = "enabled"
        print lab "\t" st
      }
    }' "$src" | sort -u
  if [[ "$cleanup" -eq 1 ]]; then rm -f "$src"; fi
}
label_is_never_touch() { al_has never-touch "$1"; }
label_is_runningboard_app() {   # the ONLY dynamic id: application.com.logi.pluginservice.<N...>
  local pfx bp
  while IFS=$'\t' read -r pfx bp; do
    case "$1" in "$pfx"*) return 0 ;; esac
  done < <(al_get rb-apps)
  return 1
}
# Mutation target? exact allowlisted launchd job with "bootout" for role optionsplus.
label_is_stop_target() {
  local d l p a
  while IFS=$'\t' read -r d l p a; do
    if [[ "$l" == "$1" ]]; then case ",$a," in *,bootout,*) return 0 ;; esac; fi
  done < <(al_get launchd-optionsplus)
  return 1
}

# ------------------------------------------------------------------ snapshot / diff
snap_value() {  # snap_value FILE KEY
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    it = json.load(open(sys.argv[1], encoding="utf-8"))["items"]
    v = it.get(sys.argv[2])
    print("" if v is None else v.get("value", ""), end="")
except Exception:
    pass
PY
}
_own_work_paths() { printf '%s\n%s\n%s\n' "$HT_WORK" "${HT_USER_WORK:-$HT_HOME/Library/Application Support/OpenLogi-hwtest}" "$HT_MUTEX"; }
take_snapshot() {
  local out="$1" d l p a v
  export HT_SNAP_OP HT_SNAP_OL HT_SNAP_JOBS HT_SNAP_DIS HT_SNAP_ENV HT_SNAP_INFO_LABELS HT_SNAP_PATHS HT_SNAP_OWN HT_SNAP_DIRS
  HT_SNAP_OP="$(list_optionsplus_procs | awk -F '\t' '{print $2 "=" $3}' | sort -u)"
  HT_SNAP_OL="$(list_openlogi_procs | awk -F '\t' '{print $2 "=" $3}' | sort -u)"
  HT_SNAP_JOBS=""
  while IFS=$'\t' read -r d l p a; do
    v=absent; lctl_loaded "$d" "$l" && v=loaded
    HT_SNAP_JOBS="${HT_SNAP_JOBS}${d}/${l}	${v}"$'\n'
  done < <(al_get launchd-optionsplus)
  HT_SNAP_DIS="$( { print_disabled_map "gui/$HT_TARGET_UID"; print_disabled_map system; } 2>/dev/null | while IFS=$'\t' read -r l v; do
      if label_is_stop_target "$l" || label_is_never_touch "$l"; then printf '%s\t%s\n' "$l" "$v"; fi; done | sort -u)"
  HT_SNAP_ENV=""
  for v in $(al_get env-unset); do HT_SNAP_ENV="${HT_SNAP_ENV}${v}=$(as_user launchctl getenv "$v" 2>/dev/null || true)"$'\n'; done
  HT_SNAP_INFO_LABELS="$( { list_logi_labels "gui/$HT_TARGET_UID" | sed 's/^/gui: /'; list_logi_labels system | sed 's/^/system: /'; } 2>/dev/null | sed -E 's/(application\.com\.logi\.pluginservice\.).*/\1<N>/' | sort -u)"
  HT_SNAP_OWN="$(_own_work_paths)"
  HT_SNAP_PATHS="$( { al_get paths-absent; al_get paths-empty; } | grep -vxF -f <(printf '%s\n' "$HT_SNAP_OWN") || true)"
  HT_SNAP_DIRS="$(printf '%s\n%s\n%s\n' "$HT_CONFIG_DIR" "$HT_STATE_DIR" "$HT_DATA_DIR")"
  python3 - "$out" <<'PY'
import datetime, hashlib, json, os, platform, subprocess, sys
items = {}
def add(k, v, info=False): items[k] = {"value": "" if v is None else str(v).strip("\n"), "info": bool(info)}
def run(cmd):
    try: return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
    except Exception: return ""
e = os.environ.get
add("info.os", "%s %s %s" % (platform.system(), platform.mac_ver()[0], platform.machine()), True)
add("info.consoleUser", e("HT_TARGET_USER", ""), True)
add("proc.optionsplus", e("HT_SNAP_OP", ""))
op = e("HT_SNAP_OP", "")
add("app.LogiPluginService.running", "true" if "\nLogiPluginService=" in "\n" + op else "false")
add("app.logioptionsplus.gui.running", "true" if "\nlogioptionsplus=" in "\n" + op else "false")
add("proc.openlogi", e("HT_SNAP_OL", ""))
for line in e("HT_SNAP_JOBS", "").splitlines():
    if "\t" in line:
        k, v = line.split("\t", 1); add("launchd.job:" + k, v)
add("launchd.disabled.allowlisted", e("HT_SNAP_DIS", ""))
for line in e("HT_SNAP_ENV", "").splitlines():
    if "=" in line:
        k, v = line.split("=", 1); add("launchd.env:" + k, v)
add("info.launchd.logi_labels", e("HT_SNAP_INFO_LABELS", ""), True)
def manifest(d):
    if not os.path.exists(d): return "absent"
    lines = ["present"]
    for dp, dns, fns in os.walk(d):
        dns.sort(); fns.sort()
        rel = os.path.relpath(dp, d)
        if rel != ".": lines.append("D /" + rel)
        for n in fns:
            p = os.path.join(dp, n)
            try:
                h = hashlib.sha256(open(p, "rb").read()).hexdigest()
                lines.append("F /%s %d %s" % (os.path.relpath(p, d), os.path.getsize(p), h))
            except Exception:
                lines.append("F /%s unreadable" % os.path.relpath(p, d))
    return "\n".join(lines)
for d in e("HT_SNAP_DIRS", "").splitlines():
    if d: add("dir.openlogi:" + d, manifest(d))
for d in e("HT_SNAP_PATHS", "").splitlines():
    if d: add("path.exists:" + d, str(os.path.exists(d)))
fw = run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--listapps"])
add("info.firewall.apps.openlogi", "\n".join(l.strip() for l in fw.splitlines() if "openlogi" in l.lower()), True)
add("info.firewall.global", run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"]).strip(), True)
btm = run(["sfltool", "dumpbtm"])
add("info.btm.openlogi", "\n".join(l.rstrip() for l in btm.splitlines() if "org.openlogi" in l.lower() or "openlogi.app" in l.lower()), True)
tcc = []
for db in ("%s/Library/Application Support/com.apple.TCC/TCC.db" % e("HT_HOME", ""), "/Library/Application Support/com.apple.TCC/TCC.db"):
    if os.path.exists(db):
        o = run(["sqlite3", db, "SELECT service, client, auth_value FROM access WHERE client LIKE '%openlogi%';"])
        tcc += ["%s|%s" % (db, l) for l in o.splitlines()] or ["%s|none-or-unreadable" % db]
add("info.tcc.openlogi", "\n".join(tcc), True)
udp = run(["lsof", "-nP", "-iUDP:%s" % e("HT_PORT", "42424"), "-Fc"])
add("net.udp.listeners", "\n".join(sorted({l[1:] for l in udp.splitlines() if l.startswith("c")})))
doc = {"takenAt": datetime.datetime.now().astimezone().isoformat(timespec="milliseconds"), "host": platform.node(), "items": items}
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False); f.write("\n")
print(len(items))
PY
}
# compare_snapshots PRE POST -> prints DIFF lines; exit 0 = all non-info items equal.
# Run-1 pre-snapshots (old keys) are mapped: proc.optionsplus.allowlist "pid\tname\tcmd" -> name=cmd.
compare_snapshots() {
  python3 - "$1" "$2" <<'PY'
import json, sys
pre = json.load(open(sys.argv[1], encoding="utf-8"))["items"]
post = json.load(open(sys.argv[2], encoding="utf-8"))["items"]
if "proc.optionsplus.allowlist" in pre and "proc.optionsplus" not in pre:
    v = pre.pop("proc.optionsplus.allowlist")["value"]
    rows = sorted({"%s=%s" % (l.split("\t")[1], l.split("\t", 2)[2]) for l in v.splitlines() if l.count("\t") >= 2})
    pre["proc.optionsplus"] = {"value": "\n".join(rows), "info": False}
for k in [k for k in pre if k not in post]:
    pre[k] = dict(pre[k], info=True)   # keys the new snapshot does not produce (run-1 format) -> info only
fail = same = 0
for k in sorted(set(pre) | set(post)):
    a = pre.get(k, {}).get("value", "<missing>"); b = post.get(k, {}).get("value", "<missing>")
    info = pre.get(k, {}).get("info") or post.get(k, {}).get("info")
    if a == b:
        if not info: same += 1
        print("%s %s" % ("INFO-SAME" if info else "PASS", k)); continue
    if info: print("INFO-CHANGED %s" % k)
    else:
        fail += 1; print("FAIL %s" % k)
    print("    pre : %s" % a.replace("\n", " | "))
    print("    post: %s" % b.replace("\n", " | "))
print("DIFF RESULT: %s (%d items equal, %d differ; INFO items not counted)" % ("PASS" if fail == 0 else "FAIL", same, fail))
sys.exit(0 if fail == 0 else 1)
PY
}

# ------------------------------------------------------------------ Options+ stop / restore
# Policy: never `launchctl disable/enable` (keeps print-disabled overrides). Exact allowlisted plist jobs:
# bootout to stop, bootstrap (+kickstart for gui) to restore. LogiPluginService is a RunningBoard app job
# (application.com.logi.pluginservice.<N>, the only dynamic id): never bootout; stop = kill exact executable
# paths, restore = `open -g -j` the exact bundle path. GUI (logioptionsplus): stop = SIGTERM to the exact
# executable path; restore = back to its PRE-TEST state (running -> open -g; not running -> stays closed).
# No osascript anywhere (avoids Automation/TCC prompts).
# Record whether the Options+ GUI / LogiPluginService run BEFORE anything is changed. Must be called (and saved)
# before restore-on-exit is armed: otherwise a failure before stop_options_plus (bad PAT, download error) would make
# restore treat "unknown" as "was closed" and kill Jay's open Options+ window.
record_optionsplus_prestate() {
  HT_PLUGIN_WAS_RUNNING=0; logi_plugin_service_running && HT_PLUGIN_WAS_RUNNING=1
  HT_GUI_WAS_RUNNING=0; gui_running && HT_GUI_WAS_RUNNING=1
  HT_GUI_STATE_KNOWN=1; HT_PLUGIN_STATE_KNOWN=1
  export HT_PLUGIN_WAS_RUNNING HT_GUI_WAS_RUNNING HT_GUI_STATE_KNOWN HT_PLUGIN_STATE_KNOWN
  write_r INFO "pre-test: LogiPluginService running=$HT_PLUGIN_WAS_RUNNING, Options+ GUI running=$HT_GUI_WAS_RUNNING"
}
stop_options_plus() {
  section "STOP Options+ (allowlist only)"
  local d l p a
  [[ "${HT_GUI_STATE_KNOWN:-0}" == 1 && "${HT_PLUGIN_STATE_KNOWN:-0}" == 1 ]] || record_optionsplus_prestate
  local stopped="[]"
  while IFS=$'\t' read -r d l p a; do
    if lctl_loaded "$d" "$l"; then
      write_r INFO "bootout $d/$l"
      lctl bootout "$d" "$l" || write_r WARN "bootout $d/$l returned non-zero"
      stopped="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.append(sys.argv[2]); print(json.dumps(a))' "$stopped" "$d/$l")"
    else
      write_r INFO "$d/$l not loaded - left alone"
    fi
  done < <(al_get launchd-optionsplus)
  HT_ACT_DISABLED_JSON="$stopped"; export HT_ACT_DISABLED_JSON
  save_state
  HT_KILL_GRACE=5 kill_allowlisted op-procs initial
  save_state
}
watch_respawn() {
  local sec="$1" end n=0
  end=$(( $(date +%s) + sec ))
  while [[ $(date +%s) -lt $end ]]; do
    if [[ -n "$(list_optionsplus_procs)" ]]; then kill_allowlisted op-procs respawn; n=$((n + 1)); fi
    sleep 2
  done
  write_r INFO "Respawn check (${sec}s): $n round(s) found allowlisted Options+ processes"
  echo "$n"
}
_open_bundle_as_user() {  # exact allowlisted bundle paths only
  local bp="$1" ok=1 x y
  while IFS=$'\t' read -r x y; do [[ "$y" == "$bp" ]] && ok=0; done < <(al_get rb-apps)
  IFS=$'\t' read -r x y _ <<<"$(gui_info)"; [[ "$x" == "$bp" ]] && ok=0
  if [[ $ok -ne 0 ]]; then write_r ERROR "REFUSED open $bp (not in allowlist)"; return 1; fi
  if [[ -n "${HT_DRY_OPEN:-}" ]]; then printf '%s\n' "$bp" >>"$HT_DRY_OPEN"; return 0; fi
  as_user /usr/bin/open -g -j -a "$bp" 2>/dev/null || as_user /usr/bin/open -g -a "$bp" 2>/dev/null
}
restore_gui() {
  if [[ "${HT_GUI_STATE_KNOWN:-0}" != 1 ]]; then rr WARN "Options+ GUI" "pre-test state unknown - left as it is now"; return 0; fi
  local bp bid main i
  IFS=$'\t' read -r bp bid main <<<"$(gui_info)"
  sleep "${HT_GUI_SETTLE_SEC:-5}"
  if [[ "${HT_GUI_WAS_RUNNING:-0}" == 1 ]]; then
    gui_running || _open_bundle_as_user "$bp" || true
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do gui_running && break; sleep 1; done
    if gui_running; then rr OK "Options+ GUI" "running (as before)"; else rr ERROR "Options+ GUI" "was running before, not running now"; fi
  else
    # Not running before: make sure the restored agent did not open it (checked twice, agent may open it late).
    for i in 1 2; do
      if gui_running; then
        local pid
        for pid in $(list_optionsplus_procs | awk -F '\t' '$2 == "logioptionsplus" {print $1}'); do safe_kill_pid "$pid" "GUI was closed before the test" op-procs || true; done
      fi
      sleep "${HT_GUI_SETTLE_SEC:-5}"
    done
    if gui_running; then rr ERROR "Options+ GUI" "was NOT running before, still running"; else rr OK "Options+ GUI" "closed (as before)"; fi
  fi
}
restore_options_plus() {
  section "RESTORE Options+"
  local t d l
  for t in $(python3 -c 'import json,os; print("\n".join(json.loads(os.environ.get("HT_ACT_DISABLED_JSON","[]"))))'); do
    l="${t##*/}"; d="${t%/*}"
    if label_is_runningboard_app "$l"; then rr OK "launchd $t" "RunningBoard app job - restored via open, not bootstrap"; continue; fi
    if lctl_loaded "$d" "$l"; then rr OK "launchd $t" "already loaded"; continue; fi
    lctl bootstrap "$d" "$l" || true
    case "$d" in gui/*) lctl kickstart "$d" "$l" || true ;; esac
    if lctl_loaded "$d" "$l"; then rr OK "launchd $t" "bootstrapped"; else rr ERROR "launchd $t" "not loaded after bootstrap"; fi
  done
  sleep 3
  if [[ "${HT_PLUGIN_STATE_KNOWN:-0}" != 1 ]]; then
    rr WARN "LogiPluginService" "pre-test state unknown - left as it is now"
  elif [[ "${HT_PLUGIN_WAS_RUNNING:-0}" == 1 ]]; then
    local pfx bp i
    IFS=$'\t' read -r pfx bp <<<"$(al_get rb-apps | head -1)"
    for i in 1 2 3 4 5; do logi_plugin_service_running && break; sleep 1; done
    logi_plugin_service_running || _open_bundle_as_user "$bp" || true
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do logi_plugin_service_running && break; sleep 1; done
    if logi_plugin_service_running; then rr OK "LogiPluginService" "running"; else rr ERROR "LogiPluginService" "was running before, not running now"; fi
  else
    rr OK "LogiPluginService" "was not running before - not started"
  fi
  restore_gui
  write_r INFO "Options+ processes now: $(proc_names_running | tr '\n' ' ')"
}

# artifact_to_dmg SRC WORKDIR -> prints the .dmg path. SRC = the browser-downloaded artifact .zip (zip wrapping the
# .dmg, possibly nested), a .dmg, or a FOLDER (Safari auto-unzips downloads). Read-only on SRC.
artifact_to_dmg() {
  local src="$1" w="$2" d iz
  case "$src" in
    *.dmg) [[ -f "$src" ]] && { printf '%s\n' "$src"; return 0; } ;;
  esac
  if [[ -d "$src" ]]; then
    d="$(find "$src" -name '*.dmg' -type f 2>/dev/null | head -1)"
    if [[ -z "$d" ]]; then iz="$(find "$src" -name '*.zip' -type f 2>/dev/null | head -1)"; [[ -n "$iz" ]] && src="$iz"; fi
    [[ -n "$d" ]] && { printf '%s\n' "$d"; return 0; }
  fi
  [[ -f "$src" ]] || return 1
  mkdir -p "$w/unz"
  unzip -o -q "$src" -d "$w/unz" || return 1
  d="$(find "$w/unz" -name '*.dmg' -type f | head -1)"
  if [[ -z "$d" ]]; then
    iz="$(find "$w/unz" -name '*.zip' -type f | head -1)"
    [[ -n "$iz" ]] || return 1
    mkdir -p "$w/unz2"; unzip -o -q "$iz" -d "$w/unz2" || return 1
    d="$(find "$w/unz2" -name '*.dmg' -type f | head -1)"
  fi
  [[ -n "$d" ]] || return 1
  printf '%s\n' "$d"
}
# check_build_signature APP: arm64 macOS kills code that is not signed at all; ad-hoc is enough (run 1: Signature=adhoc).
check_build_signature() {
  local app="$1" b out bad=0
  for b in "$app/Contents/MacOS/openlogi-desktop" "$app/Contents/Library/LoginItems/OpenLogi Agent.app/Contents/MacOS/openlogi-agent"; do
    [[ -e "$b" ]] || { echo "  codesign: $(basename "$b") MISSING in build"; bad=1; continue; }
    out="$(codesign -dv "$b" 2>&1 || true)"
    if printf '%s' "$out" | grep -q -i 'not signed'; then
      echo "  !!! codesign: $(basename "$b") is NOT signed (not even ad-hoc) - macOS on arm64 will KILL it. Do not run; tell GM."; bad=1
    else
      echo "  codesign: $(basename "$b") $(printf '%s\n' "$out" | grep -E '^(Signature=|Authority=)' | head -1)"
    fi
  done
  return $bad
}

# ------------------------------------------------------------------ OpenLogi stop / files / TCC / env
stop_openlogi() {
  section "STOP OpenLogi (exact paths; releases input hooks)"
  local uid="$HT_TARGET_UID" left
  if lctl_loaded "gui/$uid" "$HT_AGENT_SERVICE"; then lctl bootout "gui/$uid" "$HT_AGENT_SERVICE" || true; fi
  kill_allowlisted ol-procs "stop OpenLogi"
  sleep 1
  left="$(list_openlogi_procs)"
  if [[ -n "$left" ]]; then rr ERROR "OpenLogi processes" "still alive: $(printf '%s' "$left" | tr '\n' ' ')"; return 1; fi
  rr OK "OpenLogi processes" "none left (own test processes excluded)"
}
rm_safe() {
  local p="$1"
  if ! al_path_removable "$p"; then rr ERROR "remove $p" "not in allowlist - refused"; return 1; fi
  [[ -e "$p" || -L "$p" ]] || return 0
  if [[ -n "${HT_DRY_RM:-}" ]]; then printf '%s\n' "$p" >>"$HT_DRY_RM"; rr OK "remove $p" "(dry)"; return 0; fi
  rm -rf "$p" 2>/dev/null || true
  if [[ -e "$p" ]]; then rr ERROR "remove $p" "still present"; return 1; fi
  rr OK "remove $p"
}
remove_test_files() {
  section "CLEANUP files (allowlist only)"
  local pre="$HT_WORK/snapshot-pre.json" have_pre=0 d pv b
  [[ -f "$pre" ]] && have_pre=1
  if [[ "${HT_APP_EXISTED:-0}" != 1 && -d "$HT_APP" ]]; then rm_safe "$HT_APP" || true; fi
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$d" in "$HT_APP"|"$HT_WORK"|"$HT_MUTEX"|*/OpenLogi-hwtest) continue ;; esac
    b="$(python3 -c 'import json,os,sys; m=[x.split("|",1)[1] for x in json.loads(os.environ.get("HT_ACT_BACKUPS_JSON","[]")) if x.split("|",1)[0]==sys.argv[1]]; print(m[0] if m else "")' "$d")"
    if [[ -n "$b" && -d "$b" ]]; then
      rm_safe "$d" || true
      if /usr/bin/ditto "$b" "$d"; then rr OK "restore pre-existing $d"; else rr ERROR "restore pre-existing $d" "ditto failed"; fi
      continue
    fi
    pv=""
    if [[ $have_pre -eq 1 ]]; then pv="$(snap_value "$pre" "dir.openlogi:$d")"; [[ -n "$pv" ]] || pv="$(snap_value "$pre" "path.exists:$d")"; fi
    if [[ "$pv" == absent || "$pv" == False ]]; then rm_safe "$d" || true
    elif [[ $have_pre -eq 0 && -e "$d" ]]; then rr LEFTOVER "keep $d" "no snapshot: cannot tell whether it existed before"
    fi
  done < <(al_get paths-absent)
  while IFS= read -r d; do
    [[ -n "$d" && -d "$d" ]] || continue
    pv=""; [[ $have_pre -eq 1 ]] && pv="$(snap_value "$pre" "path.exists:$d")"
    [[ "$pv" == False ]] || continue
    if [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then rm_safe "$d" || true; else rr LEFTOVER "keep $d" "created during the test but not empty"; fi
  done < <(al_get paths-empty | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
}
reset_tcc_for_openlogi() {
  section "TCC reset (OpenLogi bundle ids only)"
  local s b
  for s in $(al_get tcc-services); do
    for b in $(al_get tcc-bundles); do
      if tccutil reset "$s" "$b" >/dev/null 2>&1 || as_user tccutil reset "$s" "$b" >/dev/null 2>&1; then rr OK "tccutil reset $s $b"
      else rr WARN "tccutil reset $s $b" "failed - remove manually (RUNBOOK 第 9 步)"; fi
    done
  done
  rr LEFTOVER "Local Network (本地网络) entry for OpenLogi" "tccutil cannot reset it; see RUNBOOK 第 9 步"
}
restore_launchd_env() {
  local v pre cur prev
  prev="$HT_WORK/snapshot-pre.json"
  for v in $(al_get env-unset); do
    pre=""; [[ -f "$prev" ]] && pre="$(snap_value "$prev" "launchd.env:$v")"
    cur="$(as_user launchctl getenv "$v" 2>/dev/null || true)"
    if [[ -z "$pre" && -n "$cur" ]]; then
      launchctl asuser "$HT_TARGET_UID" launchctl unsetenv "$v" 2>/dev/null || true
      cur="$(as_user launchctl getenv "$v" 2>/dev/null || true)"
      if [[ -z "$cur" ]]; then rr OK "launchctl unsetenv $v"; else rr ERROR "launchctl unsetenv $v" "still set"; fi
    else
      rr OK "launchd env $v" "unchanged (before='${pre}')"
    fi
  done
}

# ------------------------------------------------------------------ lease watchdog (LaunchDaemon + detached loop)
# Both call `watchdog.sh --tick` which reads state.json + lease.json and restores only when
# the main script died, the lease expired (main hung), or the absolute hard cap passed.
install_watchdog() {
  local suite="$HT_WORK/suite"
  if ! al_launchd_allowed bootstrap system "$HT_WATCHDOG_LABEL"; then write_r ERROR "watchdog label not in allowlist"; return 1; fi
  # shellcheck disable=SC2016  # $0 is expanded by the inner bash
  nohup /bin/bash -c 'while sleep 30; do /bin/bash "$0" --tick; [ "$?" -eq 10 ] && exit 0; done' "$suite/watchdog.sh" >/dev/null 2>&1 &
  echo $! >"$HT_WORK/watchdog.pid"
  write_r INFO "Detached lease-watchdog loop pid $(cat "$HT_WORK/watchdog.pid") (checks every 30 s)"
  cat >"$HT_WATCHDOG_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$HT_WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$suite/watchdog.sh</string><string>--tick</string></array>
  <key>EnvironmentVariables</key><dict><key>HT_FROM_LAUNCHD</key><string>1</string></dict>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HT_WORK/watchdog.out</string>
  <key>StandardErrorPath</key><string>$HT_WORK/watchdog.err</string>
</dict>
</plist>
PLIST
  chmod 644 "$HT_WATCHDOG_PLIST"
  launchctl bootout "system/$HT_WATCHDOG_LABEL" 2>/dev/null || true
  lctl bootstrap system "$HT_WATCHDOG_LABEL"
  write_r INFO "LaunchDaemon $HT_WATCHDOG_LABEL installed (StartInterval 60 s, also runs at boot)"
}
uninstall_watchdog() {
  local pid
  if [[ -f "$HT_WORK/watchdog.pid" ]]; then
    pid="$(cat "$HT_WORK/watchdog.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && /bin/ps -p "$pid" -o command= 2>/dev/null | grep -q 'watchdog.sh'; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$HT_WORK/watchdog.pid"
  fi
  [[ -f "$HT_WATCHDOG_PLIST" ]] && rm -f "$HT_WATCHDOG_PLIST"
  if [[ "${HT_FROM_LAUNCHD:-0}" == 1 ]]; then
    write_r INFO "Watchdog LaunchDaemon plist deleted; job is booted out as the very last action of this watchdog run"
    return 0
  fi
  if lctl_loaded system "$HT_WATCHDOG_LABEL"; then lctl bootout system "$HT_WATCHDOG_LABEL" || true; fi
  write_r INFO "Watchdog removed"
}

# ------------------------------------------------------------------ full restore (main end, Ctrl+C, watchdog, manual)
_mutex_take() {
  local waited=0 holder
  while ! mkdir "$HT_MUTEX" 2>/dev/null; do
    holder="$(cat "$HT_MUTEX/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$HT_MUTEX"; continue; fi
    sleep 1; waited=$((waited + 1))
    if [[ $waited -gt 300 ]]; then write_r ERROR "restore mutex busy for 300 s - continuing anyway"; return 0; fi
  done
  echo $$ >"$HT_MUTEX/pid"
}
_mutex_drop() { rm -rf "$HT_MUTEX" 2>/dev/null || true; }
HT_DIFF_RESULT="n/a"
full_restore() {
  local reason="$1"
  _mutex_take
  HT_RR_ERR=0; HT_RR_N=0; HT_RR_TEXT=""
  section "FULL RESTORE ($reason)"
  step "stop OpenLogi" stop_openlogi
  step "restore Options+" restore_options_plus
  step "launchd env" restore_launchd_env
  step "TCC reset" reset_tcc_for_openlogi   # before the app is deleted
  step "files" remove_test_files
  export HT_COMPLETED=1
  [[ -d "$HT_WORK" ]] && { save_state || true; }
  if [[ -f "$HT_WORK/snapshot-pre.json" ]]; then
    sleep 3
    take_snapshot "$HT_WORK/snapshot-post.json" >/dev/null 2>&1 || true
    section "STATE DIFF (pre vs post)"
    local dl drc=0
    dl="$(compare_snapshots "$HT_WORK/snapshot-pre.json" "$HT_WORK/snapshot-post.json" 2>&1)" || drc=$?
    printf '%s\n' "$dl" | while IFS= read -r l; do write_r DIFF "$l"; done
    if [[ $drc -eq 0 ]]; then HT_DIFF_RESULT=PASS; rr OK "state diff" "PASS"; else HT_DIFF_RESULT=FAIL; rr ERROR "state diff" "FAIL - see DIFF lines"; fi
  fi
  local fw
  fw="$("$HT_FIREWALL" --listapps 2>/dev/null | grep -i openlogi || true)"
  [[ -n "$fw" ]] && rr LEFTOVER "macOS firewall app entry" "$(printf '%s' "$fw" | tr '\n' ' ') - see RUNBOOK 第 9 步"
  step "watchdog" uninstall_watchdog
  [[ -n "${HT_USER_WORK:-}" ]] && { rm_safe "$HT_USER_WORK" || true; }
  rm_safe "$HT_WORK" || true
  local rc=0
  rr_summary || rc=1
  write_r INFO "Only remaining test file: $HT_RESULT"
  _mutex_drop
  return $rc
}

# ------------------------------------------------------------------ OpenLogi CLI / Flow status
# The CLI talks to the agent over ~/.config/openlogi/agent.sock -> must run AS THE USER with the user's HOME.
# Every openlogi CLI call gets a timeout (HT_CLI_TIMEOUT, default 30 s). macOS has no GNU `timeout`: perl's alarm
# survives exec, so the openlogi process ITSELF gets SIGALRM (exit 142) - no orphan keeps $(...) open.
# No /usr/bin/perl -> runs without a timeout (UNVERIFIED that macOS 27 still ships perl).
cli() {
  local -a to=()
  [[ -x /usr/bin/perl ]] && to=(/usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "${HT_CLI_TIMEOUT:-30}")
  if is_root; then
    launchctl asuser "$HT_TARGET_UID" /usr/bin/sudo -u "$HT_TARGET_USER" /usr/bin/env HOME="$HT_HOME" OPENLOGI_LOG="$HT_LOG_FILTER" ${to[@]+"${to[@]}"} "$HT_CLI" "$@"
  else
    /usr/bin/env OPENLOGI_LOG="$HT_LOG_FILTER" ${to[@]+"${to[@]}"} "$HT_CLI" "$@"
  fi
}
# parse_flow_status < JSON  -> "phase<TAB>sas<TAB>peer<TAB>localConfirmed<TAB>peerConfirmed<TAB>failure<TAB>nPeers<TAB>peer0"  (pure)
parse_flow_status() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try: d = json.loads(raw) if raw else None
except Exception: d = None
ph, sas, peer, lc, pc, fail = "Unavailable", "", "", "0", "0", ""
peers = []
if isinstance(d, dict):
    ph = "None"
    peers = [p.get("name", "") for p in (d.get("peers") or []) if isinstance(p, dict)]
    p = d.get("pairing")
    if isinstance(p, str): ph = p
    elif isinstance(p, dict) and p:
        ph = list(p.keys())[0]; v = p[ph]
        if ph == "Prompted" and isinstance(v, dict):
            sas = str(v.get("sas", "")); peer = v.get("machine_name", "") or ""
            lc = "1" if v.get("local_confirmed") else "0"; pc = "1" if v.get("peer_confirmed") else "0"
        elif ph == "Paired" and isinstance(v, dict): peer = v.get("name", "") or ""
        elif ph == "Failed":
            if isinstance(v, str): fail = v
            elif isinstance(v, dict) and v:
                k = list(v.keys())[0]; m = v[k]
                fail = k + (": " + str(m.get("message", "")) if isinstance(m, dict) else "")
print("\t".join([ph, sas, peer, lc, pc, fail.replace("\t", " ").replace("\n", " "), str(len(peers)), peers[0] if peers else ""]))
'
}
flow_state() { cli flow status 2>/dev/null | parse_flow_status; }
fmt_sas() { local s="$1"; if [[ ${#s} -eq 6 ]]; then echo "${s:0:3} ${s:3:3}"; else echo "$s"; fi; }

# ------------------------------------------------------------------ agent log events / Flow layout
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
set_openlogi_flow_layout() {
  local config_path="$1" edge="$2" peer="$3" port="${4:-42424}"
  if [[ ! -d "$(dirname "$config_path")" ]]; then
    mkdir -p "$(dirname "$config_path")"
    chown "${HT_TARGET_USER:-$(id -un)}" "$(dirname "$config_path")" 2>/dev/null || true
  fi
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
    chown "${HT_TARGET_USER:-$(id -un)}" "$config_path" 2>/dev/null || true
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
  chown "${HT_TARGET_USER:-$(id -un)}" "$config_path" 2>/dev/null || true
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
    write_r WARN "No Flow peer name available yet (pass --peer-name or finish pairing). Layout NOT written. GM layout for this host: edge=$edge -> peer=<Alienware>"
    return 1
  fi
  set_openlogi_flow_layout "$HT_CONFIG_DIR/config.toml" "$edge" "$peer" "$port"
  write_r INFO "flow enable (reload after layout): $(cli flow enable 2>&1 || true)"
  return 0
}

# ------------------------------------------------------------------ human gates (no countdowns; Enter / skip / abort)
HT_ABORTED=0
ht_abort() {
  HT_ABORTED=1
  write_r ERROR "ABORT: $*"
  exit 130
}
# gate TITLE PHASE POLL_SEC AUTO(0|1) "CMD1 CMD2" CHECK_FN -- LINE...
#   CHECK_FN prints one status line, returns 0 when the step is satisfied.
#   AUTO=1: continue by itself as soon as CHECK_FN succeeds. Result in GATE_RESULT: done|skip|<cmd>.
#   abort -> ht_abort (EXIT trap restores). Lease renewed every 60 s while waiting.
#   Test hooks: HT_GATE_FD (input fd), HT_GATE_READ_SEC, HT_GATE_SLEEP, HT_GATE_MAX_ITER.
gate() {
  local title="$1" phase="$2" poll="$3" auto="$4" cmds="$5" check="$6"
  shift 6
  if [[ "${1:-}" == "--" ]]; then shift; fi
  GATE_RESULT=""
  local help="输入: [回车]=我做完了,重新检查   skip=跳过此步   abort=中止测试并自动恢复"
  [[ -n "$cmds" ]] && help="$help   其它命令: $cmds"
  banner green "$title" "" "$@" "" "$(lease_status)" "$help"
  write_r GATE "GATE OPEN: $title"
  lease_renew "$phase"
  local fd="${HT_GATE_FD:-0}" now last_renew last_check=0 last_status="" st="" rc line it=0 c
  last_renew="$(date +%s)"
  while :; do
    it=$((it + 1))
    if [[ "${HT_GATE_MAX_ITER:-0}" -gt 0 && $it -gt ${HT_GATE_MAX_ITER:-0} ]]; then write_r ERROR "gate: max iterations reached (test guard)"; GATE_RESULT=max; return 3; fi
    now="$(date +%s)"
    if [[ "${HT_HARDCAP_MS:-0}" -gt 0 && $now -ge $(( HT_HARDCAP_MS / 1000 )) ]]; then ht_abort "HARD CAP reached at gate: $title"; fi
    if [[ $(( now - last_renew )) -ge 60 ]]; then
      lease_renew "$phase"; last_renew="$now"
      printf '  .. 仍在等待 [%s] - %s\n' "$title" "$(lease_status)" >&2
    fi
    if [[ -n "$check" && $(( now - last_check )) -ge $poll ]]; then
      last_check="$now"; rc=0
      st="$($check 2>/dev/null)" || rc=$?
      if [[ -n "$st" && "$st" != "$last_status" ]]; then write_r GATE "  status: $st"; last_status="$st"; fi
      if [[ "$auto" == 1 && $rc -eq 0 ]]; then write_r GATE "GATE PASSED (auto-detected): $title"; GATE_RESULT="done"; return 0; fi
    fi
    line=""
    if ! read -r -t "${HT_GATE_READ_SEC:-2}" line <&"$fd"; then
      [[ -t "$fd" ]] || sleep "${HT_GATE_SLEEP:-1}"
      continue
    fi
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^ *//; s/ *$//' | tr '[:upper:]' '[:lower:]')"
    if [[ "$line" == abort ]]; then write_r ERROR "GATE ABORT by user: $title"; ht_abort "aborted by user at gate: $title"; fi
    if [[ "$line" == skip ]]; then write_r WARN "GATE SKIPPED by user: $title"; GATE_RESULT="skip"; return 0; fi
    for c in $cmds; do
      if [[ "$line" == "$c" ]]; then write_r GATE "GATE command: $c"; GATE_RESULT="$c"; return 0; fi
    done
    if [[ -n "$line" ]]; then printf '  未知输入 "%s"。可用: 回车 / skip / abort %s\n' "$line" "$cmds" >&2; continue; fi
    if [[ -z "$check" ]]; then write_r GATE "GATE PASSED (Enter): $title"; GATE_RESULT="done"; return 0; fi
    rc=0; st="$($check 2>/dev/null)" || rc=$?
    last_check="$(date +%s)"
    if [[ $rc -eq 0 ]]; then write_r GATE "GATE PASSED: $title"; GATE_RESULT="done"; return 0; fi
    printf '  还没满足: %s  (完成后再按回车; 或输入 skip / abort)\n' "$st" >&2
  done
}
