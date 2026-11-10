#!/usr/bin/env python3
"""Collect DXVK-dumped DXBC shaders into a deduplicated, stage-sorted set.

Input : one or more raw dump dirs (DXVK_SHADER_DUMP_PATH output: <stage>.<dxvkhash>.dxbc/.spv)
Output: OUT/<stage>/<sha256>.dxbc plus OUT/manifest.json

Each shader is identified by the SHA-256 of its bytes, and the DXBC container's own MD5
checksum (bytes 4..20) is recorded too. The stage comes from the SHEX/SHDR version token
(program type in bits 16..31), not from DXVK's file prefix, so the set stays correct if the
dump naming changes. Usage: collect.py OUT RAWDIR [RAWDIR...]
"""
import hashlib, json, os, struct, sys, time

STAGES = {0: 'ps', 1: 'vs', 2: 'gs', 3: 'hs', 4: 'ds', 5: 'cs'}


def parse(blob):
    if blob[:4] != b'DXBC':
        return None
    checksum = blob[4:20].hex()
    count, = struct.unpack_from('<I', blob, 28)
    for i in range(count):
        off, = struct.unpack_from('<I', blob, 32 + 4 * i)
        fourcc = blob[off:off + 4]
        if fourcc in (b'SHEX', b'SHDR'):
            ver, = struct.unpack_from('<I', blob, off + 8)
            return {'checksum': checksum, 'stage': STAGES.get(ver >> 16, f'type{ver >> 16}'),
                    'model': f'{(ver >> 4) & 0xf}_{ver & 0xf}', 'chunk': fourcc.decode()}
    return {'checksum': checksum, 'stage': 'unknown', 'model': '?', 'chunk': None}


def main():
    out, raws = sys.argv[1], sys.argv[2:]
    man_path = os.path.join(out, 'manifest.json')
    man = json.load(open(man_path)) if os.path.exists(man_path) else {'shaders': {}}
    seen, new, bad = man['shaders'], 0, 0
    for raw in raws:
        for fn in sorted(os.listdir(raw)):
            if not fn.endswith('.dxbc'):
                continue
            blob = open(os.path.join(raw, fn), 'rb').read()
            info = parse(blob)
            if not info:
                bad += 1
                continue
            h = hashlib.sha256(blob).hexdigest()
            if h in seen:
                continue
            d = os.path.join(out, info['stage'])
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, h + '.dxbc'), 'wb').write(blob)
            seen[h] = info | {'size': len(blob), 'dxvk_name': fn, 'source': os.path.basename(raw.rstrip('/'))}
            new += 1
    counts = {}
    for s in seen.values():
        counts[s['stage']] = counts.get(s['stage'], 0) + 1
    man.update(updated=time.strftime('%Y-%m-%dT%H:%M:%S%z'), total=len(seen), by_stage=dict(sorted(counts.items())))
    json.dump(man, open(man_path, 'w'), indent=0)
    print(f'new={new} invalid={bad} total={len(seen)} by_stage={man["by_stage"]}')


if __name__ == '__main__':
    main()
