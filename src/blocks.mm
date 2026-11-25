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
#include <atomic>
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
struct Lv { int rBlend, rNear, rZero; float step, toFull, lam, zeroBonus; };
kernel void search(texture2d<float, access::write> out [[texture(0)]], texture2d<float> prev [[texture(1)]],
                   texture2d<float> cur [[texture(2)]], texture2d<float, access::read> above [[texture(3)]],
                   constant Lv &p [[buffer(7)]], uint2 cell [[threadgroup_position_in_grid]],
                   uint lane [[thread_index_in_simdgroup]]) {
    Near n = nearby(above, (float2(cell) + 0.5f) * 0.5f);
    float2 st[5] = {n.blend, n.own, n.side, n.updown, 0};
    int r[5] = {p.rBlend, p.rNear, p.rNear, p.rNear, p.rZero}, end[5], total = 0;
    for (int i = 0; i < 5; i++) st[i] = round(st[i] / (p.toFull * p.step)) * p.step; // in this level's pixels, on the grid
    float2 want = st[0];
    for (int i = 0; i < 5; i++) {
        bool inside = false;
        for (int j = 0; j < 5; j++)
            if (j != i && (r[j] > r[i] || (r[j] == r[i] && j < i)) && all(fabs(st[j] - st[i]) <= float(r[j] - r[i]) * p.step)) inside = true;
        total += inside ? 0 : (2 * r[i] + 1) * (2 * r[i] + 1);
        end[i] = total;
    }
    float2 o = float2(cell) * float(kCell) - float(kWin - kCell) * 0.5f;
    float best = INFINITY;
    float2 got = 0;
    for (int t = int(lane); t < total; t += 32) {
        int i = 0;
        while (t >= end[i]) i++;
        int j = t - (i ? end[i - 1] : 0), w = 2 * r[i] + 1;
        float2 v = st[i] + float2(j % w - r[i], j / w - r[i]) * p.step;
        float2 d = drift(prev, cur, o, kWin, v * 0.5f); // its mean out: a fade or a flash changes brightness, not where things are
        float2 m = mismatch(prev, cur, o, kWin, v * 0.5f, d.x / max(d.y, 1.0f)), off = fabs(v - want);
        float c = (m.x + kOut * (float(kWin * kWin) - m.y)) / float(kWin * kWin) + p.lam * (off.x + off.y);
        if (all(v == 0.0f)) c -= p.zeroBonus;
        if (c < best) { best = c; got = v; }
    }
    float low = simd_min(best);
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
struct PK { float cellShare, zeroShare; };
static float patchCost(texture2d<float> prev, texture2d<float> cur, float2 q, float2 v) {
    float2 m = mismatch(prev, cur, q - 1.5f, 3, v * 0.25f, 0); // level 1: half of v is v / 4 of its pixels
    return m.y >= 5 ? m.x / m.y : INFINITY;
}
kernel void pick(texture2d<float, access::write> vec [[texture(0)]], texture2d<float> prev [[texture(1)]],
                 texture2d<float> cur [[texture(2)]], texture2d<float, access::read> field [[texture(3)]],
                 constant PK &p [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    float2 q = float2(gid) + 0.5f;
    Near n = nearby(field, q / float(kCell));
    float2 holder = n.blend;
    float held = patchCost(prev, cur, q, holder);
    if (isfinite(held)) {
        float2 challenger[4] = {n.own, n.side, n.updown, 0};
        for (int i = 0; i < 4; i++) {
            float c = patchCost(prev, cur, q, challenger[i]);
            if (c < held * (i < 3 ? p.cellShare : p.zeroShare)) { holder = challenger[i]; held = c; }
        }
    }
    vec.write(float4(holder, 0, 0), gid);
}

// the frame in between, one thread per chroma pixel and its 2x2 luma. a side whose sample lies outside the picture
// gives way to the other, otherwise half each.
// doubt (genDoubt): each side counts as far as the field where its sample lands moves the same way as here, else
// something else is there (covering, uncovered) and the other side is taken; never less than a floor, so where both
// sides slip they still mix by how much. (softening both where neither counts was tried: it touched 0.1% of pixels for
// +0.01 db)
struct MP { float sw, sh, sig, floor; int doubt; };
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
                  texture2d<float, access::read> vec [[texture(6)]],
                  constant MP &p [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    float2 v = vec.read(gid).xy, h = v * 0.5f, hc = v * 0.25f; // half the vector in luma and in chroma pixels
    float2 cq = float2(gid) + 0.5f, lq = cq * 2.0f, size = float2(p.sw, p.sh);
    float wPrev = inside(lq - h, size), wCur = inside(lq + h, size);
    if (p.doubt) {
        int2 last = int2(vec.get_width(), vec.get_height()) - 1;
        float2 slipPrev = vec.read(uint2(clamp(int2(floor(cq - hc)), int2(0), last))).xy - v;
        float2 slipCur = vec.read(uint2(clamp(int2(floor(cq + hc)), int2(0), last))).xy - v;
        wPrev *= max(exp(-dot(slipPrev, slipPrev) / (p.sig * p.sig)), p.floor);
        wCur *= max(exp(-dot(slipCur, slipCur) / (p.sig * p.sig)), p.floor);
    }
    float toCur = wPrev + wCur > 0.0f ? wCur / (wPrev + wCur) : 0.5f; // both outside: half each
    for (int i = 0; i < 4; i++) {
        float2 s = lq + float2(float(i % 2) - 0.5f, float(i / 2) - 0.5f);
        outY.write(float4(saturate(mix(sharp(prevY, s - h), sharp(curY, s + h), toCur))), gid * 2 + uint2(i % 2, i / 2));
    }
    outC.write(float4(mix(prevC.sample(tween, cq - hc).rg, curC.sample(tween, cq + hc).rg, toCur), 0, 0), gid);
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
// genDoubt: how far (px) the field where a side's sample lands may move otherwise before that side stops counting,
// and the least it then counts. the floor: 1e-3 to 0.5 all 38.11 db on the clips; 0.05, so a slipping side counts
// 1/20 and two slipping sides still mix by how much
static const float kSideSig = 10, kSideFloor = 0.05f;

struct Lv { int32_t rBlend, rNear, rZero; float step, toFull, lam, zeroBonus; };
struct GP { int32_t range; float scale; };
struct PK { float cellShare, zeroShare; };
struct MP { float size[2], sig, floor; int32_t doubt; };

static struct {
    id<MTLDevice> dev; // these four once, kept over stop()
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> halve, search, medoid, fill, shiftCost, shiftBest, pick, mixer;
    CVMetalTextureCacheRef cache = NULL;
    std::vector<id<MTLTexture>> pa, pb, raw, field; // per level, [0] is level 1
    id<MTLTexture> vec, none, pan;                  // none, pan: the 1x1 fields the top starts from
    id<MTLBuffer> cost;
    int w = 0, h = 0;
    double gpuMs = 0;
    bool up = false;
} gS;

static std::atomic<bool> gRefused{false};
static os_unfair_lock gWhyLock = OS_UNFAIR_LOCK_INIT;
static std::string gWhy;

double lastGpuMs() { return gS.gpuMs; }
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

void stop() {
    gS.pa.clear(); gS.pb.clear(); gS.raw.clear(); gS.field.clear();
    gS.vec = gS.none = gS.pan = nil;
    gS.cost = nil;
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

bool generate(CVPixelBufferRef prev, CVPixelBufferRef cur, CVPixelBufferRef dst, bool, bool) {
    if (!gS.up) return false;
    for (CVPixelBufferRef pb : {prev, cur, dst})
        if ((int)CVPixelBufferGetWidth(pb) != gS.w || (int)CVPixelBufferGetHeight(pb) != gS.h || CVPixelBufferGetPlaneCount(pb) != 2) return false;
    bool shift = gSet.genShift, doubt = gSet.genDoubt;
    std::vector<CVMetalTextureRef> keep;
    id<MTLTexture> prevY = plane(prev, 0, false, keep), prevC = plane(prev, 1, false, keep);
    id<MTLTexture> curY = plane(cur, 0, false, keep), curC = plane(cur, 1, false, keep);
    id<MTLTexture> outY = plane(dst, 0, true, keep), outC = plane(dst, 1, true, keep);
    bool ok = prevY && prevC && curY && curC && outY && outC;
    if (ok) {
        id<MTLCommandBuffer> cb = [gS.queue commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
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
            Lv lv = {i == top ? 3 : 2, 1, i == top ? kRangeTop : i ? 1 : 0, i ? 1.0f : 0.5f, (float)(2 << i), kLam, kZeroSearch};
            [e setComputePipelineState:gS.search];
            [e setTexture:gS.raw[i] atIndex:0];
            [e setTexture:gS.pa[i] atIndex:1]; [e setTexture:gS.pb[i] atIndex:2];
            [e setTexture:i < top ? gS.field[i + 1] : shift ? gS.pan : gS.none atIndex:3];
            [e setBytes:&lv length:sizeof lv atIndex:7];
            [e dispatchThreadgroups:MTLSizeMake(gS.raw[i].width, gS.raw[i].height, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
            [e setTexture:gS.field[i] atIndex:0]; [e setTexture:gS.raw[i] atIndex:1];
            run(e, gS.medoid, gS.raw[i].width, gS.raw[i].height);
        }
        float lsize[2] = {(float)gS.pa[0].width, (float)gS.pa[0].height};
        [e setTexture:gS.raw[0] atIndex:0]; [e setTexture:gS.field[0] atIndex:1]; // raw is free again by now
        [e setBytes:lsize length:sizeof lsize atIndex:7];
        run(e, gS.fill, gS.raw[0].width, gS.raw[0].height);
        PK pk = {kCellShare, kZeroShare};
        [e setTexture:gS.vec atIndex:0];
        [e setTexture:gS.pa[0] atIndex:1]; [e setTexture:gS.pb[0] atIndex:2]; [e setTexture:gS.raw[0] atIndex:3];
        [e setBytes:&pk length:sizeof pk atIndex:7];
        run(e, gS.pick, gS.vec.width, gS.vec.height);
        MP mp = {{(float)gS.w, (float)gS.h}, kSideSig, kSideFloor, doubt};
        [e setTexture:outY atIndex:0]; [e setTexture:outC atIndex:1];
        [e setTexture:prevY atIndex:2]; [e setTexture:curY atIndex:3]; [e setTexture:prevC atIndex:4]; [e setTexture:curC atIndex:5];
        [e setTexture:gS.vec atIndex:6];
        [e setBytes:&mp length:sizeof mp atIndex:7];
        run(e, gS.mixer, outC.width, outC.height);
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        ok = cb.status == MTLCommandBufferStatusCompleted;
        if (ok) gS.gpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
    }
    for (CVMetalTextureRef t : keep) CFRelease(t);
    CVMetalTextureCacheFlush(gS.cache, 0); // the cache would otherwise hold on to every frame's planes
    return ok;
}

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
    gS.dev = dev; gS.queue = queue;
    gS.halve = all[0]; gS.search = all[1]; gS.medoid = all[2]; gS.fill = all[3];
    gS.shiftCost = all[4]; gS.shiftBest = all[5]; gS.pick = all[6]; gS.mixer = all[7];
    gS.cache = cache;
    return nullptr;
}

static id<MTLTexture> image(int w, int h, MTLPixelFormat f, MTLStorageMode m = MTLStorageModePrivate) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.width = w; d.height = h; d.pixelFormat = f;
    d.storageMode = m;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [gS.dev newTextureWithDescriptor:d];
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
        gS.none = image(1, 1, MTLPixelFormatRG32Float, MTLStorageModeShared);
        gS.pan = image(1, 1, MTLPixelFormatRG32Float, MTLStorageModePrivate);
        gS.cost = [gS.dev newBufferWithLength:sizeof(float) * (2 * kShiftRange + 1) * (2 * kShiftRange + 1) options:MTLResourceStorageModePrivate];
        bool have = gS.vec && gS.none && gS.pan && gS.cost;
        for (size_t i = 0; i < gS.pa.size(); i++) have = have && gS.pa[i] && gS.pb[i] && gS.raw[i] && gS.field[i];
        if (!have) return refuse("out of gpu memory");
        float zero[2] = {0, 0};
        [gS.none replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:sizeof zero];
        gS.up = true;
        // a throwaway frame now: metal compiles and allocates on first use, better here than on the first real pair
        CVPixelBufferRef a = blank(w, h), b = blank(w, h), d = blank(w, h);
        bool ran = a && b && d && generate(a, b, d, false, false);
        if (a) CFRelease(a);
        if (b) CFRelease(b);
        if (d) CFRelease(d);
        if (!ran) return refuse("the first frame did not come out");
    }
    return true;
}

}
