#!/usr/bin/env python3
"""Parse a FEX code map exactly as FEXCore CodeMap::ParseCodeMap does; exit 1 on any inconsistency."""
import struct, sys
def parse(p):
    d = open(p, 'rb').read(); i = 0; files = {}; exe = None
    while i < len(d):
        fid, off = struct.unpack_from('<QI', d, i); i += 12
        if fid == 0xFFFFFFFFFFFFFFFF and off == 0xFFFFFFFF:
            ext, = struct.unpack_from('<Q', d, i); start = i - 12; i += 8
            end = d.index(b'\0', i); name = d[i:end].decode(); i = end + 1
            i = start + ((i - start + 3) & ~3)
            files.setdefault(ext, [name, set()])
        elif fid == 0xFFFFFFFFFFFFFFFF and off in (0xFFFFFFEE, 0xFFFFFFEF):
            exe, = struct.unpack_from('<Q', d, i); i += 8
        elif fid == 0xFFFFFFFFFFFFFFFF:
            sys.exit(f'{p}: malformed marker {off:#x} (FEX would ERROR_AND_DIE)')
        else:
            if fid not in files: sys.exit(f'{p}: unknown file id {fid:016x}')
            files[fid][1].add(off)
    return files, exe
bad = 0
for p in sys.argv[1:]:
    files, exe = parse(p)
    with_blocks = [f for f in files.values() if f[1]]
    print(f'{p.split("/")[-1]}: files={len(files)} exe={"yes" if exe else "no"} blocks={sum(len(f[1]) for f in files.values())} path={with_blocks[0][0] if with_blocks else "-"}')
    bad |= len(with_blocks) != 1
sys.exit(bad)
