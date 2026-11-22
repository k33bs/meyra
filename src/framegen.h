// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>
#include <cstdint>

// 30 -> 60 frame generation with apple's low latency interpolator (macos 26+). one middle frame per real pair.
namespace framegen {

bool available();                // os and hardware support it at all
void startThread();
void stopThread();                // at quit, after the render thread
bool ready(int w, int h);        // session up for this size. asking for a size starts (or restarts) the session
void request(CVPixelBufferRef prev, CVPixelBufferRef cur); // 420v, both retained by us while needed
void cancel();                   // the pending request is no longer wanted
CVPixelBufferRef take(double graceMs); // the middle frame of the last request, +1, or null if not ready in time
double peakMs();                 // slowly decaying max of recent generation times
const char *status();            // short text for the overlay

struct Stats { int n = 0; double sumMs = 0, maxMs = 0; };
Stats takeStats();

}
