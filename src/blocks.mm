// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// the method (block matching on the frame in between, coarse to fine, a per-pixel choice among a few vectors, a 3x3
// vector medoid) follows macframegen; the whole picture's shift as a start for fast pans, and taking the side that
// fits where the two frames disagree, follow zerofg. see THIRD_PARTY_NOTICES.md. written for meyra, its own numbers
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "blocks.h"
#include "common.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <os/lock.h>
#include <string>
#include <vector>

namespace blocks {

// all matching is on luma, chroma goes along. a pyramid per frame: level 1 is half the picture, every next one half
// again, the last one the first at most kTopMax wide. a field is one vector per 8x8 cell of a level, kept in full
// picture pixels, prev to cur, and read as "this piece of the frame in between sits at p - v/2 in prev, p + v/2 in
// cur". every level's search starts from the field above it; the top one from a 1x1 field that holds zero, or with
// genShift the shift of the whole picture. after the search a medoid, at the end a choice per level 1 pixel
static NSString *const kKernels = @R"M(
#include <metal_stdlib>
using namespace metal;
constexpr sampler tween(address::clamp_to_edge, coord::pixel, filter::linear); // bilinear, in pixels, edges repeated
constant int kCell = 8;      // a cell, in pixels of its level
constant int kWin = 12;      // a cell is judged over this: itself and 2 px of the cells around
constant float kOut = 0.01f; // search: a tap that reads outside the picture costs this (an edge that slid in or out)
// slots, every kernel: what it writes first, then what it reads (prev before cur, frames before fields), its
// constants in buffer 7

// each pixel of the next level is the mean of the 2x2 under it: one filtered read where the four meet
kernel void halve(texture2d<float, access::write> dst [[texture(0)]], texture2d<float> src [[texture(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    dst.write(src.sample(tween, float2(gid * 2 + 1)), gid);
}

// prev read at p - h against cur at p + h over the n x n pixels from o, only taps with both samples inside the
// picture. drift: their summed difference and how many, for the mean; every second tap each way, read where four
// pixels meet, so all of them in a quarter of the reads. mismatch: the summed absolute difference less a given mean,
// and how many taps. selects, not branches: a branch in here doubled the search's time
static float2 drift(texture2d<float> prev, texture2d<float> cur, float2 o, int n, float2 h) {
    float2 lo = fabs(h), hi = float2(prev.get_width(), prev.get_height()) - lo, s = 0;
    for (int y = 0; y < n; y += 2) // every second tap each way: the mean needs no more
        for (int x = 0; x < n; x += 2) {
            float2 p = o + float2(x, y) + 1.0f;
            s += select(float2(0), float2(prev.sample(tween, p - h).r - cur.sample(tween, p + h).r, 1), all(p >= lo) && all(p <= hi));
        }
    return s;
}
static float2 mismatch(texture2d<float> prev, texture2d<float> cur, float2 o, int n, float2 h, float mean) {
    float2 lo = fabs(h), hi = float2(prev.get_width(), prev.get_height()) - lo, s = 0;
    for (int y = 0; y < n; y++)
        for (int x = 0; x < n; x++) {
            float2 p = o + float2(x, y) + 0.5f;
            s += select(float2(0), float2(fabs(prev.sample(tween, p - h).r - cur.sample(tween, p + h).r - mean), 1), all(p >= lo) && all(p <= hi));
        }
    return s;
}

// the vectors a field offers at a point given in its cells (cell k spans k..k+1): the cell the point is in, the one
// beside it and the one above or below it on the sides the point leans to, and a blend of the three, linear over the
// triangle of their centres. no reads of the far corner
struct Near { float2 own, side, updown, blend; };
static Near nearby(texture2d<float, access::read> f, float2 at) {
    int2 last = int2(f.get_width(), f.get_height()) - 1;
    int2 k = clamp(int2(floor(at)), int2(0), last);
    float2 d = clamp(at - float2(k) - 0.5f, -0.5f, 0.5f);
    int2 lean = select(int2(-1), int2(1), d >= 0.0f);
    Near r;
    r.own = f.read(uint2(k)).xy;
    r.side = f.read(uint2(clamp(k + int2(lean.x, 0), int2(0), last))).xy;
    r.updown = f.read(uint2(clamp(k + int2(0, lean.y), int2(0), last))).xy;
    d = fabs(d);
    r.blend = r.own + d.x * (r.side - r.own) + d.y * (r.updown - r.own);
    return r;
}

// one simdgroup per cell. starts: what the field above offers here (the blend, then the three cells) and zero, each
// searched over its own square of +-r steps; a start whose square lies inside another one's is skipped. the blend is
// also what the cost penalty measures from. at the top the field above is 1x1: all of it is zero or the picture's shift
// small (kSmall): the medoid above takes out a thing narrower than two of its cells (a character, a ball) with the
// wrong vectors, so the cell above's own vector from before its medoid is one more start (rRaw, -1 none). and where
// even the best fits badly (over wideOver), a second look +-rWide steps of twice the size around it: a thing moving
// some 30-60 px a frame against its ground is otherwise out of reach below the top
struct Lv { int rBlend, rNear, rZero; float step, toFull, lam, zeroBonus; int rRaw, rWide; float wideOver, edge; };
static float cellCost(texture2d<float> prev, texture2d<float> cur, float2 o, float2 v, float2 want, float lam) {
    float2 d = drift(prev, cur, o, kWin, v * 0.5f); // its mean out: a fade or a flash changes brightness, not where things are
    float2 m = mismatch(prev, cur, o, kWin, v * 0.5f, d.x / max(d.y, 1.0f)), off = fabs(v - want);
    return (m.x + kOut * (float(kWin * kWin) - m.y)) / float(kWin * kWin) + lam * (off.x + off.y);
}
kernel void search(texture2d<float, access::write> out [[texture(0)]], texture2d<float> prev [[texture(1)]],
                   texture2d<float> cur [[texture(2)]], texture2d<float, access::read> above [[texture(3)]],
                   texture2d<float, access::read> rawAbove [[texture(4)]],
                   constant Lv &p [[buffer(7)]], uint2 cell [[threadgroup_position_in_grid]],
                   uint lane [[thread_index_in_simdgroup]]) {
    Near n = nearby(above, (float2(cell) + 0.5f) * 0.5f);
    // kBorder: within p.edge (this level's px) of the picture's edge kSmall's start from above and its wide look stay
    // out: there they found the edge's own mess (what slid in, the hud in the corners) more than anything small
    float2 o = float2(cell) * float(kCell) - float(kWin - kCell) * 0.5f, size = float2(prev.get_width(), prev.get_height());
    bool atEdge = p.edge > 0 && (any(o < p.edge) || any(o + float(kWin) > size - p.edge));
    int ns = p.rRaw >= 0 && !atEdge ? 6 : 5;
    float2 st[6] = {n.blend, n.own, n.side, n.updown, 0, 0};
    if (ns == 6) st[5] = rawAbove.read(min(cell / 2, uint2(rawAbove.get_width(), rawAbove.get_height()) - 1)).xy;
    int r[6] = {p.rBlend, p.rNear, p.rNear, p.rNear, p.rZero, p.rRaw}, end[6], total = 0;
    for (int i = 0; i < ns; i++) st[i] = round(st[i] / (p.toFull * p.step)) * p.step; // in this level's pixels, on the grid
    float2 want = st[0];
    for (int i = 0; i < ns; i++) {
        bool inside = false;
        for (int j = 0; j < ns; j++)
            if (j != i && (r[j] > r[i] || (r[j] == r[i] && j < i)) && all(fabs(st[j] - st[i]) <= float(r[j] - r[i]) * p.step)) inside = true;
        total += inside ? 0 : (2 * r[i] + 1) * (2 * r[i] + 1);
        end[i] = total;
    }
    float best = INFINITY;
    float2 got = 0;
    for (int t = int(lane); t < total; t += 32) {
        int i = 0;
        while (t >= end[i]) i++;
        int j = t - (i ? end[i - 1] : 0), w = 2 * r[i] + 1;
        float2 v = st[i] + float2(j % w - r[i], j / w - r[i]) * p.step;
        float c = cellCost(prev, cur, o, v, want, p.lam);
        if (all(v == 0.0f)) c -= p.zeroBonus;
        if (c < best) { best = c; got = v; }
    }
    float low = simd_min(best);
    if (p.rWide > 0 && low > p.wideOver && !atEdge) { // the same for the whole simdgroup
        float2 mid = simd_shuffle(got, simd_min(best == low ? lane : 32u));
        int w = 2 * p.rWide + 1;
        for (int t = int(lane); t < w * w; t += 32) {
            float2 v = mid + float2(t % w - p.rWide, t / w - p.rWide) * 2.0f * p.step;
            float c = cellCost(prev, cur, o, v, want, p.lam);
            if (c < best) { best = c; got = v; }
        }
        low = simd_min(best);
    }
    if (lane == simd_min(best == low ? lane : 32u)) out.write(float4(got * p.toFull, 0, 0), cell);
}

// a medoid over 3x3 vectors: each of the nine adds its l1 distance to every other one (36 pairs, each counted for
// both), the lowest total wins, the middle one on a tie. single wrong vectors go, edges between motions keep their place
kernel void medoid(texture2d<float, access::write> dst [[texture(0)]], texture2d<float, access::read> src [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    int2 last = int2(src.get_width(), src.get_height()) - 1;
    float2 v[9];
    float sum[9];
    for (int i = 0; i < 9; i++) {
        v[i] = src.read(uint2(clamp(int2(gid) + int2(i % 3, i / 3) - 1, int2(0), last))).xy;
        sum[i] = 0;
    }
    for (int i = 0; i < 9; i++)
        for (int j = i + 1; j < 9; j++) {
            float2 d = fabs(v[i] - v[j]);
            sum[i] += d.x + d.y;
            sum[j] += d.x + d.y;
        }
    int at = 4;
    for (int i = 0; i < 9; i++) if (sum[i] < sum[at] - 1e-4f) at = i;
    dst.write(float4(v[at], 0, 0), gid);
}

// where only one of the two frames has a cell's content (slid in or out at an edge) its cost is flat and its vector is
// what the coarser level guessed: it takes the vector of the nearest cell further in that could be measured. measured:
// at least half of the cell's window has both samples inside. level 1, run on the finest field
static float seen(float2 o, float2 h, float2 size) {
    float2 lo = max(o, fabs(h)), hi = min(o + float(kWin), size - fabs(h));
    float2 f = saturate((hi - lo) / float(kWin));
    return f.x * f.y;
}
kernel void fill(texture2d<float, access::write> dst [[texture(0)]], texture2d<float, access::read> src [[texture(1)]],
                 constant float2 &size [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    int2 n = int2(src.get_width(), src.get_height());
    float2 v = src.read(gid).xy;
    float2 o = float2(gid) * float(kCell) - float(kWin - kCell) * 0.5f;
    if (seen(o, v * 0.25f, size) < 0.5f) {
        // inwards along the axis the vector leaves the picture by
        float2 h = fabs(v * 0.25f);
        bool across = min(o.x + float(kWin), size.x - h.x) - max(o.x, h.x) < min(o.y + float(kWin), size.y - h.y) - max(o.y, h.y);
        int2 step = across ? int2(int(gid.x) * 2 < n.x ? 1 : -1, 0) : int2(0, int(gid.y) * 2 < n.y ? 1 : -1);
        for (int2 c = int2(gid) + step; all(c >= 0) && all(c < n); c += step) {
            float2 w = src.read(uint2(c)).xy;
            if (seen(float2(c) * float(kCell) - float(kWin - kCell) * 0.5f, w * 0.25f, size) >= 0.5f) { v = w; break; }
        }
    }
    dst.write(float4(v, 0, 0), gid);
}

// genShift: the whole picture moved by one shift, on the top level. one threadgroup per shift, the mean difference
// where the two overlap (every second pixel each way), at least half the picture overlapping
struct GP { int range; float scale; };
kernel void shiftCost(device float *cost [[buffer(0)]], texture2d<float, access::read> prev [[texture(0)]],
                      texture2d<float, access::read> cur [[texture(1)]], constant GP &p [[buffer(7)]],
                      uint2 tg [[threadgroup_position_in_grid]], uint t [[thread_index_in_threadgroup]],
                      uint sg [[simdgroup_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]]) {
    threadgroup float2 part[2];
    int2 d = int2(tg) - p.range;
    int w = int(prev.get_width()), h = int(prev.get_height());
    int x0 = max(0, -d.x), x1 = min(w, w - d.x), y0 = max(0, -d.y), y1 = min(h, h - d.y);
    float2 s = 0;
    for (int y = y0 + int(t / 32) * 2; y < y1; y += 4)
        for (int x = x0 + int(t % 32) * 2; x < x1; x += 64)
            s += float2(fabs(prev.read(uint2(x, y)).r - cur.read(uint2(x + d.x, y + d.y)).r), 1.0f);
    s = simd_sum(s);
    if (lane == 0) part[sg] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (t != 0) return;
    s = part[0] + part[1];
    bool enough = (x1 - x0) * (y1 - y0) * 2 >= w * h;
    cost[tg.y * (2 * p.range + 1) + tg.x] = enough && s.y > 0 ? s.x / s.y : INFINITY;
}
// the cheapest shift into the 1x1 field the top level starts from. equal costs go to the shift nearer zero, so a
// black or flat picture says zero
static bool cheaper(float c, int i, float bc, int bi, int side, int range) {
    int di = abs(i % side - range) + abs(i / side - range), db = abs(bi % side - range) + abs(bi / side - range);
    return c < bc || (c == bc && di < db);
}
kernel void shiftBest(texture2d<float, access::write> g [[texture(0)]], device const float *cost [[buffer(0)]],
                      constant GP &p [[buffer(7)]], uint t [[thread_index_in_threadgroup]]) {
    threadgroup float tc[256];
    threadgroup int ti[256];
    int side = 2 * p.range + 1, n = side * side;
    float c = INFINITY;
    int at = n / 2;
    for (int i = int(t); i < n; i += 256) if (cheaper(cost[i], i, c, at, side, p.range)) { c = cost[i]; at = i; }
    tc[t] = c; ti[t] = at;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (t != 0) return;
    for (int i = 1; i < 256; i++) if (cheaper(tc[i], ti[i], c, at, side, p.range)) { c = tc[i]; at = ti[i]; }
    float2 v = isfinite(c) ? float2(at % side - p.range, at / side - p.range) * p.scale : float2(0);
    g.write(float4(v, 0, 0), uint2(0));
}

// per pixel of level 1 (the chroma grid): which vector to use. the field's blend holds the place: it comes from the
// 12x12 search and agrees with the cells around. a challenger takes it over only when its 3x3 cost is under a share
// of the holder's, the cells first (own, side, up or down), zero last: zero has to beat whatever holds by then.
// equal never takes over, and nothing takes over a holder that matches exactly. only taps with both samples inside
// count, averaged; with fewer than 5 of 9 inside a vector is not measured: a challenger is passed over, an unmeasured
// blend stays (an edge slid in, the edge fill chose it). the plain difference here: the field already took the mean
// out, and a 3x3 is too small to lose its own (0.1 db worse)
struct PK { float cellShare, zeroShare, zTie, zGap, zTex; };
static float patchCost(texture2d<float> prev, texture2d<float> cur, float2 q, float2 v) {
    float2 m = mismatch(prev, cur, q - 1.5f, 3, v * 0.25f, 0); // level 1: half of v is v / 4 of its pixels
    return m.y >= 5 ? m.x / m.y : INFINITY;
}
kernel void pick(texture2d<float, access::write> vec [[texture(0)]], texture2d<float, access::write> cost [[texture(1)]],
                 texture2d<float> prev [[texture(2)]], texture2d<float> cur [[texture(3)]],
                 texture2d<float, access::read> field [[texture(4)]],
                 constant PK &p [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    float2 q = float2(gid) + 0.5f;
    Near n = nearby(field, q / float(kCell));
    float2 holder = n.blend;
    float held = patchCost(prev, cur, q, holder);
    if (isfinite(held)) {
        float2 challenger[4] = {n.own, n.side, n.updown, 0};
        for (int i = 0; i < 4; i++) {
            float c = patchCost(prev, cur, q, challenger[i]);
            // still (kStill): a narrow still thing over a fast pan fits the pan too, both sides of it land on ground.
            // where zero fits about as well and the place has texture, zero takes it
            if (i == 3 && p.zTie > 0 && c < p.zTie && c <= held + p.zGap) {
                int2 hi = int2(prev.get_width(), prev.get_height()) - 1;
                float m = 0, d = 0;
                for (int k = 0; k < 16; k++) m += prev.read(uint2(clamp(int2(q) + int2(k % 4 - 2, k / 4 - 2), int2(0), hi))).r / 16;
                for (int k = 0; k < 16; k++) d += fabs(prev.read(uint2(clamp(int2(q) + int2(k % 4 - 2, k / 4 - 2), int2(0), hi))).r - m) / 16;
                if (d > p.zTex) { holder = 0; held = c; continue; }
            }
            if (c < held * (i < 3 ? p.cellShare : p.zeroShare)) { holder = challenger[i]; held = c; }
        }
    }
    vec.write(float4(holder, 0, 0), gid);
    cost.write(float4(isfinite(held) ? held : 0.0f), gid); // for kSides
}

// band (kBand): where no vector fits both sides (pick cost over p.lo), the place is seen in one frame only: ground a
// still or slow thing covers or uncovers. its vector comes from around, rings 4, 8, 16, 32 px out (chroma pixels),
// the first one the field agrees with where it lands on at least one side. a few passes reach into wider bands
struct BF { float lo, tol; int steps; };
kernel void band(texture2d<float, access::write> dst [[texture(0)]], texture2d<float, access::read> vec [[texture(1)]],
                 texture2d<float, access::read> cost [[texture(2)]], constant BF &p [[buffer(7)]],
                 uint2 gid [[thread_position_in_grid]]) {
    int2 last = int2(vec.get_width(), vec.get_height()) - 1;
    float2 v = vec.read(gid).xy, q = float2(gid) + 0.5f;
    if (cost.read(gid).r <= p.lo) { dst.write(float4(v, 0, 0), gid); return; }
    auto at = [&](float2 c) { return vec.read(uint2(clamp(int2(floor(c)), int2(0), last))).xy; };
    float best = INFINITY;
    for (int r = 0; r < p.steps; r++)
        for (int k = 0; k < 8; k++) {
            float2 u = at(q + float2(cos(k * 0.785398f), sin(k * 0.785398f)) * float(4 << r));
            float s = min(length(at(q - u * 0.25f) - u), length(at(q + u * 0.25f) - u)); // half of u, in chroma pixels
            if (s >= p.tol) continue;
            s += 0.05f * float(r); // nearer rings first
            if (s < best) { best = s; v = u; }
        }
    dst.write(float4(v, 0, 0), gid);
}

// whole (kWhole): how much of the picture no vector fits, counted once a simdgroup
kernel void unfit(device atomic_uint *n [[buffer(0)]], texture2d<float, access::read> cost [[texture(0)]],
                  constant float &over [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    uint bad = simd_sum(cost.read(gid).r > over ? 1u : 0u);
    if (simd_is_first()) atomic_fetch_add_explicit(n, bad, memory_order_relaxed);
}

// sides (kSides), once a pair in solve(): which side to believe where something covers or uncovers. every pixel of the
// frame in between writes its match cost where it lands in prev and in cur, the lowest stays (a z-buffer by cost). a
// side whose spot is held by something that matches clearly better shows that thing there, not this one: the other
// side is taken. +1 prev only, -1 cur only, 0 both. then smoothed over 5x5 points 2 apart, counting the ones that move
// like here, so whole parts of an edge take the same side
struct SD { float lo, hi, sig; int step; };
kernel void ownClear(device uint *held [[buffer(0)]], uint2 gid [[thread_position_in_grid]], uint2 n [[threads_per_grid]]) {
    held[gid.y * n.x + gid.x] = 0xffffffffu;
}
kernel void ownHit(device atomic_uint *held [[buffer(0)]], texture2d<float, access::read> vec [[texture(0)]],
                   texture2d<float, access::read> cost [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 n = int2(vec.get_width(), vec.get_height());
    float2 q = float2(gid) + 0.5f, v = vec.read(gid).xy;
    uint key = uint(saturate(cost.read(gid).r) * 65535.0f);
    int2 a = int2(floor(q - v * 0.25f)), b = int2(floor(q + v * 0.25f)); // half of v, in chroma pixels
    if (all(a >= 0) && all(a < n)) atomic_fetch_min_explicit(&held[a.y * n.x + a.x], key, memory_order_relaxed);
    if (all(b >= 0) && all(b < n)) atomic_fetch_min_explicit(&held[n.x * n.y + b.y * n.x + b.x], key, memory_order_relaxed);
}
kernel void sideOwn(texture2d<float, access::write> dst [[texture(0)]], texture2d<float, access::read> vec [[texture(1)]],
                    texture2d<float, access::read> cost [[texture(2)]], device const uint *held [[buffer(0)]],
                    constant SD &p [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    int2 n = int2(vec.get_width(), vec.get_height());
    float2 q = float2(gid) + 0.5f, v = vec.read(gid).xy;
    float e = cost.read(gid).r, ea = 2, eb = 2;
    int2 a = int2(floor(q - v * 0.25f)), b = int2(floor(q + v * 0.25f));
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            int2 pa = a + int2(x, y), pb = b + int2(x, y);
            if (all(pa >= 0) && all(pa < n)) ea = min(ea, float(held[pa.y * n.x + pa.x]) / 65535.0f);
            if (all(pb >= 0) && all(pb < n)) eb = min(eb, float(held[n.x * n.y + pb.y * n.x + pb.x]) / 65535.0f);
        }
    dst.write(float4(smoothstep(p.lo, p.hi, e - eb) - smoothstep(p.lo, p.hi, e - ea)), gid);
}
kernel void sideSmooth(texture2d<float, access::write> dst [[texture(0)]], texture2d<float, access::read> src [[texture(1)]],
                       texture2d<float, access::read> vec [[texture(2)]], constant SD &p [[buffer(7)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 last = int2(vec.get_width(), vec.get_height()) - 1;
    float2 v = vec.read(gid).xy;
    float s = 0, n = 0;
    for (int y = -2; y <= 2; y++)
        for (int x = -2; x <= 2; x++) {
            uint2 at = uint2(clamp(int2(gid) + int2(x, y) * p.step, int2(0), last));
            float2 d = vec.read(at).xy - v;
            float w = exp(-dot(d, d) / (p.sig * p.sig));
            s += w * src.read(at).r; n += w;
        }
    dst.write(float4(s / n), gid);
}

// a frame at time t (0 prev, 1 cur), one thread per chroma pixel and its 2x2 luma: prev read at p - t v, cur at
// p + (1 - t) v, prev counting 1 - t and cur t, so the nearer frame counts more. a side whose sample lies outside the
// picture gives way to the other. relook: the field is solved for t = 0.5, at t the vector here belongs to what sat
// at p + (0.5 - t) v then, so it is read again from there (once, the nearest cell). still: no vectors at all, a plain
// cross-fade by t (the time blend)
// fallback (kFallback): where the two warped samples still disagree over the 2x2 (by more than kApartLo of the luma
// range, fully at kApartHi) the vector is wrong or one side shows something else: it goes over to the time blend, a
// soft or doubled edge instead of a torn one. not at the picture's edge, where one side is outside by design
// doubt (genDoubt): each side counts as far as the field where its sample lands moves the same way as here, else
// something else is there (covering, uncovered) and the other side is taken; never less than a floor, so where both
// sides slip they still mix by how much. (softening both where neither counts was tried: it touched 0.1% of pixels for
// +0.01 db)
// sides (kSides): the pair's side map, read where this place sat at t = 0.5, pulls the weight toward the side it
// names; fixed for the pair, so the same place keeps its side over all the frames made from it
// near (kNear, with kFallback): the fallback takes the nearer real frame as it is instead of the time blend, the two
// meeting in a short cross-fade around t 0.5
struct MP { float sw, sh, sig, floor, t; int doubt, relook, still, fall; float lo, hi; int sides, near, crisp, detail, mean; };
// catmull-rom, 4x4 reads, edges held: the warped luma keeps its fine detail where bilinear would soften it
static float sharp(texture2d<float> t, float2 s) {
    float2 q = s - 0.5f, i = floor(q), f = q - i;
    float4 wx = float4(((-0.5f * f.x + 1.0f) * f.x - 0.5f) * f.x, (1.5f * f.x - 2.5f) * f.x * f.x + 1.0f,
                       ((-1.5f * f.x + 2.0f) * f.x + 0.5f) * f.x, (0.5f * f.x - 0.5f) * f.x * f.x);
    float4 wy = float4(((-0.5f * f.y + 1.0f) * f.y - 0.5f) * f.y, (1.5f * f.y - 2.5f) * f.y * f.y + 1.0f,
                       ((-1.5f * f.y + 2.0f) * f.y + 0.5f) * f.y, (0.5f * f.y - 0.5f) * f.y * f.y);
    int2 mx = int2(t.get_width() - 1, t.get_height() - 1), b = int2(i) - 1;
    float r = 0;
    for (int y = 0; y < 4; y++) {
        uint ry = uint(clamp(b.y + y, 0, mx.y));
        float4 row = float4(t.read(uint2(uint(clamp(b.x, 0, mx.x)), ry)).r, t.read(uint2(uint(clamp(b.x + 1, 0, mx.x)), ry)).r,
                            t.read(uint2(uint(clamp(b.x + 2, 0, mx.x)), ry)).r, t.read(uint2(uint(clamp(b.x + 3, 0, mx.x)), ry)).r);
        r += dot(row, wx) * wy[y];
    }
    return r;
}
static float inside(float2 s, float2 size) {
    float2 e = min(s, size - s);
    return saturate(min(e.x, e.y) + 1.0f);
}
kernel void mixer(texture2d<float, access::write> outY [[texture(0)]], texture2d<float, access::write> outC [[texture(1)]],
                  texture2d<float> prevY [[texture(2)]], texture2d<float> curY [[texture(3)]],
                  texture2d<float> prevC [[texture(4)]], texture2d<float> curC [[texture(5)]],
                  texture2d<float, access::read> vec [[texture(6)]], texture2d<float> side [[texture(7)]],
                  constant MP &p [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    int2 last = int2(vec.get_width(), vec.get_height()) - 1;
    float2 cq = float2(gid) + 0.5f, lq = cq * 2.0f, size = float2(p.sw, p.sh);
    float2 v = p.still ? float2(0) : vec.read(gid).xy;
    if (p.relook && !p.still) v = vec.read(uint2(clamp(int2(floor(cq + (0.5f - p.t) * 0.5f * v)), int2(0), last))).xy;
    float2 back = v * p.t, ahead = v * (1.0f - p.t); // to prev and to cur, luma pixels
    float2 backC = back * 0.5f, aheadC = ahead * 0.5f;
    float wPrev = (1.0f - p.t) * inside(lq - back, size), wCur = p.t * inside(lq + ahead, size);
    if (p.doubt && !p.still) {
        float2 slipPrev = vec.read(uint2(clamp(int2(floor(cq - backC)), int2(0), last))).xy - v;
        float2 slipCur = vec.read(uint2(clamp(int2(floor(cq + aheadC)), int2(0), last))).xy - v;
        wPrev *= max(exp(-dot(slipPrev, slipPrev) / (p.sig * p.sig)), p.floor);
        wCur *= max(exp(-dot(slipCur, slipCur) / (p.sig * p.sig)), p.floor);
    }
    float toCur = wPrev + wCur > 0.0f ? wCur / (wPrev + wCur) : p.t; // both outside: by time
    if (p.sides && !p.still) {
        float s = clamp(side.sample(tween, cq + (0.5f - p.t) * 0.5f * v).r, -1.0f, 1.0f) * inside(lq - back, size) * inside(lq + ahead, size);
        toCur = s > 0.0f ? mix(toCur, 0.0f, s) : mix(toCur, 1.0f, -s);
    }
    if (!p.fall || p.still) {
        for (int i = 0; i < 4; i++) {
            float2 s = lq + float2(float(i % 2) - 0.5f, float(i / 2) - 0.5f);
            outY.write(float4(saturate(mix(sharp(prevY, s - back), sharp(curY, s + ahead), toCur))), gid * 2 + uint2(i % 2, i / 2));
        }
        outC.write(float4(mix(prevC.sample(tween, cq - backC).rg, curC.sample(tween, cq + aheadC).rg, toCur), 0, 0), gid);
        return;
    }
    float a[4], b[4], apart = 0;
    for (int i = 0; i < 4; i++) {
        float2 s = lq + float2(float(i % 2) - 0.5f, float(i / 2) - 0.5f);
        a[i] = sharp(prevY, s - back); b[i] = sharp(curY, s + ahead);
        apart += fabs(a[i] - b[i]) * 0.25f;
    }
    // near t 0 or 1 the far side hardly counts and the near one is almost right: less of the blend there
    float w = smoothstep(p.lo, p.hi, apart) * inside(lq - back, size) * inside(lq + ahead, size) * 4.0f * p.t * (1.0f - p.t);
    float bt = p.near ? smoothstep(0.4f, 0.6f, p.t) : p.t;
    for (int i = 0; i < 4; i++) {
        uint2 at = gid * 2 + uint2(i % 2, i / 2);
        outY.write(float4(saturate(mix(mix(a[i], b[i], toCur), mix(prevY.read(at).r, curY.read(at).r, bt), w))), at);
    }
    float2 c = mix(prevC.sample(tween, cq - backC).rg, curC.sample(tween, cq + aheadC).rg, toCur);
    outC.write(float4(mix(c, mix(prevC.read(gid).rg, curC.read(gid).rg, bt), w), 0, 0), gid);
}
)M" R"M(
// the mixer with kCrisp, kDetail or kMean, a copy so that the plain one stays as it was to the byte:
// crisp (kCrisp): the cubic at a = -0.75 in place of catmull-rom's -0.5, less lost between pixels, a little more ring
// detail (kDetail): the luma goes to a scratch plane with what the kernel lost here (from each side's fraction and
// weight, none where the fallback blends), and the detail pass gives that much back, see there
// mean (kMean, with kFallback): apart is the 2x2's mean difference, not its mean |difference|: two warps of the same
// thing at different fractions differ in fine detail only, which cancels over the 2x2
static float k1(float x, float a) { return ((a + 2) * x - (a + 3)) * x * x + 1; }
static float k2(float x, float a) { return ((a * x - 5 * a) * x + 8 * a) * x - 4 * a; }
static float look(texture2d<float> t, float2 s, int crisp) {
    if (!crisp) return sharp(t, s);
    const float a = -0.75f;
    float2 q = s - 0.5f, i = floor(q), f = q - i;
    float4 wx = float4(k2(1 + f.x, a), k1(f.x, a), k1(1 - f.x, a), k2(2 - f.x, a));
    float4 wy = float4(k2(1 + f.y, a), k1(f.y, a), k1(1 - f.y, a), k2(2 - f.y, a));
    int2 mx = int2(t.get_width() - 1, t.get_height() - 1), b = int2(i) - 1;
    float r = 0;
    for (int y = 0; y < 4; y++) {
        uint ry = uint(clamp(b.y + y, 0, mx.y));
        float4 row = float4(t.read(uint2(uint(clamp(b.x, 0, mx.x)), ry)).r, t.read(uint2(uint(clamp(b.x + 1, 0, mx.x)), ry)).r,
                            t.read(uint2(uint(clamp(b.x + 2, 0, mx.x)), ry)).r, t.read(uint2(uint(clamp(b.x + 3, 0, mx.x)), ry)).r);
        r += dot(row, wx) * wy[y];
    }
    return r;
}
kernel void mixerX(texture2d<float, access::write> outY [[texture(0)]], texture2d<float, access::write> outC [[texture(1)]],
                   texture2d<float> prevY [[texture(2)]], texture2d<float> curY [[texture(3)]],
                   texture2d<float> prevC [[texture(4)]], texture2d<float> curC [[texture(5)]],
                   texture2d<float, access::read> vec [[texture(6)]], texture2d<float> side [[texture(7)]],
                   texture2d<float, access::write> made [[texture(8)]], texture2d<float, access::write> lost [[texture(9)]],
                   constant MP &p [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    int2 last = int2(vec.get_width(), vec.get_height()) - 1;
    float2 cq = float2(gid) + 0.5f, lq = cq * 2.0f, size = float2(p.sw, p.sh);
    float2 v = p.still ? float2(0) : vec.read(gid).xy;
    if (p.relook && !p.still) v = vec.read(uint2(clamp(int2(floor(cq + (0.5f - p.t) * 0.5f * v)), int2(0), last))).xy;
    float2 back = v * p.t, ahead = v * (1.0f - p.t); // to prev and to cur, luma pixels
    float2 backC = back * 0.5f, aheadC = ahead * 0.5f;
    float wPrev = (1.0f - p.t) * inside(lq - back, size), wCur = p.t * inside(lq + ahead, size);
    if (p.doubt && !p.still) {
        float2 slipPrev = vec.read(uint2(clamp(int2(floor(cq - backC)), int2(0), last))).xy - v;
        float2 slipCur = vec.read(uint2(clamp(int2(floor(cq + aheadC)), int2(0), last))).xy - v;
        wPrev *= max(exp(-dot(slipPrev, slipPrev) / (p.sig * p.sig)), p.floor);
        wCur *= max(exp(-dot(slipCur, slipCur) / (p.sig * p.sig)), p.floor);
    }
    float toCur = wPrev + wCur > 0.0f ? wCur / (wPrev + wCur) : p.t; // both outside: by time
    if (p.sides && !p.still) {
        float s = clamp(side.sample(tween, cq + (0.5f - p.t) * 0.5f * v).r, -1.0f, 1.0f) * inside(lq - back, size) * inside(lq + ahead, size);
        toCur = s > 0.0f ? mix(toCur, 0.0f, s) : mix(toCur, 1.0f, -s);
    }
    // kDetail: per axis, what the kernel lost here, (4 f (1 - f))^2 of each side's fraction by its weight (the 2x2
    // shares them; the square fits flatter over t than 4 f (1 - f) alone)
    float2 fb = fract(-back), fa = fract(ahead), lb = 4.0f * fb * (1.0f - fb), la = 4.0f * fa * (1.0f - fa);
    float2 loss = p.still ? float2(0) : mix(lb * lb, la * la, toCur);
    if (!p.fall || p.still) {
        for (int i = 0; i < 4; i++) {
            float2 s = lq + float2(float(i % 2) - 0.5f, float(i / 2) - 0.5f);
            float y = saturate(mix(look(prevY, s - back, p.crisp), look(curY, s + ahead, p.crisp), toCur));
            if (p.detail) made.write(float4(y), gid * 2 + uint2(i % 2, i / 2));
            else outY.write(float4(y), gid * 2 + uint2(i % 2, i / 2));
        }
        if (p.detail) lost.write(float4(loss, 0, 0), gid);
        outC.write(float4(mix(prevC.sample(tween, cq - backC).rg, curC.sample(tween, cq + aheadC).rg, toCur), 0, 0), gid);
        return;
    }
    float a[4], b[4], apart = 0;
    for (int i = 0; i < 4; i++) {
        float2 s = lq + float2(float(i % 2) - 0.5f, float(i / 2) - 0.5f);
        a[i] = look(prevY, s - back, p.crisp); b[i] = look(curY, s + ahead, p.crisp);
        apart += (p.mean ? a[i] - b[i] : fabs(a[i] - b[i])) * 0.25f;
    }
    apart = fabs(apart);
    // near t 0 or 1 the far side hardly counts and the near one is almost right: less of the blend there
    float w = smoothstep(p.lo, p.hi, apart) * inside(lq - back, size) * inside(lq + ahead, size) * 4.0f * p.t * (1.0f - p.t);
    float bt = p.near ? smoothstep(0.4f, 0.6f, p.t) : p.t;
    for (int i = 0; i < 4; i++) {
        uint2 at = gid * 2 + uint2(i % 2, i / 2);
        float y = saturate(mix(mix(a[i], b[i], toCur), mix(prevY.read(at).r, curY.read(at).r, bt), w));
        if (p.detail) made.write(float4(y), at);
        else outY.write(float4(y), at);
    }
    if (p.detail) lost.write(float4(loss * (1.0f - w), 0, 0), gid);
    float2 c = mix(prevC.sample(tween, cq - backC).rg, curC.sample(tween, cq + aheadC).rg, toCur);
    outC.write(float4(mix(c, mix(prevC.read(gid).rg, curC.read(gid).rg, bt), w), 0, 0), gid);
}
// kDetail: an unsharp step per axis, (2 y - left - right) / 4 times what the mixer says the kernel lost here times
// the gain, held inside the 3x3's own range so an edge gets no ring and flat noise nothing it did not have
kernel void detail(texture2d<float, access::write> outY [[texture(0)]], texture2d<float, access::read> made [[texture(1)]],
                   texture2d<float, access::read> lost [[texture(2)]], constant float &gain [[buffer(7)]],
                   uint2 gid [[thread_position_in_grid]]) {
    int2 mx = int2(made.get_width(), made.get_height()) - 1, c = int2(gid);
    float v[9], lo = 1, hi = 0;
    for (int k = 0; k < 9; k++) {
        v[k] = made.read(uint2(clamp(c + int2(k % 3 - 1, k / 3 - 1), int2(0), mx))).r;
        lo = min(lo, v[k]); hi = max(hi, v[k]);
    }
    float2 g = lost.read(gid / 2).rg * gain;
    float y = v[4] + g.x * (2 * v[4] - v[3] - v[5]) * 0.25f + g.y * (2 * v[4] - v[1] - v[7]) * 0.25f;
    outY.write(float4(clamp(y, lo, hi)), gid);
}
)M";

// measure (the frame log): appended to the above for a library of their own, compiled only when it is on, so the
// kernels above stay as they are. probe: per 8x8 cell of the final field its mean vector, mean pick cost and the
// share over `over`. fallCount: every 4th chroma pixel each way, the fallback's weight as mixer and mixerX work it out
// at p.t (the p.fall flag aside), counted where it is over a half
static NSString *const kMeasure = @R"M(
kernel void probe(device float4 *out [[buffer(0)]], texture2d<float, access::read> vec [[texture(0)]],
                  texture2d<float, access::read> cost [[texture(1)]], constant float &over [[buffer(7)]],
                  uint2 gid [[thread_position_in_grid]], uint2 n [[threads_per_grid]]) {
    uint2 lo = gid * 8, hi = min(lo + 8, uint2(vec.get_width(), vec.get_height()));
    float2 v = 0;
    float e = 0, bad = 0, k = 0;
    for (uint y = lo.y; y < hi.y; y++)
        for (uint x = lo.x; x < hi.x; x++) {
            float c = cost.read(uint2(x, y)).r;
            v += vec.read(uint2(x, y)).xy; e += c; bad += c > over ? 1.0f : 0.0f; k += 1;
        }
    out[gid.y * n.x + gid.x] = float4(v / k, e / k, bad / k);
}
kernel void fallCount(device atomic_uint *n [[buffer(0)]], texture2d<float> prevY [[texture(0)]], texture2d<float> curY [[texture(1)]],
                      texture2d<float, access::read> vec [[texture(2)]], constant MP &p [[buffer(7)]],
                      uint2 gid [[thread_position_in_grid]]) {
    int2 last = int2(vec.get_width(), vec.get_height()) - 1;
    uint2 at = uint2(min(int2(gid * 4 + 1), last));
    float2 cq = float2(at) + 0.5f, lq = cq * 2.0f, size = float2(p.sw, p.sh);
    float2 v = vec.read(at).xy;
    if (p.relook) v = vec.read(uint2(clamp(int2(floor(cq + (0.5f - p.t) * 0.5f * v)), int2(0), last))).xy;
    float2 back = v * p.t, ahead = v * (1.0f - p.t);
    float apart = 0;
    for (int i = 0; i < 4; i++) {
        float2 s = lq + float2(float(i % 2) - 0.5f, float(i / 2) - 0.5f);
        float a = look(prevY, s - back, p.crisp), b = look(curY, s + ahead, p.crisp);
        apart += (p.mean ? a - b : fabs(a - b)) * 0.25f;
    }
    apart = fabs(apart);
    float w = smoothstep(p.lo, p.hi, apart) * inside(lq - back, size) * inside(lq + ahead, size) * 4.0f * p.t * (1.0f - p.t);
    uint fell = simd_sum(w > 0.5f ? 1u : 0u);
    if (simd_is_first()) atomic_fetch_add_explicit(n, fell, memory_order_relaxed);
}
)M";

// the numbers were picked on 60 fps game footage, the middle of n and n+2 against the real n+1 (2026-11-25)
static const int kTopMax = 160;          // the top level is the first one at most this wide (1080p: 120, a pixel there is 16)
static const int kRangeTop = 10;         // top level: zero +-10 px there, so +-160 px a frame at 1080p without genShift
static const int kShiftRange = 32;       // genShift: the picture's shift +-32 px of the top level (+-512 at 1080p)
static const float kLam = 0.0015f;       // cost per level pixel off the expected vector (luma 0..1, mean per tap)
static const float kZeroSearch = 0.0015f; // search: zero's cost less this (a still picture stays still)
// pick: a cell vector takes over below kCellShare x the holder's cost, zero below kZeroShare x: zero needs a clear
// win, smooth blurred ground otherwise takes it in fast pans and shows holes. from a grid on the clips (luma psnr, 472
// pairs): cell share 0.7-1.0 with gaps 0-0.015 all 38.08-38.10; zero share 1.0 37.96, 0.9 38.00, 0.7 38.05, 0.6
// 38.08, 0.5 38.09, 0.4 38.10, 0.3 to 0.1 38.11, 0 (zero never) 38.05; gaps on zero 0-0.005 at most +0.02, so none.
// below 0.5 the hud over the airstrip pays (th60 hud mask: 0.6 54.95, 0.5 54.57, 0.4 54.07, 0.3 53.36), so 0.5
static const float kCellShare = 0.85f, kZeroShare = 0.5f;
// kStill: zero takes the place when its cost is under 0.02 and at most 0.002 over the holder's, and the 4x4 around has
// a mean deviation over 0.01 (texture). kBand: from a pick cost of 0.03, at most 2 px off where it lands, 3 passes.
// both from the made-up followed characters (blocktest -follow), see edges-report.md, round 2
static const float kStillTie = 0.02f, kStillGap = 0.002f, kStillTex = 0.01f;
static const float kBandOver = 0.03f, kBandTol = 2;
static const int kBandSteps = 4, kBandPasses = 3;
// kWhole: a place is unfit from a pick cost of kWholeOver; the whole picture gives up its vectors once more than
// kWholeIn of it is unfit and takes them back below kWholeOut (so it does not flip pair by pair). see round 2
static const float kWholeOver = 0.05f, kWholeIn = 0.3f, kWholeOut = 0.15f;
// kBorder: the outer 64 px (full size). corners on the clips 24.54 -> 25.28 db with kSmall, the outer band 27.49 -> 27.68
static const float kBorderPx = 64;
// genDoubt: how far (px) the field where a side's sample lands may move otherwise before that side stops counting,
// and the least it then counts. the floor: 1e-3 to 0.5 all 38.11 db on the clips; 0.05, so a slipping side counts
// 1/20 and two slipping sides still mix by how much
static const float kSideSig = 10, kSideFloor = 0.05f;
// kSmall: the start from the cell above before its medoid, +-1 step; the second look +-8 steps of 2 on level 2 (+-64
// px at 1080p) where the best cost is over 0.03. found on made-up characters over the clips (blocktest -sprite,
// -sweep, t 0.5): a character moving 30 px a pair over still ground, psnr within 6 px of its outline 21.7 -> 24.8 db,
// 46 px 19.9 -> 22.8, 60 px 19.4 -> 21.4, 90 px 18.9 -> 20.3. the clips: n,n+2 the same but u60 (camera whips, -0.2
// db), n,n+3 .. n,n+10 +0.01 to +0.2. solve paced 2.36 -> 2.65 ms (median, 2026-11-25). a ball (44 px) is still lost,
// and over +-160 px a pair everything is. the second look from 0.05 or 0.1: the sweep loses, the clips hardly gain
static const int kRawReach = 1, kWideReach = 8, kWideLevel = 1;
static const float kWideOver = 0.03f;
// kFallback: from 0.1 of the luma range apart over a 2x2 the time blend starts to take over, fully at 0.25, times
// 4 t (1 - t). without that last part it cost a followed character 1 db at t 0.1 and 0.9; with it the made-up
// characters gain a little at every t, the clips lose up to 0.1 db at t 1/4 .. 3/4 (0.1 at 0.5) and the worst torn
// blocks (a hud over a moving ground) get a few db back. 0.08 ms a frame paced. 0.05/0.15 cost 0.2-0.5 db, 0.15/0.35
// does almost nothing; a gate on the pick's cost fired on nothing useful; the nearer frame instead of the blend: worse
static const float kApartLo = 0.1f, kApartHi = 0.25f;
// kDetail: the unsharp step's gain where the kernel lost most (half a pixel), catmull-rom and with kCrisp. picked on
// pans of a real frame at sub-pixel speeds, where they bring hf (made over truth) from 0.92-0.97 to 0.97-1.02 over t;
// 1 and more went past the real frames (1.06+) and lost psnr. the clips: hf 0.87-0.91 -> 0.98-1.03, psnr -0.15 db
static const float kDetailGain = 0.75f, kDetailCrisp = 0.45f;
// kSides: a side gives way from 0.005 of match cost worse than what holds its spot, fully at 0.02; smoothed once over
// 5x5 points 2 chroma px apart, vectors within about 4 px counting. see edges-report.md, "sides"
static const float kOwnLo = 0.005f, kOwnHi = 0.02f, kOwnSig = 4;
static const int kOwnStep = 2;

struct Lv { int32_t rBlend, rNear, rZero; float step, toFull, lam, zeroBonus; int32_t rRaw, rWide; float wideOver, edge; };
struct GP { int32_t range; float scale; };
struct PK { float cellShare, zeroShare, zTie, zGap, zTex; };
struct MP { float size[2], sig, floor, t; int32_t doubt, relook, still, fall; float lo, hi; int32_t sides, near, crisp, detail, mean; };
struct SD { float lo, hi, sig; int32_t step; };
struct BF { float lo, tol; int32_t steps; };

static struct {
    id<MTLDevice> dev; // these once, kept over stop()
    id<MTLCommandQueue> queue;
    id<MTLLibrary> lib;
    id<MTLComputePipelineState> halve, search, medoid, fill, shiftCost, shiftBest, pick, mixer;
    // the newer switches' kernels, set up on first use (ready()): with them all off, the cost is 0.5.0's
    id<MTLComputePipelineState> ownClear, ownHit, sideOwn, sideSmooth, band, unfit, mixerX, detail;
    CVMetalTextureCacheRef cache = NULL;
    std::vector<id<MTLTexture>> pa, pb, raw, field; // per level, [0] is level 1
    id<MTLTexture> vec, none, pan;                  // none, pan: the 1x1 fields the top starts from
    id<MTLTexture> pickCost, side, side2;           // the pick's cost (always written); kSides: the side map and its spare
    id<MTLTexture> vecB;                            // kBand: gS.vec's spare
    id<MTLBuffer> unfitN;                           // kWhole: the count, shared
    id<MTLTexture> made, lost;                      // kDetail: the mixer's luma and what its kernel lost, per axis
    // side, side2, vecB, made, lost and owner are made on first use (ready()), unfitN and pickCost with the rest
    float unfitShare = 0;                           // kWhole: of the last solve
    bool whole = false;                             // kWhole: the picture gave up its vectors (kept over pairs)
    id<MTLBuffer> cost, owner;                      // owner: kSides' z-buffers, prev's then cur's
    int w = 0, h = 0;
    double gpuMs = 0;
    bool up = false;
    // what solve() keeps for frame(): the pair's planes, until the next solve() or stop()
    CVPixelBufferRef held[2] = {NULL, NULL};
    std::vector<CVMetalTextureRef> heldKeep;
    id<MTLTexture> heldY[2], heldC[2];
    bool solved = false;
    bool vecOwn = false;                   // gS.vec is the held pair's (solve with motion), not another's
    bool sides = false;                    // gS.side is this pair's (solved with kSides)
    // measure: its two kernels (kept over stop(), as the others), the buffers read back, what was read
    id<MTLComputePipelineState> probe, fallCount;
    id<MTLBuffer> probeOut, fallN;         // a float4 per cell; a count per frame
    Figures fig = {};
    bool figOk = false;
    float fall[16];                        // per frame of the last frames()
    int fallFrames = 0;                    // how many of those were measured
} gS;
static const int kFallMax = 16;
static std::atomic<bool> gMeasure{false};

static std::atomic<bool> gRefused{false};
static os_unfair_lock gWhyLock = OS_UNFAIR_LOCK_INIT;
static std::string gWhy;

double lastGpuMs() { return gS.gpuMs; }
float lastUnfit() { return gS.whole ? -gS.unfitShare : gS.unfitShare; }
void measure(bool on) { gMeasure = on; }
bool measuring() { return gMeasure; }
bool lastFigures(Figures &f) { bool ok = gMeasure && gS.figOk; if (ok) f = gS.fig; return ok; }
float lastFall(int i) { return gMeasure && i >= 0 && i < gS.fallFrames ? gS.fall[i] : -1; }
bool refused() { return gRefused; }
void retry() { gRefused = false; }
const char *note() {
    static thread_local char text[200];
    if (!gRefused) return "";
    os_unfair_lock_lock(&gWhyLock);
    snprintf(text, sizeof text, "block generator not usable: %s", gWhy.c_str());
    os_unfair_lock_unlock(&gWhyLock);
    return text;
}

static void letGo() {
    for (CVMetalTextureRef t : gS.heldKeep) CFRelease(t);
    gS.heldKeep.clear();
    for (CVPixelBufferRef &pb : gS.held) { if (pb) CFRelease(pb); pb = NULL; }
    gS.heldY[0] = gS.heldY[1] = gS.heldC[0] = gS.heldC[1] = nil;
    gS.solved = gS.vecOwn = gS.sides = false;
}

void release() { letGo(); gS.whole = false; }

void stop() {
    letGo();
    gS.pa.clear(); gS.pb.clear(); gS.raw.clear(); gS.field.clear();
    gS.vec = gS.none = gS.pan = gS.pickCost = gS.side = gS.side2 = gS.vecB = gS.made = gS.lost = nil;
    gS.cost = gS.owner = gS.unfitN = nil;
    gS.probeOut = gS.fallN = nil; gS.figOk = false; gS.fallFrames = 0;
    gS.whole = false;
    if (gS.cache) CVMetalTextureCacheFlush(gS.cache, 0);
    gS.up = false;
}

bool refuse(const char *why) {
    os_unfair_lock_lock(&gWhyLock);
    gWhy = why;
    os_unfair_lock_unlock(&gWhyLock);
    gRefused = true;
    logLine("block generator refused: %s", why);
    stop();
    return false;
}

static id<MTLTexture> plane(CVPixelBufferRef pb, int i, bool write, std::vector<CVMetalTextureRef> &keep) {
    NSDictionary *a = write ? @{(id)kCVMetalTextureUsage: @(MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead)} : nil;
    CVMetalTextureRef t = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, gS.cache, pb, (__bridge CFDictionaryRef)a, i ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
                                              CVPixelBufferGetWidthOfPlane(pb, i), CVPixelBufferGetHeightOfPlane(pb, i), i, &t);
    if (!t) return nil;
    keep.push_back(t);
    return CVMetalTextureGetTexture(t);
}

static void run(id<MTLComputeCommandEncoder> e, id<MTLComputePipelineState> ps, NSUInteger w, NSUInteger h) {
    [e setComputePipelineState:ps];
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 8, 1)]; // exact grid: no thread past the edge
}

static bool fits(CVPixelBufferRef pb) {
    return pb && (int)CVPixelBufferGetWidth(pb) == gS.w && (int)CVPixelBufferGetHeight(pb) == gS.h && CVPixelBufferGetPlaneCount(pb) == 2;
}

// the motion for a pair: pyramids, the picture's shift, the search level by level, the fill, the pick into gS.vec
static void encodeSolve(id<MTLComputeCommandEncoder> e, id<MTLTexture> prevY, id<MTLTexture> curY, bool shift, int how) {
    bool small = how & kSmall, sides = how & kSides;
    int levels = (int)gS.pa.size(), top = levels - 1;
    for (int i = 0; i < levels; i++)
        for (auto [to, from] : {std::pair{gS.pa[i], i ? gS.pa[i - 1] : prevY}, std::pair{gS.pb[i], i ? gS.pb[i - 1] : curY}}) {
            [e setTexture:to atIndex:0]; [e setTexture:from atIndex:1];
            run(e, gS.halve, to.width, to.height);
        }
    if (shift) {
        GP gp = {kShiftRange, (float)(2 << top)};
        [e setComputePipelineState:gS.shiftCost];
        [e setTexture:gS.pa[top] atIndex:0]; [e setTexture:gS.pb[top] atIndex:1];
        [e setBuffer:gS.cost offset:0 atIndex:0];
        [e setBytes:&gp length:sizeof gp atIndex:7];
        [e dispatchThreadgroups:MTLSizeMake(2 * kShiftRange + 1, 2 * kShiftRange + 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:gS.shiftBest];
        [e setTexture:gS.pan atIndex:0];
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    }
    for (int i = top; i >= 0; i--) { // from the top level down
        Lv lv = {i == top ? 3 : 2, 1, i == top ? kRangeTop : i ? 1 : 0, i ? 1.0f : 0.5f, (float)(2 << i), kLam, kZeroSearch,
                 small && i < top ? kRawReach : -1, small && i == kWideLevel && i < top ? kWideReach : 0, kWideOver,
                 how & kBorder ? kBorderPx / (float)(2 << i) : 0};
        [e setComputePipelineState:gS.search];
        [e setTexture:gS.raw[i] atIndex:0];
        [e setTexture:gS.pa[i] atIndex:1]; [e setTexture:gS.pb[i] atIndex:2];
        [e setTexture:i < top ? gS.field[i + 1] : shift ? gS.pan : gS.none atIndex:3];
        [e setTexture:i < top ? gS.raw[i + 1] : gS.none atIndex:4]; // raw above: what it searched, before its medoid
        [e setBytes:&lv length:sizeof lv atIndex:7];
        [e dispatchThreadgroups:MTLSizeMake(gS.raw[i].width, gS.raw[i].height, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        [e setTexture:gS.field[i] atIndex:0]; [e setTexture:gS.raw[i] atIndex:1];
        run(e, gS.medoid, gS.raw[i].width, gS.raw[i].height);
    }
    float lsize[2] = {(float)gS.pa[0].width, (float)gS.pa[0].height};
    [e setTexture:gS.raw[0] atIndex:0]; [e setTexture:gS.field[0] atIndex:1]; // raw is free again by now
    [e setBytes:lsize length:sizeof lsize atIndex:7];
    run(e, gS.fill, gS.raw[0].width, gS.raw[0].height);
    PK pk = {kCellShare, kZeroShare, how & kStill ? kStillTie : 0, kStillGap, kStillTex};
    [e setTexture:gS.vec atIndex:0]; [e setTexture:gS.pickCost atIndex:1];
    [e setTexture:gS.pa[0] atIndex:2]; [e setTexture:gS.pb[0] atIndex:3]; [e setTexture:gS.raw[0] atIndex:4];
    [e setBytes:&pk length:sizeof pk atIndex:7];
    run(e, gS.pick, gS.vec.width, gS.vec.height);
    if (how & kBand) {
        BF bf = {kBandOver, kBandTol, kBandSteps};
        [e setBytes:&bf length:sizeof bf atIndex:7];
        for (int k = 0; k < kBandPasses; k++) {
            [e setTexture:gS.vecB atIndex:0]; [e setTexture:gS.vec atIndex:1]; [e setTexture:gS.pickCost atIndex:2];
            run(e, gS.band, gS.vec.width, gS.vec.height);
            std::swap(gS.vec, gS.vecB);
        }
    }
    if (how & kWhole) {
        float over = kWholeOver;
        [e setBuffer:gS.unfitN offset:0 atIndex:0]; [e setTexture:gS.pickCost atIndex:0];
        [e setBytes:&over length:sizeof over atIndex:7];
        run(e, gS.unfit, gS.vec.width, gS.vec.height);
    }
    if (!sides) return;
    SD sd = {kOwnLo, kOwnHi, kOwnSig, kOwnStep};
    [e setBuffer:gS.owner offset:0 atIndex:0];
    run(e, gS.ownClear, gS.vec.width, gS.vec.height * 2);
    [e memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [e setTexture:gS.vec atIndex:0]; [e setTexture:gS.pickCost atIndex:1];
    run(e, gS.ownHit, gS.vec.width, gS.vec.height);
    [e memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [e setTexture:gS.side2 atIndex:0]; [e setTexture:gS.vec atIndex:1]; [e setTexture:gS.pickCost atIndex:2];
    [e setBytes:&sd length:sizeof sd atIndex:7];
    run(e, gS.sideOwn, gS.vec.width, gS.vec.height);
    [e setTexture:gS.side atIndex:0]; [e setTexture:gS.side2 atIndex:1]; [e setTexture:gS.vec atIndex:2];
    run(e, gS.sideSmooth, gS.vec.width, gS.vec.height);
}

// one frame at t from gS.vec and the pair's planes
static void encodeFrame(id<MTLComputeCommandEncoder> e, id<MTLTexture> const pair[4], id<MTLTexture> outY, id<MTLTexture> outC,
                        float t, int how, bool doubt) {
    MP mp = {{(float)gS.w, (float)gS.h}, kSideSig, kSideFloor, t, doubt, (how & kRelook) != 0, (how & kTimeBlend) != 0,
             (how & kFallback) != 0, kApartLo, kApartHi, (how & kSides) != 0 && gS.sides, (how & kNear) != 0, (how & kCrisp) != 0,
             (how & kDetail) != 0, (how & kMean) != 0};
    [e setTexture:outY atIndex:0]; [e setTexture:outC atIndex:1];
    [e setTexture:pair[0] atIndex:2]; [e setTexture:pair[2] atIndex:3]; [e setTexture:pair[1] atIndex:4]; [e setTexture:pair[3] atIndex:5];
    [e setTexture:gS.vec atIndex:6]; [e setTexture:gS.side ?: gS.none atIndex:7]; // side: read only with kSides
    [e setBytes:&mp length:sizeof mp atIndex:7];
    if (!(how & (kCrisp | kDetail | kMean))) { run(e, gS.mixer, outC.width, outC.height); return; }
    [e setTexture:gS.made atIndex:8]; [e setTexture:gS.lost atIndex:9];
    run(e, gS.mixerX, outC.width, outC.height);
    if (!(how & kDetail)) return;
    float gain = how & kCrisp ? kDetailCrisp : kDetailGain;
    [e setTexture:outY atIndex:0]; [e setTexture:gS.made atIndex:1]; [e setTexture:gS.lost atIndex:2];
    [e setBytes:&gain length:sizeof gain atIndex:7];
    run(e, gS.detail, outY.width, outY.height);
}

// measure: the cells of gS.vec, and its probe pass after the solve
static MTLSize probeCells() { return MTLSizeMake((gS.vec.width + 7) / 8, (gS.vec.height + 7) / 8, 1); }
static void encodeProbe(id<MTLComputeCommandEncoder> e) {
    float over = kWholeOver;
    [e setBuffer:gS.probeOut offset:0 atIndex:0];
    [e setTexture:gS.vec atIndex:0]; [e setTexture:gS.pickCost atIndex:1];
    [e setBytes:&over length:sizeof over atIndex:7];
    MTLSize c = probeCells();
    run(e, gS.probe, c.width, c.height);
}
// medians, means and the unfit share from what probe wrote. on the generator thread, about 8000 cells at 1080p
static void readProbe() {
    MTLSize c = probeCells();
    int n = (int)(c.width * c.height);
    const float (*p)[4] = (const float (*)[4])gS.probeOut.contents;
    std::vector<float> x(n), y(n);
    double len = 0, err = 0, bad = 0;
    for (int i = 0; i < n; i++) {
        x[i] = p[i][0]; y[i] = p[i][1];
        len += sqrt((double)p[i][0] * p[i][0] + (double)p[i][1] * p[i][1]); err += p[i][2]; bad += p[i][3];
    }
    std::nth_element(x.begin(), x.begin() + n / 2, x.end());
    std::nth_element(y.begin(), y.begin() + n / 2, y.end());
    gS.fig = {x[n / 2], y[n / 2], (float)(len / n), (float)(err / n), (float)(bad / n)};
    gS.figOk = true;
}
// the fallback's weight at t for frame i of a frames() round, counted into gS.fallN[i]. the mixer's own numbers
static MTLSize fallGrid() { return MTLSizeMake((gS.vec.width + 3) / 4, (gS.vec.height + 3) / 4, 1); }
static void encodeFall(id<MTLComputeCommandEncoder> e, id<MTLTexture> const pair[4], float t, int how, int i) {
    MP mp = {{(float)gS.w, (float)gS.h}, kSideSig, kSideFloor, t, 0, (how & kRelook) != 0, 0, 1, kApartLo, kApartHi, 0, 0,
             (how & kCrisp) != 0, 0, (how & kMean) != 0};
    [e setBuffer:gS.fallN offset:i * sizeof(uint32_t) atIndex:0];
    [e setTexture:pair[0] atIndex:0]; [e setTexture:pair[2] atIndex:1]; [e setTexture:gS.vec atIndex:2];
    [e setBytes:&mp length:sizeof mp atIndex:7];
    MTLSize g = fallGrid();
    run(e, gS.fallCount, g.width, g.height);
}
static bool measureUp();
static int ready(int how);

static bool finish(id<MTLCommandBuffer> cb) {
    [cb commit];
    [cb waitUntilCompleted];
    bool ok = cb.status == MTLCommandBufferStatusCompleted;
    if (ok) gS.gpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
    return ok;
}

bool generate(CVPixelBufferRef prev, CVPixelBufferRef cur, CVPixelBufferRef dst, bool, bool, int how) {
    if (!gS.up || !fits(prev) || !fits(cur) || !fits(dst)) return false;
    how = ready(how);
    bool shift = gSet.genShift, doubt = gSet.genDoubt;
    std::vector<CVMetalTextureRef> keep;
    id<MTLTexture> pair[4] = {plane(prev, 0, false, keep), plane(prev, 1, false, keep), plane(cur, 0, false, keep), plane(cur, 1, false, keep)};
    id<MTLTexture> outY = plane(dst, 0, true, keep), outC = plane(dst, 1, true, keep);
    bool ok = pair[0] && pair[1] && pair[2] && pair[3] && outY && outC;
    if (ok) {
        id<MTLCommandBuffer> cb = [gS.queue commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        encodeSolve(e, pair[0], pair[2], shift, how);
        gS.sides = how & kSides; // until letGo() below
        encodeFrame(e, pair, outY, outC, 0.5f, how & (kFallback | kSides | kNear | kCrisp | kDetail | kMean), doubt);
        [e endEncoding];
        ok = finish(cb);
    }
    for (CVMetalTextureRef t : keep) CFRelease(t);
    CVMetalTextureCacheFlush(gS.cache, 0); // the cache would otherwise hold on to every frame's planes
    letGo(); // gS.vec is this pair's now, not the held one's: and the held pair is not wanted after the any-rate path
    return ok;
}

bool solve(CVPixelBufferRef prev, CVPixelBufferRef cur, bool, bool, bool motion, int how) {
    letGo();
    if (!motion || !(how & kWhole)) gS.whole = false; // a cut guard switched on again starts from a picture that fits
    if (gMeasure) gS.figOk = false;
    if (!gS.up || !fits(prev) || !fits(cur)) return false;
    gS.held[0] = (CVPixelBufferRef)CFRetain(prev);
    gS.held[1] = (CVPixelBufferRef)CFRetain(cur);
    for (int k = 0; k < 2; k++) {
        gS.heldY[k] = plane(gS.held[k], 0, false, gS.heldKeep);
        gS.heldC[k] = plane(gS.held[k], 1, false, gS.heldKeep);
    }
    if (!gS.heldY[0] || !gS.heldC[0] || !gS.heldY[1] || !gS.heldC[1]) { letGo(); return false; }
    if (!motion) return gS.solved = true; // a time blend reads no vectors: holding the pair is all it needs (vecOwn stays false)
    how = ready(how);
    id<MTLCommandBuffer> cb = [gS.queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    *(uint32_t *)gS.unfitN.contents = 0;
    encodeSolve(e, gS.heldY[0], gS.heldY[1], gSet.genShift, how);
    bool probe = gMeasure && measureUp(); // the frame log only
    if (probe) encodeProbe(e);
    [e endEncoding];
    gS.solved = gS.vecOwn = finish(cb);
    if (probe && gS.solved) readProbe();
    if (gS.solved && (how & kWhole)) {
        gS.unfitShare = *(uint32_t *)gS.unfitN.contents / float(gS.vec.width * gS.vec.height);
        gS.whole = gS.whole ? gS.unfitShare >= kWholeOut : gS.unfitShare > kWholeIn;
    }
    gS.sides = gS.solved && (how & kSides);
    if (!gS.solved) letGo();
    return gS.solved;
}

bool frames(const float *t, CVPixelBufferRef const *dst, int n, int how) {
    if (!gS.up || !gS.solved || n < 1) return false;
    if (!(how & kTimeBlend) && !gS.vecOwn) return false; // a pair held without its vectors: another pair's would warp it
    for (int i = 0; i < n; i++) if (!fits(dst[i]) || !(t[i] >= 0 && t[i] <= 1)) return false;
    how = ready(how);
    bool doubt = gSet.genDoubt;
    id<MTLTexture> pair[4] = {gS.heldY[0], gS.heldC[0], gS.heldY[1], gS.heldC[1]};
    std::vector<CVMetalTextureRef> keep;
    id<MTLCommandBuffer> cb = [gS.queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    bool ok = true;
    bool fall = gMeasure && measureUp(); // the frame log only
    if (fall) { gS.fallFrames = 0; memset(gS.fallN.contents, 0, kFallMax * sizeof(uint32_t)); }
    for (int i = 0; i < n && ok; i++) {
        id<MTLTexture> outY = plane(dst[i], 0, true, keep), outC = plane(dst[i], 1, true, keep);
        ok = outY && outC;
        // kWhole while the picture gave up its vectors: the time blend, or with kNear the nearer real frame
        bool give = (how & kWhole) && gS.whole;
        float at = give && (how & kNear) ? (t[i] < 0.5f ? 0.0f : 1.0f) : t[i];
        if (ok) encodeFrame(e, pair, outY, outC, at, give ? how | kTimeBlend : how, doubt);
        if (ok && fall && i < kFallMax && !give && !(how & kTimeBlend)) encodeFall(e, pair, at, how, i);
    }
    [e endEncoding];
    ok = ok && finish(cb); // a command buffer that was not committed is simply dropped
    if (fall && ok) {
        MTLSize g = fallGrid();
        bool blend = (how & kTimeBlend) || ((how & kWhole) && gS.whole);
        for (int i = 0; i < n && i < kFallMax; i++) gS.fall[i] = blend ? 1 : ((const uint32_t *)gS.fallN.contents)[i] / float(g.width * g.height);
        gS.fallFrames = std::min(n, kFallMax);
    }
    for (CVMetalTextureRef k : keep) CFRelease(k);
    CVMetalTextureCacheFlush(gS.cache, 0);
    return ok;
}

bool frame(float t, CVPixelBufferRef dst, int how) { return frames(&t, &dst, 1, how); }

// the device, its kernels and the texture cache, once. nothing is kept unless all of it is there
static const char *setup() {
    if (gS.cache) return nullptr;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return "no metal device";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kKernels options:nil error:&err];
    if (!lib) {
        logLine("block generator: %s", err.localizedDescription.UTF8String ?: "?");
        return "its shaders did not compile";
    }
    auto ps = [&](NSString *n) -> id<MTLComputePipelineState> {
        id<MTLFunction> f = [lib newFunctionWithName:n];
        return f ? [dev newComputePipelineStateWithFunction:f error:nil] : nil;
    };
    id<MTLComputePipelineState> all[8] = {ps(@"halve"), ps(@"search"), ps(@"medoid"), ps(@"fill"), ps(@"shiftCost"), ps(@"shiftBest"), ps(@"pick"), ps(@"mixer")};
    for (auto p : all) if (!p) return "a kernel could not be set up";
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    CVMetalTextureCacheRef cache = NULL;
    if (!queue || CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &cache) != kCVReturnSuccess || !cache) return "no texture cache";
    gS.dev = dev; gS.queue = queue; gS.lib = lib;
    gS.halve = all[0]; gS.search = all[1]; gS.medoid = all[2]; gS.fill = all[3];
    gS.shiftCost = all[4]; gS.shiftBest = all[5]; gS.pick = all[6]; gS.mixer = all[7];
    gS.cache = cache;
    return nullptr;
}

// measure: its kernels once (the block generator's source with its own after it), its buffers per picture size. a
// failure only costs the figures: logged once, the generator runs on
static bool measureUp() {
    if (gS.probeOut && gS.fallN) return true;
    static bool failed = false;
    if (failed || !gS.vec) return false;
    if (!gS.probe) {
        NSError *err = nil;
        id<MTLLibrary> lib = [gS.dev newLibraryWithSource:[kKernels stringByAppendingString:kMeasure] options:nil error:&err];
        id<MTLFunction> p = [lib newFunctionWithName:@"probe"], f = [lib newFunctionWithName:@"fallCount"];
        id<MTLComputePipelineState> pp = p ? [gS.dev newComputePipelineStateWithFunction:p error:nil] : nil;
        id<MTLComputePipelineState> fp = f ? [gS.dev newComputePipelineStateWithFunction:f error:nil] : nil;
        if (!pp || !fp) {
            failed = true;
            logLine("block generator: no figures for the frame log: %s", err ? err.localizedDescription.UTF8String : "a kernel could not be set up");
            return false;
        }
        gS.probe = pp; gS.fallCount = fp;
    }
    MTLSize c = probeCells();
    gS.probeOut = [gS.dev newBufferWithLength:sizeof(float) * 4 * c.width * c.height options:MTLResourceStorageModeShared];
    gS.fallN = [gS.dev newBufferWithLength:sizeof(uint32_t) * kFallMax options:MTLResourceStorageModeShared];
    return gS.probeOut && gS.fallN;
}

static id<MTLTexture> image(int w, int h, MTLPixelFormat f, MTLStorageMode m = MTLStorageModePrivate) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.width = w; d.height = h; d.pixelFormat = f;
    d.storageMode = m;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [gS.dev newTextureWithDescriptor:d];
}

// the parts of the newer switches in how, made the first time they are asked for at this size. how comes back
// without the bits whose part could not be made (logged once): those frames are made as if the switch were off
static int ready(int how) {
    auto ps = [](__strong id<MTLComputePipelineState> &p, NSString *n) {
        if (p) return true;
        id<MTLFunction> f = [gS.lib newFunctionWithName:n];
        p = f ? [gS.dev newComputePipelineStateWithFunction:f error:nil] : nil;
        return p != nil;
    };
    auto tex = [](__strong id<MTLTexture> &t, int w, int h, MTLPixelFormat f) { if (!t) t = image(w, h, f); return t != nil; };
    int w = gS.w / 2, h = gS.h / 2, lost = 0;
    if ((how & kBand) && !(ps(gS.band, @"band") && tex(gS.vecB, w, h, MTLPixelFormatRG32Float))) lost |= kBand;
    if ((how & kWhole) && !ps(gS.unfit, @"unfit")) lost |= kWhole;
    if ((how & kSides) && !(ps(gS.ownClear, @"ownClear") && ps(gS.ownHit, @"ownHit") && ps(gS.sideOwn, @"sideOwn") && ps(gS.sideSmooth, @"sideSmooth")
                            && tex(gS.side, w, h, MTLPixelFormatR16Float) && tex(gS.side2, w, h, MTLPixelFormatR16Float)
                            && (gS.owner ?: (gS.owner = [gS.dev newBufferWithLength:sizeof(uint32_t) * w * h * 2 options:MTLResourceStorageModePrivate]))))
        lost |= kSides;
    if ((how & (kCrisp | kDetail | kMean)) && !(ps(gS.mixerX, @"mixerX") && tex(gS.made, gS.w, gS.h, MTLPixelFormatR16Float) && tex(gS.lost, w, h, MTLPixelFormatRG16Float)))
        lost |= kCrisp | kDetail | kMean;
    if ((how & kDetail) && !ps(gS.detail, @"detail")) lost |= kDetail;
    static bool told = false;
    if (lost && !told) { told = true; logLine("block generator: a newer switch's kernel or memory could not be set up (how %d), made without it", lost); }
    return how & ~lost;
}

static CVPixelBufferRef blank(int w, int h) {
    NSDictionary *a = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pb);
    return pb;
}

bool start(int w, int h) {
    stop();
    @autoreleasepool {
        if (w < 64 || h < 64 || w % 2 || h % 2 || w > 8192 || h > 8192) {
            char why[64];
            snprintf(why, sizeof why, "picture size %dx%d", w, h);
            return refuse(why);
        }
        if (const char *why = setup()) return refuse(why);
        gS.w = w; gS.h = h;
        for (int lw = (w + 1) / 2, lh = (h + 1) / 2;; lw = (lw + 1) / 2, lh = (lh + 1) / 2) {
            gS.pa.push_back(image(lw, lh, MTLPixelFormatR16Float));
            gS.pb.push_back(image(lw, lh, MTLPixelFormatR16Float));
            gS.raw.push_back(image((lw + 7) / 8, (lh + 7) / 8, MTLPixelFormatRG32Float));
            gS.field.push_back(image((lw + 7) / 8, (lh + 7) / 8, MTLPixelFormatRG32Float));
            if (lw <= kTopMax) break; // 8192 wide: 6 levels
        }
        gS.vec = image(w / 2, h / 2, MTLPixelFormatRG32Float);
        gS.pickCost = image(w / 2, h / 2, MTLPixelFormatR16Float);
        gS.unfitN = [gS.dev newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
        gS.none = image(1, 1, MTLPixelFormatRG32Float, MTLStorageModeShared);
        gS.pan = image(1, 1, MTLPixelFormatRG32Float, MTLStorageModePrivate);
        gS.cost = [gS.dev newBufferWithLength:sizeof(float) * (2 * kShiftRange + 1) * (2 * kShiftRange + 1) options:MTLResourceStorageModePrivate];
        bool have = gS.vec && gS.unfitN && gS.pickCost && gS.none && gS.pan && gS.cost;
        for (size_t i = 0; i < gS.pa.size(); i++) have = have && gS.pa[i] && gS.pb[i] && gS.raw[i] && gS.field[i];
        if (!have) return refuse("out of gpu memory");
        float zero[2] = {0, 0};
        [gS.none replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:sizeof zero];
        gS.up = true;
        if (gMeasure) measureUp(); // its compile here, not on the first pair
        // a throwaway frame now: metal compiles and allocates on first use, better here than on the first real pair
        CVPixelBufferRef a = blank(w, h), b = blank(w, h), d = blank(w, h);
        bool ran = a && b && d && generate(a, b, d, false, false);
        if (a) CFRelease(a);
        if (b) CFRelease(b);
        if (d) CFRelease(d);
        if (!ran) return refuse("the first frame did not come out");
        // switches already on: their kernels and memory now too, not on the first real pair
        ready((gSet.genSides ? kSides : 0) | (gSet.genOutline ? kBand : 0) | (gSet.genCutGuard ? kWhole : 0) | (gSet.genFallback ? kMean : 0) | (gSet.genSharp ? kCrisp | kDetail : 0));
    }
    return true;
}

}
