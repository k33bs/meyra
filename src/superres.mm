// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include "superres.h"
#include "common.h"
#include <atomic>
#include <os/lock.h>
#include <unistd.h>

namespace superres {

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
struct Req { CVPixelBufferRef src[2]; id<MTLCommandBuffer> drawn; uint64_t ticket; };
static Req gReq;                          // under gLock
static std::atomic<bool> gPending{false}, gBusy{false};
static std::atomic<uint64_t> gWanted{0};
static CVPixelBufferRef gRes[2];          // under gLock, +1
static CVPixelBufferPoolRef gSrcPool, gDstPool; // under gLock
static Tiles gTiles;                      // under gLock
static dispatch_semaphore_t gDone, gWake;
static std::atomic<int> gWantW{0}, gWantH{0}, gWantP{0}, gReadyW{0}, gReadyH{0}, gReadyP{0};
static std::atomic<double> gLastAsk{0};
static std::atomic<int> gState{0};        // 0 idle, 1 starting, 2 ready, 3 cannot take this size
static char gWhy[64];
static Stats gS;
static std::atomic<bool> gQuit{false};
static dispatch_semaphore_t gStopped;
static const double kIdleEnd = 3;         // seconds nobody asked before the session is let go
// the scaler rings in the outermost ~16 px of what it returns, as if the frame were padded with black. so each tile
// is drawn with this much mirrored picture around it and the scaled margin is left out again (setting srPad)
static const int kPad = 16;
static const int kOverlap = 128;          // source pixels the two tiles share, the seam is faded across the middle of it

bool available() {
    static int v = -1;
    if (v < 0) {
        v = 0;
        if (@available(macOS 26.0, *)) v = VTLowLatencySuperResolutionScalerConfiguration.isSupported ? 1 : 0;
    }
    return v == 1;
}

bool ready(int w, int h) {
    gLastAsk = nowSec();
    int p = gSet.srPad ? kPad : 0;
    if (gWantW != w || gWantH != h || gWantP != p) { gWantW = w; gWantH = h; gWantP = p; dispatch_semaphore_signal(gWake); }
    return gState == 2 && gReadyW == w && gReadyH == h && gReadyP == p;
}

const char *status() {
    if (!available()) return "not available on this mac";
    switch (gState.load()) {
    case 1: return "starting";
    case 3: return gWhy;
    default: return "";
    }
}

Tiles tiles() {
    os_unfair_lock_lock(&gLock);
    Tiles t = gTiles;
    os_unfair_lock_unlock(&gLock);
    return t;
}

bool buffers(CVPixelBufferRef src[2]) {
    src[0] = src[1] = NULL;
    os_unfair_lock_lock(&gLock);
    int n = gState == 2 && gSrcPool ? gTiles.n : 0;
    bool ok = n > 0;
    for (int i = 0; i < n && ok; i++) ok = CVPixelBufferPoolCreatePixelBuffer(NULL, gSrcPool, &src[i]) == kCVReturnSuccess;
    os_unfair_lock_unlock(&gLock);
    if (!ok) for (int i = 0; i < 2; i++) if (src[i]) { CFRelease(src[i]); src[i] = NULL; }
    for (int i = 0; i < n && ok; i++) tag709(src[i]);
    return ok;
}

void request(CVPixelBufferRef src[2], id<MTLCommandBuffer> drawn) {
    while (dispatch_semaphore_wait(gDone, DISPATCH_TIME_NOW) == 0) {} // drain old signals first
    uint64_t t = ++gWanted;
    gBusy = true;
    os_unfair_lock_lock(&gLock);
    Req old = gReq;
    bool had = gPending.exchange(true);
    gReq = {{src[0], src[1]}, drawn, t};
    CVPixelBufferRef stale[2] = {gRes[0], gRes[1]}; // finished just after an earlier take gave up on it
    gRes[0] = gRes[1] = NULL;
    os_unfair_lock_unlock(&gLock);
    if (had) for (auto p : old.src) if (p) CFRelease(p);
    for (auto p : stale) if (p) CFRelease(p);
    dispatch_semaphore_signal(gWake);
}

bool busy() { return gBusy; }

bool take(double graceMs, CVPixelBufferRef dst[2]) {
    dispatch_semaphore_wait(gDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(graceMs * NSEC_PER_MSEC)));
    os_unfair_lock_lock(&gLock);
    dst[0] = gRes[0]; dst[1] = gRes[1];
    gRes[0] = gRes[1] = NULL;
    os_unfair_lock_unlock(&gLock);
    if (dst[0]) return true;
    ++gWanted; // too late: whatever comes out is not wanted any more
    return false;
}

Stats takeStats() {
    os_unfair_lock_lock(&gLock);
    Stats s = gS;
    gS = Stats();
    os_unfair_lock_unlock(&gLock);
    return s;
}

// tile layout for a source size, from what the scaler says it takes: the whole frame if it can, else two halves
// sharing kOverlap columns. smallest scale factor above 1
API_AVAILABLE(macos(26.0))
static bool plan(int w, int h, int pad, Tiles &t, float &factor) {
    // one tile before two, and padded before not: 720p fits whole but not with padding, and one unpadded tile beats
    // two padded ones (half the work, no seam)
    for (int k = 0; k < (pad ? 4 : 2); k++) {
        int n = pad ? k / 2 + 1 : k + 1, pd = pad && k % 2 == 0 ? pad : 0;
        int tw = n == 1 ? w : ((w + kOverlap) / 2 + 1) & ~1;
        factor = 0;
        for (NSNumber *f in [VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:tw + 2 * pd frameHeight:h + 2 * pd])
            if (f.floatValue > 1 && (factor == 0 || f.floatValue < factor)) factor = f.floatValue;
        if (factor > 0) {
            t = {n, tw + 2 * pd, h + 2 * pd, w - tw, (int)lround((tw + 2 * pd) * factor), (int)lround((h + 2 * pd) * factor), pd};
            return true;
        }
    }
    return false;
}

static void dropPools() {
    os_unfair_lock_lock(&gLock);
    if (gSrcPool) CVPixelBufferPoolRelease(gSrcPool);
    if (gDstPool) CVPixelBufferPoolRelease(gDstPool);
    gSrcPool = gDstPool = NULL;
    gTiles = Tiles();
    os_unfair_lock_unlock(&gLock);
}

static CVPixelBufferPoolRef makePool(NSDictionary *attrs, int w, int h) {
    NSMutableDictionary *a = [attrs mutableCopy];
    a[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    a[(id)kCVPixelBufferWidthKey] = @(w);
    a[(id)kCVPixelBufferHeightKey] = @(h);
    a[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    a[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
    CVPixelBufferPoolRef p = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &p);
    return p;
}

// same trick as frame generation: the thread spins while the scaler is in use, because a core that winds down
// between frames makes each call take twice as long (two tiles: ~7 ms hot, 13-20 ms with sleeps). while frame
// generation is on its thread already keeps the cores up, so this one sleeps on a semaphore then
API_AVAILABLE(macos(26.0))
static void loop() {
    VTFrameProcessor *proc = nil;
    int fails = 0, restarts = 0; // frames that failed in a row, and sessions restarted over it
    while (!gQuit) {
        double idle = nowSec() - gLastAsk.load();
        int ww = gWantW, wh = gWantH, wp = gWantP;
        if (idle > kIdleEnd) {
            if (proc) {
                [proc endSession];
                proc = nil;
                dropPools();
                logLine("apple super resolution: idle, session closed");
            }
            gState = 0; gReadyW = gReadyH = 0; // also after a failed start, so the next use tries again
            fails = restarts = 0;
            dispatch_semaphore_wait(gWake, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
            continue;
        }
        if (ww > 0 && (ww != gReadyW || wh != gReadyH || wp != gReadyP) && !(gState == 3 && ww == gReadyW && wh == gReadyH && wp == gReadyP)) {
            @autoreleasepool {
                if (proc) { [proc endSession]; proc = nil; }
                dropPools();
                gState = 1;
                double t0 = nowSec();
                Tiles t; float factor = 0;
                NSError *e = nil;
                bool ok = plan(ww, wh, wp, t, factor);
                VTLowLatencySuperResolutionScalerConfiguration *cfg = nil;
                if (ok) {
                    cfg = [[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:t.w frameHeight:t.h scaleFactor:factor];
                    proc = [VTFrameProcessor new];
                    ok = cfg && [proc startSessionWithConfiguration:cfg error:&e];
                }
                if (ok) {
                    CVPixelBufferPoolRef sp = makePool(cfg.sourcePixelBufferAttributes, t.w, t.h), dp = makePool(cfg.destinationPixelBufferAttributes, t.outW, t.outH);
                    os_unfair_lock_lock(&gLock);
                    gSrcPool = sp; gDstPool = dp; gTiles = t;
                    os_unfair_lock_unlock(&gLock);
                    ok = sp && dp;
                }
                if (!ok) { proc = nil; dropPools(); snprintf(gWhy, sizeof gWhy, "cannot take %dx%d", ww, wh); }
                gReadyW = ww; gReadyH = wh; gReadyP = wp;
                gState = ok ? 2 : 3;
                if (ok) logLine("apple super resolution ready for %dx%d: %d tile%s of %dx%d (padding %d) at %.2gx -> %dx%d (%.0f ms)", ww, wh, t.n, t.n > 1 ? "s" : "",
                                t.w, t.h, t.pad, factor, t.outW, t.outH, (nowSec() - t0) * 1000);
                else logLine("apple super resolution unavailable for %dx%d%s%s", ww, wh, e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
            }
            continue;
        }
        if (!gPending.load(std::memory_order_relaxed)) {
            if (gState != 2 || effFrameGen()) dispatch_semaphore_wait(gWake, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC));
            continue; // otherwise spin, see above
        }
        os_unfair_lock_lock(&gLock);
        Req r = gReq;
        gReq = Req();
        gPending = false;
        Tiles t = gTiles;
        CVPixelBufferPoolRef dp = gDstPool;
        if (dp) CVPixelBufferPoolRetain(dp);
        os_unfair_lock_unlock(&gLock);
        @autoreleasepool {
            double t0 = nowSec();
            [r.drawn waitUntilCompleted];
            CVPixelBufferRef dst[2] = {NULL, NULL};
            bool tried = false;
            bool ok = gState == 2 && dp && t.n > 0 && r.drawn.status == MTLCommandBufferStatusCompleted &&
                      (int)CVPixelBufferGetWidth(r.src[0]) == t.w && (int)CVPixelBufferGetHeight(r.src[0]) == t.h;
            for (int i = 0; i < t.n && ok; i++) {
                ok = gWanted == r.ticket && CVPixelBufferPoolCreatePixelBuffer(NULL, dp, &dst[i]) == kCVReturnSuccess;
                if (!ok) break;
                tag709(dst[i]);
                VTFrameProcessorFrame *sf = [[VTFrameProcessorFrame alloc] initWithBuffer:r.src[i] presentationTimeStamp:CMTimeMake((int64_t)r.ticket, 60)];
                VTFrameProcessorFrame *df = [[VTFrameProcessorFrame alloc] initWithBuffer:dst[i] presentationTimeStamp:CMTimeMake((int64_t)r.ticket, 60)];
                VTLowLatencySuperResolutionScalerParameters *p = [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:sf destinationFrame:df];
                NSError *err = nil;
                ok = p && [proc processWithParameters:p error:&err];
                tried = true;
                if (!ok && fails == 0) logLine("apple super resolution: a frame failed%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
            }
            // same as in framegen.mm: a session that started and then fails every frame gets a new one, twice
            if (ok) fails = restarts = 0;
            else if (tried && ++fails >= 30) {
                fails = 0;
                if (++restarts > 2) { gState = 3; snprintf(gWhy, sizeof gWhy, "keeps failing"); logLine("apple super resolution: keeps failing, stopped"); }
                else { gReadyW = gReadyH = 0; logLine("apple super resolution: 30 frames failed in a row, starting a new session"); }
            }
            double ms = (nowSec() - t0) * 1000;
            bool keep = ok && gWanted == r.ticket;
            os_unfair_lock_lock(&gLock);
            CVPixelBufferRef old[2] = {gRes[0], gRes[1]};
            gRes[0] = keep ? dst[0] : NULL; gRes[1] = keep ? dst[1] : NULL;
            if (ok) { gS.sumMs += ms; gS.n++; if (ms > gS.maxMs) gS.maxMs = ms; }
            os_unfair_lock_unlock(&gLock);
            for (int i = 0; i < 2; i++) {
                if (old[i]) CFRelease(old[i]);
                if (dst[i] && !keep) CFRelease(dst[i]);
                if (r.src[i]) CFRelease(r.src[i]);
            }
            if (dp) CVPixelBufferPoolRelease(dp);
            dispatch_semaphore_signal(gDone); // before busy clears: a request slipping in between drains it, the other way round it woke that request's take() empty
            gBusy = gPending.load();
        }
    }
    if (proc) [proc endSession];
    dropPools();
    os_unfair_lock_lock(&gLock);
    Req r = gReq;
    gReq = Req();
    bool had = gPending.exchange(false);
    CVPixelBufferRef res[2] = {gRes[0], gRes[1]};
    gRes[0] = gRes[1] = NULL;
    os_unfair_lock_unlock(&gLock);
    for (int i = 0; i < 2; i++) {
        if (had && r.src[i]) CFRelease(r.src[i]);
        if (res[i]) CFRelease(res[i]);
    }
    dispatch_semaphore_signal(gStopped);
}

void startThread() {
    gDone = dispatch_semaphore_create(0);
    gWake = dispatch_semaphore_create(0);
    if (!available()) return;
    if (@available(macOS 26.0, *)) {
        gStopped = dispatch_semaphore_create(0);
        NSThread *th = [[NSThread alloc] initWithBlock:^{ loop(); }];
        th.qualityOfService = NSQualityOfServiceUserInteractive;
        th.name = @"super resolution";
        [th start];
    }
}

void stopThread() {
    if (!gStopped || gQuit.exchange(true)) return;
    dispatch_semaphore_signal(gWake);
    dispatch_semaphore_wait(gStopped, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
}

}
