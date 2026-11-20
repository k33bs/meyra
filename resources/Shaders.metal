// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
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
struct L { float full; float still; float stillTol; float pad; };

// bt.709 yuv -> gamma rgb
static float3 toRgb(float y, float cb, float cr, float full) {
    if (full > 0.5) {
        cb -= 128.0 / 255.0;
        cr -= 128.0 / 255.0;
    } else {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cb = (cb - 128.0 / 255.0) * (255.0 / 224.0);
        cr = (cr - 128.0 / 255.0) * (255.0 / 224.0);
    }
    return saturate(float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb));
}

// bgrg422 view of 2vuy: g = luma, b = cb, r = cr
fragment float4 fsYuv(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv);
    return float4(toRgb(c.g, c.b, c.r, l.full), 1);
}

// two plane 420v: luma in r8, cb cr in rg8 at half size
fragment float4 fsNv(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]], constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 c = tc.sample(s, in.uv).rg;
    return float4(toRgb(ty.sample(s, in.uv).r, c.r, c.g, l.full), 1);
}

// rgb sources. video range rgb gets expanded
// generated frames only. where content slid in from outside the picture the interpolator has nothing to draw from and
// leaves chroma collapsing towards zero, which shows as vivid green (measured 20 to 90 of 255 on both channels).
// both chroma channels very low here or right next to here -> take the real frame's pixel instead.
// a genuinely pure green object also trips this and just gets the real frame's pixel, harmless for anything static.
fragment float4 fsNvFix(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                        texture2d<float> ry [[texture(2)]], texture2d<float> rc [[texture(3)]], texture2d<float> py [[texture(4)]],
                        constant L &l [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler n(filter::nearest, address::clamp_to_edge);
    float2 px = 1.0 / float2(tc.get_width(), tc.get_height());
    float low = 1;
    for (int j = -2; j <= 2; j++)
        for (int i = -2; i <= 2; i++) {
            float2 c = tc.sample(n, in.uv + float2(i, j) * px).rg;
            low = min(low, max(c.r, c.g));
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
    float2 c = bad ? rc.sample(s, in.uv).rg : tc.sample(s, in.uv).rg;
    float y = bad ? ry.sample(s, in.uv).r : ty.sample(s, in.uv).r;
    return float4(toRgb(y, c.r, c.g, l.full), 1);
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

// status overlay, premultiplied alpha
fragment float4 fsHud(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
