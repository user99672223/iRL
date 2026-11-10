#!/usr/bin/env python3
"""Build DXMT's on-device shader cache database from captured DXBC, so the phone skips runtime
conversion for every shader in it.

Matches madeira/dxmt exactly:
  file   shaders_<metal_version>.db       (dxmt_shader_cache.cpp; precise min/max = default)
  table  cache_<kDXMTShaderCacheVersion>  (19), columns key BLOB PRIMARY KEY, value BLOB NOT NULL (cache.c)
  key    sha1(DXBC bytes) || variant digest: 40 raw bytes (std::pair<Sha1Digest,Sha1Digest>)
  pixel variant digest = sha1(u32 sample_mask, u32 unorm_output_reg_mask, u8 dual_source, u8 disable_depth)
         (Sha1HashState::update(T) hashes sizeof(T) bytes, in CreateVariantShader<ShaderVariantPixel> order)
  value  SM50GetCompiledBitcode bytes for function ps_<sha1hex[:8]>_<digesthex> (dxmt_precompile)
Only the default pixel variant (sample mask all-ones, no dual-source, depth output kept, no unorm
reinterpretation) is precompiled. Vertex-shader variants hash the runtime input layout, so they are
filled from device logs later.
Usage: build_dxmt_db.py --dxbc build/shaders/dxbc --out build/shaders/dxmt/shaders_320.db [--limit N]"""
import argparse, hashlib, os, sqlite3, struct, subprocess, sys, tempfile
ap = argparse.ArgumentParser()
ap.add_argument('--dxbc', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--tool', default=os.path.join(os.path.dirname(__file__), '../../build/airconv/dxmt_precompile'))
ap.add_argument('--metal', type=int, default=320); ap.add_argument('--version', type=int, default=19)
ap.add_argument('--limit', type=int, default=0)
a = ap.parse_args()

VARIANTS = [(0xFFFFFFFF, 0, False, False)]  # (sample_mask, unorm_mask, dual_source, disable_depth)
def digest(sm, unorm, dual, depth):
    return hashlib.sha1(struct.pack('<IIBB', sm, unorm, dual, depth)).digest()

files = sorted(os.path.join(a.dxbc, 'ps', f) for f in os.listdir(os.path.join(a.dxbc, 'ps')) if f.endswith('.dxbc'))
if a.limit: files = files[:a.limit]
tmp = tempfile.mkdtemp(prefix='dxmtdb-', dir=os.path.dirname(os.path.abspath(a.out)) if os.path.isdir(os.path.dirname(os.path.abspath(a.out))) else None)
jobs, keys = [], {}
for p in files:
    sha = hashlib.sha1(open(p, 'rb').read()).digest()
    for sm, unorm, dual, depth in VARIANTS:
        d = digest(sm, unorm, dual, depth)
        name = f'ps_{sha.hex()[:8]}_{d.hex()}'
        out = os.path.join(tmp, f'{sha.hex()}_{d.hex()}.bin')
        keys[out] = sha + d
        jobs.append(f'{p}\t{name}\t{sm}\t{int(dual)}\t{int(depth)}\t{unorm}\t{out}')

# Parallel: split the job list over the CPU cores.
n = os.cpu_count() or 4
chunks = [jobs[i::n] for i in range(n)]
procs = [subprocess.Popen([a.tool, str(a.metal)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for c in chunks if c]
outs = [p.communicate('\n'.join(c) + '\n') for p, c in zip(procs, [c for c in chunks if c])]
ok, fails = [], []
for so, se in outs:
    for line in so.splitlines():
        (ok if line.startswith('ok ') else fails).append(line)
os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
if os.path.exists(a.out): os.remove(a.out)
db = sqlite3.connect(a.out)
db.execute(f'CREATE TABLE IF NOT EXISTS cache_{a.version} (key BLOB PRIMARY KEY, value BLOB NOT NULL);')
for line in ok:
    out = line[3:]
    db.execute(f'INSERT OR REPLACE INTO cache_{a.version} (key, value) VALUES (?, ?);', (keys[out], open(out, 'rb').read()))
    os.remove(out)
db.commit()
rows, size = db.execute(f'SELECT COUNT(*), SUM(LENGTH(value)) FROM cache_{a.version}').fetchone()
db.execute('VACUUM'); db.close()
os.rmdir(tmp) if not os.listdir(tmp) else None
print(f'{len(files)} pixel shaders, {len(ok)} precompiled, {len(fails)} failed -> {a.out}: {rows} rows, {(size or 0) >> 20} MB values')
for f in fails[:20]: print(f)
sys.exit(1 if fails and not ok else 0)
