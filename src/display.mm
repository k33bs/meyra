// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#include "display.h"
#include "common.h"
#include <cmath>

namespace display {

static CGDirectDisplayID gChanged;  // display we switched, 0 = none
static CGDisplayModeRef gOriginal;  // its mode before
static std::string gStatus = "";

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

void apply(NSScreen *screen, double fps, int mode) {
    if (!screen) return;
    CGDirectDisplayID did = idOf(screen);
    if (gChanged && (gChanged != did || mode == 0)) restore();
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    if (!cur) return;
    double curHz = CGDisplayModeGetRefreshRate(cur);
    char b[160];
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
    lastLog = key;
    gStatus = b;
    CGDisplayModeRelease(cur);
}

std::string status() { return gStatus; }

}
