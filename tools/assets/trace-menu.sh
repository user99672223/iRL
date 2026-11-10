#!/usr/bin/env bash
# Launch Rocket League (no EAC) under strace (openat only) to record every game file it opens.
# Based on tools/shaders/capture.sh (Heroic GE-Proton, Heroic's Legendary login), without shader dumping.
# Usage: trace-menu.sh auth|noauth SECONDS
#   auth   : Legendary dry-run gives a fresh exchange code + Legendary's argument set
#   noauth : RocketLeague.exe with no Epic arguments (result: the game hands off to the Epic launcher via LaunchURL and exits)
#   dummy  : Legendary's argument set with an invalid exchange code (what CI can pass)
# Output: build/assets/trace-<mode>-<ts>/{strace.*,shots/}, log in logs/assets-trace-<mode>-<ts>.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-auth}"; RUNSECS="${2:-300}"
TS=$(date +%Y%m%dT%H%M%S)
OUT="$ROOT/build/assets/trace-$MODE-$TS"; mkdir -p "$OUT/shots" "$OUT/proton-logs"
LOG="$ROOT/logs/assets-trace-$MODE-$TS.log"
LEG=/opt/Heroic/resources/app.asar.unpacked/build/bin/x64/linux/legendary
export LEGENDARY_CONFIG_PATH=/home/familybadgujarwilly/.config/heroic/legendaryConfig/legendary
PROTON=/home/familybadgujarwilly/.config/heroic/tools/proton/GE-Proton-latest/proton
PREFIX="/home/familybadgujarwilly/Games/Heroic/Prefixes/Rocket League"
GAME=/home/familybadgujarwilly/Games/Heroic/rocketleague
redact() { sed -E 's/(AUTH_PASSWORD=)[^ "]+/\1<redacted>/g; s/(epicusername=)[^ "]+/\1<redacted>/g; s/(epicuserid=)[^ "]+/\1<redacted>/g'; }
log() { echo "[$(date -Is)] $*" | redact >> "$LOG"; }
ARGS=()
if [ "$MODE" = auth ]; then
  J=$(mktemp)
  log "cmd: $LEG launch Sugar --dry-run --override-exe Binaries/Win64/RocketLeague.exe --skip-version-check --json"
  "$LEG" launch Sugar --dry-run --override-exe Binaries/Win64/RocketLeague.exe --skip-version-check --json > "$J" 2>>"$LOG" || { log "legendary failed"; exit 1; }
  mapfile -t ARGS < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(d["game_parameters"]+d["egl_parameters"]+d["user_parameters"]))' "$J")
  rm -f "$J"
fi
if [ "$MODE" = dummy ]; then
  ARGS=(-AUTH_LOGIN=unused -AUTH_PASSWORD=00000000000000000000000000000000 -AUTH_TYPE=exchangecode -epicapp=Sugar
        -epicenv=Prod -EpicPortal -epiclocale=en -epicsandboxid=9773aa1aa54f4f7b80e44bef04986cea)
fi
export STEAM_COMPAT_DATA_PATH="$PREFIX" STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.steam" \
       STEAM_COMPAT_INSTALL_PATH="$GAME" SteamAppId=0 SteamGameId=0 \
       PROTON_LOG=1 PROTON_LOG_DIR="$OUT/proton-logs" MESA_VK_DEVICE_SELECT=8086:9a49 WINEDEBUG=-all
log "mode=$MODE run=${RUNSECS}s out=$OUT"
log "cmd: strace -f ${TRACE_READS:+(tfc read ranges) }-o $OUT/strace $PROTON waitforexitandrun $GAME/Binaries/Win64/RocketLeague.exe ${ARGS[*]:-}"
cd "$GAME/Binaries/Win64"
STRACE_ARGS=(-e trace=openat)
if [ -n "${TRACE_READS:-}" ]; then
  # Read ranges of the big texture caches only (-P limits tracing to calls touching those paths).
  STRACE_ARGS=(-y -e trace=openat,read,pread64,preadv,preadv2,lseek)
  for f in "$GAME"/TAGame/CookedPCConsole/*.tfc; do STRACE_ARGS+=(-P "$f"); done
fi
strace -f -qq "${STRACE_ARGS[@]}" -e signal=none -o "$OUT/strace" "$PROTON" waitforexitandrun "$GAME/Binaries/Win64/RocketLeague.exe" "${ARGS[@]}" > >(redact >> "$LOG") 2>&1 &
PID=$!
echo "$PID" > "$OUT/pid"
for ((t=0; t<RUNSECS; t+=15)); do
  sleep 15
  kill -0 $PID 2>/dev/null || { log "game exited after ${t}s"; break; }
  # Only shoot an existing window: xwd with an empty id waits for a click forever.
  W=$(timeout 5 bash "$ROOT/tools/shaders/rl-ui.sh" wid 2>/dev/null)
  [ -n "$W" ] && timeout 10 bash "$ROOT/tools/shaders/rl-ui.sh" shot "$OUT/shots/t$(printf %04d $t).png" 2>/dev/null
done
if kill -0 $PID 2>/dev/null; then
  log "stopping game"
  WINEPREFIX="$PREFIX/pfx" "$(dirname "$PROTON")/files/bin/wineserver" -k 2>>"$LOG"
  sleep 5; kill $PID 2>/dev/null
fi
for f in "$OUT/proton-logs"/*.log; do [ -e "$f" ] && redact < "$f" > "$f.redacted" && mv "$f.redacted" "$f"; done
log "end; strace files: $(ls "$OUT"/strace* | wc -l)"
echo "$OUT"
