// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

// apple's low latency super resolution scaler (macos 26+). 420v in, 420v out, at most ~1280 px a side, so a 1080p
// frame goes through as two overlapping tiles. the render thread draws the tiles, the worker scales them.
namespace superres {

bool available();                // os and hardware support it at all
void startThread();
void stopThread();               // at quit, after the render thread
bool ready(int w, int h);        // session up for this source size. asking for a size starts (or restarts) the session
const char *status();            // short text for the overlay, "" when ready

// count, tile size (padding included), second tile's left edge in the picture, scaled tile size, mirrored padding on every side
struct Tiles { int n = 0, w = 0, h = 0, x1 = 0, outW = 0, outH = 0, pad = 0; };
Tiles tiles();
bool buffers(CVPixelBufferRef src[2]);                        // fresh source tiles to draw into, +1 each
void request(CVPixelBufferRef src[2], id<MTLCommandBuffer> drawn); // takes over src, scales them once `drawn` (committed) is done
bool busy();                                                  // still on an earlier request
bool take(double graceMs, CVPixelBufferRef dst[2]);           // the scaled tiles, +1 each, or false if not done in time

struct Stats { int n = 0; double sumMs = 0, maxMs = 0; };     // per request, gpu wait included
Stats takeStats();

}
