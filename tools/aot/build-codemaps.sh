#!/bin/bash
# Full AOT input build (re-run after every game patch): PE-metadata seeds + direct-call targets
# (leaf functions without .pdata) + relocated code pointers + PGO JIT misses (tools/aot/pgo/*.json) → build/aot/codemap-ready, verified. Logs to logs/.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$R"
GAME="${1:-/home/familybadgujarwilly/Games/Heroic/rocketleague}"
OBJDUMP="$R/toolchains/llvm-mingw-20260421-ucrt-ubuntu-22.04-x86_64/bin/llvm-objdump"
L="logs/aot-build-codemaps-$(date +%Y%m%dT%H%M%S).log"
{
  echo "# $(date -Is) tools/aot/build-codemaps.sh $GAME"
  rm -rf build/aot/codemap-seed build/aot/codemap-ready
  python3 -I tools/aot/gen_codemaps.py --game "$GAME" --out build/aot/codemap-seed
  python3 -I tools/aot/call_targets.py --objdump "$OBJDUMP" --game "$GAME" --manifest build/aot/codemap-seed/manifest.json --out build/aot/call-targets.json
  # PGO: JIT misses recorded at runtime (ARM64 CI bench boot, later device launches), see import_misses.py
  python3 -I - build/aot/call-targets.json tools/aot/pgo/*.json > build/aot/extra.json <<'PY'
import json, sys
out = {}
for p in sys.argv[1:]:
    for k, v in json.load(open(p)).items():
        out.setdefault(k.lower(), set()).update(v)
json.dump({k: sorted(v) for k, v in out.items()}, sys.stdout)
PY
  python3 -I tools/aot/gen_codemaps.py --game "$GAME" --extra build/aot/extra.json --out build/aot/codemap-ready
  python3 -I tools/aot/check_codemap.py $(ls build/aot/codemap-ready/* | grep -v manifest.json)
  rm -rf build/aot/codemap-seed
  echo "exit=0"
} > "$L" 2>&1 || { echo "FAILED, see $L" >&2; exit 1; }
echo "ok: $L"
