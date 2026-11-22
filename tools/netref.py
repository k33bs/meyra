#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 k33bs
# additional terms under section 7 of the licence: see "licence" in README.md
#
# reference for the net files in resources/nets (format: resources/nets/README.md): runs one on a raw picture the
# slow, obvious way and writes the resulting luma (2x, or same size for a 1x net) as raw 8 bit. the shader passes the app builds from the same file are
# checked against this, and an export from a training framework can be checked the same way.
# plain python, no numpy: use a crop of 100x100 or so.
#   tools/netref.py FILE.net IN.raw W H OUT.gray [gray|rgb]
# IN.raw is W x H, 8 bit luma (gray, default) or rgb24, of which the luma is taken the way the app does
import sys

def load(path):
    toks, name = [], ''
    for l in open(path, encoding='utf-8'):
        l = l.split('#')[0]
        if l.startswith('name '): name = l[5:].strip(); continue
        toks += l.split()
    it = iter(toks)
    assert next(it) == 'meyra-net' and next(it) == '1'
    layers, out, base, feat = [], None, 'none', {'y': 1}
    def floats(tag, n):
        assert next(it) == tag, tag
        return [float(next(it)) for _ in range(n)]
    for t in it:
        if t == 'out':
            out = next(it)
            if next(it, None) == 'base': base = next(it)
            break
        assert t == 'layer'
        L = {'id': next(it), 'add': []}
        assert next(it) == 'conv'
        while True:
            k, v = next(it).split('=')
            L[k] = v
            if k == 'act': break
        L['k'], L['out'] = int(L['k']), int(L['out'])
        L['in'] = L['in'].split('+')
        L['add'] = L['add'].split('+') if L['add'] else []
        nin = feat[L['in'][0]]
        L['w'] = floats('w', L['out'] * nin * L['k'] ** 2)
        L['b'] = floats('b', L['out'])
        if L['act'] == 'prelu': L['a'] = floats('a', L['out'])
        feat[L['id']] = L['out']
        layers.append(L)
    assert out == layers[-1]['id'] and layers[-1]['out'] in (1, 4)
    return name, layers, base

def run(layers, base, y, W, H):
    val = {'y': [y]}  # id -> [feature][row][col]
    cl = lambda v, hi: 0 if v < 0 else hi if v > hi else v
    for L in layers:
        k, n, h = L['k'], L['out'], L['k'] // 2
        src = [val[s] for s in L['in']]
        nin = len(src[0])
        x = [[[sum(s[i][r][c] for s in src) for c in range(W)] for r in range(H)] for i in range(nin)] if len(src) > 1 else src[0]
        res = []
        for o in range(n):
            acc = [[L['b'][o]] * W for _ in range(H)]
            for i in range(nin):
                for ky in range(k):
                    for kx in range(k):
                        w = L['w'][((o * nin + i) * k + ky) * k + kx]
                        if w == 0: continue
                        for r in range(H):
                            row, a = x[i][cl(r + ky - h, H - 1)], acc[r]
                            for c in range(W): a[c] += w * row[cl(c + kx - h, W - 1)]  # edges repeat
            for s in L['add']:
                for r in range(H):
                    for c in range(W): acc[r][c] += val[s][o][r][c]
            if L['act'] != 'none':
                al = L['a'][o] if L['act'] == 'prelu' else 0
                acc = [[v if v > 0 else al * v for v in row] for row in acc]
            res.append(acc)
        val[L['id']] = res
    f = val[layers[-1]['id']]
    if len(f) == 1:  # same size net
        return [[cl(f[0][r][c] + (y[r][c] if base != 'none' else 0), 1.0) for c in range(W)] for r in range(H)]
    out = [[f[(r & 1) * 2 + (c & 1)][r >> 1][c >> 1] for c in range(2 * W)] for r in range(2 * H)]
    for r in range(2 * H):
        for c in range(2 * W):
            if base == 'nearest': out[r][c] += y[r >> 1][c >> 1]
            elif base == 'bilinear':
                fy, fx = (r + 0.5) / 2 - 0.5, (c + 0.5) / 2 - 0.5
                r0, c0 = int(fy // 1), int(fx // 1)
                ty, tx = fy - r0, fx - c0
                p = lambda rr, cc: y[cl(rr, H - 1)][cl(cc, W - 1)]
                out[r][c] += (p(r0, c0) * (1 - tx) + p(r0, c0 + 1) * tx) * (1 - ty) + (p(r0 + 1, c0) * (1 - tx) + p(r0 + 1, c0 + 1) * tx) * ty
    return [[cl(v, 1.0) for v in row] for row in out]

def main():
    path, src, W, H, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    rgb = len(sys.argv) > 6 and sys.argv[6] == 'rgb'
    d = open(src, 'rb').read()
    assert len(d) == W * H * (3 if rgb else 1), 'input size'
    if rgb: y = [[(0.2126 * d[3 * (r * W + c)] + 0.7152 * d[3 * (r * W + c) + 1] + 0.0722 * d[3 * (r * W + c) + 2]) / 255 for c in range(W)] for r in range(H)]
    else: y = [[d[r * W + c] / 255 for c in range(W)] for r in range(H)]
    name, layers, base = load(path)
    out = run(layers, base, y, W, H)
    open(dst, 'wb').write(bytes(int(v * 255 + 0.5) for row in out for v in row))
    print('%s: %dx%d -> %dx%d' % (name, W, H, len(out[0]), len(out)))

if __name__ == '__main__':
    main()
