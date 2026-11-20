// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#include "framegen.h"
#include "common.h"
#include <atomic>
#include <os/lock.h>
#include <unistd.h>

namespace framegen {

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
struct Req { CVPixelBufferRef prev, cur; uint64_t ticket; };
static Req gReq;                          // under gLock
static std::atomic<bool> gPending{false};
static std::atomic<uint64_t> gWanted{0};
static CVPixelBufferRef gResult;          // under gLock, +1
static dispatch_semaphore_t gDone;
static std::atomic<double> gPeak{0};
static std::atomic<int> gWantW{0}, gWantH{0}, gReadyW{0}, gReadyH{0};
static std::atomic<double> gLastAsk{0};   // last time anyone asked for the session
static std::atomic<int> gState{0};        // 0 idle, 1 starting, 2 ready, 3 failed
static Stats gS;
static std::atomic<bool> gQuit{false};
static dispatch_semaphore_t gStopped;
static const double kIdleEnd = 3;         // seconds nobody asked before the session (and the neural engine) is let go

bool available() {
    static int v = -1;
    if (v < 0) {
        v = 0;
        if (@available(macOS 26.0, *)) v = VTLowLatencyFrameInterpolationConfiguration.isSupported ? 1 : 0;
    }
    return v == 1;
}

bool ready(int w, int h) {
    gLastAsk = nowSec();
    gWantW = w; gWantH = h;
    return gState == 2 && gReadyW == w && gReadyH == h;
}

const char *status() {
    if (!available()) return "not available on this mac";
    switch (gState.load()) {
    case 1: return "starting";
    case 3: return "could not start for this picture size";
    default: return "";
    }
}

void request(CVPixelBufferRef prev, CVPixelBufferRef cur) {
    while (dispatch_semaphore_wait(gDone, DISPATCH_TIME_NOW) == 0) {} // drain old signals first
    CFRetain(prev); CFRetain(cur);
    uint64_t t = ++gWanted;
    os_unfair_lock_lock(&gLock);
    Req old = gReq;
    bool had = gPending.exchange(true);
    gReq = {prev, cur, t};
    os_unfair_lock_unlock(&gLock);
    if (had) { CFRelease(old.prev); CFRelease(old.cur); } // never got picked up
}

void cancel() { ++gWanted; }

CVPixelBufferRef take(double graceMs) {
    dispatch_semaphore_wait(gDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(graceMs * NSEC_PER_MSEC))); // a late frame must not push things around
    os_unfair_lock_lock(&gLock);
    CVPixelBufferRef mid = gResult;
    gResult = NULL;
    os_unfair_lock_unlock(&gLock);
    return mid;
}

double peakMs() { return gPeak; }

Stats takeStats() {
    os_unfair_lock_lock(&gLock);
    Stats s = gS;
    gS = Stats();
    os_unfair_lock_unlock(&gLock);
    return s;
}

// runs on its own thread that spins while frame generation is on: if that thread sleeps between frames the core winds
// down and the same call takes ~19 ms instead of ~11, which misses the 16.7 ms tick. a sleeping realtime thread was
// tried too: 15-17 ms. so this costs one core while frame generation is on, and nothing while it is off.
// the session (and with it the neural engine) is only started while someone asks for it, and closed after a few idle seconds.
API_AVAILABLE(macos(26.0))
static void loop() {
    VTFrameProcessor *proc = nil;
    CVPixelBufferPoolRef dstPool = NULL;
    while (!gQuit) {
        double idle = nowSec() - gLastAsk.load();
        int ww = gWantW, wh = gWantH;
        if (idle > kIdleEnd) {
            if (proc) {
                [proc endSession];
                proc = nil;
                if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; }
                gState = 0; gReadyW = gReadyH = 0;
            }
            usleep(20000);
            continue;
        }
        if (ww > 0 && (ww != gReadyW || wh != gReadyH) && !(gState == 3 && ww == gReadyW && wh == gReadyH)) {
            @autoreleasepool {
                if (proc) { [proc endSession]; proc = nil; }
                if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; }
                gState = 1;
                double t0 = nowSec();
                VTLowLatencyFrameInterpolationConfiguration *cfg = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:ww frameHeight:wh numberOfInterpolatedFrames:1];
                NSError *e = nil;
                proc = [VTFrameProcessor new];
                bool ok = cfg && [proc startSessionWithConfiguration:cfg error:&e];
                if (ok) {
                    NSMutableDictionary *a = [cfg.destinationPixelBufferAttributes mutableCopy];
                    a[(id)kCVPixelBufferWidthKey] = @(ww);
                    a[(id)kCVPixelBufferHeightKey] = @(wh);
                    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &dstPool);
                    ok = dstPool != NULL;
                }
                gReadyW = ww; gReadyH = wh;
                gState = ok ? 2 : 3;
                if (!ok) proc = nil;
                logLine("frame generation %s for %dx%d (%.0f ms)%s%s", ok ? "ready" : "unavailable", ww, wh, (nowSec() - t0) * 1000,
                        e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
            }
            continue;
        }
        if (!gPending.load(std::memory_order_relaxed)) {
            if (!effFrameGen() || gState != 2) usleep(5000); // nothing to stay hot for
            continue;                                       // otherwise spin, see above
        }
        os_unfair_lock_lock(&gLock);
        Req r = gReq;
        gPending = false;
        os_unfair_lock_unlock(&gLock);
        @autoreleasepool {
            double t = nowSec();
            CVPixelBufferRef dst = NULL;
            bool ok = false;
            bool sizeOk = gState == 2 && (int)CVPixelBufferGetWidth(r.cur) == gReadyW && (int)CVPixelBufferGetHeight(r.cur) == gReadyH;
            if (sizeOk && gWanted == r.ticket && CVPixelBufferPoolCreatePixelBuffer(NULL, dstPool, &dst) == kCVReturnSuccess) {
                tag709(dst);
                VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:r.prev presentationTimeStamp:CMTimeMake(0, 30000)];
                VTFrameProcessorFrame *fc = [[VTFrameProcessorFrame alloc] initWithBuffer:r.cur presentationTimeStamp:CMTimeMake(1001, 30000)];
                VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMake(500, 30000)];
                VTLowLatencyFrameInterpolationParameters *p = [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fc previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
                NSError *err = nil;
                ok = p && [proc processWithParameters:p error:&err];
            }
            double ms = (nowSec() - t) * 1000;
            bool keep = ok && gWanted == r.ticket;
            os_unfair_lock_lock(&gLock);
            CVPixelBufferRef old = gResult;
            gResult = keep ? dst : NULL;
            if (ok) { gS.sumMs += ms; gS.n++; if (ms > gS.maxMs) gS.maxMs = ms; gPeak = fmax(ms, gPeak.load() * 0.995); }
            os_unfair_lock_unlock(&gLock);
            if (old) CFRelease(old);
            if (dst && !keep) CFRelease(dst);
            CFRelease(r.prev); CFRelease(r.cur);
            dispatch_semaphore_signal(gDone);
        }
    }
    if (proc) [proc endSession];
    if (dstPool) CVPixelBufferPoolRelease(dstPool);
    os_unfair_lock_lock(&gLock);
    Req r = gReq;
    bool had = gPending.exchange(false);
    CVPixelBufferRef res = gResult;
    gResult = NULL;
    os_unfair_lock_unlock(&gLock);
    if (had) { CFRelease(r.prev); CFRelease(r.cur); }
    if (res) CFRelease(res);
    dispatch_semaphore_signal(gStopped);
}

void startThread() {
    gDone = dispatch_semaphore_create(0);
    if (!available()) return;
    if (@available(macOS 26.0, *)) {
        gStopped = dispatch_semaphore_create(0);
        NSThread *th = [[NSThread alloc] initWithBlock:^{ loop(); }];
        th.qualityOfService = NSQualityOfServiceUserInteractive;
        th.name = @"frame generation";
        [th start];
    }
}

void stopThread() {
    if (!gStopped || gQuit.exchange(true)) return;
    dispatch_semaphore_wait(gStopped, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
}

}
