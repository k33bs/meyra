// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// what the op names of the graph file mean (runOps and its helpers) and the two kernels below (`down`, `warp`) are
// ported from flyhigh-engine, https://github.com/getflyhigh/flyhigh-engine, Apache-2.0: net/build.rs and the kernels
// tex_down, render_tex, interp, warp, sad, convex, film, luma, blend. see THIRD_PARTY_NOTICES.md. the graph itself,
// the tensor list and the weights are the user's files and are only ever read at run time.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#include "flyhigh.h"
#include "common.h"
#include <atomic>
#include <cmath>
#include <os/lock.h>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#include <CommonCrypto/CommonDigest.h>

namespace flyhigh {

// down: one 420v frame -> the net's input, [3][oh][ow] half floats, blue green red, values 0..1. an antialiased
// (triangle) shrink of the frame with its edge repeated out to iw x ih, the next multiple of 32.
// warp: one plane of the frame in between. the net's maps ([10][hq][wq]: where each pixel comes from in a and in b,
// three weights, a small correction in bgr) are enlarged to the plane, both real frames are read at the places the
// maps name (bicubic, edges held) and mixed. sub: 1 for the luma plane, 2 for chroma at half size
static NSString *const kKernels = @R"M(
#include <metal_stdlib>
using namespace metal;
struct DP { uint w, h, iw, ih, ow, oh, full, sd; };
static float3 toRgb(float3 v, uint full, uint sd) {
    float y = v.x, cb = v.y - 128.0f / 255.0f, cr = v.z - 128.0f / 255.0f;
    if (full == 0) { y = (y - 16.0f / 255.0f) * (255.0f / 219.0f); cb *= 255.0f / 224.0f; cr *= 255.0f / 224.0f; }
    if (sd != 0) return saturate(float3(y + 1.402f * cr, y - 0.3441f * cb - 0.7141f * cr, y + 1.772f * cb));
    return saturate(float3(y + 1.5748f * cr, y - 0.1873f * cb - 0.4681f * cr, y + 1.8556f * cb));
}
kernel void down(texture2d<float, access::read> ty [[texture(0)]], texture2d<float, access::read> tc [[texture(1)]],
                 device half *outp [[buffer(0)]], constant DP &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.ow || gid.y >= p.oh) return;
    float sh = float(p.ih) / float(p.oh), sw = float(p.iw) / float(p.ow);
    float fsh = max(sh, 1.0f), fsw = max(sw, 1.0f);
    float cy = (float(gid.y) + 0.5f) * sh, cx = (float(gid.x) + 0.5f) * sw;
    int ymin = max(0, int(floor(cy - fsh + 0.5f))), ymax = min(int(p.ih), int(floor(cy + fsh + 0.5f)));
    int xmin = max(0, int(floor(cx - fsw + 0.5f))), xmax = min(int(p.iw), int(floor(cx + fsw + 0.5f)));
    float3 acc = 0; float norm = 0;
    for (int y = ymin; y < ymax; y++) {
        float wy = max(0.0f, 1.0f - fabs((float(y) + 0.5f - cy) / fsh));
        uint sy = uint(min(y, int(p.h) - 1));
        for (int x = xmin; x < xmax; x++) {
            float w = wy * max(0.0f, 1.0f - fabs((float(x) + 0.5f - cx) / fsw));
            uint sx = uint(min(x, int(p.w) - 1));
            acc += float3(ty.read(uint2(sx, sy)).r, tc.read(uint2(sx / 2, sy / 2)).rg) * w; norm += w;
        }
    }
    float3 v = toRgb(acc / norm, p.full, p.sd);
    uint plane = p.oh * p.ow, o = gid.y * p.ow + gid.x;
    outp[o] = half(v.b); outp[plane + o] = half(v.g); outp[2 * plane + o] = half(v.r);
}

struct WP { uint w, h, wp, hp, hq, wq, sub, full, sd; float fsx, fsy; };
static inline float cub1(float x) { const float a = -0.75f; return ((a + 2.0f) * x - (a + 3.0f)) * x * x + 1.0f; }
static inline float cub2(float x) { const float a = -0.75f; return ((a * x - 5.0f * a) * x + 8.0f * a) * x - 4.0f * a; }
static float2 cubic(texture2d<float, access::read> t, float gx, float gy) {
    int px = int(floor(gx)), py = int(floor(gy)), mx = int(t.get_width()) - 1, my = int(t.get_height()) - 1;
    float tx = gx - float(px), tyy = gy - float(py);
    float4 cx = float4(cub2(tx + 1.0f), cub1(tx), cub1(1.0f - tx), cub2(2.0f - tx));
    float4 cy = float4(cub2(tyy + 1.0f), cub1(tyy), cub1(1.0f - tyy), cub2(2.0f - tyy));
    float2 r = 0;
    for (int j = 0; j < 4; j++) {
        uint y = uint(clamp(py + j - 1, 0, my));
        float2 row = 0;
        for (int i = 0; i < 4; i++) row += t.read(uint2(uint(clamp(px + i - 1, 0, mx)), y)).rg * cx[i];
        r += row * cy[j];
    }
    return r;
}
kernel void warp(texture2d<float, access::read> ta [[texture(0)]], texture2d<float, access::read> tb [[texture(1)]],
                 texture2d<float, access::write> dst [[texture(2)]], const device half *m [[buffer(0)]],
                 constant WP &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.w / p.sub || gid.y >= p.h / p.sub) return;
    float s = float(p.sub);
    float lx = float(gid.x) * s + (s - 1.0f) * 0.5f, ly = float(gid.y) * s + (s - 1.0f) * 0.5f; // this pixel on the luma grid
    float iy = (ly + 0.5f) * float(p.hq) / float(p.hp) - 0.5f, ix = (lx + 0.5f) * float(p.wq) / float(p.wp) - 0.5f;
    int qy0 = int(floor(iy)), qx0 = int(floor(ix));
    float fy = iy - float(qy0), fx = ix - float(qx0);
    uint y0 = uint(clamp(qy0, 0, int(p.hq) - 1)), y1 = uint(clamp(qy0 + 1, 0, int(p.hq) - 1));
    uint x0 = uint(clamp(qx0, 0, int(p.wq) - 1)), x1 = uint(clamp(qx0 + 1, 0, int(p.wq) - 1));
    uint plane = p.hq * p.wq;
    float q[10];
    for (uint c = 0; c < 10; c++) {
        const device half *b = m + c * plane;
        q[c] = mix(mix(float(b[y0 * p.wq + x0]), float(b[y0 * p.wq + x1]), fx), mix(float(b[y1 * p.wq + x0]), float(b[y1 * p.wq + x1]), fx), fy);
    }
    float mx = max(q[4], max(q[5], q[6]));
    float e0 = exp(q[4] - mx), e1 = exp(q[5] - mx), e2 = exp(q[6] - mx), es = e0 + e1 + e2;
    float wa = (e0 + 0.5f * e2) / es, wb = (e1 + 0.5f * e2) / es;
    float2 ca = cubic(ta, float(gid.x) + q[0] * p.fsx / s, float(gid.y) + q[1] * p.fsy / s);
    float2 cb = cubic(tb, float(gid.x) + q[2] * p.fsx / s, float(gid.y) + q[3] * p.fsy / s);
    // the correction is in rgb: taken over to this plane's own values
    float3 res = float3(q[9], q[8], q[7]);
    float3 kw = p.sd != 0 ? float3(0.299f, 0.587f, 0.114f) : float3(0.2126f, 0.7152f, 0.0722f);
    float dy = dot(res, kw);
    float2 d = p.sub == 1 ? float2(dy * (p.full != 0 ? 1.0f : 219.0f / 255.0f), 0.0f)
                          : float2((res.b - dy) / (2.0f - 2.0f * kw.b), (res.r - dy) / (2.0f - 2.0f * kw.r)) * (p.full != 0 ? 1.0f : 224.0f / 255.0f);
    float2 o = saturate(ca * wa + cb * wb + d);
    dst.write(float4(o.x, o.y, 0.0f, 1.0f), gid);
}
)M";

typedef MPSGraphTensor T;
static const MPSDataType DT = MPSDataTypeFloat16;

static std::atomic<bool> gRefused{false};
static std::string gWhy;                       // under gNoteLock
static os_unfair_lock gNoteLock = OS_UNFAIR_LOCK_INIT;

static NSString *folder() {
    // hidden, command line, for tests: another folder to read the three files from
    static NSString *const f = [[NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain][@"genModelDir"] description]
        ?: [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Meyra/flyhighfg"];
    return f;
}
static bool present() {
    for (NSString *n in @[@"graph.json", @"flyhighfg.json", @"flyhighfg.bin"])
        if (![NSFileManager.defaultManager isReadableFileAtPath:[folder() stringByAppendingPathComponent:n]]) return false;
    return true;
}
bool installed() {
    // asked on every capture tick: look at the disk once a second at most
    static std::atomic<double> at{-1};
    static std::atomic<bool> there{false};
    double now = nowSec();
    if (at < 0 || ([NSThread isMainThread] && now - at > 1)) { there = present(); at = now; } // after the first look only the main thread goes to the disk (the app asks once a second), the render thread asks every frame
    return there && !gRefused;
}
const char *note() {
    static thread_local char text[200];
    if (installed()) return "";
    os_unfair_lock_lock(&gNoteLock);
    if (gRefused) snprintf(text, sizeof text, "second generator not usable: %s", gWhy.c_str());
    else snprintf(text, sizeof text, "frame generator files not installed");
    os_unfair_lock_unlock(&gNoteLock);
    return text;
}
void retry() { gRefused = false; }
bool complete() { return present(); }

// the licence text goes next to the files, they ask for attribution
static const struct { const char *name, *sha; size_t most; } kFiles[] = {
    {"WEIGHTS_LICENSE.md", "d26368dc848a55f2f69f3f96c24be371b6a38f6b0729f66ec10c84f4fcf3311c", 1 << 16},
    {"graph.json", "5d367b59abf2a086c8529b3c8b7ba3990e11189a4b2150b362c4597c75d87d12", 1 << 20},
    {"flyhighfg.json", "ab8be2b2e275656bf26be3448bfba6759be8ec365c7294dbdc8e0b9f7e80bf44", 1 << 20},
    {"flyhighfg.bin", "660fce3db712fa17484a4981a45c08f549e93610cbaea05a266a4c36985cb487", 8 << 20},
};
static const char *const kFrom = "https://raw.githubusercontent.com/getflyhigh/flyhigh-engine/34c3fb6383b5d94146cd36878482367f49bb06dc/models/";
static std::atomic<bool> gGetting{false};
bool downloading() { return gGetting; }

void download(void (^done)(const std::string &)) {
    if (present()) { done("the files are there already, take them out of the folder first"); return; }
    if (gGetting.exchange(true)) { done("already downloading"); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      std::string err;
      std::vector<NSData *> got;
      NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
      cfg.timeoutIntervalForRequest = 20;
      cfg.timeoutIntervalForResource = 120;
      NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
      for (auto &f : kFiles) {
          NSMutableURLRequest *q = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%s%s", kFrom, f.name]]];
          [q setValue:@"Meyra" forHTTPHeaderField:@"User-Agent"]; // and nothing else about the machine
          [q setValue:@"en" forHTTPHeaderField:@"Accept-Language"];
          dispatch_semaphore_t sem = dispatch_semaphore_create(0);
          __block NSData *data = nil;
          __block std::string why;
          [[s dataTaskWithRequest:q completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
              long code = [r isKindOfClass:NSHTTPURLResponse.class] ? (long)((NSHTTPURLResponse *)r).statusCode : 0;
              if (e) why = std::string("github could not be reached (") + (e.localizedDescription.UTF8String ?: "?") + ")";
              else if (code != 200) why = "github answered with http " + std::to_string(code);
              else data = d;
              dispatch_semaphore_signal(sem);
          }] resume];
          dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER); // the resource timeout ends it
          if (why.empty() && data.length > f.most) why = "is larger than it can be";
          if (why.empty()) {
              unsigned char md[CC_SHA256_DIGEST_LENGTH];
              char hex[65];
              CC_SHA256(data.bytes, (CC_LONG)data.length, md);
              for (int i = 0; i < 32; i++) snprintf(hex + 2 * i, 3, "%02x", md[i]);
              if (strcmp(hex, f.sha)) why = "is not the file it should be (checksum)";
          }
          if (!why.empty()) { err = std::string(f.name) + ": " + why; break; }
          got.push_back(data);
      }
      [s finishTasksAndInvalidate];
      // nothing is written before everything is there and right
      if (err.empty()) {
          NSError *e = nil;
          [NSFileManager.defaultManager createDirectoryAtPath:folder() withIntermediateDirectories:YES attributes:nil error:&e];
          for (size_t i = 0; i < got.size() && !e; i++) [got[i] writeToFile:[folder() stringByAppendingPathComponent:@(kFiles[i].name)] options:NSDataWritingAtomic error:&e];
          if (e) err = std::string("the files could not be saved (") + (e.localizedDescription.UTF8String ?: "?") + ")";
      }
      logLine("frame generator files: %s", err.empty() ? "downloaded" : err.c_str());
      dispatch_async(dispatch_get_main_queue(), ^{
          gGetting = false;
          if (err.empty()) retry();
          done(err);
      });
    });
}
static void refuse(const std::string &why) {
    os_unfair_lock_lock(&gNoteLock);
    gWhy = why;
    os_unfair_lock_unlock(&gNoteLock);
    gRefused = true;
    logLine("second generator refused: %s", why.c_str());
}

// ---- the graph file, op by op, as an mpsgraph

struct Net {
    MPSGraph *g;
    NSDictionary *tensors;
    NSData *blob;
    NSMutableDictionary<NSString *, T *> *env;
    std::map<void *, std::vector<long>> shape; // mpsgraph does not always know its static shapes: tracked here
    NSArray<NSString *> *renderIn;             // what the file's last stage reads: a, b, flow, weights, correction
};
static void need(bool ok, const std::string &what) { if (!ok) throw std::runtime_error(what); }
static NSArray<NSNumber *> *shp(std::initializer_list<long> v) {
    NSMutableArray *a = [NSMutableArray array];
    for (long x : v) [a addObject:@(x)];
    return a;
}
static T *setS(Net &n, T *t, std::vector<long> v) { n.shape[(__bridge void *)t] = v; return t; }
static long dim(Net &n, T *t, int i) {
    auto it = n.shape.find((__bridge void *)t);
    need(it != n.shape.end(), "a tensor of unknown size");
    return it->second[i];
}
static std::vector<long> tensorShape(Net &n, NSString *name, long *offset) {
    NSDictionary *t = [n.tensors[name] isKindOfClass:NSDictionary.class] ? n.tensors[name] : nil;
    need(t != nil, std::string("no tensor ") + (name.UTF8String ?: "?"));
    NSArray *sh = [t[@"shape"] isKindOfClass:NSArray.class] ? t[@"shape"] : nil;
    need(sh && [t[@"offset"] isKindOfClass:NSNumber.class], std::string("tensor without shape or offset: ") + name.UTF8String);
    std::vector<long> v;
    long cnt = 1;
    for (id d in sh) {
        need([d isKindOfClass:NSNumber.class] && [d longValue] > 0 && [d longValue] < (1 << 20), std::string("bad shape: ") + name.UTF8String);
        v.push_back([d longValue]);
        cnt *= [d longValue];
        need(cnt < (1L << 28), std::string("tensor too large: ") + name.UTF8String);
    }
    long off = [t[@"offset"] longValue];
    need(off >= 0 && cnt <= (long)n.blob.length / 2 - off, // not (off + cnt) * 2: a huge offset wraps around and passes
          std::string("tensor outside the weights file: ") + name.UTF8String);
    *offset = off;
    return v;
}
static T *weight(Net &n, NSString *name, std::vector<long> *shapeOut = nullptr) {
    long off;
    std::vector<long> v = tensorShape(n, name, &off);
    long cnt = 1;
    NSMutableArray *sh = [NSMutableArray array];
    for (long d : v) { cnt *= d; [sh addObject:@(d)]; }
    if (shapeOut) *shapeOut = v;
    return [n.g constantWithData:[n.blob subdataWithRange:NSMakeRange(off * 2, cnt * 2)] shape:sh dataType:DT];
}
static std::vector<float> weightF(Net &n, NSString *name, std::vector<long> *shapeOut) {
    long off;
    *shapeOut = tensorShape(n, name, &off);
    long cnt = 1;
    for (long d : *shapeOut) cnt *= d;
    const _Float16 *p = (const _Float16 *)((const char *)n.blob.bytes + off * 2);
    std::vector<float> v(cnt);
    for (long i = 0; i < cnt; i++) v[i] = (float)p[i];
    return v;
}
static T *constF(Net &n, const std::vector<float> &v, NSArray *shape) {
    std::vector<_Float16> h(v.size());
    for (size_t i = 0; i < v.size(); i++) h[i] = (_Float16)v[i];
    return [n.g constantWithData:[NSData dataWithBytes:h.data() length:h.size() * 2] shape:shape dataType:DT];
}
static T *scalar(Net &n, double v) { return [n.g constantWithScalar:v dataType:DT]; }
static T *sl(Net &n, T *x, int axis, long a, long len) { return [n.g sliceTensor:x dimension:axis start:a length:len name:nil]; }

// 3x3 convolution, pad 1, bias, and a per-channel leaky relu when the op names its slopes
static T *conv3(Net &n, T *x, NSString *wn, NSString *bn, NSString *sn, long stride) {
    std::vector<long> ws, bs, ss;
    T *w = weight(n, wn, &ws), *b = weight(n, bn, &bs);
    need(ws.size() == 4 && ws[2] == 3 && ws[3] == 3, "a convolution that is not 3x3");
    need(ws[1] == dim(n, x, 1), std::string("convolution input channels do not fit: ") + wn.UTF8String);
    need(bs.size() == 1 && bs[0] == ws[0], "convolution bias does not fit");
    need(stride == 1 || stride == 2, "convolution stride");
    MPSGraphConvolution2DOpDescriptor *d = [MPSGraphConvolution2DOpDescriptor descriptorWithStrideInX:stride strideInY:stride dilationRateInX:1 dilationRateInY:1 groups:1
        paddingLeft:1 paddingRight:1 paddingTop:1 paddingBottom:1 paddingStyle:MPSGraphPaddingStyleExplicit
        dataLayout:MPSGraphTensorNamedDataLayoutNCHW weightsLayout:MPSGraphTensorNamedDataLayoutOIHW];
    long co = ws[0];
    std::vector<long> rs = {1, co, (dim(n, x, 2) - 1) / stride + 1, (dim(n, x, 3) - 1) / stride + 1};
    T *r = [n.g convolution2DWithSourceTensor:x weightsTensor:w descriptor:d name:nil];
    r = [n.g additionWithPrimaryTensor:r secondaryTensor:[n.g reshapeTensor:b withShape:shp({1, co, 1, 1}) name:nil] name:nil];
    if (sn) {
        T *s = weight(n, sn, &ss);
        need(ss.size() == 1 && ss[0] == co, "convolution slopes do not fit");
        r = [n.g leakyReLUWithTensor:r alphaTensor:[n.g reshapeTensor:s withShape:shp({1, co, 1, 1}) name:nil] name:nil];
    }
    return setS(n, r, rs);
}
// antialiased shrink by a whole factor f: a triangle 2f wide, the taps cut off at the edge made up for
static T *shrink(Net &n, T *x, long f) {
    long c = dim(n, x, 1), h = dim(n, x, 2), w = dim(n, x, 3), oh = h / f, ow = w / f;
    need(f >= 2 && f <= 16 && f % 2 == 0 && h % f == 0 && w % f == 0, "an antialiased resize this cannot do");
    std::vector<float> k1(2 * f), k2(4 * f * f), rn(oh * ow);
    for (long j = 0; j < 2 * f; j++) k1[j] = 1.0f - fabsf(j + 0.5f - f) / f;
    for (long a = 0; a < 2 * f; a++) for (long b = 0; b < 2 * f; b++) k2[a * 2 * f + b] = k1[a] * k1[b] / (f * f);
    auto norm = [&](long o, long size) {
        float s = 0;
        for (long j = 0; j < 2 * f; j++) { long y = o * f - f / 2 + j; if (y >= 0 && y < size) s += k1[j]; }
        return s / f;
    };
    for (long y = 0; y < oh; y++) for (long xx = 0; xx < ow; xx++) rn[y * ow + xx] = 1.0f / (norm(y, h) * norm(xx, w));
    MPSGraphConvolution2DOpDescriptor *d = [MPSGraphConvolution2DOpDescriptor descriptorWithStrideInX:f strideInY:f dilationRateInX:1 dilationRateInY:1 groups:1
        paddingLeft:f / 2 paddingRight:f / 2 paddingTop:f / 2 paddingBottom:f / 2 paddingStyle:MPSGraphPaddingStyleExplicit
        dataLayout:MPSGraphTensorNamedDataLayoutNCHW weightsLayout:MPSGraphTensorNamedDataLayoutOIHW];
    T *r = [n.g convolution2DWithSourceTensor:[n.g reshapeTensor:x withShape:shp({c, 1, h, w}) name:nil] weightsTensor:constF(n, k2, shp({1, 1, 2 * f, 2 * f})) descriptor:d name:nil];
    r = [n.g reshapeTensor:r withShape:shp({1, c, oh, ow}) name:nil];
    return [n.g multiplicationWithPrimaryTensor:r secondaryTensor:constF(n, rn, shp({1, 1, oh, ow})) name:nil];
}
// out[p] = img[p + flow[p]], bilinear, edges held
static T *warpOp(Net &n, T *img, T *flow) {
    need(dim(n, flow, 1) == 2 && dim(n, flow, 2) == dim(n, img, 2) && dim(n, flow, 3) == dim(n, img, 3), "warp: picture and flow do not fit");
    T *c = [n.g transposeTensor:flow permutation:@[@0, @2, @3, @1] name:nil];
    return [n.g sampleGridWithSourceTensor:img coordinateTensor:c layout:MPSGraphTensorNamedDataLayoutNCHW normalizeCoordinates:NO relativeCoordinates:YES
                              alignCorners:YES paddingMode:MPSGraphPaddingModeClampToEdge samplingMode:MPSGraphResizeBilinear constantValue:0 name:nil];
}
static T *luma(Net &n, T *x) { // of blue green red
    need(dim(n, x, 1) == 3, "luma of something that is not a picture");
    T *b = [n.g multiplicationWithPrimaryTensor:sl(n, x, 1, 0, 1) secondaryTensor:scalar(n, 0.114) name:nil];
    T *g = [n.g multiplicationWithPrimaryTensor:sl(n, x, 1, 1, 1) secondaryTensor:scalar(n, 0.587) name:nil];
    T *r = [n.g multiplicationWithPrimaryTensor:sl(n, x, 1, 2, 1) secondaryTensor:scalar(n, 0.299) name:nil];
    return [n.g additionWithPrimaryTensor:[n.g additionWithPrimaryTensor:b secondaryTensor:g name:nil] secondaryTensor:r name:nil];
}
// |a - b moved by (dx, dy)| for every move within the radius, each averaged over 3x3
static T *sadVolume(Net &n, T *la, T *lb, long r) {
    long h = dim(n, la, 2), w = dim(n, la, 3);
    need(r >= 1 && r <= 8 && dim(n, la, 1) == 1 && dim(n, lb, 1) == 1 && dim(n, lb, 2) == h && dim(n, lb, 3) == w, "cost volume inputs do not fit");
    T *lbp = [n.g padTensor:lb withPaddingMode:MPSGraphPaddingModeClampToEdge leftPadding:shp({0, 0, r, r}) rightPadding:shp({0, 0, r, r}) constantValue:0 name:nil];
    NSMutableArray *moved = [NSMutableArray array];
    for (long dy = -r; dy <= r; dy++)
        for (long dx = -r; dx <= r; dx++) [moved addObject:sl(n, sl(n, lbp, 2, r + dy, h), 3, r + dx, w)];
    T *d = [n.g absoluteWithTensor:[n.g subtractionWithPrimaryTensor:la secondaryTensor:[n.g concatTensors:moved dimension:1 name:nil] name:nil] name:nil];
    MPSGraphPooling2DOpDescriptor *pd = [MPSGraphPooling2DOpDescriptor descriptorWithKernelWidth:3 kernelHeight:3 strideInX:1 strideInY:1 dilationRateInX:1 dilationRateInY:1
        paddingLeft:1 paddingRight:1 paddingTop:1 paddingBottom:1 paddingStyle:MPSGraphPaddingStyleExplicit dataLayout:MPSGraphTensorNamedDataLayoutNCHW];
    pd.includeZeroPadToAverage = YES;
    return [n.g avgPooling2DWithSourceTensor:d descriptor:pd name:nil];
}
// twice the size: each of the four new pixels a weighted mean of the 3x3 around the old one, weights from wt
static T *convex(Net &n, T *wt, T *x) {
    long c = dim(n, x, 1), h = dim(n, x, 2), w = dim(n, x, 3);
    need(dim(n, wt, 1) == 36 && dim(n, wt, 2) == h && dim(n, wt, 3) == w, "upsample weights do not fit");
    T *m = [n.g softMaxWithTensor:[n.g reshapeTensor:wt withShape:shp({1, 9, 4, h, w}) name:nil] axis:1 name:nil];
    T *xp = [n.g padTensor:x withPaddingMode:MPSGraphPaddingModeConstant leftPadding:shp({0, 0, 1, 1}) rightPadding:shp({0, 0, 1, 1}) constantValue:0 name:nil];
    NSMutableArray *nb = [NSMutableArray array];
    for (int ky = 0; ky < 3; ky++) for (int kx = 0; kx < 3; kx++) [nb addObject:sl(n, sl(n, xp, 2, ky, h), 3, kx, w)];
    T *xs = [n.g stackTensors:nb axis:2 name:nil];
    T *sub[4];
    for (int s = 0; s < 4; s++) {
        T *ms = [n.g reshapeTensor:sl(n, m, 2, s, 1) withShape:shp({1, 1, 9, h, w}) name:nil];
        sub[s] = [n.g reshapeTensor:[n.g reductionSumWithTensor:[n.g multiplicationWithPrimaryTensor:xs secondaryTensor:ms name:nil] axis:2 name:nil] withShape:shp({1, c, h, w}) name:nil];
    }
    T *row0 = [n.g reshapeTensor:[n.g stackTensors:@[sub[0], sub[1]] axis:4 name:nil] withShape:shp({1, c, h, 2 * w}) name:nil];
    T *row1 = [n.g reshapeTensor:[n.g stackTensors:@[sub[2], sub[3]] axis:4 name:nil] withShape:shp({1, c, h, 2 * w}) name:nil];
    return [n.g reshapeTensor:[n.g stackTensors:@[row0, row1] axis:3 name:nil] withShape:shp({1, c, 2 * h, 2 * w}) name:nil];
}
static NSArray<NSString *> *names(NSDictionary *op, NSString *key) {
    NSArray *a = [op[key] isKindOfClass:NSArray.class] ? op[key] : @[];
    for (id s in a) need([s isKindOfClass:NSString.class], "an op with a name that is not text");
    return a;
}
static double number(NSDictionary *op, NSString *key, double fallback) {
    return [op[key] isKindOfClass:NSNumber.class] ? [op[key] doubleValue] : fallback;
}

static void runOps(Net &n, NSArray *ops, int k, float t, int depth = 0) {
    MPSGraph *g = n.g;
    need([ops isKindOfClass:NSArray.class] && depth < 3, "graph file: no list of ops");
    for (NSDictionary *op in ops) {
        need([op isKindOfClass:NSDictionary.class] && [op[@"op"] isKindOfClass:NSString.class], "graph file: an op without a name");
        NSString *name = op[@"op"];
        auto is = [&](const char *s) { return [name isEqualToString:@(s)]; };
        if (is("repeat")) {
            for (int i = 0; i < k; i++) runOps(n, op[@"body"], k, t, depth + 1);
            continue;
        }
        NSArray<NSString *> *inN = names(op, @"in"), *o = names(op, @"out"), *w = names(op, @"w");
        if (is("render_pix")) { n.renderIn = inN; continue; } // done by the warp kernel at full size
        NSMutableArray<T *> *in = [NSMutableArray array];
        for (NSString *s in inN) if (![s isEqual:@"t"]) {
            need(n.env[s] != nil, std::string(name.UTF8String) + " reads " + s.UTF8String + ", which nothing made");
            [in addObject:n.env[s]];
        }
        need(o.count >= 1, std::string(name.UTF8String) + " without an output");
        auto ins = [&](NSUInteger c) { need(in.count >= c, std::string(name.UTF8String) + " with too few inputs"); };
        auto ws = [&](NSUInteger c) { need(w.count >= c, std::string(name.UTF8String) + " with too few weights"); };
        auto sameHW = [&](T *a, T *b) { need(dim(n, a, 2) == dim(n, b, 2) && dim(n, a, 3) == dim(n, b, 3), std::string(name.UTF8String) + ": sizes do not fit"); };
        T *r = nil;
        long c0 = in.count ? dim(n, in[0], 1) : 0, h0 = in.count ? dim(n, in[0], 2) : 1, w0 = in.count ? dim(n, in[0], 3) : 1;
        std::vector<long> rs = {1, c0, h0, w0};
        if (is("interpolate")) {
            ins(1);
            double s = number(op, @"scale", 0);
            if ([op[@"antialias"] isKindOfClass:NSNumber.class] && [op[@"antialias"] boolValue]) {
                need(s > 0 && s < 1 && fabs(1 / s - round(1 / s)) < 1e-6, "an antialiased resize this cannot do");
                long f = lround(1 / s);
                r = shrink(n, in[0], f);
                rs = {1, c0, h0 / f, w0 / f};
            } else {
                need(s >= 1 && s <= 8 && s == floor(s), "a resize this cannot do");
                rs = {1, c0, (long)(h0 * s), (long)(w0 * s)};
                int32_t sz[2] = {(int32_t)rs[2], (int32_t)rs[3]};
                r = [g resizeBilinearWithTensor:in[0] sizeTensor:[g constantWithData:[NSData dataWithBytes:sz length:8] shape:@[@2] dataType:MPSDataTypeInt32]
                                    centerResult:YES alignCorners:NO layout:MPSGraphTensorNamedDataLayoutNCHW name:nil];
            }
        } else if (is("conv")) { ins(1); ws(3); r = conv3(n, in[0], w[0], w[1], w[2], (long)number(op, @"stride", 1)); rs = n.shape[(__bridge void *)r]; }
        else if (is("conv2d")) { ins(1); ws(2); r = conv3(n, in[0], w[0], w[1], nil, 1); rs = n.shape[(__bridge void *)r]; }
        else if (is("avgpool")) {
            ins(1);
            long kk = (long)number(op, @"k", 0);
            need(kk >= 1 && kk <= 8 && h0 % kk == 0 && w0 % kk == 0, "a pooling this cannot do");
            MPSGraphPooling2DOpDescriptor *d = [MPSGraphPooling2DOpDescriptor descriptorWithKernelWidth:kk kernelHeight:kk strideInX:kk strideInY:kk paddingStyle:MPSGraphPaddingStyleTF_VALID dataLayout:MPSGraphTensorNamedDataLayoutNCHW];
            r = [g avgPooling2DWithSourceTensor:in[0] descriptor:d name:nil];
            rs = {1, c0, h0 / kk, w0 / kk};
        } else if (is("warp")) { ins(2); r = warpOp(n, in[0], in[1]); }
        else if (is("concat")) {
            ins(1);
            long c = 0;
            for (T *x in in) { sameHW(in[0], x); c += dim(n, x, 1); }
            r = [g concatTensors:in dimension:1 name:nil];
            rs[1] = c;
        } else if (is("slice")) {
            ins(1);
            long a = (long)number(op, @"a", -1), b = (long)number(op, @"b", -1);
            need(a >= 0 && b > a && b <= c0, "a slice outside its tensor");
            r = sl(n, in[0], 1, a, b - a);
            rs[1] = b - a;
        } else if (is("scale")) { ins(1); r = [g multiplicationWithPrimaryTensor:in[0] secondaryTensor:scalar(n, number(op, @"factor", 1)) name:nil]; }
        else if (is("mul_t")) { ins(1); r = [g multiplicationWithPrimaryTensor:in[0] secondaryTensor:scalar(n, [op[@"mode"] isEqual:@"fwd"] ? 2 * t : 2 * (1 - t)) name:nil]; }
        else if (is("neg")) { ins(1); r = [g negativeWithTensor:in[0] name:nil]; }
        else if (is("add") || is("mul")) {
            ins(2); sameHW(in[0], in[1]);
            need(dim(n, in[1], 1) == c0 || dim(n, in[1], 1) == 1, std::string(name.UTF8String) + ": channels do not fit");
            r = is("add") ? [g additionWithPrimaryTensor:in[0] secondaryTensor:in[1] name:nil] : [g multiplicationWithPrimaryTensor:in[0] secondaryTensor:in[1] name:nil];
        } else if (is("zeros")) {
            ins(1);
            long ch = (long)number(op, @"ch", 0);
            need(ch >= 1 && ch <= 4096, "zeros of no size");
            r = [g constantWithScalar:0 shape:shp({1, ch, h0, w0}) dataType:DT];
            rs[1] = ch;
        } else if (is("zeros_like")) { ins(1); r = [g constantWithScalar:0 shape:shp({1, c0, h0, w0}) dataType:DT]; }
        else if (is("copy")) { ins(1); r = in[0]; }
        else if (is("luma")) { ins(1); r = luma(n, in[0]); rs[1] = 1; }
        else if (is("luma_grad")) { // how much the luma changes to the right and downwards
            ins(1);
            need(h0 > 1 && w0 > 1, "a gradient of one pixel");
            T *l = luma(n, in[0]);
            T *gx = [g subtractionWithPrimaryTensor:sl(n, l, 3, 1, w0 - 1) secondaryTensor:sl(n, l, 3, 0, w0 - 1) name:nil];
            T *gy = [g subtractionWithPrimaryTensor:sl(n, l, 2, 1, h0 - 1) secondaryTensor:sl(n, l, 2, 0, h0 - 1) name:nil];
            gx = [g padTensor:[g absoluteWithTensor:gx name:nil] withPaddingMode:MPSGraphPaddingModeConstant leftPadding:shp({0, 0, 0, 0}) rightPadding:shp({0, 0, 0, 1}) constantValue:0 name:nil];
            gy = [g padTensor:[g absoluteWithTensor:gy name:nil] withPaddingMode:MPSGraphPaddingModeConstant leftPadding:shp({0, 0, 0, 0}) rightPadding:shp({0, 0, 1, 0}) constantValue:0 name:nil];
            r = [g additionWithPrimaryTensor:gx secondaryTensor:gy name:nil];
            rs[1] = 1;
        } else if (is("sad_volume")) {
            ins(2);
            long rad = (long)number(op, @"radius", 0);
            r = sadVolume(n, in[0], in[1], rad);
            rs[1] = (2 * rad + 1) * (2 * rad + 1);
        } else if (is("affine_out")) { ins(1); r = [g subtractionWithPrimaryTensor:[g multiplicationWithPrimaryTensor:[g sigmoidWithTensor:in[0] name:nil] secondaryTensor:scalar(n, 2) name:nil] secondaryTensor:scalar(n, 1) name:nil]; }
        else if (is("film_mlp")) { // two small layers of the phase t, worked out here once: t is fixed at a half
            ws(4);
            std::vector<long> s1, sb1, s2, sb2;
            auto w1 = weightF(n, w[0], &s1), b1 = weightF(n, w[1], &sb1), w2 = weightF(n, w[2], &s2), b2 = weightF(n, w[3], &sb2);
            need(s1.size() == 2 && s1[1] == 1 && sb1.size() == 1 && sb1[0] == s1[0] && s2.size() == 2 && s2[1] == s1[0] && sb2.size() == 1 && sb2[0] == s2[0], "the phase layers do not fit");
            long hid = s1[0], outN = s2[0];
            std::vector<float> hv(hid), gv(outN);
            for (long i = 0; i < hid; i++) hv[i] = fmaxf(0.0f, w1[i] * t + b1[i]);
            for (long q = 0; q < outN; q++) { float s = b2[q]; for (long i = 0; i < hid; i++) s += w2[q * hid + i] * hv[i]; gv[q] = s; }
            r = constF(n, gv, shp({1, outN, 1, 1}));
            rs = {1, outN, 1, 1};
        } else if (is("film_modulate")) {
            ins(2);
            need(dim(n, in[1], 1) == 2 * c0 && dim(n, in[1], 2) == 1 && dim(n, in[1], 3) == 1, "the phase vector does not fit");
            T *sc = [g additionWithPrimaryTensor:sl(n, in[1], 1, 0, c0) secondaryTensor:scalar(n, 1) name:nil];
            r = [g additionWithPrimaryTensor:[g multiplicationWithPrimaryTensor:in[0] secondaryTensor:sc name:nil] secondaryTensor:sl(n, in[1], 1, c0, c0) name:nil];
        } else if (is("convex_upsample")) {
            ins(2); ws(2); sameHW(in[0], in[1]);
            r = convex(n, conv3(n, in[0], w[0], w[1], nil, 1), in[1]);
            rs = {1, dim(n, in[1], 1), 2 * h0, 2 * w0};
        } else if (is("blend_weights")) { // three weights -> the share of a and of b
            ins(1);
            need(c0 == 3 && o.count == 2, "blend weights of something else");
            T *p = [g softMaxWithTensor:in[0] axis:1 name:nil];
            T *h2 = [g multiplicationWithPrimaryTensor:sl(n, p, 1, 2, 1) secondaryTensor:scalar(n, 0.5) name:nil];
            n.env[o[0]] = setS(n, [g additionWithPrimaryTensor:sl(n, p, 1, 0, 1) secondaryTensor:h2 name:nil], {1, 1, h0, w0});
            n.env[o[1]] = setS(n, [g additionWithPrimaryTensor:sl(n, p, 1, 1, 1) secondaryTensor:h2 name:nil], {1, 1, h0, w0});
            continue;
        } else need(false, std::string("an op this build does not know: ") + name.UTF8String);
        n.env[o[0]] = setS(n, r, rs);
    }
}

// ---- one session: a picture size and a working size. generator thread only

static struct {
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> down, warp;
    CVMetalTextureCacheRef cache;
    MPSGraphExecutable *exe;
    NSArray<MPSGraphTensorData *> *feeds, *results;
    id<MTLBuffer> bufA, bufB, bufM;
    int w = 0, h = 0, wp, hp, iwp, ihp, hq, wq;
    bool up = false;
} gS;

static bool gSpinWait = false;

void stop() {
    gS.exe = nil; gS.feeds = gS.results = nil;
    gS.bufA = gS.bufB = gS.bufM = nil;
    if (gS.cache) CVMetalTextureCacheFlush(gS.cache, 0);
    gS.up = false;
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

bool generate(CVPixelBufferRef prev, CVPixelBufferRef cur, CVPixelBufferRef dst, bool full, bool sd) {
    if (!gS.up) return false;
    for (CVPixelBufferRef pb : {prev, cur, dst})
        if ((int)CVPixelBufferGetWidth(pb) != gS.w || (int)CVPixelBufferGetHeight(pb) != gS.h || CVPixelBufferGetPlaneCount(pb) != 2) return false;
    std::vector<CVMetalTextureRef> keep;
    id<MTLTexture> ay = plane(prev, 0, false, keep), ac = plane(prev, 1, false, keep), by = plane(cur, 0, false, keep), bc = plane(cur, 1, false, keep);
    id<MTLTexture> dy = plane(dst, 0, true, keep), dc = plane(dst, 1, true, keep);
    bool ok = ay && ac && by && bc && dy && dc;
    if (ok) {
        MPSCommandBuffer *cb = [MPSCommandBuffer commandBufferFromCommandQueue:gS.queue];
        struct { uint32_t w, h, iw, ih, ow, oh, full, sd; } dp = {(uint32_t)gS.w, (uint32_t)gS.h, (uint32_t)gS.wp, (uint32_t)gS.hp, (uint32_t)gS.iwp, (uint32_t)gS.ihp, full, sd};
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:gS.down];
        [e setBytes:&dp length:sizeof dp atIndex:1];
        for (int i = 0; i < 2; i++) {
            [e setTexture:i ? by : ay atIndex:0];
            [e setTexture:i ? bc : ac atIndex:1];
            [e setBuffer:i ? gS.bufB : gS.bufA offset:0 atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake((gS.iwp + 7) / 8, (gS.ihp + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        }
        [e endEncoding];
        [gS.exe encodeToCommandBuffer:cb inputsArray:gS.feeds resultsArray:gS.results executionDescriptor:nil];
        struct { uint32_t w, h, wp, hp, hq, wq, sub, full, sd; float fsx, fsy; } wp =
            {(uint32_t)gS.w, (uint32_t)gS.h, (uint32_t)gS.wp, (uint32_t)gS.hp, (uint32_t)gS.hq, (uint32_t)gS.wq, 1, full, sd, (float)gS.wp / gS.iwp, (float)gS.hp / gS.ihp};
        e = [cb computeCommandEncoder];
        [e setComputePipelineState:gS.warp];
        [e setBuffer:gS.bufM offset:0 atIndex:0];
        for (int i = 0; i < 2; i++) { // luma, then chroma at half size
            wp.sub = i + 1;
            [e setBytes:&wp length:sizeof wp atIndex:1];
            [e setTexture:i ? ac : ay atIndex:0]; [e setTexture:i ? bc : by atIndex:1]; [e setTexture:i ? dc : dy atIndex:2];
            [e dispatchThreadgroups:MTLSizeMake((gS.w / (i + 1) + 7) / 8, (gS.h / (i + 1) + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        }
        [e endEncoding];
        id<MTLCommandBuffer> last = gSpinWait ? cb.commandBuffer : nil; // what commit hands to the gpu
        [cb commit];
        // genSpinWait (hidden): watch the status instead of sleeping until woken. this thread spins between frames
        // anyway. a second at most, then something is wrong and it may as well sleep
        if (last) for (double t0 = nowSec(); last.status < MTLCommandBufferStatusCompleted && nowSec() - t0 < 1;) {}
        [cb waitUntilCompleted];
        ok = cb.status == MTLCommandBufferStatusCompleted;
    }
    for (CVMetalTextureRef t : keep) CFRelease(t);
    CVMetalTextureCacheFlush(gS.cache, 0); // or the cache keeps a texture per frame that went through
    return ok;
}

static CVPixelBufferRef blank(int w, int h) {
    NSDictionary *a = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pb);
    return pb;
}

bool start(int w, int h, int rung) {
    stop();
    if ([NSUserDefaults.standardUserDefaults objectForKey:@"genSpinWait"]) gSpinWait = [NSUserDefaults.standardUserDefaults boolForKey:@"genSpinWait"];
    @autoreleasepool {
        @try {
            try {
                need(w >= 64 && h >= 64 && w % 2 == 0 && h % 2 == 0 && w <= 8192 && h <= 8192, "picture size");
                if (!gS.dev) {
                    gS.dev = MTLCreateSystemDefaultDevice();
                    gS.queue = [gS.dev newCommandQueue];
                    NSError *err = nil;
                    id<MTLLibrary> lib = [gS.dev newLibraryWithSource:kKernels options:nil error:&err];
                    need(lib != nil, "its shaders did not compile");
                    gS.down = [gS.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"down"] error:&err];
                    gS.warp = [gS.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"warp"] error:&err];
                    need(gS.down && gS.warp, "its shaders did not compile");
                    CVMetalTextureCacheCreate(NULL, NULL, gS.dev, NULL, &gS.cache);
                    need(gS.cache != NULL, "no texture cache");
                }
                Net n;
                NSData *mj = [NSData dataWithContentsOfFile:[folder() stringByAppendingPathComponent:@"flyhighfg.json"]];
                NSData *gj = [NSData dataWithContentsOfFile:[folder() stringByAppendingPathComponent:@"graph.json"]];
                n.blob = [NSData dataWithContentsOfFile:[folder() stringByAppendingPathComponent:@"flyhighfg.bin"] options:NSDataReadingMappedIfSafe error:nil];
                need(mj && gj && n.blob, "a file could not be read");
                NSDictionary *man = [NSJSONSerialization JSONObjectWithData:mj options:0 error:nil], *graph = [NSJSONSerialization JSONObjectWithData:gj options:0 error:nil];
                need([man isKindOfClass:NSDictionary.class] && [man[@"tensors"] isKindOfClass:NSDictionary.class], "flyhighfg.json is not a tensor list");
                need([graph isKindOfClass:NSDictionary.class] && [graph[@"ops"] isKindOfClass:NSArray.class], "graph.json is not an op graph");
                n.tensors = man[@"tensors"];
                // the working sizes the net was made for: 848x480 and 1280x720, never above the picture, on a 32 grid
                int rw = rung >= 720 ? 1280 : 848, rh = rung >= 720 ? 720 : 480;
                gS.w = w; gS.h = h;
                gS.wp = (w + 31) / 32 * 32; gS.hp = (h + 31) / 32 * 32;
                gS.iwp = (std::min(rw, w) + 31) / 32 * 32; gS.ihp = (std::min(rh, h) + 31) / 32 * 32;
                // the last op names what the picture is put together from; the first two of those are the inputs
                NSArray *ops = graph[@"ops"];
                NSDictionary *last = [ops.lastObject isKindOfClass:NSDictionary.class] ? ops.lastObject : nil;
                NSArray<NSString *> *rin = last ? names(last, @"in") : @[];
                need(last && [last[@"op"] isEqual:@"render_pix"] && rin.count == 5, "graph.json does not end in a render of two frames and three maps");
                n.g = [MPSGraph new];
                n.env = [NSMutableDictionary dictionary];
                T *inA = [n.g placeholderWithShape:shp({1, 3, gS.ihp, gS.iwp}) dataType:DT name:nil];
                T *inB = [n.g placeholderWithShape:shp({1, 3, gS.ihp, gS.iwp}) dataType:DT name:nil];
                n.env[rin[0]] = setS(n, inA, {1, 3, gS.ihp, gS.iwp});
                n.env[rin[1]] = setS(n, inB, {1, 3, gS.ihp, gS.iwp});
                runOps(n, ops, 1, 0.5f);
                T *flow = n.env[rin[2]], *vis = n.env[rin[3]], *res = n.env[rin[4]];
                need(flow && vis && res, "graph.json does not make the maps its render reads");
                need(dim(n, flow, 1) == 4 && dim(n, vis, 1) == 3 && dim(n, res, 1) == 3, "the maps have other channels than expected");
                gS.hq = (int)dim(n, flow, 2); gS.wq = (int)dim(n, flow, 3);
                need(gS.hq > 0 && gS.wq > 0 && dim(n, vis, 2) == gS.hq && dim(n, vis, 3) == gS.wq && dim(n, res, 2) == gS.hq && dim(n, res, 3) == gS.wq, "the maps differ in size");
                T *out = [n.g concatTensors:@[flow, vis, res] dimension:1 name:nil];
                MPSGraphShapedType *st = [[MPSGraphShapedType alloc] initWithShape:shp({1, 3, gS.ihp, gS.iwp}) dataType:DT];
                gS.exe = [n.g compileWithDevice:[MPSGraphDevice deviceWithMTLDevice:gS.dev] feeds:@{inA: st, inB: st} targetTensors:@[out] targetOperations:nil compilationDescriptor:nil];
                need(gS.exe != nil, "the net did not compile");
                size_t inBytes = (size_t)3 * gS.ihp * gS.iwp * 2;
                gS.bufA = [gS.dev newBufferWithLength:inBytes options:MTLResourceStorageModeShared];
                gS.bufB = [gS.dev newBufferWithLength:inBytes options:MTLResourceStorageModeShared];
                gS.bufM = [gS.dev newBufferWithLength:(size_t)10 * gS.hq * gS.wq * 2 options:MTLResourceStorageModeShared];
                MPSGraphTensorData *dA = [[MPSGraphTensorData alloc] initWithMTLBuffer:gS.bufA shape:shp({1, 3, gS.ihp, gS.iwp}) dataType:DT];
                MPSGraphTensorData *dB = [[MPSGraphTensorData alloc] initWithMTLBuffer:gS.bufB shape:shp({1, 3, gS.ihp, gS.iwp}) dataType:DT];
                NSMutableArray *feeds = [NSMutableArray array];
                for (T *ft in gS.exe.feedTensors) [feeds addObject:ft == inA ? dA : dB];
                gS.feeds = feeds;
                gS.results = @[[[MPSGraphTensorData alloc] initWithMTLBuffer:gS.bufM shape:shp({1, 10, gS.hq, gS.wq}) dataType:DT]];
                gS.up = true;
                // once on nothing: the first run is where metal compiles the net's kernels
                CVPixelBufferRef a = blank(w, h), b = blank(w, h), d = blank(w, h);
                bool ran = a && b && d && generate(a, b, d, false, false);
                if (a) CFRelease(a);
                if (b) CFRelease(b);
                if (d) CFRelease(d);
                need(ran, "the first frame did not come out");
            } catch (const std::exception &e) {
                stop();
                refuse(e.what());
            }
        } @catch (NSException *e) {
            stop();
            refuse(e.reason.UTF8String ?: "the net could not be built");
        }
    }
    return gS.up;
}

}
