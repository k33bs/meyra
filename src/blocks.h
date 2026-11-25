// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>

// the third frame generator (genModel 3): block matching on the gpu, no weights, no files. vectors are searched
// coarse to fine on the frame in between (each one says where a piece of it was in prev and will be in cur), so every
// output pixel has one and nothing is left to fill. gSet.genShift and gSet.genDoubt are read on every frame
namespace blocks {

// generator thread only. start: textures and pipelines for this picture size, one run on blank frames
bool start(int w, int h);
void stop();
bool refused();       // start failed or refuse() was called: model() falls back to apple's until retry(). any thread
const char *note();   // why, "" when not refused
void retry();         // forget a refusal (the user chose the generator again, or it went idle)
bool refuse(const char *why); // refuse from outside too (framegen: no output buffers). stops it, returns false
// prev, cur, dst: 420v, w x h. matched and mixed as they are (ycbcr), so range and matrix do not matter here
bool generate(CVPixelBufferRef prev, CVPixelBufferRef cur, CVPixelBufferRef dst, bool full, bool sd);
double lastGpuMs();   // gpu time of the last frame, for tests

}
