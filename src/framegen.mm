// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#include "framegen.h"
#include "flyhigh.h"
#include "blocks.h"
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
// any rate, see requestAt: the request waiting, the positions of the one being made that are still to come, the
// frames made. its times stay out of gRing and gPeak: those are the schedules' budget, and stay theirs
static const int kAtKeep = 32;            // two pairs' worth and some: takeAt lets the ones gone by go at once
struct AtReq { CVPixelBufferRef prev, cur; long pair; float t[kAtMax]; int n, how; double gap; uint64_t ticket; bool (^ready)(void); double asked; bool full, sd; };
static AtReq gAtReq;                      // under gLock
static std::atomic<bool> gAtPending{false};
static std::atomic<bool> gAtRelease{false}; // dropAt: the block generator's held pair goes, on the generator thread
static long gAtMaking = -1;               // under gLock
static float gAtLeft[kAtMax];
static int gAtLeftN;
struct AtRes { long pair; float t; CVPixelBufferRef pb; };
static AtRes gAt[kAtKeep];                // under gLock, +1 each
static int gAtN;
static uint64_t gAtEpoch;                 // under gLock: dropAt moves it on, a frame made for an older one is not kept
static dispatch_semaphore_t gAtDone;      // a frame was made, or a request ended
static float gAtRing[120];                // under gLock: request -> its frames, the worst against its own slot, ms
static double gAtRingT[120];              // and when each came in: a time no longer being measured ages out (pairMs)
static int gAtRingN, gAtRingAt;
static void ownStop() { flyhigh::stop(); blocks::stop(); } // the generators of our own, either may be up
// the frame log's figures (blocks::measuring()): the solve count, the second's sums under gLock
static const CFStringRef kFigKey = CFSTR("meyra.figures");
static long gPairSeq;                     // generator thread
static PairStats gPs;                     // under gLock

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
    return m == 3 ? (blocks::refused() ? 0 : 3) : m && flyhigh::installed() ? m : 0; // 3 needs no files, only a start that worked
}

const char *modelNote() { return gSet.genModel == 3 ? blocks::note() : gSet.genModel ? flyhigh::note() : ""; }

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

void requestAt(CVPixelBufferRef prev, CVPixelBufferRef cur, long pair, const float *t, int n, int how, double gap, bool (^ready)(void), bool full, bool sd) {
    if (n < 1) return;
    CFRetain(prev); CFRetain(cur);
    AtReq r = {prev, cur, pair, {}, std::min(n, kAtMax), how, gap, gWanted.load(), ready, nowSec(), full, sd}; // not ++: the pair being made is still wanted, cancel() ends both
    for (int i = 0; i < r.n; i++) r.t[i] = t[i];
    os_unfair_lock_lock(&gLock);
    AtReq old = gAtReq;
    bool had = gAtPending.exchange(true);
    gAtReq = r;
    os_unfair_lock_unlock(&gLock);
    if (had) { CFRelease(old.prev); CFRelease(old.cur); } // never got picked up
}

static bool near(const float *t, int n, float x) { for (int i = 0; i < n; i++) if (fabsf(t[i] - x) <= 0.02f) return true; return false; }

CVPixelBufferRef takeAt(long pair, float t, double graceMs) {
    double until = nowSec() + graceMs / 1000;
    while (dispatch_semaphore_wait(gAtDone, DISPATCH_TIME_NOW) == 0) {} // old signals: what they told of is in gAt, the look sees it. else the grace below spins
    for (;;) {
        os_unfair_lock_lock(&gLock);
        int best = -1;
        for (int i = 0; i < gAtN; i++)
            if (gAt[i].pair == pair && fabsf(gAt[i].t - t) <= 0.02f && (best < 0 || fabsf(gAt[i].t - t) < fabsf(gAt[best].t - t))) best = i;
        CVPixelBufferRef pb = best >= 0 ? gAt[best].pb : NULL;
        if (pb) { // shown content never goes back: older pairs and earlier positions of this one go too
            CVPixelBufferRef gone[kAtKeep];
            int w = 0, k = 0;
            float bt = gAt[best].t;
            for (int i = 0; i < gAtN; i++) {
                if (i == best) continue;
                if (gAt[i].pair < pair || (gAt[i].pair == pair && gAt[i].t < bt)) gone[k++] = gAt[i].pb;
                else gAt[w++] = gAt[i];
            }
            gAtN = w;
            os_unfair_lock_unlock(&gLock);
            for (int i = 0; i < k; i++) CFRelease(gone[i]);
            return pb;
        }
        // still to come: waiting, or being made and not done yet. apple's middle only counts once it is picked up
        bool coming = (gAtPending && gAtReq.pair == pair && near(gAtReq.t, gAtReq.n, t)) || (gAtMaking == pair && near(gAtLeft, gAtLeftN, t));
        os_unfair_lock_unlock(&gLock);
        double w = until - nowSec();
        if (!coming || w <= 0) return NULL;
        dispatch_semaphore_wait(gAtDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(w * NSEC_PER_SEC)));
    }
}

bool making() { os_unfair_lock_lock(&gLock); bool m = gAtMaking >= 0; os_unfair_lock_unlock(&gLock); return m; }

bool comingAfter(long pair, float t) {
    bool c = false;
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gAtN && !c; i++) c = gAt[i].pair == pair && gAt[i].t > t + 0.02f;
    if (gAtPending && gAtReq.pair == pair) for (int i = 0; i < gAtReq.n && !c; i++) c = gAtReq.t[i] > t + 0.02f;
    if (gAtMaking == pair) for (int i = 0; i < gAtLeftN && !c; i++) c = gAtLeft[i] > t + 0.02f;
    os_unfair_lock_unlock(&gLock);
    return c;
}

void dropAt() {
    AtRes old[kAtKeep];
    os_unfair_lock_lock(&gLock);
    int n = gAtN;
    memcpy(old, gAt, sizeof old);
    gAtN = 0;
    AtReq r = gAtReq;
    bool had = gAtPending.exchange(false);
    gAtEpoch++;
    gAtRingN = gAtRingAt = 0; // another generator or setting may follow: its own times
    os_unfair_lock_unlock(&gLock);
    gAtRelease = true;
    for (int i = 0; i < n; i++) CFRelease(old[i].pb);
    if (had) { CFRelease(r.prev); CFRelease(r.cur); }
}

// the 95th of the last 120 pairs. none made for 10 s: 0, the renderer's own guess. a stall's times (a budget 7 -> 10
// ms) stayed for good while nothing was made (fixed 60 on 60 fps: all real), d a period up for good. made now and
// then (a dip): the whole ring still, sparse pairs keep their measured time. after 10 s without, the next pair starts
// the ring over (see where it is written)
double pairMs() {
    float v[120];
    double newest = 0;
    os_unfair_lock_lock(&gLock);
    int n = gAtRingN;
    memcpy(v, gAtRing, sizeof v);
    for (int i = 0; i < n; i++) newest = fmax(newest, gAtRingT[i]);
    os_unfair_lock_unlock(&gLock);
    if (n < 20 || nowSec() - newest > 10) return 0;
    int k = n * 95 / 100;
    std::nth_element(v, v + k, v + n);
    return v[k];
}

// under gLock: keep a frame made. a pair's frames are wanted until its slots have gone by: three pairs back at most,
// and no more than kAtKeep (then the lowest pair and position goes: the first a slot passes). what goes is handed back
// to be let go outside the lock
static int keepAt(long pair, float t, CVPixelBufferRef pb, CVPixelBufferRef *out) {
    int w = 0, k = 0;
    for (int i = 0; i < gAtN; i++) { if (gAt[i].pair < pair - 3) out[k++] = gAt[i].pb; else gAt[w++] = gAt[i]; }
    gAtN = w;
    if (gAtN == kAtKeep) {
        int lo = 0;
        for (int i = 1; i < gAtN; i++) if (gAt[i].pair < gAt[lo].pair || (gAt[i].pair == gAt[lo].pair && gAt[i].t < gAt[lo].t)) lo = i;
        out[k++] = gAt[lo].pb;
        gAt[lo] = gAt[--gAtN];
    }
    gAt[gAtN++] = {pair, t, pb};
    return k;
}

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

PairStats takePairStats() {
    os_unfair_lock_lock(&gLock);
    PairStats s = gPs;
    gPs = PairStats();
    os_unfair_lock_unlock(&gLock);
    return s;
}

bool figuresOf(CVPixelBufferRef pb, Figures &f) {
    CFTypeRef d = pb ? CVBufferCopyAttachment(pb, kFigKey, NULL) : NULL;
    bool ok = d && CFGetTypeID(d) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)d) == sizeof f;
    if (ok) CFDataGetBytes((CFDataRef)d, CFRangeMake(0, sizeof f), (UInt8 *)&f);
    if (d) CFRelease(d);
    return ok;
}

// the frame log: a solve's figures into the second's sums, a made frame's onto it (before it is kept: the render
// thread reads them once it can take it) and its fall into the sums
static void pairSolved(const Figures &f, bool have) {
    os_unfair_lock_lock(&gLock);
    PairStats &s = gPs;
    s.n++;
    if (s.nGap < 64) s.gap[s.nGap++] = f.gapMs;
    if (have) { s.nFig++; s.lenSum += f.len; s.lenMax = fmax(s.lenMax, f.len); s.vxSum += f.vx; s.vySum += f.vy; s.errSum += f.err; s.unfitSum += f.unfit; }
    os_unfair_lock_unlock(&gLock);
}
static void frameMade(CVPixelBufferRef dst, const Figures &f) {
    CFDataRef d = CFDataCreate(NULL, (const UInt8 *)&f, sizeof f);
    if (d) { CVBufferSetAttachment(dst, kFigKey, d, kCVAttachmentMode_ShouldNotPropagate); CFRelease(d); }
    if (f.fall < 0) return;
    os_unfair_lock_lock(&gLock);
    gPs.fallN++; gPs.fallSum += f.fall; gPs.fallMax = fmax(gPs.fallMax, f.fall);
    os_unfair_lock_unlock(&gLock);
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
        if (gAtRelease.exchange(false) && gReadyM == 3) blocks::release();
        double idle = nowSec() - gLastAsk.load();
        int ww = gWantW, wh = gWantH, wm = gWantM;
        if (idle > kIdleEnd) {
            if (gReadyM) { ownStop(); gReadyM = 0; if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; } }
            if (proc) {
                [proc endSession];
                proc = nil;
                if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; }
            }
            gState = 0; gReadyW = gReadyH = 0; // also after a failed start, so the next use tries again
            fails = restarts = 0;
            flyhigh::retry(); // a start can fail over a busy gpu, not only over its files: the next use looks again
            blocks::retry();
            usleep(20000);
            continue;
        }
        bool other = ww != gReadyW || wh != gReadyH || wm != gReadyM;
        if (ww > 0 && other && wm) {
            // the second generator. files that turn out unusable are refused in there, model() is then 0 and the
            // render thread asks for apple's on its next frame. 3: the block generator, refused when it cannot start
            @autoreleasepool {
                if (proc) { [proc endSession]; proc = nil; }
                if (dstPool) { CVPixelBufferPoolRelease(dstPool); dstPool = NULL; }
                gState = 1;
                double t0 = nowSec();
                ownStop();
                bool ok = wm == 3 ? blocks::start(ww, wh) : flyhigh::start(ww, wh, wm == 2 ? 720 : 480);
                if (ok) {
                    NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), (id)kCVPixelBufferWidthKey: @(ww),
                                        (id)kCVPixelBufferHeightKey: @(wh), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
                    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &dstPool);
                    ok = dstPool != NULL || (wm == 3 && blocks::refuse("no output buffers")); // 3: apple's takes over
                }
                gReadyW = ww; gReadyH = wh; gReadyM = wm;
                os_unfair_lock_lock(&gLock); gRingN = gRingAt = 0; os_unfair_lock_unlock(&gLock); gPeak = 0; // another generator or size: its times are its own
                gState = ok ? 2 : 3;
                fails = 0; // not restarts: this is also where a session is started again after 30 failed frames
                const char *why = ok ? "" : wm == 3 ? blocks::note() : flyhigh::note();
                logLine("frame generation %s for %dx%d, %s (%.0f ms)%s%s", ok ? "ready" : "unavailable", ww, wh, wm == 3 ? "block generator" : wm == 2 ? "second generator at 720 lines" : "second generator at 480 lines",
                        (nowSec() - t0) * 1000, *why ? ": " : "", why);
            }
            continue;
        }
        if (ww > 0 && other && !(gState == 3 && ww == gReadyW && wh == gReadyH && wm == gReadyM)) {
            @autoreleasepool {
                if (gReadyM) { ownStop(); gReadyM = 0; }
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
        if (gAtPending.load(std::memory_order_relaxed)) { // any rate: one pair, its positions one after the other
            os_unfair_lock_lock(&gLock);
            if (!gAtPending.exchange(false)) { os_unfair_lock_unlock(&gLock); continue; } // dropAt let it go in between
            AtReq r = gAtReq;
            bool any = gReadyM == 3; // the block generator. the others: the middle, once
            float at[kAtMax];
            int m = 0;
            for (int i = 0; i < r.n && (any || !m); i++) if (any || fabsf(r.t[i] - 0.5f) <= 0.02f) at[m++] = any ? r.t[i] : 0.5f;
            gAtMaking = r.pair; gAtLeftN = m;
            memcpy(gAtLeft, at, sizeof at);
            uint64_t epoch = gAtEpoch;
            os_unfair_lock_unlock(&gLock);
            @autoreleasepool {
                double wait = 0;
                if (r.ready && m) { // as below
                    while (!r.ready() && gWanted == r.ticket && nowSec() - r.asked < 0.05) {}
                    wait = (nowSec() - r.asked) * 1000;
                }
                bool sizeOk = gState == 2 && (int)CVPixelBufferGetWidth(r.cur) == gReadyW && (int)CVPixelBufferGetHeight(r.cur) == gReadyH;
                bool ok = sizeOk && m && gWanted == r.ticket, tried = false;
                double worst = -1; // made - asked - (t - t0) * gap: each frame against its own slot, the worst of the pair
                double solveMs = 0; // the overlay's generator time: the pair's first frame carries the solve (the old path's had it inside)
                if (ok && any) { tried = true; double ts = nowSec(); ok = blocks::solve(r.prev, r.cur, r.full, r.sd, !(r.how & blocks::kTimeBlend), r.how); solveMs = (nowSec() - ts) * 1000; }
                bool measure = any && blocks::measuring(); // the frame log only
                Figures fig = {};
                if (measure && ok) {
                    blocks::Figures b;
                    bool have = blocks::lastFigures(b);
                    fig = {++gPairSeq, (float)(r.gap * 1000), have ? b.vx : NAN, have ? b.vy : NAN, have ? b.len : NAN, have ? b.err : NAN, have ? b.unfit : NAN, -1};
                    pairSolved(fig, have);
                }
                for (int i = 0; i < m && ok && gWanted == r.ticket; i++) {
                    double t = nowSec();
                    // back-pressure: a newer pair waits and this one has taken longer than its gap. the rest of this
                    // one is dropped (those slots show what is up) so the newer is not replaced unmade: before, every
                    // second pair at 4k with 16 positions was skipped whole
                    if (i > 0 && gAtPending.load(std::memory_order_relaxed) && r.gap > 0 && t - r.asked > r.gap) break;
                    CVPixelBufferRef dst = NULL, gone[kAtKeep];
                    int ng = 0;
                    if (CVPixelBufferPoolCreatePixelBuffer(NULL, dstPool, &dst) != kCVReturnSuccess) { ok = false; break; }
                    tag709(dst);
                    tried = true;
                    if (any) {
                        ok = blocks::frame(at[i], dst, r.how);
                        if (ok && measure) { fig.fall = blocks::lastFall(); frameMade(dst, fig); }
                    } else if (gReadyM) ok = flyhigh::generate(r.prev, r.cur, dst, r.full, r.sd);
                    else {
                        VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:r.prev presentationTimeStamp:CMTimeMake(0, 30000)];
                        VTFrameProcessorFrame *fc = [[VTFrameProcessorFrame alloc] initWithBuffer:r.cur presentationTimeStamp:CMTimeMake(1001, 30000)];
                        VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMake(500, 30000)];
                        VTLowLatencyFrameInterpolationParameters *p = [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fc previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
                        ok = p && proc && [proc processWithParameters:p error:nil];
                    }
                    double now = nowSec(), ms = (now - t) * 1000;
                    os_unfair_lock_lock(&gLock);
                    for (int k = 0; k < gAtLeftN; k++) if (gAtLeft[k] == at[i]) { gAtLeft[k] = gAtLeft[--gAtLeftN]; break; }
                    bool keep = ok && epoch == gAtEpoch; // made for a path that has since started over: not kept
                    if (keep) ng = keepAt(r.pair, at[i], dst, gone);
                    if (ok) { ms += solveMs; solveMs = 0; gS.sumMs += ms; gS.n++; if (ms > gS.maxMs) gS.maxMs = ms; gLast = ms; }
                    if (ok) worst = fmax(worst, (now - r.asked - (at[i] - at[0]) * r.gap) * 1000);
                    if (r.ready && i == 0) { gS.waitSum += wait; gS.waitN++; if (wait > gS.waitMax) gS.waitMax = wait; }
                    os_unfair_lock_unlock(&gLock);
                    for (int k = 0; k < ng; k++) CFRelease(gone[k]);
                    if (!keep) CFRelease(dst);
                    dispatch_semaphore_signal(gAtDone);
                }
                if (worst >= 0) {
                    os_unfair_lock_lock(&gLock);
                    double now = nowSec(); // the last one 10 s back or more: the ring aged out (pairMs), its times are not
                    // brought back by the first new pair (a stall's 10 ms for 2-4 s more)
                    if (gAtRingN && now - gAtRingT[(gAtRingAt + 119) % 120] > 10) gAtRingN = gAtRingAt = 0;
                    gAtRing[gAtRingAt] = (float)worst; gAtRingT[gAtRingAt] = now; gAtRingAt = (gAtRingAt + 1) % 120; if (gAtRingN < 120) gAtRingN++;
                    os_unfair_lock_unlock(&gLock);
                }
                if (!ok && tried && fails == 0) logLine("frame generation: a frame failed (%s, any rate)", any ? "block generator" : gReadyM ? "second generator" : "apple's");
                if (ok) fails = restarts = 0; // as below
                else if (tried && ++fails >= 30) {
                    fails = 0;
                    if (++restarts > 2) { gState = 3; logLine("frame generation: keeps failing, stopped until it is turned off and on"); }
                    else { gReadyW = gReadyH = 0; logLine("frame generation: 30 frames failed in a row, starting a new session"); }
                }
                os_unfair_lock_lock(&gLock);
                gAtMaking = -1; gAtLeftN = 0;
                os_unfair_lock_unlock(&gLock);
                CFRelease(r.prev); CFRelease(r.cur);
                dispatch_semaphore_signal(gAtDone);
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
                ok = gReadyM == 3 ? blocks::generate(r.prev, r.cur, dst, r.full, r.sd, (gSet.genSmallFast ? blocks::kSmall : 0) | (gSet.genSides ? blocks::kSides : 0) | (gSet.genOutline ? blocks::kStill | blocks::kBand | blocks::kBorder : 0) | (gSet.genSharp ? blocks::kCrisp | blocks::kDetail : 0)) : flyhigh::generate(r.prev, r.cur, dst, r.full, r.sd);
                if (!ok && fails == 0) logLine("frame generation: a frame failed (%s)", gReadyM == 3 ? "block generator" : "second generator");
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
    if (gReadyM) ownStop();
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
    dropAt();
    dispatch_semaphore_signal(gStopped);
}

void startThread() {
    gDone = dispatch_semaphore_create(0);
    gAtDone = dispatch_semaphore_create(0);
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
