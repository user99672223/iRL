#!/bin/bash
# Inject the laptop-built AOT inputs into an iRL IPA (before Impactor signs it):
#   Payload/<App>.app/AOT/codemaps/<module>-<fileid>   static code maps (gen_codemaps.py)
#   Payload/<App>.app/AOT/manifest.json                 module list, FileIds, block counts
# On first launch the app's "Prepare AOT" step copies codemaps/ to <FEX cache>/codemap/ready/
# and runs FEXOfflineCompiler.exe process-all under Wine. Usage: inject-ipa.sh IN.ipa OUT.ipa [codemap-dir]
set -euo pipefail
IN=$(realpath "$1"); OUT=$(realpath -m "$2"); CM=$(realpath "${3:-$(dirname "$0")/../../build/aot/codemap-ready}")
[ -f "$CM/manifest.json" ] || { echo "no manifest.json in $CM (run gen_codemaps.py)" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$IN" "$W/x.ipa"
APP=$(unzip -Z1 "$W/x.ipa" | grep -oE '^Payload/[^/]+\.app/' | head -1)
APP=${APP%/}
[ -n "$APP" ] || { echo "no Payload/*.app in $IN" >&2; exit 1; }
mkdir -p "$W/$APP/AOT/codemaps"
find "$CM" -maxdepth 1 -type f ! -name manifest.json -exec cp {} "$W/$APP/AOT/codemaps/" \;
cp "$CM/manifest.json" "$W/$APP/AOT/manifest.json"
(cd "$W" && zip -qr -0 x.ipa "$APP/AOT")
mv "$W/x.ipa" "$OUT"
echo "injected $(ls "$W/$APP/AOT/codemaps" | wc -l) code maps into $OUT ($APP)"
