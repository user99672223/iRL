#!/usr/bin/env python3
"""Convert the collected DXBC set to per-shader .metallib with the Linux airconv build.

  convert.py [--jobs N] [--limit N]
Input : build/shaders/dxbc/<stage>/<sha256>.dxbc        (tools/shaders/collect.py)
Output: build/shaders/metallib/<stage>/<sha256>.metallib + build/shaders/metallib/report.json
Logs  : logs/shader-convert-<ts>.log (every failure with airconv's full stderr)

Per shader: `airconv -S` first, and the shader is rejected if the IR declares any function that is
not an AIR/LLVM intrinsic. That catches shaders needing the MSAD/SamplePos/tessellation helper
modules, which the Linux build stubs out (see build-airconv-linux.sh); those stay on DXMT's
runtime path. Then `airconv -A` writes the .metallib. Idempotent: existing outputs are skipped.
Note: this is the default compilation variant (no PSO-specific arguments). See README.md.
"""
import argparse, concurrent.futures as cf, json, os, re, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AIRCONV = os.path.join(ROOT, 'build/airconv/airconv')
SRC = os.path.join(ROOT, 'build/shaders/dxbc')
DST = os.path.join(ROOT, 'build/shaders/metallib')
DECL = re.compile(r'^declare .*@("?)([^"(\s]+)\1\(', re.M)
NOISE = ('Failed to parse air bitcode', '[airconv] ml1382')


def one(stage, name):
    src = os.path.join(SRC, stage, name)
    out = os.path.join(DST, stage, name[:-5] + '.metallib')
    if os.path.exists(out):
        return 'skip', stage, name, ''
    with tempfile.NamedTemporaryFile(suffix='.ll') as ll:
        p = subprocess.run([AIRCONV, src, '-S', '-o', ll.name], capture_output=True, text=True)
        err = '\n'.join(l for l in p.stderr.splitlines() if not l.startswith(NOISE))
        if p.returncode:
            return 'fail', stage, name, f'airconv -S exit {p.returncode}\n{p.stderr}'
        bad = [f for _, f in DECL.findall(open(ll.name).read()) if not f.startswith(('air.', 'llvm.'))]
        if bad:
            return 'needs-helper', stage, name, 'unresolved: ' + ', '.join(sorted(set(bad)))
    p = subprocess.run([AIRCONV, src, '-A', '-o', out], capture_output=True, text=True)
    if p.returncode or not os.path.exists(out) or open(out, 'rb').read(4) != b'MTLB':
        if os.path.exists(out):
            os.remove(out)
        return 'fail', stage, name, f'airconv -A exit {p.returncode}\n{p.stderr}'
    return 'ok', stage, name, err


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jobs', type=int, default=6)
    ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    work = [(s, n) for s in sorted(os.listdir(SRC)) if os.path.isdir(os.path.join(SRC, s))
            for n in sorted(os.listdir(os.path.join(SRC, s))) if n.endswith('.dxbc')]
    if a.limit:
        work = work[:a.limit]
    for s in {s for s, _ in work}:
        os.makedirs(os.path.join(DST, s), exist_ok=True)
    log_path = os.path.join(ROOT, 'logs', f'shader-convert-{time.strftime("%Y%m%dT%H%M%S")}.log')
    counts, t0 = {}, time.time()
    with open(log_path, 'w') as log, cf.ThreadPoolExecutor(a.jobs) as ex:
        log.write(f'# {time.strftime("%Y-%m-%dT%H:%M:%S%z")} {" ".join(sys.argv)} airconv={AIRCONV} shaders={len(work)}\n')
        for i, (res, stage, name, msg) in enumerate(ex.map(lambda w: one(*w), work), 1):
            counts[res] = counts.get(res, 0) + 1
            if res not in ('ok', 'skip'):
                log.write(f'[{res}] {stage}/{name}\n{msg}\n')
            if i % 1000 == 0:
                log.write(f'progress {i}/{len(work)} {counts} {time.time() - t0:.0f}s\n'); log.flush()
        log.write(f'done {counts} in {time.time() - t0:.0f}s\n')
    ok = sum(1 for s in os.listdir(DST) if os.path.isdir(os.path.join(DST, s)) for _ in os.listdir(os.path.join(DST, s)))
    json.dump({'converted_total': ok, 'last_run': counts, 'log': os.path.relpath(log_path, ROOT)},
              open(os.path.join(DST, 'report.json'), 'w'), indent=1)
    print(f'{counts} -> {ok} metallibs; log {log_path}')


if __name__ == '__main__':
    main()
