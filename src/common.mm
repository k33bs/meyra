// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <QuartzCore/QuartzCore.h>
#include "common.h"
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/lock.h>

Settings gSet;

static FILE *gLogFile;
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;

double nowSec() { return CACurrentMediaTime(); }
static const double gStart = CACurrentMediaTime();
double sinceStart(double t) { return (t > 0 ? t : nowSec()) - gStart; }

void logOpen(const char *path) {
    gLogFile = fopen(path, "w");
    if (!gLogFile) fprintf(stderr, "cannot write log %s\n", path);
}

void logLine(const char *fmt, ...) {
    char b[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    os_unfair_lock_lock(&gLogLock);
    fprintf(stdout, "%s\n", b);
    fflush(stdout);
    if (gLogFile) { fprintf(gLogFile, "%s\n", b); fflush(gLogFile); }
    os_unfair_lock_unlock(&gLogLock);
}

// ordinary threads wake up to a frame late from a sleep. a time constraint thread does not
void makeRealtime(double periodSec) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticksPerSec = 1e9 * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t p;
    p.period = (uint32_t)(periodSec * ticksPerSec);
    p.computation = (uint32_t)(0.002 * ticksPerSec);
    p.constraint = (uint32_t)(0.004 * ticksPerSec);
    p.preemptible = 1;
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

void tag709(CVPixelBufferRef pb) {
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
}

std::string fourcc(uint32_t v) {
    char s[5] = {char(v >> 24), char(v >> 16), char(v >> 8), char(v), 0};
    for (int i = 0; i < 4; i++) if (s[i] < 32 || s[i] > 126) s[i] = '?';
    return s;
}

int chainParse(const char *s, const char **why) {
    const char *colon = strchr(s, ':');
    if (!colon || strchr(colon + 1, ':')) { *why = "want PRE:POST"; return -1; }
    int b = kChainSet, at = 0;
    for (const char *p = s; p < colon; p++) { // N or n, D, E in that order
        const char *o = strchr("NnDE", *p);
        int k = o ? (int)(o - "NnDE") : -1, rank = k < 2 ? 0 : k - 1;
        if (k < 0 || rank < at) { *why = "PRE is N or n, D, E in that order"; return -1; }
        at = rank + 1;
        b |= 1 << k;
    }
    const char *p = colon + 1;
    if (*p == 'D') { b |= kPostD; p++; }
    if (*p == 'E') { b |= kPostE; p++; }
    if (!strcmp(p, "SU")) b |= kPostU | kPostS | kSharpFirst;
    else if (!strcmp(p, "US")) b |= kPostU | kPostS;
    else if (!strcmp(p, "U")) b |= kPostU;
    else if (!strcmp(p, "S")) b |= kPostS;
    else if (*p) { *why = "POST is D E U S in that order, or SU"; return -1; }
    if ((b & kPreD) && (b & kPostD)) { *why = "D twice"; return -1; }
    if ((b & kPreE) && (b & kPostE)) { *why = "E twice"; return -1; }
    if ((b & kPostE) && (b & kPostU)) { *why = "E takes the upscaler's place"; return -1; }
    if ((b & kPreE) && (b & kPostD)) { *why = "E before D"; return -1; }
    if ((b & (kPreN | kPreNSide)) && (b & (kPreD | kPreE))) { *why = "noise filter together with D or E before the interpolator is not built"; return -1; }
    return b;
}

std::string chainText(int b) {
    std::string t;
    if (b & kPreN) t += 'N';
    if (b & kPreNSide) t += 'n';
    if (b & kPreD) t += 'D';
    if (b & kPreE) t += 'E';
    t += ':';
    if (b & kPostD) t += 'D';
    if (b & kPostE) t += 'E';
    if (b & kSharpFirst) return t + "SU";
    if (b & kPostU) t += 'U';
    if (b & kPostS) t += 'S';
    return t;
}

void hudRectsParse(const char *s) {
    int n = 0; // the count last, never 0 in between: the render thread reads it while a preset loads the same areas again
    for (NSString *one in [@(s ?: "") componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *v = [one componentsSeparatedByString:@","];
        if (v.count != 4 || n >= kHudMax) continue;
        float x = fminf(1, fmaxf(0, v[0].floatValue)), y = fminf(1, fmaxf(0, v[1].floatValue));
        float w = fminf(1 - x, v[2].floatValue), h = fminf(1 - y, v[3].floatValue);
        if (!(w > 0 && h > 0)) continue;
        gSet.hudRect[4 * n] = x; gSet.hudRect[4 * n + 1] = y; gSet.hudRect[4 * n + 2] = w; gSet.hudRect[4 * n + 3] = h;
        n++;
    }
    gSet.hudN = n;
}

std::string hudRectsText() {
    std::string t;
    for (int i = 0, n = gSet.hudN; i < n; i++) {
        char b[80];
        snprintf(b, sizeof b, "%s%.4f,%.4f,%.4f,%.4f", i ? ";" : "", gSet.hudRect[4 * i].load(), gSet.hudRect[4 * i + 1].load(), gSet.hudRect[4 * i + 2].load(), gSet.hudRect[4 * i + 3].load());
        t += b;
    }
    return t;
}

// keys in the user defaults. the argument domain (-key value on the command line) overrides them for one run
// without being saved, which is what the automated tests use
void settingsLoad() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{@"levels": @0, @"deband": @YES, @"upscale": @1, @"sharpen": @0.6, @"frameGen": @YES, @"early": @NO,
                          @"passthrough": @NO, @"audio": @YES, @"audioTrimMs": @0, @"refresh": @1, @"overlay": @YES,
                          @"checkUpdatesAtLaunch": @YES, @"srWithGen": @YES, @"srPad": @YES, @"vsync": @YES, @"gameMode": @YES,
                          @"genSmall": @NO, @"genStill": @0, @"denoise": @NO, @"noise": @0.5}];
    gSet.levels = (int)((([d integerForKey:@"levels"] % 3) + 3) % 3); // a negative number stays a place in the list
    gSet.deband = [d boolForKey:@"deband"];
    gSet.upscale = (int)((([d integerForKey:@"upscale"] % 5) + 5) % 5);
    gSet.enhance = (int)MAX(0, [d integerForKey:@"enhance"]); // a number with no net behind it counts as off
    gSet.enhanceAt = (int)((([d integerForKey:@"enhanceAt"] % 3) + 3) % 3);
    gSet.enhanceDown = (int)((([d integerForKey:@"enhanceDown"] % 2) + 2) % 2);
    gSet.sharpen = fminf(1, fmaxf(0, [d floatForKey:@"sharpen"]));
    gSet.frameGen = [d boolForKey:@"frameGen"];
    gSet.early = [d boolForKey:@"early"];
    gSet.passthrough = [d boolForKey:@"passthrough"];
    gSet.audio = [d boolForKey:@"audio"];
    gSet.audioTrim = [d doubleForKey:@"audioTrimMs"] / 1000;
    gSet.refresh = (int)((([d integerForKey:@"refresh"] % 3) + 3) % 3);
    gSet.overlay = [d boolForKey:@"overlay"];
    gSet.overlayFull = [d boolForKey:@"overlayFull"];
    gSet.look = (int)((([d integerForKey:@"look"] % 4) + 4) % 4);
    gSet.compare = (int)((([d integerForKey:@"compare"] % 8) + 8) % 8);
    gSet.genFloor = [d objectForKey:@"genFloor"] ? fminf(15, fmaxf(4, [d floatForKey:@"genFloor"])) : 12;
    { // was a switch: a saved or typed yes is 1, 1280x720
        id v = [d objectForKey:@"genSmall"];
        int n = [v isKindOfClass:NSNumber.class] ? [v intValue] : [v isKindOfClass:NSString.class] ? ([v intValue] ?: [v boolValue]) : 0;
        gSet.genSmall = n < 0 || n > 3 ? 0 : n;
    }
    gSet.netHalf = [d boolForKey:@"netHalf"];
    gSet.genDeadline = [d integerForKey:@"genDeadline"] == 1 ? 1 : 0;
    gSet.genLateNext = [d boolForKey:@"genLateNext"];
    gSet.gpuAwake = [d boolForKey:@"gpuAwake"];
    gSet.genStill = (int)((([d integerForKey:@"genStill"] % 5) + 5) % 5);
    gSet.genModel = (int)(([d integerForKey:@"genModel"] % 3 + 3) % 3);
    gSet.srWithGen = [d boolForKey:@"srWithGen"];
    gSet.srPad = [d boolForKey:@"srPad"];
    gSet.vsync = [d boolForKey:@"vsync"];
    gSet.colour = (int)((([d integerForKey:@"colour"] % 3) + 3) % 3);
    gSet.keepRes = [d boolForKey:@"keepRes"];
    gSet.denoise = [d boolForKey:@"denoise"];
    gSet.hudLock = [d boolForKey:@"hudLock"];
    gSet.cutTest = [d boolForKey:@"cutTest"];
    gSet.repeatTol = [d boolForKey:@"repeatTol"];
    gSet.ptsTime = [d boolForKey:@"ptsTime"];
    gSet.enhanceReal = [d boolForKey:@"enhanceReal"];
    gSet.enhanceHold = [d boolForKey:@"enhanceHold"];
    gSet.superSample = [d boolForKey:@"superSample"];
    gSet.noise = fminf(1, fmaxf(0, [d floatForKey:@"noise"]));
    hudRectsParse([[d objectForKey:@"hudRects"] description].UTF8String);
    gSet.hudShow = [d boolForKey:@"hudShow"];
    if (id c = [d objectForKey:@"chain"]) { // hidden, for tests. anything but a string was never a chain
        const char *s = [c isKindOfClass:NSString.class] ? [c UTF8String] : "?", *why = "";
        int b = chainParse(s, &why);
        if (b < 0) logLine("chain: \"%s\" refused (%s), using :DUS", s, why);
        else {
            gSet.chain = b;
            std::string t = chainText(b);
            size_t k = t.find(':');
            auto spaced = [](std::string x) { std::string o; for (char ch : x) { if (!o.empty()) o += ' '; o += ch; } return o; };
            logLine("chain: %s -> pre [%s] post [%s]", s, spaced(t.substr(0, k)).c_str(), spaced(t.substr(k + 1)).c_str());
        }
    }
}

void settingsSave(const char *key) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *k = @(key);
    if ([k isEqual:@"levels"]) [d setInteger:gSet.levels forKey:k];
    else if ([k isEqual:@"deband"]) [d setBool:gSet.deband forKey:k];
    else if ([k isEqual:@"srPad"]) [d setBool:gSet.srPad forKey:k];
    else if ([k isEqual:@"vsync"]) [d setBool:gSet.vsync forKey:k];
    else if ([k isEqual:@"colour"]) [d setInteger:gSet.colour forKey:k];
    else if ([k isEqual:@"keepRes"]) [d setBool:gSet.keepRes forKey:k];
    else if ([k isEqual:@"srWithGen"]) [d setBool:gSet.srWithGen forKey:k];
    else if ([k isEqual:@"upscale"]) [d setInteger:gSet.upscale forKey:k];
    else if ([k isEqual:@"enhance"]) [d setInteger:gSet.enhance forKey:k];
    else if ([k isEqual:@"enhanceAt"]) [d setInteger:gSet.enhanceAt forKey:k];
    else if ([k isEqual:@"enhanceDown"]) [d setInteger:gSet.enhanceDown forKey:k];
    else if ([k isEqual:@"sharpen"]) [d setFloat:gSet.sharpen forKey:k];
    else if ([k isEqual:@"frameGen"]) [d setBool:gSet.frameGen forKey:k];
    else if ([k isEqual:@"early"]) [d setBool:gSet.early forKey:k];
    else if ([k isEqual:@"genSmall"]) [d setInteger:gSet.genSmall forKey:k];
    else if ([k isEqual:@"netHalf"]) [d setBool:gSet.netHalf forKey:k];
    else if ([k isEqual:@"genDeadline"]) [d setInteger:gSet.genDeadline forKey:k];
    else if ([k isEqual:@"genLateNext"]) [d setBool:gSet.genLateNext forKey:k];
    else if ([k isEqual:@"gpuAwake"]) [d setBool:gSet.gpuAwake forKey:k];
    else if ([k isEqual:@"genStill"]) [d setInteger:gSet.genStill forKey:k];
    else if ([k isEqual:@"genModel"]) [d setInteger:gSet.genModel forKey:k];
    else if ([k isEqual:@"denoise"]) [d setBool:gSet.denoise forKey:k];
    else if ([k isEqual:@"hudLock"]) [d setBool:gSet.hudLock forKey:k];
    else if ([k isEqual:@"cutTest"]) [d setBool:gSet.cutTest forKey:k];
    else if ([k isEqual:@"repeatTol"]) [d setBool:gSet.repeatTol forKey:k];
    else if ([k isEqual:@"ptsTime"]) [d setBool:gSet.ptsTime forKey:k];
    else if ([k isEqual:@"enhanceReal"]) [d setBool:gSet.enhanceReal forKey:k];
    else if ([k isEqual:@"enhanceHold"]) [d setBool:gSet.enhanceHold forKey:k];
    else if ([k isEqual:@"superSample"]) [d setBool:gSet.superSample forKey:k];
    else if ([k isEqual:@"passthrough"]) [d setBool:gSet.passthrough forKey:k];
    else if ([k isEqual:@"audio"]) [d setBool:gSet.audio forKey:k];
    else if ([k isEqual:@"audioTrimMs"]) [d setDouble:round(gSet.audioTrim * 1000) forKey:k];
    else if ([k isEqual:@"refresh"]) [d setInteger:gSet.refresh forKey:k];
    else if ([k isEqual:@"overlay"]) [d setBool:gSet.overlay forKey:k];
    else if ([k isEqual:@"overlayFull"]) [d setBool:gSet.overlayFull forKey:k];
    else if ([k isEqual:@"look"]) [d setInteger:gSet.look forKey:k];
    else if ([k isEqual:@"compare"]) [d setInteger:gSet.compare forKey:k];
    else if ([k isEqual:@"hudRects"]) { if (gSet.hudN) [d setObject:@(hudRectsText().c_str()) forKey:k]; else [d removeObjectForKey:k]; }
    else if ([k isEqual:@"hudShow"]) [d setBool:gSet.hudShow forKey:k];
}
