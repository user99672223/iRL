#!/usr/bin/env python3
"""Package what CI needs to boot Rocket League to the main menu (trace-menu.sh results):
  * every file in menu-files.txt, in full, except the big texture caches
  * Textures*.tfc as SPARSE files: real size, but only the byte ranges the game read on the way to
    the menu (strace read/pread64/lseek on those files), rounded out to 1 MiB; the rest are holes
  * all of Binaries/Win64
Output: <out>/chunks/game.tar.zst.NNN (95 MB pieces, git-friendly), <out>/manifest.json, restore.sh.
Usage: package.py --game DIR --files menu-files.txt --reads STRACE [STRACE...] --out DIR --stage DIR"""
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile
ap = argparse.ArgumentParser()
ap.add_argument('--game', required=True); ap.add_argument('--files', required=True)
ap.add_argument('--reads', required=True, nargs='+', help='one or more read-range straces; ranges are unioned'); ap.add_argument('--out', required=True)
ap.add_argument('--stage', required=True, help='scratch dir on the same disk (sparse files take little space)')
a = ap.parse_args()
game = os.path.realpath(a.game)
ALIGN = 1 << 20

# --- read ranges per texture cache -------------------------------------------------------------
CALL = re.compile(r'^(\d+)\s+(?:(\w+)\((.*)|<\.\.\. (\w+) resumed>(.*))$')
pending, pos, ranges = {}, {}, {}
def fdpath(argstr):
    m = re.match(r'(\d+)<([^>]+)>', argstr)
    return (int(m.group(1)), m.group(2)) if m else (None, None)
def add(path, off, n):
    if n > 0 and path.endswith('.tfc'):
        ranges.setdefault(path, []).append((off, off + n))
import itertools
for line in itertools.chain.from_iterable(open(r, errors='replace') for r in a.reads):
    m = CALL.match(line.rstrip('\n'))
    if not m:
        continue
    pid = m.group(1)
    if m.group(2):
        name, rest = m.group(2), m.group(3)
        if rest.endswith('<unfinished ...>'):
            pending[pid] = (name, rest[:-len('<unfinished ...>')])
            continue
    else:
        name, rest = m.group(4), m.group(5)
        if pid not in pending:
            continue
        pname, head = pending.pop(pid)
        rest = head + rest
    fd, path = fdpath(rest)
    if fd is None:
        continue
    res = re.search(r'\)\s+=\s+(-?\d+)', rest)
    if not res:
        continue
    ret = int(res.group(1))
    if ret < 0:
        continue
    nums = re.findall(r',\s*(\d+)', rest[:res.start()])
    if name == 'pread64' or name.startswith('preadv'):
        off = int(nums[-1]) if nums else 0
        add(path, off, ret)
    elif name == 'read':
        off = pos.get(path, 0)
        add(path, off, ret)
        pos[path] = off + ret
    elif name == 'lseek':
        pos[path] = ret
    elif name == 'openat':
        pos[path] = 0

def merged(rs):
    rs = sorted((s // ALIGN * ALIGN, -(-e // ALIGN) * ALIGN) for s, e in rs)
    out = []
    for s, e in rs:
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out

# --- stage ---------------------------------------------------------------------------------------
files = [l.split('\t', 1)[1].strip() for l in open(a.files) if not l.startswith('#') and '\t' in l]
files += [os.path.join('Binaries/Win64', f) for f in os.listdir(os.path.join(game, 'Binaries/Win64'))
          if os.path.isfile(os.path.join(game, 'Binaries/Win64', f))]
files = sorted(set(files))
st = os.path.join(a.stage, 'game'); shutil.rmtree(st, ignore_errors=True); os.makedirs(st)
manifest = {'game': 'Rocket League (Epic)', 'purpose': 'boot to main menu in CI', 'files': []}
stored = 0
for rel in files:
    src, dst = os.path.join(game, rel), os.path.join(st, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    size = os.path.getsize(src)
    if rel.endswith('.tfc'):
        rs = merged(ranges.get(src, []))
        with open(src, 'rb') as i, open(dst, 'wb') as o:
            o.truncate(size)
            for s, e in rs:
                e = min(e, size); i.seek(s); o.seek(s); o.write(i.read(e - s))
        kept = sum(min(e, size) - s for s, e in rs)
        manifest['files'].append({'path': rel, 'size': size, 'sparse': True, 'stored_bytes': kept,
                                  'ranges': [[s, min(e, size)] for s, e in rs]})
        stored += kept
    else:
        shutil.copy2(src, dst)
        h = hashlib.sha256(open(src, 'rb').read()).hexdigest()
        manifest['files'].append({'path': rel, 'size': size, 'sha256': h})
        stored += size
print(f'staged {len(files)} files, {stored / 2**20:.0f} MiB of real data')
for f in manifest['files']:
    if f.get('sparse'):
        print(f"  {f['path']}: {f['stored_bytes'] / 2**20:.0f} MiB of {f['size'] / 2**30:.2f} GiB in {len(f['ranges'])} ranges")

# --- pack ----------------------------------------------------------------------------------------
os.makedirs(os.path.join(a.out, 'chunks'), exist_ok=True)
for old in os.listdir(os.path.join(a.out, 'chunks')):
    os.remove(os.path.join(a.out, 'chunks', old))
tar = subprocess.Popen(['tar', '--sparse', '--format=gnu', '-C', st, '-cf', '-', '.'], stdout=subprocess.PIPE)
zst = subprocess.Popen(['zstd', '-12', '-T0', '--long=27', '-q', '-c'], stdin=tar.stdout, stdout=subprocess.PIPE)
spl = subprocess.run(['split', '-b', '95M', '-d', '-a', '3', '-', os.path.join(a.out, 'chunks', 'game.tar.zst.')], stdin=zst.stdout)
tar.wait(); zst.wait()
assert tar.returncode == 0 and zst.returncode == 0 and spl.returncode == 0
chunks = sorted(os.listdir(os.path.join(a.out, 'chunks')))
manifest['chunks'] = [{'name': c, 'sha256': hashlib.sha256(open(os.path.join(a.out, 'chunks', c), 'rb').read()).hexdigest()} for c in chunks]
json.dump(manifest, open(os.path.join(a.out, 'manifest.json'), 'w'), indent=1)
total = sum(os.path.getsize(os.path.join(a.out, 'chunks', c)) for c in chunks)
print(f'{len(chunks)} chunks, {total / 2**20:.0f} MiB compressed')
shutil.rmtree(st)
