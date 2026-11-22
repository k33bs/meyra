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
struct L { float full; float still; float stillTol; float mode; };

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
fragment float4 fsNvFix(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                        texture2d<float> ry [[texture(2)]], texture2d<float> rc [[texture(3)]], texture2d<float> py [[texture(4)]],
                        constant L &l [[buffer(0)]]) {
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
    bool bad = low < 0.36;
    // still areas (hud, anything that did not change between the two real frames): the interpolator softens them and
    // can wobble them, the real pixel is exact. still = both real frames agree on luma here and all around here
    if (l.still > 0.5 && !bad) {
        float2 ly = 1.0 / float2(ry.get_width(), ry.get_height());
        float d = 0;
        for (int j = -2; j <= 2; j += 2)
            for (int i = -2; i <= 2; i += 2) {
                float2 o = in.uv + float2(i, j) * ly;
                d = max(d, abs(ry.sample(n, o).r - py.sample(n, o).r));
            }
        bad = d < l.stillTol;
    }
    float2 cuv = in.uv + float2(kChromaShift / ty.get_width(), 0);
    float2 c = bad ? rc.sample(s, cuv).rg : tc.sample(s, cuv).rg;
    float y = bad ? ry.sample(s, in.uv).r : ty.sample(s, in.uv).r;
    return float4(toRgb(y, c.r, c.g, l.full, isSd(l.mode)), 1);
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

// last pass: plain copy / bilinear scale when amount is 0, otherwise contrast adaptive sharpening on luma only
// (no colour fringes), eased off on isolated noisy pixels so grain is not amplified, and clamped to the
// neighbourhood so it cannot ring
fragment float4 fsOut(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 e = t.sample(s, in.uv).rgb;
    if (u.amount <= 0) return float4(e, 1);
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
    return float4(clamp(e + (lo - le), mn, mx), 1);
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

// status overlay, premultiplied alpha
fragment float4 fsHud(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
