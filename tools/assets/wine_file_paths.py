#!/usr/bin/env python3
"""Extract every game-folder path from a Wine WINEDEBUG=+file log (opened or not) and merge with
other lists. Paths appear as L"X:\\...\\rocketleague\\..." or unix "/.../rocketleague/..."; matching
is case-insensitive against the real files (Windows semantics). Also adds a guard set:
  * every package named in TAGame/Config/*.ini and Engine/Config/*.ini startup lists
    (lines like Package=, NativePackage=, +Package=, StartupPackages entries), resolved to *.upk
  * every .ini/.bin/.cfg/.txt/.json under TAGame/ and Engine/ (small)
Usage: wine_file_paths.py --game DIR --out menu-files.txt [--old old-menu-files.txt] WINELOG..."""
import argparse, os, re
ap = argparse.ArgumentParser()
ap.add_argument('--game', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--old'); ap.add_argument('logs', nargs='+')
a = ap.parse_args()
game = os.path.realpath(a.game)
index = {}
for dp, _, fns in os.walk(game):
    for fn in fns:
        rel = os.path.relpath(os.path.join(dp, fn), game)
        index[rel.lower().replace('\\', '/')] = rel
byname = {}
for low, rel in index.items():
    byname.setdefault(os.path.basename(low), []).append(rel)
found, why = set(), {}
def addrel(rel, reason):
    if rel not in found:
        found.add(rel); why[rel] = reason
# 1. Wine +file log
PAT = re.compile(r'rocketleague[\\/]+((?:[^"\s\\/]+[\\/]+)*[^"\s\\/]+)', re.I)
for lg in a.logs:
    with open(lg, errors='replace') as f:
        for line in f:
            if 'rocketleague' not in line.lower():
                continue
            for m in PAT.finditer(line.replace('\\\\', '\\')):
                low = re.sub(r'[\\/]+', '/', m.group(1)).lower()
                if low in index:
                    addrel(index[low], 'wine')
n_wine = len(found)
# 2. old strace list
if a.old:
    for l in open(a.old):
        if '\t' in l and not l.startswith('#'):
            rel = l.split('\t', 1)[1].strip()
            if os.path.isfile(os.path.join(game, rel)):
                addrel(rel, 'strace')
n_old = len(found)
# 3. guard: startup package lists
pkgs = set()
for cfgdir in ('TAGame/Config', 'Engine/Config'):
    d = os.path.join(game, cfgdir)
    if not os.path.isdir(d):
        continue
    for fn in os.listdir(d):
        if not fn.lower().endswith('.ini'):
            continue
        for line in open(os.path.join(d, fn), errors='replace'):
            m = re.match(r'\s*[+\-.!]?(?:Package|NativePackage|NativeScriptPackage|NonNativePackage|StartupPackage|EditPackage)s?\s*=\s*([A-Za-z0-9_]+)', line, re.I)
            if m:
                pkgs.add(m.group(1).lower())
for p in pkgs:
    for rel in byname.get(p + '.upk', []):
        addrel(rel, 'startup-list')
n_pkg = len(found)
# 4. guard: small config/data files
for low, rel in index.items():
    if (low.startswith('tagame/') or low.startswith('engine/')) and low.rsplit('.', 1)[-1] in ('ini', 'bin', 'cfg', 'txt', 'json'):
        if os.path.getsize(os.path.join(game, rel)) < 64 << 20:
            addrel(rel, 'config')
rows = sorted(found)
total = sum(os.path.getsize(os.path.join(game, r)) for r in rows)
with open(a.out, 'w') as o:
    o.write(f'# {len(rows)} files, {total} bytes ({total / 2**30:.2f} GiB): Wine +file opens to the main menu, old strace list, startup package lists, small config files\n')
    for r in rows:
        o.write(f'{os.path.getsize(os.path.join(game, r))}\t{r}\n')
print(f'wine={n_wine} +strace={n_old - n_wine} +startup-list={n_pkg - n_old} +config={len(found) - n_pkg} -> {len(rows)} files, {total / 2**30:.2f} GiB')
print('startup packages named in ini:', len(pkgs))
