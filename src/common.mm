// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <QuartzCore/QuartzCore.h>
#include "common.h"
#include <cstdarg>
#include <cstdio>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/lock.h>

Settings gSet;

static FILE *gLogFile;
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;

double nowSec() { return CACurrentMediaTime(); }

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

// keys in the user defaults. the argument domain (-key value on the command line) overrides them for one run
// without being saved, which is what the automated tests use
void settingsLoad() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{@"levels": @0, @"deband": @YES, @"upscale": @1, @"sharpen": @0.6, @"frameGen": @YES, @"early": @NO,
                          @"passthrough": @NO, @"audio": @YES, @"audioTrimMs": @0, @"refresh": @1, @"overlay": @YES,
                          @"checkUpdatesAtLaunch": @YES, @"srWithGen": @YES, @"srPad": @YES, @"vsync": @YES, @"gameMode": @YES}];
    gSet.levels = (int)[d integerForKey:@"levels"] % 3;
    gSet.deband = [d boolForKey:@"deband"];
    gSet.upscale = (int)[d integerForKey:@"upscale"] % 5;
    gSet.sharpen = fminf(1, fmaxf(0, [d floatForKey:@"sharpen"]));
    gSet.frameGen = [d boolForKey:@"frameGen"];
    gSet.early = [d boolForKey:@"early"];
    gSet.passthrough = [d boolForKey:@"passthrough"];
    gSet.audio = [d boolForKey:@"audio"];
    gSet.audioTrim = [d doubleForKey:@"audioTrimMs"] / 1000;
    gSet.refresh = (int)[d integerForKey:@"refresh"] % 3;
    gSet.overlay = [d boolForKey:@"overlay"];
    gSet.srWithGen = [d boolForKey:@"srWithGen"];
    gSet.srPad = [d boolForKey:@"srPad"];
    gSet.vsync = [d boolForKey:@"vsync"];
    gSet.colour = (int)[d integerForKey:@"colour"] % 3;
}

void settingsSave(const char *key) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *k = @(key);
    if ([k isEqual:@"levels"]) [d setInteger:gSet.levels forKey:k];
    else if ([k isEqual:@"deband"]) [d setBool:gSet.deband forKey:k];
    else if ([k isEqual:@"srPad"]) [d setBool:gSet.srPad forKey:k];
    else if ([k isEqual:@"vsync"]) [d setBool:gSet.vsync forKey:k];
    else if ([k isEqual:@"colour"]) [d setInteger:gSet.colour forKey:k];
    else if ([k isEqual:@"srWithGen"]) [d setBool:gSet.srWithGen forKey:k];
    else if ([k isEqual:@"upscale"]) [d setInteger:gSet.upscale forKey:k];
    else if ([k isEqual:@"sharpen"]) [d setFloat:gSet.sharpen forKey:k];
    else if ([k isEqual:@"frameGen"]) [d setBool:gSet.frameGen forKey:k];
    else if ([k isEqual:@"early"]) [d setBool:gSet.early forKey:k];
    else if ([k isEqual:@"passthrough"]) [d setBool:gSet.passthrough forKey:k];
    else if ([k isEqual:@"audio"]) [d setBool:gSet.audio forKey:k];
    else if ([k isEqual:@"audioTrimMs"]) [d setDouble:round(gSet.audioTrim * 1000) forKey:k];
    else if ([k isEqual:@"refresh"]) [d setInteger:gSet.refresh forKey:k];
    else if ([k isEqual:@"overlay"]) [d setBool:gSet.overlay forKey:k];
}
