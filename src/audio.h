// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#include <cstdint>
#include <string>

// captured audio -> ring -> default output device, held a set delay behind the arrival clock so it plays in step
// with the picture. the capture side never waits.
namespace audio {

bool start(unsigned ioFrames);   // output unit on the default device
void stop();
bool running();
void reset();                    // new source: forget the ring and the arrival clock. only while no source pushes

// t: host time (seconds) at which the first sample of this packet was captured or arrived
// packetTime: the device's stream position in frames at 48 kHz, -1 if unknown (used to count lost audio)
void pushInt32(const int32_t *s, long frames, int channels, double t, int64_t packetTime); // decklink, hdmi channel order
void pushFloat(const float *s, long frames, int channels, double t);   // interleaved float
void lost();                     // no signal: packets until the next push are not continuous

// once a second: aim the delay at (video capture -> glass) + trim - output device latency
void retarget(double videoDelay, double trim, bool mute);
void setMute(bool mute);
std::string statusLine();        // for the overlay
void setInput(const std::string &input); // main thread: the input and how it was found ("usb3 digital audio, auto: same name"), "" if not known

struct Stats {
    int frames = 0, packets = 0, underruns = 0, overruns = 0, resyncs = 0, gaps = 0;
    double jitterMs = 0, delayMs = 0;
    double peakL = 0, peakR = 0; // pushed stereo, after the fold down
    double rawPeak = 0;          // any input channel before the fold down
    double outPeak = 0;          // what was sent to the output device (0 while muted)
};
Stats takeStats();

}
