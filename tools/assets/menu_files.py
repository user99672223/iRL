#!/usr/bin/env python3
"""From strace logs (trace-menu.sh), list every game file Rocket League opened successfully.
Paths are resolved with realpath (Wine opens through dosdevices/x: symlinks) and kept only when
they are regular files under the game folder. Writes "<size>\t<relative path>" lines, sorted,
plus a total. Usage: menu_files.py --game DIR --out menu-files.txt STRACE [STRACE...]"""
import argparse, os, re
ap = argparse.ArgumentParser()
ap.add_argument('--game', required=True); ap.add_argument('--out', required=True); ap.add_argument('traces', nargs='+')
a = ap.parse_args()
game = os.path.realpath(a.game)
OPEN = re.compile(r'openat\((?:AT_FDCWD|\d+), "((?:[^"\\]|\\.)*)", [^)]*\)\s+= (\d+)')
cwd_hint = os.path.join(game, 'Binaries', 'Win64')  # the launcher's cwd; Wine itself uses absolute paths
found = set()
for t in a.traces:
    with open(t, errors='replace') as f:
        for line in f:
            m = OPEN.search(line)
            if not m:
                continue
            p = m.group(1).encode().decode('unicode_escape')
            if not p.startswith('/'):
                p = os.path.join(cwd_hint, p)
            rp = os.path.realpath(p)
            if rp.startswith(game + '/') and os.path.isfile(rp):
                found.add(os.path.relpath(rp, game))
rows = sorted((os.path.getsize(os.path.join(game, r)), r) for r in found)
total = sum(s for s, _ in rows)
with open(a.out, 'w') as o:
    o.write(f'# {len(rows)} files, {total} bytes ({total / 2**30:.2f} GiB) opened by Rocket League up to the main menu\n')
    for s, r in sorted(rows, key=lambda x: x[1]):
        o.write(f'{s}\t{r}\n')
print(f'{len(rows)} files, {total / 2**30:.2f} GiB')
