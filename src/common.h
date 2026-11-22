// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <string>

double nowSec();                         // CACurrentMediaTime, host clock in seconds
double sinceStart(double t = 0);         // seconds since launch, now or at host time t
void logOpen(const char *path);          // also write log lines to this file
void logLine(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void makeRealtime(double periodSec);     // time constraint policy for the calling thread
std::string fourcc(uint32_t v);
void tag709(CVPixelBufferRef pb);       // mark a buffer as bt.709, which every source here is

// the chain: which stages run before the interpolator on real frames and which after, on every frame. the order
// inside each part is fixed, so a set of flags says it all. hidden key `chain`, written PRE:POST:
//   PRE   N noise filter, the interpolator gets filtered frames | n noise filter beside it: real frames are shown
//         filtered, the interpolator works on the raw ones | D dither removal | E enhance net (back at source size)
//   POST  D E U S, or SU for sharpening before the upscaler. E takes the upscaler's place
// no key = :DUS, today's order. the stages still follow their own settings (deband, enhance, upscale, sharpen): the
// chain only says where, and leaves out what it does not name
enum { kPreN = 1, kPreNSide = 2, kPreD = 4, kPreE = 8, kPostD = 16, kPostE = 32, kPostU = 64, kPostS = 128, kSharpFirst = 256, kChainSet = 512 };
int chainParse(const char *s, const char **why); // -1 and the reason when refused
std::string chainText(int bits);

// user settings, read from any thread
struct Settings {
    std::atomic<int> levels{0};          // 0 auto, 1 video range, 2 full range
    std::atomic<bool> deband{true};      // dither removal
    std::atomic<int> upscale{1};         // 0 plain (bilinear), 1 metalfx, 2 apple super resolution (metalfx until it is up), 3 edge-aware (fsr 1 easu), 4 edge-aware (sgsr 1)
    std::atomic<int> enhance{0};         // 0 off, n = the nth net in Resources/nets, run on every frame at any window size. takes the upscaler's place
    std::atomic<int> enhanceAt{0};       // where the net sits: 0 after dither removal, 1 before it, 2 after the upscaler (on the picture at window size)
    std::atomic<float> sharpen{0.6f};    // 0 = off
    std::atomic<int> enhanceDown{0};     // how the net's 2x picture is brought down to a smaller window: 0 area (mean), 1 lanczos (keeps more of what the net added)
    std::atomic<bool> frameGen{false};
    std::atomic<bool> early{true};       // early schedule for generated frames, else on the tick
    std::atomic<bool> passthrough{false};// everything off without touching the other settings
    std::atomic<bool> audio{true};
    std::atomic<double> audioTrim{0};    // seconds, positive = later
    std::atomic<int> refresh{1};         // 0 leave the display alone, 1 auto, 2 match source rate
    std::atomic<bool> overlay{false};
    std::atomic<float> genFloor{12};     // early schedule: the least time a generated frame is waited for, ms. lower = sooner on screen with a quick generator, more late frames
    std::atomic<bool> freeze{false};     // the newest real frame stays up, everything done to it still follows the switches. not saved
    std::atomic<int> compare{0};         // 0 off. the original against the result: 1 left | right, 2 above / below, 3 diagonal, 4 side by side, 5 one above the other. every stage: 6 strips of the picture, 7 the same strip of each
    std::atomic<bool> overlayFull{false}; // the overlay lists every switch, not only what runs
    std::atomic<int> colour{0};          // how the picture's colours are handed to macos: 0 bt.709 (exact), 1 srgb (more contrast), 2 the screen's own (unmanaged, most saturated)
    std::atomic<bool> keepRes{false};    // full screen keeps the window's resolution and stretches it, instead of rendering at the screen's
    std::atomic<bool> vsync{true};       // presents wait for the display. off: a few ms sooner, can tear
    std::atomic<bool> srPad{true};       // apple super resolution: mirrored padding around the tiles against ringing at the picture's edges
    std::atomic<bool> netHalf{false};    // enhance nets do the sums of their narrower layers (up to 24 features) in half precision: ~1.2x quicker on 4x8 and 8x24 nets, ~1.05x on 6x16, the picture within a level or two of 255
    // 1080p: apple's interpolator gets frames shrunk to a size it is quicker at, the generated frame is enlarged again. softer the smaller.
    // 0 off, 1 1280x720 (its fast size, ~4 ms instead of ~11; what "on" was while this was a switch, so a saved yes still means it), 2 1344x768, 3 1536x864
    std::atomic<int> genSmall{0};
    std::atomic<int> genDeadline{0};     // early schedule, how long a generated frame is waited for: 0 by the slowest recent one (decaying peak + 2.5 ms, never under genFloor), 1 by the usual (95th percentile of the last 120 + a margin, no floor)
    std::atomic<bool> genLateNext{false};// a generated frame that is not ready when due is still shown when it comes, while a refresh of the screen lies between it and its real frame. else dropped
    std::atomic<bool> gpuAwake{false};   // a tiny job keeps the gpu from clocking down between frames while a net or the second generator is in use. costs power
    std::atomic<int> genModel{0};        // who makes the generated frames: 0 apple's interpolator, 1 the second generator (flyhigh.h) working at 480 lines, 2 at 720. 1 and 2 need the user's files
    std::atomic<int> genStill{0};        // how generated frames take the real frame's pixel where nothing moved: 0 hard limit (as always), 1 soft with dither allowed for, 2 metalgoose's rule, 3 the same with dither allowed for, 4 none (tests only, not in the menu)
    std::atomic<bool> srWithGen{true};   // run apple super resolution next to frame generation too, one after the other: ~9 ms more delay
    std::atomic<bool> denoise{false};    // apple's temporal noise filter on real frames, first in the chain. ~10 ms per frame on the video encoder block
    std::atomic<float> noise{0.5f};      // its strength, 0..1 (hidden). at 1 moving edges keep ~14% of the frame before, at 0.5 ~2%, flat areas come out the same
    // experimental switches, all off = as before
    std::atomic<bool> hudLock{false};     // pixels still for over a second are taken from the real frame in generated ones
    std::atomic<bool> cutTest{false};     // grid + histogram scene cut test with flash rejection, instead of the single mean difference
    std::atomic<bool> repeatTol{false};   // a repeated frame may differ by a few levels (noisy usb cards), instead of exact
    std::atomic<bool> ptsTime{false};     // presents timed from the capture timestamps with a tracked offset, instead of arrival time
    std::atomic<bool> enhanceReal{false}; // the net runs on real frames only, generated ones reuse its stored change where still
    std::atomic<bool> enhanceHold{false}; // what the net adds is held steady over time where the picture is still
    std::atomic<int> look{0};            // tone curve and colour factor before the last pass: 0 off, 1 mild, 2 middle, 3 strong
    std::atomic<bool> superSample{false}; // upscaler runs to twice the window, then an exact area shrink
    std::atomic<int> chain{kPostD | kPostU | kPostS}; // which stages run where (hidden, see chainParse)
    // hud areas (setting hudRects, "x,y,w,h;x,y,w,h"): up to 8 rectangles in parts of the picture that take the real
    // frame's pixels in generated frames. written by the main thread only: the numbers first, then how many
    std::atomic<int> hudN{0};
    std::atomic<float> hudRect[32] = {};
    std::atomic<bool> hudShow{false};     // outline them on the picture
};
static const int kHudMax = 8;
void hudRectsParse(const char *s);       // the setting's text into gSet, what does not read as a rectangle is left out
std::string hudRectsText();
extern Settings gSet;

void settingsLoad();
void settingsSave(const char *key);      // persist one setting after the user changed it

// effective values, passthrough wins
inline bool effDeband() { return gSet.deband && !gSet.passthrough; }
inline int effUpscale() { return gSet.passthrough ? 0 : gSet.upscale.load(); }
inline int effEnhance() { return gSet.passthrough ? 0 : gSet.enhance.load(); }
inline float effSharpen() { return gSet.passthrough ? 0 : gSet.sharpen.load(); }
inline bool effFrameGen() { return gSet.frameGen && !gSet.passthrough; }
// genSmall's sizes, by the setting's number
static const int kGenSmallW[] = {0, 1280, 1344, 1536}, kGenSmallH[] = {0, 720, 768, 864};
// with srWithGen off: super resolution steps aside while frame generation is on (no extra delay that way)
// noise filter: 0 off, kPreN or kPreNSide. a chain names it itself, without one the setting means beside
inline int effNoise() { int c = gSet.chain; return gSet.passthrough ? 0 : c & kChainSet ? c & (kPreN | kPreNSide) : gSet.denoise ? kPreNSide : 0; }
inline bool srYields() { return gSet.upscale == 2 && effFrameGen() && !gSet.srWithGen; }
