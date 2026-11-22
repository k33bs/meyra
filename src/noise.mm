// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include "noise.h"
#include "common.h"
#include <atomic>
#include <os/lock.h>
#include <unistd.h>

namespace noise {

// the filter only takes the compressed family of pixel formats. this one is 420v stored lossless: a copy in, a copy out
static const OSType kFmt = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange;
static const double kCut = 40;            // sparse luma difference above which the frame before is no reference (the motion guard's limit)

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CVPixelBufferRef gSrc, gDst;       // the job, under gLock, both +1
static double gAsked;                     // under gLock
static std::atomic<CVPixelBufferRef> gBusy{NULL}; // the buffer being filled. only compared
static std::atomic<int> gBadW{0}, gBadH{0};       // size the filter refused
static Stats gS;
static dispatch_semaphore_t gGo, gStopped;
static std::atomic<bool> gQuit{false};
static CVPixelBufferPoolRef gPool;        // render thread: where the filtered frames go
static int gPoolW, gPoolH;

bool available() {
    static int v = -1;
    if (v < 0) {
        v = 0;
        if (@available(macOS 26.0, *)) v = VTTemporalNoiseFilterConfiguration.isSupported ? 1 : 0;
    }
    return v == 1;
}

static std::atomic<int> gAskW{0}, gAskH{0};       // the size last asked about, so status speaks for the picture in use
bool can(int w, int h) { gAskW = w; gAskH = h; return available() && !(w == gBadW && h == gBadH); }
const char *status() { return !available() ? "not available on this mac" : gBadW && gBadW == gAskW && gBadH == gAskH ? "not working for this picture" : ""; }
bool done(CVPixelBufferRef dst) { return gBusy.load() != dst; }

bool wait(CVPixelBufferRef dst, double graceMs) {
    double end = nowSec() + graceMs / 1000;
    while (!done(dst) && nowSec() < end) usleep(200); // callers are realtime threads, they wake on time
    return done(dst);
}

Stats takeStats() {
    os_unfair_lock_lock(&gLock);
    Stats s = gS;
    gS = Stats();
    os_unfair_lock_unlock(&gLock);
    return s;
}

CVPixelBufferRef start(CVPixelBufferRef nv) {
    int W = (int)CVPixelBufferGetWidth(nv), H = (int)CVPixelBufferGetHeight(nv);
    if (!gGo || !can(W, H) || gBusy.load()) return NULL;
    if (!gPool || gPoolW != W || gPoolH != H) {
        if (gPool) CVPixelBufferPoolRelease(gPool);
        gPool = NULL;
        NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                            (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &gPool);
        gPoolW = W; gPoolH = H;
    }
    CVPixelBufferRef dst = NULL;
    if (!gPool || CVPixelBufferPoolCreatePixelBuffer(NULL, gPool, &dst) != kCVReturnSuccess) return NULL;
    tag709(dst);
    CFRetain(nv); CFRetain(dst);
    os_unfair_lock_lock(&gLock);
    gSrc = nv; gDst = dst; gAsked = nowSec();
    os_unfair_lock_unlock(&gLock);
    gBusy = dst;
    dispatch_semaphore_signal(gGo);
    return dst;
}

static void copyPlanes(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, 0);
    for (int p = 0; p < 2; p++) {
        const uint8_t *s = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, p);
        uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, p);
        size_t srb = CVPixelBufferGetBytesPerRowOfPlane(a, p), drb = CVPixelBufferGetBytesPerRowOfPlane(b, p);
        size_t h = CVPixelBufferGetHeightOfPlane(a, p), n = CVPixelBufferGetWidthOfPlane(a, p) * (p ? 2 : 1);
        for (size_t r = 0; r < h; r++) memcpy(d + r * drb, s + r * srb, n);
    }
    CVPixelBufferUnlockBaseAddress(b, 0);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
}

static double lumaDiff(CVPixelBufferRef a, CVPixelBufferRef b) {
    int W = (int)CVPixelBufferGetWidth(a), H = (int)CVPixelBufferGetHeight(a);
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0), *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);
    size_t ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    long sum = 0, n = 0;
    for (int r = 4; r < H; r += 9)
        for (int x = 4; x < W; x += 13) { sum += abs(pa[r * ra + x] - pb[r * rb + x]); n++; }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return n ? (double)sum / n : 0;
}

API_AVAILABLE(macos(26.0))
static void loop() {
    VTFrameProcessor *proc = nil;
    VTPixelTransferSessionRef in = NULL, out = NULL;
    CVPixelBufferPoolRef pool = NULL;     // frames in the filter's format, sources and results
    CVPixelBufferRef prevC = NULL, prevNv = NULL; // the frame before: as the filter takes it, and as it came (for the cut check)
    int sw = 0, sh = 0, fails = 0;
    int64_t n = 0;
    while (true) {
        dispatch_semaphore_wait(gGo, DISPATCH_TIME_FOREVER);
        if (gQuit) break;
        os_unfair_lock_lock(&gLock);
        CVPixelBufferRef src = gSrc, dst = gDst;
        double asked = gAsked;
        gSrc = gDst = NULL;
        os_unfair_lock_unlock(&gLock);
        if (!src) continue;
        @autoreleasepool {
            int W = (int)CVPixelBufferGetWidth(src), H = (int)CVPixelBufferGetHeight(src);
            if (W != sw || H != sh) {
                if (proc) { [proc endSession]; proc = nil; }
                if (pool) { CVPixelBufferPoolRelease(pool); pool = NULL; }
                if (prevC) { CFRelease(prevC); prevC = NULL; }
                if (prevNv) { CFRelease(prevNv); prevNv = NULL; }
                sw = W; sh = H; fails = 0;
                VTTemporalNoiseFilterConfiguration *cfg = [[VTTemporalNoiseFilterConfiguration alloc] initWithFrameWidth:W frameHeight:H sourcePixelFormat:kFmt];
                NSError *e = nil;
                proc = [VTFrameProcessor new];
                bool ok = cfg && cfg.previousFrameCount >= 1 && [proc startSessionWithConfiguration:cfg error:&e];
                if (ok) {
                    NSMutableDictionary *a = [cfg.sourcePixelBufferAttributes mutableCopy];
                    a[(id)kCVPixelBufferPixelFormatTypeKey] = @(kFmt);
                    a[(id)kCVPixelBufferWidthKey] = @(W);
                    a[(id)kCVPixelBufferHeightKey] = @(H);
                    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &pool);
                    if (!in) VTPixelTransferSessionCreate(NULL, &in);
                    if (!out) VTPixelTransferSessionCreate(NULL, &out);
                    ok = pool && in && out;
                }
                if (!ok) { proc = nil; gBadW = W; gBadH = H; }
                logLine("noise filter %s for %dx%d%s%s", ok ? "ready" : "unavailable", W, H, e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
            }
            bool ok = false;
            CVPixelBufferRef c = NULL, d = NULL;
            if (proc && CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &c) == kCVReturnSuccess && VTPixelTransferSessionTransferImage(in, src, c) == noErr) {
                // the very first frame has nothing before it: it goes through as it came
                if (prevC && CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &d) == kCVReturnSuccess) {
                    VTFrameProcessorFrame *fc = [[VTFrameProcessorFrame alloc] initWithBuffer:c presentationTimeStamp:CMTimeMake(n * 1001, 30000)];
                    VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:prevC presentationTimeStamp:CMTimeMake((n - 1) * 1001, 30000)];
                    VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:d presentationTimeStamp:CMTimeMake(n * 1001, 30000)];
                    // a cut, a jump at the fastest pans: the filter starts over rather than blend across it
                    bool cut = lumaDiff(prevNv, src) > kCut;
                    VTTemporalNoiseFilterParameters *p = fc && fp && fd ? [[VTTemporalNoiseFilterParameters alloc] initWithSourceFrame:fc nextFrames:@[] previousFrames:@[fp] destinationFrame:fd
                                                                                                                         filterStrength:gSet.noise hasDiscontinuity:cut] : nil;
                    NSError *err = nil;
                    ok = p && [proc processWithParameters:p error:&err] && VTPixelTransferSessionTransferImage(out, d, dst) == noErr;
                    if (!ok && fails == 0) logLine("noise filter: a frame failed%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
                    // it can start fine and fail every frame, like the other two: stop asking for this size
                    if (ok) fails = 0;
                    else if (++fails >= 30) { gBadW = W; gBadH = H; logLine("noise filter: keeps failing, stopped for this picture"); }
                }
                n++;
                if (prevC) CFRelease(prevC);
                prevC = c; c = NULL;
                if (prevNv) CFRelease(prevNv);
                prevNv = (CVPixelBufferRef)CFRetain(src);
            }
            if (c) CFRelease(c);
            if (d) CFRelease(d);
            if (!ok) copyPlanes(src, dst); // whoever waits for dst gets the picture either way
            double ms = (nowSec() - asked) * 1000;
            os_unfair_lock_lock(&gLock);
            if (ok) { gS.n++; gS.sumMs += ms; if (ms > gS.maxMs) gS.maxMs = ms; }
            os_unfair_lock_unlock(&gLock);
            CFRelease(src);
            gBusy = NULL;
            CFRelease(dst);
        }
    }
    if (proc) [proc endSession];
    if (in) { VTPixelTransferSessionInvalidate(in); CFRelease(in); }
    if (out) { VTPixelTransferSessionInvalidate(out); CFRelease(out); }
    if (pool) CVPixelBufferPoolRelease(pool);
    if (prevC) CFRelease(prevC);
    if (prevNv) CFRelease(prevNv);
    dispatch_semaphore_signal(gStopped);
}

void startThread() {
    if (!available()) return;
    if (@available(macOS 26.0, *)) {
        gGo = dispatch_semaphore_create(0);
        gStopped = dispatch_semaphore_create(0);
        NSThread *th = [[NSThread alloc] initWithBlock:^{ loop(); }];
        th.qualityOfService = NSQualityOfServiceUserInteractive;
        th.name = @"noise filter";
        [th start];
    }
}

void stopThread() {
    if (!gStopped || gQuit.exchange(true)) return;
    dispatch_semaphore_signal(gGo);
    dispatch_semaphore_wait(gStopped, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
}

}
