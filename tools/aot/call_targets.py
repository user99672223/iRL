#!/usr/bin/env python3
"""Find leaf-function entries that .pdata doesn't list: the targets of direct `call rel32`
instructions found by disassembling each module (llvm-objdump linear sweep). A target is kept only if
the sweep shows an instruction starting at exactly that address, inside an executable section.
Output: JSON {module_basename: [rva, ...]} for gen_codemaps.py --extra.
Usage: call_targets.py --objdump PATH --game DIR --out extra.json [--manifest codemap-ready/manifest.json]"""
import argparse, json, os, re, subprocess, sys
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
    valid = sorted(t - base for t in targets if t in starts)
    out[m['name'].lower()] = valid
    print(f"{m['name']}: {len(targets)} direct call targets, {len(valid)} at instruction starts", flush=True)
json.dump(out, open(a.out, 'w'))
