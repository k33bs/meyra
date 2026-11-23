// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <string>

// capture -> (optional frame generation) -> levels -> dither removal -> upscale (metalfx, apple super resolution, fsr 1 or sgsr 1) -> sharpen -> screen.
// with enhance on a small net (nets.h) takes the upscaler's place, at any window size.
// the capture side only parks the newest frame; a dedicated render thread draws it.
namespace renderer {

struct Stats {
    int in = 0, nosignal = 0, late = 0, real = 0, repeats = 0, nearRepeats = 0, superseded = 0, drawn = 0, shown = 0;
    int gapN = 0, gapBad = 0; double gapMax = 0; // on-screen spacing between consecutive frames. bad = more than 4.5 ms off a whole number of frame times
    int notShown = 0;                            // presented but never reached the screen
    int rolled = 0;                              // frames with the picture shifted vertically, dropped
    int drained = 0;                             // frames left out because the display's queue had backed up: repeats in plain passthrough, generated frames
    int gen = 0, genLate = 0, genSkipped = 0;    // generated frames shown, not ready in time, too much motion
    int genNext = 0;                             // of those shown: not ready when due and put up when they came (genLateNext)
    int sr = 0, srLate = 0;                      // frames through apple super resolution, frames that fell back to metalfx (scaler busy or late)
    double gpuSum = 0, gpuMax = 0; int gpuN = 0; // per drawn frame, all its command buffers
    double gpuBusy = 0;                          // the same, summed
    int net = 0, netKept = 0, netBare = 0;       // enhance net: times it ran, frames that got its kept work instead (enhanceReal, enhanceHold), generated frames with nothing kept to take
    double netPx = 0;                            // pixels through its passes: input pixels x passes, summed over the runs
    int noiseRaw = 0;                            // real frames shown unfiltered with the noise filter on (busy, not done in time)
    double convSum = 0; int convN = 0;           // 422 -> 420 conversion for the interpolator
    double tickMax = 0, drawableMax = 0, schedLateMax = 0;
    double toPresSum = 0; int toPresN = 0;       // real frame arrival -> present call
    double toGlassSum = 0, toGlassMax = 0, toGlassMin = 1e9; int toGlassN = 0; // real frame arrival -> on screen
    double lagSum = 0; int lagN = 0;             // capture time -> arrival, where the source knows its capture time
    int darkest = 255;                           // lowest sampled luma, shows which range the source really sends
    // the experimental switches, for their own log line
    int cuts = 0, flashes = 0;                   // cutTest: pairs called a cut, and pairs that looked like one and were a flash
    int repOver = 0; float repShift = 0;         // repeatTol: among the frames called repeats, the most samples over the band and the largest block shift
    double ptsJit = 0, ptsMargin = 0; int ptsIgnored = 0, ptsMoved = 0, ptsResets = 0; // ptsTime: mean deviation and margin in ms, samples ignored / followed / clock restarts since the source began
    // for the overlay's order line: how many of the drawn frames went through each stage (kDid*)
    int did[16] = {};
    // gpu ms per stage (kSt*), summed over the command buffers measured (stageN), and those buffers' whole gpu time.
    // on unless -stageTimes NO
    double stage[9] = {}, stageCb = 0; int stageN = 0;
};
// a generated frame, dither removal and the enhance net before the interpolator, dither removal, the net after dither
// removal / before it / after the upscaler, sharpening before the upscaler, upscalers by lastSize's numbers
// (kDidUp + 1 = metalfx ...), the net's picture filtered down to the window, sharpening
enum { kDidGen, kDidPreD, kDidPreE, kDidD, kDidE0, kDidE1, kDidE2, kDidSharpFirst, kDidUp, kDidDown = kDidUp + 5, kDidSharp, kDidN };
// kStBetween: what was encoded between two of our passes without being one, the enhance net and / or metalfx
enum { kStConvert, kStDither, kStEnhance, kStUpscale, kStBetween, kStShrink, kStSharpen, kStOverlay, kStN };

bool init(NSString *shaderSource, std::string &err);
CAMetalLayer *layer();
void startThread();
void stopThread();                   // at quit, before anything it uses goes away
void setScale(double backingScale);  // main thread, for the overlay size

// sources call these
void beginSource(double frameDur, bool sameSource); // before a source starts: forget the previous one (levels survive a restart of the same source)
void setFrameDur(double sec);
void applyColour();                  // main thread: gSet.colour changed
void signalChanged();                // the source's signal changed format: levels detection starts over
// capture thread, takes over the caller's +1. pts: the frame's timestamp on the capture device's own clock in seconds
// (any start, only its steps count), -1 without one
void submit(CVPixelBufferRef pb, double arrival, double captured, bool late, double pts = -1);
void noSignalFrame();

void clear();                        // put a black picture up once (signal lost, source stopped)
void setHud(id<MTLTexture> t);       // main thread, null hides
void setLabels(id<MTLTexture> t);    // main thread: the compare view's captions, as wide as the picture
std::string compareNames();          // the stages the compare view shows, left to right, joined by '|'. empty: not showing
void snapshot(NSString *path);       // save the next drawn frame as it leaves the chain (png, without overlay)
// replay numbers its frames, and tests ask for snapshots by number (hidden: -snapFrames 16,16g -snapDir DIR, from
// -snapFrom seconds on). 16 is that frame, 16g the generated frame shown just before it. saved as f016.png, f016g.png
static const CFStringRef kFrameKey = CFSTR("MeyraFrame");
void replayLoop(int n);              // replay source: the nth pass over its frames begins
int snapsLeft();                     // numbered snapshots still to be saved, -1 when none were asked for
int chainNow();                      // the chain as it runs right now (common.h), which a schedule or a missing part can make another than the one asked for
Stats takeStats();
bool fullRange();
void lastSize(int &w, int &h, int &fitW, int &fitH, int &upscaler); // upscaler that ran last: 0 none or plain, 1 metalfx, 2 apple super resolution, 3 fsr 1, 4 sgsr 1
std::string extraText(int which, const Stats &s); // enhanceReal (0), enhanceHold (1), superSample (2): "off", "acting: ..." or "idle: why"
int enhanceRan();                   // the enhance net the last frame went through, 0 = none (off, still starting, cannot run)
double genBudgetMs();  // early schedule: how long after its real frame arrived a generated frame is due, as last planned
bool genLateRoom();    // genLateNext has room to act on this screen and schedule
int genSmallNow();    // the smaller size frames are being generated at (genSmall's number, with a 1080p source), 0 = full size
bool deepNow();                      // apple super resolution and frame generation are taking turns right now
void fitSize(size_t dw, size_t dh, size_t W, size_t H, size_t &fw, size_t &fh); // the picture inside a drawable, as show() places it (centred)
float hudLocked();                   // hud lock: share of the picture locked at the last count, -1 while there is none

}
