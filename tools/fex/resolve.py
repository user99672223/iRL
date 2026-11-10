#!/usr/bin/env python3
"""Resolve git conflict hunks in one file: resolve.py FILE CHOICE [CHOICE...]
CHOICE per hunk, in order: ours | theirs | both (ours then theirs) | rboth (theirs then ours) | @path (text file with replacement)."""
import sys, re
path, choices = sys.argv[1], sys.argv[2:]
src = open(path).read().split('\n')
out, i, h = [], 0, 0
while i < len(src):
    l = src[i]
    if l.startswith('<<<<<<< '):
        ours, theirs, base, cur = [], [], [], 'ours'; i += 1
        while not src[i].startswith('>>>>>>> '):
            if src[i].startswith('||||||| '): cur = 'base'
            elif src[i] == '=======': cur = 'theirs'
            else: {'ours': ours, 'theirs': theirs, 'base': base}[cur].append(src[i])
            i += 1
        c = choices[h]; h += 1
        out += {'ours': ours, 'theirs': theirs, 'both': ours + theirs, 'rboth': theirs + ours}.get(c) or open(c[1:]).read().rstrip('\n').split('\n')
    else:
        out.append(l)
    i += 1
assert h == len(choices), f'{path}: {h} hunks, {len(choices)} choices'
open(path, 'w').write('\n'.join(out))
print(f'{path}: resolved {h} hunks: {" ".join(choices)}')
