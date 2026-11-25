// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>
#include <cstdint>

// 30 -> 60 frame generation: one middle frame per real pair. by apple's low latency interpolator (macos 26+), or
// by the second generator (genModel 1, 2, flyhigh.h) when the user has its files, or by block matching (3, blocks.h)
namespace framegen {

bool available();                // os and hardware support it at all
void startThread();
void stopThread();                // at quit, after the render thread
int model();                     // the generator in use: gSet.genModel, or 0 (apple's) while the second one's files are missing or the block generator is refused
const char *modelNote();         // "" or why the chosen generator is not the one in use
bool ready(int w, int h, int model = 0); // session up for this size and generator. asking starts (or restarts) the session
// 420v, both retained by us while needed. ready: the frames are still being written (gpu work, the noise filter),
// the thread waits, spinning, until it says yes. full, sd: range and matrix of the values (only the second generator asks)
void request(CVPixelBufferRef prev, CVPixelBufferRef cur, bool (^ready)(void) = nil, bool full = false, bool sd = false);
void cancel();                   // the pending request is no longer wanted
void tellWhenDone(dispatch_semaphore_t s); // once: signal s when the last request has been answered (or has failed)
bool done();                     // the last request has been answered
CVPixelBufferRef take(double graceMs); // the middle frame of the last request, +1, or null if not ready in time
double peakMs();                 // slowly decaying max of recent generation times
double usualMs();                // the time 95 of 100 of the last 120 frames were made in, 0 before there are 20
double lastMs();                 // the last frame's
double waitPeakMs();             // the same for the time spent waiting on `ready`
const char *status();            // short text for the overlay

struct Stats { int n = 0; double sumMs = 0, maxMs = 0; int waitN = 0; double waitSum = 0, waitMax = 0; };
Stats takeStats();

}
