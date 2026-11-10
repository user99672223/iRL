#!/bin/bash
# Build the folder of files iRL's "Check game files" reported missing or incomplete
# (Documents/game-check.txt sent back from the iPhone). Output: dist/rl-missing/rocketleague/<same layout>,
# hard links to the game files (no extra disk space). Send that folder with LocalSend, move it into
# Files › iRL › Incoming, and tap Check game files: iRL puts every file in its place.
# Usage: missing-files.sh <game-check.txt> [game-dir]
set -euo pipefail
LIST="$1"; GAME="${2:-/home/familybadgujarwilly/Games/Heroic/rocketleague}"
R="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$R/dist/rl-missing/rocketleague"
rm -rf "$R/dist/rl-missing"; mkdir -p "$OUT"
n=0; bytes=0
while IFS=$'\t' read -r kind rel _; do
  case "$kind" in missing|size) ;; *) continue ;; esac
  [ -f "$GAME/$rel" ] || { echo "not on the laptop: $rel"; continue; }
  mkdir -p "$OUT/$(dirname "$rel")"
  ln "$GAME/$rel" "$OUT/$rel" 2>/dev/null || cp "$GAME/$rel" "$OUT/$rel"
  n=$((n+1)); bytes=$((bytes + $(stat -c %s "$GAME/$rel")))
done < "$LIST"
echo "$n files, $(awk -v b=$bytes 'BEGIN{printf "%.2f GB", b/1e9}') -> $R/dist/rl-missing/rocketleague"
