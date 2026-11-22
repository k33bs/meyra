// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#include "display.h"
#include "common.h"
#include <atomic>
#include <cmath>

namespace display {

static CGDirectDisplayID gChanged;  // display we switched, 0 = none
static CGDisplayModeRef gOriginal;  // its mode before
static std::string gStatus = "";
static std::atomic<bool> gVariable{false};
static std::atomic<double> gPeriod{0};

static CGDirectDisplayID idOf(NSScreen *s) { return [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue]; }

static bool multipleOf(double rate, double fps) {
    if (fps < 1) return false;
    double k = round(rate / fps);
    return k >= 1 && fabs(rate - k * fps) < 0.5;
}

static bool setMode(CGDirectDisplayID did, CGDisplayModeRef mode) {
    CGDisplayConfigRef cfg;
    if (!mode || CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return false;
    if (CGConfigureDisplayWithDisplayMode(cfg, did, mode, NULL) != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return false; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly) == kCGErrorSuccess;
}

void restore() {
    if (gChanged && gOriginal)
        logLine("display: %s %.2f hz", setMode(gChanged, gOriginal) ? "back to" : "could not go back to", CGDisplayModeGetRefreshRate(gOriginal));
    if (gOriginal) CGDisplayModeRelease(gOriginal);
    gOriginal = NULL;
    gChanged = 0;
}

void apply(NSScreen *screen, double fps, int mode, bool fullScreen) {
    if (!screen) return;
    CGDirectDisplayID did = idOf(screen);
    if (gChanged && (gChanged != did || mode == 0)) restore();
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    if (!cur) return;
    double curHz = CGDisplayModeGetRefreshRate(cur);
    char b[160];
    // variable refresh (adaptive sync, promotion): the screen shows each frame when it comes, as long as the source's
    // frame time is inside its range. better than any fixed mode: even motion and no wait for a tick (measured on a
    // 48-100 hz screen, full screen: about half the delay of the matched 60 hz mode).
    // only full screen: a window is drawn by the compositor at the screen's top rate (measured: 10/20 ms steps at
    // 100 hz), so there the fixed mode below is still the even one.
    // the range is remembered from before we switch: on a fixed mode of ours the screen reports that mode's rate
    static CGDirectDisplayID rangeOf; static double lo, hi;
    if (gChanged != did || rangeOf != did) { rangeOf = did; lo = screen.minimumRefreshInterval; hi = screen.maximumRefreshInterval; }
    bool vrr = mode == 1 && fullScreen && fps >= 1 && hi - lo > 0.0005 && 1 / fps >= lo - 0.0002 && 1 / fps <= hi + 0.0002;
    gVariable = vrr;
    gPeriod = vrr && lo > 0 ? lo : curHz > 0 ? 1 / curHz : 0;
    { static int lastKey = -1; int key = (int)vrr | (int)fullScreen << 1 | (hi - lo > 0.0005) << 2; // why, once per change
      if (mode == 1 && fps >= 1 && key != lastKey) { lastKey = key; logLine("display: range %.1f-%.1f ms, full screen %d, variable %d", lo * 1000, hi * 1000, (int)fullScreen, (int)vrr); } }
    if (vrr) {
        if (gChanged == did) restore();
        snprintf(b, sizeof b, "%s variable %.0f-%.0f Hz, following the source", screen.localizedName.UTF8String, 1 / hi, 1 / lo);
        if (gStatus != b) logLine("display: %s (source %.2f fps)", b, fps);
        gStatus = b;
        CGDisplayModeRelease(cur);
        return;
    }
    if (mode == 0 || fps < 1) {
        snprintf(b, sizeof b, "%s %.0f Hz", screen.localizedName.UTF8String, curHz);
        gStatus = b;
        CGDisplayModeRelease(cur);
        return;
    }
    // the rate we would pick
    CGDisplayModeRef base = gChanged == did && gOriginal ? gOriginal : cur;
    double baseHz = CGDisplayModeGetRefreshRate(base);
    NSArray *all = CFBridgingRelease(CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)@{(id)kCGDisplayShowDuplicateLowResolutionModes: @YES}));
    CGDisplayModeRef best = NULL;
    bool leave = mode == 1 && multipleOf(baseHz, fps);
    auto off = [&](double r) { return fabs(r - round(r / fps) * fps); }; // 60 vs 59.94 for 59.94 content
    if (!leave) {
        for (id m in all) {
            CGDisplayModeRef dm = (__bridge CGDisplayModeRef)m;
            if (CGDisplayModeGetWidth(dm) != CGDisplayModeGetWidth(cur) || CGDisplayModeGetHeight(dm) != CGDisplayModeGetHeight(cur) ||
                CGDisplayModeGetPixelWidth(dm) != CGDisplayModeGetPixelWidth(cur)) continue;
            double r = CGDisplayModeGetRefreshRate(dm), br = best ? CGDisplayModeGetRefreshRate(best) : 0;
            if (mode == 2) {
                if (fabs(r - fps) < 0.5 && (!best || fabs(r - fps) < fabs(br - fps))) best = dm;
            } else if (multipleOf(r, fps) && (!best || r > br + 0.5 || (fabs(r - br) <= 0.5 && off(r) < off(br)))) {
                best = dm; // fastest whole multiple: a fast refresh is what keeps the display's own hold short
            }
        }
    }
    if (!best) leave = true; // nothing better on offer: the display's own mode
    double target = leave ? baseHz : CGDisplayModeGetRefreshRate(best);
    if (!leave && fabs(target - curHz) > 0.01) {
        bool first = !gChanged;
        if (first) { gChanged = did; gOriginal = CGDisplayModeRetain(cur); }
        if (setMode(did, best)) logLine("display %s: %.2f -> %.2f hz while running", screen.localizedName.UTF8String, curHz, target);
        else {
            logLine("display %s: could not switch to %.2f hz", screen.localizedName.UTF8String, target);
            target = curHz;
            if (first) { CGDisplayModeRelease(gOriginal); gOriginal = NULL; gChanged = 0; }
        }
    }
    if (leave && gChanged == did) restore();
    bool even = multipleOf(target, fps);
    snprintf(b, sizeof b, "%s %.0f Hz%s", screen.localizedName.UTF8String, target,
             gChanged == did ? " (matched while running)" : even ? "" : " (no matching mode offered, motion may judder)");
    static std::string lastLog;
    char key[256];
    snprintf(key, sizeof key, "%s (source %.2f fps, %s)", b, fps, mode == 1 ? "automatic" : "source rate");
    if (lastLog != key) logLine("display: %s", key);
    if (target > 0) gPeriod = 1 / target;
    lastLog = key;
    gStatus = b;
    CGDisplayModeRelease(cur);
}

std::string status() { return gStatus; }
bool variable() { return gVariable; }
double period() { return gPeriod; }
void modeChanged(NSScreen *screen) {
    if (!screen || gVariable) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(idOf(screen));
    double hz = cur ? CGDisplayModeGetRefreshRate(cur) : 0;
    if (hz > 0) gPeriod = 1 / hz;
    if (cur) CGDisplayModeRelease(cur);
}

}
