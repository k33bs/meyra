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

// any rate (gSet.rate): one pair, a list of positions (0 prev, 1 cur), every frame kept by (pair, position) the moment
// it is made, nearest first in the order asked. the block generator (model 3) makes any position, how as in blocks.h
// (kTimeBlend: a cross-fade, no motion search). apple's and the second generator make 0.5 only, other positions are
// left out. a new request replaces one not yet picked up; the one being made goes on until it is cancelled. gap: the
// pair's content gap in seconds, positions after the first are due that much later per unit of t (see pairMs)
static const int kAtMax = 16;    // positions a request holds: 240 hz on 20 fps needs 9, times 8 in a dip more
void requestAt(CVPixelBufferRef prev, CVPixelBufferRef cur, long pair, const float *t, int n, int how, double gap, bool (^ready)(void) = nil, bool full = false, bool sd = false);
CVPixelBufferRef takeAt(long pair, float t, double graceMs); // the frame nearest t (within 0.02), +1. null: not made, or not by then. older ones go
bool making();                   // any rate: a pair's frames are being made right now (the log, missed refreshes)
bool comingAfter(long pair, float t); // a position of pair past t (by 0.02) is made, waiting or being made: not one replaced, dropped or failed
void dropAt();                   // every frame kept and the request waiting are let go (the path starts over or ends)
double pairMs();                 // from a request to its frames, each against its own slot (made - asked - (t - t0) * gap): 95 of the last 120, 0 before 20

struct Stats { int n = 0; double sumMs = 0, maxMs = 0; int waitN = 0; double waitSum = 0, waitMax = 0; };
Stats takeStats();

// the frame log (blocks::measure on: renderer -frameLog), any rate with the block generator only. every made frame
// carries its pair's figures as an attachment. pair: solves counted since launch, from 1 (the path's own pair numbers
// start over with it, this does not); gapMs: the pair's content gap as asked (requestAt's gap); vx .. unfit as
// blocks::Figures, nan where the solve had none; fall: this frame's
struct Figures { long pair; float gapMs, vx, vy, len, err, unfit, fall; };
bool figuresOf(CVPixelBufferRef pb, Figures &f);
// for the log's "pairs" line: what was solved and made since the last call. gap: the first 64 gaps, ms
struct PairStats { int n = 0, nFig = 0, nGap = 0; float gap[64]; double lenSum = 0, lenMax = 0, vxSum = 0, vySum = 0, errSum = 0, unfitSum = 0;
                   int fallN = 0; double fallSum = 0, fallMax = 0; };
PairStats takePairStats();

}
