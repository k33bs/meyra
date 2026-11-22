// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <MetalFX/MetalFX.h>
#include "display.h"
#include "renderer.h"
#include "common.h"
#include "framegen.h"
#include "superres.h"
#include <array>
#include <atomic>
#include <cmath>
#include <os/lock.h>

namespace renderer {

static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLRenderPipelineState> gPipeYuv, gPipeNv, gPipeNvFix, gPipeOut, gPipeDeband, gPipeHud, gPipeEasu, gPipeSgsr, gPipeTiles, gPipeTileY, gPipeTileC;
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
static bool gNewestRepeat, gNewestChanged;

// levels: auto detection per source. video range never goes below 16, so a few frames in a row with a handful of
// luma samples under 10 means full range. the old rule wanted 1% of the samples dark, which a daylight scene never
// has: it sat on "video" for minutes with the darkest sample at 1. sticky once seen, kept across restarts of
// the same source
static const int kDarkLuma = 10, kDarkSamples = 3, kDarkFrames = 5; // of the 2048 sampled per frame
static std::atomic<bool> gFullSeen{false};
static std::atomic<int> gDarkFrames{0};
static std::atomic<double> gQueueLag{0};   // from handing a frame to the display to it being on screen, last frame
static std::atomic<double> gLevelsFrom{0}; // no verdict before this time
// the signal's format changed: a new verdict, and not from the changeover itself. an xbox going to 720p sent ~6 s
// with samples at 1 and then a video range picture, which stuck on "full" and looked washed out. 15 s is how long
// its "keep this resolution?" question can stand
void signalChanged() { gFullSeen = false; gDarkFrames = 0; gLevelsFrom = nowSec() + 15; }
bool fullRange() { return gSet.levels == 2 || (gSet.levels == 0 && gFullSeen); }

// render thread only
static id<MTLTexture> gRgb, gUp, gFlat, gSrOut, gEdge;
static std::atomic<bool> gDeepNow{false}; // the in-turns schedule is on, for the overlay
bool deepNow() { return gDeepNow; }
static bool gSrCan;             // apple super resolution has something to do and is up (picture larger than the source, session ready)
static CVPixelBufferRef gSrFor; // the frame whose scaled picture gSrOut holds, scaled ahead of its turn. not retained, only compared
static id<MTLFXSpatialScaler> gScaler;
static size_t gSrcW, gSrcH, gFitW, gFitH;
static std::atomic<int> gInfoW{0}, gInfoH{0}, gInfoFitW{0}, gInfoFitH{0}, gInfoUp{0};
static CVPixelBufferPoolRef gNvPool;
static int gNvW, gNvH;

// adjacent real frames whose sparse luma difference is above this are not interpolated
static const double kMotionLimit = 40;
// after this many skipped pairs in a row (half a second) real frames go straight through, until this many calm ones
static const int kThroughAfter = 15, kCalmToLeave = 8;
static const double kEarlyWake = 0.0003;  // seconds: a timed present this close to due goes now rather than after another sleep
// apple super resolution: how long a frame waits for the scaler before it goes through metalfx instead.
// sharpening after it stays at the setting: its output is softer than metalfx's, not harsher (compared at 0, 0.6, 1)
static const double kSrLateMs = 12;

CAMetalLayer *layer() { return gLayer; }
void setScale(double s) { gScale = s > 0 ? s : 1; }
// the layer's colour space tells macos what the numbers mean. bt.709 is what the source says they are, but macos
// reads its tone curve as a camera's and the picture comes out flatter than on a tv. srgb gives the contrast a tv
// has. none at all leaves the numbers to the screen: most saturated, and different on every screen
void applyColour() {
    int c = gSet.colour;
    CGColorSpaceRef cs = c == 2 ? NULL : CGColorSpaceCreateWithName(c == 1 ? kCGColorSpaceSRGB : kCGColorSpaceITUR_709);
    gLayer.colorspace = cs;
    if (cs) CGColorSpaceRelease(cs);
}

void setFrameDur(double s) { if (s > 0.001 && s < 1) gFrameDur = s; }

void lastSize(int &w, int &h, int &fw, int &fh, int &up) { w = gInfoW; h = gInfoH; fw = gInfoFitW; fh = gInfoFitH; up = gInfoUp; }

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
    gScaler = nil; gUp = nil; gSrOut = nil; gEdge = nil;
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
    gInfoW = (int)srcW; gInfoH = (int)srcH; gInfoFitW = (int)fitW; gInfoFitH = (int)fitH;
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

static CVMetalTextureRef plane(CVPixelBufferRef pb, int i, bool target) {
    NSDictionary *a = target ? @{(id)kCVMetalTextureUsage: @(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)} : nil;
    CVMetalTextureRef t = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, (__bridge CFDictionaryRef)a, i ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
                                              CVPixelBufferGetWidthOfPlane(pb, i), CVPixelBufferGetHeightOfPlane(pb, i), i, &t);
    return t;
}

// apple super resolution for one frame: src out as 420v tiles, through the scaler, back together into gSrOut at fit
// size. the scaler needs the tiles drawn first, so cb is committed and replaced. false = busy, late or broken, the
// caller scales some other way. adds its own releases to the (new) cb
static bool superScale(id<MTLCommandBuffer> __strong &cb, id<MTLTexture> src, size_t W, size_t fw, size_t fh) {
    CVPixelBufferRef tl[2], sr[2];
    if (superres::busy() || !superres::buffers(tl)) { bump(&Stats::srLate); return false; }
    superres::Tiles t = superres::tiles();
    double cw = t.w - 2.0 * t.pad, H = t.h - 2.0 * t.pad; // the part of a tile that is picture
    bool ok = true;
    for (int i = 0; i < t.n; i++) {
        CVMetalTextureRef y = plane(tl[i], 0, true), c = plane(tl[i], 1, true);
        ok = ok && y && c;
        if (ok) {
            float u[4] = {(float)((i ? t.x1 : 0) - t.pad) / W, (float)t.w / W, (float)(-t.pad / H), (float)(t.h / H)};
            pass(cb, gPipeTileY, src, nil, CVMetalTextureGetTexture(y), (MTLViewport){0, 0, (double)t.w, (double)t.h, 0, 1}, u);
            pass(cb, gPipeTileC, src, nil, CVMetalTextureGetTexture(c), (MTLViewport){0, 0, t.w / 2.0, t.h / 2.0, 0, 1}, u);
        }
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) { if (y) CFRelease(y); if (c) CFRelease(c); }];
    }
    if (!ok) { for (int i = 0; i < t.n; i++) CFRelease(tl[i]); return false; }
    [cb commit];
    superres::request(tl, cb);
    cb = [gQueue commandBuffer];
    if (!superres::take(kSrLateMs, sr)) { bump(&Stats::srLate); return false; }
    std::array<CVMetalTextureRef, 4> p = {plane(sr[0], 0, false), plane(sr[0], 1, false), t.n > 1 ? plane(sr[1], 0, false) : NULL, t.n > 1 ? plane(sr[1], 1, false) : NULL};
    if (!gSrOut) gSrOut = makeTex(fw, fh, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    ok = gSrOut && p[0] && p[1] && (t.n == 1 || (p[2] && p[3]));
    if (ok) {
        // tile width, second tile's left edge (0: one tile), padding across and down, all as parts of the picture
        float u[4] = {(float)(cw / W), t.n > 1 ? (float)t.x1 / W : 0, (float)t.pad / W, (float)(t.pad / H)};
        id<MTLTexture> y0 = CVMetalTextureGetTexture(p[0]), c0 = CVMetalTextureGetTexture(p[1]);
        id<MTLTexture> y1 = t.n > 1 ? CVMetalTextureGetTexture(p[2]) : y0, c1 = t.n > 1 ? CVMetalTextureGetTexture(p[3]) : c0;
        pass(cb, gPipeTiles, y0, c0, gSrOut, (MTLViewport){0, 0, (double)fw, (double)fh, 0, 1}, u, false, y1, c1);
    }
    CVPixelBufferRef s0 = sr[0], s1 = sr[1];
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { for (auto x : p) if (x) CFRelease(x); CFRelease(s0); if (s1) CFRelease(s1); }];
    return ok;
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

// sd sources (480 / 576 lines) are bt.601, unless the buffer says 709. a 601 tag on an hd buffer is not followed:
// usb devices put it there by default
static bool gSd;
static bool is601(CVPixelBufferRef pb) {
    CFTypeRef m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
    bool sd = CVPixelBufferGetHeight(pb) <= 576 && !(m && CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2));
    if (m) CFRelease(m);
    return sd;
}

// show one frame. pb is 2vuy from the source, or 420v (converted or generated).
// arrival > 0 marks a real frame, for the delay stats. borrows pb, retains what it needs.
// for a generated frame, `real` is the real frame its broken pixels get repaired from (null = no repair)
// onlyScale: run apple super resolution for this frame now and keep the result for when it is shown, present nothing
static void show(CVPixelBufferRef pb, double arrival, CVPixelBufferRef real = NULL, CVPixelBufferRef prevReal = NULL, bool onlyScale = false) {
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
    id<CAMetalDrawable> dr = onlyScale ? nil : [gLayer nextDrawable]; // may block, fine on this thread
    tdr = (nowSec() - tdr) * 1000;
    os_unfair_lock_lock(&gLock);
    if (tdr > gS.drawableMax) gS.drawableMax = tdr;
    NSString *snapPath = onlyScale ? nil : gSnapPath; // a pass that draws nothing must not eat the snapshot
    if (!onlyScale) gSnapPath = nil;
    id<MTLTexture> hud = gSet.overlay ? gHudTex : nil;
    os_unfair_lock_unlock(&gLock);
    if (!dr && !(onlyScale && gFitW)) { drop(); return; }

    size_t dw = dr ? dr.texture.width : gFitW, dh = dr ? dr.texture.height : gFitH;
    size_t fw = dw, fh = dw * H / W;
    if (fh > dh) { fh = dh; fw = dh * W / H; }
    fw &= ~(size_t)1; fh &= ~(size_t)1;
    if (fw < 2 || fh < 2) { drop(); return; }
    prepare(W, H, fw, fh);
    if (!gRgb || !gFlat) { drop(); return; }

    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    bool scaled = !onlyScale && gSrFor == pb && gSrOut && gSrOut.width == fw && gSrOut.height == fh; // done ahead
    if (scaled) gSrFor = NULL; // once: the pool hands the same buffer out again for a later frame
    MTLViewport full = {0, 0, (double)W, (double)H, 0, 1};
    id<MTLTexture> src = gSrOut;
    int up = effUpscale(), ran = 2; // what scaled this frame: 0 nothing or plain, 1 metalfx, 2 apple super resolution, 3 fsr 1 easu, 4 sgsr 1
    if (!scaled) {
    ran = 0;
    if (!nv) gSd = is601(pb); // generated and converted frames follow the source they came from
    static const bool oldGreen = [NSUserDefaults.standardUserDefaults boolForKey:@"greenOld"]; // hidden, to compare
    float lv[4] = {fullRange() ? 1.0f : 0.0f, p0 ? 1.0f : 0.0f, 1.5f / 255, (gSd ? 1.0f : 0.0f) + (oldGreen ? 2.0f : 0.0f)}; // levels, still-area rule on, how close counts as unchanged, mode
    if (nv && r0 && r1) pass(cb, gPipeNvFix, CVMetalTextureGetTexture(t0), CVMetalTextureGetTexture(t1), gRgb, full, lv, false, CVMetalTextureGetTexture(r0), CVMetalTextureGetTexture(r1), p0 ? CVMetalTextureGetTexture(p0) : CVMetalTextureGetTexture(r0));
    else if (nv) pass(cb, gPipeNv, CVMetalTextureGetTexture(t0), CVMetalTextureGetTexture(t1), gRgb, full, lv);
    else pass(cb, gPipeYuv, CVMetalTextureGetTexture(t0), nil, gRgb, full, lv);
    src = gRgb;
    if (effDeband()) {
        float db[4] = {1.0f / W, 1.0f / H, 2.5f / 255, 0};
        pass(cb, gPipeDeband, src, nil, gFlat, full, db);
        src = gFlat;
    }
    gSrFor = NULL; // gSrOut is about to be someone else's, or nobody's
    gSrCan = up == 2 && !srYields() && fw > W && fh > H && superres::ready((int)W, (int)H);
    if (gSrCan && superScale(cb, src, W, fw, fh)) { src = gSrOut; ran = 2; }
    }
    if (onlyScale) {
        if (ran == 2) gSrFor = pb;
        CFRetain(pb);
        if (real) CFRetain(real);
        if (prevReal) CFRetain(prevReal);
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            CFRelease(t0);
            if (t1) CFRelease(t1);
            if (r0) CFRelease(r0);
            if (r1) CFRelease(r1);
            if (p0) CFRelease(p0);
            if (prevReal) CFRelease(prevReal);
            if (real) CFRelease(real);
            CFRelease(pb);
        }];
        [cb commit];
        return;
    }
    if ((up == 3 || up == 4) && fw > W && fh > H) {
        if (!gEdge) gEdge = makeTex(fw, fh, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        float eu[4] = {1.0f / W, 1.0f / H, 0, 0};
        if (gEdge) { pass(cb, up == 3 ? gPipeEasu : gPipeSgsr, src, nil, gEdge, (MTLViewport){0, 0, (double)fw, (double)fh, 0, 1}, eu); src = gEdge; ran = up; }
    }
    if (up >= 1 && up <= 2 && !ran && gScaler) { // also the fallback while super resolution starts, cannot take the size or runs late
        gScaler.colorTexture = src;
        gScaler.outputTexture = gUp;
        [gScaler encodeToCommandBuffer:cb];
        src = gUp;
        ran = 1;
    }
    gInfoUp = ran;
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
    double dur = gFrameDur, handed = nowSec();
    [dr addPresentedHandler:^(id<MTLDrawable> d) {
        static std::atomic<double> last{0};
        double pt = d.presentedTime;
        if (pt > 0) gQueueLag = pt - handed;
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
    if (ran == 2) gS.sr++;
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
    gSd = is601(src);
    tag709(nv); // also for sd: nothing downstream reads the tag for colour, the shader goes by gSd
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
// apple super resolution next to frame generation ("deep"). the two share the neural engine and each slows the other,
// so they go strictly one after the other: generate (11 ms), scale the generated frame (8), scale the next real frame
// (8). measured that way it all fits in a 33 ms pair, but the generated frame is on screen ~22 ms after its real frame
// arrived, not 13, and the real frame 17 ms after that: a few ms after the NEXT real frame has come in. that one
// waits here (generation for it starts at once), and takes its place when the held frame has been shown
static bool deep;
static CVPixelBufferRef nextNv;
static double nextArrival;
static bool nextAsked;
// only while super resolution really runs: in a window no larger than the source, or while its session is starting or
// has failed, the plain schedules show frames sooner
static bool deepWanted() { return effFrameGen() && effUpscale() == 2 && gSet.srWithGen && superres::available() && gSrCan; }
static double genBudget() { return fmin(15.0, fmax(12.0, framegen::peakMs() + 2.5)) / 1000; } // 1.5 ms of margin left 1% of generated frames late live

static void dropHeld() {
    if (prevNv) { CFRelease(prevNv); prevNv = NULL; }
    if (curNv) { CFRelease(curNv); curNv = NULL; }
    if (nextNv) { CFRelease(nextNv); nextNv = NULL; }
    gSrFor = NULL;
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
        if (deep && curNv) {
            if (mid) gRealDue = now + gFrameDur.load(); // scaling the generated frame took its time: the real one follows that
            show(curNv, 0, NULL, NULL, true);           // and is scaled now, while nothing else wants the neural engine
            now = nowSec();
        }
    }
    if (gRealDue > 0 && now >= gRealDue - kEarlyWake) {
        if (curNv) {
            show(curNv, curArrival);
            if (prevNv) CFRelease(prevNv);
            prevNv = curNv; prevArrival = curArrival; curNv = NULL;
        }
        gRealDue = 0;
        if (nextNv) { // the frame that came in meanwhile moves up. its generated frame is already being made
            curNv = nextNv; curArrival = nextArrival; genAsked = nextAsked; nextNv = NULL;
            gMidDue = curArrival + genBudget();
            gRealDue = gMidDue + gFrameDur.load();
        }
    }
    gNextDue = gMidDue > 0 ? gMidDue : gRealDue;
}

// one capture tick. owns pb.
// changed: a repeat that is not bit for bit the frame before (something small moved: a spinner, a cursor, typed text)
static void tick(CVPixelBufferRef pb, double arrival, bool repeat, bool changed) {
    bool dw = deepWanted(), ew = gSet.early || dw; // deep needs timed presents
    if (early != ew || deep != dw) { // the schedules keep different promises: start clean
        framegen::cancel();
        dropHeld();
        early = ew; deep = dw;
        gDeepNow = dw;
    }
    // frame generation needs yuv 4:2:2 input at an even size the interpolator accepts
    bool genOk = effFrameGen() && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8 &&
                 framegen::ready((int)CVPixelBufferGetWidth(pb), (int)CVPixelBufferGetHeight(pb));
    if (prevNv && (CVPixelBufferGetWidth(prevNv) != CVPixelBufferGetWidth(pb) || CVPixelBufferGetHeight(prevNv) != CVPixelBufferGetHeight(pb))) dropHeld();
    if (!genOk) {
        if (prevNv || curNv) { framegen::cancel(); dropHeld(); }
        // repeats are shown too. left out, each frame of a 30 fps game stayed up for one refresh or three whenever the
        // timing wobbled (the counts looked perfect, the picture looked choppy); shown, each one stays exactly two.
        // the catch: at a 60 hz screen frames then go in exactly as fast as they come out, and a backlog (from start-up,
        // from a stall) never clears: measured 75 ms to the screen instead of 21. so when the display's queue has
        // backed up, one repeat is left out to drain a place. passthrough leaves nothing out at all
        static double lastSkip;
        double now = CACurrentMediaTime();
        bool backed = gQueueLag > 2.0 * gFrameDur && now - lastSkip > 0.25;
        if (!gSet.passthrough && repeat && !changed && !display::variable() && backed) { lastSkip = now; CFRelease(pb); return; }
        show(pb, repeat ? 0 : arrival);
        CFRelease(pb);
        return;
    }
    if (!repeat) {
        CVPixelBufferRef nv = toNV(pb);
        CFRelease(pb);
        if (!nv) return;
        newRun++; repeatRun = 0;
        if (deep && curNv && gRealDue > 0 && gMidDue == 0 && !nextNv) { // see deep: the held frame is shown first
            nextNv = nv; nextArrival = arrival;
            nextAsked = lumaDiff(curNv, nv) <= kMotionLimit;
            if (nextAsked) framegen::request(curNv, nv);
            else bump(&Stats::genSkipped);
            return;
        }
        if (nextNv) { framegen::cancel(); CFRelease(nextNv); nextNv = NULL; } // a third frame on top: 60 fps content, or this schedule fell a pair behind
        if (curNv) { // previous real frame never got its turn: the source is running at 60, not 30
            // early: or this frame came a few ms before the held one was due (the margin is only 2-5 ms). show it now
            if (early && gRealDue > 0) show(curNv, curArrival);
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
            gMidDue = arrival + genBudget();
            gRealDue = gMidDue + gFrameDur.load();
            gNextDue = gMidDue;
            return; // the previous real frame went up at its own due time
        }
        show(prevNv, prevArrival); // a real frame, one tick pair after it arrived
        return;
    }
    newRun = 0; repeatRun++;
    // a still picture with something small changing on it: no pair is waiting, so this frame becomes the one on screen.
    // without this the change only showed once a later frame differed by more than kRepeatSlack samples
    if (changed && !curNv && gNextDue == 0) {
        CVPixelBufferRef nv = toNV(pb);
        CFRelease(pb);
        if (nv) { if (prevNv) CFRelease(prevNv); prevNv = nv; prevArrival = arrival; show(prevNv, 0); }
        return;
    }
    CFRelease(pb); // a copy of what we already have
    if (early) { // timed presents take care of the held frames. nothing due: keep the overlay and settings alive
        static double lastIdle;
        if (gNextDue == 0 && prevNv && nowSec() - lastIdle > 0.1) { lastIdle = nowSec(); show(prevNv, 0); }
        return;
    }
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
    // the rows that went round the edge on their own. on a roll they match too; on a fast vertical pan they are new
    // picture, and without this check a pan of 120+ px a frame was dropped as a roll
    auto wrapped = [&](int sh) { float t = 0; for (int i = kRows - sh; i < kRows; i++) t += fabsf(cur.v[(i + sh) % kRows] - prev.v[i]); return t / sh; };
    float same = sad(0);
    if (same < kSameProfile) return 0; // looks like the previous frame where it is
    float best = 1e9; int at = 0;
    for (int sh = kRollMin; sh <= kRollMax; sh++) { float t = sad(sh); if (t < best) { best = t; at = sh; } }
    return (best < same * 0.3f && best < kSameProfile && wrapped(at) < kSameProfile) ? at : 0; // the shifted match must be clearly better
}

void submit(CVPixelBufferRef pb, double arrival, double captured, bool late) {
    Luma l;
    bool repeat = false, changed = false;
    int darkest = 255;
    if (lockLuma(pb, l)) {
        Sig g; Profile p; int dark;
        analyse(l, g, p, dark, darkest);
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        static int rolledRun; // a real roll is a frame or two. more in a row is the detector fooled: let the picture through
        if (!(gHaveProf && rollOf(p, gProf))) rolledRun = 0;
        else if (!gSet.passthrough && ++rolledRun <= 2) { // screen keeps the last good frame. passthrough shows it as it came
            bump(&Stats::rolled);
            CFRelease(pb);
            return;
        }
        gProf = p; gHaveProf = true;
        if (dark < kDarkSamples || arrival < gLevelsFrom) gDarkFrames = 0; // in a row: stray undershoot on a video range source must not add up
        else if (++gDarkFrames >= kDarkFrames) gFullSeen = true;
        int nd = 9999;
        if (gHaveSig) { nd = 0; for (size_t i = 0; i < sizeof g.b; i++) nd += g.b[i] != gSig.b[i]; }
        repeat = nd <= kRepeatSlack;
        gSig = g; gHaveSig = true;
        changed = repeat && nd > 0;
        if (changed) bump(&Stats::nearRepeats);
    }
    os_unfair_lock_lock(&gLock);
    gS.in++;
    if (darkest < gS.darkest) gS.darkest = darkest;
    if (repeat) gS.repeats++; else gS.real++;
    if (late) gS.late++;
    if (captured > 0 && arrival > captured) { gS.lagSum += (arrival - captured) * 1000; gS.lagN++; }
    CVPixelBufferRef old = gNewest;
    // a new frame still waiting when its own repeat comes in: same picture, and it stays new (with its own arrival
    // time). otherwise the render thread only ever sees "repeat" and that game frame is never shown
    if (old && !gNewestRepeat && repeat) { repeat = false; arrival = gNewestArrival; }
    gNewest = pb; gNewestArrival = arrival; gNewestCaptured = captured; gNewestRepeat = repeat; gNewestChanged = repeat && changed;
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
                bool repeat = gNewestRepeat, changed = gNewestChanged;
                gNewest = NULL;
                os_unfair_lock_unlock(&gLock);
                if (gClearReq.exchange(false) && !pb) { framegen::cancel(); dropHeld(); clearNow(); }
                double t = nowSec();
                if (pb) tick(pb, arrival, repeat, changed);
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
    id<MTLRenderPipelineState> __strong *pipes[] = {&gPipeYuv, &gPipeNv, &gPipeNvFix, &gPipeOut, &gPipeDeband, &gPipeEasu, &gPipeSgsr};
    NSString *names[] = {@"fsYuv", @"fsNv", @"fsNvFix", @"fsOut", @"fsDeband", @"fsEasu", @"fsSgsr"};
    for (int i = 0; i < 7; i++) {
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
    pd.colorAttachments[0].blendingEnabled = NO;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsTiles"];
    gPipeTiles = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm; // the planes of a 420v tile
    pd.fragmentFunction = [lib newFunctionWithName:@"fsTileY"];
    gPipeTileY = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsTileC"];
    gPipeTileC = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeTiles || !gPipeTileY || !gPipeTileC) { err = "pipeline fsTiles"; return false; }
    if (CVMetalTextureCacheCreate(NULL, NULL, gDev, NULL, &gCache) != kCVReturnSuccess) { err = "no metal texture cache"; return false; }

    gLayer = [CAMetalLayer layer];
    gLayer.device = gDev;
    gLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    gLayer.framebufferOnly = YES;
    gLayer.opaque = YES;
    gLayer.maximumDrawableCount = 3;
    gLayer.displaySyncEnabled = gSet.vsync; // off is ~5 ms faster but tears
    gLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    applyColour();
    return true;
}

}
