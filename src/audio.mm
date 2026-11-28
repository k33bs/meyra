// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// audio comes in packets (one per video frame from decklink, ~10-20 ms chunks from avfoundation). the output callback
// reads the ring at a fractional position steered to stay `delay` behind the packet arrival clock: small errors are
// slewed (capture and output clocks drift apart slowly), big ones (delay changed, stall) fade out and re-seek.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include "audio.h"
#include "common.h"
#include "record.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <os/lock.h>

namespace audio {

static const int kRate = 48000;
static const int64_t kRing = 1 << 16;      // stereo frames, 1.36 s. covers the longest delay plus a couple of packets
static const double kSlew = 0.005;         // most the read speed may bend while steering, 0.5% is about 9 cents
static const double kJump = kSlew * kRate; // 5 ms. further off than this: fade and re-seek
static const double kMargin = 0.004;       // spare audio kept for a late packet, seconds

static float gRing[kRing * 2];
static std::atomic<int64_t> gW{0};         // frames written since start. the writer never waits, old audio is overwritten
static std::atomic<double> gEpoch{0};      // host time at which frame 0 would have arrived, smoothed. 0 = not known yet
static std::atomic<double> gDelay{0.03};
static std::atomic<bool> gMute{false};
static AudioUnit gAU;
static bool gUp;

// writer side, capture thread only
static double wEpoch;
static int wSeen, wOdd;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static Stats gS; // frames, packets, jitter under gLock
static std::atomic<int> gUnder{0}, gOver{0}, gResync{0}, gBuf{0};
static std::atomic<double> gLead{0}, gDelayNow{0};
static std::atomic<double> gInLag{0};     // how long after its timestamp a chunk arrives, decaying peak. ~0 when timestamps are arrival times
static std::atomic<double> gDevLat{0};  // output device latency after the render timestamp, seconds
static std::atomic<float> gOutPeak{0};     // what actually went to the speakers, render thread
static int64_t wNext = -1;                 // decklink packet time expected next, capture thread
static std::string gLine = "off"; // main thread
static std::string gInput;        // main thread: the input and how it was found, for the status line. empty if not known
static std::atomic<double> gLastIn{0}; // host time of the last packet pushed. "in step" only while packets come

static double hostNow() { return AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) * 1e-9; }
static inline float tap(int64_t i, int c) { return gRing[((i & (kRing - 1)) << 1) + c]; }

static OSStatus render(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *ts, UInt32, UInt32 n, AudioBufferList *io) {
    static double pos; // read position in frames
    static bool playing;
    float *out = (float *)io->mBuffers[0].mData;
    double now = hostNow();
    double th = (ts->mFlags & kAudioTimeStampHostTimeValid) ? AudioConvertHostTimeToNanos(ts->mHostTime) * 1e-9 : now; // when out[0] reaches the device
    int64_t w = gW.load();
    double epoch = gEpoch.load();
    double want = (th - gDelay.load() - epoch) * kRate; // the frame that should be reaching the device at th
    // readable: 4 point interpolation looks one back and two ahead, and the oldest stretch may be getting overwritten
    auto ok = [&](double p) { return epoch > 0 && p - 1 >= std::max<int64_t>(0, w - kRing + 2048) && p + n * (1 + kSlew) + 2 < w; };
    double step = 1;
    float g = 1, gStep = 0;
    bool leave = playing && fabs(pos - want) > kJump;
    if (leave) gStep = -1.0f / n; // fade out on the old position, re-seek on the next call
    else if (playing) step = 1 - std::clamp((pos - want) / kRate, -kSlew, kSlew); // error corrected with a 1 s time constant
    else if (ok(want + 48)) { pos = want; playing = true; g = 0; gStep = 1.0f / n; } // (re)start with a fade in, 1 ms spare
    if (!playing || !ok(pos)) {
        memset(out, 0, n * 2 * sizeof(float));
        record::sound(out, n, th + gDevLat.load(std::memory_order_relaxed));
        if (playing) { if (pos + n * (1 + kSlew) + 2 < w) gOver++; else gUnder++; } // lapped by the writer, or ran dry
        playing = false;
        return noErr;
    }
    bool mute = gMute;
    double p = pos;
    float peak = 0;
    for (UInt32 i = 0; i < n; i++, p += step, g += gStep) {
        int64_t k = (int64_t)p;
        float f = (float)(p - k);
        for (int c = 0; c < 2; c++) { // catmull-rom. plain linear dulls the top end as the fraction wanders
            float y0 = tap(k - 1, c), y1 = tap(k, c), y2 = tap(k + 1, c), y3 = tap(k + 2, c);
            float a = 0.5f * (y3 - y0) + 1.5f * (y1 - y2), b = y0 - 2.5f * y1 + 2 * y2 - 0.5f * y3, d = 0.5f * (y2 - y0);
            float v = (((a * f + b) * f + d) * f + y1) * g;
            out[i * 2 + c] = mute ? 0 : v;
            peak = fmaxf(peak, fabsf(v));
        }
    }
    if (!mute && peak > gOutPeak.load(std::memory_order_relaxed)) gOutPeak = peak;
    gDelayNow = th - epoch - pos / kRate;
    gLead = th - now;
    gBuf = n;
    pos = p;
    if (leave) { playing = false; gResync++; }
    record::sound(out, n, th + gDevLat.load(std::memory_order_relaxed)); // a copy into a ring, nothing more
    return noErr;
}

// arrival clock: when frame 0 would have arrived, averaged so one late packet does not move it.
// a few packets in a row that are way off mean the stream restarted, start over
static void clockIn(double t, int64_t w, long n, float pl, float pr, float rawPeak = 0, bool gap = false) {
    double raw = t - (double)w / kRate, dev = raw - wEpoch;
    if (!wSeen || (fabs(dev) > 0.02 && ++wOdd > 3)) { wEpoch = raw; wSeen = 1; wOdd = 0; dev = 0; }
    else if (fabs(dev) <= 0.02) { wOdd = 0; wSeen = std::min(wSeen + 1, 32); wEpoch += dev / wSeen; }
    gEpoch = wSeen >= 8 ? wEpoch : 0;
    gLastIn.store(hostNow(), std::memory_order_relaxed);
    os_unfair_lock_lock(&gLock);
    gS.frames += (int)n; gS.packets++;
    gS.jitterMs = fmax(gS.jitterMs, fabs(dev) * 1000);
    gS.peakL = fmax(gS.peakL, pl); gS.peakR = fmax(gS.peakR, pr);
    gS.rawPeak = fmax(gS.rawPeak, rawPeak);
    gS.gaps += gap;
    os_unfair_lock_unlock(&gLock);
}

void pushInt32(const int32_t *s, long n, int ch, double t, int64_t packetTime) {
    if (n <= 0 || ch < 2) return;
    const float k = 1.0f / 2147483648.0f;
    int64_t w = gW.load();
    float pl = 0, pr = 0;
    int32_t raw = 0; // loudest sample on any channel before the fold down: tells "silent source" from "lost in the mix"
    bool gap = packetTime >= 0 && wNext >= 0 && packetTime != wNext; // the device lost audio between packets
    if (packetTime >= 0) wNext = packetTime + n;
    for (long i = 0; i < n; i++, s += ch) {
        for (int c = 0; c < ch; c++) raw = std::max(raw, s[c] == INT32_MIN ? INT32_MAX : std::abs(s[c]));
        float l = s[0] * k, r = s[1] * k;
        if (ch >= 8) { // hdmi order fl fr lfe fc ls rs bl br. plain fold down, lfe left out. does nothing to a stereo source
            float c = 0.707f * s[3] * k;
            l += c + 0.707f * (s[4] * k + s[6] * k);
            r += c + 0.707f * (s[5] * k + s[7] * k);
            // the sum of a loud surround mix goes past full scale. turned down just far enough while it does, back up
            // over ~0.3 s: clipping it instead crackled. a stereo source never gets here, its gain stays 1
            static float gain = 1;
            float pk = fmaxf(fabsf(l), fabsf(r));
            gain = pk * gain > 1 ? 1 / pk : fminf(1, gain + (1 - gain) * 7e-5f);
            l *= gain; r *= gain;
        }
        float *d = gRing + (((w + i) & (kRing - 1)) << 1);
        d[0] = l; d[1] = r;
        pl = fmaxf(pl, fabsf(l)); pr = fmaxf(pr, fabsf(r));
    }
    gW = w + n;
    clockIn(t, w, n, pl, pr, raw * k, gap);
}

void pushFloat(const float *s, long n, int ch, double t) {
    if (n <= 0 || ch < 1) return;
    int64_t w = gW.load();
    float pl = 0, pr = 0;
    for (long i = 0; i < n; i++, s += ch) {
        float l = s[0], r = ch > 1 ? s[1] : s[0];
        float *d = gRing + (((w + i) & (kRing - 1)) << 1);
        d[0] = l; d[1] = r;
        pl = fmaxf(pl, fabsf(l)); pr = fmaxf(pr, fabsf(r));
    }
    gW = w + n;
    // sources that stamp chunks with capture time (avfoundation) deliver them late, sometimes by more than the whole
    // picture delay. the reader then asks for samples that are not here yet and stays silent, so this feeds the floor
    double lag = hostNow() - t, old = gInLag.load();
    if (lag > 0 && lag < 0.25) gInLag = old + (lag - old) * (lag > old ? 0.2 : 0.01); // quick up, slow down; a stall is not the norm
    clockIn(t, w, n, pl, pr, fmaxf(pl, pr));
}

void lost() { wSeen = 0; wNext = -1; }

void reset() {
    gEpoch = 0;
    gLastIn = 0;
    gInLag = 0;
    wSeen = wOdd = 0;
    wEpoch = 0;
    wNext = -1;
    // the reader treats epoch 0 as "not known" and stays silent, so the write position can restart safely
    gW = 0;
}

static UInt32 prop(AudioObjectID id, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeOutput) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 v = 0, sz = sizeof v;
    AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &v);
    return v;
}

static AudioObjectID outDevice() {
    AudioObjectID id = 0;
    UInt32 sz = sizeof id;
    if (gAU) AudioUnitGetProperty(gAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &sz);
    return id;
}

struct Dev { std::string name; UInt32 latency = 0, stream = 0; double rate = 0; };
static Dev devInfo(AudioObjectID id) {
    Dev d;
    if (!id) return d;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    AudioStreamID streams[32];
    UInt32 sz = sizeof streams;
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, streams) != noErr || sz < sizeof(AudioStreamID)) return d;
    CFStringRef name = NULL;
    a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    sz = sizeof name;
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &name) == noErr && name) d.name = ((__bridge_transfer NSString *)name).UTF8String ?: "";
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    sz = sizeof d.rate;
    AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &d.rate);
    d.latency = prop(id, kAudioDevicePropertyLatency);
    d.stream = prop(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
    return d;
}

// the default output unit follows the user's device choice and converts from our format to the device's
bool start(unsigned bufFrames) {
    if (gUp) return true;
    AudioComponentDescription cd = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &cd);
    if (!comp || AudioComponentInstanceNew(comp, &gAU) != noErr) return false;
    AudioStreamBasicDescription f = {(Float64)kRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked, 8, 1, 8, 2, 32, 0}; // interleaved stereo float
    AURenderCallbackStruct cb = {render, NULL};
    if (AudioUnitSetProperty(gAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
        AudioUnitSetProperty(gAU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr) {
        AudioComponentInstanceDispose(gAU); gAU = NULL;
        return false;
    }
    if (bufFrames) { // smaller io buffer = less delay. this is our process's io size on the device, other apps keep theirs
        AudioObjectPropertyAddress a = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 v = bufFrames;
        if (AudioObjectSetPropertyData(outDevice(), &a, 0, NULL, sizeof v, &v) != noErr) logLine("audio: the device kept its own buffer size");
    }
    if (AudioUnitInitialize(gAU) != noErr || AudioOutputUnitStart(gAU) != noErr) {
        AudioComponentInstanceDispose(gAU); gAU = NULL;
        return false;
    }
    gUp = true;
    return true;
}

void stop() {
    if (!gUp) return;
    AudioOutputUnitStop(gAU);
    AudioUnitUninitialize(gAU);
    AudioComponentInstanceDispose(gAU);
    gAU = NULL;
    gUp = false;
    gLine = "off";
}

bool running() { return gUp; }

void retarget(double videoDelay, double trim, bool mute) {
    gMute = mute;
    if (!gUp) { gLine = "off"; return; }
    Dev d = devInfo(outDevice());
    // the render timestamp already includes the io buffer and safety offset, only latency + stream come after it
    double dev = d.rate > 0 ? (d.latency + d.stream) / d.rate : 0;
    gDevLat = dev;
    // lowest delay that still has audio to read: how far ahead the device asks, one callback's worth, a late packet
    double floor = gLead.load() + gBuf.load() / (double)kRate + kMargin;
    if (floor < 0.004 || floor > 0.06) floor = 0.025; // output not running yet, or something odd
    floor += gInLag.load();
    double want = videoDelay + trim - dev;
    gDelay = fmax(floor, want);
    // the input it comes from and how it was found, then where it plays. nothing pushed for a second: no sound coming
    // in, whatever the clock still knows
    char b[400];
    bool coming = gEpoch.load() != 0 && hostNow() - gLastIn.load(std::memory_order_relaxed) < 1.0;
    std::string where = (gInput.empty() ? "" : "input: " + gInput + "; ") + "output: " + d.name;
    if (mute) snprintf(b, sizeof b, "muted");
    else if (!coming) snprintf(b, sizeof b, "no sound coming in (%s)", where.c_str());
    else if (want < floor - 0.004) snprintf(b, sizeof b, "%.0f ms behind the picture (%s)", (floor - want) * 1000, where.c_str());
    else snprintf(b, sizeof b, "in step with the picture (%s)", where.c_str());
    gLine = b;
}

void setInput(const std::string &name) { gInput = name; }

void setMute(bool m) { gMute = m; }

std::string statusLine() { return gLine; }

Stats takeStats() {
    os_unfair_lock_lock(&gLock);
    Stats s = gS;
    gS = Stats();
    os_unfair_lock_unlock(&gLock);
    s.underruns = gUnder.exchange(0);
    s.overruns = gOver.exchange(0);
    s.resyncs = gResync.exchange(0);
    s.delayMs = gDelay.load() * 1000;
    s.outPeak = gOutPeak.exchange(0);
    return s;
}

}
