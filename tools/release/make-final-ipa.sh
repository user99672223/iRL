#!/bin/bash
# Produce dist/iRL-final.ipa for Impactor:
#   1. download the IPA artifact of the newest successful "Build iRL IPA" run on main (or use $1)
#   2. inject the AOT code maps (tools/aot/inject-ipa.sh, from build/aot/codemap-ready)
#   3. inject precompiled shaders if build/shaders/out/ exists (Payload/<app>/Shaders/)
# Logs to logs/release-*.log.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$R"
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-/home/familybadgujarwilly/.config/gh}"
L="logs/release-$(date +%Y%m%dT%H%M%S).log"; mkdir -p dist
exec > >(tee -a "$L") 2>&1
echo "# $(date -Is) tools/release/make-final-ipa.sh $*"
if [ -n "${1:-}" ]; then IN="$1"; else
  RUN=$(gh run list --workflow build.yml --branch main --status success -L 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] || { echo "no successful CI run yet"; exit 1; }
  rm -rf dist/ci && mkdir -p dist/ci
  gh run download "$RUN" -D dist/ci
  IN=$(find dist/ci -name '*.ipa' -print -quit)
  echo "CI run $RUN -> $IN"
fi
[ -f "$IN" ] || { echo "no IPA found"; exit 1; }
[ -f build/aot/codemap-ready/manifest.json ] || bash tools/aot/build-codemaps.sh
bash tools/aot/inject-ipa.sh "$IN" dist/iRL-final.ipa build/aot/codemap-ready
if [ -d build/shaders/out ] && [ -n "$(ls -A build/shaders/out)" ]; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  APP=$(unzip -Z1 dist/iRL-final.ipa | grep -m1 -oE '^Payload/[^/]+\.app/' || true); APP=${APP%/}
  mkdir -p "$W/$APP/Shaders" && cp -r build/shaders/out/. "$W/$APP/Shaders/"
  (cd "$W" && zip -qr -0 "$R/dist/iRL-final.ipa" "$APP/Shaders")
  echo "injected shaders: $(ls build/shaders/out | wc -l) files"
fi
# File list of the laptop's install (size<TAB>relative path, every file) for iRL's
# "Check game files" (GameCheck.swift).
GAME="${IRL_GAME:-/home/familybadgujarwilly/Games/Heroic/rocketleague}"
if [ -d "$GAME" ]; then
  W2=$(mktemp -d)
  APP=$(unzip -Z1 dist/iRL-final.ipa | grep -m1 -oE '^Payload/[^/]+\.app/' || true); APP=${APP%/}
  mkdir -p "$W2/$APP"
  (cd "$GAME" && find . -type f -printf '%s\t%P\n' | LC_ALL=C sort -t$'\t' -k2) > "$W2/$APP/GameFiles.tsv"
  (cd "$W2" && zip -q "$R/dist/iRL-final.ipa" "$APP/GameFiles.tsv")
  echo "injected GameFiles.tsv: $(wc -l < "$W2/$APP/GameFiles.tsv") files"; rm -rf "$W2"
fi
unzip -tq dist/iRL-final.ipa
ls -l dist/iRL-final.ipa; sha256sum dist/iRL-final.ipa
