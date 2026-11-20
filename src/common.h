// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <string>

double nowSec();                         // CACurrentMediaTime, host clock in seconds
void logOpen(const char *path);          // also write log lines to this file
void logLine(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void makeRealtime(double periodSec);     // time constraint policy for the calling thread
std::string fourcc(uint32_t v);
void tag709(CVPixelBufferRef pb);       // mark a buffer as bt.709, which every source here is

// user settings, read from any thread
struct Settings {
    std::atomic<int> levels{0};          // 0 auto, 1 video range, 2 full range
    std::atomic<bool> deband{true};      // dither removal
    std::atomic<int> upscale{1};         // 0 plain (bilinear), 1 metalfx
    std::atomic<float> sharpen{0.6f};    // 0 = off
    std::atomic<bool> frameGen{false};
    std::atomic<bool> early{true};       // early schedule for generated frames, else on the tick
    std::atomic<bool> passthrough{false};// everything off without touching the other settings
    std::atomic<bool> audio{true};
    std::atomic<double> audioTrim{0};    // seconds, positive = later
    std::atomic<int> refresh{1};         // 0 leave the display alone, 1 auto, 2 match source rate
    std::atomic<bool> overlay{false};
};
extern Settings gSet;

void settingsLoad();
void settingsSave(const char *key);      // persist one setting after the user changed it

// effective values, passthrough wins
inline bool effDeband() { return gSet.deband && !gSet.passthrough; }
inline int effUpscale() { return gSet.passthrough ? 0 : gSet.upscale.load(); }
inline float effSharpen() { return gSet.passthrough ? 0 : gSet.sharpen.load(); }
inline bool effFrameGen() { return gSet.frameGen && !gSet.passthrough; }
