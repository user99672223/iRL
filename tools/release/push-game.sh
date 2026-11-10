#!/bin/bash
# Copy the Rocket League folder from the laptop into iRL's Documents over USB (libimobiledevice
# house_arrest; needs UIFileSharingEnabled, which iRL declares). Resumable: re-run after a disconnect
# and rsync only sends what's missing. Target: iRL › Documents/Games/rocketleague, which the app
# exposes in the Wine prefix as C:\games\rocketleague (the path the AOT code maps use).
# Usage: push-game.sh [game-dir] [bundle-id]
set -euo pipefail
GAME="${1:-/home/familybadgujarwilly/Games/Heroic/rocketleague}"
BUNDLE="${2:-io.github.irl}"
R="$(cd "$(dirname "$0")/../.." && pwd)"
L="$R/logs/push-game-$(date +%Y%m%dT%H%M%S).log"
exec > >(tee -a "$L") 2>&1
echo "# $(date -Is) push-game.sh $GAME $BUNDLE"
idevice_id -l | grep -q . || { echo "No iPhone on USB. Plug it in, unlock it, tap Trust."; exit 1; }
ideviceinfo -k ProductType; ideviceinfo -k ProductVersion
FREE=$(ideviceinfo -q com.apple.disk_usage -k TotalDataAvailable 2>/dev/null || echo 0)
NEED=$(du -sb "$GAME" | cut -f1)
echo "phone free: $((FREE/1024/1024/1024)) GiB, game: $((NEED/1024/1024/1024)) GiB"
[ "$FREE" = 0 ] || [ "$FREE" -gt "$NEED" ] || { echo "Not enough free space on the iPhone."; exit 1; }
M=$(mktemp -d)
trap 'fusermount -u "$M" 2>/dev/null || true; rmdir "$M"' EXIT
ifuse --documents "$BUNDLE" "$M" || { echo "Could not mount $BUNDLE Documents. Is iRL installed and opened once?"; exit 1; }
mkdir -p "$M/Games/rocketleague"
# --inplace/--partial: resumable on a 42 GB copy; no --delete (never remove anything on the phone).
rsync -rt --partial --inplace --info=progress2 "$GAME/" "$M/Games/rocketleague/"
echo "verify: $(find "$GAME" -type f | wc -l) files on laptop, $(find "$M/Games/rocketleague" -type f | wc -l) on phone"
cmp "$GAME/Binaries/Win64/RocketLeague.exe" "$M/Games/rocketleague/Binaries/Win64/RocketLeague.exe" && echo "RocketLeague.exe matches"
echo "done"
