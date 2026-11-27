// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import "letterbox.h"
#include <algorithm>
#include <cstdlib>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// the bands. looking: rows of black from the top and from the bottom (a row is black with at most a 128th of it above
// black + 6), both at least 4 % of the height, within a few rows of each other, the picture between them 1.9 to 2.8
// wide, its first two rows at each edge well lit and a sixteenth of it well above black: a dark scene or a fade never
// is. the same rows (2 either way) held for 1 s, and nothing at all in the bands, to the pixel, by the test that lets
// go (every 4th call while held, and on the call it would crop): so it never crops on what it would drop the next
// frame. a let go, or bands held half a second and lost, counts: each inside 10 s of the last doubles the hold (3 s,
// 6 s, then 8 s), 10 s without one and it is back to 1 s. a game that boxes some shots only stops pumping.
// cropped: every pixel of both bands, every frame, but the 2 rows next to the picture (a soft edge from scaling). 4 in
// a line, across or down, above black + 10, or more such pixels than noise makes, or a row a 64th above black + 6 (a
// dim picture come back), and it lets go in that frame. a dark moment inside the picture keeps the crop: only the
// bands are looked at. anything under 4 pixels both ways is noise. neon for rows of 2vuy or 420v luma, a plain loop
// for the rest of a row and any other step
namespace letterbox {

static const int kDark = 6;     // a black pixel: black + 6 and below (capture noise, undershoot below black is black too)
static const int kLit = 10;     // cropped, a band pixel above black + 10 is something
static const int kRun = 4;      // lit in a line, across or down, before it counts: a hot pixel, or two, never does
static const int kBright = 24;  // the picture: a sixteenth of it above black + 24
static const int kSlack = 2;    // rows next to the picture's edge not looked at
static const int kWobble = 2;   // rows the bands may move while held
static const double kHolds[] = {1, 3, 6, 8}, kRecent = 10, kLost = 0.5, kGap = 0.5; // seconds

static size_t gW, gH, gStep;
static bool gOn;
static Band gBand;
static double gSince = -1, gLast = -1, gLetGo = -1e9; // hold started, last call, last let go
static int gLets;                                    // let goes, each inside kRecent of the last
static unsigned gTick;                               // calls since the hold began: the band scan every 4th
static int gTop, gBot, gMinTop, gMinBot;             // rows of black, top and bottom: as the hold began, the least since

static inline int clampLuma(int v) { return std::min(std::max(v, 0), 254); }
static inline bool above(const Plane &y, size_t x, size_t r, int lim) { return y.p[r * y.stride + x * y.step] > lim; }

#if defined(__ARM_NEON)
// lim in every lane; 2vuy: 255 in the chroma lanes between, never above
static inline uint8x16_t lims(int lim, size_t sb) {
    static const uint8_t c[16] = {0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255};
    uint8x16_t l = vdupq_n_u8((uint8_t)lim);
    return sb == 2 ? vorrq_u8(l, vld1q_u8(c)) : l;
}
static inline bool any(uint8x16_t m) { return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(m), 4)), 0) != 0; }
// N pixels from q: the lanes above l, or'd, back; the lanes above d counted into c (a lane takes N * S / 16 at most).
// two of each in turn, not one long chain
template <size_t S, size_t N> static inline uint8x16_t block(const uint8_t *q, uint8x16_t l, uint8x16_t d, uint8x16_t &c) {
    uint8x16_t m[2] = {vdupq_n_u8(0), vdupq_n_u8(0)}, s[2] = {vdupq_n_u8(0), vdupq_n_u8(0)};
    for (size_t j = 0; j < N * S / 16; j++) {
        uint8x16_t v = vld1q_u8(q + 16 * j);
        m[j & 1] = vorrq_u8(m[j & 1], vcgtq_u8(v, l));
        s[j & 1] = vaddq_u8(s[j & 1], vcgtq_u8(v, d));
    }
    c = vsubq_u8(c, vaddq_u8(s[0], s[1]));
    return vorrq_u8(m[0], m[1]);
}
// N pixels from q: any above d? the most of them, one compare: a black block costs a load and a max a vector
template <size_t S, size_t N> static inline bool over(const uint8_t *q, uint8x16_t d) {
    uint8x16_t m[2] = {vdupq_n_u8(0), vdupq_n_u8(0)};
    for (size_t j = 0; j < N * S / 16; j++) m[j & 1] = vmaxq_u8(m[j & 1], vld1q_u8(q + 16 * j));
    return any(vcgtq_u8(vmaxq_u8(m[0], m[1]), d));
}
#endif

// row r: its pixels above dark counted, until past most, and lit(x) for each one above lim: true from it ends the row,
// kFound back. S: bytes a pixel, 0 for y.step and no neon. 64 pixels at a time, then 16: counted only when one is
// above dark, looked at one by one only when one is above lim. the vector passes stop short of the row's last luma
// byte: nothing past it is read, the bottom band ends at the buffer's end
static const size_t kFound = SIZE_MAX;
template <size_t S, class F> static size_t scan(const Plane &y, size_t r, int dark, int lim, size_t most, F &&lit) {
    const uint8_t *row = y.p + r * y.stride;
    const size_t w = y.w, st = S ? S : y.step;
    size_t n = 0, x = 0;
#if defined(__ARM_NEON)
    if constexpr (S == 1 || S == 2) {
        const uint8x16_t l = lims(lim, S), d = lims(dark, S);
        uint8x16_t c = vdupq_n_u8(0);
        for (int k = 0; x + 63 + S <= w; x += 64) {
            if (!over<S, 64>(row + x * S, d)) continue;
            if (any(block<S, 64>(row + x * S, l, d, c)))
                for (size_t i = x; i < x + 64; i++)
                    if (row[i * S] > lim && lit(i)) return kFound;
            if (++k == 30) { // a lane takes at most 240 before it is summed, 6 more below
                n += vaddlvq_u8(c), c = vdupq_n_u8(0), k = 0;
                if (n > most) return n;
            }
        }
        for (; x + 15 + S <= w; x += 16)
            if (over<S, 16>(row + x * S, d) && any(block<S, 16>(row + x * S, l, d, c)))
                for (size_t i = x; i < x + 16; i++)
                    if (row[i * S] > lim && lit(i)) return kFound;
        n += vaddlvq_u8(c);
    }
#endif
    for (; x < w; x++) {
        n += row[x * st] > dark;
        if (row[x * st] > lim && lit(x)) return kFound;
    }
    return n;
}
// pixels of row r above lim, until past most
static size_t count(const Plane &y, size_t r, int lim, size_t most) {
    auto no = [](size_t) { return false; };
    return y.step == 2 ? scan<2>(y, r, lim, 255, most, no) : y.step == 1 ? scan<1>(y, r, lim, 255, most, no) : scan<0>(y, r, lim, 255, most, no);
}

// a lit pixel at x, r: part of kRun in a line, across, or down within rows [r0, r1)?
static bool line(const Plane &y, size_t x, size_t r, size_t r0, size_t r1, int lim) {
    int a = 1;
    for (size_t i = x; i > 0 && a < kRun && above(y, i - 1, r, lim); i--) a++;
    for (size_t i = x + 1; i < y.w && a < kRun && above(y, i, r, lim); i++) a++;
    if (a >= kRun) return true;
    a = 1;
    for (size_t i = r; i > r0 && a < kRun && above(y, x, i - 1, lim); i--) a++;
    for (size_t i = r + 1; i < r1 && a < kRun && above(y, x, i, lim); i++) a++;
    return a >= kRun;
}

// something in rows [r0, r1): a row with more than tol above dark (a dim picture, that the looking would not call
// black either), a lit line, or more lit pixels than noise. both from the same loads; the first found ends it
template <size_t S> static bool seen(const Plane &y, size_t r0, size_t r1, int dark, size_t tol, int lim, size_t &hits, size_t most) {
    for (size_t r = r0; r < r1; r++) {
        size_t n = scan<S>(y, r, dark, lim, tol, [&](size_t x) { return ++hits > most || line(y, x, r, r0, r1, lim); });
        if (n == kFound || n > tol) return true;
    }
    return false;
}

// the bands of a crop, rows [0, a) and [b, h), hold nothing. the bottom one first: subtitles and prompts go there.
// a row may hold twice what the looking lets a black row hold
static bool clear(const Plane &y, long a, long b, int dark, int lim) {
    size_t top = (size_t)std::max(a, 0L), bot = (size_t)std::min(std::max(b, 0L), (long)y.h);
    size_t hits = 0, most = (top + (y.h - bot)) * y.w / 256, tol = y.w / 64; // hot pixels: a 256th of the bands
    auto s = y.step == 2 ? seen<2> : y.step == 1 ? seen<1> : seen<0>;
    return !s(y, bot, y.h, dark, tol, lim, hits, most) && !s(y, 0, top, dark, tol, lim, hits, most);
}

// rows of black from one end, at most cap
static int run(const Plane &y, bool fromBottom, int cap, int lim, size_t tol) {
    int n = 0;
    while (n < cap && count(y, fromBottom ? y.h - 1 - n : n, lim, tol) <= tol) n++;
    return n;
}

// the rows between hold a picture: a sixteenth of a sparse grid of it well above black
static bool picture(const Plane &y, int top, int bottom, int lim) {
    size_t n = 0, up = 0;
    for (int r = top + 4; r < bottom; r += 16)
        for (size_t x = 4; x < y.w; x += 8) n++, up += above(y, x, r, lim);
    return n && up * 16 >= n;
}

static void letGo(double t) {
    gLets = t - gLetGo < kRecent ? gLets + 1 : 1;
    gLetGo = t;
}

void reset() {
    gW = gH = gStep = 0;
    gOn = false;
    gBand = {0, 0};
    gSince = gLast = -1;
    gLetGo = -1e9;
    gLets = 0;
    gTick = 0;
}

void seen(double t) {
    if (gLast >= 0 && t > gLast) gLast = t;
}

Band look(const Plane &y, double t, int black) {
    const Band all = {0, (int)y.h};
    if (!y.p || y.w < 64 || y.h < 64 || !y.step) return all;
    if (y.w != gW || y.h != gH || y.step != gStep) {
        reset();
        gW = y.w, gH = y.h, gStep = y.step;
    }
    if (gLast >= 0 && (t < gLast || t - gLast > kGap)) gOn = false, gSince = -1; // a pause (no signal) or the clock went back: no crop, the hold starts over
    gLast = t;
    const int h = (int)y.h, dark = clampLuma(black + kDark), lit = clampLuma(black + kLit);
    if (gOn) {
        if (clear(y, gBand.top - kSlack, gBand.bottom + kSlack, dark, lit)) return gBand;
        gOn = false, gSince = -1;
        letGo(t);
        return all;
    }
    auto drop = [&] { // bands held a while and gone count as a let go
        if (gSince >= 0 && t - gSince >= kLost) letGo(t);
        gSince = -1;
        return all;
    };
    const size_t tol = y.w / 128;
    const int cap = h / 3, least = (h * 4 + 99) / 100;
    int top = run(y, false, cap, dark, tol);
    if (top < least || top >= cap) return drop(); // a picture to the top (most frames end here, on row 0), or all black
    int bot = run(y, true, cap, dark, tol);
    if (bot < least || bot >= cap || std::abs(top - bot) > std::max(4, h / 160)) return drop();
    double wide = (double)y.w / (h - top - bot);
    if (wide < 1.9 || wide > 2.8) return drop();
    for (int r : {top, top + 1, h - bot - 1, h - bot - 2}) // a sharp edge, not a dark scene fading out
        if (count(y, r, dark, y.w / 4) <= y.w / 4) return drop();
    if (!picture(y, top, h - bot, clampLuma(black + kBright))) return drop();
    if (gSince < 0 || std::abs(top - gTop) > kWobble || std::abs(bot - gBot) > kWobble) {
        if (gSince >= 0 && t - gSince >= kLost) letGo(t);
        gSince = t;
        gTick = 0;
        gTop = gMinTop = top;
        gBot = gMinBot = bot;
    } else {
        gMinTop = std::min(gMinTop, top);
        gMinBot = std::min(gMinBot, bot);
    }
    if (t - gLetGo >= kRecent) gLets = 0;
    bool due = t - gSince >= kHolds[std::min(gLets, 3)];
    if (((gTick++ & 3) == 0 || due) && !clear(y, gMinTop - kSlack, h - gMinBot + kSlack, dark, lit)) return drop();
    if (!due) return all;
    gOn = true;
    gBand = {gMinTop, h - gMinBot};
    return gBand;
}

}
