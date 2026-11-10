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
  IN=$(find dist/ci -name '*.ipa' | head -1)
  echo "CI run $RUN -> $IN"
fi
[ -f "$IN" ] || { echo "no IPA found"; exit 1; }
[ -f build/aot/codemap-ready/manifest.json ] || bash tools/aot/build-codemaps.sh
bash tools/aot/inject-ipa.sh "$IN" dist/iRL-final.ipa build/aot/codemap-ready
if [ -d build/shaders/out ] && [ -n "$(ls -A build/shaders/out)" ]; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  APP=$(unzip -Z1 dist/iRL-final.ipa | grep -oE '^Payload/[^/]+\.app/' | head -1); APP=${APP%/}
  mkdir -p "$W/$APP/Shaders" && cp -r build/shaders/out/. "$W/$APP/Shaders/"
  (cd "$W" && zip -qr -0 "$R/dist/iRL-final.ipa" "$APP/Shaders")
  echo "injected shaders: $(ls build/shaders/out | wc -l) files"
fi
unzip -tq dist/iRL-final.ipa
ls -l dist/iRL-final.ipa; sha256sum dist/iRL-final.ipa
