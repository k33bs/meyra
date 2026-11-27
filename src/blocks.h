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
void release();                  // the pair solve() holds goes (the any-rate path has ended). generator thread
bool refused();       // start failed or refuse() was called: model() falls back to apple's until retry(). any thread
const char *note();   // why, "" when not refused
void retry();         // forget a refusal (the user chose the generator again, or it went idle)
bool refuse(const char *why); // refuse from outside too (framegen: no output buffers). stops it, returns false
// prev, cur, dst: 420v, w x h. matched and mixed as they are (ycbcr), so range and matrix do not matter here
bool generate(CVPixelBufferRef prev, CVPixelBufferRef cur, CVPixelBufferRef dst, bool full, bool sd, int how = 0);
// any time between the two: solve() once per pair (the motion, the pair is held until the next solve or stop), then
// frame() at t in (0, 1), 0 = prev, 1 = cur, one gpu round each so the first can be shown before the next is made.
// frames(): several in one gpu round. how: kRelook looks the vector up again where the content sat at t = 0.5,
// kTimeBlend uses no vectors (a cross-fade by t: a baseline and a cheap fallback). generate() is solve and t = 0.5
// in one round. motion false: the pair is only held, nothing searched (kTimeBlend needs no vectors)
// fixes for the edges of moving things, off = the bytes from before: kSmall (solve, generate) the search keeps small
// fast things (a character, a ball) its coarse levels used to lose; kFallback (frame, generate) where the two sides
// still disagree after the warp, the time blend takes over: soft instead of torn; kSides (solve, generate) where
// something covers or uncovers, the side that shows it is taken, decided once a pair and smoothed (in place of genDoubt);
// kNear (frame, generate) with kFallback: the fallback takes the nearer real frame, not the time blend.
// for the character the camera follows: kStill (solve, generate) a still thing with texture keeps zero where the pan
// fits it too; kBand (solve, generate) ground seen in one frame only takes its vector from around
// kWhole (solve, frame) a camera whip: when most of the picture fits no vector, frames are the time blend (with kNear
// the nearer real frame) until most fits again
// kBorder (solve, generate) with kSmall: its extra looks stay out of the outer 64 px, where they cost the corners
// for made frames as sharp as the real ones: kCrisp (frame, generate) a sharper resampling kernel; kDetail (frame,
// generate) gives back the fine detail the kernel lost; kMean (frame, generate) with kFallback: no blend where the
// two warps differ in fine detail only
enum { kRelook = 1, kTimeBlend = 2, kFallback = 4, kSmall = 8, kSides = 16, kNear = 32, kStill = 64, kBand = 128, kWhole = 256,
       kBorder = 512, kCrisp = 1024, kDetail = 2048, kMean = 4096 };
bool solve(CVPixelBufferRef prev, CVPixelBufferRef cur, bool full, bool sd, bool motion = true, int how = 0);
bool frame(float t, CVPixelBufferRef dst, int how = 0);
bool frames(const float *t, CVPixelBufferRef const *dst, int n, int how = 0);
double lastGpuMs();   // gpu time of the last frame, for tests
float lastUnfit();    // kWhole: the share of the picture the last solve found unfit, negative while given up (tests)

// figures for the frame log (renderer -frameLog), off unless measure(true): off, nothing below is compiled, run or
// read. a kernel library of its own; solve() and frames() add a pass each and read a small shared buffer back after
// the wait they do anyway. per solve, over the 8x8 cells of the final field (one per 16 full px): vx, vy the median of
// the cells' mean vectors, len the mean of their lengths (full picture px, prev to cur, over the pair), err the mean
// pick cost (luma 0..1 per tap), unfit the share over kWholeOver (what kWhole counts). per frame: fall, the share of
// a sample every 8 full px the fallback blends more than half (w > 0.5 as the mixer has it at that t; without
// kFallback what it would), 1 for a time blend
struct Figures { float vx, vy, len, err, unfit; };
void measure(bool on);  // before start(), or it comes up at the next solve
bool measuring();
bool lastFigures(Figures &f); // of the last solve: false when it searched nothing (no motion, failed, off)
float lastFall(int i = 0);    // of the i-th frame of the last frame()/frames(), -1 not measured

}
