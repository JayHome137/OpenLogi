#!/usr/bin/env bash
# Build (once) and run the CGEvent injector as the console user.
# Usage: inject.sh --edge right [--out /path/to.json]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=""
EDGE="right"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --edge) EDGE="$2"; ARGS+=(--edge "$2"); shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
BIN_DIR="${HT_WORK:-/tmp}/bin"
mkdir -p "$BIN_DIR"
BIN="$BIN_DIR/ht-inject"
if [[ ! -x "$BIN" || "$DIR/inject.swift" -nt "$BIN" ]]; then
  /usr/bin/swiftc -O -o "$BIN" "$DIR/inject.swift" 2>"$BIN_DIR/swiftc.err" || {
    echo "{\"ok\":false,\"error\":\"swiftc failed\",\"log\":$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$BIN_DIR/swiftc.err")}"
    exit 1
  }
fi
# Run as the console user so Accessibility grants for that user apply.
UID_CONSOLE="$(stat -f%u /dev/console)"
RESULT="$(launchctl asuser "$UID_CONSOLE" "$BIN" --edge "$EDGE" "${ARGS[@]:-}" 2>/dev/null || true)"
if [[ -z "$RESULT" ]]; then
  # Fallback: osascript System Events (also needs Accessibility; less precise).
  RESULT="$(launchctl asuser "$UID_CONSOLE" /usr/bin/osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
  set p to mouse location
end tell
return "{\"ok\":false,\"error\":\"CGEvent injector produced no output; osascript can read mouse location but cannot synthesize continuous motion reliably. Grant Accessibility to the injector / Terminal and retry, or move the mouse by hand.\",\"method\":\"none\"}"
OSA
)"
fi
[[ -n "$OUT" ]] && printf '%s\n' "$RESULT" >"$OUT"
printf '%s\n' "$RESULT"
