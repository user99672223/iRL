#!/usr/bin/env python3
"""Turn runtime-recorded FEX code maps (JIT misses, <cache>/codemap/new/*.bin, from a device launch or
the ARM64 CI bench) into a --extra JSON {module_basename: [rva, ...]} for gen_codemaps.py.
Only modules whose FileId matches the current game files (manifest.json) are kept, so Wine's own
system DLLs (different builds on the phone), stale game versions and the sub-4GB modules gen_codemaps
skips never get in. Merges with an existing JSON if --merge is given.
Usage: import_misses.py --manifest build/aot/codemap-ready/manifest.json --out tools/aot/pgo/jit-misses.json MAP.bin..."""
import argparse, json, os, struct, sys
ap = argparse.ArgumentParser()
ap.add_argument('--manifest', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--merge', action='store_true'); ap.add_argument('maps', nargs='+')
a = ap.parse_args()
man = json.load(open(a.manifest))
ids = {int(m['file_id'], 16): m['name'].lower() for m in man['modules']}
out = {k: set(v) for k, v in json.load(open(a.out)).items()} if a.merge and os.path.exists(a.out) else {}
seen = {}
for p in a.maps:
    d = open(p, 'rb').read(); i = 0
    while i + 12 <= len(d):
        fid, off = struct.unpack_from('<QI', d, i); i += 12
        if fid == 0xFFFFFFFFFFFFFFFF and off == 0xFFFFFFFF:
            start = i - 12; i += 8; end = d.index(b'\0', i); i = end + 1
            i = start + ((i - start + 3) & ~3)
        elif fid == 0xFFFFFFFFFFFFFFFF and off in (0xFFFFFFEE, 0xFFFFFFEF):
            i += 8
        elif fid == 0xFFFFFFFFFFFFFFFF:
            sys.exit(f'{p}: malformed marker {off:#x}')
        else:
            seen[fid] = seen.get(fid, 0) + 1
            if fid in ids:
                out.setdefault(ids[fid], set()).add(off)
json.dump({k: sorted(v) for k, v in sorted(out.items())}, open(a.out, 'w'), indent=0)
for fid, n in sorted(seen.items(), key=lambda x: -x[1]):
    print(f"{ids.get(fid, '(not a shipped game module)'):40s} {fid:016x} {n} blocks {'kept' if fid in ids else 'skipped'}")
print('total kept:', sum(len(v) for v in out.values()))
