// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <Cocoa/Cocoa.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#include "common.h"
#include "record.h"
#include <atomic>
#include <cmath>
#include <deque>
#include <memory>
#include <os/lock.h>
#include <sys/mount.h>
#include <vector>

// threads: copy() and light() on the render thread, sound() on the audio output thread, the rest of the api on the
// main thread. everything that touches the encoder, the ring or the open file runs on gQ. a save writes on gSaveQ
// from its own copy of the ring, so keeping goes on meanwhile.
namespace record {

static const int kRate = 48000;
static const int kFlight = 6;              // frames copied but not yet handed to the encoder. more: the file loses one
static const double kLowDisk = 2e9;        // bytes free under which a recording stops itself

static id<MTLDevice> gDev;
static CVMetalTextureCacheRef gCache;
static dispatch_queue_t gQ, gSaveQ;
static dispatch_group_t gSaves;
static void (^gSay)(NSString *);
static std::atomic<int> gState{0};
static std::atomic<bool> gStopping{false};  // a recording that is being closed: nothing new is copied, what is on its way still lands in the file
static std::atomic<bool> gOverlay{false};
static std::atomic<double> gFlash{0};      // a save was asked for: the light is white until then
static std::atomic<double> gSince{0};      // when the recording was started, for the counter
static id<MTLTexture> gLight[3];           // keeping, recording, saved

// the pool the render thread draws its buffers from. swapped by gQ when the size changes
static os_unfair_lock gPoolLock = OS_UNFAIR_LOCK_INIT;
static CVPixelBufferPoolRef gPool;
static int gPoolW, gPoolH;
static std::atomic<bool> gMaking{false};
static std::atomic<bool> gSrgb{true};         // how the window reads the numbers: the file says the same
static std::atomic<int> gMaxH{0};            // the file is at most this high, 0: as shown
static std::atomic<int> gFlight{0}, gLost{0};

// gQ only
static VTCompressionSessionRef gVT;
static int gW, gH;
static intptr_t gGen;                      // which encoder: frames still coming out of the one before are not this file's
static double gLastPts, gFirstPts;
static bool gHole, gWantKey;               // a frame did not get into the file: the ones after it lean on it, none until the next key frame
static long gFrames, gBytes;
static AVAssetWriter *gWr;
static AVAssetWriterInput *gVIn, *gAIn;
static NSString *gName;
struct Kept { CMSampleBufferRef sb; double pts; bool key; long bytes; };
static std::deque<Kept> gRing;             // encoded video, oldest first, starts on a key frame
static std::deque<Kept> gRingA;            // pcm sound, one buffer per output callback
static long gRingBytes;
static double gKeepSec = 30;

// sound: the output callback copies into a ring and notes where each call began and when it is heard
static const int64_t kSnd = 1 << 16;       // stereo frames, 1.36 s
static float gSnd[kSnd * 2];
struct Chunk { int64_t at; unsigned n; double t; };
static Chunk gChunk[256];
static std::atomic<int64_t> gSndW{0};
static std::atomic<unsigned> gChunkW{0};
static unsigned gChunkR;                   // gQ
static double gSndNext;                    // gQ: the time the next buffer gets when the sound runs on unbroken
static CMAudioFormatDescriptionRef gAFmt;

static void say(NSString *t) { logLine("record: %s", t.UTF8String); if (gSay) dispatch_async(dispatch_get_main_queue(), ^{ gSay(t); }); }
static CMTime cm(double t) { return CMTimeMake((int64_t)llround(t * 1e6), 1000000); }
static NSString *mmss(double s) { return [NSString stringWithFormat:@"%d:%02d", (int)s / 60, (int)s % 60]; }

NSString *folder() {
    NSString *d = [NSUserDefaults.standardUserDefaults stringForKey:@"recDir"]; // hidden
    if (!d.length) d = [NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"meyra"];
    return d.stringByExpandingTildeInPath;
}
static double diskFree() {
    struct statfs s;
    return statfs(folder().fileSystemRepresentation, &s) == 0 ? (double)s.f_bavail * s.f_bsize : 1e18;
}
static NSURL *newFile(NSString *what) {
    [NSFileManager.defaultManager createDirectoryAtPath:folder() withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *base = [NSString stringWithFormat:@"meyra %@%@", [f stringFromDate:NSDate.date], what];
    NSString *p = [folder() stringByAppendingPathComponent:[base stringByAppendingString:@".mov"]];
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:p]; i++) p = [folder() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.mov", base, i]];
    return [NSURL fileURLWithPath:p];
}

static void dropRing() {
    for (auto &k : gRing) CFRelease(k.sb);
    for (auto &k : gRingA) CFRelease(k.sb);
    gRing.clear(); gRingA.clear(); gRingBytes = 0;
}

static NSDictionary *aac() {
    return @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(kRate), AVNumberOfChannelsKey: @2, AVEncoderBitRateKey: @256000};
}

// the file of a recording is opened by its first key frame: the writer wants the encoder's format
static bool openFile(CMSampleBufferRef first, bool withSound) {
    NSError *e = nil;
    NSURL *u = newFile(@"");
    gWr = [[AVAssetWriter alloc] initWithURL:u fileType:AVFileTypeQuickTimeMovie error:&e];
    if (!gWr) { say([NSString stringWithFormat:@"recording: no file (%@)", e.localizedDescription]); return false; }
    gWr.movieFragmentInterval = CMTimeMake(10, 1); // a crash or a kill leaves a file that plays up to the last ten seconds
    gVIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:CMSampleBufferGetFormatDescription(first)];
    gVIn.expectsMediaDataInRealTime = YES;
    [gWr addInput:gVIn];
    gAIn = nil;
    if (withSound && gAFmt) {
        gAIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:aac() sourceFormatHint:gAFmt];
        gAIn.expectsMediaDataInRealTime = YES;
        if ([gWr canAddInput:gAIn]) [gWr addInput:gAIn]; else gAIn = nil;
    }
    if (![gWr startWriting]) { say([NSString stringWithFormat:@"recording: no file (%@)", gWr.error.localizedDescription]); gWr = nil; gVIn = gAIn = nil; return false; }
    [gWr startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(first)];
    gName = u.lastPathComponent;
    gFirstPts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first));
    gFrames = 0; gBytes = 0;
    return true;
}

static void closeFile(bool wait, NSString *why) {
    if (!gWr) return;
    AVAssetWriter *w = gWr;
    NSString *name = gName;
    double len = gLastPts - gFirstPts;
    long frames = gFrames;
    int lost = gLost.exchange(0);
    AVAssetWriterInput *vi = gVIn, *ai = gAIn;
    gWr = nil; gName = nil; gVIn = gAIn = nil;
    if (w.status != AVAssetWriterStatusWriting) { // a writer that gave up takes no more calls. the file plays up to its last fragment
        say([NSString stringWithFormat:@"recording failed: %@", w.error.localizedDescription ?: @"unknown"]);
        return;
    }
    [vi markAsFinished];
    [ai markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [w finishWritingWithCompletionHandler:^{
        if (w.status == AVAssetWriterStatusCompleted)
            say([NSString stringWithFormat:@"%@saved %@  (%@, %ld frames%@)", why ?: @"", name, mmss(len), frames, lost ? [NSString stringWithFormat:@", %d lost", lost] : @""]);
        else say([NSString stringWithFormat:@"recording failed: %@", w.error.localizedDescription ?: @"unknown"]);
        dispatch_semaphore_signal(done);
    }];
    if (wait) dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

static void endSession() {
    os_unfair_lock_lock(&gPoolLock);
    CVPixelBufferPoolRef old = gPool;
    gPool = NULL; gPoolW = gPoolH = 0;
    os_unfair_lock_unlock(&gPoolLock);
    if (old) CFRelease(old);
    if (gVT) { VTCompressionSessionInvalidate(gVT); CFRelease(gVT); gVT = NULL; }
    gW = gH = 0;
}

// sound that came since the last call, as one buffer per output callback
static void takeSound() {
    unsigned w = gChunkW.load();
    if (w - gChunkR > 200) { gChunkR = w - 200; gSndNext = 0; } // not drained for too long: the oldest are overwritten
    for (; gChunkR != w; gChunkR++) {
        Chunk c = gChunk[gChunkR & 255];
        if (c.n == 0 || gSndW.load() - c.at > kSnd - 4096) { gSndNext = 0; continue; }
        if (!gAFmt) {
            AudioStreamBasicDescription f = {(Float64)kRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked, 8, 1, 8, 2, 32, 0};
            CMAudioFormatDescriptionCreate(NULL, &f, 0, NULL, 0, NULL, NULL, &gAFmt);
        }
        // counted on from the last buffer while the device's own time agrees within 50 ms: its timestamps wobble by a
        // fraction of a ms, and sound with gaps that small in it clicks. a hundredth of the difference is taken up each
        // time, so a device whose clock runs a little off the mac's stays in step over an hour. further off: the stream
        // broke, start anew
        double off = c.t - gSndNext, t = gSndNext > 0 && fabs(off) < 0.05 ? gSndNext + off * 0.01 : c.t;
        gSndNext = t + c.n / (double)kRate;
        int st = gState;
        bool file = st == 2 && gAIn && t >= gFirstPts;
        if (!file && st != 1) continue;
        size_t bytes = (size_t)c.n * 8;
        CMBlockBufferRef bb = NULL;
        if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes, kCMBlockBufferAssureMemoryNowFlag, &bb) != noErr) continue;
        int64_t a = c.at & (kSnd - 1), n1 = std::min<int64_t>(c.n, kSnd - a);
        CMBlockBufferReplaceDataBytes(gSnd + a * 2, bb, 0, (size_t)n1 * 8);
        if (n1 < c.n) CMBlockBufferReplaceDataBytes(gSnd, bb, (size_t)n1 * 8, (size_t)(c.n - n1) * 8);
        CMSampleBufferRef sb = NULL;
        OSStatus r = CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, bb, gAFmt, c.n, cm(t), NULL, &sb);
        CFRelease(bb);
        if (r != noErr || !sb) continue;
        if (file) { if (gWr.status == AVAssetWriterStatusWriting && gAIn.readyForMoreMediaData) [gAIn appendSampleBuffer:sb]; CFRelease(sb); }
        else gRingA.push_back({sb, t, true, (long)bytes});
    }
}

static void stopRecording(bool wait, NSString *why) {
    if (gVT) VTCompressionSessionCompleteFrames(gVT, kCMTimeInvalid); // its last frames are queued on gQ behind this block
    auto fin = ^{ takeSound(); closeFile(wait, why); gState = 0; gStopping = false; endSession(); };
    if (wait) fin(); else dispatch_async(gQ, fin);
}

// an encoded frame, in the order shown
static void video(CMSampleBufferRef sb) {
    int st = gState;
    CFArrayRef at = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    bool key = !(at && CFArrayGetCount(at) && CFDictionaryContainsKey((CFDictionaryRef)CFArrayGetValueAtIndex(at, 0), kCMSampleAttachmentKey_NotSync));
    double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
    long bytes = (long)CMSampleBufferGetTotalSampleSize(sb);
    if (st == 2) {
        if (!gWr) {
            static double shut; // a file that could not be opened is not tried again on every frame
            if (!key || gStopping || nowSec() < shut) return;
            if (diskFree() < kLowDisk) { gState = 0; say(@"recording: the disk is nearly full, not started"); dispatch_async(gQ, ^{ endSession(); }); return; }
            if (!openFile(sb, gChunkW.load() != gChunkR || gSndNext > 0)) { shut = nowSec() + 5; gState = 0; dispatch_async(gQ, ^{ endSession(); }); return; }
        }
        if (gWr.status != AVAssetWriterStatusWriting) { gState = 0; closeFile(false, nil); dispatch_async(gQ, ^{ endSession(); }); return; }
        if (gHole && !key) { gLost++; return; }
        gHole = !(gVIn.readyForMoreMediaData && [gVIn appendSampleBuffer:sb]);
        if (gHole) { gLost++; gWantKey = true; } else { gFrames++; gBytes += bytes; }
        if (gFrames % 600 == 599 && !gStopping && diskFree() < kLowDisk) { gStopping = true; stopRecording(false, @"the disk is nearly full: "); }
    } else if (st == 1) {
        if (gRing.empty() && !key) return;
        CFRetain(sb);
        gRing.push_back({sb, pts, key, bytes});
        gRingBytes += bytes;
        // whole groups go, from the oldest: while the one after it still reaches back far enough, or the lot is too much
        long cap = (long)(gKeepSec * 40e6); // bytes. about ten times what 30 s at 1440p come to
        for (;;) {
            size_t k = 1;
            while (k < gRing.size() && !gRing[k].key) k++;
            if (k >= gRing.size() || !(gRing[k].pts <= pts - gKeepSec || gRingBytes > cap)) break;
            for (size_t i = 0; i < k; i++) { gRingBytes -= gRing.front().bytes; CFRelease(gRing.front().sb); gRing.pop_front(); }
        }
        while (!gRingA.empty() && gRingA.front().pts < gRing.front().pts - 0.5) { CFRelease(gRingA.front().sb); gRingA.pop_front(); }
    }
}

static void encoded(void *gen, void *, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    if (status != noErr || !sb || (flags & kVTEncodeInfo_FrameDropped)) { gLost++; return; }
    CFRetain(sb);
    dispatch_async(gQ, ^{ if ((intptr_t)gen == gGen) video(sb); CFRelease(sb); });
}

static void makeSession(int w, int h) {
    if (gState == 2 && gWr) closeFile(false, @"size, bitrate or colour changed: "); // goes on in a new file
    if (gState == 1 && gRing.size() > 1) say(@"size, bitrate or colour changed: keeping starts over"); // one file cannot hold two sizes
    dropRing();
    gHole = gWantKey = false;
    endSession();
    gLastPts = 0;
    NSDictionary *spec = @{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
    OSStatus r = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_HEVC, (__bridge CFDictionaryRef)spec, NULL, NULL, encoded, (void *)++gGen, &gVT);
    if (r != noErr || !gVT) {
        gVT = NULL; gState = 0;
        say([NSString stringWithFormat:@"recording: no hardware encoder for %dx%d (%d)", w, h, (int)r]);
        return;
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    gKeepSec = fmin(300, fmax(5, [d objectForKey:@"recKeepSeconds"] ? [d doubleForKey:@"recKeepSeconds"] : 30));
    // 0.3 bits a pixel at 60 frames: 37 mbit at 1080p, 66 at 1440p. grain and a later upload both want bits
    double mbit = [d doubleForKey:@"recMbit"] > 0 ? [d doubleForKey:@"recMbit"] : fmin(200, fmax(12, w * (double)h * 60 * 0.3 / 1e6));
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse); // what is kept can then be cut at any key frame
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@((long)(mbit * 1e6)));
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@60);
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFNumberRef)@1);
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    // the tone curve the window is shown with. tagged bt.709 while the window is srgb, players show the file flatter than the screen was
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_TransferFunction, gSrgb ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(gVT, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    VTCompressionSessionPrepareToEncodeFrames(gVT);
    NSDictionary *pa = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                         (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)pa, &pool);
    gW = w; gH = h;
    os_unfair_lock_lock(&gPoolLock);
    gPool = pool; gPoolW = w; gPoolH = h;
    os_unfair_lock_unlock(&gPoolLock);
    logLine("record: encoder %dx%d hevc, %.0f mbit", w, h, mbit);
}

struct Frame { CVPixelBufferRef pb; CVMetalTextureRef mt; std::atomic<int> left{2}; std::atomic<double> shown{0}; double handed; };

static void encode(Frame *f) {
    gFlight--;
    double shown = f->shown.load(), pts = shown > 0 ? shown : f->handed; // not on a screen: the time it was handed over
    if (gVT && gState && (int)CVPixelBufferGetWidth(f->pb) == gW && (int)CVPixelBufferGetHeight(f->pb) == gH && pts > gLastPts) {
        gLastPts = pts;
        static CFDictionaryRef keyNow = (__bridge_retained CFDictionaryRef)@{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
        if (VTCompressionSessionEncodeFrame(gVT, f->pb, cm(pts), kCMTimeInvalid, gWantKey ? keyNow : NULL, NULL, NULL) != noErr) gLost++;
        gWantKey = false;
    }
    CFRelease(f->mt);
    CFRelease(f->pb);
    delete f;
    takeSound();
}

void copy(id<MTLCommandBuffer> cb, id<CAMetalDrawable> dr, int x, int y, int w, int h) {
    if (!gState || gStopping || !dr) return;
    id<MTLTexture> t = dr.texture;
    if (t.framebufferOnly || t.pixelFormat != MTLPixelFormatBGRA8Unorm) return; // a drawable from before the layer was told
    x = std::max(0, x); y = std::max(0, y);
    w = std::min(w, (int)t.width - x) & ~1; h = std::min(h, (int)t.height - y) & ~1;
    if (w < 64 || h < 64) return;
    int cap = gMaxH, ow = w, oh = h; // what the file gets: the picture's pixels, or scaled down to the height asked for
    if (cap >= 64 && h > cap) { oh = cap & ~1; ow = (int)lround(w * (double)oh / h) & ~1; }
    os_unfair_lock_lock(&gPoolLock);
    CVPixelBufferPoolRef pool = gPoolW == ow && gPoolH == oh ? gPool : NULL;
    if (pool) CFRetain(pool);
    os_unfair_lock_unlock(&gPoolLock);
    if (!pool) { // first frame, or another size: the encoder is made off this thread, frames until then are not in the file
        if (!gMaking.exchange(true)) dispatch_async(gQ, ^{ if (gState) makeSession(ow, oh); gMaking = false; });
        return;
    }
    if (gFlight >= kFlight) { gLost++; CFRelease(pool); return; }
    static CFDictionaryRef aux = (__bridge_retained CFDictionaryRef)@{(id)kCVPixelBufferPoolAllocationThresholdKey: @(kFlight + 8)};
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, pool, aux, &pb);
    CFRelease(pool);
    if (r != kCVReturnSuccess || !pb) { gLost++; return; }
    CVMetalTextureRef mt = NULL;
    static CFDictionaryRef use = (__bridge_retained CFDictionaryRef)@{(id)kCVMetalTextureUsage: @(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget)};
    CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, use, MTLPixelFormatBGRA8Unorm, ow, oh, 0, &mt);
    id<MTLTexture> dst = mt ? CVMetalTextureGetTexture(mt) : nil;
    if (!dst) { if (mt) CFRelease(mt); CFRelease(pb); gLost++; return; }
    if (ow == w && oh == h) {
        id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
        [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [e endEncoding];
    } else { // smaller: lanczos on the gpu, in the same command buffer
        static MPSImageLanczosScale *sc = [[MPSImageLanczosScale alloc] initWithDevice:gDev];
        MPSScaleTransform tr = {ow / (double)w, oh / (double)h, -x * (ow / (double)w), -y * (oh / (double)h)};
        sc.scaleTransform = &tr;
        [sc encodeToCommandBuffer:cb sourceTexture:t destinationTexture:dst];
        sc.scaleTransform = NULL;
    }
    gFlight++;
    Frame *f = new Frame;
    f->pb = pb; f->mt = mt; f->handed = nowSec();
    // to the encoder when the gpu is done with it and the screen has said when it showed it. neither handler does work:
    // the frame generator may be waiting behind them
    auto done = ^{ if (--f->left == 0) dispatch_async(gQ, ^{ encode(f); }); };
    [dr addPresentedHandler:^(id<MTLDrawable> d) { f->shown = d.presentedTime; done(); }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { done(); }];
}

static void again() {
    os_unfair_lock_lock(&gPoolLock);
    gPoolW = gPoolH = 0;
    os_unfair_lock_unlock(&gPoolLock);
}
void colour(bool srgb) { if (gSrgb.exchange(srgb) != srgb) again(); }

void limit(int maxH) { // the next frame finds no pool of its size: a new encoder, and a new file when one is open
    gMaxH = maxH;
    again();
}

void sound(const float *s, unsigned n, double t) {
    if (!gState || n == 0 || n > 8192) return;
    int64_t w = gSndW.load(std::memory_order_relaxed), a = w & (kSnd - 1), n1 = std::min<int64_t>(n, kSnd - a);
    memcpy(gSnd + a * 2, s, (size_t)n1 * 8);
    if (n1 < n) memcpy(gSnd, s + n1 * 2, (size_t)(n - n1) * 8);
    unsigned c = gChunkW.load(std::memory_order_relaxed);
    gChunk[c & 255] = {w, n, t};
    gSndW.store(w + n);
    gChunkW.store(c + 1);
}

// the mark: an amber dot while the last seconds are kept, a red one while recording, white for a moment after a save
static id<MTLTexture> dot(float r, float g, float b) {
    const int n = 64;
    std::vector<uint8_t> px(n * n * 4);
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        float a = std::clamp(n / 2 - hypotf(x + 0.5f - n / 2, y + 0.5f - n / 2), 0.0f, 1.0f); // the disc, one pixel of soft edge
        uint8_t *p = &px[(y * n + x) * 4];                                                       // bgra, premultiplied
        p[0] = (uint8_t)(b * a * 255); p[1] = (uint8_t)(g * a * 255); p[2] = (uint8_t)(r * a * 255); p[3] = (uint8_t)(a * 255);
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:n height:n mipmapped:NO];
    id<MTLTexture> t = [gDev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:0 withBytes:px.data() bytesPerRow:n * 4];
    return t;
}
id<MTLTexture> light() {
    int st = state();
    if (st && nowSec() < gFlash) return gLight[2];
    return st == 2 ? gLight[1] : st == 1 ? gLight[0] : nil;
}

// how long the recording has run: small white digits with a dark edge. scale: screen pixels a point.
// render thread. drawn anew when the second changes
id<MTLTexture> counter(double scale) {
    static id<MTLTexture> tex;
    static int was = -1;
    static double wasScale;
    if (state() != 2) return nil;
    int sec = std::max(0, (int)(nowSec() - gSince));
    scale = std::clamp(scale, 1.0, 4.0);
    if (tex && sec == was && scale == wasScale) return tex;
    NSString *t = sec >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60] : [NSString stringWithFormat:@"%d:%02d", sec / 60, sec % 60];
    NSFont *f = [NSFont monospacedDigitSystemFontOfSize:11 * scale weight:NSFontWeightSemibold];
    CTLineRef ln[2];
    for (int i = 0; i < 2; i++) {
        CGColorRef c = CGColorGetConstantColor(i ? kCGColorWhite : kCGColorBlack);
        ln[i] = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:t attributes:@{(id)kCTFontAttributeName: f, (id)kCTForegroundColorAttributeName: (__bridge id)c}]);
    }
    CGFloat asc = 0, desc = 0, e = round(scale); // e: the edge
    int w = (int)ceil(CTLineGetTypographicBounds(ln[1], &asc, &desc, NULL) + 2 * e) + 2, h = (int)ceil(asc + desc + 2 * e);
    std::vector<uint8_t> px(w * h * 4, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetAlpha(ctx, 0.6); // the edge: the same text in black all around, soft where they overlap less
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) if (dx || dy) { CGContextSetTextPosition(ctx, 1 + e + dx * e, e + desc + dy * e); CTLineDraw(ln[0], ctx); }
    CGContextSetAlpha(ctx, 1);
    CGContextSetTextPosition(ctx, 1 + e, e + desc);
    CTLineDraw(ln[1], ctx);
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    CFRelease(ln[0]); CFRelease(ln[1]);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    tex = [gDev newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px.data() bytesPerRow:w * 4];
    was = sec; wasScale = scale;
    return tex;
}

void init(id<MTLDevice> dev, void (^sayIt)(NSString *)) {
    gDev = dev; gSay = [sayIt copy];
    CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &gCache);
    gQ = dispatch_queue_create("record", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    gSaveQ = dispatch_queue_create("record save", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    gSaves = dispatch_group_create();
    gLight[0] = dot(1.0f, 0.72f, 0.15f);
    gLight[1] = dot(1.0f, 0.16f, 0.14f);
    gLight[2] = dot(1.0f, 1.0f, 1.0f);
}

int state() { return gStopping ? 0 : gState.load(); }
void overlay(bool on) { gOverlay = on; }
bool withOverlay() { return gOverlay; }

static void begin(int st) { // gQ: sound from before now is not this one's
    gChunkR = gChunkW.load(); gSndNext = 0; gLost = 0; gLastPts = 0;
    if (st == 2) gSince = nowSec();
    gHole = gWantKey = false;
    gStopping = false;
    gState = st;
}

void toggle() {
    if (state() == 2) { gStopping = true; dispatch_async(gQ, ^{ stopRecording(false, nil); }); return; }
    dispatch_async(gQ, ^{ dispatch_async(gQ, ^{ dropRing(); endSession(); begin(2); }); }); // behind the closing of the one before
}

void keep(bool on) {
    if (state() == 2) { gStopping = true; dispatch_async(gQ, ^{ stopRecording(false, nil); }); }
    if (on) dispatch_async(gQ, ^{ dispatch_async(gQ, ^{ begin(1); }); }); // behind a recording's last frames
    else { if (gState == 1) gState = 0; dispatch_async(gQ, ^{ dispatch_async(gQ, ^{ if (gState != 2) { dropRing(); if (!gState) endSession(); } }); }); }
}

// the ring as it is now -> a file, on its own queue. video goes in as it was encoded, sound becomes aac
void save() {
    if (gState != 1) return;
    gFlash = nowSec() + 0.7;
    dispatch_async(gQ, ^{
        takeSound();
        if (gRing.size() < 2) { say(@"nothing kept yet"); return; }
        if (diskFree() < kLowDisk) { say(@"not saved: the disk is nearly full"); return; }
        auto v = std::make_shared<std::vector<CMSampleBufferRef>>(), a = std::make_shared<std::vector<CMSampleBufferRef>>();
        double from = gRing.front().pts, to = gRing.back().pts;
        for (auto &k : gRing) { CFRetain(k.sb); v->push_back(k.sb); }
        for (auto &k : gRingA) if (k.pts >= from && k.pts <= to) { CFRetain(k.sb); a->push_back(k.sb); }
        int lost = gLost.exchange(0);
        dispatch_group_async(gSaves, gSaveQ, ^{
            NSError *e = nil;
            NSURL *u = newFile([NSString stringWithFormat:@" last %.0f s", to - from]);
            AVAssetWriter *w = [[AVAssetWriter alloc] initWithURL:u fileType:AVFileTypeQuickTimeMovie error:&e];
            AVAssetWriterInput *vi = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:CMSampleBufferGetFormatDescription(v->front())];
            AVAssetWriterInput *ai = a->empty() ? nil : [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:aac() sourceFormatHint:CMSampleBufferGetFormatDescription(a->front())];
            // as if live: the writer then does not hold one track back until the other has caught up, which with sound
            // encoded on the way in ended with both waiting
            vi.expectsMediaDataInRealTime = YES; ai.expectsMediaDataInRealTime = YES;
            bool ok = w != nil;
            if (ok) {
                [w addInput:vi];
                if (ai && [w canAddInput:ai]) [w addInput:ai]; else ai = nil;
                ok = [w startWriting];
            }
            if (ok) {
                [w startSessionAtSourceTime:cm(from)];
                // both in the order of their times
                auto put = [&](AVAssetWriterInput *in, CMSampleBufferRef sb) {
                    for (int i = 0; !in.readyForMoreMediaData && i < 5000 && w.status == AVAssetWriterStatusWriting; i++) usleep(1000);
                    return in.readyForMoreMediaData && [in appendSampleBuffer:sb];
                };
                size_t ia = 0;
                for (size_t iv = 0; ok && iv < v->size(); iv++) {
                    double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp((*v)[iv]));
                    while (ok && ai && ia < a->size() && CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp((*a)[ia])) <= t) ok = put(ai, (*a)[ia++]);
                    if (ok) ok = put(vi, (*v)[iv]);
                }
                if (!ok) [w cancelWriting]; // takes the half-written file away
                else {
                    [vi markAsFinished];
                    [ai markAsFinished];
                    dispatch_semaphore_t done = dispatch_semaphore_create(0);
                    [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
                    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
                    ok = w.status == AVAssetWriterStatusCompleted;
                }
            }
            if (ok) say([NSString stringWithFormat:@"saved %@  (%zu frames%@)", u.lastPathComponent, v->size(), lost ? [NSString stringWithFormat:@", %d lost", lost] : @""]);
            else say([NSString stringWithFormat:@"not saved: %@", (w.error ?: e).localizedDescription ?: @"the file could not be written"]);
            for (auto sb : *v) CFRelease(sb);
            for (auto sb : *a) CFRelease(sb);
        });
    });
}

void finish() {
    if (!gQ) return;
    gStopping = true; // nothing new is copied. what the encoder still holds comes out and is queued behind the first block
    dispatch_sync(gQ, ^{ if (gState == 2 && gVT) VTCompressionSessionCompleteFrames(gVT, kCMTimeInvalid); });
    dispatch_sync(gQ, ^{ if (gState == 2) takeSound(); closeFile(true, nil); gState = 0; dropRing(); endSession(); });
    dispatch_group_wait(gSaves, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
}

}
