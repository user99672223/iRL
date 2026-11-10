#!/bin/bash
# Restore the CI copy of Rocket League (main-menu subset) from a checkout of the private irl-assets repo.
# Usage: restore.sh <irl-assets checkout> <target dir>
# Texture caches come back as sparse files (full size, holes where the menu never reads).
set -euo pipefail
SRC="$(realpath "$1")"; DST="$(realpath -m "$2")"
mkdir -p "$DST"
( cd "$SRC/chunks" && sha256sum --quiet -c <(python3 -c 'import json,sys; [print(c["sha256"]+"  "+c["name"]) for c in json.load(open(sys.argv[1]))["chunks"]]' "$SRC/manifest.json") )
cat "$SRC"/chunks/game.tar.zst.* | zstd -d --long=27 -q -c | tar --sparse -xf - -C "$DST"
python3 - "$SRC/manifest.json" "$DST" <<'PY'
import hashlib, json, os, sys
m = json.load(open(sys.argv[1])); bad = 0
for f in m['files']:
    p = os.path.join(sys.argv[2], f['path'])
    if not os.path.isfile(p) or os.path.getsize(p) != f['size']:
        print('MISSING/SIZE', f['path']); bad += 1
    elif 'sha256' in f and hashlib.sha256(open(p, 'rb').read()).hexdigest() != f['sha256']:
        print('HASH', f['path']); bad += 1
print(f"restored {len(m['files'])} files, {bad} problems")
sys.exit(1 if bad else 0)
PY
