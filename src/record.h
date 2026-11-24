// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

// what is on screen -> the hardware hevc encoder -> a .mov in ~/Movies/meyra, with the sound as it is played.
// the render thread only copies the drawn picture on the gpu and never waits: when the encoder or the disk fall
// behind, the file loses a frame, the screen does not.
// two ways: a recording from start to stop, or the last seconds held in memory (encoded) and written when asked.
namespace record {

void init(id<MTLDevice> dev, void (^say)(NSString *)); // main thread, once. say: a hint line, called on the main thread

// main thread
void toggle();          // start / stop a recording. ends keeping
void keep(bool on);     // hold the last seconds (default recKeepSeconds, 30). ends a recording
void save();            // write what is held to a file. keeping goes on
void finish();          // at quit: close the file. waits for it
int state();            // 0 idle, 1 keeping the last seconds, 2 recording
void overlay(bool on);  // the overlay and hint lines are part of the file
void limit(int maxH);   // the file is at most this high, 0: as shown. also: the bitrate (default recMbit) is read again
void colour(bool srgb);  // the window is shown as srgb (or left to the screen), not as bt.709
NSString *folder();

// render thread
bool withOverlay();
void copy(id<MTLCommandBuffer> cb, id<CAMetalDrawable> dr, int x, int y, int w, int h); // the picture's rectangle, before the commit
id<MTLTexture> light(); // the mark for the corner, nil when idle. drawn after copy(), so never in the file
id<MTLTexture> counter(double scale); // how long the recording has run, left of the mark. scale: screen pixels a point. nil when not recording

// audio output thread: what goes to the device, interleaved stereo float at 48 khz. t: host time it is heard at
void sound(const float *s, unsigned frames, double t);

}
