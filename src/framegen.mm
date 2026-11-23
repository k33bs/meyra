// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#include "framegen.h"
#include "flyhigh.h"
#include "common.h"
#include <algorithm>
#include <atomic>
#include <os/lock.h>
#include <unistd.h>

namespace framegen {

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
struct Req { CVPixelBufferRef prev, cur; uint64_t ticket; bool (^ready)(void); double asked; bool full, sd; };
static Req gReq;                          // under gLock
static std::atomic<bool> gPending{false};
static std::atomic<uint64_t> gWanted{0};
static CVPixelBufferRef gResult;          // under gLock, +1
static uint64_t gResultTicket;            // under gLock: the request gResult answers
static dispatch_semaphore_t gDone;
static dispatch_semaphore_t gTell;        // under gLock, see tellWhenDone
static std::atomic<double> gPeak{0}, gWaitPeak{0}, gLast{0};
static std::atomic<int> gWantW{0}, gWantH{0}, gReadyW{0}, gReadyH{0};
static std::atomic<int> gWantM{0}, gReadyM{0}; // which generator: 0 apple's, 1 and 2 the second one at its two working sizes
static std::atomic<double> gLastAsk{0};   // last time anyone asked for the session
static std::atomic<int> gState{0};        // 0 idle, 1 starting, 2 ready, 3 failed
static Stats gS;
static float gRing[120];                  // under gLock: the last generation times, for usualMs
static int gRingN, gRingAt;
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

int model() {
    int m = gSet.genModel;
    return m && flyhigh::installed() ? m : 0;
}

const char *modelNote() { return gSet.genModel ? flyhigh::note() : ""; }

bool ready(int w, int h, int model) {
    gLastAsk = nowSec();
    gWantW = w; gWantH = h; gWantM = model;
    return gState == 2 && gReadyW == w && gReadyH == h && gReadyM == model;
}

const char *status() {
    if (!available()) return "not available on this mac";
    switch (gState.load()) {
    case 1: return "starting";
    case 3: return "not working for this picture (off and on again retries)";
    default: return "";
    }
}

void request(CVPixelBufferRef prev, CVPixelBufferRef cur, bool (^ready)(void), bool full, bool sd) {
    while (dispatch_semaphore_wait(gDone, DISPATCH_TIME_NOW) == 0) {} // drain old signals first
    CFRetain(prev); CFRetain(cur);
    uint64_t t = ++gWanted;
    os_unfair_lock_lock(&gLock);
    Req old = gReq;
    bool had = gPending.exchange(true);
    gReq = {prev, cur, t, ready, nowSec(), full, sd};
    os_unfair_lock_unlock(&gLock);
    if (had) { CFRelease(old.prev); CFRelease(old.cur); } // never got picked up
}

void cancel() { ++gWanted; }

void tellWhenDone(dispatch_semaphore_t s) {
    os_unfair_lock_lock(&gLock);
    gTell = s;
    os_unfair_lock_unlock(&gLock);
}
bool done() {
    os_unfair_lock_lock(&gLock);
    bool d = !gPending && gResultTicket == gWanted;
    os_unfair_lock_unlock(&gLock);
    return d;
}

CVPixelBufferRef take(double graceMs) {
    dispatch_semaphore_wait(gDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(graceMs * NSEC_PER_MSEC))); // a late frame must not push things around
    os_unfair_lock_lock(&gLock);
    CVPixelBufferRef mid = gResult;
    gResult = NULL;
    // a frame that finished after its take gave up is still lying here when the next pair is late too. it belongs
    // between two older frames: showing it would step motion backwards
    bool stale = mid && gResultTicket != gWanted;
    os_unfair_lock_unlock(&gLock);
    if (stale) { CFRelease(mid); mid = NULL; }
    return mid;
}

double peakMs() { return gPeak; }
double usualMs() {
    float v[120];
    os_unfair_lock_lock(&gLock);
    int n = gRingN;
    memcpy(v, gRing, sizeof v);
    os_unfair_lock_unlock(&gLock);
    if (n < 20) return 0;
    int k = n * 95 / 100;
    std::nth_element(v, v + k, v + n);
    return v[k];
}
double lastMs() { return gLast; }
double waitPeakMs() { return gWaitPeak; }

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
    int fails = 0, restarts = 0; // calls that failed in a row, and sessions restarted over it
    while (!gQuit) {
        double idle = nowSec() - gLastAsk.load();
        int ww = gWantW, wh = gWantH, wm = gWantM;
        if (idle > kIdleEnd) {
            if (gReadyM) { flyhigh::stop(); gReadyM = 0; if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; } }
            if (proc) {
                [proc endSession];
                proc = nil;
                if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; }
            }
            gState = 0; gReadyW = gReadyH = 0; // also after a failed start, so the next use tries again
            fails = restarts = 0;
            flyhigh::retry(); // a start can fail over a busy gpu, not only over its files: the next use looks again
            usleep(20000);
            continue;
        }
        bool other = ww != gReadyW || wh != gReadyH || wm != gReadyM;
        if (ww > 0 && other && wm) {
            // the second generator. files that turn out unusable are refused in there, model() is then 0 and the
            // render thread asks for apple's on its next frame
            @autoreleasepool {
                if (proc) { [proc endSession]; proc = nil; }
                if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; }
                gState = 1;
                double t0 = nowSec();
                bool ok = flyhigh::start(ww, wh, wm == 2 ? 720 : 480);
                if (ok) {
                    NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), (id)kCVPixelBufferWidthKey: @(ww),
                                        (id)kCVPixelBufferHeightKey: @(wh), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
                    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &dstPool);
                    ok = dstPool != NULL;
                }
                gReadyW = ww; gReadyH = wh; gReadyM = wm;
                os_unfair_lock_lock(&gLock); gRingN = gRingAt = 0; os_unfair_lock_unlock(&gLock); gPeak = 0; // another generator or size: its times are its own
                gState = ok ? 2 : 3;
                fails = 0; // not restarts: this is also where a session is started again after 30 failed frames
                logLine("frame generation %s for %dx%d, second generator at %d lines (%.0f ms)%s%s", ok ? "ready" : "unavailable", ww, wh, wm == 2 ? 720 : 480,
                        (nowSec() - t0) * 1000, ok ? "" : ": ", ok ? "" : flyhigh::note());
            }
            continue;
        }
        if (ww > 0 && other && !(gState == 3 && ww == gReadyW && wh == gReadyH && wm == gReadyM)) {
            @autoreleasepool {
                if (gReadyM) { flyhigh::stop(); gReadyM = 0; }
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
                os_unfair_lock_lock(&gLock); gRingN = gRingAt = 0; os_unfair_lock_unlock(&gLock); gPeak = 0;
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
            // spinning, not sleeping, for the same reason as above. 50 ms: something broke, go on with what is there
            double wait = 0;
            if (r.ready) {
                while (!r.ready() && gWanted == r.ticket && nowSec() - r.asked < 0.05) {}
                wait = (nowSec() - r.asked) * 1000;
            }
            gWaitPeak = fmax(wait, gWaitPeak.load() * 0.995);
            double t = nowSec();
            CVPixelBufferRef dst = NULL;
            bool ok = false, tried = false;
            bool sizeOk = gState == 2 && (int)CVPixelBufferGetWidth(r.cur) == gReadyW && (int)CVPixelBufferGetHeight(r.cur) == gReadyH;
            if (sizeOk && gReadyM && gWanted == r.ticket && CVPixelBufferPoolCreatePixelBuffer(NULL, dstPool, &dst) == kCVReturnSuccess) {
                tag709(dst);
                tried = true;
                ok = flyhigh::generate(r.prev, r.cur, dst, r.full, r.sd);
                if (!ok && fails == 0) logLine("frame generation: a frame failed (second generator)");
            } else if (sizeOk && gWanted == r.ticket && CVPixelBufferPoolCreatePixelBuffer(NULL, dstPool, &dst) == kCVReturnSuccess) {
                tag709(dst);
                VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:r.prev presentationTimeStamp:CMTimeMake(0, 30000)];
                VTFrameProcessorFrame *fc = [[VTFrameProcessorFrame alloc] initWithBuffer:r.cur presentationTimeStamp:CMTimeMake(1001, 30000)];
                VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMake(500, 30000)];
                VTLowLatencyFrameInterpolationParameters *p = [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fc previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
                NSError *err = nil;
                tried = true;
                ok = p && [proc processWithParameters:p error:&err];
                if (!ok && fails == 0) logLine("frame generation: a frame failed%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
            }
            // a session can start fine and then fail every frame. it still said "ready" then and nothing was generated:
            // start a new one, and give up (visible in the overlay) if that keeps failing too
            if (ok) fails = restarts = 0;
            else if (tried && ++fails >= 30) {
                fails = 0;
                if (++restarts > 2) { gState = 3; logLine("frame generation: keeps failing, stopped until it is turned off and on"); }
                else { gReadyW = gReadyH = 0; logLine("frame generation: 30 frames failed in a row, starting a new session"); }
            }
            double ms = (nowSec() - t) * 1000;
            bool keep = ok && gWanted == r.ticket;
            os_unfair_lock_lock(&gLock);
            CVPixelBufferRef old = gResult;
            gResult = keep ? dst : NULL;
            gResultTicket = r.ticket;
            if (ok) { gS.sumMs += ms; gS.n++; if (ms > gS.maxMs) gS.maxMs = ms; gPeak = fmax(ms, gPeak.load() * 0.995); gLast = ms; }
            if (ok) { gRing[gRingAt] = (float)ms; gRingAt = (gRingAt + 1) % 120; if (gRingN < 120) gRingN++; }
            if (r.ready) { gS.waitSum += wait; gS.waitN++; if (wait > gS.waitMax) gS.waitMax = wait; }
            dispatch_semaphore_t tell = gTell;
            gTell = nil;
            os_unfair_lock_unlock(&gLock);
            if (tell) dispatch_semaphore_signal(tell);
            if (old) CFRelease(old);
            if (dst && !keep) CFRelease(dst);
            CFRelease(r.prev); CFRelease(r.cur);
            dispatch_semaphore_signal(gDone);
        }
    }
    if (gReadyM) flyhigh::stop();
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
