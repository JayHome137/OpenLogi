#!/usr/bin/env bash
# Automated OpenLogi Flow hardware test for macOS (Jay's Mac Mini).
# Modes: preflight | run | restore
# Must be run with sudo for run/restore (launchctl bootout/bootstrap of system domain,
# /Applications install, LaunchDaemon watchdog). Preflight can run unprivileged.
#
# Artifact: --artifact /path/to/OpenLogi-macos-dmg-*.zip|.dmg
#        or --download-token <GitHub token> (never hardcoded).
# Coordination with Windows: --start-at-epoch-ms <T0> (shared wall-clock).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/common.sh"
export HT_COMMON="$DIR/common.sh"

MODE="preflight"
ARTIFACT=""
TOKEN=""
PEER_ADDRESS=""
PEER_NAME=""
FLOW_EDGE="right"
START_AT_MS=0
WATCHDOG_MIN=15
RESPAWN_SEC=20
SKIP_INJECT=0
PORT=42424
HUMAN_GATE_SEC=180
MEASURE_WAIT_SEC=180

usage() {
  cat <<USAGE
Usage: sudo $0 --mode preflight|run|restore [options]
  --artifact PATH           Local artifact (.zip wrapping .dmg, or .dmg)
  --download-token TOKEN    GitHub token to download from Actions run $HT_RUN_ID
  --peer-address HOST       Peer for openlogi flow pair-start
  --peer-name NAME          [[flow.layout]].peer (usually Alienware hostname after pairing)
  --flow-edge EDGE          left|right|top|bottom (default: right on Mac; GM: Mac left of Alienware)
  --start-at-epoch-ms MS    Shared T0 with the Windows run
  --watchdog-minutes N      Failsafe deadline (default 15; 5 is tight for first-run TCC+SAS+BT)
  --respawn-watch-sec N     How long to watch Options+ respawn (default 20)
  --human-gate-sec N        Pause after pair-start for SAS confirm / TCC (default 180)
  --measure-wait-sec N      Poll agent log for real-mouse crossings (default 180)
  --skip-injection          Do not attempt CGEvent injection
  --port N                  Flow UDP port (default 42424)
  Token: --download-token, or env OPENLOGI_GH_TOKEN / GITHUB_TOKEN, or interactive read -s when TTY.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --download-token) TOKEN="$2"; shift 2 ;;
    --peer-address) PEER_ADDRESS="$2"; shift 2 ;;
    --peer-name) PEER_NAME="$2"; shift 2 ;;
    --flow-edge) FLOW_EDGE="$2"; shift 2 ;;
    --start-at-epoch-ms) START_AT_MS="$2"; shift 2 ;;
    --watchdog-minutes) WATCHDOG_MIN="$2"; shift 2 ;;
    --respawn-watch-sec) RESPAWN_SEC="$2"; shift 2 ;;
    --human-gate-sec) HUMAN_GATE_SEC="$2"; shift 2 ;;
    --measure-wait-sec) MEASURE_WAIT_SEC="$2"; shift 2 ;;
    --skip-injection) SKIP_INJECT=1; shift ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done
export HT_PORT="$PORT"

# ---------- restore mode ----------
if [[ "$MODE" == "restore" ]]; then
  is_root || { echo "restore needs sudo"; exit 2; }
  if [[ -f "$(state_path)" ]]; then
    load_state_env
    full_restore "manual restore mode"
  else
    echo "No saved state. Use emergency-restore.sh." >&2
    exit 1
  fi
  exit 0
fi

init_context "$(console_user)"
export HT_ACT_DISABLED_JSON='[]' HT_ACT_BACKUPS_JSON='[]'

# ---------- preflight (read-only) ----------
if [[ "$MODE" == "preflight" ]]; then
  # SSH-safe: use the invoking user (id -un / id -u). Works without GUI session / without root.
  init_context "$(/usr/bin/id -un)"
  export HT_COMMON="$DIR/common.sh"
  echo "==== PREFLIGHT (read-only; nothing changed) ===="
  echo "  note                   : safe over SSH; uses launchctl print gui/$(id -u) + print-disabled"
  echo "  elevated               : $(is_root && echo yes || echo no)"
  echo "  os                     : $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) $(uname -m)"
  echo "  invokingUser           : $(/usr/bin/id -un) (uid $(/usr/bin/id -u))"
  echo "  consoleUser            : $(console_user)"
  echo "  targetUser/uid         : $HT_TARGET_USER / $HT_TARGET_UID"
  echo "  resultLog              : $HT_RESULT"
  echo "  configDir              : $HT_CONFIG_DIR (exists=$([[ -d $HT_CONFIG_DIR ]] && echo yes || echo no))"
  echo "  stateDir(logs)         : $HT_STATE_DIR"
  echo "  OpenLogi.app           : $([[ -d $HT_APP ]] && echo present || echo absent)"
  echo "  SIP                    : $(csrutil status 2>/dev/null | head -1)"
  echo "  firewall               : $($HT_FIREWALL --getglobalstate 2>/dev/null || echo unknown)"
  echo
  preflight_print_discovery "$HT_TARGET_UID"
  echo
  if [[ -n "$ARTIFACT" ]]; then
    echo "  artifact               : $([[ -f $ARTIFACT ]] && echo "present: $ARTIFACT" || echo "MISSING: $ARTIFACT")"
  elif [[ -n "$TOKEN" ]]; then
    arch="$(uname -m)"
    aname="$HT_ARTIFACT_ARM64"; [[ "$arch" == "x86_64" ]] && aname="$HT_ARTIFACT_X86"
    echo "  artifact               : will download $aname from run $HT_RUN_ID (arch=$arch)"
  else
    echo "  artifact               : NONE (pass --artifact / --download-token / env OPENLOGI_GH_TOKEN for a real run)"
  fi
  echo
  echo "A real run (--mode run) WOULD:"
  echo "  1. Snapshot launchd/labels/procs/BTM/TCC-readable/firewall/dirs"
  echo "  2. Arm detached watchdog + LaunchDaemon BEFORE touching Options+"
  echo "  3. bootout plist stop-targets (com.logi.cp-dev-mgr, com.logi.optionsplus.updater);"
  echo "     kill LogiPluginService processes only (no bootout of application.* RunningBoard jobs)"
  echo "     (preserves print-disabled overrides exactly)"
  echo "  4. Install OpenLogi.app from DMG, open app (TCC prompts need a human)"
  echo "  5. Enable Flow / pair / write [[flow.layout]] edge=right -> Alienware / measure"
  echo "  6. Quit OpenLogi, bootstrap Options+ back, tccutil reset OpenLogi grants, keep ONLY $HT_RESULT"
  echo
  echo "Stop policy: bootout+kill (no disable/enable). Never-touch: ${HT_NEVER_TOUCH_LABELS[*]}"
  exit 0
fi

# ---------- run ----------
[[ "$MODE" == "run" ]] || { echo "Unknown mode: $MODE"; exit 2; }
is_root || { echo "run needs sudo (launchctl system domain + /Applications + LaunchDaemon)"; exit 2; }
[[ -n "$HT_TARGET_USER" && "$HT_TARGET_USER" != "root" && "$HT_TARGET_USER" != "loginwindow" ]] || {
  echo "No interactive console user. Log in graphically first."; exit 1
}

mkdir -p "$HT_WORK/suite" "$HT_WORK/backup" "$HT_WORK/dl" "$HT_USER_WORK"
# Install an independent suite copy for the watchdog.
cp -f "$DIR"/*.sh "$DIR"/*.swift "$HT_WORK/suite/" 2>/dev/null || cp -f "$DIR"/*.sh "$HT_WORK/suite/"
chmod +x "$HT_WORK/suite"/*.sh
export HT_DEADLINE_MS=$(( $(now_ms) + WATCHDOG_MIN * 60000 ))
export HT_STARTED_MS="$(now_ms)" HT_MAIN_PID=$$ HT_COMPLETED=0
: >"$HT_RESULT"

section "OpenLogi Flow HW test START (macOS)"
write_r INFO "host=$(hostname) user=$HT_TARGET_USER mode=run port=$PORT edge=$FLOW_EDGE watchdog=${WATCHDOG_MIN}min"
write_r INFO "build: run $HT_RUN_ID commit bd04518f (UNSIGNED)"
write_r WARN "Accessibility / Input Monitoring / Local Network TCC cannot be granted by this script. If not already granted, a human must approve the System Settings prompts once before crossings work."

# Discover Options+ jobs (for snapshot + restore)
discover_logi_jobs
save_state

section "PRE-SNAPSHOT"
take_snapshot "$HT_WORK/snapshot-pre.json"
write_r INFO "Pre-snapshot saved: $HT_WORK/snapshot-pre.json"

section "ARM WATCHDOG"
install_watchdog "$HT_DEADLINE_MS" "$HT_WORK/suite"

# Backup pre-existing OpenLogi dirs
for d in "$HT_CONFIG_DIR" "$HT_STATE_DIR" "$HT_DATA_DIR"; do
  if [[ -d "$d" ]]; then
    b="$HT_WORK/backup/$(printf '%s' "$d" | shasum -a 256 | awk '{print $1}')"
    mkdir -p "$b"
    /usr/bin/ditto "$d" "$b"
    export HT_ACT_BACKUPS_JSON
    HT_ACT_BACKUPS_JSON="$(python3 -c 'import json,os,sys; a=json.loads(os.environ.get("HT_ACT_BACKUPS_JSON","[]")); a.append(sys.argv[1]+"|"+sys.argv[2]); print(json.dumps(a))' "$d" "$b")"
    write_r WARN "Pre-existing OpenLogi dir backed up: $d"
  fi
done
save_state

# Resolve artifact
section "ARTIFACT"
resolve_artifact() {
  if [[ -n "$ARTIFACT" ]]; then
    [[ -f "$ARTIFACT" ]] || { write_r ERROR "Artifact not found: $ARTIFACT"; return 1; }
    echo "$ARTIFACT"; return 0
  fi
  if [[ -z "$TOKEN" ]]; then
    TOKEN="${OPENLOGI_GH_TOKEN:-${GITHUB_TOKEN:-}}"
  fi
  if [[ -z "$TOKEN" && -t 0 ]]; then
    printf 'GitHub PAT (input hidden): ' >&2
    read -r -s TOKEN
    printf '\n' >&2
  fi
  [[ -n "$TOKEN" ]] || { write_r ERROR "Provide --artifact, --download-token, env OPENLOGI_GH_TOKEN, or interactive token"; return 1; }
  local arch aname api art url dest
  arch="$(uname -m)"
  aname="$HT_ARTIFACT_ARM64"; [[ "$arch" == "x86_64" ]] && aname="$HT_ARTIFACT_X86"
  api="https://api.github.com/repos/$HT_REPO/actions/runs/$HT_RUN_ID/artifacts"
  art="$(curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$api" \
    | python3 -c 'import json,sys; name=sys.argv[1]; d=json.load(sys.stdin); a=next((x for x in d.get("artifacts",[]) if x["name"]==name),None); print(a["archive_download_url"] if a else "")' "$aname")"
  [[ -n "$art" ]] || { write_r ERROR "Artifact $aname not found in run $HT_RUN_ID"; return 1; }
  dest="$HT_WORK/dl/artifact.zip"
  curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -o "$dest" "$art"
  echo "$dest"
}
OUTER="$(resolve_artifact)" || { full_restore "artifact failure"; exit 1; }
# Wipe token ASAP (artifact under $HT_WORK/dl is deleted on cleanup).
TOKEN=""
unset TOKEN OPENLOGI_GH_TOKEN GITHUB_TOKEN || true
write_r INFO "Artifact: $OUTER sha256=$(shasum -a 256 "$OUTER" | awk '{print $1}')"

# Extract DMG
DMG=""
case "$OUTER" in
  *.dmg) DMG="$OUTER" ;;
  *.zip)
    unzip -o -q "$OUTER" -d "$HT_WORK/dl/unz"
    DMG="$(find "$HT_WORK/dl/unz" -name '*.dmg' | head -1)"
    # Nested zip? (Actions sometimes wraps)
    if [[ -z "$DMG" ]]; then
      IZ="$(find "$HT_WORK/dl/unz" -name '*.zip' | head -1 || true)"
      if [[ -n "$IZ" ]]; then
        unzip -o -q "$IZ" -d "$HT_WORK/dl/unz2"
        DMG="$(find "$HT_WORK/dl/unz2" -name '*.dmg' | head -1)"
      fi
    fi
    ;;
esac
[[ -n "$DMG" && -f "$DMG" ]] || { write_r ERROR "No .dmg found in artifact"; full_restore "bad artifact"; exit 1; }
write_r INFO "DMG: $DMG sha256=$(shasum -a 256 "$DMG" | awk '{print $1}')"

# Stop Options+ BEFORE installing/opening OpenLogi (HID++ fight).
stop_options_plus
sleep 2
watch_respawn "$RESPAWN_SEC"
save_state

section "INSTALL OpenLogi.app"
MNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk '/\/Volumes\//{print $NF; exit}')"
[[ -n "$MNT" ]] || { write_r ERROR "hdiutil attach failed"; full_restore "attach failed"; exit 1; }
write_r INFO "Mounted at $MNT"
# Copy app (overwrite if we are replacing a previous test install; never delete a pre-existing app we didn't create — HT_APP_EXISTED tracks that).
if [[ "$HT_APP_EXISTED" == "1" ]]; then
  write_r WARN "OpenLogi.app already existed — leaving it; mounting DMG for CLI/hash only. (Re-test with a clean machine or remove the app first if you need this exact build.)"
else
  /usr/bin/ditto "$MNT/OpenLogi.app" "$HT_APP"
  /usr/bin/xattr -dr com.apple.quarantine "$HT_APP" || true
  write_r INFO "Installed $HT_APP (quarantine cleared)"
fi
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force || true
codesign -dv "$HT_APP" 2>&1 | while IFS= read -r L; do write_r INFO "codesign: $L"; done || true

section "START OpenLogi (user session)"
# Set OPENLOGI_LOG for the user domain so the agent picks it up.
launchctl asuser "$HT_TARGET_UID" launchctl setenv OPENLOGI_LOG "$HT_LOG_FILTER" || true
launchctl asuser "$HT_TARGET_UID" /usr/bin/open -a "$HT_APP" || true
sleep 8
if ! pgrep -x openlogi-agent >/dev/null 2>&1; then
  # Try opening the agent helper directly.
  launchctl asuser "$HT_TARGET_UID" /usr/bin/open -g -a "$HT_AGENT_BUNDLE" || true
  sleep 5
fi
if pgrep -x openlogi-agent >/dev/null 2>&1; then
  write_r INFO "openlogi-agent running: $(pgrep -x openlogi-agent | tr '\n' ' ')"
else
  write_r ERROR "openlogi-agent not running. Gatekeeper / TCC may be blocking. A human must open System Settings → Privacy & Security → Open Anyway / grant Accessibility + Input Monitoring + Local Network."
fi

section "AGENT STATUS / DEVICES"
# api status reports accessibility_granted / input_monitoring_granted
STAT="$(cli api status 2>/dev/null || true)"
write_r INFO "api status: $STAT"
DEVS="$(cli api devices 2>/dev/null || true)"
write_r INFO "api devices: $DEVS"
if ! printf '%s' "$STAT" | grep -q '"accessibility_granted": *true'; then
  write_r WARN "accessibility_granted is not true — edge detection will not work until a human grants Accessibility to OpenLogi Agent."
fi
if ! printf '%s' "$STAT" | grep -q '"input_monitoring_granted": *true'; then
  write_r WARN "input_monitoring_granted is not true — HID++ / Bluetooth device access needs Input Monitoring."
fi

# Coordination
if [[ "$START_AT_MS" -gt 0 ]]; then
  NOW="$(now_ms)"
  WAIT=$(( START_AT_MS - NOW ))
  if [[ "$WAIT" -gt 0 ]]; then
    MAX_WAIT=$(( HT_DEADLINE_MS - NOW - HT_CLEANUP_RESERVE_SEC * 1000 ))
    if [[ "$WAIT" -gt "$MAX_WAIT" ]]; then WAIT=$MAX_WAIT; fi
    if [[ "$WAIT" -lt 0 ]]; then WAIT=0; fi
    write_r INFO "Coordinated start: waiting ${WAIT} ms until T0=$(fmt_ms "$START_AT_MS")"
    sleep "$(python3 -c "print($WAIT/1000.0)")"
  fi
fi

section "FLOW ENABLE / PAIR"
write_r INFO "flow enable: $(cli flow enable 2>&1 || true)"
if [[ -n "$PEER_ADDRESS" ]]; then
  write_r INFO "flow pair-start $PEER_ADDRESS: $(cli flow pair-start "$PEER_ADDRESS" 2>&1 || true)"
  sleep 3
  write_r INFO "flow status: $(cli flow status 2>&1 || true)"
  write_r WARN "SAS confirmation is a HUMAN step: verify the 6-digit code matches, then run \`openlogi flow confirm\` on BOTH machines. This script does NOT auto-confirm."
else
  write_r WARN "No --peer-address: pairing (incl. SAS) must be done manually. See RUNBOOK-Jay.md."
fi

if [[ "${HUMAN_GATE_SEC:-0}" -gt 0 ]]; then
  section "HUMAN GATE (${HUMAN_GATE_SEC}s): confirm SAS on BOTH machines; grant Accessibility / Input Monitoring / Local Network if prompted"
  write_r WARN "Sleeping ${HUMAN_GATE_SEC}s — run: openlogi flow confirm (both hosts). Then prepare the real mouse."
  sleep "$HUMAN_GATE_SEC"
fi

section "FLOW LAYOUT (GM: Mac Mini is LEFT of Jay-Alienware)"
write_r INFO "Defaults: this host edge=$FLOW_EDGE -> peer (Alienware). Override with --flow-edge / --peer-name. Schema: [[flow.layout]] (openlogi-core config/flow.rs)."
# Existing user config was backed up with the config dir; cleanup restores it.
apply_flow_layout_and_reload "$FLOW_EDGE" "$PEER_NAME" "$PORT" || true

section "FLOW CROSSING MEASUREMENT"
MEASURE_START="$(now_ms)"
if [[ "$SKIP_INJECT" -eq 1 ]]; then
  write_r WARN "Injection skipped. Move the real mouse across Mac RIGHT edge to Alienware (and back from Alienware LEFT) several times; waiting ${MEASURE_WAIT_SEC}s."
  sleep "$MEASURE_WAIT_SEC"
else
  write_r WARN "Attempting CGEvent injection. Prefer a real mouse move. Accessibility for the injector is also required."
  INJ_OUT="$HT_WORK/inject.json"
  /bin/bash "$HT_WORK/suite/inject.sh" --edge "$FLOW_EDGE" --out "$INJ_OUT" || true
  [[ -f "$INJ_OUT" ]] && write_r INFO "Injection probe: $(cat "$INJ_OUT")"
  write_r WARN "Now move the REAL mouse across Mac RIGHT edge (and back from Alienware LEFT) several times; waiting up to ${MEASURE_WAIT_SEC}s."
  END=$(( $(date +%s) + MEASURE_WAIT_SEC ))
  while (( $(date +%s) < END )); do
    if parse_agent_events "$MEASURE_START" 2>/dev/null | grep -q 'handoff\|edge\|rejected\|timed out'; then
      break
    fi
    sleep 2
  done
fi

section "FLOW EVENTS (from agent log)"
parse_agent_events "$MEASURE_START" 2>/dev/null | while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    EVENT) write_r EVENT "$a $b \"$c\" $d" ;;
    TIMING) write_r TIMING "$a" ;;
  esac
done || write_r WARN "No Flow events parsed (no crossing, or agent log empty / wrong filter)."
write_r INFO "Final flow status: $(cli flow status 2>&1 || true)"

# Always restore
full_restore "main run end" || write_r ERROR "full_restore reported errors"
section "DONE"
write_r INFO "Result log: $HT_RESULT"
