// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import "sidefill.h"
#import "common.h"
#import "letterbox.h"
#import "canvas.h"
#include <cmath>
#include <cstring>

// side bars. grey (sideFill 1): one flat dark grey, its level from sideDim. glow (2): a copy of the picture going up at
// a sixteenth a side (rgba16f) is kept as a running mean over time (sideSmooth, so a flash or flicker at the edge does
// not strobe in the bar, a cut comes through whole after 125 ms) and its mips are the blur. a bar pixel
// takes the colour of the nearest point of the picture's edge, blurred more and darker the further out it is
// (sideBlur, sideDim), carried straight out: mirrored, a pan would run the other way in the bar. a short soft step at
// the seam instead of a line, a little less colour, and a dither of one level, else the dark gradients band on a
// bgra8 drawable. the shaders are compiled the first time the bars are wanted, never with them off
namespace sidefill {

static NSString *const kKernels = @R"M(
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
// the small copy: 4 x 4 bilinear taps over the part of the picture one texel covers, into two running means read and
// written in place: slow (sideSmooth, the one the bars are drawn from) and fast (25 ms). a texel the picture jumped
// away from in one frame is marked, and the fast one's alpha counts how long it has stayed away from the slow one
// (0.01 + seconds, small for the half float's sake; 0 not marked). back near it (a flash over) or away for long
// without a cut: not marked any more. the slow one's alpha says marked, and its smallest mip, copied to n, is how much
// of the picture that is, a frame ago. while that is most of it the slow one holds still on marked texels, so it still
// knows the picture from before the jump. marked for k.y (125 ms: 8 frames at 60) and the picture now staying near the
// fast one: a cut, and the slow one takes it at once. a flash, a lightning strike, a muzzle flash, gone before that,
// comes back to where the slow one held: the bar sees no more than its first frame's share, nothing to snap back
// from. longer: in after 125 ms, out 125 ms after it ends, no faster. a cut reaches the bar that much later. a fade or
// a pan moves a little each frame and is never marked, nor is a part of the picture alone: smoothed as always
// (snapping there goes in steps). u.xy a quarter texel, u.z and u.w how much of the new picture goes into each.
// k: seconds since the last frame, how long a mark has to hold for a cut, how long it may hold at most
struct M { float4 slow [[color(0)]]; float4 fast [[color(1)]]; };
fragment M fsSideSmall(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> n [[texture(1)]], constant float4 &u [[buffer(0)]],
                       constant float4 &k [[buffer(1)]], M was) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = 0;
    for (int j = 0; j < 4; j++)
        for (int i = 0; i < 4; i++) c += t.sample(s, in.uv + (float2(i, j) - 1.5) * u.xy).rgb;
    c /= 16;
    float3 now = abs(c - was.fast.rgb), f = mix(was.fast.rgb, c, u.w), jump = abs(f - was.slow.rgb), off = abs(c - f), away = abs(c - was.slow.rgb);
    float j = max(jump.r, max(jump.g, jump.b)), most = n.read(uint2(0)).a;
    float age = was.fast.a > 0 ? was.fast.a - 0.01 + k.x : max(now.r, max(now.g, now.b)) > 0.2 ? 0 : -1; // -1: not marked
    if (u.z >= 1 || max(away.r, max(away.g, away.b)) < 0.1 || age > k.z) age = -1;
    bool cut = age >= k.y && most > 0.4 && j > 0.1 && max(off.r, max(off.g, off.b)) < 0.3 * j;
    bool mark = age >= 0 && !cut;
    M o;
    o.slow = float4(cut ? f : mark && most > 0.4 ? was.slow.rgb : mix(was.slow.rgb, c, u.z), mark ? 1 : 0);
    o.fast = float4(f, mark ? 0.01 + age : 0);
    return o;
}
// grey: one flat colour
fragment float4 fsSideFlat(V in [[stage_in]], constant float4 &u [[buffer(0)]]) { return float4(u.rgb, 1); }
// the glow, at an eighth of the drawable a side (sc: drawable pixels a texel), for the whole of it: the bars' pass
// reads it bilinear, at the seam too. pic: the picture's left, top, right, bottom in drawable pixels. k: brightness
// past the seam, blur growth (px of radius per px out), width of the seam's step (px, also the blur there). cr: the
// part of the picture pic shows, left, top, width, height in 0..1 (all of it but with the letterbox crop)
struct G { float4 pic; float4 k; float4 sc; float4 cr; };
fragment float4 fsSideGlow(V in [[stage_in]], texture2d<float> a [[texture(0)]], constant G &b [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 p = in.pos.xy * b.sc.xy, lo = b.pic.xy, size = b.pic.zw - lo;
    float2 q = clamp(p, lo, b.pic.zw); // the nearest point of the picture
    float d = length(p - q), m = min(size.x, size.y);
    float r = b.k.z + b.k.y * d; // blur radius, px: already soft at the seam
    float2 full = size / b.cr.zw; // the whole picture, px
    float lod = log2(max(r * a.get_width() / full.x, 1.0));
    float2 uv = b.cr.xy + (q - lo) / full, o = 0.5 * r / full;
    float3 c = a.sample(s, uv + o * float2(-1, -0.33), level(lod)).rgb + a.sample(s, uv + o * float2(0.33, -1), level(lod)).rgb +
               a.sample(s, uv + o * float2(1, 0.33), level(lod)).rgb + a.sample(s, uv + o * float2(-0.33, 1), level(lod)).rgb;
    c *= 0.25; // four taps around the point, turned a little so the mips' grid does not show
    c = mix(float3(dot(c, float3(0.2126, 0.7152, 0.0722))), c, 0.85);
    c *= mix(0.5 + 0.5 * b.k.x, b.k.x, smoothstep(0.0, b.k.z, d)) * exp(-2 * d / m); // half way down at the seam, then eased
    return float4(c, 1);
}
// the bars at full size: the glow, and a dither of one level. u: 1 / drawable size, frame number
fragment float4 fsSideBars(V in [[stage_in]], texture2d<float> g [[texture(0)]], constant float4 &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = g.sample(s, in.pos.xy * u.xy).rgb;
    uint2 q = uint2(in.pos.xy);
    uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u ^ uint(u.z) * 0xcb1ab31fu;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    float n = (float(h & 0xffffu) + float(h >> 16)) / 65535.0 - 1.0; // -1 .. 1, triangular
    return float4(saturate(c + n / 255), 1);
}
)M";

// the stretch's last pass, a library of its own, compiled the first time the stretch is wanted: nothing of it at
// launch, and a fault here leaves the picture unstretched, never the app unable to start. V, vs, U and grainOn are
// copies of Shaders.metal's, outAt one of its fsOut: keep them in step
static NSString *const kWarp = @R"M(
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
struct U { float2 texel; float amount; float pad; };
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
// sides-only stretch: the picture drawn R times the fit's width (the viewport), the middle at the fit's scale, the
// outer parts widened more and more towards the edges. horizontal only. x = place in the picture, y = place on screen,
// both in half-widths of the fit (x in -1..1, y in -R..R). picture -> screen, sign kept:
//   |x| <= x0: y = x;  else y = x0 + m t + (R-1) t^3, t = (|x| - x0) / m, m = 1 - x0
// slope 1 up to x0, 1 + 3 (R-1) / m at the edge, the slope and its own rate of change continuous, edge to edge exact.
// it is the cubic of bin jin's (bjin) hyperview.hook, an mpv user shader published as a gist (y = (R-1) x^3 + x, here
// x0 = 0), written from the formula, given a true middle band. screen -> picture is a depressed cubic with one real
// root: cardano scaled to z^3 + 3z = 2q, then
// s = cube root of (q + sqrt(q^2 + 1)), z = s - 1/s, taken as 2q / (s^2 + 1 + 1/s^2) so nothing cancels as R goes
// to 1. x = x0 + m c z with c = sqrt(m / 3a). metal 3.0 / 3.1 have no cbrt; the root's argument is >= 1, so powr is fine.
// w, filled on the cpu for a given R and x0 (a = R - 1, m = 1 - x0):
//   w = (R, x0, 1.5 sqrt(3a) / m^1.5, m^1.5 / sqrt(3a)); R <= 1: w = (1, 0, 0, 0), no warp
static float warpX(float y, constant float4 &w) {
    float d = abs(y) - w.y;
    if (d <= 0) return y;
    float q = w.z * d, s = powr(q + sqrt(q * q + 1), 1.0 / 3);
    return copysign(w.y + w.w * 2 * q / (s * s + 1 + 1 / (s * s)), y);
}
// fsOut's body, reading at uv instead of in.uv. a copy on purpose: with one shared function the compiler built fsOut's
// grain path an ulp differently (measured), and fsOut has to stay exactly as it was. keep the two in step
static float4 outAt(V in, float2 uv, texture2d<float> t, constant U &u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 e = t.sample(s, uv).rgb;
    if (u.amount <= 0) return float4(grainOn(e, in.pos.xy, u.pad), 1);
    float3 b = t.sample(s, uv + float2(0, -u.texel.y)).rgb;
    float3 d = t.sample(s, uv + float2(-u.texel.x, 0)).rgb;
    float3 f = t.sample(s, uv + float2(u.texel.x, 0)).rgb;
    float3 h = t.sample(s, uv + float2(0, u.texel.y)).rgb;
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
// fsOut at the warped spot. in.uv runs across the viewport (the stretched rect); y and the sharpen taps unchanged
fragment float4 fsOutWarp(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]],
                          constant float4 &w [[buffer(1)]]) {
    float2 uv = in.uv;
    if (w.x > 1) uv.x = 0.5 + 0.5 * warpX((2 * in.uv.x - 1) * w.x, w);
    return outAt(in, uv, t, u);
}
)M";

id<MTLRenderPipelineState> warpPipe(id<MTLDevice> dev) {
    static id<MTLRenderPipelineState> p;
    static bool tried;
    if (tried) return p;
    tried = true;
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kWarp options:nil error:&e];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsOutWarp"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (lib) p = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!p) logLine("side stretch: no pipeline, not stretched for this session: %s", e.localizedDescription.UTF8String ?: "?");
    return p;
}

static id<MTLRenderPipelineState> gSmall, gGlowP, gBars, gFlat;
static id<MTLTexture> gMean, gFast, gCut, gGlow; // the running means (the slow one with its mips), its last mip. the glow at an eighth of the drawable
static int gOk;               // 0 not tried, 1 ready, -1 failed: black bars for the session
static double gLast;
static uint64_t gNoMem;       // the picture and drawable size that got no texture: not asked again until one of them changes
static uint32_t gFrame;

static bool setup(id<MTLDevice> dev) {
    if (gOk) return gOk > 0;
    gOk = -1;
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kKernels options:nil error:&e];
    if (!lib) { logLine("side bars: shaders did not compile, black bars for this session: %s", e.localizedDescription.UTF8String ?: "?"); return false; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsSideSmall"];
    MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
    ca.pixelFormat = pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
    gSmall = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.colorAttachments[1].pixelFormat = MTLPixelFormatInvalid;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsSideGlow"];
    gGlowP = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsSideBars"];
    gBars = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsSideFlat"];
    gFlat = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gSmall || !gGlowP || !gBars || !gFlat) { logLine("side bars: no pipeline, black bars for this session"); return false; }
    gOk = 1;
    return true;
}

static id<MTLRenderCommandEncoder> open(id<MTLCommandBuffer> cb, id<MTLTexture> t, MTLLoadAction load, void (^mark)(MTLRenderPassDescriptor *)) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = load;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    mark(rp);
    return [cb renderCommandEncoderWithDescriptor:rp];
}

// the small copy into the running means, and the slow one's mips
static bool update(id<MTLCommandBuffer> cb, id<MTLTexture> pic, double fw, double fh, void (^mark)(MTLRenderPassDescriptor *)) {
    NSUInteger w = (NSUInteger)fmax(8, round(fw / 16)), h = (NSUInteger)fmax(8, round(fh / 16));
    bool fresh = !gMean || !gFast || !gCut || gMean.width != w || gMean.height != h;
    if (fresh) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:YES];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        gMean = [cb.device newTextureWithDescriptor:d];
        d.mipmapLevelCount = 1;
        gFast = [cb.device newTextureWithDescriptor:d];
        d.width = d.height = 1;
        gCut = [cb.device newTextureWithDescriptor:d];
        if (!gMean || !gFast || !gCut) return false;
    }
    double now = nowSec(), dt = now - gLast;
    gLast = now;
    // new size, first time, after a pause (no signal, another source): from the picture as it is now, not faded in
    bool snap = fresh || !(dt >= 0 && dt < 0.25);
    float a = snap ? 1 : (float)(1 - exp(-dt * 1000 / gSet.sideSmooth)), af = snap ? 1 : (float)(1 - exp(-dt * 1000 / 25));
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int i = 0; i < 2; i++) {
        rp.colorAttachments[i].texture = i ? gFast : gMean;
        rp.colorAttachments[i].loadAction = snap ? MTLLoadActionClear : MTLLoadActionLoad; // a new texture can hold nans
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    mark(rp);
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:gSmall];
    [e setViewport:(MTLViewport){0, 0, (double)w, (double)h, 0, 1}];
    float u[4] = {0.25f / w, 0.25f / h, a, af}, k[4] = {(float)dt, 0.125f, 0.3f, 0};
    [e setFragmentBytes:u length:sizeof u atIndex:0];
    [e setFragmentBytes:k length:sizeof k atIndex:1];
    [e setFragmentTexture:pic atIndex:0];
    [e setFragmentTexture:gCut atIndex:1]; // a new one holds anything, but then this is a snap and it is not looked at
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b generateMipmapsForTexture:gMean];
    [b copyFromTexture:gMean sourceSlice:0 sourceLevel:gMean.mipmapLevelCount - 1 toTexture:gCut destinationSlice:0 destinationLevel:0 sliceCount:1 levelCount:1];
    [b endEncoding];
    return true;
}

// letterbox crop. the ease in: 200 ms from the first frame with a band, smoothstepped. out: at once
static double gZoomFrom, gZoomLast;
static int gZoomTop, gZoomBottom;

bool zoom(int top, int bottom, int H, MTLViewport vp, double dw, double dh, MTLViewport &all, MTLViewport &shown, double *ease) {
    double bh = (bottom - top) * vp.height / H, z = fmin(dw / vp.width, dh / fmax(1, bh)), now = nowSec();
    if (now - gZoomLast > 0.1) gZoomTop = -1; // not asked for a while (switched off, no signal): eased in again
    gZoomLast = now;
    if (top <= 0 && bottom >= H) { gZoomTop = -1; return false; }
    if (z < 1.02) return false; // the band fills the window already (or nearly)
    if (top != gZoomTop || bottom != gZoomBottom) { gZoomFrom = now; gZoomTop = top; gZoomBottom = bottom; }
    double t = fmin(1, fmax(0, (now - gZoomFrom) / 0.2)), e = t * t * (3 - 2 * t), zs = 1 + (z - 1) * e;
    double cy = 0.5 * (top + bottom) * vp.height / H;                     // the band's middle in the picture, px
    double at = vp.originY + cy + (0.5 * dh - vp.originY - cy) * e;          // and on screen: from where it is to the middle
    all = (MTLViewport){0.5 * dw - 0.5 * vp.width * zs, at - cy * zs, vp.width * zs, vp.height * zs, 0, 1};
    double x0 = fmax(0, all.originX), x1 = fmin(dw, all.originX + all.width);
    double y0 = fmax(0, at - 0.5 * bh * zs), y1 = fmin(dh, at + 0.5 * bh * zs);
    shown = (MTLViewport){round(x0), round(y0), round(x1) - round(x0), round(y1) - round(y0), 0, 1};
    if (ease) *ease = e;
    return shown.width >= 2 && shown.height >= 2;
}

double stretchWidth(int step, MTLViewport vp, double dw) {
    if (step <= 0 || dw <= vp.width + 1) return 1;
    return (vp.width + fmin(step, 3) / 3.0 * (dw - vp.width)) / vp.width;
}

bool stretch(double r, double centre, double dw, MTLViewport &all, MTLViewport &shown, float w[4]) {
    if (r < 1.001) return false;
    double cx = all.originX + 0.5 * all.width, x0 = fmin(fmax(centre, 0.0), 0.6), m = 1 - x0, a = r - 1, m15 = pow(m, 1.5);
    all.width *= r;
    all.originX = cx - 0.5 * all.width;
    double l = round(fmax(0, all.originX)), rt = round(fmin(dw, all.originX + all.width));
    shown.originX = l; shown.width = rt - l;
    w[0] = (float)r; w[1] = (float)x0; w[2] = (float)(1.5 * sqrt(3 * a) / m15); w[3] = (float)(m15 / sqrt(3 * a));
    return true;
}

// the frame last looked at, held: while it is, the source's pool cannot hand the same buffer out again as a new frame,
// so the same pointer is the same picture (shown again, held, or the newer real frame of a generated one)
static CVPixelBufferRef gLookPb;
static letterbox::Band gLookBand;

bool crop(CVPixelBufferRef pb, bool fullRange, MTLViewport vp, double dw, double dh, MTLViewport &all, MTLViewport &shown, double *ease) {
    if (!pb) return false;
    size_t H = CVPixelBufferGetHeight(pb);
    if (pb != gLookPb) {
        OSType f = CVPixelBufferGetPixelFormatType(pb);
        bool nv = f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        letterbox::Band b = {0, (int)H};
        if ((nv || f == kCVPixelFormatType_422YpCbCr8) && CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            letterbox::Plane y = {(const uint8_t *)(nv ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)), // 2vuy: cb y cr y
                                  nv ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb), nv ? 1u : 2u, CVPixelBufferGetWidth(pb), H};
            if (y.p) { if (!nv) y.p++; b = letterbox::look(y, nowSec(), fullRange ? 0 : 16); }
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        }
        if (gLookPb) CVPixelBufferRelease(gLookPb);
        gLookPb = CVPixelBufferRetain(pb);
        gLookBand = b;
    } else letterbox::seen(nowSec()); // a freeze or a held frame is no pause
    return zoom(gLookBand.top, gLookBand.bottom, (int)H, vp, dw, dh, all, shown, ease);
}

void cropOff() {
    if (!gLookPb) return;
    CVPixelBufferRelease(gLookPb);
    gLookPb = NULL;
    letterbox::reset();
}

// the glow at an eighth of the drawable from the slow mean's mips (fsSideGlow), g its G
static void glow(id<MTLCommandBuffer> cb, const float g[16], void (^mark)(MTLRenderPassDescriptor *)) {
    id<MTLRenderCommandEncoder> e = open(cb, gGlow, MTLLoadActionDontCare, mark);
    [e setRenderPipelineState:gGlowP];
    [e setViewport:(MTLViewport){0, 0, (double)gGlow.width, (double)gGlow.height, 0, 1}];
    [e setFragmentBytes:g length:16 * sizeof(float) atIndex:0];
    [e setFragmentTexture:gMean atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

// what draw() leaves for after(): the frame's own buffer holds only the bars, from the glow made after the frame
// before; the small copy, the mips and the next glow, and the canvas's look at the new frame, go in a buffer of their
// own committed behind it
static bool gAfter, gGlowDue, gCanvasDue, gReal;
static id<MTLTexture> gPic;
static CVPixelBufferRef gFrameAfter;
static MTLViewport gVp, gSides[2];
static double gFw, gFh;
static float gG[16];
static uint64_t gHave; // the size the glow in gGlow was made for, 0 none

void draw(id<MTLCommandBuffer> cb, id<MTLTexture> pic, CVPixelBufferRef frame, bool real, id<MTLTexture> dst, MTLViewport vp, MTLViewport all, double fw, double fh,
          void (^mark)(MTLRenderPassDescriptor *)) {
    double dw = dst.width, dh = dst.height, x0 = vp.originX, y0 = vp.originY, x1 = x0 + vp.width, y1 = y0 + vp.height;
    if (vp.width >= dw && vp.height >= dh) return; // no bars
    if (!setup(cb.device)) return;
    MTLViewport r[4] = {{0, 0, x0, dh, 0, 1}, {x1, 0, dw - x1, dh, 0, 1}, {x0, 0, vp.width, y0, 0, 1}, {x0, y1, vp.width, dh - y1, 0, 1}};
    auto fill = [&](id<MTLRenderCommandEncoder> e) { // left and right whole height, above and below as wide as the picture: whatever the window leaves
        for (MTLViewport v : r)
            if (v.width >= 1 && v.height >= 1) { [e setViewport:v]; [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; }
        [e endEncoding];
    };
    if (gSet.sideFill == 1) { // grey: a flat dark grey, no copy of the picture
        id<MTLRenderCommandEncoder> e = open(cb, dst, MTLLoadActionLoad, mark);
        float v = 0.25f * (1 - gSet.sideDim), u[4] = {v, v, v, 0};
        [e setRenderPipelineState:gFlat];
        [e setFragmentBytes:u length:sizeof u atIndex:0];
        fill(e);
        return;
    }
    NSUInteger gw = (NSUInteger)ceil(dw / 8), gh = (NSUInteger)ceil(dh / 8);
    uint64_t key = ((uint64_t)vp.width << 48) | ((uint64_t)vp.height << 32) | (gw << 16) | gh;
    if (key == gNoMem) return;
    if (!gGlow || gGlow.width != gw || gGlow.height != gh) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:gw height:gh mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        gGlow = [cb.device newTextureWithDescriptor:d];
        gHave = 0;
    }
    float g[16] = {(float)x0, (float)y0, (float)x1, (float)y1, 1 - gSet.sideDim, gSet.sideBlur, 0.03f * (float)fmin(vp.width, vp.height), 0,
                   (float)(dw / gw), (float)(dh / gh), 0, 0,
                   (float)((x0 - all.originX) / all.width), (float)((y0 - all.originY) / all.height), (float)(vp.width / all.width), (float)(vp.height / all.height)};
    // nothing made at this size yet (the first frame, a resize, the crop easing in): made now, in the frame's own
    // buffer, as the glow always was. else the next one is made after the frame, and the bars show it a frame on:
    // they follow the picture over sideSmooth anyway, a cut reaches them one frame later
    bool now = gHave != key || !(nowSec() - gLast < 0.25); // after a pause the one made then is stale: update() starts over
    if (now) {
        if (!gGlow || !update(cb, pic, fw, fh, mark)) {
            gNoMem = key;
            logLine("side bars: no memory for %.0fx%.0f, black bars at this size", dw, dh);
            return;
        }
        glow(cb, g, mark);
        gHave = key;
    }
    // canvas: the side bars from what the picture showed there before, over the glow. only with the picture as it is,
    // not cropped or stretched (it would be at another scale and speed than the bar), and not on the any-rate path
    // (made frames come at times the canvas does not follow): the glow then. it also does above and below
    bool plain = all.originX == vp.originX && all.originY == vp.originY && all.width == vp.width && all.height == vp.height && vp.width == fw && vp.height == fh;
    bool canv = gSet.sideFill == 3 && plain && gSet.rate == 0, sides = false;
    if (canv) sides = canvas::bars(cb, dst, vp, r[0], r[1], gGlow, 1 - gSet.sideDim, mark);
    else if (gSet.sideFill == 3) canvas::reset();
    gAfter = true; gGlowDue = !now; gCanvasDue = canv; gReal = real;
    gPic = pic; gVp = vp; gSides[0] = r[0]; gSides[1] = r[1]; gFw = fw; gFh = fh;
    memcpy(gG, g, sizeof g);
    if (gFrameAfter) CVPixelBufferRelease(gFrameAfter);
    gFrameAfter = canv && frame ? CVPixelBufferRetain(frame) : NULL;
    if (sides) r[0].width = r[1].width = 0;
    id<MTLRenderCommandEncoder> e = open(cb, dst, MTLLoadActionLoad, mark); // measured: a second trip through the drawable costs next to nothing
    float u[4] = {(float)(1 / dw), (float)(1 / dh), (float)(gFrame++ & 1023), 0};
    [e setRenderPipelineState:gBars];
    [e setFragmentBytes:u length:sizeof u atIndex:0];
    [e setFragmentTexture:gGlow atIndex:0];
    fill(e);
}

id<MTLCommandBuffer> after(id<MTLCommandQueue> q) {
    if (!gAfter) return nil;
    gAfter = false;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    void (^none)(MTLRenderPassDescriptor *) = ^(MTLRenderPassDescriptor *) {};
    if (gGlowDue) {
        if (update(cb, gPic, gFw, gFh, none)) glow(cb, gG, none);
        else gHave = 0; // no memory: the next frame tries in its own buffer and says so
    }
    if (gCanvasDue) canvas::after(cb, gPic, gFrameAfter, gReal, gVp, gSides[0], gSides[1]);
    gPic = nil;
    if (gFrameAfter) { CVPixelBufferRelease(gFrameAfter); gFrameAfter = NULL; }
    return cb;
}

}
