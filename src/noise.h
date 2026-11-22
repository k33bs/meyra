// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>

// apple's temporal noise filter (macos 26+) on real frames, with the frame before as its only reference: nothing is
// held back for a look ahead. it runs on the video encoder block, so neither the interpolator nor the gpu waits for
// it, but it takes ~10 ms a 1080p frame, conversions included, on a thread of its own
namespace noise {

bool available();                 // os and hardware support it at all
bool can(int w, int h);           // and it has not refused this picture size
void startThread();
void stopThread();                // at quit, after the render thread
// start on one frame (420v). the filtered picture will be in the buffer handed back (+1) once done() says so. null:
// not possible (not available, this size refused) or still busy with the frame before; the caller shows the raw frame
CVPixelBufferRef start(CVPixelBufferRef nv);
bool done(CVPixelBufferRef dst);
bool wait(CVPixelBufferRef dst, double graceMs); // done within that time
const char *status();             // short text for the overlay, "" when fine

struct Stats { int n = 0; double sumMs = 0, maxMs = 0; }; // per frame, start to done
Stats takeStats();

}
