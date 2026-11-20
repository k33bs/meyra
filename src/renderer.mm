// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <MetalFX/MetalFX.h>
#include "renderer.h"
#include "common.h"
#include "framegen.h"
#include <atomic>
#include <cmath>
#include <os/lock.h>

namespace renderer {

static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLRenderPipelineState> gPipeYuv, gPipeNv, gPipeNvFix, gPipeOut, gPipeDeband, gPipeHud;
static CAMetalLayer *gLayer;
static CVMetalTextureCacheRef gCache;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static Stats gS;
static dispatch_semaphore_t gWake;
static std::atomic<double> gFrameDur{1.0 / 59.94};
static std::atomic<double> gScale{2};
static id<MTLTexture> gHudTex;            // under gLock
static NSString *gSnapPath;               // under gLock
static std::atomic<bool> gResetReq{false}, gClearReq{false}, gQuit{false};
static dispatch_semaphore_t gStopped;

// parked by the capture thread, under gLock
static CVPixelBufferRef gNewest;
static double gNewestArrival, gNewestCaptured;
static bool gNewestRepeat;

// levels: auto detection per source. video range never goes below 16, so a few frames in a row with a handful of
// luma samples under 10 means full range. the old rule wanted 1% of the samples dark, which a daylight scene never
// has: it sat on "video" for minutes with the darkest sample at 1. sticky once seen, kept across restarts of
// the same source
static const int kDarkLuma = 10, kDarkSamples = 3, kDarkFrames = 5; // of the 2048 sampled per frame
static std::atomic<bool> gFullSeen{false};
static std::atomic<int> gDarkFrames{0};
bool fullRange() { return gSet.levels == 2 || (gSet.levels == 0 && gFullSeen); }

// render thread only
static id<MTLTexture> gRgb, gUp, gFlat;
static id<MTLFXSpatialScaler> gScaler;
static size_t gSrcW, gSrcH, gFitW, gFitH;
static std::atomic<int> gInfoW{0}, gInfoH{0}, gInfoFitW{0}, gInfoFitH{0};
static std::atomic<bool> gInfoFx{false};
static CVPixelBufferPoolRef gNvPool;
static int gNvW, gNvH;

// adjacent real frames whose sparse luma difference is above this are not interpolated
static const double kMotionLimit = 40;
// after this many skipped pairs in a row (half a second) real frames go straight through, until this many calm ones
static const int kThroughAfter = 15, kCalmToLeave = 8;
static const double kEarlyWake = 0.0003;  // seconds: a timed present this close to due goes now rather than after another sleep

CAMetalLayer *layer() { return gLayer; }
void setScale(double s) { gScale = s > 0 ? s : 1; }
void setFrameDur(double s) { if (s > 0.001 && s < 1) gFrameDur = s; }

void lastSize(int &w, int &h, int &fw, int &fh, bool &fx) { w = gInfoW; h = gInfoH; fw = gInfoFitW; fh = gInfoFitH; fx = gInfoFx; }

void setHud(id<MTLTexture> t) {
    os_unfair_lock_lock(&gLock);
    gHudTex = t;
    os_unfair_lock_unlock(&gLock);
}

void snapshot(NSString *path) {
    os_unfair_lock_lock(&gLock);
    gSnapPath = path;
    os_unfair_lock_unlock(&gLock);
}

Stats takeStats() {
    os_unfair_lock_lock(&gLock);
    Stats s = gS;
    gS = Stats();
    os_unfair_lock_unlock(&gLock);
    CVMetalTextureCacheFlush(gCache, 0);
    return s;
}

static void bump(int Stats::*f) {
    os_unfair_lock_lock(&gLock);
    gS.*f += 1;
    os_unfair_lock_unlock(&gLock);
}

static id<MTLTexture> makeTex(size_t w, size_t h, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage = usage;
    d.storageMode = MTLStorageModePrivate;
    return [gDev newTextureWithDescriptor:d];
}

static void prepare(size_t srcW, size_t srcH, size_t fitW, size_t fitH) {
    if (gRgb && gSrcW == srcW && gSrcH == srcH && gFitW == fitW && gFitH == fitH) return;
    gSrcW = srcW; gSrcH = srcH; gFitW = fitW; gFitH = fitH;
    gScaler = nil; gUp = nil;
    MTLTextureUsage inUse = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (fitW > srcW && fitH > srcH) { // metalfx only scales up
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.inputWidth = srcW; d.inputHeight = srcH; d.outputWidth = fitW; d.outputHeight = fitH;
        d.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        gScaler = [d newSpatialScalerWithDevice:gDev];
        if (gScaler) {
            inUse |= gScaler.colorTextureUsage;
            gUp = makeTex(fitW, fitH, gScaler.outputTextureUsage | MTLTextureUsageShaderRead);
        }
    }
    gRgb = makeTex(srcW, srcH, inUse);
    gFlat = makeTex(srcW, srcH, inUse);
    gInfoW = (int)srcW; gInfoH = (int)srcH; gInfoFitW = (int)fitW; gInfoFitH = (int)fitH; gInfoFx = gScaler != nil;
    logLine("pipeline: %zux%zu -> on screen %zux%zu, metalfx %s", srcW, srcH, fitW, fitH, gScaler ? "ready" : "not needed");
}

static void pass(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> pipe, id<MTLTexture> src, id<MTLTexture> src2, id<MTLTexture> dst, MTLViewport vp,
                 const void *u, bool keepDst = false, id<MTLTexture> src3 = nil, id<MTLTexture> src4 = nil, id<MTLTexture> src5 = nil) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = keepDst ? MTLLoadActionLoad : MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pipe];
    [e setViewport:vp];
    if (u) [e setFragmentBytes:u length:16 atIndex:0]; // every uniform struct is four floats
    [e setFragmentTexture:src atIndex:0];
    if (src2) [e setFragmentTexture:src2 atIndex:1];
    if (src3) [e setFragmentTexture:src3 atIndex:2];
    if (src4) [e setFragmentTexture:src4 atIndex:3];
    if (src5) [e setFragmentTexture:src5 atIndex:4];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

static void savePng(id<MTLTexture> t, NSString *path) {
    size_t w = t.width, h = t.height;
    NSMutableData *px = [NSMutableData dataWithLength:w * h * 4];
    [t getBytes:px.mutableBytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, w, h, 8, w * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    bool ok = false;
    if (dst) { CGImageDestinationAddImage(dst, img, NULL); ok = CGImageDestinationFinalize(dst); CFRelease(dst); }
    CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    logLine("snapshot %zux%zu %s: %s", w, h, ok ? "saved" : "failed", path.UTF8String);
}

static void clearNow() {
    id<CAMetalDrawable> dr = [gLayer nextDrawable];
    if (!dr) return;
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dr.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb presentDrawable:dr];
    [cb commit];
}

// show one frame. pb is 2vuy from the source, or 420v (converted or generated).
// arrival > 0 marks a real frame, for the delay stats. borrows pb, retains what it needs.
// for a generated frame, `real` is the real frame its broken pixels get repaired from (null = no repair)
static void show(CVPixelBufferRef pb, double arrival, CVPixelBufferRef real = NULL, CVPixelBufferRef prevReal = NULL) {
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    bool nv = CVPixelBufferIsPlanar(pb);
    if (!nv && fmt != kCVPixelFormatType_422YpCbCr8) return; // sources only deliver 2vuy
    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
    CVMetalTextureRef t0 = NULL, t1 = NULL, r0 = NULL, r1 = NULL, p0 = NULL;
    if (real && prevReal) CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, prevReal, NULL, MTLPixelFormatR8Unorm, W, H, 0, &p0);
    if (real) {
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, real, NULL, MTLPixelFormatR8Unorm, W, H, 0, &r0);
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, real, NULL, MTLPixelFormatRG8Unorm, W / 2, H / 2, 1, &r1);
    }
    if (nv) {
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, NULL, MTLPixelFormatR8Unorm, W, H, 0, &t0);
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, NULL, MTLPixelFormatRG8Unorm, W / 2, H / 2, 1, &t1);
    } else {
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, NULL, MTLPixelFormatBGRG422, W, H, 0, &t0);
    }
    auto drop = [&] { if (t0) CFRelease(t0); if (t1) CFRelease(t1); if (r0) CFRelease(r0); if (r1) CFRelease(r1); if (p0) CFRelease(p0); };
    if (!t0 || (nv && !t1)) { drop(); return; }
    double tdr = nowSec();
    id<CAMetalDrawable> dr = [gLayer nextDrawable]; // may block, fine on this thread
    tdr = (nowSec() - tdr) * 1000;
    os_unfair_lock_lock(&gLock);
    if (tdr > gS.drawableMax) gS.drawableMax = tdr;
    NSString *snapPath = gSnapPath;
    gSnapPath = nil;
    id<MTLTexture> hud = gSet.overlay ? gHudTex : nil;
    os_unfair_lock_unlock(&gLock);
    if (!dr) { drop(); return; }

    size_t dw = dr.texture.width, dh = dr.texture.height;
    size_t fw = dw, fh = dw * H / W;
    if (fh > dh) { fh = dh; fw = dh * W / H; }
    fw &= ~(size_t)1; fh &= ~(size_t)1;
    if (fw < 2 || fh < 2) { drop(); return; }
    prepare(W, H, fw, fh);
    if (!gRgb || !gFlat) { drop(); return; }

    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    MTLViewport full = {0, 0, (double)W, (double)H, 0, 1};
    float lv[4] = {fullRange() ? 1.0f : 0.0f, p0 ? 1.0f : 0.0f, 1.5f / 255, 0}; // levels, still-area rule on, how close counts as unchanged
    if (nv && r0 && r1) pass(cb, gPipeNvFix, CVMetalTextureGetTexture(t0), CVMetalTextureGetTexture(t1), gRgb, full, lv, false, CVMetalTextureGetTexture(r0), CVMetalTextureGetTexture(r1), p0 ? CVMetalTextureGetTexture(p0) : CVMetalTextureGetTexture(r0));
    else if (nv) pass(cb, gPipeNv, CVMetalTextureGetTexture(t0), CVMetalTextureGetTexture(t1), gRgb, full, lv);
    else pass(cb, gPipeYuv, CVMetalTextureGetTexture(t0), nil, gRgb, full, lv);
    id<MTLTexture> src = gRgb;
    if (effDeband()) {
        float db[4] = {1.0f / W, 1.0f / H, 2.5f / 255, 0};
        pass(cb, gPipeDeband, src, nil, gFlat, full, db);
        src = gFlat;
    }
    if (effUpscale() == 1 && gScaler) {
        gScaler.colorTexture = src;
        gScaler.outputTexture = gUp;
        [gScaler encodeToCommandBuffer:cb];
        src = gUp;
    }
    MTLViewport vp = {(double)((dw - fw) / 2), (double)((dh - fh) / 2), (double)fw, (double)fh, 0, 1};
    float u[4] = {1.0f / src.width, 1.0f / src.height, effSharpen(), 0};
    pass(cb, gPipeOut, src, nil, dr.texture, vp, u);
    id<MTLTexture> fin = nil;
    if (snapPath) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:fw height:fh mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        fin = [gDev newTextureWithDescriptor:d];
        if (fin) pass(cb, gPipeOut, src, nil, fin, (MTLViewport){0, 0, (double)fw, (double)fh, 0, 1}, u);
    }
    if (hud) {
        double m = 12 * gScale;
        double hw = fmin((double)hud.width, fw - m), hh = fmin((double)hud.height, fh - m);
        if (hw > 0 && hh > 0)
            pass(cb, gPipeHud, hud, nil, dr.texture, (MTLViewport){vp.originX + m, vp.originY + m, (double)hud.width, (double)hud.height, 0, 1}, NULL, true);
    }

    // every frame: when did it really reach the screen. counts alone can look perfect while the spacing is not
    double dur = gFrameDur;
    [dr addPresentedHandler:^(id<MTLDrawable> d) {
        static std::atomic<double> last{0};
        double pt = d.presentedTime;
        os_unfair_lock_lock(&gLock);
        if (pt <= 0) gS.notShown++;
        else {
            double prev = last.exchange(pt), gap = (pt - prev) * 1000;
            // off the source's frame grid by more than 4.5 ms. a whole number of frame times is fine: skipped repeats
            double steps = fmax(1, round(gap / (dur * 1000)));
            if (prev > 0 && gap > 0 && gap < 500) { gS.gapN++; if (fabs(gap - steps * dur * 1000) > 4.5) gS.gapBad++; if (gap > gS.gapMax) gS.gapMax = gap; }
            if (arrival > 0) {
                double g = (pt - arrival) * 1000;
                gS.shown++; gS.toGlassSum += g; gS.toGlassN++;
                if (g > gS.toGlassMax) gS.toGlassMax = g;
                if (g < gS.toGlassMin) gS.toGlassMin = g;
            }
        }
        os_unfair_lock_unlock(&gLock);
    }];
    CFRetain(pb); // the frame's memory must outlive the gpu work
    if (real) CFRetain(real);
    if (prevReal) CFRetain(prevReal);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        double gpu = (c.GPUEndTime - c.GPUStartTime) * 1000;
        os_unfair_lock_lock(&gLock);
        gS.gpuSum += gpu; gS.gpuN++;
        if (gpu > gS.gpuMax) gS.gpuMax = gpu;
        os_unfair_lock_unlock(&gLock);
        CFRelease(t0);
        if (t1) CFRelease(t1);
        if (r0) CFRelease(r0);
        if (r1) CFRelease(r1);
        if (p0) CFRelease(p0);
        if (prevReal) CFRelease(prevReal);
        if (real) CFRelease(real);
        CFRelease(pb);
        if (fin) savePng(fin, snapPath);
    }];
    [cb presentDrawable:dr];
    [cb commit];
    os_unfair_lock_lock(&gLock);
    gS.drawn++;
    if (arrival > 0) { gS.toPresSum += (nowSec() - arrival) * 1000; gS.toPresN++; }
    os_unfair_lock_unlock(&gLock);
}

// the interpolator only takes 420v. 2vuy in, +1 out. cpu loop, about a millisecond at 1080p
static CVPixelBufferRef toNV(CVPixelBufferRef src) {
    double t = nowSec();
    int W = (int)CVPixelBufferGetWidth(src), H = (int)CVPixelBufferGetHeight(src);
    if (!gNvPool || gNvW != W || gNvH != H) {
        if (gNvPool) CVPixelBufferPoolRelease(gNvPool);
        gNvPool = NULL;
        NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                            (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &gNvPool);
        gNvW = W; gNvH = H;
    }
    CVPixelBufferRef nv = NULL;
    if (!gNvPool || CVPixelBufferPoolCreatePixelBuffer(NULL, gNvPool, &nv) != kCVReturnSuccess) return NULL;
    tag709(nv);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(nv, 0);
    const uint8_t *s = (const uint8_t *)CVPixelBufferGetBaseAddress(src);
    size_t srb = CVPixelBufferGetBytesPerRow(src);
    uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv, 0), *c = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv, 1);
    size_t yrb = CVPixelBufferGetBytesPerRowOfPlane(nv, 0), crb = CVPixelBufferGetBytesPerRowOfPlane(nv, 1);
    for (int r = 0; r < H; r++) {
        const uint8_t *sr = s + r * srb;
        uint8_t *yr = y + r * yrb;
        for (int x = 0; x < W; x++) yr[x] = sr[2 * x + 1];
    }
    for (int r = 0; r < H / 2; r++) {
        const uint8_t *s0 = s + (2 * r) * srb, *s1 = s0 + srb;
        uint8_t *cr = c + r * crb;
        for (int x = 0; x < W; x++) cr[x] = (uint8_t)((s0[2 * x] + s1[2 * x] + 1) >> 1); // u v u v, rows averaged in pairs
    }
    CVPixelBufferUnlockBaseAddress(nv, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    os_unfair_lock_lock(&gLock);
    gS.convSum += (nowSec() - t) * 1000; gS.convN++;
    os_unfair_lock_unlock(&gLock);
    return nv;
}

static double lumaDiff(CVPixelBufferRef a, CVPixelBufferRef b) {
    int W = (int)CVPixelBufferGetWidth(a), H = (int)CVPixelBufferGetHeight(a);
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);
    size_t rb = CVPixelBufferGetBytesPerRowOfPlane(a, 0);
    long sum = 0, n = 0;
    for (int r = 4; r < H; r += 9)
        for (int x = 4; x < W; x += 13) { sum += abs(pa[r * rb + x] - pb[r * rb + x]); n++; }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return n ? (double)sum / n : 0;
}

// frame scheduling, render thread only.
// tick schedule: on a new real frame show the previous real one and start generating; on the repeat tick show the
//   generated frame. real frames reach the screen one frame pair (33.4 ms) after they arrive.
// early schedule: the generated frame goes up as soon as it can be expected to exist (budget: how long the generator
//   has recently needed, plus a margin), the real frame one frame time after that. same even spacing, less delay.
//   needs timed presents, hence gNextDue and the realtime render thread.
static CVPixelBufferRef prevNv, curNv; // newest real frame already on screen, and the one waiting behind the generated frame
static double prevArrival, curArrival;
static int newRun, repeatRun;
static bool genAsked;
static bool early;                     // schedule the held frames were planned under
static double gMidDue, gRealDue, gNextDue;
static int skipRun, calmRun;
static bool through;

static void dropHeld() {
    if (prevNv) { CFRelease(prevNv); prevNv = NULL; }
    if (curNv) { CFRelease(curNv); curNv = NULL; }
    newRun = repeatRun = 0; genAsked = false;
    gMidDue = gRealDue = gNextDue = 0;
    skipRun = calmRun = 0; through = false;
}

static CVPixelBufferRef takeMid(double graceMs) {
    if (!genAsked) return NULL;
    CVPixelBufferRef mid = framegen::take(graceMs);
    if (mid) bump(&Stats::gen); else bump(&Stats::genLate);
    return mid;
}

// early schedule: present whatever has come due
static void runDue() {
    double now = nowSec();
    if (gMidDue > 0 && now >= gMidDue - kEarlyWake) {
        os_unfair_lock_lock(&gLock);
        double late = (now - gMidDue) * 1000;
        if (late > gS.schedLateMax) gS.schedLateMax = late;
        os_unfair_lock_unlock(&gLock);
        CVPixelBufferRef mid = takeMid(1.5);
        if (mid) { show(mid, 0, curNv, prevNv); CFRelease(mid); }
        gMidDue = 0;
        now = nowSec();
    }
    if (gRealDue > 0 && now >= gRealDue - kEarlyWake) {
        if (curNv) {
            show(curNv, curArrival);
            if (prevNv) CFRelease(prevNv);
            prevNv = curNv; prevArrival = curArrival; curNv = NULL;
        }
        gRealDue = 0;
    }
    gNextDue = gMidDue > 0 ? gMidDue : gRealDue;
}

// one capture tick. owns pb.
static void tick(CVPixelBufferRef pb, double arrival, bool repeat) {
    if (early != gSet.early.load()) { // the two schedules keep different promises: start clean
        dropHeld();
        early = gSet.early;
    }
    // frame generation needs yuv 4:2:2 input at an even size the interpolator accepts
    bool genOk = effFrameGen() && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8 &&
                 framegen::ready((int)CVPixelBufferGetWidth(pb), (int)CVPixelBufferGetHeight(pb));
    if (prevNv && (CVPixelBufferGetWidth(prevNv) != CVPixelBufferGetWidth(pb) || CVPixelBufferGetHeight(prevNv) != CVPixelBufferGetHeight(pb))) dropHeld();
    if (!genOk) {
        if (prevNv || curNv) { framegen::cancel(); dropHeld(); }
        // a repeat is the picture already on screen. presenting it anyway fills the display's queue: at a 60 hz screen
        // we then submit exactly as fast as it drains, a backlog from start-up never clears, and passthrough ends up
        // two refreshes slower than frame generation. so skip repeats, except to refresh now and then (overlay,
        // resize, a paused source)
        static double lastShow; static CGSize lastSize;
        double now = CACurrentMediaTime();
        CGSize sz = gLayer.drawableSize;
        if (repeat && now - lastShow < 0.1 && CGSizeEqualToSize(sz, lastSize)) { CFRelease(pb); return; }
        lastShow = now; lastSize = sz;
        show(pb, repeat ? 0 : arrival);
        CFRelease(pb);
        return;
    }
    if (!repeat) {
        CVPixelBufferRef nv = toNV(pb);
        CFRelease(pb);
        if (!nv) return;
        newRun++; repeatRun = 0;
        if (curNv) { // previous real frame never got its turn: the source is running at 60, not 30
            if (prevNv) CFRelease(prevNv);
            prevNv = curNv; prevArrival = curArrival; curNv = NULL;
        }
        if (newRun >= 2 || !prevNv) { // 60 fps content (menus), or the very first frame: nothing to generate, show it straight
            if (prevNv) CFRelease(prevNv);
            prevNv = nv; prevArrival = arrival;
            genAsked = false;
            gMidDue = gRealDue = gNextDue = 0;
            show(prevNv, arrival);
            return;
        }
        // normal 30 fps case: hold the new frame and start on the middle
        bool calm = lumaDiff(prevNv, nv) <= kMotionLimit;
        skipRun = calm ? 0 : skipRun + 1;
        calmRun = calm ? calmRun + 1 : 0;
        // nothing is being generated for a while (very fast motion): waiting a frame pair then only costs delay.
        // after half a second of that, pass real frames straight through until motion has been calm again for a bit
        if (!through && skipRun >= kThroughAfter) through = true;
        if (through && calmRun >= kCalmToLeave) through = false;
        if (through) {
            if (prevNv) CFRelease(prevNv);
            prevNv = nv; prevArrival = arrival;
            genAsked = false;
            gMidDue = gRealDue = gNextDue = 0;
            bump(&Stats::genSkipped);
            show(prevNv, arrival);
            return;
        }
        curNv = nv; curArrival = arrival;
        genAsked = calm;
        if (genAsked) framegen::request(prevNv, curNv);
        else bump(&Stats::genSkipped);
        if (early) {
            double budget = fmin(15.0, fmax(12.0, framegen::peakMs() + 2.5)) / 1000; // 1.5 ms of margin left 1% of generated frames late live
            gMidDue = arrival + budget;
            gRealDue = gMidDue + gFrameDur.load();
            gNextDue = gMidDue;
            return; // the previous real frame went up at its own due time
        }
        show(prevNv, prevArrival); // a real frame, one tick pair after it arrived
        return;
    }
    CFRelease(pb); // exact copy of what we already have
    newRun = 0; repeatRun++;
    if (early) return; // timed presents take care of the held frames
    if (repeatRun == 1 && curNv) {
        CVPixelBufferRef mid = takeMid(2);
        if (mid) { show(mid, 0, curNv, prevNv); CFRelease(mid); }
        else show(prevNv, 0); // not ready or skipped: same as the console would have shown
        if (prevNv) CFRelease(prevNv);
        prevNv = curNv; prevArrival = curArrival; curNv = NULL;
        return;
    }
    if (prevNv) show(prevNv, repeatRun == 2 ? prevArrival : 0); // game dropped a frame, hold the newest real one
}

// analysis on the capture thread: repeats, rolled frames, levels

// luma samples of a frame, whatever its layout
struct Luma {
    const uint8_t *base = nullptr; size_t rb = 0; int step = 1, off = 0, w = 0, h = 0;
    uint8_t at(int x, int y) const { return base[(size_t)y * rb + (size_t)x * step + off]; }
};
static bool lockLuma(CVPixelBufferRef pb, Luma &l) {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
    l.w = (int)CVPixelBufferGetWidth(pb); l.h = (int)CVPixelBufferGetHeight(pb);
    if (CVPixelBufferIsPlanar(pb)) { l.base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0); l.rb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0); }
    else { l.base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb); l.rb = CVPixelBufferGetBytesPerRow(pb); l.step = 2; l.off = 1; } // 2vuy: u y v y
    if (!l.base || l.w < 64 || l.h < 64) { CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly); return false; }
    return true;
}

// sparse fingerprint. a console's repeated frames are identical apart from, now and then, a handful of bytes, so a
// sparse sample is both cheaper and more forgiving than comparing everything
struct Sig { uint8_t b[2048]; };
static const int kRepeatSlack = 10; // of 2048 samples. a small overlay element updating at 60 must not make every frame look new
// rolled frames: now and then a frame arrives with the picture shifted vertically with wrap-around (the bottom of the
// image at the top), from a bad hdmi connection. detect by matching a per-row luma profile against the previous
// frame's at a large circular shift, and drop the frame instead of showing it
static const int kRows = 270;
struct Profile { float v[kRows]; };

static Sig gSig; static bool gHaveSig;
static Profile gProf; static bool gHaveProf;

static void analyse(const Luma &l, Sig &g, Profile &p, int &dark, int &darkest) {
    long n = (long)l.w * l.h, step = n / (long)sizeof g.b;
    dark = 0; darkest = 255;
    for (size_t i = 0; i < sizeof g.b; i++) {
        long k = (long)i * step;
        g.b[i] = l.at((int)(k % l.w), (int)(k / l.w));
        dark += g.b[i] < kDarkLuma;
        if (g.b[i] < darkest) darkest = g.b[i];
    }
    for (int i = 0; i < kRows; i++) {
        int y = (int)((long)i * l.h / kRows), sum = 0;
        for (int k = 0; k < 16; k++) sum += l.at(l.w / 32 + k * l.w / 16, y);
        p.v[i] = sum / 16.0f;
    }
}

// profile distance in luma levels (0-255) below which two frames count as the same picture, and the shifts searched:
// a rolled frame is shifted by a large part of the height, never by a few rows
static const float kSameProfile = 6;
static const int kRollMin = 30, kRollMax = 240; // of kRows
static int rollOf(const Profile &cur, const Profile &prev) {
    auto sad = [&](int sh) { float t = 0; for (int i = 0; i < kRows; i++) t += fabsf(cur.v[(i + sh) % kRows] - prev.v[i]); return t / kRows; };
    float same = sad(0);
    if (same < kSameProfile) return 0; // looks like the previous frame where it is
    float best = 1e9; int at = 0;
    for (int sh = kRollMin; sh <= kRollMax; sh++) { float t = sad(sh); if (t < best) { best = t; at = sh; } }
    return (best < same * 0.3f && best < kSameProfile) ? at : 0; // the shifted match must be clearly better
}

void submit(CVPixelBufferRef pb, double arrival, double captured, bool late) {
    Luma l;
    bool repeat = false;
    int darkest = 255;
    if (lockLuma(pb, l)) {
        Sig g; Profile p; int dark;
        analyse(l, g, p, dark, darkest);
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        if (gHaveProf && rollOf(p, gProf)) { // screen keeps the last good frame
            bump(&Stats::rolled);
            CFRelease(pb);
            return;
        }
        gProf = p; gHaveProf = true;
        if (dark < kDarkSamples) gDarkFrames = 0; // in a row: stray undershoot on a video range source must not add up
        else if (++gDarkFrames >= kDarkFrames) gFullSeen = true;
        int nd = 9999;
        if (gHaveSig) { nd = 0; for (size_t i = 0; i < sizeof g.b; i++) nd += g.b[i] != gSig.b[i]; }
        repeat = nd <= kRepeatSlack;
        gSig = g; gHaveSig = true;
        if (repeat && nd > 0) bump(&Stats::nearRepeats);
    }
    os_unfair_lock_lock(&gLock);
    gS.in++;
    if (darkest < gS.darkest) gS.darkest = darkest;
    if (repeat) gS.repeats++; else gS.real++;
    if (late) gS.late++;
    if (captured > 0 && arrival > captured) { gS.lagSum += (arrival - captured) * 1000; gS.lagN++; }
    CVPixelBufferRef old = gNewest;
    gNewest = pb; gNewestArrival = arrival; gNewestCaptured = captured; gNewestRepeat = repeat;
    if (old) gS.superseded++;
    os_unfair_lock_unlock(&gLock);
    if (old) CFRelease(old);
    dispatch_semaphore_signal(gWake);
}

void noSignalFrame() { bump(&Stats::nosignal); }

void beginSource(double frameDur, bool sameSource) {
    gHaveSig = gHaveProf = false;
    if (!sameSource) { gFullSeen = false; gDarkFrames = 0; }
    setFrameDur(frameDur);
    os_unfair_lock_lock(&gLock);
    CVPixelBufferRef old = gNewest;
    gNewest = NULL;
    os_unfair_lock_unlock(&gLock);
    if (old) CFRelease(old);
    gResetReq = true;
    dispatch_semaphore_signal(gWake);
}

void clear() {
    gClearReq = true;
    dispatch_semaphore_signal(gWake);
}

void startThread() {
    gStopped = dispatch_semaphore_create(0);
    NSThread *th = [[NSThread alloc] initWithBlock:^{
        makeRealtime(1 / 59.94); // timed presents need on-time wake-ups, ordinary threads get them a frame late
        while (!gQuit) {
            if (gNextDue > 0) {
                double w = gNextDue - nowSec();
                if (w > 0) dispatch_semaphore_wait(gWake, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(w * NSEC_PER_SEC)));
            } else dispatch_semaphore_wait(gWake, DISPATCH_TIME_FOREVER);
            @autoreleasepool {
                if (gResetReq.exchange(false)) { framegen::cancel(); dropHeld(); }
                os_unfair_lock_lock(&gLock);
                CVPixelBufferRef pb = gNewest;
                double arrival = gNewestArrival;
                bool repeat = gNewestRepeat;
                gNewest = NULL;
                os_unfair_lock_unlock(&gLock);
                if (gClearReq.exchange(false) && !pb) { framegen::cancel(); dropHeld(); clearNow(); }
                double t = nowSec();
                if (pb) tick(pb, arrival, repeat);
                if (gNextDue > 0) runDue();
                double ms = (nowSec() - t) * 1000;
                os_unfair_lock_lock(&gLock);
                if (ms > gS.tickMax) gS.tickMax = ms;
                os_unfair_lock_unlock(&gLock);
            }
        }
        framegen::cancel();
        dropHeld();
        dispatch_semaphore_signal(gStopped);
    }];
    th.qualityOfService = NSQualityOfServiceUserInteractive;
    th.name = @"render";
    [th start];
}

void stopThread() {
    if (!gStopped || gQuit.exchange(true)) return;
    dispatch_semaphore_signal(gWake);
    dispatch_semaphore_wait(gStopped, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    os_unfair_lock_lock(&gLock);
    CVPixelBufferRef pb = gNewest;
    gNewest = NULL;
    os_unfair_lock_unlock(&gLock);
    if (pb) CFRelease(pb);
}

bool init(NSString *shaderSource, std::string &err) {
    gDev = MTLCreateSystemDefaultDevice();
    if (!gDev) { err = "no metal device"; return false; }
    gQueue = [gDev newCommandQueue];
    if (!gQueue) { err = "no metal command queue"; return false; }
    gWake = dispatch_semaphore_create(0);
    NSError *e = nil;
    id<MTLLibrary> lib = [gDev newLibraryWithSource:shaderSource options:nil error:&e];
    if (!lib) { err = std::string("shaders: ") + (e.localizedDescription.UTF8String ?: "?"); return false; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> __strong *pipes[] = {&gPipeYuv, &gPipeNv, &gPipeNvFix, &gPipeOut, &gPipeDeband};
    NSString *names[] = {@"fsYuv", @"fsNv", @"fsNvFix", @"fsOut", @"fsDeband"};
    for (int i = 0; i < 5; i++) {
        pd.fragmentFunction = [lib newFunctionWithName:names[i]];
        *pipes[i] = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!*pipes[i]) { err = std::string("pipeline ") + names[i].UTF8String; return false; }
    }
    pd.fragmentFunction = [lib newFunctionWithName:@"fsHud"];
    pd.colorAttachments[0].blendingEnabled = YES; // premultiplied over
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    gPipeHud = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeHud) { err = "pipeline fsHud"; return false; }
    if (CVMetalTextureCacheCreate(NULL, NULL, gDev, NULL, &gCache) != kCVReturnSuccess) { err = "no metal texture cache"; return false; }

    gLayer = [CAMetalLayer layer];
    gLayer.device = gDev;
    gLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    gLayer.framebufferOnly = YES;
    gLayer.opaque = YES;
    gLayer.maximumDrawableCount = 3;
    gLayer.displaySyncEnabled = YES; // off is ~5 ms faster but tears
    gLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    gLayer.colorspace = cs;
    CGColorSpaceRelease(cs);
    return true;
}

}
