#!/usr/bin/env bash
# OpenLogi Flow hardware test for macOS (Mac Mini 192.168.1.8, user jayboy137). Writes ~/OpenLogi-test-result.log.
#   sudo /bin/bash run-openlogi-flow-test.sh --mode preflight|run|restore [options]
# START ORDER: Windows FIRST. Start this only after the Windows window shows green "READY: listening on UDP 42424".
# Pairing: Windows = responder (`openlogi flow listen`), this Mac = initiator (`flow pair-start 192.168.1.9:42424`).
# Every human step waits for Enter / skip / abort (no countdowns). A lease watchdog (LaunchDaemon + detached loop)
# restores Options+ only if this script dies, hangs past its lease, or passes the absolute hard cap.
# shellcheck disable=SC2317,SC1111  # check/trap functions are invoked indirectly; curly quotes are literal UI text
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

MODE="preflight"; ARTIFACT=""; TOKEN=""; PEER_ADDRESS="192.168.1.9"; PEER_NAME=""; FLOW_EDGE="right"
RESPAWN_SEC=20; WITH_INJECT=0; PORT=42424; PAIR_ROLE="initiate"
usage() {
  cat <<USAGE
Usage: sudo /bin/bash $0 --mode preflight|run|restore [options]
  --artifact PATH           Local artifact (.zip wrapping .dmg, or .dmg)
  --download-token TOKEN    (discouraged: visible in shell history) - without it the script asks (hidden input)
  --peer-address HOST       Windows host for pair-start (default 192.168.1.9; port $PORT is added)
  --pair-role initiate|skip Default initiate (Windows listens)
  --peer-name NAME          [[flow.layout]].peer override (normally the paired name)
  --flow-edge EDGE          default right (Mac Mini is LEFT of Jay-Alienware)
  --lease-minutes N         watchdog lease, renewed every minute while the script is alive (default $HT_LEASE_MIN)
  --hard-cap-minutes N      absolute limit; restore happens after this no matter what (default $HT_HARDCAP_MIN)
  --respawn-watch-sec N     watch Options+ respawn after stopping it (default 20)
  --with-injection          also run the CGEvent injection probe (needs an extra Accessibility grant; off by default)
  --port N                  Flow UDP port (default 42424)
  Deprecated (run 1, ignored): --watchdog-minutes (= --lease-minutes), --human-gate-sec, --measure-wait-sec,
                               --start-at-epoch-ms, --skip-injection
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --download-token) TOKEN="$2"; shift 2 ;;
    --peer-address) PEER_ADDRESS="$2"; shift 2 ;;
    --pair-role) PAIR_ROLE="$2"; shift 2 ;;
    --peer-name) PEER_NAME="$2"; shift 2 ;;
    --flow-edge) FLOW_EDGE="$2"; shift 2 ;;
    --lease-minutes|--watchdog-minutes) HT_LEASE_MIN="$2"; shift 2 ;;
    --hard-cap-minutes) HT_HARDCAP_MIN="$2"; shift 2 ;;
    --respawn-watch-sec) RESPAWN_SEC="$2"; shift 2 ;;
    --with-injection) WITH_INJECT=1; shift ;;
    --skip-injection) WITH_INJECT=0; shift ;;
    --human-gate-sec|--measure-wait-sec|--start-at-epoch-ms) echo "NOTE: $1 is ignored in run 2 (gates wait for Enter)" >&2; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done
export HT_PORT="$PORT" HT_LEASE_MIN HT_HARDCAP_MIN
case "$PEER_ADDRESS" in *:*) PEER_TARGET="$PEER_ADDRESS" ;; *) PEER_TARGET="$PEER_ADDRESS:$PORT" ;; esac
al_load || exit 2

show_failed() {
  banner red "FAILED  FAILED  FAILED  (Mac mini .8)" "原因: $1" \
    ">> 在 Windows (Alienware .9) 窗口输入 abort 然后回车, 让它也恢复。" \
    ">> 本窗口现在自动恢复 Options+ 并清理(不要关窗口, 等它显示 DONE)。"
}

# ---------------------------------------------------------------- restore mode
if [[ "$MODE" == "restore" ]]; then
  is_root || { echo "restore needs sudo"; exit 2; }
  [[ -f "$(state_path)" ]] || { echo "No saved state. Use emergency-restore.sh." >&2; exit 1; }
  load_state_env
  HT_USER_WORK="$HT_HOME/Library/Application Support/OpenLogi-hwtest"
  if full_restore "manual restore mode"; then exit 0; else exit 3; fi
fi

# ---------------------------------------------------------------- preflight (read-only)
if [[ "$MODE" == "preflight" ]]; then
  init_context "$(console_user)"
  echo "==== PREFLIGHT (read-only; nothing changed) ===="
  echo "  allowlist              : $HT_ALLOWLIST"
  echo "  elevated               : $(is_root && echo yes || echo no)"
  echo "  os                     : $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) $(uname -m)"
  echo "  bash                   : $BASH_VERSION"
  echo "  python3                : $(python3 -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || echo MISSING)"
  echo "  consoleUser / uid      : $HT_TARGET_USER / $HT_TARGET_UID"
  echo "  resultLog              : $HT_RESULT"
  echo "  configDir              : $HT_CONFIG_DIR (exists=$([[ -d $HT_CONFIG_DIR ]] && echo yes || echo no))"
  echo "  OpenLogi.app           : $([[ -d $HT_APP ]] && echo present || echo absent)"
  echo "  leftover state (run 1) : $([[ -f "$(state_path)" ]] && echo "YES -> run emergency-restore.sh first" || echo no)"
  echo "  watchdog plist         : $([[ -f $HT_WATCHDOG_PLIST ]] && echo "PRESENT -> run emergency-restore.sh first" || echo absent)"
  for v in $(al_get env-unset); do
    cur="$(as_user launchctl getenv "$v" 2>/dev/null || true)"
    echo "  launchd env $v : ${cur:-<unset>}$([[ -n $cur ]] && echo '   <-- run-1 leftover; emergency-restore.sh clears it')"
  done
  echo "  firewall               : $($HT_FIREWALL --getglobalstate 2>/dev/null || echo unknown)"
  echo "  peer                   : $PEER_TARGET (ping: $(/sbin/ping -c 1 -t 2 "${PEER_ADDRESS%%:*}" >/dev/null 2>&1 && echo reachable || echo 'no reply - Windows often blocks ping; not an error'))"
  echo "  Options+ GUI bundle id : $(gui_bundle_id)"
  echo
  echo "  --- allowlisted launchd jobs (exact) ---"
  while IFS=$'\t' read -r d l p a; do
    printf '  %-45s %-8s actions=%s plist=%s\n' "$d/$l" "$(lctl_loaded "$d" "$l" && echo loaded || echo absent)" "$a" "${p:-<none>}"
  done < <(al_get launchd-all)
  echo "  never touched: $(al_get never-touch | tr '\n' ' ')"
  echo "  --- observed Logitech launchd labels (info only; anything not listed above is never touched) ---"
  { list_logi_labels "gui/$HT_TARGET_UID" | sed 's/^/  gui: /'; list_logi_labels system | sed 's/^/  system: /'; } || true
  echo "  --- Options+ processes matching allowlist (exact path) ---"
  list_optionsplus_procs | sed 's/^/  PROC /' || true
  MISM="$(list_optionsplus_path_mismatch || true)"
  if [[ -n "$MISM" ]]; then
    echo "  --- !!! processes with an allowlisted NAME but a different PATH (a run would refuse to start) ---"
    printf '%s\n' "$MISM" | sed 's/^/  MISMATCH /'
  fi
  echo
  if [[ -n "$ARTIFACT" ]]; then
    if [[ -e "$ARTIFACT" ]]; then
      echo "  artifact: present: $ARTIFACT"
      PF_TMP="$(mktemp -d /tmp/ol-hwtest-pf.XXXXXX)"
      if PF_DMG="$(artifact_to_dmg "$ARTIFACT" "$PF_TMP")" && [[ -n "$PF_DMG" ]]; then
        echo "  dmg in artifact: $(basename "$PF_DMG")"
        PF_MNT="$(hdiutil attach -nobrowse -readonly "$PF_DMG" 2>/dev/null | awk -F '\t' '/\/Volumes\//{print $NF; exit}')"
        if [[ -n "$PF_MNT" ]]; then
          check_build_signature "$PF_MNT/OpenLogi.app" || true
          hdiutil detach "$PF_MNT" -quiet 2>/dev/null || hdiutil detach "$PF_MNT" -force 2>/dev/null || true
        else echo "  !! could not mount the dmg (signature not checked)"; fi
      else echo "  !! no .dmg found in $ARTIFACT"; fi
      rm -rf "$PF_TMP"
    else echo "  artifact: MISSING: $ARTIFACT"; fi
  else echo "  artifact: will download $( [[ "$(uname -m)" == x86_64 ]] && echo "$HT_ARTIFACT_X86" || echo "$HT_ARTIFACT_ARM64") from run $HT_RUN_ID (token asked with hidden input)"; fi
  echo
  echo "A real run (--mode run) WOULD: snapshot -> lease watchdog (${HT_LEASE_MIN} min lease, ${HT_HARDCAP_MIN} min hard cap)"
  echo "  -> bootout allowlisted Options+ jobs + kill exact Options+ paths -> install /Applications/OpenLogi.app -> TCC gates"
  echo "  -> flow enable -> pair-start $PEER_TARGET -> SAS gate -> layout edge=$FLOW_EDGE -> measurement gate -> restore -> diff"
  if [[ -n "$MISM" ]]; then echo "PREFLIGHT RESULT: BLOCKED (allowlist path mismatch) - send this output to GM"; exit 4; fi
  echo "PREFLIGHT RESULT: OK"
  exit 0
fi

# ---------------------------------------------------------------- run
[[ "$MODE" == "run" ]] || { echo "Unknown mode: $MODE" >&2; exit 2; }
is_root || { echo "run needs sudo:  sudo /bin/bash $0 --mode run" >&2; exit 2; }
init_context "$(console_user)"
[[ -n "$HT_TARGET_USER" && "$HT_TARGET_USER" != root && "$HT_TARGET_USER" != loginwindow ]] || { show_failed "No logged-in console user (log in on the Mac screen first)."; exit 1; }
if [[ -f "$(state_path)" || -f "$HT_WATCHDOG_PLIST" ]]; then
  show_failed "Leftover state from an earlier run ($(state_path) / watchdog plist). Run: sudo /bin/bash emergency-restore.sh   then start again."
  exit 1
fi
MISM="$(list_optionsplus_path_mismatch || true)"
if [[ -n "$MISM" ]]; then
  show_failed "Options+ process path(s) not in allowlist.json: $(printf '%s' "$MISM" | tr '\n' ';'). Nothing was changed."
  exit 1
fi
HT_USER_WORK="$HT_HOME/Library/Application Support/OpenLogi-hwtest"
: >"$HT_RESULT"; chown "$HT_TARGET_USER" "$HT_RESULT" 2>/dev/null || true

# Gate M0 (nothing changed yet): Windows must already be READY.
gate "GATE M0 (Mac .8): Windows 端准备好了吗?" "gate-m0" 5 0 "" "" -- \
  "看 Alienware (.9) 上的 PowerShell 窗口:" \
  "  显示绿色 'READY: listening on UDP 42424'  -> 在这里按回车继续。" \
  "  显示红色 FAILED                          -> 输入 abort 回车 (Mac 还什么都没改)。" \
  "  还没启动 Windows 脚本                     -> 先去 Windows 启动(RUNBOOK 第 3 步), 等 READY 再回来按回车。"

# ---- from here on things change: arm restore-on-exit
HT_ARMED=0
on_exit() {
  local rc=$?
  set +e
  trap '' INT TERM
  trap - EXIT
  if [[ "${HT_ARMED:-0}" == 1 ]]; then
    if [[ "$HT_ABORTED" == 1 ]]; then
      banner yellow "已中止 (abort / Ctrl+C)。正在自动恢复, 不要关窗口, 等到出现 DONE。" "如果 Windows 端还在运行: 在 Windows 窗口输入 abort 回车。"
    elif [[ $rc -ne 0 ]]; then
      show_failed "脚本出错 (exit $rc) - 见上面的 ERROR 行"
    fi
    local ok=1
    full_restore "main end (exit $rc)" || ok=0
    local col=green; [[ $ok -eq 1 && "$HT_DIFF_RESULT" != FAIL && $rc -eq 0 ]] || col=red
    banner "$col" "DONE (Mac). 恢复=$([[ $ok -eq 1 ]] && echo 全部成功 || echo '有错误, 见 RESTORE SUMMARY'); 状态对比=$HT_DIFF_RESULT" "结果日志: $HT_RESULT"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'ht_abort "Ctrl+C / TERM"' INT TERM

mkdir -p "$HT_WORK/suite" "$HT_WORK/backup" "$HT_WORK/dl"
chmod 755 "$HT_WORK"
cp -f "$DIR"/*.sh "$DIR"/inject.swift "$HT_WORK/suite/" 2>/dev/null || cp -f "$DIR"/*.sh "$HT_WORK/suite/"
cp -f "$HT_ALLOWLIST" "$HT_WORK/suite/allowlist.json"
chmod 755 "$HT_WORK/suite"/*.sh
HT_HARDCAP_MS=$(( $(now_ms) + HT_HARDCAP_MIN * 60000 )); export HT_HARDCAP_MS
record_optionsplus_prestate   # BEFORE arming restore: unknown GUI/plugin state must never look like "was closed"
save_state
lease_renew start
HT_ARMED=1

section "OpenLogi Flow HW test START (macOS, run 2)"
write_r INFO "host=$(hostname) user=$HT_TARGET_USER port=$PORT edge=$FLOW_EDGE peer=$PEER_TARGET lease=${HT_LEASE_MIN}min hardcap=${HT_HARDCAP_MIN}min allowlist=$HT_ALLOWLIST"
write_r INFO "build: run $HT_RUN_ID commit bd04518f (UNSIGNED)"

section "PRE-SNAPSHOT"
write_r INFO "Pre-snapshot: $(take_snapshot "$HT_WORK/snapshot-pre.json") items -> $HT_WORK/snapshot-pre.json"

section "ARM WATCHDOG (lease)"
install_watchdog
lease_renew watchdog-armed
write_r INFO "$(lease_status)"

for d in "$HT_CONFIG_DIR" "$HT_STATE_DIR" "$HT_DATA_DIR"; do
  if [[ -d "$d" ]]; then
    b="$HT_WORK/backup/$(printf '%s' "$d" | shasum -a 256 | awk '{print $1}')"
    mkdir -p "$b"; /usr/bin/ditto "$d" "$b"
    HT_ACT_BACKUPS_JSON="$(python3 -c 'import json,os,sys; a=json.loads(os.environ.get("HT_ACT_BACKUPS_JSON","[]")); a.append(sys.argv[1]+"|"+sys.argv[2]); print(json.dumps(a))' "$d" "$b")"
    export HT_ACT_BACKUPS_JSON
    write_r WARN "Pre-existing OpenLogi dir backed up: $d"
  fi
done
save_state

section "ARTIFACT"
resolve_artifact() {
  if [[ -n "$ARTIFACT" ]]; then
    [[ -f "$ARTIFACT" || -d "$ARTIFACT" ]] || { write_r ERROR "Artifact not found: $ARTIFACT"; return 1; }
    echo "$ARTIFACT"; return 0
  fi
  local tok="${TOKEN:-${OPENLOGI_GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  if [[ -z "$tok" && -t 0 ]]; then
    printf '粘贴 GitHub PAT 后回车 (输入不显示): ' >&2
    read -r -s tok; printf '\n' >&2
  fi
  [[ -n "$tok" ]] || { write_r ERROR "No artifact and no token"; return 1; }
  local aname api art dest
  aname="$HT_ARTIFACT_ARM64"; [[ "$(uname -m)" == x86_64 ]] && aname="$HT_ARTIFACT_X86"
  api="https://api.github.com/repos/$HT_REPO/actions/runs/$HT_RUN_ID/artifacts"
  # token goes to curl via a stdin config (-K -), never on the command line / in ps
  art="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -fsSL -K - -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$api" \
    | python3 -c 'import json,sys; n=sys.argv[1]; d=json.load(sys.stdin); a=next((x for x in d.get("artifacts",[]) if x["name"]==n),None); print(a["archive_download_url"] if a else "")' "$aname")"
  [[ -n "$art" ]] || { write_r ERROR "Artifact $aname not found in run $HT_RUN_ID (token scope? needs Actions: Read-only on JayHome137/OpenLogi)"; return 1; }
  dest="$HT_WORK/dl/artifact.zip"
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -fsSL -K - -o "$dest" "$art"
  tok=""
  echo "$dest"
}
OUTER="$(resolve_artifact)"
TOKEN=""; unset TOKEN OPENLOGI_GH_TOKEN GITHUB_TOKEN || true
[[ -f "$OUTER" ]] && write_r INFO "Artifact: $OUTER sha256=$(shasum -a 256 "$OUTER" | awk '{print $1}')"
DMG="$(artifact_to_dmg "$OUTER" "$HT_WORK/dl")" || true
[[ -n "$DMG" && -f "$DMG" ]] || { write_r ERROR "No .dmg found in artifact"; exit 1; }
write_r INFO "DMG: $DMG sha256=$(shasum -a 256 "$DMG" | awk '{print $1}')"
lease_renew artifact-ready

stop_options_plus
sleep 2
write_r INFO "respawn rounds: $(watch_respawn "$RESPAWN_SEC")"
lease_renew optionsplus-stopped

section "INSTALL OpenLogi.app"
MNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F '\t' '/\/Volumes\//{print $NF; exit}')"
[[ -n "$MNT" ]] || { write_r ERROR "hdiutil attach failed"; exit 1; }
if [[ "$HT_APP_EXISTED" == 1 ]]; then
  write_r WARN "OpenLogi.app already existed - left untouched (it will NOT be the tested build)."
else
  /usr/bin/ditto "$MNT/OpenLogi.app" "$HT_APP"
  /usr/bin/xattr -dr com.apple.quarantine "$HT_APP" || true
  write_r INFO "Installed $HT_APP (quarantine cleared)"
fi
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force || true
codesign -dv "$HT_APP" 2>&1 | while IFS= read -r L; do write_r INFO "codesign: $L"; done || true
check_build_signature "$HT_APP" | while IFS= read -r L; do write_r INFO "$L"; done || true
lease_renew installed

section "START OpenLogi (user session)"
launchctl asuser "$HT_TARGET_UID" launchctl setenv OPENLOGI_LOG "$HT_LOG_FILTER" || true
as_user /usr/bin/open -a "$HT_APP" || true
agent_check() {
  local p
  p="$(list_openlogi_procs | awk -F '\t' '$2 == "openlogi-agent" {print $1}' | tr '\n' ' ')"
  if [[ -n "$p" ]]; then echo "openlogi-agent 运行中 pid=$p"; return 0; fi
  echo "openlogi-agent 没有在运行"; return 1
}
start_agent_again() { as_user /usr/bin/open -a "$HT_APP" || true; sleep 3; as_user /usr/bin/open -g -a "$HT_AGENT_BUNDLE" || true; sleep 5; }
for _ in 1 2 3 4 5 6 7 8 9 10; do agent_check >/dev/null && break; sleep 1; done
if ! agent_check >/dev/null; then start_agent_again; fi
while ! agent_check >/dev/null; do
  gate "GATE M1 (Mac .8): OpenLogi Agent 没有启动" "gate-m1" 5 1 "retry" agent_check -- \
    "可能被 macOS 拦截(未签名)。在 Mac 屏幕上:" \
    "  1) 如果弹窗 '无法打开 “OpenLogi”' -> 点 '完成'(不要点 '移到废纸篓')。" \
    "  2) 打开  苹果菜单 > 系统设置 > 隐私与安全性, 滚到最下面 '安全性' 一栏," \
    "     看到 '已阻止 “OpenLogi …” 以保护 Mac' -> 点 '仍要打开' -> 输入 Mac 登录密码 -> 再点 '仍要打开'。" \
    "  3) 回到这个终端输入 retry 回车。脚本会重新启动 OpenLogi。(约 1-2 分钟)"
  [[ "$GATE_RESULT" == retry ]] && start_agent_again
  [[ "$GATE_RESULT" == skip ]] && break
done
agent_check >/dev/null || { write_r ERROR "openlogi-agent not running"; exit 1; }
write_r INFO "$(agent_check)"
lease_renew agent-up

section "PERMISSIONS (TCC)"
tcc_check() {
  local s
  s="$(cli api status 2>/dev/null || true)"
  printf '%s' "$s" | python3 -c '
import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: print("agent 还没响应 (api status 无输出)"); sys.exit(1)
a = d.get("accessibility_granted") is True; i = d.get("input_monitoring_granted") is True
yn = lambda b: "已允许" if b else "未允许"
print("辅助功能=%s  输入监控=%s  hook=%s" % (yn(a), yn(i), d.get("hook_installed")))
sys.exit(0 if (a and i) else 1)'
}
restart_agent() {
  local pid
  for pid in $(list_openlogi_procs | awk -F '\t' '$2 == "openlogi-agent" {print $1}'); do safe_kill_pid "$pid" "restart after TCC grant" ol-procs || true; done
  sleep 3
  agent_check >/dev/null || start_agent_again
}
AGB="/Applications/OpenLogi.app/Contents/Library/LoginItems/OpenLogi Agent.app"
while ! tcc_check >/dev/null; do
  gate "GATE M2 (Mac .8): 给 OpenLogi Agent 授权 (输入监控 + 辅助功能)" "gate-m2-tcc" 5 1 "restart" tcc_check -- \
    "在 Mac 屏幕: 苹果菜单 > 系统设置 > 隐私与安全性。每一项都这样做 (约 3-5 分钟):" \
    "  A) 点 '输入监控'  B) 点 '辅助功能'" \
    "     列表里有 'OpenLogi Agent' -> 打开它右边的开关 (会要密码或指纹)。" \
    "     列表里没有 -> 点列表下面的 '+' -> 在弹出的选文件窗口按 Command+Shift+G -> 粘贴下面这一行 -> 回车 -> 点 '打开':" \
    "       $AGB" \
    "     如果弹窗问 '退出并重新打开' -> 点 '稍后'。" \
    "  然后回到这个终端输入 restart 回车(重启 agent 让授权生效), 下面状态变成 已允许/已允许 就自动继续。" \
    "  (本地网络 稍后配对时会弹窗 '允许 “OpenLogi Agent” 查找本地网络上的设备' -> 点 '允许'。)"
  [[ "$GATE_RESULT" == restart ]] && restart_agent
  [[ "$GATE_RESULT" == skip ]] && break
done
write_r INFO "TCC: $(tcc_check || true)"
write_r INFO "api devices: $(cli api devices 2>/dev/null | tr '\n' ' ' || true)"
lease_renew tcc-done

section "FLOW ENABLE"
write_r INFO "flow enable: $(cli flow enable 2>&1 | tr '\n' ' ' || true)"

section "FLOW PAIRING (Mac = initiator -> $PEER_TARGET)"
PAIRED_NAME=""
IFS=$'\t' read -r FS_PH FS_SAS FS_PEER _ _ FS_FAIL FS_N FS_P0 <<<"$(flow_state)"
if [[ "${FS_N:-0}" -gt 0 ]]; then PAIRED_NAME="$FS_P0"; write_r INFO "Already paired with $PAIRED_NAME - pairing skipped"; fi
PAIR_WAIT_START="$(date +%s)"
pair_wait_check() {
  local ph sas peer lc pc fail n p0 out el
  IFS=$'\t' read -r ph sas peer lc pc fail n p0 <<<"$(flow_state)"
  if [[ "$ph" == Prompted ]]; then echo "已连上 Windows, 配对码 $(fmt_sas "$sas")"; return 0; fi
  if [[ "${n:-0}" -gt 0 && "$ph" != Connecting ]]; then echo "already paired with $p0"; return 0; fi
  if [[ "$ph" == Connecting ]]; then echo "正在连接 $PEER_TARGET ..."; return 1; fi
  out="$(cli flow pair-start "$PEER_TARGET" 2>&1 | tr '\n' ' ' || true)"
  IFS=$'\t' read -r ph sas peer lc pc fail n p0 <<<"$(flow_state)"
  if [[ "$ph" == Prompted ]]; then echo "已连上 Windows, 配对码 $(fmt_sas "$sas")"; return 0; fi
  el=$(( $(date +%s) - PAIR_WAIT_START ))
  if [[ $el -ge 600 ]]; then
    echo "已经 $((el / 60)) 分钟连不上 $PEER_TARGET ($out$fail)。请看 Windows 窗口: 还显示 READY 吗? 是否 FAILED? 继续等就不用动; 要放弃输入 abort"
  else
    echo "连不上 $PEER_TARGET (${el}s): ${out}${fail}  -> 每 10 秒自动重试。请确认 Windows 窗口显示 READY。"
  fi
  return 1
}
sas_check() {
  local ph sas peer lc pc fail n p0
  IFS=$'\t' read -r ph sas peer lc pc fail n p0 <<<"$(flow_state)"
  if [[ "$ph" == Paired || ( "${n:-0}" -gt 0 && "$ph" != Prompted ) ]]; then echo "配对完成: ${peer:-$p0}"; return 0; fi
  if [[ "$ph" == Failed ]]; then echo "FAILED: $fail"; return 0; fi
  echo "本机已确认=$lc  Windows已确认=$pc"
  return 1
}
while [[ -z "$PAIRED_NAME" && "$PAIR_ROLE" != skip ]]; do
  lease_renew pairing
  PAIR_WAIT_START="$(date +%s)"
  gate "GATE M3 (Mac .8): 连接 Windows 并发起配对" "gate-m3-peer" 10 1 "" pair_wait_check -- \
    "脚本每 10 秒自动对 $PEER_TARGET 发起配对, 不用按键。" \
    "如果 Mac 屏幕弹窗 '允许 “OpenLogi Agent” 查找并连接到本地网络上的设备?' -> 点 '允许'。" \
    "  (如果以前点过 '不允许': 系统设置 > 隐私与安全性 > 本地网络 -> 打开 OpenLogi Agent 的开关)" \
    "Windows 窗口必须显示 READY。如果 Windows 显示 FAILED: 在这里输入 abort 回车。"
  [[ "$GATE_RESULT" == skip ]] && break
  OUTCOME=""
  while :; do
    IFS=$'\t' read -r FS_PH FS_SAS FS_PEER _ _ FS_FAIL FS_N FS_P0 <<<"$(flow_state)"
    gate "GATE M4 (两台机器): 核对配对码  $(fmt_sas "$FS_SAS")" "gate-m4-sas" 2 1 "y n" sas_check -- \
      "本窗口的配对码: $(fmt_sas "$FS_SAS")    对方名字: $FS_PEER" \
      "看 Windows 窗口里的 6 位码, 和上面这个一模一样吗?" \
      "  一样: 在【本窗口】输入 y 回车, 并在【Windows 窗口】也输入 y 回车 (两边都要)。" \
      "  不一样: 输入 n 回车 (拒绝, 然后重试)。" \
      "配对码出现后 120 秒内两边都要确认, 否则超时, 脚本会让你重试。"
    case "$GATE_RESULT" in
      y) write_r INFO "flow confirm: $(cli flow confirm 2>&1 | tr '\n' ' ' || true)"; continue ;;
      n) write_r WARN "flow reject: $(cli flow reject 2>&1 | tr '\n' ' ' || true)"; OUTCOME=failed; break ;;
      skip) OUTCOME=skip; break ;;
    esac
    IFS=$'\t' read -r FS_PH FS_SAS FS_PEER _ _ FS_FAIL FS_N FS_P0 <<<"$(flow_state)"
    if [[ "$FS_PH" == Failed ]]; then write_r WARN "Pairing failed: $FS_FAIL"; OUTCOME=failed; break; fi
    PAIRED_NAME="${FS_PEER:-$FS_P0}"; OUTCOME=paired; break
  done
  [[ "$OUTCOME" == skip ]] && break
  if [[ "$OUTCOME" == failed ]]; then
    cli flow cancel >/dev/null 2>&1 || true
    gate "GATE M4b (Mac .8): 配对没有成功" "gate-pair-retry" 5 0 "" "" -- \
      "先在 Windows 窗口 (GATE W3b) 按回车, 让它重新监听;" "然后在这里按回车 = 重新发起配对。" "abort = 结束测试并自动恢复 (Windows 窗口也输入 abort)。"
  fi
done
if [[ -n "$PAIRED_NAME" ]]; then write_r GATE "PAIRED with peer name: $PAIRED_NAME"; else write_r WARN "No paired peer - crossings cannot happen."; fi
lease_renew paired

section "FLOW LAYOUT (GM: Mac Mini is LEFT of Jay-Alienware -> Mac edge=$FLOW_EDGE)"
apply_flow_layout_and_reload "$FLOW_EDGE" "${PEER_NAME:-$PAIRED_NAME}" "$PORT" || true

section "FLOW CROSSING MEASUREMENT"
MEASURE_START="$(now_ms)"
if [[ "$WITH_INJECT" -eq 1 ]]; then
  INJ_OUT="$HT_WORK/inject.json"
  /bin/bash "$HT_WORK/suite/inject.sh" --edge "$FLOW_EDGE" --out "$INJ_OUT" || true
  [[ -f "$INJ_OUT" ]] && write_r INFO "Injection probe: $(cat "$INJ_OUT")"
fi
measure_check() {
  local ev o i b
  ev="$(parse_agent_events "$MEASURE_START" 2>/dev/null || true)"
  o="$(printf '%s\n' "$ev" | grep -c $'\tFlow handoff completed\t' || true)"
  i="$(printf '%s\n' "$ev" | grep -c $'\tFlow incoming handoff finished\t' || true)"
  b="$(printf '%s\n' "$ev" | grep '^EVENT' | grep -c -E 'timed out|rejected|failed|ignored|cancelled|invalid' || true)"
  echo "Mac->Alienware 完成 $o 次 | Alienware->Mac 到达 $i 次 | 失败/忽略 $b 次"
  return 0
}
gate "GATE M5 (两台机器): 用真鼠标来回跨屏" "gate-m5-measure" 5 0 "" measure_check -- \
  "用 Logitech 真鼠标 (不要用触控板/别的鼠标):" \
  "  1) 在 Mac 上把光标一直往【右边缘】推 -> 光标应出现在 Alienware 屏幕上 (蓝牙切换常要 10-30 秒)。" \
  "  2) 在 Alienware 上把光标一直往【左边缘】推 -> 回到 Mac。" \
  "  至少来回 3 次。状态行会显示已检测到的次数。" \
  "做完后在【本窗口】按回车结束测量 (Windows 窗口也按回车)。"

section "FLOW EVENTS (from agent log)"
parse_agent_events "$MEASURE_START" 2>/dev/null | while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    EVENT) write_r EVENT "$a $b \"$c\" $d" ;;
    TIMING) write_r TIMING "$a" ;;
  esac
done || true
write_r INFO "Final flow status: $(cli flow status 2>&1 | tr '\n' ' ' || true)"
exit 0   # EXIT trap restores and prints DONE
