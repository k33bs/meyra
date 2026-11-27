// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// system capture: is the device running what was asked, and is a low frame rate the signal's own. plain functions,
// no apple types, so they can be tried on their own
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace capcheck {

// a format as asked or as read back. 0 = unknown, never counted as a difference
struct Fmt { int w = 0, h = 0; uint32_t cc = 0; double minDur = 0, maxDur = 0; };

enum { kSize = 1, kLayout = 2, kRate = 4, kMaxDur = 8 };

// frame durations as seconds: 1/60, 1000/60000 and 60000/3600000 are the same, 1001/60000 is not
inline bool sameDur(double a, double b) { return a <= 0 || b <= 0 || std::fabs(a - b) <= 1e-4 * b; }

// what differs. kMaxDur alone is only logged: cameras keep their own lowest rate and still run what was asked
inline int differs(const Fmt &asked, const Fmt &now) {
    int d = 0;
    if (asked.w && now.w && (asked.w != now.w || asked.h != now.h)) d |= kSize;
    if (asked.cc && now.cc && asked.cc != now.cc) d |= kLayout;
    if (!sameDur(asked.minDur, now.minDur)) d |= kRate;
    if (!sameDur(asked.maxDur, now.maxDur)) d |= kMaxDur;
    return d;
}
inline bool runsOther(int d) { return d & (kSize | kLayout | kRate); }

// rates a source sends on its own: film, pal, ntsc, half of them
inline bool signalRate(double fps) {
    for (double r : {23.976, 24.0, 25.0, 29.97, 30.0, 47.952, 48.0, 50.0})
        if (std::fabs(fps - r) <= 0.005 * r) return true;
    return false;
}

// steps between the device's own timestamps in a second, sorted
struct Steps { int n = 0; double mean = 0, med = 0, lo = 0, hi = 0, min = 0, max = 0; }; // lo / hi: 10th and 90th percentile
inline Steps steps(std::vector<double> v) {
    Steps s;
    if (v.empty()) return s;
    std::sort(v.begin(), v.end());
    s.n = (int)v.size();
    for (double x : v) s.mean += x;
    s.mean /= s.n;
    s.med = v[v.size() / 2];
    s.lo = v[v.size() / 10];
    s.hi = v[v.size() * 9 / 10];
    s.min = v.front();
    s.max = v.back();
    return s;
}

// fewer frames than the format's rate, evenly spaced at a rate a source sends (24/25/30 into a 60 format, a camera in
// low light): the signal's own rate, not frames lost on the way. an even 20 of 60 is not one
inline bool evenSignalRate(const Steps &s, double formatFps) {
    if (s.n < 8 || s.med <= 0 || s.mean <= 0 || formatFps <= 0) return false;
    double fps = 1 / s.mean; // the mean: a median of jittered steps lands on one side
    if (fps >= 0.9 * formatFps || !signalRate(fps)) return false;
    return s.hi < 1.25 * s.med && s.lo > 0.75 * s.med;
}

}
