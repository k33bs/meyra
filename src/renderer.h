// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <string>

// capture -> (optional frame generation) -> levels -> dither removal -> upscale (metalfx, apple super resolution, fsr 1 or sgsr 1) -> sharpen -> screen.
// the capture side only parks the newest frame; a dedicated render thread draws it.
namespace renderer {

struct Stats {
    int in = 0, nosignal = 0, late = 0, real = 0, repeats = 0, nearRepeats = 0, superseded = 0, drawn = 0, shown = 0;
    int gapN = 0, gapBad = 0; double gapMax = 0; // on-screen spacing between consecutive frames. bad = more than 4.5 ms off a whole number of frame times
    int notShown = 0;                            // presented but never reached the screen
    int rolled = 0;                              // frames with the picture shifted vertically, dropped
    int gen = 0, genLate = 0, genSkipped = 0;    // generated frames shown, not ready in time, too much motion
    int sr = 0, srLate = 0;                      // frames through apple super resolution, frames that fell back to metalfx (scaler busy or late)
    double gpuSum = 0, gpuMax = 0; int gpuN = 0;
    double convSum = 0; int convN = 0;           // 422 -> 420 conversion for the interpolator
    double tickMax = 0, drawableMax = 0, schedLateMax = 0;
    double toPresSum = 0; int toPresN = 0;       // real frame arrival -> present call
    double toGlassSum = 0, toGlassMax = 0, toGlassMin = 1e9; int toGlassN = 0; // real frame arrival -> on screen
    double lagSum = 0; int lagN = 0;             // capture time -> arrival, where the source knows its capture time
    int darkest = 255;                           // lowest sampled luma, shows which range the source really sends
};

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
void submit(CVPixelBufferRef pb, double arrival, double captured, bool late); // capture thread, takes over the caller's +1
void noSignalFrame();

void clear();                        // put a black picture up once (signal lost, source stopped)
void setHud(id<MTLTexture> t);       // main thread, null hides
void snapshot(NSString *path);       // save the next drawn frame as it leaves the chain (png, without overlay)
Stats takeStats();
bool fullRange();
void lastSize(int &w, int &h, int &fitW, int &fitH, int &upscaler); // upscaler that ran last: 0 none or plain, 1 metalfx, 2 apple super resolution, 3 fsr 1, 4 sgsr 1
bool deepNow();                      // apple super resolution and frame generation are taking turns right now

}
