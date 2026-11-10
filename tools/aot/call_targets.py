#!/usr/bin/env python3
"""Find function entries that .pdata doesn't list (leaf functions): the targets of direct `call rel32`
instructions found by disassembling each module (llvm-objdump linear sweep). A target is kept only if
the sweep shows an instruction starting at exactly that address, inside an executable section.
Also adds indirect targets: every DIR64 base relocation in a data section whose pointer lands on an
instruction start (vtables, function-pointer tables, callbacks).
Output: JSON {module_basename: [rva, ...]} for gen_codemaps.py --extra.
Usage: call_targets.py --objdump PATH --game DIR --out extra.json [--manifest codemap-ready/manifest.json]"""
import argparse, json, os, re, subprocess, sys
import pefile
ap = argparse.ArgumentParser()
ap.add_argument('--objdump', required=True); ap.add_argument('--game', required=True)
ap.add_argument('--manifest', required=True); ap.add_argument('--out', required=True)
a = ap.parse_args()
man = json.load(open(a.manifest))
LINE = re.compile(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$')
CALL = re.compile(r'^callq?\s+0x([0-9a-f]+)\b')
out = {}
for m in man['modules']:
    path = os.path.join(a.game, m['rel'])
    base = int(m['preferred_base'], 16)
    p = subprocess.Popen([a.objdump, '-d', '--no-show-raw-insn', '--no-leading-headers', path],
                         stdout=subprocess.PIPE, text=True, errors='replace')
    starts, targets = set(), set()
    for line in p.stdout:
        mm = LINE.match(line)
        if not mm:
            continue
        addr = int(mm.group(1), 16); starts.add(addr)
        c = CALL.match(mm.group(2) + ' ' + mm.group(3))
        if c:
            targets.add(int(c.group(1), 16))
    p.wait()
    direct = {t - base for t in targets if t in starts}
    # Indirect targets: absolute pointers listed in .reloc (DIR64) that sit in non-executable
    # sections (vtables, function-pointer tables, callbacks) and point at an instruction start.
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_BASERELOC']])
    execsec = [(x.VirtualAddress, x.VirtualAddress + max(x.Misc_VirtualSize, x.SizeOfRawData)) for x in pe.sections if x.Characteristics & 0x20000000]
    inexec = lambda r: any(lo <= r < hi for lo, hi in execsec)
    indirect = set()
    for blk in getattr(pe, 'DIRECTORY_ENTRY_BASERELOC', []):
        for e in blk.entries:
            if e.type != 10 or inexec(e.rva):  # IMAGE_REL_BASED_DIR64, data only
                continue
            try:
                v = pe.get_qword_at_rva(e.rva)
            except Exception:
                continue
            if v in starts:
                indirect.add(v - base)
    pe.close()
    valid = sorted(direct | indirect)
    out[m['name'].lower()] = valid
    print(f"{m['name']}: {len(direct)} direct-call targets, {len(indirect)} relocated data pointers to code, {len(valid)} total", flush=True)
json.dump(out, open(a.out, 'w'))
