// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <Foundation/Foundation.h>

// the shaders of upscale 5 (hashed filters) and stabilise. not in Shaders.metal: they are compiled the first time one
// of the two is used (renderer.mm, hashStabPipes), so with both off nothing of them is built and a fault here cannot
// keep meyra from starting
namespace renderer {
extern NSString *const kHashStabKernels; // a const would stay in this file
NSString *const kHashStabKernels = @R"M(
#include <metal_stdlib>
using namespace metal;

struct V { float4 pos [[position]]; float2 uv; }; // as in Shaders.metal
vertex V vs(uint vid [[vertex_id]]) {
    float2 p = float2(vid & 1, vid >> 1);
    V o;
    o.pos = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}
struct U { float2 texel; float amount; float pad; };

// upscale 5, hashed filters: the raisr / ravu-lite method, written here from the method. the table is ravu-lite r3's
// (lgpl-3, see THIRD_PARTY_NOTICES.md), turned by tools/ravu2hash.py. per source pixel: 5x5 luma around it, gradients
// in the middle 3x3 weighed by a small gaussian, and from their structure tensor the edge's angle (24 steps over 180
// degrees), strength (4) and how much one direction rules (3). that picks one of 288 trained 5x5 kernels, four in
// one, a kernel per sub-pixel of the 2x picture. luma only, colour comes along bilinear as with the nets.
// k: 13 x 289 rgba32f, a row per bucket (taps 0..12, y * 5 + x, the other 12 by point symmetry), the last row
// holds the strength and coherence steps and the gaussian
static float yOf(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
constant float kHashAr = 1.0; // how far each sub-pixel is held inside the four source pixels nearest it: no ringing
// out: the four sub-pixels' luma, left top, right top, left bottom, right bottom
fragment float4 fsHashY(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> k [[texture(1)]]) {
    int2 p = int2(in.pos.xy), m = int2(t.get_width(), t.get_height()) - 1;
    float l[25];
    for (int j = 0; j < 5; j++)
        for (int i = 0; i < 5; i++) l[j * 5 + i] = yOf(t.read(uint2(clamp(p + int2(i - 2, j - 2), 0, m))).rgb);
    float4 st = k.read(uint2(0, 288)), co = k.read(uint2(1, 288));
    float a = 0, b = 0, d = 0;
    for (int j = 1; j < 4; j++) {
        float3 g = k.read(uint2(1 + j, 288)).rgb;
        for (int i = 1; i < 4; i++) {
            float gx = 0.5 * (l[j * 5 + i + 1] - l[j * 5 + i - 1]), gy = 0.5 * (l[j * 5 + i + 5] - l[j * 5 + i - 5]), w = g[i - 1];
            a += gx * gx * w; b += gx * gy * w; d += gy * gy * w;
        }
    }
    float tr = 0.5 * (a + d), h = sqrt(max(tr * tr - (a * d - b * b), 0.0));
    float l1 = tr + h, s1 = sqrt(l1), s2 = sqrt(max(tr - h, 0.0));
    float ang = abs(b) < 1.192092896e-7 ? 0.0 : fmod(atan2(l1 - a, b) + M_PI_F, M_PI_F); // of the stronger direction
    float coh = s1 + s2 < 1.192092896e-7 ? 0.0 : (s1 - s2) / (s1 + s2);
    int ai = min(int(ang * 24 / M_PI_F), 23), si = int(s1 >= st.x) + int(s1 >= st.y) + int(s1 >= st.z), ci = int(coh >= co.x) + int(coh >= co.y);
    uint row = uint((ai * 4 + si) * 3 + ci);
    float4 r = l[12] * k.read(uint2(12, row));
    for (int i = 0; i < 12; i++) {
        float4 w = k.read(uint2(i, row));
        r += l[i] * w + l[24 - i] * w.wzyx; // tap 24 - i has sub-pixel 3 - s's weight of tap i
    }
    float4 mn = min(float4(l[11], l[13], l[11], l[13]), float4(l[7], l[7], l[17], l[17]));
    float4 mx = max(float4(l[11], l[13], l[11], l[13]), float4(l[7], l[7], l[17], l[17]));
    mn = min(min(mn, float4(l[6], l[8], l[16], l[18])), l[12]);
    mx = max(max(mx, float4(l[6], l[8], l[16], l[18])), l[12]);
    return saturate(mix(r, clamp(r, mn, mx), kHashAr));
}
// the 2x picture: bilinear colour with its luma replaced by the filters'
fragment float4 fsHashUp(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> y4 [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    uint2 p = uint2(in.pos.xy);
    float3 c = t.sample(s, in.uv).rgb;
    return float4(saturate(c + (y4.read(p / 2)[(p.y & 1) * 2 + (p.x & 1)] - yOf(c))), 1);
}

// stabilise, real frames only: the result for the frame before, moved along the picture's motion in whole pixels (no
// resampling, nothing to soften), held inside what the 3x3 around has now and mixed in with a modest weight. where
// the move is not trusted or the hold has to cut much off, the frame as it is.
// motion: a block search here, 16x16 blocks. a quarter size luma first (4x4 means)
fragment float4 fsStabQ(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = 1.0 / float2(t.get_width(), t.get_height());
    float3 c = t.sample(s, in.uv + float2(-1, -1) * px).rgb + t.sample(s, in.uv + float2(1, -1) * px).rgb +
               t.sample(s, in.uv + float2(-1, 1) * px).rgb + t.sample(s, in.uv + float2(1, 1) * px).rgb;
    return float4(yOf(c * 0.25), 0, 0, 1);
}
// the search, spread so the gpu has enough to do at once: a pixel per block and move tried. coarse: +-6 quarter pixels
// (24 px) on the quarter size luma, the block against the frame before. a little cost per pixel of move, so flat areas
// say still. out (r16f, 13 x 13 a block): the mean difference
constant float kStabBias = 0.25 / 255;
constant int kStabR = 6;
fragment float4 fsStabCoarse(V in [[stage_in]], texture2d<float> qn [[texture(0)]], texture2d<float> qp [[texture(1)]]) {
    int2 g = int2(in.pos.xy), b = g / 13, v = g % 13 - kStabR, mq = int2(qn.get_width(), qn.get_height()) - 1;
    float e = 0;
    for (int j = 0; j < 4; j++)
        for (int i = 0; i < 4; i++) {
            int2 o = b * 4 + int2(i, j);
            e += abs(qn.read(uint2(clamp(o, 0, mq))).r - qp.read(uint2(clamp(o + v, 0, mq))).r);
        }
    return float4(e / 16 + kStabBias * 4 * (abs(v.x) + abs(v.y)), 0, 0, 1);
}
// a block's best coarse move. out: x, y + 128 in 255ths (quarter pixels)
fragment float4 fsStabCoarsePick(V in [[stage_in]], texture2d<float> co [[texture(0)]]) {
    int2 b = int2(in.pos.xy), v = 0;
    float best = 1e9;
    for (int y = 0; y < 13; y++)
        for (int x = 0; x < 13; x++) {
            float e = co.read(uint2(b * 13 + int2(x, y))).r;
            if (e < best) { best = e; v = int2(x, y) - kStabR; }
        }
    return float4((float2(v) + 128) / 255, 0, 1);
}
// fine: +-2 px around four times that, or no move at all, on full size against the result before, on an eighth of
// the block's pixels, staggered. out (rgba16f, 6 x 5 a block, 26 used): difference, move x, y
fragment float4 fsStabFine(V in [[stage_in]], texture2d<float> cv [[texture(0)]], texture2d<float> t [[texture(1)]], texture2d<float> h [[texture(2)]]) {
    int2 g = int2(in.pos.xy), b = g / int2(6, 5), k = g % int2(6, 5), m = int2(t.get_width(), t.get_height()) - 1;
    if (k.x == 5 && k.y > 0) return float4(1e4, 0, 0, 1);
    int2 v = int2(round(cv.read(uint2(b)).rg * 255)) - 128, u = k.x == 5 ? int2(0) : v * 4 + k - 2;
    float e = 0;
    for (int j = 0; j < 8; j++)
        for (int i = 0; i < 4; i++) {
            int2 p = b * 16 + int2(4 * i + (j & 3), 2 * j);
            e += abs(yOf(t.read(uint2(clamp(p, 0, m))).rgb) - yOf(h.read(uint2(clamp(p + u, 0, m))).rgb));
        }
    return float4(e / 32 + kStabBias * (abs(u.x) + abs(u.y)), float2(u), 1);
}
// a block's move: the best of its 26. out: move x, y + 128 in 255ths, what was left of the difference (x8)
fragment float4 fsStabPick(V in [[stage_in]], texture2d<float> f [[texture(0)]]) {
    int2 b = int2(in.pos.xy);
    float4 best = float4(1e9, 0, 0, 0);
    for (int y = 0; y < 5; y++)
        for (int x = 0; x < 6; x++) {
            float4 c = f.read(uint2(b * int2(6, 5) + int2(x, y)));
            if (c.x < best.x) best = c;
        }
    return float4((best.yz + 128) / 255, saturate(best.x * 8), 1);
}
// per pixel: the move of its block, of the nearest blocks across, down and diagonally, or none, whichever fits the
// pixel and its four neighbours best. amount: the most the frame before may have, 0 = no history (copy)
constant float kStabFit = 0.2;  // the pixel and its four neighbours may differ by this much of the 3x3's range (or 3 levels) and the move counts as right, none from twice that
constant float kStabCut = 3.0 / 255, kStabCutAll = 10.0 / 255; // the hold cuts this much off: less weight, none
fragment float4 fsStab(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> h [[texture(1)]], texture2d<float> mv [[texture(2)]],
                       constant U &u [[buffer(0)]]) {
    int2 p = int2(in.pos.xy), m = int2(t.get_width(), t.get_height()) - 1;
    float3 c[9], mn = 1, mx = 0;
    float y[9], ylo = 1, yhi = 0;
    for (int k = 0; k < 9; k++) {
        c[k] = t.read(uint2(clamp(p + int2(k % 3 - 1, k / 3 - 1), 0, m))).rgb;
        y[k] = yOf(c[k]);
        mn = min(mn, c[k]); mx = max(mx, c[k]); ylo = min(ylo, y[k]); yhi = max(yhi, y[k]);
    }
    if (u.amount <= 0) return float4(c[4], 1);
    int2 bb = p / 16, side = select(int2(-1), int2(1), p % 16 >= 8), mb = int2(mv.get_width(), mv.get_height()) - 1;
    int2 cand[5] = {int2(0), bb, bb + int2(side.x, 0), bb + int2(0, side.y), bb + side};
    float best = 1e9;
    int2 v = 0;
    for (int n = 0; n < 5; n++) {
        int2 d = n ? int2(round(mv.read(uint2(clamp(cand[n], 0, mb))).rg * 255)) - 128 : int2(0);
        float e = 0;
        for (int k = 1; k < 9; k += 2) e += abs(y[k] - yOf(h.read(uint2(clamp(p + d + int2(k % 3 - 1, k / 3 - 1), 0, m))).rgb));
        e += abs(y[4] - yOf(h.read(uint2(clamp(p + d, 0, m))).rgb));
        if (e < best) { best = e; v = d; }
    }
    int2 q = p + v;
    if (any(q < 0) || any(q > m)) return float4(c[4], 1); // came in from outside the picture
    float3 o = h.read(uint2(q)).rgb, oc = clamp(o, mn, mx), cut = abs(o - oc);
    float fit = 1 - smoothstep(1.0, 2.0, best / 5 / max(3.0 / 255, kStabFit * (yhi - ylo)));
    float w = u.amount * fit * (1 - smoothstep(kStabCut, kStabCutAll, max(cut.r, max(cut.g, cut.b))));
    return float4(mix(c[4], oc, w), 1);
}
)M";
}
