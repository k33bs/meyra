// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Foundation/Foundation.h>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

// one capture source. frames go to renderer::submit, audio to audio::push*. status changes go to the callback,
// which may be called on any thread.
enum class SourceState { Starting, Running, NoSignal, Error, Gone };

struct SourceStatus {
    SourceState state = SourceState::Starting;
    std::string text;      // human readable: signal description, or what went wrong
};
using StatusFn = std::function<void(const SourceStatus &)>;

// what a system capture device really delivers, counted at its callback since the last take (avf only)
struct CaptureCounts {
    int frames = 0;         // buffers with a picture
    int noImage = 0;        // buffers without one
    int late = 0, outOfBuffers = 0, discontinuity = 0, otherDrop = 0; // thrown away by avfoundation, by its reason
    int steps = 0;          // device timestamp steps measured: mean, median, 10th / 90th percentile, shortest, longest, seconds
    double stepMean = 0, stepMed = 0, stepLo = 0, stepHi = 0, stepMin = 0, stepMax = 0;
    double askedFps = 0, activeFps = 0, activeMinFps = 0; // read back from macos: the rate it runs, the lowest it may go to. 0 unknown
    bool mismatch = false;  // macos runs another size, layout or rate than was asked
    std::string asked, active; // "2vuy 1920x1080 @ 60.00"
    int drops() const { return late + outOfBuffers + discontinuity + otherDrop; }
};

struct Choice { std::string id, name; };   // an option in a submenu (format, connection, audio input)

struct SourceInfo {
    std::string id;        // "avf:<uniqueID>", "replay:<path>", or "<driver prefix>:<device>"
    std::string name;
    std::string group;     // "Capture devices", "Cameras"
    bool captureDevice = false; // counts for the "exactly one device" first-run rule
    std::vector<Choice> formats;     // system capture: sensible modes. a vendor driver: whatever it lets the user pick
    std::string defaultFormat;
    // system capture: a format the device also offers in a compressed layout besides the uncompressed one it gets by
    // default. format id -> {fourcc, "Compressed (MJPEG)"}. formats without a choice are not in it
    std::map<std::string, std::vector<Choice>> layouts;
    std::string kind = "capture device";   // shown next to the name in the picker
    std::string formatLabel = "Format";    // what `formats` are called for this source, e.g. "Input"
    std::string audioLabel;                // sound that comes with the picture, e.g. "Embedded (HDMI / SDI)". empty = none
    bool pickAudio = false;                // the user chooses a separate audio input (system capture)
};

class Source {
public:
    virtual ~Source() {}
    virtual bool start(std::string &err) = 0;
    virtual void stop() = 0;                     // blocks until no more callbacks
    virtual double frameDuration() = 0;          // seconds, best known
    virtual bool hasAudio() = 0;
    virtual bool takeCounts(CaptureCounts &) { return false; } // avf: what the device delivered since the last call. false: not counted
    StatusFn onStatus;
protected:
    void report(SourceState s, const std::string &t) { if (onStatus) onStatus({s, t}); }
};

struct SourceOptions {
    std::string format;     // one of SourceInfo::formats, empty = default
    std::string layout;     // avf: a fourcc from SourceInfo::layouts for that format, empty = the uncompressed one as always
    std::string audioInput; // avf: "auto", "none" or an audio device uniqueID
    bool audio = true;
    bool mayPrompt = true;  // allowed to ask for camera / microphone access
};

// a vendor driver: a faster or fuller path to one maker's devices than the system's capture interface gives.
// optional by design: every device also works through the system path, a driver only adds a second entry for it.
// to add one, write src/source_<name>.mm with a Source subclass and one of these, and list it in source.mm
struct Driver {
    const char *prefix;    // source ids are "<prefix>:<device>"
    const char *vendor;    // as it appears in the system's device names; used to label the system entry of the same device
    const char *missing;   // hint shown while the vendor's own software is not installed, or null if none is needed
    std::vector<SourceInfo> (*list)(bool &softwareFound);   // cheap enough to call when a menu opens
    std::unique_ptr<Source> (*make)(const std::string &id, const SourceOptions &o);
    void (*watch)(std::function<void()> changed);           // hot plug, or null
};
const std::vector<const Driver *> &drivers();
extern const Driver kDeckLinkDriver;

// enumeration. cheap enough to call when a menu opens. hints: one line per driver whose software is missing
std::vector<SourceInfo> listAVF(const std::vector<std::string> &vendorsWithDriver);
std::vector<Choice> listAVFAudioInputs();
std::vector<std::string> listAVFLayouts(const std::string &id); // every pixel layout per size and rate, for --list-devices
std::vector<SourceInfo> listSources(std::vector<std::string> *hints = nullptr);

std::unique_ptr<Source> makeAVFSource(const std::string &id, const SourceOptions &o);
std::unique_ptr<Source> makeReplaySource(const std::string &path);
std::unique_ptr<Source> makeSource(const std::string &id, const SourceOptions &o);

// hot plug: called on the main thread whenever devices come or go
void watchDevices(std::function<void()> changed);
