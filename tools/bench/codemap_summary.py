#!/usr/bin/env python3
"""Per-module block counts from FEX code maps (JIT misses recorded in <cache>/codemap/new)."""
import collections, os, struct, sys
blocks, names = collections.defaultdict(set), {}
for d in sys.argv[1:]:
    for f in sorted(os.listdir(d)):
        data = open(os.path.join(d, f), 'rb').read(); i = 0
        while i + 12 <= len(data):
            fid, off = struct.unpack_from('<QI', data, i); i += 12
            if fid == 0xFFFFFFFFFFFFFFFF and off == 0xFFFFFFFF:
                ext, = struct.unpack_from('<Q', data, i); s = i - 12; i += 8
                e = data.index(b'\0', i); names[ext] = data[i:e].decode(errors='replace'); i = e + 1; i = s + ((i - s + 3) & ~3)
            elif fid == 0xFFFFFFFFFFFFFFFF:
                i += 8
            else:
                blocks[fid].add(off)
total = sum(len(b) for b in blocks.values())
print(f'{total} JIT-missed blocks in {len(blocks)} modules')
for fid, b in sorted(blocks.items(), key=lambda x: -len(x[1])):
    print(f'{len(b):7d}  {names.get(fid, hex(fid)).split(chr(92))[-1]}')
