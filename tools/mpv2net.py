#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 k33bs
# additional terms under section 7 of the licence: see "licence" in README.md
#
# pulls the weights out of an mpv user shader and writes them as a meyra net file (resources/nets/*.net, format in
# resources/nets/README.md). knows the two layouts the shipped nets come in:
#   fsrcnnx (igv): fragment passes, 4 features per pass, "res += mat4(..) * NAME_texOff(vec2(x,y))"
#   artcnn (artoriuz): compute passes, all features of a layer in one pass, "resultN += M4(..) * inp_G_X_Y"
# the shader's own header comment (its licence) is carried over to the top of the net file.
#   tools/mpv2net.py SHADER.glsl "Menu Name" OUT.net
import re, sys

NUM = r'-?[0-9.]+(?:e-?[0-9]+)?'

def nums(s):
    return re.findall(NUM, s)

def passes(src):
    out = []
    for chunk in re.split(r'(?m)^(?=//!(?:HOOK|DESC) )', src)[1:]:
        if out and not re.search(r'(?m)^(vec4|void) hook', out[-1]):  # directives of one pass may start with either
            out[-1] += chunk
        else:
            out.append(chunk)
    res = []
    for c in out:
        d = {'desc': re.search(r'//!DESC (.*)', c).group(1).strip(), 'bind': re.findall(r'//!BIND (\S+)', c),
             'save': (re.findall(r'//!SAVE (\S+)', c) or [None])[0], 'body': c}
        res.append(d)
    return res

class Layer:
    def __init__(self, name, n):
        self.name, self.n, self.k, self.src, self.add, self.act = name, n, 1, [], [], 'none'
        self.w, self.b, self.a = {}, ['0'] * n, ['0'] * n  # w[(o, i, dy, dx)]
    def tap(self, o, i, dx, dy, v):
        self.w[(o, i, dy, dx)] = v
        self.k = max(self.k, 2 * max(abs(dx), abs(dy)) + 1)
    def write(self, f, nin):
        h = self.k // 2
        f.write('layer %s conv k=%d in=%s out=%d%s act=%s\n' % (self.name, self.k, '+'.join(self.src), self.n,
                                                             ' add=' + '+'.join(self.add) if self.add else '', self.act))
        f.write('w ' + ' '.join(self.w.get((o, i, dy, dx), '0') for o in range(self.n) for i in range(nin)
                                for dy in range(-h, h + 1) for dx in range(-h, h + 1)) + '\n')
        f.write('b ' + ' '.join(self.b) + '\n')
        if self.act == 'prelu':
            f.write('a ' + ' '.join(self.a) + '\n')

def fsrcnnx(ps):
    layers, where = [], {}  # texture name -> (layer name, first feature)
    stem = lambda p: re.sub(r'[ _]\d+$', '', p['desc'])
    swap = False
    i = 0
    while i < len(ps):
        grp = [p for p in ps[i:] if stem(p) == stem(ps[i])]
        grp = ps[i:i + len(grp)]
        i += len(grp)
        if grp[0]['save'] is None:  # aggregation: depth to space
            swap = 'index.x * 2 + index.y' in grp[0]['body']
            continue
        L = Layer('l%d' % len(layers), 4 * len(grp))
        for g, p in enumerate(grp):
            body = p['body'][p['body'].index('hook()'):]
            L.b[4 * g:4 * g + 4] = nums(re.search(r'vec4 res = vec4\(([^)]*)\)', body).group(1))
            for m in re.finditer(r'res \+= (?:mat4(?:x4)?|vec4)\(([^)]*)\) \* (?:float\()?(\w+)_texOff\((?:vec2\((-?\d+),(-?\d+)\)|0)\)', body):
                v, tex, dx, dy = nums(m.group(1)), m.group(2), int(m.group(3) or 0), int(m.group(4) or 0)
                if tex == 'LUMA':
                    src, base = 'y', 0
                    for r in range(4): L.tap(4 * g + r, 0, dx, dy, v[r])
                else:
                    src, base = where[tex]
                    for c in range(4):
                        for r in range(4): L.tap(4 * g + r, base + c, dx, dy, v[c * 4 + r])  # glsl matrices are column major
                if src not in L.src: L.src.append(src)
            for m in re.finditer(r'res \+= (\w+)_texOff\(0\);', body):
                src, base = where[m.group(1)]
                assert base == 4 * g
                if src not in L.add: L.add.append(src)
            m = re.search(r'res = max\(res, vec4\(0\.0\)\) \+ vec4\(([^)]*)\) \* min\(res, vec4\(0\.0\)\);', body)
            if m: L.act = 'prelu'; L.a[4 * g:4 * g + 4] = nums(m.group(1))
            n = len(re.findall(r'res \+= ', body))
            assert n == len(re.findall(r'res \+= (?:mat4|vec4)', body)) + len(re.findall(r'res \+= \w+_texOff\(0\);', body))
        assert len(L.src) == 1
        for g, p in enumerate(grp): where[p['save']] = (L.name, 4 * g)
        layers.append(L)
    return layers, swap

def artcnn(ps):
    layers = []
    for p in ps:
        body = p['body']
        if 'Depth-To-Space' in p['desc']:
            assert '[i0.y * 2 + i0.x]' in body
            continue
        groups = sorted(set(int(g) for g in re.findall(r'V4 result(\d+) = ', body)))
        L = Layer(p['save'], 4 * len(groups))
        L.src = ['y' if b == 'LUMA' else b for b in p['bind']]
        if len(L.src) > 1: assert re.search(r'inp\[0\]\[y\]\[x\] = V4\(\w+_mul \* texelFetch\([^;]*\) \+ \w+_mul \* texelFetch', body)
        for g in groups:
            L.b[4 * g:4 * g + 4] = nums(re.search(r'V4 result%d = V4\(([^)]*)\)' % g, body).group(1))
        for m in re.finditer(r'result(\d+) \+= (M4|V4)\(([^)]*)\) \* inp_(\d+)_(\d+)_(\d+);', body):
            g, v, ig, x, y = int(m.group(1)), nums(m.group(3)), int(m.group(4)), int(m.group(5)) - 1, int(m.group(6)) - 1
            if m.group(2) == 'V4':
                for r in range(4): L.tap(4 * g + r, 0, x, y, v[r])
            else:
                for c in range(4):
                    for r in range(4): L.tap(4 * g + r, 4 * ig + c, x, y, v[c * 4 + r])
        assert len(re.findall(r'result\d+ \+= ', body)) == len(re.findall(r'result\d+ \+= (?:M4|V4)\([^)]*\) \* inp_\d+_\d+_\d+;', body))
        if re.search(r'imageStore\(out_image, [^;]*max\(result0, V4\(0\.0\)\)\)', body): L.act = 'relu'
        layers.append(L)
    return layers, False

def main():
    path, name, dst = sys.argv[1:4]
    src = open(path, encoding='utf-8').read()
    head = src[:src.index('//!')].strip().splitlines()
    ps = passes(src)
    layers, swap = (artcnn if 'imageStore' in src else fsrcnnx)(ps)
    last = layers[-1]
    assert last.n == 4
    if swap:  # this shader's last pass takes feature dx*2+dy, the net format wants dy*2+dx: features 1 and 2 change places
        last.w = {((2, 1)[o - 1] if o in (1, 2) else o, i, dy, dx): v for (o, i, dy, dx), v in last.w.items()}
        last.b[1], last.b[2] = last.b[2], last.b[1]
    count = {'y': 1}
    with open(dst, 'w', encoding='utf-8') as f:
        f.write('# weights of %s, taken from the mpv shader %s by tools/mpv2net.py.\n' % (name, path.split('/')[-1]))
        f.write('# the shader\'s own notice follows, it covers these weights:\n#\n')
        for l in head: f.write('# ' + re.sub(r'^// ?', '', l) + '\n' if l.strip('/ ') else '#\n')
        f.write('\nmeyra-net 1\nname %s\n' % name)
        for L in layers:
            nin = count[L.src[0]]
            assert all(count[s] == nin for s in L.src) and all(count[s] == L.n for s in L.add)
            assert len(L.w) == L.n * nin * L.k * L.k, (L.name, len(L.w))
            L.write(f, nin)
            count[L.name] = L.n
        f.write('out %s\n' % last.name)
    print('%s: %d layers, %d weights' % (dst, len(layers), sum(len(L.w) + L.n for L in layers)))
    for L in layers: print('  %s k=%d in=%s out=%d add=%s act=%s' % (L.name, L.k, '+'.join(L.src), L.n, '+'.join(L.add), L.act))

main()
