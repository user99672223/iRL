#!/usr/bin/env python3
"""Generate FEX code maps statically from x86-64 PE images (no runtime recording needed).

FEX's FEXOfflineCompiler only compiles blocks listed in a code map. Normally code maps are
recorded while the game runs under FEX. This tool seeds them statically from metadata every
x64 PE carries, so the first on-device AOT pass already covers (nearly) every function:

  * AddressOfEntryPoint
  * exported functions (non-forwarded, inside executable sections)
  * TLS callbacks
  * every primary RUNTIME_FUNCTION in .pdata (all non-leaf functions; chained fragments skipped)

The on-disk format mirrors FEXCore/include/FEXCore/Core/CodeCache.h (struct CodeMap) of the
pinned FEX (Madeira ios-port-2607):
  Entry          = packed { u64 FileId; u32 BlockOffset }       (BlockOffset = RVA)
  LoadExternal   = Entry{~0, 0xffffffff} + u64 FileId + NUL-terminated path, padded to 4 bytes
  SetExecutable  = Entry{~0, 0xfffffffe} + u64 FileId
FileId follows Source/Windows/Common/ImageTracker.cpp:
  XXH3_64(lowercase basename) ^ (SizeOfImage << 32 | TimeDateStamp)
Paths are lowercased Windows paths, as ImageTracker records them.

One code map is written per module (the executable's map also lists every dependency), so a
game patch only regenerates the modules whose FileId changed.
"""
import argparse, json, os, struct, sys, time
import pefile, xxhash

SCN_MEM_EXECUTE = 0x20000000
UNW_FLAG_CHAININFO = 0x4
LOAD_EXTERNAL = struct.pack('<QI', 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF)
SET_EXECUTABLE = struct.pack('<QI', 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFE)

# Not part of a no-EAC launch, or never loaded by the game.
EXCLUDE = ('easyanticheat', 'rocketleague_eac.exe', 'launcher.exe', 'clang_rt.asan', 'api-ms-win-')


def file_id(basename, nt):
    h = xxhash.xxh3_64_intdigest(basename.lower().encode())
    return h ^ ((nt.OPTIONAL_HEADER.SizeOfImage << 32) | nt.FILE_HEADER.TimeDateStamp)


def exec_ranges(pe):
    return [(s.VirtualAddress, s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData))
            for s in pe.sections if s.Characteristics & SCN_MEM_EXECUTE]


def in_exec(rva, ranges):
    return any(a <= rva < b for a, b in ranges)


def seeds(pe):
    ranges = exec_ranges(pe)
    out, stats = set(), {'entry': 0, 'exports': 0, 'tls': 0, 'pdata': 0, 'pdata_chained_skipped': 0}
    ep = pe.OPTIONAL_HEADER.AddressOfEntryPoint
    if ep and in_exec(ep, ranges):
        out.add(ep); stats['entry'] = 1
    if hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
        for e in pe.DIRECTORY_ENTRY_EXPORT.symbols:
            if e.forwarder is None and e.address and in_exec(e.address, ranges):
                out.add(e.address); stats['exports'] += 1
    if hasattr(pe, 'DIRECTORY_ENTRY_TLS') and pe.DIRECTORY_ENTRY_TLS.struct.AddressOfCallBacks:
        base = pe.OPTIONAL_HEADER.ImageBase
        va = pe.DIRECTORY_ENTRY_TLS.struct.AddressOfCallBacks
        while True:
            try:
                cb = pe.get_qword_at_rva(va - base)
            except Exception:
                break
            if not cb:
                break
            if in_exec(cb - base, ranges):
                out.add(cb - base); stats['tls'] += 1
            va += 8
    d = pe.OPTIONAL_HEADER.DATA_DIRECTORY[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXCEPTION']]
    if d.VirtualAddress and d.Size:
        raw = pe.get_data(d.VirtualAddress, d.Size)
        for i in range(0, len(raw) - 11, 12):
            begin, end, unwind = struct.unpack_from('<III', raw, i)
            if not begin or not in_exec(begin, ranges):
                continue
            try:
                flags = pe.get_data(unwind & ~1, 1)[0] >> 3
            except Exception:
                flags = 0
            if flags & UNW_FLAG_CHAININFO:
                stats['pdata_chained_skipped'] += 1
                continue
            out.add(begin); stats['pdata'] += 1
    return out, stats


def load_external(fid, path):
    body = LOAD_EXTERNAL + struct.pack('<Q', fid) + path.encode() + b'\0'
    return body + b'\0' * (-len(body) % 4)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--game', required=True, help='Rocket League folder on the laptop')
    ap.add_argument('--winroot', default=r'c:\games\rocketleague',
                    help='Windows path of the game folder inside the iRL Wine prefix')
    ap.add_argument('--exe', default='RocketLeague.exe')
    ap.add_argument('--out', required=True)
    ap.add_argument('--extra', help='JSON {module_basename: [rva,...]} merged in (PGO / JIT-miss logs)')
    a = ap.parse_args()

    extra = {k.lower(): v for k, v in json.load(open(a.extra)).items()} if a.extra else {}
    os.makedirs(a.out, exist_ok=True)
    mods, manifest = [], {'generated': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'winroot': a.winroot, 'modules': []}
    for dp, _, fns in os.walk(a.game):
        for fn in sorted(fns):
            if not fn.lower().endswith(('.exe', '.dll')):
                continue
            rel = os.path.relpath(os.path.join(dp, fn), a.game)
            if any(x in rel.lower() for x in EXCLUDE):
                continue
            try:
                pe = pefile.PE(os.path.join(dp, fn), fast_load=True)
            except pefile.PEFormatError as e:
                print(f'skip {rel}: {e}', file=sys.stderr); continue
            if pe.FILE_HEADER.Machine != 0x8664:
                print(f'skip {rel}: machine {pe.FILE_HEADER.Machine:#x} is not x86-64'); continue
            if pe.OPTIONAL_HEADER.ImageBase < 1 << 32:
                # Madeira's iOS FEX maps sub-4GB images high and rewrites their memory operands at JIT
                # time (IosJitAlias.cpp "subfloor" windows). An offline cache can't reproduce that, so these
                # stay on the JIT. In RL: X3DAudio1_7, dbghelp, xinput1_3 (all cold).
                print(f'skip {rel}: preferred base {pe.OPTIONAL_HEADER.ImageBase:#x} is below 4 GB (subfloor window, JIT only)'); continue
            pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY[n] for n in (
                'IMAGE_DIRECTORY_ENTRY_EXPORT', 'IMAGE_DIRECTORY_ENTRY_TLS')])
            blocks, st = seeds(pe)
            ex = extra.get(fn.lower(), [])
            blocks |= set(ex); st['extra'] = len(ex)
            winpath = (a.winroot.rstrip('\\') + '\\' + rel.replace('/', '\\')).lower()
            mods.append(dict(name=fn, rel=rel, fid=file_id(fn, pe), path=winpath, blocks=sorted(blocks),
                             is_exe=fn.lower() == a.exe.lower(), stats=st,
                             preferred_base=pe.OPTIONAL_HEADER.ImageBase, size=pe.OPTIONAL_HEADER.SizeOfImage,
                             timestamp=pe.FILE_HEADER.TimeDateStamp))
            pe.close()

    exe = next((m for m in mods if m['is_exe']), None)
    if not exe:
        sys.exit(f'{a.exe} not found under {a.game}')
    for m in mods:
        buf = bytearray()
        if m['is_exe']:
            buf += SET_EXECUTABLE + struct.pack('<Q', m['fid'])
            deps = [d for d in mods if d is not m]
        else:
            deps = []
        buf += load_external(m['fid'], m['path'])
        for d in deps:  # dependencies are recorded without blocks, like FEX's own aggregated maps
            buf += load_external(d['fid'], d['path'])
        for rva in m['blocks']:
            buf += struct.pack('<QI', m['fid'], rva)
        stem = os.path.splitext(m['name'])[0].lower()
        name = f'{m["name"].lower()}-{m["fid"]:016x}'  # FEX GetBaseFilename scheme
        with open(os.path.join(a.out, name), 'wb') as f:
            f.write(buf)
        manifest['modules'].append({k: m[k] for k in ('name', 'rel', 'path', 'is_exe', 'stats', 'size', 'timestamp')} |
                                   {'file_id': f'{m["fid"]:016x}', 'codemap': name, 'blocks': len(m['blocks']),
                                    'preferred_base': f'{m["preferred_base"]:#x}'})
        print(f'{name}: {len(m["blocks"])} blocks {m["stats"]}')
    json.dump(manifest, open(os.path.join(a.out, 'manifest.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
