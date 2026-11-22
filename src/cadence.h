// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// comparing frames and timing them: tolerant repeats, scene cuts, the capture clock. plain c++ on luma bytes and
// seconds, nothing of the app in here, so the tests can run the same code on files.
// the ideas (a +-3 level band for repeats, grid + histogram for cuts, capture time plus a tracked offset) are
// described in veyra (github.com/Likely7/Veyra-NRVideo); written from the description, none of its code is here
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace cadence {

// luma samples of a frame, whatever its layout
struct Luma {
    const uint8_t *base = nullptr; size_t rb = 0; int step = 1, off = 0, w = 0, h = 0;
    uint8_t at(int x, int y) const { return base[(size_t)y * rb + (size_t)x * step + off]; }
};

// --- tolerant repeats (repeatTol)
// some usb cards do not hand a repeated frame back bit for bit: about 18% of the pixels come a level off, a few
// hundred two. the exact test then calls every frame new and frame generation stops. so: one sample of every 4x4
// pixels at 1080p (130 thousand, the 2048 of the exact test are too few to tell noise from a small change), compared
// with the last NEW frame (against the frame before, a slow change would never add up to anything). new when
//   more than kOverSlack of the samples are over +-kBand levels: something visibly changed, or
//   more than kShiftSlack blocks of 16x16 samples moved their mean by kShift of a level against the whole picture's:
//     a slow pan or a light changing stays inside the band on every pixel, but all of a block's pixels go the same
//     way. card noise and a game's dither go both ways and average out (18% of pixels a level off: sd 0.03 a block).
//     measured against the whole picture's mean so a card that rounds all of a frame one way does not count
//     samples over the band are left out of the means: they are counted already, and one small thing changing
//     by a lot would otherwise shift every block it touches
// both slacks are the exact test's 10 of 2048: a small thing updating at 60 fps must not make every frame look new.
// measured on recorded 30 fps footage: real frames 6095..119336 samples over and 64..473 blocks, repeats 0..1 and 0
static const int kSigW = 480, kSigH = 270, kBand = 3, kBlock = 16;
static const double kSlackShare = 10.0 / 2048;
static const float kShift = 0.25f;
static const int kChangedOver = 8; // a repeat with more samples over the band than this had something small move on it
struct Sig { uint8_t b[kSigW * kSigH]; int w = 0, h = 0; };
inline void sig(const Luma &l, Sig &o) {
    int sx = (l.w + kSigW - 1) / kSigW, sy = (l.h + kSigH - 1) / kSigH;
    o.w = l.w / sx; o.h = l.h / sy;
    for (int y = 0; y < o.h; y++) {
        const uint8_t *r = l.base + (size_t)(y * sy + sy / 2) * l.rb + (size_t)(sx / 2) * l.step + l.off;
        uint8_t *d = o.b + y * o.w;
        for (int x = 0, st = sx * l.step; x < o.w; x++) d[x] = r[(size_t)x * st];
    }
}
struct SigDiff { int over = 0, blocks = 0, n = 0; float shift = 0; bool same = false, changed = false; };
inline SigDiff sigDiff(const Sig &a, const Sig &b) {
    SigDiff d;
    if (a.w != b.w || a.h != b.h || !a.w) return d;
    int bw = (a.w + kBlock - 1) / kBlock, bh = (a.h + kBlock - 1) / kBlock;
    int sum[(kSigW / kBlock + 1) * (kSigH / kBlock + 1)] = {0};
    long total = 0;
    for (int y = 0; y < a.h; y++) {
        const uint8_t *pa = a.b + y * a.w, *pb = b.b + y * a.w;
        int *row = sum + (y / kBlock) * bw;
        for (int bx = 0; bx < bw; bx++) {
            int x1 = bx * kBlock + kBlock < a.w ? bx * kBlock + kBlock : a.w, s = 0, o = 0;
            for (int x = bx * kBlock; x < x1; x++) { int v = pa[x] - pb[x], big = abs(v) > kBand; s += big ? 0 : v; o += big; }
            row[bx] += s; d.over += o;
        }
    }
    d.n = a.w * a.h;
    for (int i = 0; i < bw * bh; i++) total += sum[i];
    float mean = (float)total / d.n;
    for (int by = 0; by < bh; by++)
        for (int bx = 0; bx < bw; bx++) {
            int cw = (bx + 1) * kBlock <= a.w ? kBlock : a.w - bx * kBlock, chh = (by + 1) * kBlock <= a.h ? kBlock : a.h - by * kBlock;
            if (cw * chh < kBlock * kBlock / 2) continue; // a sliver at the edge is too few samples to average noise out
            float s = fabsf((float)sum[by * bw + bx] / (cw * chh) - mean);
            if (s > d.shift) d.shift = s;
            d.blocks += s > kShift;
        }
    int shiftSlack = (int)(bw * bh * kSlackShare);
    d.same = d.over <= (int)(d.n * kSlackShare) && d.blocks <= shiftSlack;
    d.changed = d.same && (d.over > kChangedOver || d.blocks > 0);
    return d;
}

// --- scene cuts (cutTest)
// a coarse picture of the frame: 64x36 cells, each the mean of 4x4 samples spread over it, and a histogram of those
// samples in 64 steps
static const int kGw = 64, kGh = 36, kBins = 64;
struct Grid { uint8_t g[kGw * kGh]; int hist[kBins]; float mean = 0; bool ok = false; };
inline void grid(const Luma &l, Grid &o) {
    memset(o.hist, 0, sizeof o.hist);
    long tot = 0;
    for (int cy = 0; cy < kGh; cy++)
        for (int cx = 0; cx < kGw; cx++) {
            int s = 0;
            for (int j = 0; j < 4; j++) {
                int y = (int)(((long)(cy * 4 + j) * 2 + 1) * l.h / (kGh * 8));
                for (int i = 0; i < 4; i++) {
                    int v = l.at((int)(((long)(cx * 4 + i) * 2 + 1) * l.w / (kGw * 8)), y);
                    s += v; o.hist[v >> 2]++;
                }
            }
            o.g[cy * kGw + cx] = (uint8_t)((s + 8) >> 4);
            tot += s;
        }
    o.mean = tot / (float)(kGw * kGh * 16);
    o.ok = true;
}
// sad: mean difference of the cells, 0..1. hist: share of the samples that sit in other histogram steps, 0..1.
// lift: change of the mean, in levels. corr: how alike the two coarse pictures are once each one's own brightness
// and contrast are taken out (1 the same picture, 0 unrelated; 0 too when either is flat)
struct Pair { float sad = 0, hist = 0, lift = 0, corr = 0; };
inline Pair compare(const Grid &a, const Grid &b) {
    Pair p;
    long sad = 0, hd = 0;
    double saa = 0, sbb = 0, sab = 0;
    for (int i = 0; i < kGw * kGh; i++) {
        sad += abs(a.g[i] - b.g[i]);
        double x = a.g[i] - a.mean, y = b.g[i] - b.mean;
        saa += x * x; sbb += y * y; sab += x * y;
    }
    for (int i = 0; i < kBins; i++) hd += labs((long)a.hist[i] - b.hist[i]);
    p.sad = sad / (255.0f * kGw * kGh);
    p.hist = hd / (2.0f * kGw * kGh * 16);
    p.lift = b.mean - a.mean;
    double var = kGw * kGh * 4.0; // a cell sd of 2 levels: below that the picture is flat and there is nothing to match
    p.corr = saa > var && sbb > var ? (float)(sab / sqrt(saa * sbb)) : 0;
    return p;
}
// what a pair of real frames is. cut: no frame is generated across it. flash: looks like one, is not
enum { kPairSame = 0, kPairCut = 1, kPairFlash = 2 };
// a cut: the coarse pictures differ and are not the same picture any more.
// kCutSad/kCutHist: cells and histogram both far apart. kCutSad2/kCutCorr: cells apart and nothing lines up.
// a flash (lightning, a muzzle flash, a white-out) is a jump in brightness that comes back a frame later. the frame
// after is not there yet when the pair has to be decided, so, without waiting for it:
//   the jump: the picture got brighter or darker by kFlashLift levels and is still the same picture underneath
//     (corr over kFlashCorr): not a cut. a white-out that leaves nothing underneath does count as one
//   the return: the frame after a jump or a cut matches the one before it (`before`, kept by the caller): not a cut,
//     whatever the frame in between was
// set on 36 thousand pairs of game footage with 14 cuts found by eye: cuts had sad 0.10..0.37 with hist 0.12..0.99, or
// corr below 0.34; fast motion inside a shot reached sad 0.13 but hist 0.09 and corr 0.60 at worst; fades in from
// black had corr over 0.98
static const float kCutSad = 0.10f, kCutHist = 0.12f, kCutSad2 = 0.06f, kCutCorr = 0.45f;
static const float kFlashLift = 12, kFlashCorr = 0.9f, kBackSad = 0.03f;
struct CutState { Grid before; bool jumped = false; }; // the frame before the last jump, while the frame after it is still to come
inline int classify(const Grid &a, const Grid &b, CutState &st, Pair *out = nullptr) {
    Pair p = compare(a, b);
    if (out) *out = p;
    bool differs = (p.sad > kCutSad && p.hist > kCutHist) || (p.sad > kCutSad2 && p.corr < kCutCorr);
    bool jump = fabsf(p.lift) > kFlashLift && p.corr > kFlashCorr;
    if (st.jumped) {
        st.jumped = false;
        if ((differs || jump) && compare(st.before, b).sad < kBackSad) return kPairFlash; // back where it was
    }
    if (differs || jump) { st.before = a; st.jumped = true; }
    return differs && !jump ? kPairCut : jump ? kPairFlash : kPairSame;
}

// --- the capture clock (ptsTime)
// when a frame "really" arrived: its capture timestamp plus the offset between the capture clock and ours, instead of
// the moment the callback happened to run. the offset is the mean of the first kClockMean samples, then a slow
// second-order loop (follows a drifting clock without lag). a sample further off than a third of a frame (8 ms at
// most) is ignored once; a second one in a row on the same side is believed and the line moves there.
// margin: frames must not be scheduled before they are here, so the time handed out is later than the line by twice
// the mean deviation (all of an even jitter), at most the same limit. a clean source gets next to none
static const int kClockMean = 10;
static const double kClockGain = 0.1, kClockDrift = 0.0025, kClockLim = 0.008;
struct PtsClock {
    int n = 0, side = 0;
    double off = 0, drift = 0, lastPts = 0, jit = 0;
    int ignored = 0, moved = 0, resets = 0;
    void reset() { n = side = 0; off = drift = jit = 0; }
    // pts on the capture clock, arrival on ours, dur: the source's frame time. all seconds. returns the time to plan from
    double feed(double pts, double arrival, double dur) {
        double dp = pts - lastPts, s = arrival - pts, lim = fmin(dur / 3, kClockLim);
        if (n && (dp <= 0 || dp > 0.25)) { reset(); resets++; } // the timestamps jumped: a new stream
        lastPts = pts;
        if (n < kClockMean) { off += (s - off) / ++n; return pts + off; }
        double want = off + drift * (dp / dur), e = s - want; // drift is per frame; a dropped frame is two
        int sd = e > 0 ? 1 : -1;
        if (fabs(e) > lim && side != sd) { side = sd; ignored++; off = want; return pts + off + margin(lim); }
        if (fabs(e) > lim) { off = s; drift = 0; side = 0; moved++; return pts + off + margin(lim); }
        side = 0;
        off = want + kClockGain * e;
        drift += kClockDrift * e;
        jit += (fabs(e) - jit) * 0.05;
        return pts + off + margin(lim);
    }
    double margin(double lim) const { return fmin(2 * jit, lim); }
};

}
