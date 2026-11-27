// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import "canvas.h"
#import "common.h"
#include <cmath>
#include <cstring>
#include <vector>
#include <algorithm>
#include <time.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// side bars, canvas. each side keeps a canvas of the world beside that edge: the picture's columns next to the edge
// are written into it where the world is now, and the bar reads it where the world will be once the picture has moved
// on. so on a pan the bar behind fills with what just left the picture, at the picture's own speed.
// two calls a frame. bars(), in the frame's own buffer: read only, the bars from what the canvas holds, at where the
// motion so far says the picture is now (a step on from the newest frame when one is due). after(), once the frame's
// buffer is committed: the new frame's motion, then its strips into the canvas, in a buffer of its own. so the bars run
// a frame behind the picture's strips; they fade over 1.5 s, a frame does not show.
// motion: once a new frame (told by a hash of its luma, the pool reuses buffers), on the cpu: a 384 px region of
// the source at each edge at a quarter, an eighth and a sixteenth a side; the 256 px strip at the edge matched against
// a held frame (replaced every 64 px or when it no longer fits well), the whole range at a sixteenth (sad), the next
// two levels a step either way (squares), a parabola for the part of a pixel. sure: a clear best against the second
// best, and texture both ways. unsure: the motion goes on as it was. a cut: the strip's mean jumped, or most of it fits
// nowhere: that side starts over, as after 200 ms unsure.
// keep out: the marked hud areas, and blocks of 16 px that stay put while the side moves (a minimap, a counter), grown
// a little through the flat blocks round them: they move with the screen, not the world. the canvas keeps what it had
// there. rows of blocks the side's one motion does not explain (another layer, a zoom) get less weight: the glow there.
// canvas: rgba16f at half the fit, wrapping both ways, in world places (fit px). rgb times alpha, alpha how fresh: one
// on write, less at every write since. a place the window moved onto is cleared, it held another place.
// bars: the canvas at the place, a small blur growing outwards, darkened as the glow is, over the glow by its weight:
// written, fresh, sure, near the seam. render thread only, nothing before the first call, no allocation once running
namespace canvas {

#ifdef CANVAS_TEST
double probe[32]; // numbers for side-test/canvas
bool testRaw;     // side-test/canvas: the bars get the canvas's colour and its weight in alpha, no glow, no dither
#else
static double probe[32]; // written, never read
static const bool testRaw = false;
#endif

static NSString *const kKernels = @R"M(
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; };
vertex V vs(uint vid [[vertex_id]]) {
    float2 p = float2(vid & 1, vid >> 1);
    V o;
    o.pos = float4(p * 2 - 1, 0, 1);
    return o;
}
// the write, over the whole canvas, read and written in place. o: offset x y (fit px), the window's low corner x y.
// p: the window's low corner before, how much fresh is left since the last write, texels a fit px. c: the window's
// size (fit px), fw, fh. s: the strip's columns in the picture [x, y), first block column (fit px), hud areas. b: a
// block's size (fit px), blocks across, down. h: the hud areas, picture parts x y w h. mk: a block kept out, 1
struct CW { float4 o; float4 p; float4 c; float4 s; float4 b; float4 h[8]; };
fragment float4 fsCanvasWrite(V in [[stage_in]], texture2d<float> pic [[texture(0)]], constant CW &u [[buffer(0)]],
                              constant uchar *mk [[buffer(1)]], float4 was [[color(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = u.c.xy, at = in.pos.xy / u.p.w - u.o.zw;
    float2 w = u.o.zw + at - size * floor(at / size); // the place this texel holds now
    float2 r = w - u.p.xy;
    float4 c = all(r >= 0) && all(r < size) ? was * u.p.z : float4(0); // held before: older. else it held another place
    float2 x = w - u.o.xy; // in the picture, fit px
    if (x.x < u.s.x || x.x >= u.s.y || x.y < 0 || x.y >= u.c.w) return c;
    float2 uv = x / u.c.zw;
    for (int i = 0; i < int(u.s.w); i++)
        if (all(uv >= u.h[i].xy) && all(uv < u.h[i].xy + u.h[i].zw)) return c;
    int2 b = int2(floor((x - float2(u.s.z, 0)) / u.b.xy));
    if (all(b >= 0) && b.x < int(u.b.z) && b.y < int(u.b.w) && mk[b.y * int(u.b.z) + b.x]) return c;
    float2 q = 0.5 / u.c.zw; // four taps half a fit px out: the texel's two by two
    float3 p = pic.sample(s, uv + float2(-q.x, -q.y)).rgb + pic.sample(s, uv + float2(q.x, -q.y)).rgb +
               pic.sample(s, uv + float2(-q.x, q.y)).rgb + pic.sample(s, uv + q).rgb;
    return float4(0.25 * p, 1);
}
// the bar. v: the picture's corner in the drawable, fw, fh. o: offset x y, the window's low corner x y. c: the
// window's size, side (-1 left, 1 right), fade distance (fit px). k: weight (sure, fresh), dim, seam step width, the
// picture's smaller side. u: 1 / drawable size, frame number, raw (tests). r: bands a fit px, bands. bd: how well each
// band of rows follows the side's motion
struct CB { float4 v; float4 o; float4 c; float4 k; float4 u; float4 r; };
fragment float4 fsCanvasBars(V in [[stage_in]], texture2d<float> cv [[texture(0)]], texture2d<float> g [[texture(1)]], constant CB &b [[buffer(0)]],
                             constant float *bd [[buffer(1)]]) {
    constexpr sampler sr(filter::linear, address::repeat);
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 x = in.pos.xy - b.v.xy;
    float d = max(b.c.z < 0 ? -x.x : x.x - b.v.z, 0.0); // out from the seam
    float2 w = x + b.o.xy, r = w - b.o.zw, o = (0.5 + 0.006 * d) * float2(1, 1); // the place; blur, a little more outwards
    float4 a = cv.sample(sr, (w + o * float2(-1, -0.33)) / b.c.xy) + cv.sample(sr, (w + o * float2(0.33, -1)) / b.c.xy) +
               cv.sample(sr, (w + o * float2(1, 0.33)) / b.c.xy) + cv.sample(sr, (w + o * float2(-0.33, 1)) / b.c.xy);
    a *= 0.25;
    float wt = all(r >= 0) && all(r < b.c.xy) ? a.a : 0.0;
    float y = clamp(x.y * b.r.x - 0.5, 0.0, b.r.y - 1); // between the two nearest bands
    int i = int(y), j = min(i + 1, int(b.r.y) - 1);
    wt = saturate(wt * b.k.x * (1 - smoothstep(0.3 * b.c.w, b.c.w, d)) * mix(bd[i], bd[j], y - i));
    float3 col = a.rgb / max(a.a, 1e-3);
    if (b.u.w > 0) return float4(saturate(col), wt);
    col = mix(float3(dot(col, float3(0.2126, 0.7152, 0.0722))), col, 0.85); // as the glow: less colour, darker
    col *= mix(0.5 + 0.5 * b.k.y, b.k.y, smoothstep(0.0, b.k.z, d)) * exp(-2 * d / b.k.w);
    float3 c = g.sample(s, in.pos.xy * b.u.xy).rgb;
    if (wt > 0) c = mix(c, col, wt);
    uint2 q = uint2(in.pos.xy); // the bars' dither, as fsSideBars
    uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u ^ uint(b.u.z) * 0xcb1ab31fu;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    float n = (float(h & 0xffffu) + float(h >> 16)) / 65535.0 - 1.0; // -1 .. 1, triangular
    return float4(saturate(c + n / 255), 1);
}
)M";

static const int kRegion = 384, kStrip = 256; // source px at each edge: looked at, matched
static const int kRx = 10, kRy = 6;           // the search at a sixteenth, either way
static const int kPadX[3] = {80, 40, 20}, kPadY[3] = {48, 24, 12}; // room round each level for the moved reads
static const double kHop = 64;                // source px from the held frame before it is replaced
static const int kBlk = 16;                   // keep-out blocks, source px (4 x 4 at a quarter)
static const double kTau = 1.5;               // s, the canvas fades by e in this
static const double kGap = 0.25;              // s between calls: start over
static const double kTexel = 0.5;             // canvas texels a fit px
static const bool kZoomGate = true;           // both sides out or both in (a zoom, walking on): the glow

static double ms() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-6; }

// a level of the luma pyramid, with room round it: valid (255) where it may be matched
struct Level {
    int w = 0, h = 0, px = 0, py = 0, stride = 0;
    std::vector<uint8_t> v, m;
    void make(int w_, int h_, int px_, int py_) {
        w = w_, h = h_, px = px_, py = py_, stride = (w + 2 * px + 15) & ~15;
        v.assign((size_t)stride * (h + 2 * py), 0);
        m.assign(v.size(), 0);
    }
    uint8_t *row(int y) { return v.data() + (size_t)(y + py) * stride + px; }
    uint8_t *mrow(int y) { return m.data() + (size_t)(y + py) * stride + px; }
    const uint8_t *row(int y) const { return v.data() + (size_t)(y + py) * stride + px; }
    const uint8_t *mrow(int y) const { return m.data() + (size_t)(y + py) * stride + px; }
};

struct Side {
    bool right = false;
    int x0 = 0, b0 = 0;           // the region's first source column; the strip's first column in it at a quarter
    Level cur[3], prev[3], ref[3]; // a quarter, an eighth, a sixteenth: this frame, the one before, the held one
    bool have = false;            // prev and ref hold frames
    double refO[2] = {0, 0};      // the held frame's offset (fit px)
    double dRef[2] = {0, 0}, dLast[2] = {0, 0}; // the frame before against the held one, its own motion (source px)
    double v[2] = {0, 0};         // dLast smoothed, jumps on: the step bars() carries the picture on by (a frame's jitters)
    std::vector<uint8_t> hud;     // a quarter: in a marked area
    int bx = 0, by = 0;           // keep-out blocks across, down
    std::vector<int8_t> score;    // per block: + stays put while the side moves, - moves with it
    std::vector<uint8_t> keep;    // per block: kept out
    std::vector<float> band;      // per row of blocks: how well it follows the side's motion, 0..1 (parallax, zoom)
    double o[2] = {0, 0};         // the newest frame's offset (fit px)
    double conf = 0, low = 0;     // sure, smoothed; how long unsure
    int epoch = 0;                // starts over: a new one
    // the canvas
    id<MTLTexture> tex;
    int cw = 0, ch = 0;           // texels
    double size[2] = {0, 0}, lo[2] = {0, 0}; // the window's size, its low corner against the offset (fit px)
    double wo[2] = {0, 0};        // the offset written last
    bool fresh = true;            // nothing written in this epoch yet
    int texEpoch = -1;
    uint64_t written = 0;
    double tWrite = 0;
    double strip = 0;             // fit px written at the edge
    MTLRenderPassDescriptor *rp;  // the write's, kept
    // motion()'s scratch, sized in layout(): per 32 px block (cuts), per keep-out block, per row of them
    std::vector<float> br, bn, ea, eb, en, eg, q;
    std::vector<int> dist;
};

static id<MTLRenderPipelineState> gWrite, gBars;
static MTLRenderPassDescriptor *gBarsRp;
static int gOk;
static Side gSide[2];
static uint64_t gHash;            // the newest frame's
static bool gHashOk;
static double gLast = -1, gNewAt = -1, gIv = 1 / 60.0, gZoom = 0; // last after(), the newest frame's time, between
                                                                   // new frames; gZoom: 0 .. 1, how much a zoom
static double gGeo[14];
static int gW, gH;
static uint32_t gFrame;
static uint64_t gNoMem;

static bool setup(id<MTLDevice> dev) {
    if (gOk) return gOk > 0;
    gOk = -1;
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kKernels options:nil error:&e];
    if (!lib) { logLine("side canvas: shaders did not compile, the glow alone for this session: %s", e.localizedDescription.UTF8String ?: "?"); return false; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsCanvasWrite"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    gWrite = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsCanvasBars"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    gBars = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gWrite || !gBars) { logLine("side canvas: no pipeline, the glow alone for this session"); return false; }
    gOk = 1;
    return true;
}

static void resetSide(Side &s) {
    s.epoch++;
    s.o[0] = s.o[1] = 0;
    s.dRef[0] = s.dRef[1] = s.dLast[0] = s.dLast[1] = s.v[0] = s.v[1] = 0;
    s.conf = s.low = 0;
    std::fill(s.band.begin(), s.band.end(), 1.0f);
}

void reset() {
    for (Side &s : gSide) {
        resetSide(s);
        s.have = false;
        s.fresh = true;
        s.written = 0;
        std::fill(s.score.begin(), s.score.end(), 0);
        std::fill(s.keep.begin(), s.keep.end(), 0);
    }
    gHashOk = false;
    gLast = gNewAt = -1;
    gZoom = 0;
}

// the region's luma at a quarter a side, 4 x 4 means. step 2 (2vuy, yuvs; luma at byte off) or 1 (420v)
static void quarter(Level &L, const uint8_t *base, size_t stride, int step, int off, int x0) {
    for (int y = 0; y < L.h; y++) {
        uint8_t *o = L.row(y);
        const uint8_t *r0 = base + (size_t)(4 * y) * stride + (size_t)x0 * step;
#if defined(__ARM_NEON)
        for (int x = 0; x < L.w; x += 16) { // 64 source px
            uint16x8_t a = vdupq_n_u16(0), b = vdupq_n_u16(0);
            for (int i = 0; i < 4; i++) {
                const uint8_t *q = r0 + i * stride + (size_t)x * 4 * step;
                uint8x16_t l[4];
                if (step == 2)
                    for (int j = 0; j < 4; j++) { uint8x16x2_t t = vld2q_u8(q + 32 * j); l[j] = off ? t.val[1] : t.val[0]; }
                else
                    for (int j = 0; j < 4; j++) l[j] = vld1q_u8(q + 16 * j);
                a = vaddq_u16(a, vpaddq_u16(vpaddlq_u8(l[0]), vpaddlq_u8(l[1])));
                b = vaddq_u16(b, vpaddq_u16(vpaddlq_u8(l[2]), vpaddlq_u8(l[3])));
            }
            vst1q_u8(o + x, vcombine_u8(vrshrn_n_u16(a, 4), vrshrn_n_u16(b, 4)));
        }
#else
        for (int x = 0; x < L.w; x++) {
            unsigned t = 0;
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) t += r0[i * stride + (size_t)(4 * x + j) * step + off];
            o[x] = (uint8_t)((t + 8) >> 4);
        }
#endif
    }
}

// the next level: 2 x 2 means, valid where all four are
static void half(Level &o, const Level &i) {
    for (int y = 0; y < o.h; y++) {
        const uint8_t *a = i.row(2 * y), *b = i.row(2 * y + 1), *ma = i.mrow(2 * y), *mb = i.mrow(2 * y + 1);
        uint8_t *v = o.row(y), *m = o.mrow(y);
        for (int x = 0; x < o.w; x++) {
            v[x] = (uint8_t)((a[2 * x] + a[2 * x + 1] + b[2 * x] + b[2 * x + 1] + 2) >> 2);
            m[x] = std::min(std::min(ma[2 * x], ma[2 * x + 1]), std::min(mb[2 * x], mb[2 * x + 1]));
        }
    }
}

// the strip of c (columns [b0, b0 + bw), a multiple of 16) against p moved by dx, dy: the mean absolute or squared
// difference where both are valid, and over how many
struct Cost { double v; uint32_t n; };
static Cost cost(const Level &c, const Level &p, int b0, int bw, int dx, int dy, bool sq) {
    uint64_t sum = 0, n = 0;
    for (int y = 0; y < c.h; y++) {
        int py = y - dy;
        if (py < -p.py || py >= p.h + p.py) continue;
        const uint8_t *cp = c.row(y) + b0, *cm = c.mrow(y) + b0, *pp = p.row(py) + b0 - dx, *pm = p.mrow(py) + b0 - dx;
#if defined(__ARM_NEON)
        uint32x4_t s = vdupq_n_u32(0);
        uint16x8_t s16 = vdupq_n_u16(0), n16 = vdupq_n_u16(0);
        for (int x = 0; x < bw; x += 16) {
            uint8x16_t m = vandq_u8(vld1q_u8(cm + x), vld1q_u8(pm + x));
            uint8x16_t d = vandq_u8(vabdq_u8(vld1q_u8(cp + x), vld1q_u8(pp + x)), m);
            if (sq) {
                s = vpadalq_u16(s, vmull_u8(vget_low_u8(d), vget_low_u8(d)));
                s = vpadalq_u16(s, vmull_high_u8(d, d));
            } else s16 = vpadalq_u8(s16, d);
            n16 = vpadalq_u8(n16, vshrq_n_u8(m, 7));
        }
        s = vpadalq_u16(s, s16);
        sum += vaddvq_u32(s);
        n += vaddvq_u16(n16);
#else
        for (int x = 0; x < bw; x++)
            if (cm[x] && pm[x]) { int d = cp[x] - pp[x]; sum += sq ? d * d : abs(d); n++; }
#endif
    }
    return {n ? (double)sum / n : 1e30, (uint32_t)n};
}

// one side's motion: the strip against the held frame (D, source px; the search starts where the last one was plus
// the last frame's motion) and since the frame before (f), how sure, a cut. the keep-out blocks follow. against a held
// frame, not the one before: the parabola on 4 x 4 means is up to a quarter px off at some parts of a pixel, and summed
// frame by frame that walked the bar 16 px off in 160 frames. this way it adds up once a hop (kHop px)
static void motion(Side &s, double D[2], double f[2], double &sure, bool &cut, double &ratio, double &texture, double a) {
    D[0] = D[1] = f[0] = f[1] = 0; sure = 0; cut = false; ratio = 1; texture = 0;
    const int bw[3] = {kStrip / 4, kStrip / 8, kStrip / 16};
    int b0[3] = {s.b0, s.b0 / 2, s.b0 / 4};
    uint32_t full = 0;
    for (int y = 0; y < s.cur[2].h; y++)
        for (int x = 0; x < bw[2]; x++) full += s.cur[2].mrow(y)[b0[2] + x] != 0;
    if (full < 32) return;
    // a sixteenth: the whole range, the best and the best not next to it
    int cx = std::clamp((int)lround((s.dRef[0] + s.dLast[0]) / 16), -8, 8), cy = std::clamp((int)lround((s.dRef[1] + s.dLast[1]) / 16), -4, 4);
    double best = 1e30, second = 1e30;
    int bx = cx, by = cy;
    static double c4[2 * kRy + 1][2 * kRx + 1];
    for (int j = -kRy; j <= kRy; j++)
        for (int i = -kRx; i <= kRx; i++) {
            Cost c = cost(s.cur[2], s.ref[2], b0[2], bw[2], cx + i, cy + j, false);
            double &v = c4[j + kRy][i + kRx];
            v = c.n * 10 >= full * 4 ? c.v : 1e30; // most of the strip still there
            if (v < best) best = v, bx = cx + i, by = cy + j;
        }
    for (int j = -kRy; j <= kRy; j++)
        for (int i = -kRx; i <= kRx; i++)
            if ((abs(cx + i - bx) > 1 || abs(cy + j - by) > 1) && c4[j + kRy][i + kRx] < second) second = c4[j + kRy][i + kRx];
    if (best >= 1e29) { cut = true; return; }
    ratio = (best + 0.5) / (second + 0.5);
    // an eighth, then a quarter: a step either way, squares
    double cq[3][3] = {};
    for (int l = 1; l >= 0; l--) {
        bx *= 2, by *= 2;
        for (int k = 0; k < 2; k++) { // at a quarter once more if the best was at the side
            double b = 1e30; int nx = bx, ny = by;
            for (int j = -1; j <= 1; j++)
                for (int i = -1; i <= 1; i++) {
                    Cost c = cost(s.cur[l], s.ref[l], b0[l], bw[l], bx + i, by + j, true);
                    cq[j + 1][i + 1] = c.v;
                    if (c.v < b) b = c.v, nx = bx + i, ny = by + j;
                }
            bool moved = nx != bx || ny != by;
            bx = nx, by = ny;
            if (l || !moved) break;
            if (k == 1) { // once more around the new best, for the parabola
                for (int j = -1; j <= 1; j++)
                    for (int i = -1; i <= 1; i++) cq[j + 1][i + 1] = cost(s.cur[0], s.ref[0], b0[0], bw[0], bx + i, by + j, true).v;
            }
        }
    }
    if (cq[1][1] >= 1e29) { cut = true; return; }
    if (abs(bx) > s.cur[0].px - 2 || abs(by) > s.cur[0].py - 2) { cut = true; return; }
    auto para = [](double a, double b, double c) { double k = a - 2 * b + c; return k > 1e-9 ? std::clamp(0.5 * (a - c) / k, -0.5, 0.5) : 0.0; };
    D[0] = 4 * (bx + (cq[1][0] < 1e29 && cq[1][2] < 1e29 ? para(cq[1][0], cq[1][1], cq[1][2]) : 0));
    D[1] = 4 * (by + (cq[0][1] < 1e29 && cq[2][1] < 1e29 ? para(cq[0][1], cq[1][1], cq[2][1]) : 0));
    f[0] = D[0] - s.dRef[0], f[1] = D[1] - s.dRef[1];
    double sx = f[0] / 4, sy = f[1] / 4; // since the frame before, at a quarter
    // at a quarter, over the strip: texture both ways, the means, the fit in blocks of 32 px (a cut: most fit
    // nowhere), and per keep-out block the fit standing still against the fit moved (bilinear)
    const Level &c = s.cur[0], &p = s.prev[0];
    int ix = (int)floor(sx), iy = (int)floor(sy), rx = (int)lround(sx), ry = (int)lround(sy);
    float fx = (float)(sx - ix), fy = (float)(sy - iy);
    int cbx = bw[0] / 8;
    std::vector<float> &br = s.br, &bn = s.bn, &ea = s.ea, &eb = s.eb, &en = s.en, &eg = s.eg;
    for (auto *v : {&br, &bn, &ea, &eb, &en, &eg}) std::fill(v->begin(), v->end(), 0.0f);
    double gx = 0, gy = 0, mc = 0, mp = 0; long ng = 0, nm = 0;
    for (int y = 0; y < c.h; y++) {
        const uint8_t *cr = c.row(y) + s.b0, *hr = s.hud.data() + (size_t)y * c.w + s.b0;
        for (int x = 0; x < bw[0]; x++) {
            if (hr[x]) continue;
            int v = cr[x], X = s.b0 + x;
            if (x + 1 < bw[0] && y + 1 < c.h && !hr[x + 1]) {
                int a = abs(cr[x + 1] - v), b = abs(c.row(y + 1)[s.b0 + x] - v);
                gx += a, gy += b, ng++;
                eg[(y / 4) * s.bx + x / 4] += a + b;
            }
            int qx = X - rx, qy = y - ry;
            if (qx >= 0 && qx < p.w && qy >= 0 && qy < p.h) {
                int k = (y / 8) * cbx + x / 8;
                br[k] += abs(v - p.row(qy)[qx]), bn[k]++;
            }
            mc += v, mp += p.row(y)[X], nm++;
            int ax = X - ix - 1, ay = y - iy - 1; // the moved read: x - sx = ax + (1 - fx)
            if (ax >= 0 && ax + 1 < p.w && ay >= 0 && ay + 1 < p.h) {
                const uint8_t *p0 = p.row(ay) + ax, *p1 = p.row(ay + 1) + ax;
                float m = (p0[0] * fx + p0[1] * (1 - fx)) * fy + (p1[0] * fx + p1[1] * (1 - fx)) * (1 - fy);
                int k = (y / 4) * s.bx + x / 4;
                ea[k] += abs(v - p.row(y)[X]), eb[k] += fabsf(v - m), en[k]++;
            }
        }
    }
    if (ng < 64 || nm < 64) { cut = false; return; }
    gx /= ng, gy /= ng;
    texture = std::min(gx, gy);
    int bad = 0, all = 0;
    for (size_t k = 0; k < br.size(); k++)
        if (bn[k] >= 32) all++, bad += br[k] / bn[k] > 18;
    if (fabs(mc - mp) / nm > 28 || (all >= 8 && bad * 10 >= all * 6)) { cut = true; return; }
    sure = std::clamp((0.85 - ratio) / 0.35, 0.0, 1.0) * std::clamp((texture - 0.8) / 1.5, 0.0, 1.0);
    // keep out: evidence only while the side clearly moves and the motion is believed. stays put: unchanged within
    // noise (a hud from the card is the same pixels again), while the moved frame before fits much worse. slow far
    // things in a forward motion change a little: not taken for a hud
    double ta = 0, tn = 0;
    for (int k = 0; k < s.bx * s.by; k++) ta += ea[k], tn += en[k];
    if (sure > 0.3 && hypot(sx, sy) >= 0.4 && ta > 4 * tn) // 1.6 source px a frame, and the strip as a whole changed
        for (int k = 0; k < s.bx * s.by; k++) {
            if (en[k] < 8) continue;
            float A = ea[k] / en[k], B = eb[k] / en[k];
            if (A < 2.5f && B > 3 * A + 3 && eg[k] > 4 * en[k]) s.score[k] = (int8_t)std::min(s.score[k] + 1, 6); // textured only
            else if (A > 2 * B + 2 && A > 3) s.score[k] = (int8_t)std::max(s.score[k] - 2, -4);
            else if (A > 8) s.score[k] = (int8_t)std::max(s.score[k] - 1, -4); // changed: not an overlay now
        }
    // blocks that stay put, grown up to 3 blocks through flat ones that never moved with the side (inside a panel)
    std::vector<int> &dist = s.dist;
    for (int k = 0; k < s.bx * s.by; k++) dist[k] = s.score[k] >= 3 ? 0 : 99;
    auto pass = [&](int k, int n) { if (s.score[k] > -2 && en[k] > 0 && eg[k] < 3 * en[k] && dist[n] + 1 < dist[k]) dist[k] = dist[n] + 1; };
    for (int y = 0; y < s.by; y++)
        for (int x = 0; x < s.bx; x++) {
            int k = y * s.bx + x;
            if (x) pass(k, k - 1);
            if (y) { pass(k, k - s.bx); if (x) pass(k, k - s.bx - 1); if (x + 1 < s.bx) pass(k, k - s.bx + 1); }
        }
    for (int y = s.by - 1; y >= 0; y--)
        for (int x = s.bx - 1; x >= 0; x--) {
            int k = y * s.bx + x;
            if (x + 1 < s.bx) pass(k, k + 1);
            if (y + 1 < s.by) { pass(k, k + s.bx); if (x + 1 < s.bx) pass(k, k + s.bx + 1); if (x) pass(k, k + s.bx - 1); }
        }
    int kept = 0;
    for (int k = 0; k < s.bx * s.by; k++) kept += s.keep[k] = dist[k] <= 3;
    probe[s.right ? 21 : 20] = kept;
    // rows that follow the motion: per row of blocks, the share where the moved frame before fits the strip well (or
    // nothing changed), not counting kept-out blocks. only while the side moves; smoothed, and over three rows
    if (sure > 0.3 && hypot(sx, sy) >= 0.4) {
        std::vector<float> &q = s.q;
        for (int y = 0; y < s.by; y++) {
            int n = 0, fit = 0;
            for (int x = 0; x < s.bx; x++) {
                int k = y * s.bx + x;
                if (en[k] < 8 || s.keep[k]) continue;
                float A = ea[k] / en[k], B = eb[k] / en[k];
                n++, fit += B <= std::max(4.0f, 0.6f * A);
            }
            q[y] = n ? std::clamp(((float)fit / n - 0.4f) / 0.4f, 0.0f, 1.0f) : s.band[y];
        }
        for (int y = 0; y < s.by; y++) {
            float m = std::min(q[y], std::max(y ? q[y - 1] : q[y], y + 1 < s.by ? q[y + 1] : q[y]));
            s.band[y] += (float)((m - s.band[y]) * a);
        }
    }
    double bm = 0;
    for (float v : s.band) bm += v;
    probe[s.right ? 23 : 22] = s.band.empty() ? 1 : bm / s.band.size();
}

// the pyramid of this frame for one side: luma at a quarter, valid where not marked and not kept out, the rest
static void pyramid(Side &s, const uint8_t *base, size_t stride, int step, int off, int W, int H) {
    Level &q = s.cur[0];
    quarter(q, base, stride, step, off, s.x0);
    std::fill(s.hud.begin(), s.hud.end(), 0);
    for (int i = 0, n = std::min((int)gSet.hudN, 8); i < n; i++) { // the marked areas, a quarter px more round them
        double x = gSet.hudRect[4 * i] * W, y = gSet.hudRect[4 * i + 1] * H, w = gSet.hudRect[4 * i + 2] * W, h = gSet.hudRect[4 * i + 3] * H;
        int a = std::max(0, (int)floor((x - s.x0) / 4) - 1), b = std::min(q.w, (int)ceil((x + w - s.x0) / 4) + 1);
        int t = std::max(0, (int)floor(y / 4) - 1), u = std::min(q.h, (int)ceil((y + h) / 4) + 1);
        for (int r = t; r < u; r++)
            for (int c = a; c < b; c++) s.hud[(size_t)r * q.w + c] = 1;
    }
    for (int y = 0; y < q.h; y++) {
        uint8_t *m = q.mrow(y);
        for (int x = 0; x < q.w; x++) {
            int bx = (x - s.b0) / 4, by = y / 4;
            bool kept = x >= s.b0 && bx < s.bx && s.keep[by * s.bx + bx];
            m[x] = s.hud[(size_t)y * q.w + x] || kept ? 0 : 255;
        }
    }
    half(s.cur[1], s.cur[0]);
    half(s.cur[2], s.cur[1]);
}

static uint64_t hashOf(const uint8_t *base, size_t stride, int step, int off, int W, int H) {
    uint64_t h = 1469598103934665603ull ^ ((uint64_t)W << 32 | (uint64_t)H);
    for (int j = 0; j < 36; j++) {
        const uint8_t *r = base + (size_t)((j * 2 + 1) * H / 72) * stride;
        for (int i = 0; i < 64; i++) {
            h ^= r[(size_t)((i * 2 + 1) * W / 128) * step + off];
            h *= 1099511628211ull;
        }
    }
    return h;
}

// sizes: the levels, the blocks, each canvas. false: no memory
static bool layout(id<MTLDevice> dev, int W, int H, MTLViewport vp, MTLViewport bar[2]) {
    double sx = vp.width / W, sy = vp.height / H;
    for (int i = 0; i < 2; i++) {
        Side &s = gSide[i];
        s.right = i == 1;
        s.x0 = s.right ? W - kRegion : 0;
        s.b0 = s.right ? (kRegion - kStrip) / 4 : 0;
        for (int l = 0; l < 3; l++) {
            int w = kRegion >> (2 + l), h = H >> (2 + l);
            s.cur[l].make(w, h, kPadX[l], kPadY[l]);
            s.prev[l].make(w, h, kPadX[l], kPadY[l]);
            s.ref[l].make(w, h, kPadX[l], kPadY[l]);
        }
        s.hud.assign((size_t)s.cur[0].w * s.cur[0].h, 0);
        s.bx = kStrip / kBlk, s.by = (s.cur[0].h + 3) / 4;
        s.score.assign(s.bx * s.by, 0);
        s.keep.assign(s.bx * s.by, 0);
        s.band.assign(s.by, 1.0f);
        int nb = (kStrip / 32) * ((s.cur[0].h + 7) / 8), nk = s.bx * s.by;
        for (auto *v : {&s.br, &s.bn}) v->assign(nb, 0);
        for (auto *v : {&s.ea, &s.eb, &s.en, &s.eg}) v->assign(nk, 0);
        s.q.assign(s.by, 1.0f);
        s.dist.assign(nk, 0);
        s.have = false;
        s.fresh = true;
        s.written = 0;
        s.tex = nil;
        if (bar[i].width < 1 || bar[i].height < 1) continue;
        // the window: the bar, the strip, room either way for a frame's motion
        s.strip = kStrip * sx;
        double mx = (16 * kRx + 24) * sx + 8, my = (16 * kRy + 16) * sy + 8;
        double wx = bar[i].width + s.strip + 2 * mx, wy = bar[i].height + 2 * my;
        s.cw = (int)ceil(wx * kTexel), s.ch = (int)ceil(wy * kTexel);
        s.size[0] = s.cw / kTexel, s.size[1] = s.ch / kTexel;
        s.lo[0] = s.right ? vp.width - s.strip - mx : -bar[i].width - mx;
        s.lo[1] = bar[i].originY - vp.originY - my;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:s.cw height:s.ch mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        s.tex = [dev newTextureWithDescriptor:d];
        if (!s.tex) return false;
    }
    return true;
}

// a pass on t, its descriptor kept in rp (made once)
static id<MTLRenderCommandEncoder> open(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *__strong &rp, id<MTLTexture> t, MTLLoadAction load,
                                        void (^mark)(MTLRenderPassDescriptor *)) {
    if (!rp) rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = load;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (mark) mark(rp);
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    rp.colorAttachments[0].texture = nil; // not held past the pass
    return e;
}

// pic's strip into the side's canvas at the offset o
static void write(id<MTLCommandBuffer> cb, Side &s, id<MTLTexture> pic, const double o[2], double now, MTLViewport vp, int W, int H) {
    bool clear = s.fresh || s.texEpoch != s.epoch;
    double lo[2], base[2], plo[2];
    for (int a = 0; a < 2; a++) {
        lo[a] = o[a] + s.lo[a];
        base[a] = floor(lo[a] / s.size[a]) * s.size[a]; // small numbers for the gpu: whole windows off, the same place
        plo[a] = clear ? lo[a] : s.wo[a] + s.lo[a];
    }
    double sx = vp.width / W, sy = vp.height / H;
    float u[52] = {(float)(o[0] - base[0]), (float)(o[1] - base[1]), (float)(lo[0] - base[0]), (float)(lo[1] - base[1]),
                   (float)(plo[0] - base[0]), (float)(plo[1] - base[1]), clear ? 0 : (float)exp(-(now - s.tWrite) / kTau), (float)kTexel,
                   (float)s.size[0], (float)s.size[1], (float)vp.width, (float)vp.height,
                   s.right ? (float)(vp.width - s.strip) : 0, s.right ? (float)vp.width : (float)s.strip, s.right ? (float)((W - kStrip) * sx) : 0, 0,
                   (float)(kBlk * sx), (float)(kBlk * sy), (float)s.bx, (float)s.by};
    int n = 0;
    for (int i = 0, k = std::min((int)gSet.hudN, 8); i < k; i++, n++)
        for (int j = 0; j < 4; j++) u[20 + 4 * n + j] = gSet.hudRect[4 * i + j];
    u[15] = (float)n;
    static const uint8_t none[16] = {};
    const uint8_t *mk = s.keep.data();
    size_t mn = s.keep.size();
    if (!mn || mn > 4096) mk = none, mn = sizeof none, u[18] = u[19] = 0; // too many to pass: none kept out in the write
    id<MTLRenderCommandEncoder> e = open(cb, s.rp, s.tex, clear ? MTLLoadActionClear : MTLLoadActionLoad, nil);
    [e setRenderPipelineState:gWrite];
    [e setViewport:(MTLViewport){0, 0, (double)s.cw, (double)s.ch, 0, 1}];
    [e setFragmentBytes:u length:sizeof u atIndex:0];
    [e setFragmentBytes:mk length:mn atIndex:1];
    [e setFragmentTexture:pic atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
    s.fresh = false;
    s.texEpoch = s.epoch;
    s.wo[0] = o[0], s.wo[1] = o[1];
    s.tWrite = now;
}

void after(id<MTLCommandBuffer> cb, id<MTLTexture> pic, CVPixelBufferRef frame, bool real, MTLViewport vp, MTLViewport left, MTLViewport right) {
    if (!cb || !frame || !pic) return;
    MTLViewport bar[2] = {left, right};
    if ((left.width < 1 || left.height < 1) && (right.width < 1 || right.height < 1)) return;
    double t0 = ms(), now = nowSec();
    probe[0]++;
    if (gLast >= 0 && (now - gLast > kGap || now < gLast)) reset(); // a pause, another source: from the start
    gLast = now;
    OSType f = CVPixelBufferGetPixelFormatType(frame);
    bool planar = f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!planar && f != kCVPixelFormatType_422YpCbCr8 && f != kCVPixelFormatType_422YpCbCr8_yuvs) return;
    int W = (int)CVPixelBufferGetWidth(frame), H = (int)CVPixelBufferGetHeight(frame);
    if (W < 2 * kRegion || H < 256 || vp.width < 64 || vp.height < 64) return;
    if (!setup(cb.device)) return;
    double geo[14] = {(double)W, (double)H, vp.originX, vp.originY, vp.width, vp.height, left.originX, left.originY, left.width, left.height,
                      right.originX, right.originY, right.width, right.height};
    uint64_t key = (uint64_t)W << 48 ^ (uint64_t)H << 32 ^ (uint64_t)vp.width << 16 ^ (uint64_t)(left.width + right.width);
    if (memcmp(geo, gGeo, sizeof geo)) { // another size: everything anew
        if (key == gNoMem) return;
        reset();
        gLast = now;
        memcpy(gGeo, geo, sizeof geo);
        gW = W, gH = H;
        if (!layout(cb.device, W, H, vp, bar)) {
            gNoMem = key;
            memset(gGeo, 0, sizeof gGeo);
            logLine("side canvas: no memory for %.0fx%.0f, the glow alone at this size", vp.width, vp.height);
            return;
        }
    }
    // the frame: the newest again (a repeat), or new: its motion
    if (CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    const uint8_t *base = (const uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(frame, 0) : CVPixelBufferGetBaseAddress(frame));
    size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, 0) : CVPixelBufferGetBytesPerRow(frame);
    int step = planar ? 1 : 2, off = f == kCVPixelFormatType_422YpCbCr8 ? 1 : 0;
    if (!base) { CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly); return; }
    uint64_t h = hashOf(base, stride, step, off, W, H);
    if (!gHashOk || h != gHash) {
        double dt = gNewAt >= 0 ? now - gNewAt : 0;
        if (gNewAt >= 0) gIv += (std::clamp(dt, 1 / 250.0, 0.1) - gIv) * 0.2;
        gNewAt = now, gHash = h, gHashOk = true;
        double a = 1 - exp(-std::clamp(dt, 0.0, 0.1) / 0.1); // 100 ms smoothing
        for (int i = 0; i < 2; i++) {
            Side &s = gSide[i];
            pyramid(s, base, stride, step, off, W, H);
            double D[2] = {0, 0}, d[2] = {0, 0}, sure = 0, ratio = 1, tex = 0;
            bool cut = false, hold = !s.have; // hold: this frame becomes the held one
            if (s.have) motion(s, D, d, sure, cut, ratio, tex, a);
            if (cut) { resetSide(s); probe[i ? 12 : 11]++; hold = true; }
            else if (s.have) {
                s.conf += (sure - s.conf) * a;
                s.low = sure < 0.25 ? s.low + dt : 0;
                if (s.low > 0.2) { resetSide(s); probe[15]++; hold = true; } // unsure too long: the canvas would drift
                else {
                    if (sure < 0.3) // unsure: the motion goes on as it was (the estimate then is often far off)
                        for (int k = 0; k < 2; k++) d[k] = s.dLast[k], D[k] = s.dRef[k] + d[k];
                    s.o[0] = s.refO[0] - D[0] * vp.width / W, s.o[1] = s.refO[1] - D[1] * vp.height / H;
                    s.dLast[0] = d[0], s.dLast[1] = d[1];
                    for (int k = 0; k < 2; k++) s.v[k] = fabs(d[k] - s.v[k]) > 1.5 ? d[k] : s.v[k] + (d[k] - s.v[k]) * a; // a real change at once
                    s.dRef[0] = D[0], s.dRef[1] = D[1];
                    hold = hypot(D[0], D[1]) > kHop || ratio > 0.6; // far from the held frame, or no longer clearly like it
                }
            }
            if (hold) {
                for (int l = 0; l < 3; l++) s.ref[l] = s.cur[l]; // same sizes: no allocation
                s.refO[0] = s.o[0], s.refO[1] = s.o[1];
                s.dRef[0] = s.dRef[1] = 0;
            }
            for (int l = 0; l < 3; l++) std::swap(s.cur[l], s.prev[l]);
            s.have = true;
            double *pr = probe + (i ? 8 : 5);
            pr[0] = d[0], pr[1] = d[1], pr[2] = sure;
            probe[i ? 18 : 16] = ratio, probe[i ? 19 : 17] = tex, probe[i ? 14 : 13] = s.conf;
        }
        // a zoom: the sides move apart or together, more than half a fit px a frame. one motion per side cannot follow
        // that (the bar would show the world misplaced), so both fade to the glow, smoothed over 100 ms
        double zl = gSide[0].dLast[0] * vp.width / W, zr = gSide[1].dLast[0] * vp.width / W;
        double z = std::max(std::min(-zl, zr), std::min(zl, -zr));
        gZoom += ((kZoomGate && z > 0.5 ? 1.0 : 0.0) - gZoom) * a;
        probe[24] = gZoom;
        probe[1]++;
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        probe[3] = ms() - t0;
    } else {
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        probe[4] = ms() - t0;
    }
    // the write: real pictures only, once a frame
    for (int i = 0; i < 2; i++) {
        Side &s = gSide[i];
        if (!s.tex || !real || (s.written == h && s.texEpoch == s.epoch && !s.fresh)) continue;
        write(cb, s, pic, s.o, now, vp, W, H);
        s.written = h;
        probe[2]++;
    }
}

bool bars(id<MTLCommandBuffer> cb, id<MTLTexture> dst, MTLViewport vp, MTLViewport left, MTLViewport right, id<MTLTexture> glow, float dim,
          void (^mark)(MTLRenderPassDescriptor *)) {
    if (gOk <= 0 || !cb || !dst || !glow) return false;
    MTLViewport bar[2] = {left, right};
    if ((left.width < 1 || left.height < 1) && (right.width < 1 || right.height < 1)) return false;
    double geo[12] = {vp.originX, vp.originY, vp.width, vp.height, left.originX, left.originY, left.width, left.height,
                      right.originX, right.originY, right.width, right.height};
    if (memcmp(geo, gGeo + 2, sizeof geo)) return false; // not laid out for this yet: after() does it
    double now = nowSec();
    if (gLast < 0 || now - gLast > kGap || now < gLast) return false; // after() starts over
    probe[25]++;
    // the picture now: the newest frame, or a step on when the next one is due (two at most). a repeat between frames
    // (30 on 60) stays where it is
    double r = gIv > 0 ? (now - gNewAt) / gIv : 0, steps = r < 0.7 ? 0 : std::min(floor(r + 0.3), 2.0);
    id<MTLRenderCommandEncoder> enc = open(cb, gBarsRp, dst, MTLLoadActionLoad, mark);
    [enc setRenderPipelineState:gBars];
    [enc setFragmentTexture:glow atIndex:1];
    float frameNo = (float)(gFrame++ & 1023);
    for (int i = 0; i < 2; i++) {
        Side &s = gSide[i];
        MTLViewport v = bar[i];
        if (v.width < 1 || v.height < 1) continue;
        double o[2], lo[2], base[2];
        bool live = s.tex && !s.fresh && s.texEpoch == s.epoch;
        for (int a = 0; a < 2; a++) {
            o[a] = s.o[a] - steps * s.v[a] * (a ? vp.height / gH : vp.width / gW);
            lo[a] = s.wo[a] + s.lo[a];
            base[a] = s.size[a] > 0 ? floor(lo[a] / s.size[a]) * s.size[a] : 0;
        }
        double wt = live ? s.conf * exp(-(now - s.tWrite) / kTau) * (1 - gZoom) : 0;
        float b[24] = {(float)vp.originX, (float)vp.originY, (float)vp.width, (float)vp.height,
                       (float)(o[0] - base[0]), (float)(o[1] - base[1]), (float)(lo[0] - base[0]), (float)(lo[1] - base[1]),
                       (float)fmax(s.size[0], 1), (float)fmax(s.size[1], 1), i ? 1.0f : -1.0f, (float)(0.25 * vp.width),
                       (float)wt, dim, 0.03f * (float)fmin(vp.width, vp.height), (float)fmin(vp.width, vp.height),
                       (float)(1.0 / dst.width), (float)(1.0 / dst.height), frameNo, testRaw ? 1.0f : 0.0f,
                       (float)(gH / vp.height / kBlk), (float)s.band.size(), 0, 0};
        [enc setViewport:v];
        [enc setFragmentBytes:b length:sizeof b atIndex:0];
        [enc setFragmentBytes:s.band.data() length:s.band.size() * sizeof(float) atIndex:1];
        [enc setFragmentTexture:s.tex ?: glow atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [enc endEncoding];
    return true;
}

}
