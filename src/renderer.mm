// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <MetalFX/MetalFX.h>
#include "awake.h"
#include "display.h"
#include "renderer.h"
#include "cadence.h"
#include "common.h"
#include "framegen.h"
#include "nets.h"
#include "noise.h"
#include "superres.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <os/lock.h>
#include <vector>

namespace renderer {

static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLRenderPipelineState> gPipeYuv, gPipeNv, gPipeNvFix, gPipeOut, gPipeDeband, gPipeHud, gPipeEasu, gPipeSgsr, gPipeDown, gPipeTiles, gPipeTileY, gPipeTileC, gPipeBackY, gPipeBackC, gPipeLock, gPipeNvFixLock, gPipeNvFixHud, gPipeNvFixLockHud, gPipeLook, gPipeCut;
static id<MTLRenderPipelineState> gPipeBox, gPipeKeepAdd, gPipeKeepUse, gPipeHold; // the experimental switches
static CAMetalLayer *gLayer;
static CVMetalTextureCacheRef gCache;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static Stats gS;
static dispatch_semaphore_t gWake;
static std::atomic<double> gFrameDur{1.0 / 59.94};
static std::atomic<double> gScale{2};
static id<MTLTexture> gHudTex;            // under gLock
static id<MTLTexture> gLabelTex;          // under gLock
static std::string gCmpNames;             // under gLock
static MTLScissorRect gSc; static bool gScOn; // render thread: the next passes draw only inside this (compare view)
static NSString *gSnapPath;               // under gLock
// numbered snapshots, for tests: frames still wanted (number, generated), under gLock
static std::vector<std::pair<int, bool>> gSnapWant;
static NSString *gSnapDir;
static double gSnapFrom;
static std::atomic<int> gSnapLeft{-1}, gLoop{0};
void replayLoop(int n) { gLoop = n; }
// frameLog (hidden, for tests): one row per drawn frame, kept in memory and written as csv at quit. the slow frames
// are in the tail, which the once a second averages hide. times in seconds since launch, gpu and gen in ms
struct LogRow { const char *kind; int frame; double arrival, present, presented, gpu, gen; };
static LogRow *gLog;
static const int kLogMax = 200000;        // 55 minutes at 60
static std::atomic<int> gLogN{0};
static NSString *gLogPath;
// debandT (hidden): how far, in levels of 255, the ring average may be from the pixel for dither removal to take it
static float gDebandT = 2.5f;
int snapsLeft() { return gSnapLeft; }
static std::atomic<bool> gResetReq{false}, gClearReq{false}, gQuit{false};
static dispatch_semaphore_t gStopped;

// parked by the capture thread, under gLock
static CVPixelBufferRef gNewest;
static double gNewestArrival, gNewestCaptured, gNewestWhen; // when: the time its presents are planned from, see ptsTime
static bool gNewestRepeat, gNewestChanged;

// levels: auto detection per source. video range never goes below 16, so a few frames in a row with a handful of
// luma samples under 10 means full range. the old rule wanted 1% of the samples dark, which a daylight scene never
// has: it sat on "video" for minutes with the darkest sample at 1. sticky once seen, kept across restarts of
// the same source
static const int kDarkLuma = 10, kDarkSamples = 3, kDarkFrames = 5; // of the 2048 sampled per frame
static std::atomic<bool> gFullSeen{false};
static std::atomic<int> gDarkFrames{0};
static std::atomic<double> gQueueLag{0};   // from handing a frame to the display to it being on screen, last frame
static std::atomic<int> gLagRun{0};        // frames in a row for which that was over two and a half frame times (up to two is normal, by where the refresh falls): the display's queue has backed up and stays so
// drain (hidden, -drain NO: as before): plain passthrough sheds a backlog too, see tick. genDrain (hidden, off): frame
// generation tries the same, see genDrain()
static bool gDrain = true, gGenDrain = false;
static std::atomic<double> gLevelsFrom{0}; // no verdict before this time
// the signal's format changed: a new verdict, and not from the changeover itself. an xbox going to 720p sent ~6 s
// with samples at 1 and then a video range picture, which stuck on "full" and looked washed out. 15 s is how long
// its "keep this resolution?" question can stand
void signalChanged() { gFullSeen = false; gDarkFrames = 0; gLevelsFrom = nowSec() + 15; }
bool fullRange() { return gSet.levels == 2 || (gSet.levels == 0 && gFullSeen); }

// render thread only
static id<MTLTexture> gRgb, gUp, gFlat, gSrOut, gEdge, gFlat2, gDown; // gFlat2, gDown: an enhance net's picture after dither removal, and filtered down to the window
static id<MTLTexture> gLook;              // the graded picture, as large as what the last pass is given
static id<MTLTexture> gSharp;             // chain SU: sharpened at source size, before the upscaler
static MTLTextureUsage gInUse;
// the chain as it runs (common.h). set at every capture tick
static std::atomic<int> gCh{kPostD | kPostU | kPostS};
int chainNow() { return gCh; }
// a real frame's picture after the stages before the interpolator (noise filter, the chain's pre part) hangs on the
// raw 420v frame under kPicKey, like genSmall's copy does. the raw frame stays what the motion check reads: the pre
// picture may still be on its way through the gpu, and the limit was tuned on raw values. kPreKey marks a picture the
// gpu pre stages made, so the same stages are not run on it again after the interpolator
static const CFStringRef kPicKey = CFSTR("meyra.pic"), kPreKey = CFSTR("meyra.pre");
static id<MTLTexture> gPreRgb, gPreFlat, gPreDown;
static CVPixelBufferPoolRef gPrePool;
static id<MTLCommandBuffer> gPreCb;       // the last pre pass, and the raw frame it was for (only compared)
static CVPixelBufferRef gPreFor;
static int gPreNet;                       // the enhance net that pass ran, 0 = none
static std::atomic<double> gGpuCarry{0};  // gpu time of a frame's earlier command buffers (pre stages, super resolution tiles, a picture scaled ahead), added to its last
static std::atomic<bool> gDeepNow{false}; // the in-turns schedule is on, for the overlay
bool deepNow() { return gDeepNow; }
static bool gSrCan;             // apple super resolution has something to do and is up (picture larger than the source, session ready)
static CVPixelBufferRef gSrFor; // the frame whose scaled picture gSrOut holds, scaled ahead of its turn. not retained, only compared
static id<MTLFXSpatialScaler> gScaler;
static size_t gSrcW, gSrcH, gFitW, gFitH;
static std::atomic<int> gInfoW{0}, gInfoH{0}, gInfoFitW{0}, gInfoFitH{0}, gInfoUp{0}, gInfoNet{0};
static CVPixelBufferPoolRef gNvPool;
static int gNvW, gNvH;
// genSmall: apple's interpolator is ~2.5x quicker at or below 1280x720 (probe: 4.3 ms against 10.9 at 1080p, paced).
// so for a 1080p source it gets a shrunk copy of each real frame, made in toNV and kept on the full size frame as an
// attachment; the generated frame comes back small and fsNvFix enlarges it. real frames are shown from the full copy
static const int kSmW = 1280, kSmH = 720;
static const CFStringRef kSmallKey = CFSTR("meyra.small");
static CVPixelBufferPoolRef gSmPool;
static int gSmPoolFor;                  // the step its buffers are sized for
static std::atomic<int> gSmall{0};      // the step in use now (gSet.genSmall's numbers), 0 = full size. written by the render thread
int genSmallNow() { return gSmall; }
// the steps between 1280x720 and full size (in the app: 1280x720 3.6 ms, 1344x768 5.9, 1536x864 7.4, 1080p 11.2).
// the interpolator takes any size on a 32 grid, so 1344x768 is not quite the picture's shape: the whole frame is
// mapped onto the whole small one, and fsNvFix enlarges by position, so it comes back undistorted.
// a plain area shrink for any factor under 2: every small sample is the mean of what it covers. rows first, then
// across; three neighbours each way, weights in 256ths. chroma keeps its place: on the left luma sample of each pair
// across (centre 0.25 of a sample), between the two rows down
struct AreaTap { uint16_t at, w[3]; };
static std::vector<AreaTap> areaTaps(int nin, int nout, double centre) {
    std::vector<AreaTap> t(nout);
    double r = (double)nin / nout, off = centre - 0.5; // input sample i covers i + off .. i + off + 1
    for (int j = 0; j < nout; j++) {
        double a = (j + centre) * r - r / 2, b = a + r, w[3] = {0, 0, 0};
        int i0 = (int)floor(a - off), first = std::min(std::max(i0, 0), nin - 3);
        for (int i = i0; i < (int)ceil(b - off); i++) {
            double ov = fmin(b, i + off + 1) - fmax(a, i + off);
            if (ov > 0) w[std::min(std::max(std::min(std::max(i, 0), nin - 1) - first, 0), 2)] += ov; // past the edge: the edge sample
        }
        int q[3], sum = 0, big = 0;
        for (int k = 0; k < 3; k++) { q[k] = (int)lround(w[k] / r * 256); sum += q[k]; if (q[k] > q[big]) big = k; }
        q[big] += 256 - sum;
        t[j] = {(uint16_t)first, {(uint16_t)q[0], (uint16_t)q[1], (uint16_t)q[2]}};
    }
    return t;
}
// one plane, ch samples to a pixel (1 luma, 2 chroma). in bands side by side, it is on the way to the generator:
// both planes together add about 0.6 ms to the conversion
static void areaPlane(const uint8_t *s, size_t srb, int win, int ch, uint8_t *d, size_t drb, const std::vector<AreaTap> &tx, const std::vector<AreaTap> &ty) {
    const size_t bands = 6, rows = ty.size();
    const std::vector<AreaTap> *px = &tx, *py = &ty;
    dispatch_apply(bands, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t bi) {
        uint16_t tmp[4096];
        for (size_t r = rows * bi / bands; r < rows * (bi + 1) / bands; r++) {
            const AreaTap &v = (*py)[r];
            const uint8_t *a = s + v.at * srb, *b = a + srb, *c = b + srb;
            int w0 = v.w[0], w1 = v.w[1], w2 = v.w[2];
            for (int x = 0; x < win * ch; x++) tmp[x] = (uint16_t)(w0 * a[x] + w1 * b[x] + w2 * c[x]);
            uint8_t *o = d + r * drb;
            for (const AreaTap &t : *px)
                for (int k = 0; k < ch; k++, o++) {
                    const uint16_t *p = tmp + t.at * ch + k;
                    *o = (uint8_t)((p[0] * t.w[0] + p[ch] * t.w[1] + p[2 * ch] * t.w[2] + 32768) >> 16);
                }
        }
    });
}
static CVPixelBufferRef held(CVPixelBufferRef nv, CFStringRef key) { // nv holds it
    CVPixelBufferRef s = (CVPixelBufferRef)CVBufferCopyAttachment(nv, key, NULL);
    if (s) CFRelease(s);
    return s;
}
static CVPixelBufferRef genIn(CVPixelBufferRef nv) { // what the interpolator gets for this real frame
    CVPixelBufferRef s = held(nv, kSmallKey);
    if (!s && (gCh & (kPreN | kPreD | kPreE))) s = held(nv, kPicKey); // not for a filter that runs beside it
    return s ?: nv;
}
static int frameOf(CVPixelBufferRef pb) { // replay's frame number, -1 without
    CFTypeRef f = CVBufferCopyAttachment(pb, kFrameKey, NULL);
    int i = f ? [(__bridge NSNumber *)f intValue] : -1;
    if (f) CFRelease(f);
    return i;
}
static void copyFrame(CVPixelBufferRef from, CVPixelBufferRef to) {
    CFTypeRef f = CVBufferCopyAttachment(from, kFrameKey, NULL);
    if (f) { CVBufferSetAttachment(to, kFrameKey, f, kCVAttachmentMode_ShouldNotPropagate); CFRelease(f); }
    else CVBufferRemoveAttachment(to, kFrameKey); // pools hand buffers out again
}
// every command buffer's gpu time is counted. the ones before a frame's last (pre stages count towards the frame
// drawn next) are carried over to it
static void timed(id<MTLCommandBuffer> cb) {
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        double gpu = (c.GPUEndTime - c.GPUStartTime) * 1000;
        gGpuCarry = gGpuCarry.load() + gpu; // handlers of one queue come one at a time
        os_unfair_lock_lock(&gLock);
        gS.gpuBusy += gpu;
        os_unfair_lock_unlock(&gLock);
    }];
}

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
int enhanceRan() { return gInfoNet; }

void setLabels(id<MTLTexture> t) { os_unfair_lock_lock(&gLock); gLabelTex = t; os_unfair_lock_unlock(&gLock); }
std::string compareNames() { os_unfair_lock_lock(&gLock); std::string s = gCmpNames; os_unfair_lock_unlock(&gLock); return s; }
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
    gScaler = nil; gUp = nil; gSrOut = nil; gEdge = nil; gFlat2 = nil; gDown = nil; gSharp = nil;
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
    gInUse = inUse;
    gRgb = makeTex(srcW, srcH, inUse);
    gFlat = makeTex(srcW, srcH, inUse);
    gInfoW = (int)srcW; gInfoH = (int)srcH; gInfoFitW = (int)fitW; gInfoFitH = (int)fitH;
    logLine("pipeline: %zux%zu -> on screen %zux%zu, metalfx %s", srcW, srcH, fitW, fitH, gScaler ? "ready" : "not needed");
}

// stage times (-stageTimes NO turns them off): a gpu timestamp at the start and at the end of every pass's fragment stage
// (the vertex stage of the next pass starts while this one still draws), read back when the command buffer is done. a pass's own time goes to its stage, told by its pipeline. the time between two passes
// is what was encoded there without pass(): the enhance net or metalfx. apple gpus only take samples at pass
// boundaries, which is all this needs. off: nothing is attached, the passes are the ones they always were
static bool gStOn;
static id<MTLCounterSet> gStSet;
static const double gStMs = 1e-6;                           // timestamps are in ns here: the stages of a buffer add up to its own gpu time
static NSMutableArray<id<MTLCounterSampleBuffer>> *gStFree; // under gLock. frames overlap on the gpu, so each command buffer has its own until it is read
static const int kStPasses = 16;
struct StCtx { id<MTLCounterSampleBuffer> buf; int n = 0; uint8_t st[kStPasses]; };
static std::shared_ptr<StCtx> gStCtx;                       // render thread: the command buffer being encoded
static id<MTLCommandBuffer> gStCb;
static void stInit() {
    NSUserDefaults *sd = NSUserDefaults.standardUserDefaults; // on unless -stageTimes NO: measured, the timestamps cost nothing that shows
    if ([sd objectForKey:@"stageTimes"] && ![sd boolForKey:@"stageTimes"]) return;
    for (id<MTLCounterSet> c in gDev.counterSets) if ([c.name isEqual:MTLCommonCounterSetTimestamp]) gStSet = c;
    bool can = gStSet && [gDev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary];
    gStFree = [NSMutableArray new];
    gStOn = can;
    logLine("stage times: %s", can ? "on" : "this gpu takes no timestamps at pass boundaries, off");
}
static void stSample(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> pipe, MTLRenderPassDescriptor *rp);

static void pass(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> pipe, id<MTLTexture> src, id<MTLTexture> src2, id<MTLTexture> dst, MTLViewport vp,
                 const void *u, bool keepDst = false, id<MTLTexture> src3 = nil, id<MTLTexture> src4 = nil, id<MTLTexture> src5 = nil, id<MTLTexture> src6 = nil,
                 const void *u2 = NULL, size_t n2 = 0) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = keepDst ? MTLLoadActionLoad : MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (gStOn) stSample(cb, pipe, rp);
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pipe];
    [e setViewport:vp];
    if (gScOn) [e setScissorRect:gSc];
    if (u) [e setFragmentBytes:u length:16 atIndex:0]; // every uniform struct is four floats
    if (u2) [e setFragmentBytes:u2 length:n2 atIndex:1]; // but the hud areas
    [e setFragmentTexture:src atIndex:0];
    if (src2) [e setFragmentTexture:src2 atIndex:1];
    if (src3) [e setFragmentTexture:src3 atIndex:2];
    if (src4) [e setFragmentTexture:src4 atIndex:3];
    if (src5) [e setFragmentTexture:src5 atIndex:4];
    if (src6) [e setFragmentTexture:src6 atIndex:5];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

static void stSample(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> pipe, MTLRenderPassDescriptor *rp) {
    if (cb != gStCb) { // a new command buffer: its own samples, read when it is done
        auto c = std::make_shared<StCtx>();
        os_unfair_lock_lock(&gLock);
        if (gStFree.count) { c->buf = gStFree.lastObject; [gStFree removeLastObject]; }
        os_unfair_lock_unlock(&gLock);
        if (!c->buf) {
            MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
            d.counterSet = gStSet; d.storageMode = MTLStorageModeShared; d.sampleCount = 2 * kStPasses;
            c->buf = [gDev newCounterSampleBufferWithDescriptor:d error:nil];
        }
        gStCb = cb;
        gStCtx = c->buf ? c : nullptr;
        if (gStCtx) [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            NSData *d = [c->buf resolveCounterRange:NSMakeRange(0, 2 * c->n)];
            const MTLCounterResultTimestamp *t = (const MTLCounterResultTimestamp *)d.bytes;
            double add[kStN] = {};
            uint64_t prevEnd = 0;
            for (int i = 0; t && i < c->n && d.length >= (NSUInteger)(2 * i + 2) * sizeof *t; i++) {
                uint64_t a = t[2 * i].timestamp, b = t[2 * i + 1].timestamp;
                if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a) { prevEnd = 0; continue; }
                add[c->st[i]] += (b - a) * gStMs;
                // before dither removal only the net can have run (its "before dither removal" place)
                if (prevEnd && a > prevEnd) add[c->st[i] == kStDither ? kStEnhance : kStBetween] += (a - prevEnd) * gStMs;
                prevEnd = b;
            }
            os_unfair_lock_lock(&gLock);
            for (int i = 0; i < kStN; i++) gS.stage[i] += add[i];
            gS.stageCb += (done.GPUEndTime - done.GPUStartTime) * 1000; gS.stageN++;
            [gStFree addObject:c->buf];
            os_unfair_lock_unlock(&gLock);
        }];
    }
    StCtx *c = gStCtx.get();
    if (!c || c->n >= kStPasses) return;
    c->st[c->n] = pipe == gPipeDeband ? kStDither : pipe == gPipeOut || pipe == gPipeLook ? kStSharpen : pipe == gPipeHud || pipe == gPipeCut ? kStOverlay : pipe == gPipeDown ? kStShrink
                : pipe == gPipeYuv || pipe == gPipeNv || pipe == gPipeNvFix || pipe == gPipeNvFixLock || pipe == gPipeNvFixHud || pipe == gPipeNvFixLockHud || pipe == gPipeBackY || pipe == gPipeBackC ? kStConvert : kStUpscale; // easu, sgsr, apple's tiles
    MTLRenderPassSampleBufferAttachmentDescriptor *a = rp.sampleBufferAttachments[0];
    a.sampleBuffer = c->buf;
    a.startOfFragmentSampleIndex = 2 * c->n; a.endOfFragmentSampleIndex = 2 * c->n + 1;
    a.startOfVertexSampleIndex = a.endOfVertexSampleIndex = MTLCounterDontSample;
    c->n++;
}

// enhanceReal, enhanceHold: what the net added to a real frame is kept apart from the picture (rg16f at the net's
// output size, see fsKeepAdd), for the newest two real frames. a kept frame shown again gets it back as it is; a
// generated frame or a repeat gets it where its picture still matches; the next real frame's is steadied against it.
// `of` is the frame it belongs to (our own 420v buffers only, held so the pool cannot hand the address out again)
struct Kept { id<MTLTexture> t; CVPixelBufferRef of = NULL; };
static Kept gKept[2];
static int gKeptNew = -1;                 // which one is the newest real frame's, -1 = nothing kept
static double gKeptAt;                    // when the net ran on it
static id<MTLTexture> gKeptRaw, gKeptTmp, gKeptPic; // the net's own change before steadying, a generated frame's, the finished picture
static int gKeptStamp;
static bool gRepeatNow;                   // set by tick: the frame being shown is a repeat of the one shown before
// hidden, for tests: keepTol, how far (levels of 255) a pixel's 3x3 may be from the guide and still count as the same
// picture, none from twice that (the soft still rule's numbers). holdMs, the time constant of steady enhance.
// holdMargin, how far outside the fresh 3x3 range the held change may sit. enhanceAhead NO: generated frames only
// get the older real frame's change. ssGamma: what supersample decodes with before averaging, 1 = not at all
static float gKeepTol = 4.5f, gHoldMs = 80, gHoldMargin = 2, gSsGamma = 2.2f;
static bool gAhead = true;
// enhanceAhead 2 (hidden): with the second generator the run ahead waits until the generated frame is made. both are
// gpu work, and started together (as 1 does, at arrival) each makes the other slower
static bool gAheadAfter = false, gAheadWait;
static std::atomic<float> gHoldW{0};      // weight of the last steadied frame, 0 = went out fresh
static std::atomic<int> gSsWhy{0}, gSsW{0}, gSsH{0}, gKeptTwo{0};
static void keptForget() {
    for (Kept &k : gKept) { if (k.of) CFRelease(k.of); k.of = NULL; }
    gKeptNew = -1;
}
static void keptFree() {
    if (!gKept[0].t) return;
    keptForget();
    gKept[0].t = gKept[1].t = gKeptRaw = gKeptTmp = gKeptPic = nil;
}
static id<MTLTexture> keptTex(size_t w, size_t h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    return [gDev newTextureWithDescriptor:d];
}
static void netRan(int en, id<MTLTexture> src) {
    os_unfair_lock_lock(&gLock);
    gS.net++; gS.netPx += (double)src.width * src.height * nets::passes(en);
    os_unfair_lock_unlock(&gLock);
}
// the net stage with one of the two switches on. key: the real frame being shown (null: not one of ours, or a
// generated frame). made: a generated frame between the real frames a (newer) and b
static id<MTLTexture> enhance(id<MTLCommandBuffer> cb, int en, int at, id<MTLTexture> src, CVPixelBufferRef key, bool made, CVPixelBufferRef a, CVPixelBufferRef b, bool noPic = false) {
    int sc = nets::scale(en), stamp = en * 16 + at * 2 + (fullRange() ? 1 : 0);
    size_t w = sc * src.width, h = sc * src.height;
    if (!gKept[0].t || gKept[0].t.width != w || gKept[0].t.height != h || stamp != gKeptStamp) {
        keptFree();
        gKept[0].t = keptTex(w, h); gKept[1].t = keptTex(w, h);
        gKeptPic = makeTex(w, h, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        gKeptStamp = stamp;
    }
    if (!gKept[0].t || !gKept[1].t || !gKeptPic) { // no memory for it: as without the switches
        keptFree();
        id<MTLTexture> t = nets::run(cb, en, src);
        if (t) netRan(en, src);
        return t;
    }
    MTLViewport vp = {0, 0, (double)w, (double)h, 0, 1};
    for (Kept &k : gKept)
        if (key && k.of == key) { // this very frame again
            pass(cb, gPipeKeepAdd, src, k.t, gKeptPic, vp, NULL);
            bump(&Stats::netKept);
            return gKeptPic;
        }
    float tol = gKeepTol / 255;
    if ((!made && gRepeatNow) || (made && gSet.enhanceReal)) {
        Kept *k1 = NULL, *k2 = NULL;
        if (made) {
            for (Kept &k : gKept) { if (k.of && k.of == a) k1 = &k; else if (k.of && k.of == b) k2 = &k; }
            if (!k1) { k1 = k2; k2 = NULL; }
        } else if (gKeptNew >= 0) k1 = &gKept[gKeptNew];
        if (k1) {
            float u[4] = {(float)sc, tol, k2 ? 1.0f : 0.0f, 0};
            pass(cb, gPipeKeepUse, src, k1->t, gKeptPic, vp, u, false, k2 ? k2->t : k1->t);
            bump(&Stats::netKept);
            if (made) gKeptTwo = k2 ? 2 : 1;
            return gKeptPic;
        }
        if (made) { bump(&Stats::netBare); return nil; } // nothing kept yet: the plain picture, the net does not run on these
    }
    // a new real frame: the net runs and its change is kept. with only steady enhance on it runs on generated frames
    // too, and they read the history without moving it on
    int hist = gKeptNew, slot = hist == 0 ? 1 : 0;
    double now = nowSec(), dur = gFrameDur, dt = fmax(1, round((now - gKeptAt) / dur)) * dur; // in whole frame times: the wake-ups wobble
    bool hold = gSet.enhanceHold && hist >= 0 && dt <= 0.25;
    if (made && !gKeptTmp) gKeptTmp = keptTex(w, h);
    if (hold && !gKeptRaw) gKeptRaw = keptTex(w, h);
    id<MTLTexture> dst = made ? gKeptTmp : gKept[slot].t, raw = hold ? gKeptRaw : dst;
    if (!dst || !raw || !nets::run(cb, en, src, raw)) return nil; // still being built, or cannot run
    netRan(en, src);
    float hw = hold ? (float)exp(-dt * 1000 / gHoldMs) : 0;
    if (hold) {
        float u[4] = {(float)sc, tol, hw, gHoldMargin / 255};
        pass(cb, gPipeHold, raw, gKept[hist].t, dst, vp, u);
    }
    if (!made) {
        gHoldW = hw;
        if (gKept[slot].of) CFRelease(gKept[slot].of);
        gKept[slot].of = key ? (CVPixelBufferRef)CFRetain(key) : NULL;
        gKeptNew = slot; gKeptAt = now;
    }
    if (noPic) return dst; // run ahead: only the keeping was wanted
    pass(cb, gPipeKeepAdd, src, dst, gKeptPic, vp, NULL);
    return gKeptPic;
}

// supersample: the upscaler's picture at twice the window, and its 2x2 mean. own scaler and textures, the plain ones
// stay as they are for when the switch goes off again
static id<MTLFXSpatialScaler> gSsScaler;
static id<MTLTexture> gSsBig, gSsOut;
static size_t gSsFor[4];
static bool gSsFxTried;
enum { kSsOff = 0, kSsOn, kSsSmall, kSsNet, kSsPlain, kSsApple, kSsTooBig, kSsNoFx, kSsNoMem };
// ready to scale W x H to twice fw x fh with upscaler `up` (1 metalfx, 3 fsr 1, 4 sgsr 1)? else why not
static int ssReady(size_t W, size_t H, size_t fw, size_t fh, int up) {
    if (2 * fw > 16384 || 2 * fh > 16384) return kSsTooBig; // the largest texture there is
    if (gSsFor[0] != W || gSsFor[1] != H || gSsFor[2] != fw || gSsFor[3] != fh) {
        gSsScaler = nil; gSsBig = nil; gSsOut = nil; gSsFxTried = false;
        gSsFor[0] = W; gSsFor[1] = H; gSsFor[2] = fw; gSsFor[3] = fh;
    }
    if (up == 1 && !gSsFxTried) {
        gSsFxTried = true;
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.inputWidth = W; d.inputHeight = H; d.outputWidth = 2 * fw; d.outputHeight = 2 * fh;
        d.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        gSsScaler = [d newSpatialScalerWithDevice:gDev];
        gSsBig = nil; // metalfx has its own wishes for what it writes to
        logLine("supersample: metalfx %zux%zu -> %zux%zu %s", W, H, 2 * fw, 2 * fh, gSsScaler ? "ready" : "refused");
    }
    if (up == 1 && !gSsScaler) return kSsNoFx;
    if (!gSsBig) gSsBig = makeTex(2 * fw, 2 * fh, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (gSsScaler ? gSsScaler.outputTextureUsage : 0));
    if (!gSsOut) gSsOut = makeTex(fw, fh, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    return gSsBig && gSsOut ? kSsOn : kSsNoMem;
}

// the three experimental picture switches, for the stats line and the overlay: acting, or idle and why
std::string extraText(int which, const Stats &s) {
    char b[160] = "off";
    int en = effEnhance();
    bool pre = (gCh & kPreE) != 0;
    const char *noNet = gSet.passthrough ? "idle: passthrough" : !en || en > nets::count() ? "idle: enhance is off" : !gInfoNet ? (*nets::status(en) ? "idle: the net is not up" : "idle: the net is not running") : NULL;
    if (which == 0 && gSet.enhanceReal) {
        if (noNet) snprintf(b, sizeof b, "%s", noNet);
        else if (pre) snprintf(b, sizeof b, "idle: the chain has the net before the interpolator, on real frames only as it is");
        else if (!s.netKept && !s.netBare) snprintf(b, sizeof b, "idle: every frame is new, net on %d of %d", s.net, s.drawn);
        else snprintf(b, sizeof b, "acting: net on %d of %d frames, %d from kept%s%s", s.net, s.drawn, s.netKept,
                      !s.gen ? "" : gKeptTwo == 2 ? " (generated: newer real frame's, then older)" : gSet.enhanceAt == 2 ? " (generated: older real frame's, the net sits after the upscaler)" : " (generated: one real frame's)",
                      s.netBare ? ", some generated frames plain" : "");
    } else if (which == 1 && gSet.enhanceHold) {
        float w = gHoldW;
        if (noNet) snprintf(b, sizeof b, "%s", noNet);
        else if (w <= 0) snprintf(b, sizeof b, "idle: no history (just started, or more than 250 ms since the last new frame)");
        else snprintf(b, sizeof b, "acting: history weight %.2f where still%s", w, !gSet.enhanceReal && s.netKept ? ", repeats take the kept result" : "");
    } else if (which == 2 && gSet.superSample) {
        static const char *const kWhy[] = {"idle: no picture yet", "", "idle: the picture is not larger than the source", "idle: the enhance net makes the picture", "idle: plain scaling has nothing to gain",
                                           "idle: apple super resolution already scales past the window", "idle: twice the window is more than a texture holds",
                                           "idle: metalfx cannot scale to twice the window", "idle: no memory for twice the window"};
        int why = gSsWhy;
        if (gSet.passthrough) snprintf(b, sizeof b, "idle: passthrough");
        else if (why == kSsOn) snprintf(b, sizeof b, "acting: %dx%d -> %dx%d", gSsW.load(), gSsH.load(), gSsW / 2, gSsH / 2);
        else snprintf(b, sizeof b, "%s", kWhy[why]);
    }
    return b;
}

static void savePng(id<MTLTexture> t, NSString *path, NSString *what = nil) {
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
    if (what) { logLine("snapshot %s %s %s", what.UTF8String, ok ? "saved" : "failed", path.UTF8String); gSnapLeft--; }
    else logLine("snapshot %zux%zu %s: %s", w, h, ok ? "saved" : "failed", path.UTF8String);
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
    timed(cb);
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

// the picture to show for a real frame: its pre picture when it has one. a filtered one may still be in the works:
// wait that long for it, then the raw frame goes up instead
static CVPixelBufferRef picOf(CVPixelBufferRef pb, double graceMs, bool count = false) { // count: this frame goes up now
    CVPixelBufferRef p = CVPixelBufferIsPlanar(pb) ? held(pb, kPicKey) : NULL;
    if (!p) return pb;
    if (CVBufferHasAttachment(p, kPreKey) || noise::wait(p, graceMs)) return p; // gpu work needs no wait: same queue, it runs before whatever reads it
    if (count) bump(&Stats::noiseRaw);
    return pb;
}

// hud lock (hudLock): per pixel of the real frames, how long it has been still and how much edge it has had (see
// fsLockUpdate). brought up to date once per new real frame, before the generated frame that leads up to it is
// drawn; generated frames then take their locked pixels from that real frame. two textures in turns, a pass cannot
// read what it writes. a pixel that moves lets go by itself, so nothing here resets on a cut
static id<MTLTexture> gHl[2];             // [0] the state up to gHlFor
static CVPixelBufferRef gHlFor;           // the real frame the state has seen last, retained
static float gHlStill = 0.02f;            // hudStill (hidden, in levels of 255): largest change still counted as the same pixel
static std::atomic<float> gHlShare{-1};   // share of the picture locked, counted about once a second, for the log
static void lockDrop() {
    if (gHlFor) { CFRelease(gHlFor); gHlFor = NULL; }
    gHl[0] = gHl[1] = nil;
    gHlShare = -1;
}
float hudLocked() { return gHlShare; }
static id<MTLTexture> lockFor(size_t W, size_t H) {
    return gSet.hudLock && gHl[0] && gHl[0].width == W && gHl[0].height == H ? gHl[0] : nil;
}
static void lockUpdate(CVPixelBufferRef nv) {
    size_t W = CVPixelBufferGetWidth(nv), H = CVPixelBufferGetHeight(nv);
    bool fresh = !gHl[0] || gHl[0].width != W || gHl[0].height != H || !gHlFor || CVPixelBufferGetWidth(gHlFor) != W || CVPixelBufferGetHeight(gHlFor) != H;
    if (!gHl[0] || gHl[0].width != W || gHl[0].height != H) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:W height:H mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        gHl[0] = [gDev newTextureWithDescriptor:d]; gHl[1] = [gDev newTextureWithDescriptor:d];
        if (!gHl[0] || !gHl[1]) { lockDrop(); return; }
    }
    CVPixelBufferRef was = fresh ? nv : gHlFor;
    std::array<CVMetalTextureRef, 4> p = {plane(nv, 0, false), plane(nv, 1, false), plane(was, 0, false), plane(was, 1, false)};
    if (p[0] && p[1] && p[2] && p[3]) {
        id<MTLCommandBuffer> cb = [gQueue commandBuffer];
        float lv[4] = {fullRange() ? 1.0f : 0.0f, fresh ? 1.0f : 0.0f, gHlStill, gSd ? 1.0f : 0.0f}; // levels, start over, tolerance, sd
        pass(cb, gPipeLock, CVMetalTextureGetTexture(p[0]), CVMetalTextureGetTexture(p[1]), gHl[1], (MTLViewport){0, 0, (double)W, (double)H, 0, 1}, lv, false,
             CVMetalTextureGetTexture(p[2]), CVMetalTextureGetTexture(p[3]), gHl[0]);
        std::swap(gHl[0], gHl[1]);
        // for the log: how much of the picture is locked right now. read back about once a second and counted off
        // this thread, every second pixel of every second row
        static int turn;
        id<MTLBuffer> buf = ++turn % 30 == 0 ? [gDev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared] : nil;
        if (buf) {
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            [bl copyFromTexture:gHl[0] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                       toBuffer:buf destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
            [bl endEncoding];
        }
        CVPixelBufferRef a = nv, b = was;
        CFRetain(a); CFRetain(b);
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            for (auto x : p) CFRelease(x);
            CFRelease(a); CFRelease(b);
            if (buf) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                const _Float16 *s = (const _Float16 *)buf.contents;
                auto still = [](float v) { float t = fmin(fmax((v - 0.80f) / 0.15f, 0), 1); return t * t * (3 - 2 * t); }; // as the shader has them
                auto edge = [](float v) { float t = fmin(fmax((v - 0.04f) / 0.06f, 0), 1); return t * t * (3 - 2 * t); };
                long n = 0, on = 0;
                for (size_t y = 1; y + 1 < H; y += 2)
                    for (size_t x = 1; x + 1 < W; x += 2, n++) {
                        float st = still((float)s[(y * W + x) * 2]), e = 0;
                        if (st <= 0) continue;
                        for (int j = -1; j <= 1; j++)
                            for (int i = -1; i <= 1; i++) { const _Float16 *q = s + ((y + j) * W + x + i) * 2; e = fmax(e, edge((float)q[1]) * still((float)q[0])); }
                        on += st * e > 0.5f;
                    }
                gHlShare = n ? (float)on / n : 0;
            });
        }];
        timed(cb);
        [cb commit];
    } else for (auto x : p) if (x) CFRelease(x);
    CFRetain(nv);
    if (gHlFor) CFRelease(gHlFor);
    gHlFor = nv;
}

// the picture's size inside a drawable of dw x dh: as large as fits, same shape, even numbers. the app maps the mouse by it
void fitSize(size_t dw, size_t dh, size_t W, size_t H, size_t &fw, size_t &fh) {
    fw = dw; fh = dw * H / W;
    if (fh > dh) { fh = dh; fw = dh * W / H; }
    fw &= ~(size_t)1; fh &= ~(size_t)1;
}

// show one frame. pb is 2vuy from the source, or 420v (converted or generated).
// arrival > 0 marks a real frame, for the delay stats. borrows pb, retains what it needs.
// for a generated frame, `real` is the real frame its broken pixels get repaired from (null = no repair)
// onlyScale: run apple super resolution for this frame now and keep the result for when it is shown, present nothing
// onlyNet: enhanceReal's run ahead. the frame's picture goes through the enhance net now and what the net added is
// kept, nothing is presented
// look: grades fitted on before/after video pairs of gta vi with the dlss 5 look. tone curve at y = i/32, then the factor
// on colour. in rgb after levels. mild: gameplay, day and night. strong: one dark cutscene. middle: the mean of both
static const float kLook[3][34] = {
    {0.00854f, 0.03386f, 0.06642f, 0.09765f, 0.1275f, 0.15842f, 0.18995f, 0.22231f, 0.25199f, 0.27984f, 0.30613f, 0.33024f, 0.35518f, 0.38291f, 0.41092f, 0.43829f, 0.4634f, 0.48792f, 0.51766f, 0.54928f, 0.57767f, 0.60944f, 0.64241f, 0.67443f, 0.70637f, 0.73994f, 0.77434f, 0.80776f, 0.83742f, 0.86206f, 0.89411f, 0.94306f, 0.97734f, 0.9073f},
    {0.0096f, 0.03547f, 0.06347f, 0.09247f, 0.12448f, 0.15907f, 0.19758f, 0.23455f, 0.26562f, 0.29534f, 0.32419f, 0.35077f, 0.37657f, 0.40146f, 0.42655f, 0.45309f, 0.47556f, 0.49247f, 0.51038f, 0.53411f, 0.55655f, 0.57633f, 0.59837f, 0.62239f, 0.64164f, 0.6674f, 0.69755f, 0.73165f, 0.7685f, 0.79936f, 0.82778f, 0.87593f, 0.92376f, 1.0072f},
    {0.01066f, 0.03708f, 0.06051f, 0.08729f, 0.12145f, 0.15972f, 0.20521f, 0.24679f, 0.27926f, 0.31084f, 0.34225f, 0.37131f, 0.39796f, 0.42002f, 0.44218f, 0.46789f, 0.48772f, 0.49703f, 0.50311f, 0.51894f, 0.53543f, 0.54322f, 0.55433f, 0.57035f, 0.57691f, 0.59486f, 0.62075f, 0.65554f, 0.69958f, 0.73665f, 0.76146f, 0.80879f, 0.87019f, 1.1071f},
};

static CVPixelBufferRef gFrozen; // render thread: the frame a freeze holds
static void thaw() { if (gFrozen) CVPixelBufferRelease(gFrozen); gFrozen = NULL; }

static void show(CVPixelBufferRef pb, double arrival, CVPixelBufferRef real = NULL, CVPixelBufferRef prevReal = NULL, bool onlyScale = false, bool onlyNet = false) {
    // freeze: whatever is due, the same real frame goes through the chain and up. the source and the timing run on
    if (gSet.freeze) {
        if (onlyNet) return;
        if (!gFrozen) gFrozen = CVPixelBufferRetain(real ?: pb);
        pb = gFrozen;
        real = prevReal = NULL;
    } else thaw();
    CVPixelBufferRef raw = pb; // as it came, before the noise filter or a stage ahead of the interpolator
    pb = picOf(pb, onlyNet ? 2 : 14, !onlyNet); // a frame shown the moment it arrived (no frame generation, 60 fps content) waits for its filter here
    if (real) real = picOf(real, 2);
    if (gSet.freeze && CVBufferHasAttachment(pb, kPreKey)) pb = raw; // frozen: the chain as it is now, not the pre picture made when the frame came
    if (prevReal) prevReal = picOf(prevReal, 0);
    int ch = gCh;
    bool cs = ch & kChainSet, preDone = CVBufferHasAttachment(real ?: pb, kPreKey);
    bool postD = (ch & kPostD) || ((ch & kPreD) && !preDone), postE = (ch & kPostE) || ((ch & kPreE) && !preDone); // a pre stage that did not run is made up for here
    int enSet = cs && !(ch & (kPostE | kPreE)) ? 0 : effEnhance(); // a chain without E: no net
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    bool nv = CVPixelBufferIsPlanar(pb);
    if (!nv && fmt != kCVPixelFormatType_422YpCbCr8) return; // sources only deliver 2vuy
    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb), gw = W, gh = H;
    if (real) { W = CVPixelBufferGetWidth(real); H = CVPixelBufferGetHeight(real); } // genSmall: a generated frame is smaller than the picture
    CVMetalTextureRef t0 = NULL, t1 = NULL, r0 = NULL, r1 = NULL, p0 = NULL;
    if (real && prevReal) CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, prevReal, NULL, MTLPixelFormatR8Unorm, W, H, 0, &p0);
    if (real) {
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, real, NULL, MTLPixelFormatR8Unorm, W, H, 0, &r0);
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, real, NULL, MTLPixelFormatRG8Unorm, W / 2, H / 2, 1, &r1);
    }
    if (nv) {
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, NULL, MTLPixelFormatR8Unorm, gw, gh, 0, &t0);
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, NULL, MTLPixelFormatRG8Unorm, gw / 2, gh / 2, 1, &t1);
    } else {
        CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, pb, NULL, MTLPixelFormatBGRG422, W, H, 0, &t0);
    }
    auto drop = [&] { if (t0) CFRelease(t0); if (t1) CFRelease(t1); if (r0) CFRelease(r0); if (r1) CFRelease(r1); if (p0) CFRelease(p0); };
    if (!t0 || (nv && !t1)) { drop(); return; }
    double tdr = nowSec();
    id<CAMetalDrawable> dr = onlyScale || onlyNet ? nil : [gLayer nextDrawable]; // may block, fine on this thread
    tdr = (nowSec() - tdr) * 1000;
    os_unfair_lock_lock(&gLock);
    if (tdr > gS.drawableMax) gS.drawableMax = tdr;
    // for tests: a snapshot waits for a generated frame. only from the command line (-snapGen YES), a saved setting is not read
    static const bool snapGen = [[NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain][@"snapGen"] boolValue];
    NSString *snapPath = onlyScale || onlyNet || (snapGen && !real) ? nil : gSnapPath; // a pass that draws nothing must not eat the snapshot
    if (snapPath) gSnapPath = nil;
    id<MTLTexture> labels = gLabelTex;
    id<MTLTexture> hud = gHudTex; // the overlay, or a hint line on its own: the app takes it away when neither is wanted
    // numbered snapshots: a generated frame goes by the real frame it leads up to
    int snapNo = -1, snapAt = -1;
    if (!snapPath && !onlyScale && !onlyNet && !gSnapWant.empty() && gLoop >= 1 && nowSec() >= gSnapFrom) {
        snapNo = frameOf(real ?: pb);
        for (size_t i = 0; i < gSnapWant.size(); i++) if (gSnapWant[i].first == snapNo && gSnapWant[i].second == (real != NULL)) snapAt = (int)i;
    }
    os_unfair_lock_unlock(&gLock);
    if (!dr && !((onlyScale || onlyNet) && gFitW)) { drop(); return; }

    size_t dw = dr ? dr.texture.width : gFitW, dh = dr ? dr.texture.height : gFitH;
    size_t fw = dw, fh = dh;
    if (dr) fitSize(dw, dh, W, H, fw, fh); // without a drawable the size is the last fit as it is: fitting it again shifts it by a pixel or two and every call would rebuild the pipeline
    if (fw < 2 || fh < 2) { drop(); return; }
    prepare(W, H, fw, fh);
    if (!gRgb || !gFlat) { drop(); return; }

    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    bool scaled = !onlyScale && !onlyNet && gSrFor == pb && gSrOut && gSrOut.width == fw && gSrOut.height == fh; // done ahead
    if (scaled) gSrFor = NULL; // once: the pool hands the same buffer out again for a later frame
    MTLViewport full = {0, 0, (double)W, (double)H, 0, 1};
    std::vector<std::pair<const char *, id<MTLTexture>>> cmp; // compare view: the picture after each stage that ran
    static std::vector<std::pair<const char *, id<MTLTexture>>> cmpAhead; // of the frame scaled ahead of its turn
    if (scaled) cmp.swap(cmpAhead);
    cmpAhead.clear();
    // the cuts show the original as the source sent it: while a generated frame is up that is still the real frame
    // before it, so the original's half moves at the game's own rate. kept ahead for a frame scaled ahead of its turn
    static id<MTLTexture> orig, origAhead;
    int cm = gSet.passthrough ? 0 : gSet.compare.load(); // once a frame, a key press comes in between
    bool cut = cm >= 1 && cm <= 5;
    if (!cut) { orig = nil; origAhead = nil; }
    else if (scaled && !real) std::swap(orig, origAhead);
    id<MTLTexture> src = gSrOut;
    int up = (ch & kPostU) ? effUpscale() : 0, ran = 2; // what scaled this frame: 0 nothing or plain, 1 metalfx, 2 apple super resolution, 3 fsr 1 easu, 4 sgsr 1
    // enhance: a small net on every frame, whatever the window size. it hands back the picture at 2x, so it stands in
    // for the upscaler: at a window of 2x or more its picture is used as it is, below that it is filtered down to
    // the window. at 2 (after the upscaler) is for windows larger than the source but not so large that the net,
    // which then works on window pixels, costs more than twice as much; outside that it runs as at 0
    int en = onlyScale || scaled || enSet > nets::count() ? 0 : enSet, at = gSet.enhanceAt;
    if (cs) { at = 0; if (!postE) en = 0; } // a chain has the net after dither removal, or before the interpolator
    if (at == 2 && !(fw > W && fh > H && fw * fh <= 2 * W * H)) at = 0;
    id<MTLTexture> net = nil; // the net's picture, once it has run
    if (!enSet) nets::idle();
    if (onlyNet && (!en || at == 2)) { drop(); return; } // after the upscaler: not ahead, that needs the whole chain
    bool keep = (gSet.enhanceReal || gSet.enhanceHold) && !gSet.passthrough && !gSet.freeze; // frozen: the net runs every time, so that changes show
    if (!keep || !enSet) keptFree();
    // the net stage: as it always was, or by way of what is kept of its work on real frames (see enhance)
    auto runNet = [&](id<MTLTexture> from) -> id<MTLTexture> {
        if (keep) return enhance(cb, en, at, from, nv && !real ? pb : NULL, real != NULL, real, prevReal, onlyNet);
        id<MTLTexture> t = nets::run(cb, en, from);
        if (t) netRan(en, from);
        return t;
    };
    if (!scaled) {
    ran = 0;
    if (!nv) gSd = is601(pb); // generated and converted frames follow the source they came from
    static const bool oldGreen = [NSUserDefaults.standardUserDefaults boolForKey:@"greenOld"]; // hidden, to compare
    // still-area rule: which one (genStill) and how close the two real frames must be to count as unchanged.
    // 0, as it always was: within 1.5 of 255 or not at all. 1, soft: still parts of a game picture are not identical,
    // its dither changes every frame (largest luma change over the shader's 9 taps was <= 4 on 97% and <= 5 on 99% of
    // a still wall, 0 on a console menu), so full weight to 4.5, none from 9. 2 and 3: metalgoose's rule, whose
    // "nothing changed" is 1 of 255 (1.5 here is the same test on whole levels). 4, for tests only: no rule
    int st = gSet.genStill;
    float lv[4] = {fullRange() ? 1.0f : 0.0f, p0 && st < 4 ? st + 1.0f : 0.0f, (st == 1 ? 4.5f : 1.5f) / 255, (gSd ? 1.0f : 0.0f) + (oldGreen ? 2.0f : 0.0f)}; // levels, still-area rule, its tolerance, mode
    id<MTLTexture> lk = nv && r0 && r1 ? lockFor(W, H) : nil; // hud lock: after the still-area rule, on top of it
    // hud areas: the marked rectangles take the real frame's pixel last of all (struct HA in the shader). none set: the passes as they were
    float ha[36] = {};
    int hn = nv && r0 && r1 ? std::min(gSet.hudN.load(), kHudMax) : 0;
    for (int i = 0; i < hn; i++) {
        float x = gSet.hudRect[4 * i], y = gSet.hudRect[4 * i + 1];
        ha[4 * i] = x; ha[4 * i + 1] = y; ha[4 * i + 2] = x + gSet.hudRect[4 * i + 2]; ha[4 * i + 3] = y + gSet.hudRect[4 * i + 3];
    }
    ha[32] = (float)hn; ha[33] = 3; // soft edge, pixels of the real frame
    if (nv && r0 && r1) pass(cb, hn ? (lk ? gPipeNvFixLockHud : gPipeNvFixHud) : lk ? gPipeNvFixLock : gPipeNvFix, CVMetalTextureGetTexture(t0), CVMetalTextureGetTexture(t1), gRgb, full, lv, false, CVMetalTextureGetTexture(r0), CVMetalTextureGetTexture(r1), p0 ? CVMetalTextureGetTexture(p0) : CVMetalTextureGetTexture(r0), lk,
                            hn ? ha : NULL, sizeof ha);
    else if (nv) pass(cb, gPipeNv, CVMetalTextureGetTexture(t0), CVMetalTextureGetTexture(t1), gRgb, full, lv);
    else pass(cb, gPipeYuv, CVMetalTextureGetTexture(t0), nil, gRgb, full, lv);
    src = gRgb;
    cmp.push_back({"as it came", src});
    if (cut && !real && !onlyNet) {
        id<MTLTexture> __strong &o = onlyScale ? origAhead : orig;
        if (!o || o.width != (NSUInteger)W || o.height != (NSUInteger)H) o = makeTex(W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        float ou[4] = {1.0f / W, 1.0f / H, 0, 0};
        if (o && raw == pb) pass(cb, gPipeOut, src, nil, o, full, ou);
        else if (o) { // the picture here is filtered already
            CVMetalTextureRef q0 = NULL, q1 = NULL;
            bool rnv = CVPixelBufferIsPlanar(raw);
            CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, raw, NULL, rnv ? MTLPixelFormatR8Unorm : MTLPixelFormatBGRG422, W, H, 0, &q0);
            if (rnv) CVMetalTextureCacheCreateTextureFromImage(NULL, gCache, raw, NULL, MTLPixelFormatRG8Unorm, W / 2, H / 2, 1, &q1);
            if (q0 && (!rnv || q1)) pass(cb, rnv ? gPipeNv : gPipeYuv, CVMetalTextureGetTexture(q0), q1 ? CVMetalTextureGetTexture(q1) : nil, o, full, lv);
            CFRetain(raw); // its memory must outlive the gpu work
            [cb addCompletedHandler:^(id<MTLCommandBuffer>) { if (q0) CFRelease(q0); if (q1) CFRelease(q1); CFRelease(raw); }];
        }
    }
    if (en && at == 1 && (net = runNet(src))) { src = net; cmp.push_back({"enhance", src}); }
    if (effDeband() && postD && !(onlyNet && at == 1)) { // the run ahead with the net first: src is what the net added, not a picture, and nobody reads this
        float db[4] = {1.0f / W, 1.0f / H, gDebandT / 255, 0}; // reach in source pixels, also on the net's larger picture
        bool big = net && net.width > W;
        if (big && !gFlat2) gFlat2 = makeTex(2 * W, 2 * H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> flat = big ? gFlat2 : gFlat;
        if (flat) { pass(cb, gPipeDeband, src, nil, flat, (MTLViewport){0, 0, (double)flat.width, (double)flat.height, 0, 1}, db); src = flat; cmp.push_back({"dither removal", src}); }
    }
    if (en && at == 0 && (net = runNet(src))) { src = net; cmp.push_back({"enhance", src}); }
    if (!onlyNet) {
    if ((ch & kSharpFirst) && effSharpen() > 0) { // chain SU: sharpen what the upscaler is given, the last pass then only resamples
        if (!gSharp) gSharp = makeTex(W, H, gInUse);
        float su[4] = {1.0f / src.width, 1.0f / src.height, effSharpen(), 0};
        if (gSharp) { pass(cb, gPipeOut, src, nil, gSharp, full, su); src = gSharp; }
    }
    gSrFor = NULL; // gSrOut is about to be someone else's, or nobody's
    gSrCan = up == 2 && !(enSet && enSet <= nets::count() && (nets::scale(enSet) == 2 || effFrameGen()) && !*nets::status(enSet) && !(cs && (ch & kPreE))) && !srYields() && fw > W && fh > H && superres::ready((int)W, (int)H);
    if (gSrCan && superScale(cb, src, W, fw, fh)) { src = gSrOut; ran = 2; }
    }
    }
    // for the overlay's order line: what this frame has been through (renderer.h). a frame scaled ahead of its turn
    // went through the first part then
    static unsigned didAhead;
    unsigned did = didAhead;
    if (!scaled) did = (effDeband() && postD ? 1u << kDidD : 0) | (net ? 1u << (kDidE0 + at) : 0) | ((ch & kSharpFirst) && effSharpen() > 0 ? 1u << kDidSharpFirst : 0)
                     | (preDone && (ch & kPreD) && effDeband() ? 1u << kDidPreD : 0) | (preDone && gPreNet ? 1u << kDidPreE : 0);
    didAhead = did;
    if (onlyScale || onlyNet) {
        if (onlyScale && ran == 2) { gSrFor = pb; cmpAhead = cmp; }
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
        timed(cb);
        [cb commit];
        return;
    }
    if (net && net.width > W && src.width > W) up = 0; // not after sharpen-first brought it back to the source size (a chain's E moved behind the interpolator). the net has made the larger picture. one that hands back the same size leaves the upscaler its job
    // supersample: the upscaler works to twice the window and the mean of every 2x2 block, in linear light, is the
    // picture. plain scaling has nothing to gain from it, apple super resolution already scales past the window
    // and is filtered down (fsTiles), a 2x net's picture is not the upscaler's
    int ss = kSsOff;
    if (gSet.superSample && !gSet.passthrough)
        ss = !(fw > W && fh > H) ? kSsSmall : net && net.width > W ? kSsNet : up == 0 ? kSsPlain : up == 2 || ran == 2 ? kSsApple : ssReady(W, H, fw, fh, up);
    if (gSsBig && ss != kSsOn) { gSsScaler = nil; gSsBig = nil; gSsOut = nil; gSsFor[0] = 0; }
    gSsWhy = ss; gSsW = (int)(2 * fw); gSsH = (int)(2 * fh);
    if (ss == kSsOn) {
        MTLViewport big = {0, 0, 2.0 * fw, 2.0 * fh, 0, 1};
        if (up == 1) {
            gSsScaler.colorTexture = src;
            gSsScaler.outputTexture = gSsBig;
            [gSsScaler encodeToCommandBuffer:cb];
        } else {
            float eu[4] = {1.0f / W, 1.0f / H, 0, 0};
            pass(cb, up == 3 ? gPipeEasu : gPipeSgsr, src, nil, gSsBig, big, eu);
        }
        float bu[4] = {0, 0, gSsGamma, 0};
        pass(cb, gPipeBox, gSsBig, nil, gSsOut, (MTLViewport){0, 0, (double)fw, (double)fh, 0, 1}, bu);
        src = gSsOut; ran = up;
    }
    if (ss != kSsOn && (up == 3 || up == 4) && fw > W && fh > H) {
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
    static const char *const kUpN[] = {"", "metalfx", "apple sr", "fsr 1", "sgsr 1"};
    gInfoUp = ran;
    if (en && at == 2 && (net = runNet(src))) {
        if (!cmp.empty() && cmp.back().second != src) cmp.push_back({ran ? kUpN[ran] : "resized", src});
        if (!cmp.empty()) cmp.push_back({"enhance", net});
        src = net;
    }
    gInfoNet = net ? en : preDone ? gPreNet : 0;
    if (net && (src.width > fw || src.height > fh)) {
        if (!gDown) gDown = makeTex(fw, fh, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        float du[4] = {1.0f / src.width, 1.0f / src.height, (float)gSet.enhanceDown, 0};
        if (gDown) { pass(cb, gPipeDown, src, nil, gDown, (MTLViewport){0, 0, (double)fw, (double)fh, 0, 1}, du); src = gDown; did |= 1u << kDidDown; if (!cmp.empty()) cmp.push_back({"shrink", src}); }
    }
    // look: after everything that makes the picture, before the sharpening. ten bits a channel, the curve would band in eight
    int look = gSet.passthrough ? 0 : gSet.look.load();
    if (!look) gLook = nil;
    else {
        if (!gLook || gLook.width != src.width || gLook.height != src.height) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:src.width height:src.height mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModePrivate;
            gLook = [gDev newTextureWithDescriptor:d];
        }
        if (gLook) {
            if (!cmp.empty() && cmp.back().second != src) cmp.push_back({ran ? kUpN[ran] : "resized", src});
            pass(cb, gPipeLook, src, nil, gLook, (MTLViewport){0, 0, (double)src.width, (double)src.height, 0, 1}, NULL, false, nil, nil, nil, nil, kLook[look - 1], sizeof kLook[0]);
            src = gLook;
            if (!cmp.empty()) cmp.push_back({"look", src});
        }
    }
    MTLViewport vp = {(double)((dw - fw) / 2), (double)((dh - fh) / 2), (double)fw, (double)fh, 0, 1};
    float u[4] = {1.0f / src.width, 1.0f / src.height, (ch & kPostS) && !(ch & kSharpFirst) ? effSharpen() : 0, 0};
    pass(cb, gPipeOut, src, nil, dr.texture, vp, u);
    // compare view. 1 to 5: the original against the result, see below. 6 and 7: the picture in strips, left to right as
    // the chain goes, each from one stage further on. 6: every strip its own part of the picture. 7: the middle strip of
    // the picture, from every stage. over the finished frame, snapshots are taken without it
    std::string names;
    if (cm && !cmp.empty()) {
        if (cmp.back().second != src) cmp.push_back({ran ? kUpN[ran] : "resized", src});
        cmp.push_back({u[2] > 0 ? "sharpened: the result" : "the result", src});
        size_t n = cut ? 0 : cmp.size(); // a cut has no strips
        double sw = (double)fw / fmax(1, n);
        for (size_t i = 0; i < n; i++) {
            NSUInteger x0 = (NSUInteger)llround(vp.originX + i * sw), x1 = (NSUInteger)llround(vp.originX + (i + 1) * sw);
            if (i + 1 < n && x1 > x0 + 2) x1 -= 1; // a hairline of the frame beneath stays between the strips
            gSc = (MTLScissorRect){x0, (NSUInteger)vp.originY, x1 - x0, (NSUInteger)fh};
            gScOn = true;
            MTLViewport v = vp;
            if (cm == 7) v.originX = round(vp.originX + i * sw - (fw - sw) / 2); // the picture's middle strip lands in this one
            id<MTLTexture> t = cmp[i].second;
            float cu[4] = {1.0f / t.width, 1.0f / t.height, i + 1 == n ? u[2] : 0, 0};
            pass(cb, gPipeOut, t, nil, dr.texture, v, cu, true);
            gScOn = false;
            names += (i ? "|" : ""); names += cmp[i].first;
        }
        static id<MTLTexture> line; // a thin light line where one strip ends and the next begins
        if (!line) {
            line = [gDev newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO]];
            const uint8_t px[4] = {150, 150, 150, 150}; // premultiplied, as the overlay's texture is
            [line replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:px bytesPerRow:4];
        }
        // the original left, above or below the diagonal, the result on the other side. 1 left | right, 2 above / below, 3
        // diagonal \: one picture, cut. 4 side by side, 5 one above the other: the picture's middle half twice
        if (cut) {
            id<MTLTexture> o = orig ?: cmp[0].second;
            bool across = cm == 2 || cm == 5, twice = cm >= 4; // the dividing line lies across
            double hw = round(fw / 2.0), hh = round(fh / 2.0);
            auto half = [&](id<MTLTexture> t, bool second, float sharp) {
                gSc = across ? (MTLScissorRect){(NSUInteger)vp.originX, (NSUInteger)(vp.originY + (second ? hh : 0)), (NSUInteger)fw, (NSUInteger)(second ? fh - hh : hh)}
                             : (MTLScissorRect){(NSUInteger)(vp.originX + (second ? hw : 0)), (NSUInteger)vp.originY, (NSUInteger)(second ? fw - hw : hw), (NSUInteger)fh};
                gScOn = true;
                MTLViewport v = vp;
                double off = round((across ? fh : fw) / 4.0) * (second ? 1 : -1);
                if (twice) { if (across) v.originY += off; else v.originX += off; }
                float cu[4] = {1.0f / t.width, 1.0f / t.height, sharp, 0};
                pass(cb, gPipeOut, t, nil, dr.texture, v, cu, true);
                gScOn = false;
            };
            if (cm == 3) {
                float cu[4] = {0, 0, (float)fmax(1, round(gScale)) * 0.5f, 0};
                pass(cb, gPipeCut, o, nil, dr.texture, vp, cu, true);
            } else {
                half(o, false, 0);
                if (twice) half(src, true, u[2]);
                double th = fmax(1, round(gScale));
                if (line) pass(cb, gPipeHud, line, nil, dr.texture, across ? (MTLViewport){vp.originX, vp.originY + hh - 1, (double)fw, th, 0, 1}
                                                                     : (MTLViewport){vp.originX + hw - 1, vp.originY, th, (double)fh, 0, 1}, NULL, true);
            }
            names = "original|final";
            if (labels) { // two captions as wide as the picture's halves: each goes where its half is
                double lh = fmin((double)labels.height, (double)fh), lw = fmin((double)labels.width, (double)fw);
                for (int k = 0; k < 2; k++) {
                    double y = fmax(vp.originY, across ? vp.originY + (k ? fh : hh) - lh : cm == 3 && k ? vp.originY : vp.originY + fh - lh);
                    gSc = (MTLScissorRect){(NSUInteger)(vp.originX + k * hw), (NSUInteger)y, (NSUInteger)(k ? fw - hw : hw), (NSUInteger)lh};
                    gScOn = true;
                    pass(cb, gPipeHud, labels, nil, dr.texture, (MTLViewport){vp.originX, y, lw, lh, 0, 1}, NULL, true);
                    gScOn = false;
                }
            }
        }
        for (size_t i = 1; i < n && line; i++)
            pass(cb, gPipeHud, line, nil, dr.texture, (MTLViewport){(double)llround(vp.originX + i * sw) - 1, vp.originY, fmax(1, round(gScale)), (double)fh, 0, 1}, NULL, true);
        if (labels && !cut) {
            double lh = fmin((double)labels.height, (double)fh), lw = fmin((double)labels.width, (double)fw);
            pass(cb, gPipeHud, labels, nil, dr.texture, (MTLViewport){vp.originX, vp.originY + fh - lh, lw, lh, 0, 1}, NULL, true);
        }
    }
    os_unfair_lock_lock(&gLock); gCmpNames = names; os_unfair_lock_unlock(&gLock);
    id<MTLTexture> fin = nil;
    NSString *snapWhat = nil;
    // not while apple super resolution is asked for and something else scaled this frame (still starting, late): the
    // snapshot waits for the frame's next time round
    if (snapAt >= 0 && !(up == 2 && ran != 2 && fw > W && fh > H && !srYields() && superres::available() && !gInfoNet)) {
        static const char *const kRan[] = {"plain", "metalfx", "apple sr", "edge-aware fsr 1", "edge-aware sgsr 1"};
        NSString *name = [NSString stringWithFormat:@"f%03d%s", snapNo, real ? "g" : ""];
        os_unfair_lock_lock(&gLock);
        if (snapAt < (int)gSnapWant.size()) gSnapWant.erase(gSnapWant.begin() + snapAt);
        snapPath = [gSnapDir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
        os_unfair_lock_unlock(&gLock);
        snapWhat = [NSString stringWithFormat:@"%@ loop %d ran %s%s", name, gLoop.load(), gInfoNet ? "enhance" : kRan[ran], gInfoNet && ran ? [NSString stringWithFormat:@" + %s", kRan[ran]].UTF8String : ""];
    }
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
    int li = gLog ? gLogN.fetch_add(1) : kLogMax;
    LogRow *lr = li < kLogMax ? &gLog[li] : NULL;
    if (lr) *lr = {arrival > 0 ? "real" : real ? "gen" : "repeat", frameOf(real ?: pb), arrival > 0 ? sinceStart(arrival) : 0, 0, 0, 0, real ? framegen::lastMs() : 0};
    [dr addPresentedHandler:^(id<MTLDrawable> d) {
        static std::atomic<double> last{0};
        double pt = d.presentedTime;
        if (lr && pt > 0) lr->presented = sinceStart(pt);
        if (pt > 0) { gQueueLag = pt - handed; if (pt - handed > 2.5 * dur) gLagRun++; else gLagRun = 0; }
        else gLagRun = 0; // not on a screen: nothing known
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
        double gpu = (c.GPUEndTime - c.GPUStartTime) * 1000, all = gpu + gGpuCarry.exchange(0);
        os_unfair_lock_lock(&gLock);
        gS.gpuBusy += gpu;
        gpu = all;
        if (lr) lr->gpu = gpu;
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
        // not on this thread: the read back and the png take 100 ms and more, and every later command buffer's
        // completion (which the frame generator may be waiting for) would stand behind it
        static dispatch_queue_t q = dispatch_queue_create("snapshot", DISPATCH_QUEUE_SERIAL);
        if (fin) dispatch_async(q, ^{ savePng(fin, snapPath, snapWhat); });
        else if (snapWhat) gSnapLeft--;
    }];
    [cb presentDrawable:dr];
    [cb commit];
    if (lr) lr->present = sinceStart();
    os_unfair_lock_lock(&gLock);
    gS.drawn++;
    did |= (real ? 1u << kDidGen : 0) | (ran ? 1u << (kDidUp + ran) : 0) | (net ? 1u << (kDidE0 + at) : 0) | (u[2] > 0 ? 1u << kDidSharp : 0);
    for (int i = 0; i < kDidN; i++) gS.did[i] += did >> i & 1;
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
    copyFrame(src, nv);
    CVBufferRemoveAttachment(nv, kPicKey);
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
    // genSmall: the 1280x720 copy, made while the frame is in the cache. every 3x3 pixels
    // become 2x2 by area (7282 / 65536 = 1/9). chroma: three rows averaged, across placed on the left luma sample
    // of each small pair like the source has it
    CVPixelBufferRef sm = NULL;
    int step = gSmall;
    if (step && gSmPool && gSmPoolFor != step) { CVPixelBufferPoolRelease(gSmPool); gSmPool = NULL; }
    if (gSmall && !gSmPool) {
        gSmPoolFor = step;
        NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                            (id)kCVPixelBufferWidthKey: @(kGenSmallW[step]), (id)kCVPixelBufferHeightKey: @(kGenSmallH[step]),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &gSmPool);
    }
    if (gSmall && gSmPool && CVPixelBufferPoolCreatePixelBuffer(NULL, gSmPool, &sm) == kCVReturnSuccess) {
        tag709(sm);
        CVPixelBufferLockBaseAddress(sm, 0);
        uint8_t *y2 = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(sm, 0), *c2 = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(sm, 1);
        size_t yrb2 = CVPixelBufferGetBytesPerRowOfPlane(sm, 0), crb2 = CVPixelBufferGetBytesPerRowOfPlane(sm, 1);
        if (step != 1) { // the sizes in between, from the 420 planes just written
            static struct { int step = 0; std::vector<AreaTap> yx, yy, cx, cy; } ta;
            if (ta.step != step) {
                int w = kGenSmallW[step], h = kGenSmallH[step];
                ta.yx = areaTaps(W, w, 0.5); ta.yy = areaTaps(H, h, 0.5); ta.cx = areaTaps(W / 2, w / 2, 0.25); ta.cy = areaTaps(H / 2, h / 2, 0.5);
                ta.step = step;
            }
            areaPlane(y, yrb, W, 1, y2, yrb2, ta.yx, ta.yy);
            areaPlane(c, crb, W / 2, 2, c2, crb2, ta.cx, ta.cy);
        }
        if (step == 1) {
        for (int r = 0; r < kSmH; r++) {
            const uint8_t *a = y + (r / 2 * 3 + (r & 1)) * yrb, *b = a + yrb; // two rows of the luma just written, the nearer one counts double
            int wa = (r & 1) ? 1 : 2, wb = 3 - wa;
            uint8_t *o = y2 + r * yrb2;
            for (int k = 0; k < kSmW / 2; k++) { // plain strides of 3 and 2: the compiler makes vector code of it
                o[2 * k] = (uint8_t)(((wa * (2 * a[3 * k] + a[3 * k + 1]) + wb * (2 * b[3 * k] + b[3 * k + 1])) * 7282 + 32768) >> 16);
                o[2 * k + 1] = (uint8_t)(((wa * (a[3 * k + 1] + 2 * a[3 * k + 2]) + wb * (b[3 * k + 1] + 2 * b[3 * k + 2])) * 7282 + 32768) >> 16);
            }
        }
        for (int r = 0; r < kSmH / 2; r++) {
            const uint8_t *a = s + (3 * r) * srb, *b = a + srb, *d = b + srb;
            uint8_t *o = c2 + r * crb2;
            for (int k = 0; k < kSmW / 4; k++, a += 12, b += 12, d += 12, o += 4)
                for (int ch = 0; ch < 4; ch += 2) { // u at 0 4 8, v at 2 6 10
                    int q0 = a[ch] + b[ch] + d[ch], q1 = a[4 + ch] + b[4 + ch] + d[4 + ch], q2 = a[8 + ch] + b[8 + ch] + d[8 + ch];
                    o[ch / 2] = (uint8_t)((7 * q0 + q1 + 12) / 24);
                    o[2 + ch / 2] = (uint8_t)((3 * q1 + 5 * q2 + 12) / 24);
                }
        }
        }
        CVPixelBufferUnlockBaseAddress(sm, 0);
        CVBufferSetAttachment(nv, kSmallKey, sm, kCVAttachmentMode_ShouldNotPropagate);
        CFRelease(sm);
    } else CVBufferRemoveAttachment(nv, kSmallKey); // the pool hands buffers out again
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

// may a frame be generated between these two real frames. as it always was: not when their mean difference is over the
// limit, which stands for a cut and for motion too fast to interpolate alike. cutTest: a cut is told by the coarse
// picture and its histogram (cadence.h), and a flash is not one. what is neither is still held to the old limit, so
// very fast motion is skipped as before
using cadence::Luma;
static bool lockLuma(CVPixelBufferRef pb, Luma &l);
static cadence::CutState gCut;
static bool calmPair(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!gSet.cutTest) return lumaDiff(a, b) <= kMotionLimit;
    static cadence::Grid ga, gb;
    Luma l;
    ga.ok = gb.ok = false;
    if (lockLuma(a, l)) { cadence::grid(l, ga); CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly); }
    if (lockLuma(b, l)) { cadence::grid(l, gb); CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly); }
    int k = ga.ok && gb.ok ? cadence::classify(ga, gb, gCut) : cadence::kPairSame;
    if (k == cadence::kPairCut) { bump(&Stats::cuts); return false; }
    if (k == cadence::kPairFlash) { bump(&Stats::flashes); return true; }
    return lumaDiff(a, b) <= kMotionLimit;
}

// the chain's pre part on the gpu: dither removal and / or the enhance net on a real frame before the interpolator
// sees it. 420v in, 420v out in the source's own range (written back as video range a full range picture would have
// its levels applied twice later, and 256 steps squeezed into 220). the net works at 2x and is brought back down
static void preGen(CVPixelBufferRef nv) {
    int ch = gCh, W = (int)CVPixelBufferGetWidth(nv), H = (int)CVPixelBufferGetHeight(nv);
    bool D = (ch & kPreD) && effDeband();
    int en = (ch & kPreE) && effEnhance() <= nets::count() ? effEnhance() : 0;
    if (!D && !en) return;
    if (!gPreRgb || (int)gPreRgb.width != W || (int)gPreRgb.height != H) {
        MTLTextureUsage use = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        gPreRgb = makeTex(W, H, use); gPreFlat = makeTex(W, H, use); gPreDown = makeTex(W, H, use);
        if (gPrePool) CVPixelBufferPoolRelease(gPrePool);
        gPrePool = NULL;
        NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                            (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &gPrePool);
    }
    CVPixelBufferRef out = NULL;
    if (!gPreRgb || !gPreFlat || !gPreDown || !gPrePool || CVPixelBufferPoolCreatePixelBuffer(NULL, gPrePool, &out) != kCVReturnSuccess) return;
    std::array<CVMetalTextureRef, 4> p = {plane(nv, 0, false), plane(nv, 1, false), plane(out, 0, true), plane(out, 1, true)};
    if (!p[0] || !p[1] || !p[2] || !p[3]) { for (auto x : p) if (x) CFRelease(x); CFRelease(out); return; }
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    MTLViewport full = {0, 0, (double)W, (double)H, 0, 1};
    float lv[4] = {fullRange() ? 1.0f : 0.0f, 0, 0, gSd ? 1.0f : 0.0f};
    pass(cb, gPipeNv, CVMetalTextureGetTexture(p[0]), CVMetalTextureGetTexture(p[1]), gPreRgb, full, lv);
    id<MTLTexture> src = gPreRgb, net = nil;
    if (D) {
        float db[4] = {1.0f / W, 1.0f / H, gDebandT / 255, 0};
        pass(cb, gPipeDeband, src, nil, gPreFlat, full, db);
        src = gPreFlat;
    }
    bool keep = gSet.enhanceHold && !gSet.passthrough; // real frames only as it is: steady enhance is all there is to add
    if (en && (net = keep ? enhance(cb, en, 0, src, nv, false, NULL, NULL) : nets::run(cb, en, src))) {
        if (!keep) netRan(en, src);
        float du[4] = {1.0f / net.width, 1.0f / net.height, (float)gSet.enhanceDown, 0};
        if ((int)net.width > W) { pass(cb, gPipeDown, net, nil, gPreDown, full, du); src = gPreDown; }
        else src = net;
    }
    gPreNet = net ? en : 0;
    pass(cb, gPipeBackY, src, nil, CVMetalTextureGetTexture(p[2]), full, lv);
    pass(cb, gPipeBackC, src, nil, CVMetalTextureGetTexture(p[3]), (MTLViewport){0, 0, W / 2.0, H / 2.0, 0, 1}, lv);
    CFRetain(nv);
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { for (auto x : p) CFRelease(x); CFRelease(nv); }];
    timed(cb);
    [cb commit];
    tag709(out);
    copyFrame(nv, out);
    CVBufferSetAttachment(out, kPreKey, kCFBooleanTrue, kCVAttachmentMode_ShouldNotPropagate);
    CVBufferSetAttachment(nv, kPicKey, out, kCVAttachmentMode_ShouldNotPropagate);
    CFRelease(out);
    gPreCb = cb; gPreFor = nv;
}

// a real frame, fresh from toNV: start what the chain has before the interpolator
static void pre(CVPixelBufferRef nv, bool gen) {
    if (gCh & (kPreN | kPreNSide)) {
        CVPixelBufferRef d = noise::start(nv);
        if (!d) { bump(&Stats::noiseRaw); return; }
        copyFrame(nv, d);
        CVBufferSetAttachment(nv, kPicKey, d, kCVAttachmentMode_ShouldNotPropagate);
        CFRelease(d);
    } else if (gen && (gCh & (kPreD | kPreE))) preGen(nv);
}

// ask for the frame between two real ones. the newer one's pre picture may not be finished: the generator waits for it
static void ask(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferRef in = genIn(b);
    bool (^ready)(void) = nil;
    if (in != b && in == held(b, kPicKey)) {
        id<MTLCommandBuffer> cb = gPreFor == b ? gPreCb : nil;
        if (cb) ready = ^{ return (bool)(cb.status >= MTLCommandBufferStatusCompleted); };
        else if (!CVBufferHasAttachment(in, kPreKey)) ready = ^{ return noise::done(in); }; // the request holds on to the frame
    }
    // the older one's noise filter can still be at work when the newer frame was turned down over it: its buffer is
    // half written then, and the newer frame is raw anyway
    CVPixelBufferRef pa = genIn(a);
    if (pa != a && pa == held(a, kPicKey) && !CVBufferHasAttachment(pa, kPreKey) && !noise::done(pa)) pa = a;
    framegen::request(pa, in, ready, fullRange(), gSd);
}

// frame scheduling, render thread only.
// tick schedule: on a new real frame show the previous real one and start generating; on the repeat tick show the
//   generated frame. real frames reach the screen one frame pair (33.4 ms) after they arrive.
// early schedule: the generated frame goes up as soon as it can be expected to exist (budget: how long the generator
//   has recently needed, plus a margin), the real frame one frame time after that. same even spacing, less delay.
//   needs timed presents, hence gNextDue and the realtime render thread.
static CVPixelBufferRef prevNv, curNv; // newest real frame already on screen, and the one waiting behind the generated frame
static double prevArrival, curArrival;
static double curWhen, nextWhen;       // the time a held frame's presents are planned from: its arrival, or the capture clock's word for it (ptsTime)
static int newRun, repeatRun;
static bool genAsked;
static bool early;                     // schedule the held frames were planned under
static double gMidDue, gRealDue, gNextDue;
static int skipRun, calmRun;
static bool through;
static bool prevCounted;               // prevNv has gone up once with its arrival time: its later showings are not new samples for the delay
// apple super resolution next to frame generation ("deep"). the two share the neural engine and each slows the other,
// so they go strictly one after the other: generate (11 ms), scale the generated frame (8), scale the next real frame
// (8). measured that way it all fits in a 33 ms pair, but the generated frame is on screen ~22 ms after its real frame
// arrived, not 13, and the real frame 17 ms after that: a few ms after the NEXT real frame has come in. that one
// waits here (generation for it starts at once), and takes its place when the held frame has been shown
static bool deep;
static CVPixelBufferRef nextNv;
static CVPixelBufferRef plainNv; // no frame generation, noise filter on: the frame on screen, shown again for its repeats
static double nextArrival;
static bool nextAsked;
// only while super resolution really runs: in a window no larger than the source, or while its session is starting or
// has failed, the plain schedules show frames sooner
// srNoDeep (hidden, for tests): never in turns. the scaler then runs inside show() next to the interpolator
static bool deepWanted() {
    static const bool no = [NSUserDefaults.standardUserDefaults boolForKey:@"srNoDeep"];
    return !no && effFrameGen() && effUpscale() == 2 && gSet.srWithGen && superres::available() && gSrCan;
}
// 1.5 ms of margin left 1% of generated frames late live. pre stages run before the generator can start: their time
// (as it had to wait for them) counts, and the 15 ms ceiling does not hold then
// genDeadline 1, by the usual: the peak is one slow frame in the last few seconds, and with the second generator on
// a shared gpu there is nearly always one, so its 6 ms frames were waited 14 ms for. by the time 95 of 100 recent
// frames took, plus a margin for the wake-up and the hand-over, and no floor: the slow few come late (dropped, or
// shown a refresh on with genLateNext) and every other frame is up sooner
static const double kUsualMargin = 2.0;
static std::atomic<double> gBudgetMs{0};
double genBudgetMs() { return gBudgetMs; }
static double genBudget() {
    bool pre = gCh & (kPreN | kPreD | kPreE);
    double usual = gSet.genDeadline == 1 ? framegen::usualMs() : 0; // 0: too few frames yet, as by the slowest
    double ms = usual > 0 ? fmin(pre ? 30.0 : 15.0, usual + (pre ? framegen::waitPeakMs() : 0) + kUsualMargin)
                          : fmin(pre ? 30.0 : 15.0, fmax((double)gSet.genFloor, framegen::peakMs() + (pre ? framegen::waitPeakMs() : 0) + 2.5));
    gBudgetMs = ms;
    return ms / 1000;
}

static void dropHeld() {
    keptForget();
    if (prevNv) { CFRelease(prevNv); prevNv = NULL; }
    if (curNv) { CFRelease(curNv); curNv = NULL; }
    if (nextNv) { CFRelease(nextNv); nextNv = NULL; }
    if (plainNv) { CFRelease(plainNv); plainNv = NULL; }
    gSrFor = NULL;
    lockDrop();
    gCut.jumped = false;
    newRun = repeatRun = 0; genAsked = false;
    gAheadWait = false;
    gMidDue = gRealDue = gNextDue = 0;
    skipRun = calmRun = 0; through = false;
    prevCounted = false;
}

// frame generation at a screen that takes frames exactly as fast as they come: a backlog in the display's queue (from
// the display changing mode at start, from a stall) never clears by itself, every frame after it waits for a drawable
// and is on screen two or three refreshes late (seen: 102 ms to the screen instead of about 58 on the tick, for as
// long as the app ran). every tick has its own picture here, so what could be left out is one generated frame or one
// showing of a still picture, when every frame of the last half second was behind, at most once a second.
// off unless -genDrain YES: tried at 60 hz on a busy machine it left a frame out every second and the delay did not
// come down. not understood yet, so it changes nothing by default
static bool genDrain() {
    static double last;
    double now = nowSec();
    if (!gGenDrain || display::variable() || gLagRun < 30 || now - last < 1) return false;
    last = now; gLagRun = 0;
    bump(&Stats::drained);
    return true;
}

// enhanceReal: the held newer frame goes through the net ahead of its turn (one run per real frame either way, only
// sooner), so the generated frame before it can take what the net added from either of its two real frames, and the
// real frame itself only has it put back on when its turn comes
static void netAhead(CVPixelBufferRef nv) {
    if (!gSet.enhanceReal || !gAhead || gSet.passthrough || !effEnhance() || (gCh & kPreE)) return;
    CVPixelBufferRef p = held(nv, kPicKey);
    for (Kept &k : gKept) if (k.of && (k.of == nv || k.of == p)) return; // done already
    if (p && !CVBufferHasAttachment(p, kPreKey) && !noise::done(p)) return; // the noise filter is not through: the net would run on the raw frame now and again on the filtered one at its turn
    show(nv, 0, NULL, NULL, false, true);
}

// genLateNext: a generated frame that is not there when due may still go up when it comes, as long as a whole refresh
// of the screen lies between then and the moment its real frame is handed over (realDue). without that room the two
// would land on the same refresh and the real frame would be pushed a refresh on, so on a screen that refreshes as
// fast as the source sends (60 hz for a 60 hz signal) there is never room and the frame is dropped as before. a
// faster screen (100, 120 hz) or a variable one has it
static double lateRoom(double realDue) {
    double p = display::period();
    return p > 0 ? (realDue - p - 0.001 - nowSec()) * 1000 : 0;
}
bool genLateRoom() { double p = display::period(); return p > 0 && gFrameDur.load() - p - 0.001 > 0.001; }
static CVPixelBufferRef takeMid(double graceMs, double realDue) {
    if (!genAsked) return NULL;
    // genWait (hidden, command line, for tests on a busy machine): wait this many ms for a generated frame however late
    static const double genWait = [[NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain][@"genWait"] doubleValue];
    CVPixelBufferRef mid = framegen::take(fmax(graceMs, genWait));
    if (!mid && gSet.genLateNext) {
        double room = lateRoom(realDue);
        if (room > 0 && (mid = framegen::take(framegen::done() ? 0 : room))) bump(&Stats::genNext);
    }
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
        CVPixelBufferRef mid = takeMid(1.5, gRealDue);
        if (mid && genDrain()) { CFRelease(mid); mid = NULL; }
        if (mid) { netAhead(curNv); show(mid, 0, curNv, prevNv); CFRelease(mid); } // ahead: only if it was not at arrival
        else if (gAheadWait && curNv) netAhead(curNv); // no generated frame to wait for any longer: the real frame must not find the net still to run
        gAheadWait = false;
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
            prevNv = curNv; prevArrival = curArrival; curNv = NULL; prevCounted = true;
        }
        gRealDue = 0;
        if (nextNv) { // the frame that came in meanwhile moves up. its generated frame is already being made
            curNv = nextNv; curArrival = nextArrival; curWhen = nextWhen; genAsked = nextAsked; nextNv = NULL;
            gMidDue = curWhen + genBudget();
            gRealDue = gMidDue + gFrameDur.load();
        }
    }
    gNextDue = gMidDue > 0 ? gMidDue : gRealDue;
}

// one capture tick. owns pb.
// changed: a repeat that is not bit for bit the frame before (something small moved: a spinner, a cursor, typed text)
// when: the time to plan this frame's presents from. its arrival, unless ptsTime has a steadier one
static void tick(CVPixelBufferRef pb, double arrival, double when, bool repeat, bool changed) {
    bool dw = deepWanted(), ew = gSet.early || dw; // deep needs timed presents
    int pw = (int)CVPixelBufferGetWidth(pb), ph = (int)CVPixelBufferGetHeight(pb);
    // genModel: the second generator works on a small copy of its own making, genSmall's is apple's fast path only
    static int genM;
    int gm = framegen::model();
    int sm = effFrameGen() && !gm && pw == 1920 && ph == 1080 ? gSet.genSmall.load() : 0; // the one size the shrinks in toNV are written for
    if (genM != gm) { framegen::cancel(); dropHeld(); genM = gm; } // a pair is made by one generator
    if (early != ew || deep != dw || gSmall != sm) { // the schedules keep different promises: start clean. genSmall: both frames of a pair must be the same size
        framegen::cancel();
        dropHeld();
        early = ew; deep = dw;
        gDeepNow = dw;
        gSmall = sm;
    }
    // frame generation needs yuv 4:2:2 input at an even size the interpolator accepts
    bool yuv = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8;
    bool genOk = effFrameGen() && yuv && framegen::ready(sm ? kGenSmallW[sm] : pw, sm ? kGenSmallH[sm] : ph, gm);
    // the chain as it can run now. without the interpolator its pre stages run after (the noise filter before show).
    // genSmall's copy is made from the raw frame, so the same there. a filter the interpolator has to wait for needs
    // timed presents: on the tick 1 + 10 + 11 ms is past the 18.7 there are, it runs beside it instead
    int ch = (gSet.chain & ~(kPreN | kPreNSide)) | effNoise();
    if ((ch & (kPreN | kPreNSide)) && !(yuv && noise::can(pw, ph))) ch &= ~(kPreN | kPreNSide);
    if (!genOk || sm) ch = (ch & ~(kPreD | kPreE)) | ((ch & kPreD) ? kPostD : 0) | ((ch & kPreE) ? kPostE : 0);
    if ((ch & kPreN) && genOk && (sm || !early)) ch = (ch & ~kPreN) | kPreNSide;
    gCh = ch;
    if (gSet.gpuAwake && ((effEnhance() && effEnhance() <= nets::count()) || (gm && genOk))) awake::touch(); // gpu work for every frame: a net, or the second generator
    if (prevNv && (CVPixelBufferGetWidth(prevNv) != CVPixelBufferGetWidth(pb) || CVPixelBufferGetHeight(prevNv) != CVPixelBufferGetHeight(pb))) dropHeld();
    if (gHlFor && !(genOk && gSet.hudLock)) lockDrop();
    if (!genOk) {
        if (prevNv || curNv) { framegen::cancel(); dropHeld(); }
        // repeats are shown too. left out, each frame of a 30 fps game stayed up for one refresh or three whenever the
        // timing wobbled (the counts looked perfect, the picture looked choppy); shown, each one stays exactly two.
        // the catch: at a 60 hz screen frames then go in exactly as fast as they come out, and a backlog (from start-up,
        // from a stall) never clears: measured 75 ms to the screen instead of 21. so when the display's queue has
        // backed up, one repeat is left out to drain a place. passthrough too (gDrain), see below
        static double lastSkip;
        double now = CACurrentMediaTime();
        bool backed = gQueueLag > 2.0 * gFrameDur && now - lastSkip > 0.25;
        // passthrough used to be exempt, and sat on a backlog for good: 57 to 80 ms to the screen where the picture chain
        // had 25, and 8 to 17 ms of every frame spent waiting for a drawable. the repeat left out is the frame already
        // on screen, so it now drains too (-drain NO: as before)
        if ((!gSet.passthrough || gDrain) && repeat && !changed && !display::variable() && backed) { lastSkip = now; if (gSet.passthrough) bump(&Stats::drained); CFRelease(pb); return; }
        // noise filter: the frame goes the 420v way and show() waits for the filter (~10 ms later on screen). its
        // repeats show the same filtered frame again, the raw one next to it would flicker
        if (ch & (kPreN | kPreNSide)) {
            if (!repeat || changed || !plainNv) {
                CVPixelBufferRef nv = toNV(pb);
                if (nv) { pre(nv, false); if (plainNv) CFRelease(plainNv); plainNv = nv; }
            }
            CFRelease(pb);
            if (plainNv) show(plainNv, repeat ? 0 : arrival);
            return;
        }
        if (plainNv) { CFRelease(plainNv); plainNv = NULL; }
        gRepeatNow = repeat && !changed; // enhanceReal, enhanceHold: the net's work on the frame before is used again
        show(pb, repeat ? 0 : arrival);
        gRepeatNow = false;
        CFRelease(pb);
        return;
    }
    if (plainNv) { CFRelease(plainNv); plainNv = NULL; }
    if (!repeat) {
        CVPixelBufferRef nv = toNV(pb);
        CFRelease(pb);
        if (!nv) return;
        pre(nv, true);
        if (gSet.hudLock) lockUpdate(nv);
        newRun++; repeatRun = 0;
        // see deep: the held frame is shown first. the same on the early schedule when pre stages have pushed the
        // budget past a frame time: the held real frame is then due after this one has come in
        if ((deep || (gCh & (kPreN | kPreD | kPreE))) && curNv && gRealDue > 0 && gMidDue == 0 && !nextNv) {
            nextNv = nv; nextArrival = arrival; nextWhen = when;
            nextAsked = calmPair(curNv, nv);
            if (nextAsked) ask(curNv, nv);
            else bump(&Stats::genSkipped);
            return;
        }
        if (nextNv) { framegen::cancel(); CFRelease(nextNv); nextNv = NULL; } // a third frame on top: 60 fps content, or this schedule fell a pair behind
        if (curNv) { // previous real frame never got its turn: the source is running at 60, not 30
            // early: or this frame came a few ms before the held one was due (the margin is only 2-5 ms). show it now
            prevCounted = early && gRealDue > 0;
            if (prevCounted) show(curNv, curArrival);
            if (prevNv) CFRelease(prevNv);
            prevNv = curNv; prevArrival = curArrival; curNv = NULL;
        }
        if (newRun >= 2 || !prevNv) { // 60 fps content (menus), or the very first frame: nothing to generate, show it straight
            if (prevNv) CFRelease(prevNv);
            prevNv = nv; prevArrival = arrival; prevCounted = true;
            genAsked = false;
            gMidDue = gRealDue = gNextDue = 0;
            show(prevNv, arrival);
            return;
        }
        // normal 30 fps case: hold the new frame and start on the middle
        bool calm = calmPair(prevNv, nv);
        skipRun = calm ? 0 : skipRun + 1;
        calmRun = calm ? calmRun + 1 : 0;
        // nothing is being generated for a while (very fast motion): waiting a frame pair then only costs delay.
        // after half a second of that, pass real frames straight through until motion has been calm again for a bit
        if (!through && skipRun >= kThroughAfter) through = true;
        if (through && calmRun >= kCalmToLeave) through = false;
        if (through) {
            if (prevNv) CFRelease(prevNv);
            prevNv = nv; prevArrival = arrival; prevCounted = true;
            genAsked = false;
            gMidDue = gRealDue = gNextDue = 0;
            bump(&Stats::genSkipped);
            show(prevNv, arrival);
            return;
        }
        curNv = nv; curArrival = arrival; curWhen = when;
        genAsked = calm;
        if (genAsked) ask(prevNv, curNv);
        else bump(&Stats::genSkipped);
        // enhanceReal's run ahead goes here, when the frame has just come in: before the generated frame it would
        // stand between that frame and the screen. a noise filtered frame is not ready yet, that one goes before the
        // generated frame after all
        bool ahead = !(gCh & (kPreN | kPreNSide));
        // enhanceAhead 2: not next to the second generator. the render thread is woken when the generated frame is made
        // and runs the net then (see the thread's loop); should that be at the frame's due time, runDue's own order holds
        gAheadWait = ahead && gAheadAfter && gm && genAsked && gSet.enhanceReal;
        if (gAheadWait) { ahead = false; framegen::tellWhenDone(gWake); }
        if (early) {
            gMidDue = when + genBudget();
            gRealDue = gMidDue + gFrameDur.load();
            gNextDue = gMidDue;
            if (ahead) netAhead(curNv);
            return; // the previous real frame went up at its own due time
        }
        // a real frame, one tick pair after it arrived. below 30 fps it has been up already, on its third signal frame:
        // shown again, but not counted again (the delay read 8 ms too long at 20 fps, and the audio followed it)
        show(prevNv, prevCounted ? 0 : prevArrival);
        prevCounted = true;
        if (ahead) netAhead(curNv);
        return;
    }
    newRun = 0; repeatRun++;
    // a still picture with something small changing on it: no pair is waiting, so this frame becomes the one on screen.
    // without this the change only showed once a later frame differed by more than kRepeatSlack samples
    // the same when no frame is held at all: the picture has been still since before frame generation could start (its
    // session takes a second or two to come up, a switch that restarts the schedule drops what was held). nothing was
    // drawn then until the picture moved, so the overlay and the hint line stood still with it
    if ((changed || !prevNv) && !curNv && gNextDue == 0) {
        CVPixelBufferRef nv = toNV(pb);
        CFRelease(pb);
        if (nv) { pre(nv, true); if (prevNv) CFRelease(prevNv); prevNv = nv; prevArrival = arrival; prevCounted = !changed; show(prevNv, 0); }
        return;
    }
    CFRelease(pb); // a copy of what we already have
    if (early) { // timed presents take care of the held frames. nothing due: keep the overlay and settings alive
        static double lastIdle;
        if (gNextDue == 0 && prevNv && nowSec() - lastIdle > 0.1) { lastIdle = nowSec(); show(prevNv, 0); }
        return;
    }
    if (repeatRun == 1 && curNv) {
        CVPixelBufferRef mid = takeMid(2, arrival + gFrameDur.load()); // the real frame goes up on the next tick
        if (mid && genDrain()) CFRelease(mid); // the display's queue is behind: this tick shows nothing
        else if (mid) { netAhead(curNv); show(mid, 0, curNv, prevNv); CFRelease(mid); }
        else show(prevNv, 0); // not ready or skipped: same as the console would have shown
        if (gAheadWait) netAhead(curNv); // as in runDue
        gAheadWait = false;
        if (prevNv) CFRelease(prevNv);
        prevNv = curNv; prevArrival = curArrival; curNv = NULL; prevCounted = false;
        return;
    }
    if (prevNv && !genDrain()) { // game dropped a frame, hold the newest real one
        show(prevNv, repeatRun == 2 && !prevCounted ? prevArrival : 0);
        if (repeatRun == 2) prevCounted = true;
    }
}

// analysis on the capture thread: repeats, rolled frames, levels

// luma samples of a frame, whatever its layout: Luma, cadence.h
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

// repeatTol: the tolerant test's own samples, of the last NEW frame (cadence.h)
static cadence::Sig gTolSig, gTolNow; static bool gHaveTol;
static cadence::PtsClock gClock; // ptsTime. capture thread only

void submit(CVPixelBufferRef pb, double arrival, double captured, bool late, double pts) {
    Luma l;
    bool repeat = false, changed = false, tol = gSet.repeatTol && !gSet.passthrough; // passthrough: only an exact copy is a repeat
    int darkest = 255, over = -1; float shift = 0;
    // ptsTime: every callback is a sample for the clock, repeats too. a source without timestamps: as without the switch
    double when = arrival;
    if (gSet.ptsTime && pts >= 0) when = gClock.feed(pts, arrival, gFrameDur);
    else if (gClock.n) gClock = cadence::PtsClock();
    if (lockLuma(pb, l)) {
        Sig g; Profile p; int dark;
        analyse(l, g, p, dark, darkest);
        if (tol) cadence::sig(l, gTolNow);
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
        if (tol) { // instead of the exact test. the first frame after switching on is new
            cadence::SigDiff d = gHaveTol ? cadence::sigDiff(gTolNow, gTolSig) : cadence::SigDiff();
            repeat = d.same; changed = d.changed;
            if (repeat) { over = d.over; shift = d.shift; }
            else { gTolSig = gTolNow; gHaveTol = true; }
        } else gHaveTol = false;
        if (changed) bump(&Stats::nearRepeats);
    } else gHaveTol = false;
    os_unfair_lock_lock(&gLock);
    gS.in++;
    if (darkest < gS.darkest) gS.darkest = darkest;
    if (repeat) gS.repeats++; else gS.real++;
    if (late) gS.late++;
    if (captured > 0 && arrival > captured) { gS.lagSum += (arrival - captured) * 1000; gS.lagN++; }
    if (over > gS.repOver) gS.repOver = over;
    if (shift > gS.repShift) gS.repShift = shift;
    if (gClock.n) { gS.ptsJit = gClock.jit * 1000; gS.ptsMargin = (when - pts - gClock.off) * 1000; gS.ptsIgnored = gClock.ignored; gS.ptsMoved = gClock.moved; gS.ptsResets = gClock.resets; }
    CVPixelBufferRef old = gNewest;
    // a new frame still waiting when its own repeat comes in: same picture, and it stays new (with its own arrival
    // time). otherwise the render thread only ever sees "repeat" and that game frame is never shown
    if (old && !gNewestRepeat && repeat) { repeat = false; arrival = gNewestArrival; when = gNewestWhen; }
    gNewest = pb; gNewestArrival = arrival; gNewestCaptured = captured; gNewestWhen = when; gNewestRepeat = repeat; gNewestChanged = repeat && changed;
    if (old) gS.superseded++;
    os_unfair_lock_unlock(&gLock);
    if (old) CFRelease(old);
    dispatch_semaphore_signal(gWake);
}

void noSignalFrame() { bump(&Stats::nosignal); }

void beginSource(double frameDur, bool sameSource) {
    gHaveSig = gHaveProf = gHaveTol = false;
    gClock = cadence::PtsClock(); // the old source has stopped, the new one has not started
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
                if (gResetReq.exchange(false)) { framegen::cancel(); dropHeld(); thaw(); }
                os_unfair_lock_lock(&gLock);
                CVPixelBufferRef pb = gNewest;
                double arrival = gNewestArrival, when = gNewestWhen;
                bool repeat = gNewestRepeat, changed = gNewestChanged;
                gNewest = NULL;
                os_unfair_lock_unlock(&gLock);
                if (gClearReq.exchange(false) && !pb) { framegen::cancel(); dropHeld(); clearNow(); }
                double t = nowSec();
                if (pb) tick(pb, arrival, when, repeat, changed);
                if (gAheadWait && framegen::done()) { gAheadWait = false; if (curNv) netAhead(curNv); }
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
    if (FILE *f = gLog ? fopen(gLogPath.UTF8String, "w") : NULL) {
        fprintf(f, "kind,frame,arrival,present,presented,gpu,gen\n");
        for (int i = 0, n = std::min(gLogN.load(), kLogMax); i < n; i++)
            fprintf(f, "%s,%d,%.5f,%.5f,%.5f,%.3f,%.2f\n", gLog[i].kind, gLog[i].frame, gLog[i].arrival, gLog[i].present, gLog[i].presented, gLog[i].gpu, gLog[i].gen);
        fclose(f);
    }
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
    id<MTLRenderPipelineState> __strong *pipes[] = {&gPipeYuv, &gPipeNv, &gPipeNvFix, &gPipeOut, &gPipeDeband, &gPipeEasu, &gPipeSgsr, &gPipeDown, &gPipeBox, &gPipeKeepAdd, &gPipeKeepUse};
    NSString *names[] = {@"fsYuv", @"fsNv", @"fsNvFix", @"fsOut", @"fsDeband", @"fsEasu", @"fsSgsr", @"fsDown", @"fsBox", @"fsKeepAdd", @"fsKeepUse"};
    for (int i = 0; i < 11; i++) {
        pd.fragmentFunction = [lib newFunctionWithName:names[i]];
        *pipes[i] = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!*pipes[i]) { err = std::string("pipeline ") + names[i].UTF8String; return false; }
    }
    pd.fragmentFunction = [lib newFunctionWithName:@"fsCut"];
    gPipeCut = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeCut) { err = "pipeline fsCut"; return false; }
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
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm; // and of a whole 420v frame, see preGen
    pd.fragmentFunction = [lib newFunctionWithName:@"fsBackY"];
    gPipeBackY = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsBackC"];
    gPipeBackC = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeBackY || !gPipeBackC) { err = "pipeline fsBack"; return false; }
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGB10A2Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsLook"];
    gPipeLook = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeLook) { err = "pipeline fsLook"; return false; }
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float; // hud lock's state
    pd.fragmentFunction = [lib newFunctionWithName:@"fsLockUpdate"];
    gPipeLock = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"fsNvFixLock"];
    gPipeNvFixLock = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeLock || !gPipeNvFixLock) { err = "pipeline fsLock"; return false; }
    pd.fragmentFunction = [lib newFunctionWithName:@"fsNvFixHud"];
    gPipeNvFixHud = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsNvFixLockHud"];
    gPipeNvFixLockHud = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeNvFixHud || !gPipeNvFixLockHud) { err = "pipeline fsNvFixHud"; return false; }
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float; // what a net added, and its guide
    pd.fragmentFunction = [lib newFunctionWithName:@"fsHold"];
    gPipeHold = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPipeHold) { err = "pipeline fsHold"; return false; }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([ud floatForKey:@"keepTol"] > 0) gKeepTol = [ud floatForKey:@"keepTol"];
    if ([ud floatForKey:@"holdMs"] > 0) gHoldMs = [ud floatForKey:@"holdMs"];
    if ([ud objectForKey:@"holdMargin"]) gHoldMargin = [ud floatForKey:@"holdMargin"];
    if ([ud floatForKey:@"ssGamma"] > 0) gSsGamma = [ud floatForKey:@"ssGamma"];
    if ([ud objectForKey:@"enhanceAhead"]) { gAheadAfter = [ud integerForKey:@"enhanceAhead"] == 2; gAhead = gAheadAfter || [ud boolForKey:@"enhanceAhead"]; }
    if ([ud floatForKey:@"debandT"] > 0) gDebandT = [ud floatForKey:@"debandT"];
    if ([ud floatForKey:@"hudStill"] > 0) gHlStill = [ud floatForKey:@"hudStill"] / 255;
    if ([ud objectForKey:@"drain"]) gDrain = [ud boolForKey:@"drain"];
    gGenDrain = [ud boolForKey:@"genDrain"];
    if ((gLogPath = [[ud stringForKey:@"frameLog"] stringByExpandingTildeInPath])) gLog = (LogRow *)calloc(kLogMax, sizeof(LogRow));
    // numbered snapshots, see renderer.h
    for (NSString *f in [[[ud objectForKey:@"snapFrames"] description] componentsSeparatedByString:@","])
        if (f.length) gSnapWant.push_back({f.intValue, [f hasSuffix:@"g"]});
    gSnapDir = [[ud stringForKey:@"snapDir"] stringByExpandingTildeInPath] ?: NSTemporaryDirectory();
    gSnapFrom = nowSec() + [ud doubleForKey:@"snapFrom"];
    if (!gSnapWant.empty()) {
        gSnapLeft = (int)gSnapWant.size();
        [NSFileManager.defaultManager createDirectoryAtPath:gSnapDir withIntermediateDirectories:YES attributes:nil error:nil];
        logLine("snapshots: %d frames by number into %s", gSnapLeft.load(), gSnapDir.UTF8String);
    }
    if (CVMetalTextureCacheCreate(NULL, NULL, gDev, NULL, &gCache) != kCVReturnSuccess) { err = "no metal texture cache"; return false; }
    stInit();

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
