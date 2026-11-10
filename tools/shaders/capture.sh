#!/usr/bin/env bash
# Capture Rocket League's DXBC shaders on the laptop: Heroic's existing Epic login (Legendary),
# no-EAC launch of RocketLeague.exe, GE-Proton + its DXVK with DXVK_SHADER_DUMP_PATH.
# Usage: tools/shaders/capture.sh [seconds-to-run]   (default 900)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNSECS="${1:-900}"
TS=$(date +%Y%m%dT%H%M%S)
LOG="$ROOT/logs/shader-capture-$TS.log"
DUMP="$ROOT/build/shaders/raw-$TS"
mkdir -p "$DUMP" "$DUMP-logs" "$ROOT/logs"
LEG=/opt/Heroic/resources/app.asar.unpacked/build/bin/x64/linux/legendary
export LEGENDARY_CONFIG_PATH=/home/familybadgujarwilly/.config/heroic/legendaryConfig/legendary
PROTON=/home/familybadgujarwilly/.config/heroic/tools/proton/GE-Proton-latest/proton
PREFIX="/home/familybadgujarwilly/Games/Heroic/Prefixes/Rocket League"
GAME=/home/familybadgujarwilly/Games/Heroic/rocketleague
redact() { sed -E 's/(AUTH_PASSWORD=)[^ "]+/\1<redacted>/g; s/(epicusername=)[^ "]+/\1<redacted>/g; s/(epicuserid=)[^ "]+/\1<redacted>/g'; }
log() { echo "[$(date -Is)] $*" | redact >> "$LOG"; }

log "capture start, run ${RUNSECS}s, dump=$DUMP"
J=$(mktemp)
log "cmd: $LEG launch Sugar --dry-run --override-exe Binaries/Win64/RocketLeague.exe --skip-version-check --json"
"$LEG" launch Sugar --dry-run --override-exe Binaries/Win64/RocketLeague.exe --skip-version-check --json > "$J" 2>>"$LOG" || { log "legendary failed"; exit 1; }
mapfile -t ARGS < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(d["game_parameters"]+d["egl_parameters"]+d["user_parameters"]))' "$J")
rm -f "$J"

export STEAM_COMPAT_DATA_PATH="$PREFIX" STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.steam" \
       STEAM_COMPAT_INSTALL_PATH="$GAME" SteamAppId=0 SteamGameId=0 \
       PROTON_LOG=1 PROTON_LOG_DIR="$DUMP-logs" MESA_VK_DEVICE_SELECT=8086:9a49 \
       DXVK_SHADER_DUMP_PATH="$DUMP" DXVK_LOG_LEVEL=info DXVK_LOG_PATH="$DUMP-logs" \
       DXVK_STATE_CACHE=0 WINEDEBUG=-all
log "env: STEAM_COMPAT_DATA_PATH=$PREFIX DXVK_SHADER_DUMP_PATH=$DUMP DXVK_LOG_LEVEL=info MESA_VK_DEVICE_SELECT=8086:9a49"
log "cmd: $PROTON waitforexitandrun $GAME/Binaries/Win64/RocketLeague.exe ${ARGS[*]}"
cd "$GAME/Binaries/Win64"
"$PROTON" waitforexitandrun "$GAME/Binaries/Win64/RocketLeague.exe" "${ARGS[@]}" > >(redact >> "$LOG") 2>&1 &
PID=$!
for ((t=0; t<RUNSECS; t+=30)); do
  sleep 30
  kill -0 $PID 2>/dev/null || { log "game exited after ${t}s"; break; }
  log "t=${t}s dumped=$(find "$DUMP" -type f | wc -l)"
done
if kill -0 $PID 2>/dev/null; then
  log "stopping game"
  WINEPREFIX="$PREFIX/pfx" "$(dirname "$PROTON")/files/bin/wineserver" -k 2>>"$LOG"
  sleep 5; kill $PID 2>/dev/null
fi
log "capture end: $(find "$DUMP" -type f | wc -l) files"
# Proton/DXVK logs carry the full command line (exchange code, account name): redact before keeping.
for f in "$DUMP-logs"/*.log; do [ -e "$f" ] && redact < "$f" > "$ROOT/logs/shader-$(basename "$f" .log)-$TS.log"; done
rm -rf "$DUMP-logs"
echo "$LOG"
