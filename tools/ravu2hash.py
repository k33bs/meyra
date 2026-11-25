#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 k33bs
# additional terms under section 7 of the licence: see "licence" in README.md
#
# turns a ravu-lite weights file (bjin/mpv-prescalers, source branch, weights/ravu-lite_weights-r3.py) into the table
# upscale 5 reads (resources/ravu-lite-r3.txt). only r3 (5x5 taps, 24 x 4 x 3 buckets) fits the shader.
#   tools/ravu2hash.py ravu-lite_weights-r3.py NOTICE.txt OUT.txt
# NOTICE.txt: the licence header of the repo's generator (ravu-lite.py), carried over to the top of the table.
#
# their layout: model_weights[angle][strength][coherence][sub][tap], tap = x * 5 + y (x across, y down, -2..2
# around the source pixel), sub = 2 * right + bottom. ours: tap = y * 5 + x, sub = 2 * bottom + right, and only
# taps 0..12 are written: every kernel is point symmetric (sub s at tap k = sub 3 - s at tap 24 - k), the shader
# gets the rest from that
import ast, sys

src, notice, out = sys.argv[1:4]
v = {}
for line in open(src):
    if '=' in line:
        k, x = line.split('=', 1)
        v[k.strip()] = ast.literal_eval(x.strip())
assert v['radius'] == 3 and v['gradient_radius'] == 2, 'r3 only'
assert (v['quant_angle'], v['quant_strength'], v['quant_coherence']) == (24, 4, 3)
w = v['model_weights']

def ours(b, s, k):  # their sub-pixel and tap for ours
    x, y = k % 5, k // 5
    return b[2 * (s & 1) + (s >> 1)][x * 5 + y]

rows, worst = [], 0
for a in range(24):
    for st in range(4):
        for c in range(3):
            b = w[a][st][c]
            r = []
            for k in range(13):
                for s in range(4):
                    p, q = ours(b, s, k), ours(b, 3 - s, 24 - k)
                    worst = max(worst, abs(p - q))
                    r.append((p + q) / 2)
            rows.append(r)
assert worst < 1e-5, 'not point symmetric: %g' % worst

with open(out, 'w') as f:
    f.write('# filter table of ravu-lite r3, from weights/ravu-lite_weights-r3.py of https://github.com/bjin/mpv-prescalers\n')
    f.write('# (source branch) by tools/ravu2hash.py. the repo\'s notice follows, it covers these weights:\n#\n')
    for line in open(notice):
        f.write(('# ' + line.rstrip()).rstrip() + '\n')
    f.write('\nmeyra-hash 1\n')
    f.write('strength %s\n' % ' '.join('%.9g' % x for x in v['min_strength']))
    f.write('coherence %s\n' % ' '.join('%.9g' % x for x in v['min_coherence']))
    f.write('gauss %s\n' % ' '.join('%.9g' % x for r in v['gaussian'] for x in r))
    f.write('# 288 rows, bucket (angle * 4 + strength) * 3 + coherence. per tap 0..12 (y * 5 + x) four sub-pixels:\n')
    f.write('# left top, right top, left bottom, right bottom\n')
    for r in rows:
        f.write('w %s\n' % ' '.join('%.9g' % x for x in r))
print('%s: %d buckets, symmetry off by %.2g at most' % (out, len(rows), worst))
