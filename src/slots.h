// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// which picture goes up on which output slot. plain c++ on ids and seconds, nothing of the app in here, no clock read,
// nothing allocated, so the test tool runs the same code on hold lists.
// the one rule: a slot at time T shows content time T - d. that lands on a picture (or within snap of one: the picture
// goes up), between two (a mix at phase t) or past the newest one known (hold it). never a mix across a cut.
// d is the governor's: a picture has to be in, and its in-betweens made, before the first slot that needs it:
//   d >= (when the newer picture is known) + budget - (content time of the first slot that needs it)
// where slots land on pictures that is gap - period + processing. anywhere else the first slot of a gap
// can sit just past the older picture, and it is nearly a whole gap. d rises at once when a picture turns out later
// than d covers (costs the slots that held), and falls slowly towards what the last second or so needed.
// a change of d counts from the gap whose phases are handed out next: phases already handed out stay what they were.
// the planner follows methods described for two other frame generators, both gpl-3.0: macframegen
// (github.com/PabloVSouza/MacFrameGen: a count of in-betweens that follows the gap between real frames, and a delay of
// about one gap less one output period plus the time to make the frames) and metalgoose
// (github.com/Stallion77RepoOfficial/MetalGoose: sample the capture timeline at each refresh's own time minus a delay, a
// delay that rises at once and falls back at 5 % of real time, their number, see Params::fall). written from a study
// that read macframegen's source and parts of metalgoose's; the planner is meyra's own, no code of either is included.
// see THIRD_PARTY_NOTICES.md
#pragma once
#include <algorithm>
#include <cmath>

namespace slots {

enum Kind { Real, Mix, Hold };
// Grid: the caller's slot times (signal ticks, refreshes). Rate: our own, num a second. Times: num - 1 even phases in
// every gap. TimesGap: as many as the gap is long, num a usual gap. Source: every picture once at its own time + d
enum Mode { Grid, Rate, Times, TimesGap, Source };
enum Why { kStart, kRise, kFall, kFast, kPause, kDrift };
static const char *const kWhy[] = {"start", "rise", "fall", "fast", "pause", "drift"};

// what goes up at `at`. Real: picture a. Mix: a and b at phase t. Hold: a again, b is not in (or not made) yet.
// content: the content time shown (the picture's own for Real and Hold)
struct Slot { int kind = Hold; long a = -1, b = -1; double t = 0, content = 0, at = 0; };

struct Params {
    int mode = Grid;
    double num = 0;                // Grid: refresh rate if known (0: measured), Rate: slots a second, Times*: m
    double budget = 0.006;         // making a pair's in-betweens. the caller keeps it current
    double floor = 0.003;          // least delay besides the budget: the caller's own work before picture()
    double dmax = 0.1;             // longer waits hold instead
    double fall = 0.05, fast = 0.5; // d given back at this share of real time (fall: metalgoose's 5 %). fast: while one-tick gaps dominate
    double cushion = 0;            // delay held on purpose over the need (rateCushion: one to three ticks): a game frame that
                                   // comes that much late (a dropped frame at 30 fps) is still in time, no hold, no rise
    int fastWin = 8;               // the fast fall looks at this many gaps (3/4 of them one tick). 20 (rateFastWin): a game
                                   // that drops a frame now and then at 60 holds about as often as with d a period up
                                   // (13 against 22 a minute on a live trace) at +0.3 ms, 0.2 s slower back to 60
    double snap = 0.1;             // within this share of a gap of a picture: the picture. 0: off (still 0.5 %:
                                   // measured refresh times never land on a picture exactly)
    double pause = 0.25;           // a longer gap is a pause: start over
    double win = 1.5, pct = 0.9;   // the fall aims at this percentile of what the last win seconds needed
    double tick = 1001.0 / 60000;  // the signal's frame time: a gap up to 1.5 of it is "one tick"
    double space = 0;              // Times*: slots no closer than this (the screen's refresh), fewer in a short gap. 0: any
    bool align = true;             // Grid, Rate: d only where slots land on pictures (a whole ratio shows real ones),
                                   // costs up to a period of delay. off: least delay, phases wherever they fall
    bool ticks = true;             // content gaps are whole signal ticks: "whole" is judged on the median gap snapped to
                                   // them, so arrival jitter does not count. off (rateEven, 24 / 25p): the mean gap as it is
    bool level = false;            // content times from a Clock (rateEvenLate): picture()'s lag, see netNeed
};

// rateEvenLate: a game that advances its picture a fixed step per frame whatever the frame's gap (house3: a 50 ms pair
// moves 1.01x a usual one, the pair after 1.00x). by arrival a 50 ms pair plays at 0.67x for three refreshes, a rattle
// on near detail while panning. here each picture is one step after the one before, and the step is how fast the
// content plays: the game's mean gap (2 s) and a pull on the level (content this far behind arrival) of 1/tau. two
// 0.1 s poles on the step: no speed step on the glass. a late frame is a 16.7 ms rise of the level, taken back over
// about tau; the planner's cushion is the room it moves in (Planner::picture's lag): the level stays under it, a frame
// that would take it past goes the rest by arrival (a step of up to a tick more, once), never a hold. gaps not one
// frame (under 0.75 or from 1.75 usual gaps: a miss, a freeze, 60 -> 30) go by arrival with the level kept; a pause or
// another usual gap starts it over. room 0 (no cushion): content is arrival. plain c++ as the planner, the test tool
// runs the same
struct Clock {
    double tick = 1001.0 / 60000, pause = 0.25, room = 0; // room: the cushion
    double tau = 0.3, pole = 0.1, mean = 2; // s: the level's pull, each of the step's two poles, the mean gap's window
    double aim = -1;               // the level aimed at: content this far behind arrival. -1: half a tick ahead, room for a
                                   // burst of late frames (6 a second at 30 fps is 100 ms a second); 0 held a slot 1-3 times
                                   // a minute on the house runs, a whole tick only cost delay
    double g[64]; long ng = 0;     // the last arrival gaps
    double w = 0, c = 0, P = 0, R = 0, s1 = 0, s = 0, lag = 0; // last arrival, its content time, the usual gap, the
                                   // mean, the poles (s: the step now), the level (arrival - content)
    long n = 0, byCount = 0, byArrival = 0, starts = 0, capped = 0;
    double usual() const {
        long k = std::min(ng, 64L);
        if (k < 8) return 0;
        double v[64]; for (long i = 0; i < k; i++) v[i] = g[i];
        std::nth_element(v, v + k / 2, v + k);
        return std::max(1.0, std::round(v[k / 2] / tick)) * tick; // snapped to ticks, as the planner's
    }
    // content time for a picture that came at `at` (the capture clock)
    double time(double at) {
        const double a = aim <= -1 ? -tick / 2 : aim;
        double gp = at - w, prev = c;
        if (room <= 0) { w = at; n++; lag = 0; return c = at; }
        if (!n || gp > pause) { // the first, or after a pause: the level where it aims
            c = at - a; lag = a; starts++;
            if (n) c = std::max(c, prev + 1e-4);
            s1 = s = R = P = usual();
        } else {
            g[ng++ % 64] = gp;
            double u = usual();
            if (u > 0 && std::fabs(u - P) > tick / 2) { P = u; s1 = s = R = u; } // another cadence: its own step
            if (P > 0 && gp > 0.75 * P && gp < 1.75 * P) { // one frame, maybe late: one step
                c += s; byCount++;
                if (at - c > 0.9 * room) { c = at - 0.9 * room; capped++; } // past the cushion: the rest by arrival (0.9: a
                // need a hair over the window's, arrival jitter or a longer step, held a slot at the edge)
                else if (at - c < a - room - tick) c = at - (a - room - tick); // (ahead: the delay bounded too)
                lag = at - c;
                R += (gp - R) * std::min(1.0, P / mean); // the game's mean gap, per frame (a gap-weighted one sat 4 % long at 25p)
                double want = std::min(1.5 * P, std::max(0.8 * P, R + P * (lag - a) / tau)), k = std::min(1.0, P / pole);
                s1 += (want - s1) * k; s += (s1 - s) * k;
            } else { c += gp; byArrival++; lag = at - c; } // by arrival: the level as it was
        }
        w = at; n++;
        return c;
    }
};

struct Planner {
    Params p;
    double d = 0;                  // the delay now, and why it last changed: for the overlay
    int why = kStart;
    int rises = 0, held = 0, late = 0, dups = 0, pauses = 0;
    int steps = 0;                 // Rate: our own slots moved under a quarter period (a shift, given back, landed): not a rise
    long thinned = 0;              // gaps given fewer slots than asked: the screen could not take them (space)

    struct Pic { long id; double t, known; bool cut; int n; }; // n: slots in the gap before it (self-timed modes)
    struct Gap { double at, g, need, net; }; // net: the need as the cushion sees it (a level netted, see cushioned)
    struct Seg { double c, d; };   // from content time c on, d
    static const int kPics = 32, kHist = 128, kSegs = 32;
    Pic pic[kPics]; long np = 0;
    Gap hist[kHist]; long nh = 0;
    Seg seg[kSegs]; long ns = 0;
    double ref = 0;                // a d whose slots land on pictures (align): d keeps to ref + n periods
    double A = 0;                  // Rate: where its slots start
    double gp = 0, lastT = -1e300, lastC = -1e300, lastK = 0;
    bool anchor = true;
    bool back = false;             // the anchor is the lattice coming back, not the caller's grid moving
    bool whole = true;             // the usual gap is a whole number of periods (or a period a whole number of gaps)
    double shifted = 0;            // Rate: how much later our own slots went for a need a little over the lattice
    double peak = 0, peakAt = 0, beat = 0, usual = 0, lgap = 0, rideAt = -1e300, stand = 0; // not whole: the most need of a phase cycle at the usual gap, when,
                                   // the cycle's length, the usual gap. lgap, rideAt: a long gap with a cushion, and
                                   // when the last one held, stand: d's floor with it (see ride)
    Slot last;

    const Pic &at(long i) const { return pic[i % kPics]; }
    // the snap, under a slot: a whole ratio's next phase sat on its edge (0.1 at 24 on 240, 0.125 at 30 on 240: a hold
    // every other slot). 0.9 of one leaves the usual 0.1 as it was everywhere else. "all" (0.45, the real frames menu):
    // half a slot, where every picture has one within reach whatever the phases (30 on 99.85: all 30), past it a
    // second slot only repeats the picture (uncapped, steps up to 23 ms off)
    double sn(double g = 0, int n = 0) const {
        double s = p.snap, h = p.snap >= 0.45 - 1e-6 ? 0.499 : 0.9;
        if ((p.mode == Grid || p.mode == Rate) && g > 0) s = std::min(s, h * per() / g);
        else if (n > 0) s = std::min(s, h / n);
        return std::max(s, 0.005);
    }
    double per() const { return p.mode == Rate ? 1 / p.num : p.num > 0 ? 1 / p.num : gp > 0 ? gp : p.tick; }
    // the lattice only means something where slots can land on pictures again and again: a whole ratio. elsewhere (59.94
    // on 144) they never do, a lattice d only rose and fell around the phases rolling past (a hold every few seconds)
    bool lattice() const { return p.align && whole && (p.mode == Rate || (p.mode == Grid && lastT > -1e299)); }
    double base() const { return (p.mode == Rate ? A : lastT) - ref; } // where slots fall in content time, at d = ref
    double quant(double x) const { // d on the lattice, not lower than x
        double P = per();
        return lattice() ? ref + P * std::ceil((x - ref) / P - 1e-6) : x;
    }
    void anchorOn(double t) { // move the lattice so that a slot lands on content time t
        double P = per(), e = t - base();
        ref -= e - P * std::floor(e / P);
    }
    void setD(double v, double from) { d = v; seg[ns++ % kSegs] = {from, v}; }
    // the d in force for a slot at T: the newest change it has reached. slot false: for content time T
    double dAt(double T, bool slot = true) const {
        for (long i = ns - 1; i > 0 && i > ns - kSegs; i--) {
            const Seg &s = seg[i % kSegs];
            if ((slot ? T - s.d : T) >= s.c - 1e-9) return s.d;
        }
        return seg[std::max(0L, ns - kSegs) % kSegs].d;
    }
    // percentile q of the needs over the last win seconds, or of all the gaps kept (the last kHist)
    // a gap's need as the fall sees it: with a cushion, on our own slots or a grid one over the usual (median) gap less
    // by what it is over it, up to the cushion: a frame a tick late is what one tick is for, however often it comes (the house run: 107 of 1960
    // gaps 3 ticks, in places over a tenth; counted whole they put d a period up). the cushion on top covers that once, not twice (else a dropped frame stood d a cushion over its own
    // need), and never under a usual gap's (a dip of long gaps took d down with it)
    double cushioned(double need, double g) const {
        const double u = p.mode == Rate || p.mode == Grid ? usual : lgap; // (self-timed: a late frame still rises there, netted it fell and rose again, 3 a sec x2)
        return p.cushion > 0 && u > 0 && g > 1.1 * u ? need - std::min(p.cushion, g - u) : need;
    }
    double needOf(long i) const { return cushioned(hist[i % kHist].net, hist[i % kHist].g); }
    // lag (rateEvenLate, Clock): the picture's content time is this far behind its arrival. the cushion sees its need as
    // if it had come that much sooner (up to the cushion; ahead of it: later), so d stands on the need of a picture on
    // time and the level moves inside the cushion. by its arrival moved, not the need less the level: a need is
    // quantised to slots and floored, a level of -20 ms took d 21 ms up
    // and not by where the slots fall: content rolls through them (its step is not two slots), a need by the slot
    // before b took d 10 ms up and down with the phase (fall at 5 %, a rise a hold). the worst phase: b in by just past lo
    double netNeed(const Pic &a, const Pic &b, double lag) const {
        if (!p.level || p.cushion <= 0) return need(a, b);
        double g = b.t - a.t, lo = b.cut ? b.t - 2e-9 : a.t + sn(g, b.n) * g;
        return p.budget + std::max(p.floor, b.known - std::min(p.cushion, lag) - lo + 0.02 * per());
    }
    double pctl(double now, double q, bool gaps) const {
        double v[kHist]; int n = 0;
        for (long i = std::max(0L, nh - kHist); i < nh; i++)
            if (gaps || (hist[i % kHist].at >= now - p.win && !(p.level && usual > 0 && hist[i % kHist].g > 1.6 * usual)))
                v[n++] = gaps ? hist[i % kHist].g : needOf(i); // (level: a gap by arrival, a miss, is the ride's, not the window's)
        if (!n) return 0;
        int k = std::min(n - 1, (int)(q * n));
        std::nth_element(v, v + k, v + n);
        return v[k];
    }
    int count(double g, double now) { // slots in a gap of g, self-timed modes
        int m = std::max(1, (int)p.num), n = m;
        if (p.mode == TimesGap) { // the usual gap: the short end of the last 128. a dip of a few seconds stays a dip
            double b = pctl(now, 0.1, true);
            n = b > 0 ? std::min(8 * m, std::max(1, (int)std::lround(g * m / b))) : m;
        } else if (p.mode != Times) return 1;
        // what the screen can take: times 4 of 60 fps is 240 a second, a 100 hz screen shows every other one at best and
        // the drawable queue backs up. +0.1: a gap measured a little short still gets its slots
        int c = p.space > 0 ? std::max(1, (int)std::floor(g / p.space + 0.1)) : n;
        if (c < n) { thinned++; n = c; }
        return n;
    }
    // whole or not, by the usual gap. at 59.94 on 144 every fifth picture came near a slot, and pulling there walked d
    // down to a rise and a hold every 4 to 12 s; not whole, phases roll as with align off. the median gap snapped to
    // signal ticks: arrival jitter of half a ms made the short end of the gaps short and turned the lattice off at true
    // whole ratios (59.94 on 59.94: d 8 -> 24 ms, 15 % mixes). exact ratios only then (1e-4, off past 5e-4): 59.94 on a
    // screen left at 60.00 is 0.1 % off, a lattice there slid d 8 -> 25 ms and back every 16 s, rolling phases keep d
    // still. unsnapped (rateEven): 1 % on, 3 % off. in between it stays as it was, so jitter at the edge does not flap
    bool isWhole() {
        double g = p.ticks ? std::round(pctl(lastK, 0.5, true) / p.tick) * p.tick : mean();
        if (g <= 0) return whole;
        if (std::fabs(g - usual) > 1e-6) peak = 0; // another usual gap (a dip that lasts): another cycle
        usual = g;
        double r = g / per(), k = r >= 1 ? std::round(r) : std::round(1 / r), dev = r >= 1 ? std::fabs(r / k - 1) : std::fabs(k * r - 1);
        double on = p.ticks ? 1e-4 : 0.01, off = p.ticks ? 5e-4 : 0.03;
        bool w = k >= 1 && (dev < on || (whole && dev <= off));
        double fr = r >= 1 ? std::fabs(r - k) : std::fabs(1 / r - k) * r; // of a gap: how far the phase moves a gap
        beat = fr > 1e-6 ? std::min(30.0, g / fr) : 30;
        if (w && !whole) anchor = back = true; // the lattice comes back: land it on a picture again
        return w;
    }
    // Rate: our next slot still shows content before t (a gap whose phases are handed out). moving our slots then would
    // move those too, onto phases nobody asked for
    bool pending(double t) const {
        double P = per(), j = lastT > -1e299 ? std::round((lastT - A) / P) + 1 : 0, Tn = A + j * P;
        return Tn - dAt(Tn) < t - 1e-9;
    }
    double mean() const { double s = 0; int n = 0; for (long i = std::max(0L, nh - kHist); i < nh; i++, n++) s += hist[i % kHist].g; return n ? s / n : 0; }
    // the least d that has b in, and its in-betweens with a made, by the first slot that needs b
    double need(const Pic &a, const Pic &b) const {
        double g = b.t - a.t, lo = b.cut ? b.t - 2e-9 : a.t + sn(g, b.n) * g, ready = b.known + p.budget, c;
        if (p.mode == Grid || p.mode == Rate) { // content up to lo does without b
            double P = per(), T0 = p.mode == Rate ? A : lastT, r = lo + 1e-9 - base();
            if (p.mode == Grid && lastT < -1e299) c = lo;                       // no slot seen yet: the worst
            else if (lattice()) c = lo + 1e-9 + P - (r - P * std::floor(r / P)); // the lattice's first point past lo
            // the slot before b is ready, from the last one at the nominal period. 2 % of a period over it: a screen's
            // real refresh is a little off its nominal one (99.8 for 100 hz), its slots come that much later, and a d
            // right on the need put rate 2's slot at the snap edge just past it, a hold every 3 gaps (on the glass, 29.97 on 100)
            else return std::max(p.floor + p.budget, T0 + P * (std::ceil((ready - T0) / P - 1e-9) - 1) - lo + 0.02 * P);
        } else { // the first phase past the snap
            int i = (int)std::floor(sn(g, b.n) * b.n + 1e-9) + 1;
            c = b.cut || i >= b.n ? b.t : a.t + g * i / b.n;
        }
        return p.budget + std::max(p.floor, b.known - c);
    }
    void start(double t) {
        nh = 0; anchor = true; ns = 0; whole = true; shifted = 0; peak = peakAt = beat = usual = lgap = stand = 0; rideAt = -1e300;
        ref = p.floor + p.budget;
        setD(ref, t);
        if (p.mode == Rate) { // its slots start on this picture
            A = t + d;
            if (A <= lastT) A += per() * std::ceil((lastT - A) / per() + 1e-6);
        }
    }

    // a new picture: its content time, a cut before it, when it was known (default: at t). ids and times only go up.
    // false: not taken (a duplicate), the caller keeps nothing of it either
    bool picture(long id, double t, bool cut, double known = -1, double lag = 0) {
        if (known < t && (!p.level || known < 0)) known = t; // (a level under 0: content ahead of its arrival, known before it)
        if (np && (t <= at(np - 1).t || id <= at(np - 1).id)) { dups++; return false; }
        if (t < lastC) late++; // slots went past it already: they held, and stay what they were
        double g = np ? t - at(np - 1).t : 0, dt = known - lastK, d0 = d;
        lastK = known;
        bool fresh = !np || g > p.pause;
        if (np && fresh) { pauses++; why = kPause; }
        pic[np % kPics] = {id, t, known, cut || fresh, fresh || cut ? 1 : count(g, known)};
        np++;
        if (fresh) { start(t); return true; }
        const Pic &a = at(np - 2), &b = at(np - 1);
        double v = d;
        if (nh >= 8 && (p.mode == Rate || p.mode == Grid)) whole = isWhole(); // see isWhole
        if (lattice()) { // a slot nearly on this picture: pull the lattice onto it, so a whole ratio does not drift
            double P = per(), e = t - base();
            e -= P * std::floor(e / P + 0.5);
            // Rate: our own slots follow, d stays. the capture card's clock and ours differ by tens of ppm; moving d with
            // it walked fixed 60 from 9 up a tick and down again every few minutes (content faster than our slots). not
            // while a gap is handed out (its phases would move): then d, as before, and the next picture pulls again. and
            // only a clock's drift (us a picture): arrival times off by tenths of a ms moved our slots back and forth and
            // took fixed 60 on a live trace from 25 to 35 ms (-rateClock NO)
            if (std::fabs(e) < 0.02 * P && std::fabs(e) > 1e-9) { if (p.mode == Rate && std::fabs(e) < 1e-4 && !pending(at(np - 2).t)) A += e; else { ref -= e; v -= e; why = kDrift; } }
        }
        double nd = need(a, b);
        if (p.cushion > 0 && nh) { // a long gap, with a cushion: past the p90 of the gaps before it. not past the usual
            // (median) gap: at 40-45 fps gaps of 1 and 2 ticks take turns, a 2 is no dropped frame (live2: 109 holds a
            // minute at one tick against that)
            double q = pctl(known, 0.9, true);
            lgap = p.ticks ? std::round(q / p.tick) * p.tick : q;
        }
        hist[nh++ % kHist] = {known, g, nd, netNeed(a, b, lag)};
        // the cycle's peak from usual gaps only: a dip's long gaps are not a phase, d comes back after it as always
        if (usual > 0 && g <= 1.1 * usual && (nd >= peak || known - peakAt > std::max(2.0, beat + 1))) { peak = nd; peakAt = known; }
        // with a cushion (Params::cushion) d stands on stand: where the last fall stopped, the window's need (late
        // frames less, see needOf) and the cushion. a rise goes to it or the need, whichever is more, so after it the
        // cushion stands again. on our own slots (Rate) a usual picture also rises to it when d is short of it by more
        // than a quarter period (the content went slower, 60 -> 30 fps: else two ticks stood as one); a hair short
        // stays, a period up for a hair is the opposite of a cushion.
        // a long gap (over the p90 gap: a dropped frame) on our own slots or a grid, with the cushion standing, does
        // not rise: it is what the cushion is for, one past it holds a slot and d stays. a rise held that slot too,
        // then stood seconds up and came back in a second of steps up to 7 ms (the house run, at two ticks). one held
        // each half second at most: more often is the content gone slower (60 -> 40 fps), that rises as without
        // (live2: 13 holds in 2 s). self-timed slots follow the content: there a long gap past the cushion still
        // rises (held, its slots were squeezed together)
        const bool lng = p.cushion > 0 && lgap > 0 && g > 1.1 * lgap;
        const bool ride = lng && (p.mode == Rate || p.mode == Grid) && known - rideAt > 0.5 && stand <= v + 0.25 * per()
                          && nd > stand + 1e-9; // (standing: as shortc, a hair short counts. one the cushion as it should stand covers rises to it, no hold: live2 60 -> 30 fps)
        const bool shortc = p.cushion > 0 && p.mode == Rate && !lng && !p.level && stand > v + 0.25 * per() && quant(stand) <= p.dmax; // (never past dmax: it held there. level: the slide only, a jump stilled a refresh after house2's 233 ms freeze)
        if (!ride && (quant(nd) > v + 1e-9 || shortc)) { // later than d covers: rise now, onto a lattice that lands on this picture
            bool moved = false;
            if (lattice()) anchorOn(t);
            hist[(nh - 1) % kHist].need = nd = need(a, b); hist[(nh - 1) % kHist].net = netNeed(a, b, lag);
            if (p.cushion > 0) nd = std::max(nd, stand); // (with a cushion: at least where d stands with it. the history keeps the need)
            v = quant(nd);
            if (p.mode == Rate && lattice() && v - nd > 1e-6) { // a need a little over the lattice (the budget a ms up):
                // our own slots go that much later instead, the content lattice stays on the pictures. a whole period
                // of delay for it took fixed 30 on 30 fps from 6 to 39 ms. a need half a period over is a new phase
                // (a dropped frame, d45): that one still rises a period, as before
                double sh = nd - (v - per());
                if (sh > 0 && sh < 0.25 * per() && !pending(a.t)) { A += sh; ref += sh; shifted += sh; v = nd; moved = true; }
            }
            if (v > p.dmax) // past it: hold instead
                v = std::max(p.floor + p.budget, lattice() ? v - per() * std::ceil((v - p.dmax) / per() - 1e-6) : p.dmax);
            // under a ms: following jitter, no hold. a shift of our own slots is a step on the glass: counted apart
            // a shift that also went a period up (60 to 30 fps, the need a hair over the point) is both
            why = moved || v - d0 > 0.001 ? kRise : kDrift;
            if (moved) steps++;
            if (v - d0 > (moved ? 0.25 * per() : 0.001)) rises++;
        } else { // fall: towards a high percentile of the window, or, while one-tick gaps dominate, the last few
            if (ride && quant(nd) > v + 1e-9) rideAt = known; // (held: see ride)
            int ones = 0, k = 0;
            double fastNeed = 0;
            const int fw = std::max(4, p.fastWin);
            for (long i = nh - 1; i >= 0 && k < fw; i--, k++) {
                ones += hist[i % kHist].g <= 1.5 * p.tick;
                fastNeed = std::max(fastNeed, needOf(i));
            }
            bool fst = k == fw && 4 * ones >= 3 * fw;
            double want = fst ? fastNeed : pctl(known, p.level ? 1.0 : p.pct, false); // (level: the most, see netNeed)
            if (p.align && !whole) { // phases roll past the pictures: a need comes back a cycle later (1.4 s at 59.94 on
                // 144, 16.7 s on a screen left at 60.00). no fall under the most of the last 2 s, nor under the most of
                // the last cycle: d stays put while the phases roll, instead of a saw-tooth 8 -> 23 ms every cycle
                for (long i = std::max(0L, nh - kHist); i < nh; i++)
                    if (hist[i % kHist].at >= known - 2) want = std::max(want, needOf(i));
                want = std::max(want, peak);
            }
            // the cushion (Params::cushion) on what the window needs: d stands that much over it, the fall stops there
            double w = std::max(want + p.cushion, p.floor + p.budget), ndr = cushioned(hist[(nh - 1) % kHist].net, g); // (a long gap: see ride)
            if (p.cushion > 0) stand = w;
            if (p.mode == Rate && lattice() && !pending(a.t)) {
                // our own slots move so that a lattice point lands on what the window needs, never under the pair just in
                // (its slots are still to come: going under it held one of them, 5 a minute at 30 fps)
                double wn = std::max(w, ndr), L = quant(wn), bk = std::min({shifted, L - wn, v - wn}); // v: off the lattice while it falls
                if (bk >= 5e-4) { // the shift given back, in one step as it came (one shorter slot spacing): a picture 5 ms
                    // late once, or a budget hump 6 -> 26 -> 6, ends at the old d. measured from the point at or over what
                    // is needed, not from d: from d a period up it gave back past that point, the fall then had nowhere to go
                    // and d stayed a period up for good (30 fps on fixed 60 after a stutter). from half a ms: 1 ms kept
                    // arrivals 1 to 2 ms late 1 in 100 for good (d 10 for 9), 0.1 moved our slots 2-7 times a second at 30-40
                    // fps with 1.5-3 ms of known spread (now 0.7-2.4 a second, d 0.3 ms up)
                    A -= bk; ref -= bk; shifted -= bk; v -= bk; L -= bk; why = kFall; steps++;
                }
                double lo = L - per(); // the point under it a hair short (under a quarter period): our slots go that much
                // later so the fall lands there, the rise's shift mirrored. else a d a period up after a whole-period rise
                // (a stutter, one picture 7 ms late) could only fall back to a point the window's p90 sat just over
                if (lo < v - 1e-9 && wn - lo > 1e-6 && wn - lo < 0.25 * per()) { double sh = wn - lo; A += sh; ref += sh; shifted += sh; steps++; }
            }
            double target = quant(std::max(w, ndr)); // nor the plain fall under the pair just in
            // level (a Clock's content): d slides both ways at 2 % of real time, a shift of the content's speed that size.
            // a rise to the window's most at once (its need grows with the content's step: the game slowed) was a 4 ms
            // step back on the glass, a quarter of a refresh's motion; the level stays under 0.9 of the cushion for this
            if (p.level && std::fabs(target - v) > 1e-9) { v = target > v ? std::min(target, v + 0.02 * dt) : std::max(target, v - 0.02 * dt); why = target > v ? kRise : kFall; }
            else if (target < v - 1e-9) { v = std::max(target, v - (fst ? p.fast : p.fall) * dt); why = fst ? kFast : kFall; }
            else if (p.cushion > 0 && p.mode != Rate && target > v + 1e-9) { // the cushion short of what the window needs
                // (a start that needed nothing, the need went up a little): up to it. not on our own slots (Rate): there
                // it moved phases already handed out, it waits for a rise there
                if (target - d0 > 0.001) rises++;
                v = target; why = kRise;
            }
        }
        if (v != d0) setD(v, a.t); // from the gap now handed out
        return true;
    }

    // the slot at T, without planning it
    Slot peek(double T) const {
        Slot s; s.at = T;
        if (!np) return s;
        double c = std::max(T - dAt(T), last.a >= 0 ? last.content : -1e300); // shown content never goes back
        long lo = std::max(0L, np - kPics), k = np - 1;
        while (k > lo && at(k).t > c + 1e-9) k--;
        const Pic &a = at(k);
        s.a = a.id; s.content = a.t; s.kind = Real;
        if (k == np - 1) { // past the newest: hold it, unless within snap of it (the next gap as long as the last few)
            double g = 0;
            for (long i = nh - 1; i >= 0 && i >= nh - 4; i--) g = std::max(g, hist[i % kHist].g);
            if (c > a.t + sn(g) * g + 1e-9) s.kind = Hold;
            return s;
        }
        if (c <= a.t + 1e-9) return s;
        const Pic &b = at(k + 1);
        double g = b.t - a.t, ph = (c - a.t) / g;
        double sg = sn(g, b.n);
        if (b.cut || ph <= sg) return s;
        if (ph >= 1 - sg) { s.a = b.id; s.content = b.t; return s; }
        if (T < b.known + p.budget - 1e-9) { s.kind = Hold; return s; } // in, but its in-betweens not made yet
        s.kind = Mix; s.b = b.id; s.t = ph; s.content = c;
        return s;
    }
    // plan the slot at T. T only goes up
    // Grid: a slot time near the grid's next points is taken as that point: jitter in measured refresh times moves
    // nothing. the grid itself follows slowly (and learns its period when num is 0)
    double onGrid(double T) const {
        if (p.mode != Grid || lastT < -1e299 || gp <= 0) return T;
        double P = per(), n = std::max(1.0, std::round((T - lastT) / P));
        return std::fabs(T - lastT - n * P) < P / 4 ? lastT + n * P : T;
    }
    Slot plan(double T) {
        double Tg = onGrid(T), n = lastT > -1e299 ? std::max(1.0, std::round((T - lastT) / per())) : 1;
        if (Tg <= lastT) return last;
        if (p.mode == Grid && p.num <= 0 && lastT > -1e299 && T - lastT < 0.1) // learn the period
            gp = gp > 0 ? gp + 0.02 * ((T - lastT) / n - gp) : T - lastT;
        lastT = Tg;
        // a re-anchor. the grid moved a little (rate 2's slew, rate 1's budget step): every slot takes the new d, which
        // keeps the content of the gaps already handed to the generator where it was. a bigger change, or the lattice
        // coming back (the slots did not move, so d would move the handed-out gaps, small or not): from the newest
        // picture on, the gaps before it keep their d, else a mix goes up at a phase nobody asked for. 3 % under d still taken: a screen's period a hair short of its nominal one put every slew
        // re-anchor a whole period up (rate 2: 34 to 354 jumps in ten minutes)
        if (anchor && np && lattice() && p.mode == Grid) {
            anchorOn(at(np - 1).t);
            double v = quant(d - 0.03 * per());
            if (std::fabs(v - d) < 0.25 * per() && !back) { ns = 0; setD(v, -1e300); } else setD(v, at(np - 1).t);
        }
        if (lattice()) anchor = back = false;
        Slot s = peek(Tg);
        if (s.kind == Hold) held++;
        lastC = Tg - dAt(Tg);
        if (Tg != T) lastT += 0.1 * (T - Tg); // on the grid: follow it slowly, not the jitter
        return last = s;
    }
    // self-timed modes: the next slot times that can be planned now (Rate: the next ones, whatever is in)
    int times(double *out, int max) const {
        int m = 0;
        if (p.mode == Grid || !np) return 0;
        if (p.mode == Rate) {
            double P = per(), j = lastT > -1e299 ? std::round((lastT - A) / P) + 1 : 0;
            for (; m < max; j++) out[m++] = A + j * P;
            return m;
        }
        for (long k = std::max(0L, np - kPics); k < np && m < max; k++) {
            bool nx = k + 1 < np;
            int n = nx ? at(k + 1).n : 1;
            double g = nx ? at(k + 1).t - at(k).t : 0;
            for (int i = 0; i < n && m < max; i++) {
                double c = at(k).t + g * i / n, dc = dAt(c, false), T = c + dc;
                bool shown = last.a >= 0 && c <= last.content + 1e-9; // after a rise: up already, no repeat
                if (T > lastT + 1e-9 && !shown && dAt(T) == dc) out[m++] = T; // a later, lower d skips it
            }
        }
        return m;
    }
    double due() const { double T; return times(&T, 1) ? T : INFINITY; }
    // the phases the pair (a, a's next) needs over the slots at T[0..n): ask as soon as the next picture is in
    int phases(long a, const double *T, int n, double *ph) const {
        int m = 0;
        for (int i = 0; i < n; i++) { Slot s = peek(onGrid(T[i])); if (s.kind == Mix && s.a == a) ph[m++] = s.t; }
        return m;
    }
};

}
