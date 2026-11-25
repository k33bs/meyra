// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#include <metal_stdlib>
using namespace metal;

struct V { float4 pos [[position]]; float2 uv; };

vertex V vs(uint vid [[vertex_id]]) {
    float2 p = float2(vid & 1, vid >> 1);
    V o;
    o.pos = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

// full = 1 when the source uses the whole 0..255 range (black at 0) instead of video range (black at 16).
// reading a full range signal as video range crushes shadows and clips highlights.
// mode: 1 = sd source (bt.601 colour), 2 = old green rule (see fsNvFix), added up
struct L { float full; float still; float stillTol; float mode; }; // still: 0 no still-area rule, else which (see stillWeight)

// bt.709 yuv -> gamma rgb. sd (480 / 576 lines) is bt.601: read as 709 its reds and greens come out visibly off
static float3 toRgb(float y, float cb, float cr, float full, bool sd = false) {
    if (full > 0.5) {
        cb -= 128.0 / 255.0;
        cr -= 128.0 / 255.0;
    } else {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cb = (cb - 128.0 / 255.0) * (255.0 / 224.0);
        cr = (cr - 128.0 / 255.0) * (255.0 / 224.0);
    }
    if (sd) return saturate(float3(y + 1.402 * cr, y - 0.3441 * cb - 0.7141 * cr, y + 1.772 * cb));
    return saturate(float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb));
}
static bool isSd(float mode) { return (int(mode) & 1) != 0; }

// 4:2:2 from hdmi / sdi has each chroma sample at the place of the left luma sample of its pair. the gpu reads a half
// width chroma texture as if each sample sat between the two (measured), which puts colour half a luma pixel to the
// right of where it belongs. reading it this far further right puts it back
constant float kChromaShift = 0.5;

// bgrg422 view of 2vuy: g = luma, b = cb, r = cr
fragment float4 fsYuv(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv + float2(kChromaShift / t.get_width(), 0));
    return float4(toRgb(t.sample(s, in.uv).g, c.b, c.r, l.full, isSd(l.mode)), 1);
}

// two plane 420v: luma in r8, cb cr in rg8 at half size
fragment float4 fsNv(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]], constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 c = tc.sample(s, in.uv + float2(kChromaShift / ty.get_width(), 0)).rg;
    return float4(toRgb(ty.sample(s, in.uv).r, c.r, c.g, l.full, isSd(l.mode)), 1);
}

// generated frames only. where content slid in from outside the picture the interpolator has nothing to draw from and
// leaves chroma collapsing towards zero, which shows as vivid green (measured 20 to 90 of 255 on both channels).
// both chroma channels very low here or right next to here -> take the real frame's pixel instead.
// grass and other real greens sit in the same range (cb 85 cr 89 measured), so low alone is not enough: the real
// frame's chroma at that spot must be clearly higher, which is what a collapse looks like and green on green is not.
// mode 2 is the rule before that (low alone), kept to compare
// the still-area rule, all of it in here: how much of the real frame's pixel a generated frame takes at uv, 0..1.
// still things (hud, anything that did not change between the two real frames) are softened and can be wobbled by
// the interpolator, the real pixel is exact. g: the generated luma here, ry / py: luma of the newer and older real
// frame. mode (genStill + 1): 1 the hard rule, 2 soft, 3 and 4 metalgoose's
constant float kStillOut = 6.0 / 255.0; // soft rule: this far outside what the real frame has nearby and the generated pixel starts to stay
static float stillWeight(float2 uv, float g, texture2d<float> ry, texture2d<float> py, float mode, float tol) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float2 ly = 1.0 / float2(ry.get_width(), ry.get_height());
    if (mode > 2.5) {
        // metalgoose's stability blend (gpl-3, Shaders/Stability.metal), on luma: largest change between the real
        // frames within 5x5 over the largest step between neighbours there is about "pixels moved". weight falls
        // with it, none from 0.9; 4/255 is their noise floor. nothing changed within 3x3: the real pixel as it is.
        // mode 4: that last test on 3x3 averages, because a game's dither changes every frame and never passes it
        float P[49], N[49];
        for (int j = 0; j < 7; j++)
            for (int i = 0; i < 7; i++) {
                float2 o = uv + float2(i - 3, j - 3) * ly;
                N[j * 7 + i] = ry.sample(n, o).r;
                P[j * 7 + i] = py.sample(n, o).r;
            }
        float dmax = 0, cmax = 0, dnear = 0, bn = 0, bp = 0;
        for (int j = 1; j < 6; j++)
            for (int i = 1; i < 6; i++) {
                int k = j * 7 + i;
                float d = abs(N[k] - P[k]);
                dmax = max(dmax, d);
                cmax = max(cmax, max(max(abs(P[k - 1] - P[k]), abs(P[k + 1] - P[k])), max(abs(P[k - 7] - P[k]), abs(P[k + 7] - P[k]))));
                cmax = max(cmax, max(max(abs(N[k - 1] - N[k]), abs(N[k + 1] - N[k])), max(abs(N[k - 7] - N[k]), abs(N[k + 7] - N[k]))));
                if (i > 1 && i < 5 && j > 1 && j < 5) { dnear = max(dnear, d); bn += N[k]; bp += P[k]; }
            }
        // mode 4's averages also agree by chance on single pixels of something that moves, and the real frame's pixel
        // there is a speck in the generated one (measured 336 a frame against 2): only where nothing within 5x5
        // changed by more than a dither does (9 of 255, where the soft rule ends too)
        if (mode > 3.5) dnear = dmax <= 9.0 / 255.0 ? abs(bn - bp) / 9 : 1;
        if (dnear <= tol) return 1;
        float r = saturate(1 - dmax / (cmax + 4.0 / 255.0) / 0.9);
        return r * r;
    }
    // still = both real frames agree on luma here and all around here
    float d = 0, lo = 1, hi = 0;
    for (int j = -2; j <= 2; j += 2)
        for (int i = -2; i <= 2; i += 2) {
            float2 o = uv + float2(i, j) * ly;
            float r = ry.sample(n, o).r;
            d = max(d, abs(r - py.sample(n, o).r));
            lo = min(lo, r); hi = max(hi, r);
        }
    if (mode < 1.5) return d < tol ? 1.0 : 0.0; // the hard rule: unchanged to within tol or not at all
    // soft: a game's dither changes every frame, so still is not identical and a hard limit switches pixels on and off
    float w = 1 - smoothstep(tol, 2 * tol, d);
    // something small and fast is at neither of its two places here: both real frames show what is behind it
    // and agree, and the real pixel would rub it out of every generated frame. told apart from a still thing the
    // interpolator only softened by its value: a softened pixel stays between the values the real frame has
    // around it, something that is only in the generated frame mostly does not
    if (w > 0) {
        for (int k = 0; k < 4; k++) { // in between the taps above, two by two pixels each
            float r = ry.sample(s, uv + float2(k & 1 ? 1.5 : -1.5, k & 2 ? 1.5 : -1.5) * ly).r;
            lo = min(lo, r); hi = max(hi, r);
        }
        w *= 1 - smoothstep(kStillOut, 2 * kStillOut, max(lo - g, g - hi));
    }
    return w;
}

// the generated frame's pixel after both rules, still as y cb cr
static float3 nvFix(V in, texture2d<float> ty, texture2d<float> tc, texture2d<float> ry, texture2d<float> rc, texture2d<float> py, constant L &l) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float2 px = 1.0 / float2(tc.get_width(), tc.get_height());
    float low = 1;
    bool oldRule = (int(l.mode) & 2) != 0;
    for (int j = -2; j <= 2; j++)
        for (int i = -2; i <= 2; i++) {
            float2 o = in.uv + float2(i, j) * px, c = tc.sample(n, o).rg, q = rc.sample(n, o).rg;
            float g = max(c.r, c.g);
            if (oldRule || max(q.r, q.g) > g + 0.06) low = min(low, g);
        }
    float w = low < 0.36 ? 1.0 : 0.0; // how much of the real frame's pixel
    float g = ty.sample(s, in.uv).r, r = ry.sample(s, in.uv).r;
    if (l.still > 0.5 && w < 0.5) {
        w = stillWeight(in.uv, g, ry, py, l.still, l.stillTol);
        if (l.still > 2.5 && w < 1) r = 0.5 * (r + py.sample(s, in.uv).r); // metalgoose: part weights go to the two real frames' mix
    }
    // the rim: in the outermost rows of colour, top and bottom, the collapse is only part of the way (measured cb 0.35
    // cr 0.40 where the picture has 0.47 0.52), above the limit of the rule further up, and shows as a green line
    // along the edge. there both channels clearly under the real frame's is enough, and only the colour is taken
    float wc = w;
    if (w < 0.5 && min(in.uv.y, 1 - in.uv.y) * tc.get_height() < 2.0)
        for (int i = -1; i <= 1; i++) {
            float2 o = in.uv + float2(i, 0) * px, e = tc.sample(n, o).rg, q = rc.sample(n, o).rg;
            if (q.r > e.r + 0.04 && q.g > e.g + 0.04) wc = 1;
        }
    // each frame's chroma is read on its own grid: a generated frame can be smaller than the real ones (genSmall)
    float2 c = mix(tc.sample(s, in.uv + float2(kChromaShift / ty.get_width(), 0)).rg, rc.sample(s, in.uv + float2(kChromaShift / ry.get_width(), 0)).rg, wc);
    float y = mix(g, r, w);
    return float3(y, c);
}
fragment float4 fsNvFix(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                        texture2d<float> ry [[texture(2)]], texture2d<float> rc [[texture(3)]], texture2d<float> py [[texture(4)]],
                        constant L &l [[buffer(0)]]) {
    float3 q = nvFix(in, ty, tc, ry, rc, py, l);
    return float4(toRgb(q.x, q.y, q.z, l.full, isSd(l.mode)), 1);
}

// hud lock. the two passes are ported from PushFPS (github.com/DosukaSOL/PushFPS, shaders/PushHudLockUpdate.hlsl and
// PushHudLockCompose.hlsl at commit 3be641ca, GPL-3.0-or-later, Copyright (C) 2026 DosukaSOL and the PushFPS
// contributors; see THIRD_PARTY_NOTICES.md). changed for here: fragment passes instead of compute, the frames come as
// 420v planes (change is taken on the rgb they stand for, contrast on luma), the tolerance is a setting, and the
// compose step is the tail of the pass that already repairs generated frames.
// state per pixel of the real frames: r = how long it has stayed the same, 0..1, g = how much contrast it has with
// its neighbours, a held maximum that fades.
constant float kLockRise = 0.06; // 1/0.06: about 38 real frames (1.3 s at 30 fps) to reach 0.9 from nothing
constant float kLockFade = 0.97; // held contrast fades about 3% a frame
static float lockLuma(float y, float full) { return full > 0.5 ? y : saturate((y - 16.0 / 255.0) * (255.0 / 219.0)); }
// once per new real frame. ty tc: that frame, py pc: the real frame before it, st: the state so far.
// l.still: 1 = start over, l.stillTol: largest channel change still counted as the same pixel (0.02)
fragment float4 fsLockUpdate(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                             texture2d<float> py [[texture(2)]], texture2d<float> pc [[texture(3)]], texture2d<float> st [[texture(4)]],
                             constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    if (l.still > 0.5) return float4(0, 0, 0, 1);
    float2 px = 1.0 / float2(ty.get_width(), ty.get_height()), cs = float2(kChromaShift / ty.get_width(), 0);
    float y = ty.sample(n, in.uv).r;
    float2 c = tc.sample(s, in.uv + cs).rg, q = pc.sample(s, in.uv + cs).rg;
    float3 d = abs(toRgb(y, c.r, c.g, l.full, isSd(l.mode)) - toRgb(py.sample(n, in.uv).r, q.r, q.g, l.full, isSd(l.mode)));
    float change = max(d.r, max(d.g, d.b));
    float lc = lockLuma(y, l.full);
    float contrast = max(max(abs(lc - lockLuma(ty.sample(n, in.uv + float2(px.x, 0)).r, l.full)), abs(lc - lockLuma(ty.sample(n, in.uv - float2(px.x, 0)).r, l.full))),
                         max(abs(lc - lockLuma(ty.sample(n, in.uv + float2(0, px.y)).r, l.full)), abs(lc - lockLuma(ty.sample(n, in.uv - float2(0, px.y)).r, l.full))));
    float2 v = st.sample(n, in.uv).rg;
    v.x = change < l.stillTol ? v.x + (1 - v.x) * kLockRise : 0;
    v.y = change < l.stillTol ? max(contrast, v.y * kLockFade) : contrast;
    return float4(v, 0, 1);
}
// a generated frame takes its locked pixels from the real frame. a pixel is locked when it has been still for about a
// second itself and it, or a neighbour that is just as still, has an edge: the inside of a thin stroke and the pixel
// beside an edge belong to the overlay too. a pixel that moves is never locked
static float lockStill(float2 v) { return smoothstep(0.80, 0.95, v.x); }
static float lockEdge(float2 v) { return smoothstep(0.04, 0.10, v.y); }
// the same pass as fsNvFix with the lock after it: the still-area rule decides for this pair of frames, the lock for
// what has been still a while. lk has the real frame's size, which is this pass's size
static float3 nvFixLock(V in, texture2d<float> ty, texture2d<float> tc, texture2d<float> ry, texture2d<float> rc, texture2d<float> py, texture2d<float> lk, constant L &l) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float3 q = nvFix(in, ty, tc, ry, rc, py, l);
    float still = lockStill(lk.sample(n, in.uv).rg), edge = 0;
    if (still > 0) {
        float2 px = 1.0 / float2(lk.get_width(), lk.get_height());
        for (int j = -1; j <= 1; j++)
            for (int i = -1; i <= 1; i++) {
                float2 v = lk.sample(n, in.uv + float2(i, j) * px).rg;
                edge = max(edge, lockEdge(v) * lockStill(v));
            }
    }
    float w = still * edge;
    // towards the real frame's own pixel, also where metalgoose's rule has mixed the two real frames
    if (w > 0) q = mix(q, float3(ry.sample(s, in.uv).r, rc.sample(s, in.uv + float2(kChromaShift / ry.get_width(), 0)).rg), w);
    return q;
}
fragment float4 fsNvFixLock(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                            texture2d<float> ry [[texture(2)]], texture2d<float> rc [[texture(3)]], texture2d<float> py [[texture(4)]],
                            texture2d<float> lk [[texture(5)]], constant L &l [[buffer(0)]]) {
    float3 q = nvFixLock(in, ty, tc, ry, rc, py, lk, l);
    return float4(toRgb(q.x, q.y, q.z, l.full, isSd(l.mode)), 1);
}

// hud areas (hudRects): rectangles the user marked on the picture. inside one a generated frame takes the newer real
// frame's pixel whatever the rules above said, with a few pixels of soft edge outside it so the border does not show.
// r: left, top, right, bottom in parts of the picture. n.x: how many, n.y: the soft edge in pixels of the real frame
struct HA { float4 r[8]; float4 n; };
static float3 hudAreas(float3 q, float2 uv, texture2d<float> ry, texture2d<float> rc, constant HA &h) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = float2(ry.get_width(), ry.get_height()), p = uv * size;
    float w = 0;
    for (int i = 0; i < int(h.n.x); i++) {
        float2 d = max(h.r[i].xy * size - p, p - h.r[i].zw * size); // how far outside, per axis
        w = max(w, 1 - smoothstep(0.0, h.n.y, length(max(d, 0.0))));
    }
    if (w > 0) q = mix(q, float3(ry.sample(s, uv).r, rc.sample(s, uv + float2(kChromaShift / ry.get_width(), 0)).rg), w);
    return q;
}
// the same two passes with the areas last. only used while any are set
fragment float4 fsNvFixHud(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                           texture2d<float> ry [[texture(2)]], texture2d<float> rc [[texture(3)]], texture2d<float> py [[texture(4)]],
                           constant L &l [[buffer(0)]], constant HA &h [[buffer(1)]]) {
    float3 q = hudAreas(nvFix(in, ty, tc, ry, rc, py, l), in.uv, ry, rc, h);
    return float4(toRgb(q.x, q.y, q.z, l.full, isSd(l.mode)), 1);
}
fragment float4 fsNvFixLockHud(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                               texture2d<float> ry [[texture(2)]], texture2d<float> rc [[texture(3)]], texture2d<float> py [[texture(4)]],
                               texture2d<float> lk [[texture(5)]], constant L &l [[buffer(0)]], constant HA &h [[buffer(1)]]) {
    float3 q = hudAreas(nvFixLock(in, ty, tc, ry, rc, py, lk, l), in.uv, ry, rc, h);
    return float4(toRgb(q.x, q.y, q.z, l.full, isSd(l.mode)), 1);
}

struct U { float2 texel; float amount; float pad; };

// dither removal. games dither by a level or two; averaging a few taps on a ring and taking the average only where it
// is within a couple of levels of the pixel flattens that without touching real edges or texture.
// the ring angle is a fixed hash of the pixel position, so the pattern does not crawl from frame to frame
fragment float4 fsDeband(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = t.sample(s, in.uv).rgb;
    float2 p = in.pos.xy;
    float a = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    for (int i = 0; i < 2; i++) {
        float r = (i == 0 ? 4.0 : 9.0);
        float2 o = float2(cos(a), sin(a)) * r * u.texel, q = float2(-o.y, o.x);
        float3 avg = 0.25 * (t.sample(s, in.uv + o).rgb + t.sample(s, in.uv - o).rgb + t.sample(s, in.uv + q).rgb + t.sample(s, in.uv - q).rgb);
        float3 diff = abs(avg - c);
        c = mix(c, avg, step(max(diff.r, max(diff.g, diff.b)), u.amount)); // amount: how far the average may be from the pixel
        a += 1.9;
    }
    return float4(c, 1);
}

// look: a tone curve on luma (33 points, linear in between), then one factor on the colour. g[33] is the factor
fragment float4 fsLook(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant float *g [[buffer(1)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float3 c = t.sample(s, in.uv).rgb;
    float y = dot(c, float3(0.2126, 0.7152, 0.0722)), x = saturate(y) * 32;
    int i = min(int(x), 31);
    return float4(saturate(mix(g[i], g[i + 1], x - i) + g[33] * (c - y)), 1);
}

// grain, the last thing done to the picture. code (u.pad): 0 off, else the frame number in the whole part and the strength
// (0..1) in the fraction. luma only, from two hashed draws (triangular, zero mean) per pixel, new for every frame. scaled by the
// pixel's own brightness like av1 grain: nothing at black, full from the shadows through the mids, fading out towards white
static float3 grainOn(float3 c, float2 p, float code) {
    if (code <= 0) return c;
    uint2 q = uint2(p);
    uint h = uint(code) * 0x9e3779b1u + q.x * 0x85ebca6bu + q.y * 0xc2b2ae35u;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    uint h2 = h * 0x2c1b3c6du + 0x297a2d39u;
    h2 ^= h2 >> 15; h2 *= 0x2c1b3c6du; h2 ^= h2 >> 12;
    float n = float(h >> 8) * (1.0 / 16777216.0) + float(h2 >> 8) * (1.0 / 16777216.0) - 1.0;
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    float s = smoothstep(0.0, 0.12, y) * (1.0 - smoothstep(0.55, 1.0, y));
    return saturate(c + n * s * fract(code) * 0.05);
}

// last pass: plain copy / bilinear scale when amount is 0, otherwise contrast adaptive sharpening on luma only
// (no colour fringes), eased off on isolated noisy pixels so grain is not amplified, and clamped to the
// neighbourhood so it cannot ring
fragment float4 fsOut(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 e = t.sample(s, in.uv).rgb;
    if (u.amount <= 0) return float4(grainOn(e, in.pos.xy, u.pad), 1);
    float3 b = t.sample(s, in.uv + float2(0, -u.texel.y)).rgb;
    float3 d = t.sample(s, in.uv + float2(-u.texel.x, 0)).rgb;
    float3 f = t.sample(s, in.uv + float2(u.texel.x, 0)).rgb;
    float3 h = t.sample(s, in.uv + float2(0, u.texel.y)).rgb;
    float3 mn = min(min(min(b, d), min(f, h)), e);
    float3 mx = max(max(max(b, d), max(f, h)), e);
    const float3 lw = float3(0.2126, 0.7152, 0.0722);
    float le = dot(e, lw), lb = dot(b, lw), ld = dot(d, lw), lf = dot(f, lw), lh = dot(h, lw);
    float lmn = min(min(min(lb, ld), min(lf, lh)), le), lmx = max(max(max(lb, ld), max(lf, lh)), le);
    float amp = sqrt(saturate(min(lmn, 1 - lmx) / max(lmx, 1e-4)));
    float noise = saturate(abs(0.25 * (lb + ld + lf + lh) - le) / max(lmx - lmn, 1e-4));
    float w = amp * (-1.0 / mix(8.0, 5.0, u.amount)) * (1 - 0.5 * noise);
    float lo = (lb * w + ld * w + lf * w + lh * w + le) / (1 + 4 * w);
    return float4(grainOn(clamp(e + (lo - le), mn, mx), in.pos.xy, u.pad), 1);
}

// compare view, diagonal cut: the original below a line from the top left to the bottom right corner, over the finished
// picture that is already there. amount: the line's half width in pixels
fragment float4 fsCut(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = t.sample(s, in.uv).rgb;
    float d = in.uv.y - in.uv.x, px = fwidth(d) * u.amount;
    if (d < -px) discard_fragment();
    return float4(d < px ? float3(0.6) : c, 1);
}

// edge-aware upscale: amd fidelityfx super resolution 1, the easu pass (mit, see THIRD_PARTY_NOTICES.md), in plain float.
// 12 taps around the output pixel, a lanczos-like kernel turned and stretched along the local edge, result clamped to
// the nearest four pixels so it cannot ring. wants gamma rgb in 0..1, which is what arrives here
static void easuSet(thread float2 &dir, thread float &len, float w, float lA, float lB, float lC, float lD, float lE) {
    float dc = lD - lC, cb = lC - lB;
    float dirX = lD - lB, lenX = saturate(abs(dirX) / max(max(abs(dc), abs(cb)), 1e-5));
    dir.x += dirX * w; len += lenX * lenX * w;
    float ec = lE - lC, ca = lC - lA;
    float dirY = lE - lA, lenY = saturate(abs(dirY) / max(max(abs(ec), abs(ca)), 1e-5));
    dir.y += dirY * w; len += lenY * lenY * w;
}
static void easuTap(thread float3 &aC, thread float &aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {
    float2 v = float2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;
    float d2 = min(dot(v, v), clp);
    float wB = 2.0 / 5.0 * d2 - 1, wA = lob * d2 - 1;
    wB *= wB; wA *= wA;
    float w = (25.0 / 16.0 * wB - (25.0 / 16.0 - 1)) * wA;
    aC += c * w; aW += w;
}
fragment float4 fsEasu(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float2 pp = in.uv / u.texel - 0.5, fp = floor(pp);
    pp -= fp;
    //   b c
    // e f g h
    // i j k l
    //   n o
    #define TAP(x, y) t.sample(s, (fp + float2(x, y) + 0.5) * u.texel).rgb
    float3 b = TAP(0, -1), c = TAP(1, -1), e = TAP(-1, 0), f = TAP(0, 0), g = TAP(1, 0), h = TAP(2, 0);
    float3 i = TAP(-1, 1), j = TAP(0, 1), k = TAP(1, 1), l = TAP(2, 1), n = TAP(0, 2), o = TAP(1, 2);
    #undef TAP
    const float3 lw = float3(0.5, 1, 0.5);
    float bL = dot(b, lw), cL = dot(c, lw), eL = dot(e, lw), fL = dot(f, lw), gL = dot(g, lw), hL = dot(h, lw);
    float iL = dot(i, lw), jL = dot(j, lw), kL = dot(k, lw), lL = dot(l, lw), nL = dot(n, lw), oL = dot(o, lw);
    float2 dir = 0;
    float len = 0;
    easuSet(dir, len, (1 - pp.x) * (1 - pp.y), bL, eL, fL, gL, jL);
    easuSet(dir, len, pp.x * (1 - pp.y), cL, fL, gL, hL, kL);
    easuSet(dir, len, (1 - pp.x) * pp.y, fL, iL, jL, kL, nL);
    easuSet(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);
    float dirR = dot(dir, dir);
    dir = dirR < 1.0 / 32768.0 ? float2(1, 0) : dir * rsqrt(dirR);
    len = len * 0.5; len *= len;
    float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));
    float2 len2 = float2(1 + (stretch - 1) * len, 1 - 0.5 * len);
    float lob = 0.5 + (1.0 / 4.0 - 0.04 - 0.5) * len, clp = 1 / lob;
    float3 mn = min(min(f, g), min(j, k)), mx = max(max(f, g), max(j, k));
    float3 aC = 0;
    float aW = 0;
    easuTap(aC, aW, float2(0, -1) - pp, dir, len2, lob, clp, b);
    easuTap(aC, aW, float2(1, -1) - pp, dir, len2, lob, clp, c);
    easuTap(aC, aW, float2(-1, 1) - pp, dir, len2, lob, clp, i);
    easuTap(aC, aW, float2(0, 1) - pp, dir, len2, lob, clp, j);
    easuTap(aC, aW, float2(0, 0) - pp, dir, len2, lob, clp, f);
    easuTap(aC, aW, float2(-1, 0) - pp, dir, len2, lob, clp, e);
    easuTap(aC, aW, float2(1, 1) - pp, dir, len2, lob, clp, k);
    easuTap(aC, aW, float2(2, 1) - pp, dir, len2, lob, clp, l);
    easuTap(aC, aW, float2(2, 0) - pp, dir, len2, lob, clp, h);
    easuTap(aC, aW, float2(1, 0) - pp, dir, len2, lob, clp, g);
    easuTap(aC, aW, float2(1, 2) - pp, dir, len2, lob, clp, o);
    easuTap(aC, aW, float2(0, 2) - pp, dir, len2, lob, clp, n);
    return float4(clamp(aC / aW, mn, mx), 1);
}

// snapdragon game super resolution 1 (qualcomm, bsd-3-clause, see THIRD_PARTY_NOTICES.md), written out tap by tap.
// bilinear colour, plus a correction worked out on green alone: 12 taps of a lanczos-like kernel that narrows where
// the taps differ from the middle, pushed (edge sharpness 2) and clamped to the nearest four. flat areas are left as
// plain bilinear, so grain is not touched
static float2 sgsrW(float2 d, float c, float sd) {
    float x = dot(d, d) * 0.55 + saturate(abs(c) * sd);
    float wA = x - 4, wB = x * wA - wA;
    float w = wB * wA * wA;
    return float2(w, w * c);
}
fragment float4 fsSgsr(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float3 col = t.sample(s, in.uv).rgb;
    float2 pp = in.uv / u.texel - 0.5, fp = floor(pp);
    pp -= fp;
    #define G(x, y) t.sample(n, (fp + float2(x, y) + 0.5) * u.texel).g
    float f = G(0, 0), g = G(1, 0), j = G(0, 1), k = G(1, 1);
    if (abs(f - j) + abs(col.g - j) + abs(col.g - f) <= 8.0 / 255.0) return float4(col, 1);
    const float2 o[12] = {float2(0, -1), float2(1, -1), float2(-1, 0), float2(0, 0), float2(1, 0), float2(2, 0),
                          float2(-1, 1), float2(0, 1), float2(1, 1), float2(2, 1), float2(0, 2), float2(1, 2)};
    float v[12] = {G(0, -1), G(1, -1), G(-1, 0), f, g, G(2, 0), G(-1, 1), j, k, G(2, 1), G(0, 2), G(1, 2)};
    #undef G
    float mean = 0.25 * (f + g + j + k), sum = 0;
    for (int i = 0; i < 12; i++) { v[i] -= mean; sum += abs(v[i]); }
    float sd = 2.181818 / max(sum, 1e-5);
    float2 a = 0;
    for (int i = 0; i < 12; i++) a += sgsrW(pp - o[i], v[i], sd);
    float mn = min(min(f, g), min(j, k)) - mean, mx = max(max(f, g), max(j, k)) - mean;
    float d = clamp(clamp(2.0 * a.y / a.x, mn, mx) - (col.g - mean), -23.0 / 255.0, 23.0 / 255.0);
    return float4(saturate(col + d), 1);
}

// apple super resolution. the scaler takes 420v at most ~1280 px a side, so the levelled, debanded picture is written
// out as one or two tiles (luma at full size, cb cr at half: the linear sample in the middle of a 2x2 block is its
// average), and the scaled tiles are put back together, faded across the middle of their overlap
// tile's left edge and width as parts of the picture width, top edge and height as parts of its height. a padded
// tile starts outside the picture, the sampler mirrors there
struct T { float off; float scale; float yoff; float yscale; };
static float3 toYuv(float3 c) { // gamma rgb -> bt.709 video range, the inverse of toRgb
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float3(16.0 / 255 + y * (219.0 / 255), 128.0 / 255 + (c.b - y) / 1.8556 * (224.0 / 255), 128.0 / 255 + (c.r - y) / 1.5748 * (224.0 / 255));
}
fragment float4 fsTileY(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant T &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::mirrored_repeat);
    return float4(toYuv(t.sample(s, float2(u.off + in.uv.x * u.scale, u.yoff + in.uv.y * u.yscale)).rgb).x, 0, 0, 1);
}
fragment float4 fsTileC(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant T &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::mirrored_repeat);
    return float4(toYuv(t.sample(s, float2(u.off + in.uv.x * u.scale, u.yoff + in.uv.y * u.yscale)).rgb).yz, 0, 1);
}

// a whole picture back to 420v in the source's own range and matrix (the L of the pass that read it): the pre stages
// of the chain hand the interpolator, and later the screen, a frame like any other. chroma sits on the left luma
// sample of each pair, as it came
static float3 toYuvAs(float3 c, float full, bool sd) {
    float3 w = sd ? float3(0.299, 0.587, 0.114) : float3(0.2126, 0.7152, 0.0722);
    float y = dot(c, w), cb = (c.b - y) / (sd ? 1.772 : 1.8556), cr = (c.r - y) / (sd ? 1.402 : 1.5748);
    if (full > 0.5) return float3(y, 128.0 / 255 + cb, 128.0 / 255 + cr);
    return float3(16.0 / 255 + y * (219.0 / 255), 128.0 / 255 + cb * (224.0 / 255), 128.0 / 255 + cr * (224.0 / 255));
}
fragment float4 fsBackY(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(toYuvAs(t.sample(s, in.uv).rgb, l.full, isSd(l.mode)).x, 0, 0, 1);
}
fragment float4 fsBackC(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(toYuvAs(t.sample(s, in.uv - float2(kChromaShift / t.get_width(), 0)).rgb, l.full, isSd(l.mode)).yz, 0, 1);
}

// first tile's right edge, second's left edge (0: one tile), padding across and down. the seam fades across the middle
// half of what the two tiles share
struct C { float a1; float b0; float px; float py; };
static float3 tileAt(texture2d<float> y0, texture2d<float> c0, texture2d<float> y1, texture2d<float> c1, float2 uv, constant C &u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float ov = u.a1 - u.b0, f0 = u.b0 + ov / 4, f1 = u.a1 - ov / 4;
    float w = u.b0 > 0 ? saturate((uv.x - f0) / (f1 - f0)) : 0;
    float py = (uv.y + u.py) / (1 + 2 * u.py);
    float3 a = 0, b = 0;
    if (w < 1) { float2 p = float2((uv.x + u.px) / (u.a1 + 2 * u.px), py), c = c0.sample(s, p).rg; a = toRgb(y0.sample(s, p).r, c.r, c.g, 0); }
    if (w > 0) { float2 p = float2((uv.x - u.b0 + u.px) / (1 - u.b0 + 2 * u.px), py), c = c1.sample(s, p).rg; b = toRgb(y1.sample(s, p).r, c.r, c.g, 0); }
    return mix(a, b, w);
}
// the scaled picture is usually bigger than the window. bilinear alone is fine down to about 2/3 (more taps there only
// blur), below that n x n bilinear taps spread over each screen pixel
fragment float4 fsTiles(V in [[stage_in]], texture2d<float> y0 [[texture(0)]], texture2d<float> c0 [[texture(1)]],
                        texture2d<float> y1 [[texture(2)]], texture2d<float> c1 [[texture(3)]], constant C &u [[buffer(0)]]) {
    float2 d = float2(abs(dfdx(in.uv.x)), abs(dfdy(in.uv.y)));
    int n = clamp(int(max(d.x * y0.get_width() / (u.a1 + 2 * u.px), d.y * y0.get_height() / (1 + 2 * u.py)) + 0.5), 1, 4);
    float3 sum = 0;
    for (int j = 0; j < n; j++)
        for (int i = 0; i < n; i++) sum += tileAt(y0, c0, y1, c1, in.uv + ((float2(i, j) + 0.5) / n - 0.5) * d, u);
    return float4(sum / (n * n), 1);
}

// a picture larger than its place on screen (the 2x result of an enhance net in a smaller window).
// amount 0, area: n x n bilinear taps spread over each screen pixel. at exactly half size that is the mean of the four
// pixels, which hands back very nearly the picture the net was given (measured 51 db): safe, and little gained.
// amount 1, lanczos 2 stretched to the screen pixel: keeps what the net added below the screen's own limit (at half
// size 0.88 of the finest detail a screen pixel can carry instead of 0.71), clamped to the pixels around so it
// cannot ring
fragment float4 fsDown(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 d = float2(abs(dfdx(in.uv.x)), abs(dfdy(in.uv.y)));
    float2 r = max(d / u.texel, 1.0); // source pixels per screen pixel
    if (u.amount < 0.5) {
        int n = clamp(int(max(r.x, r.y) + 0.5), 1, 4);
        float3 sum = 0;
        for (int j = 0; j < n; j++)
            for (int i = 0; i < n; i++) sum += t.sample(s, in.uv + ((float2(i, j) + 0.5) / n - 0.5) * d).rgb;
        return float4(sum / (n * n), 1);
    }
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float2 pp = in.uv / u.texel - 0.5, fp = floor(pp);
    float3 sum = 0, mn = 1, mx = 0;
    float ws = 0;
    for (int j = -3; j <= 4; j++)
        for (int i = -3; i <= 4; i++) {
            float2 o = float2(i, j), x = abs(fp + o - pp) / r; // distance in screen pixels
            if (x.x >= 2 || x.y >= 2) continue;
            float2 a = max(x * 3.14159265, 1e-4), k = sin(a) * sin(a * 0.5) / (a * a * 0.5);
            float3 c = t.sample(n, (fp + o + 0.5) * u.texel).rgb;
            sum += c * k.x * k.y; ws += k.x * k.y;
            if (x.x < 1 && x.y < 1) { mn = min(mn, c); mx = max(mx, c); }
        }
    return float4(clamp(sum / ws, mn, mx), 1);
}

// supersample: a picture scaled to exactly twice its place on screen, brought down by the mean of each 2x2 block,
// taken in linear light (amount = the gamma the values are decoded with, 1 = averaged as they are). in gamma the mean
// of a bright and a dark pixel comes out too dark, which is what thins bright lines and fattens dark ones
fragment float4 fsBox(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    uint2 p = uint2(in.pos.xy) * 2;
    float3 g = float3(u.amount);
    float3 sum = pow(t.read(p).rgb, g) + pow(t.read(p + uint2(1, 0)).rgb, g) + pow(t.read(p + uint2(0, 1)).rgb, g) + pow(t.read(p + uint2(1, 1)).rgb, g);
    return float4(pow(sum * 0.25, 1 / g), 1);
}

// enhanceReal, enhanceHold: what an enhance net added to a real frame is kept apart from the picture, in a texture
// at the net's output size: r = what it added to luma, g = the luma it was given (bilinear for a 2x net), the guide
// that says later whether a pixel still shows what the kept change was made for.
// pitch: one pixel of the net's input in texels of the kept texture (2 for a 2x net)
struct K { float pitch; float tol; float a; float b; };
constant float3 kLw = float3(0.2126, 0.7152, 0.0722);
// the picture t against the guide in k, over 3x3 input pixels: 1 = the same to within tol, 0 from twice that
static float keptMatch(texture2d<float> t, texture2d<float> k, float2 uv, float pitch, float tol) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float2 st = pitch / float2(k.get_width(), k.get_height());
    float d = 0;
    for (int j = -1; j <= 1; j++)
        for (int i = -1; i <= 1; i++) {
            float2 o = uv + float2(i, j) * st;
            d = max(d, abs(dot(t.sample(s, o).rgb, kLw) - k.sample(n, o).g));
        }
    return 1 - smoothstep(tol, 2 * tol, d);
}
// the frame the kept change was made from, shown (again): the net's picture without running the net
fragment float4 fsKeepAdd(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> k [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(saturate(t.sample(s, in.uv).rgb + k.read(uint2(in.pos.xy)).r), 1);
}
// another frame (a generated one, a repeat): the kept change where the picture still matches its guide, nothing where
// it does not. a = 1: a second kept frame in k2 fills in where the first does not match
fragment float4 fsKeepUse(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> k [[texture(1)]], texture2d<float> k2 [[texture(2)]],
                          constant K &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    uint2 p = uint2(in.pos.xy);
    float w = keptMatch(t, k, in.uv, u.pitch, u.tol);
    float r = w * k.read(p).r;
    if (u.a > 0.5 && w < 1) r += (1 - w) * keptMatch(t, k2, in.uv, u.pitch, u.tol) * k2.read(p).r;
    return float4(saturate(t.sample(s, in.uv).rgb + r), 1);
}
// steady enhance: only what the net added is filtered over time, never the picture. the change kept from the real
// frame before (h, same pixel: there are no motion vectors) is trusted where the guide still matches, held inside
// the range the fresh change has in the 3x3 around (plus b) so it cannot carry something the net no longer puts
// there, and mixed in with weight a. where the picture changed the fresh change goes out as it is
fragment float4 fsHold(V in [[stage_in]], texture2d<float> now [[texture(0)]], texture2d<float> h [[texture(1)]], constant K &u [[buffer(0)]]) {
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float2 px = 1.0 / float2(now.get_width(), now.get_height());
    float2 c = now.sample(n, in.uv).rg;
    float d = 0, lo = c.r, hi = c.r;
    for (int j = -1; j <= 1; j++)
        for (int i = -1; i <= 1; i++) {
            float2 o = float2(i, j) * px;
            d = max(d, abs(now.sample(n, in.uv + o * u.pitch).g - h.sample(n, in.uv + o * u.pitch).g));
            float r = now.sample(n, in.uv + o).r;
            lo = min(lo, r); hi = max(hi, r);
        }
    float q = 1 - smoothstep(u.tol, 2 * u.tol, d);
    return float4(mix(c.r, clamp(h.sample(n, in.uv).r, lo - u.b, hi + u.b), u.a * q), c.g, 0, 1);
}

// status overlay, premultiplied alpha
fragment float4 fsHud(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
