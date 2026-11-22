// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Foundation/Foundation.h>
#include <functional>
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

struct Choice { std::string id, name; };   // an option in a submenu (format, connection, audio input)

struct SourceInfo {
    std::string id;        // "avf:<uniqueID>", "replay:<path>", or "<driver prefix>:<device>"
    std::string name;
    std::string group;     // "Capture devices", "Cameras"
    bool captureDevice = false; // counts for the "exactly one device" first-run rule
    std::vector<Choice> formats;     // system capture: sensible modes. a vendor driver: whatever it lets the user pick
    std::string defaultFormat;
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
    StatusFn onStatus;
protected:
    void report(SourceState s, const std::string &t) { if (onStatus) onStatus({s, t}); }
};

struct SourceOptions {
    std::string format;     // one of SourceInfo::formats, empty = default
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
std::vector<SourceInfo> listSources(std::vector<std::string> *hints = nullptr);

std::unique_ptr<Source> makeAVFSource(const std::string &id, const SourceOptions &o);
std::unique_ptr<Source> makeReplaySource(const std::string &path);
std::unique_ptr<Source> makeSource(const std::string &id, const SourceOptions &o);

// hot plug: called on the main thread whenever devices come or go
void watchDevices(std::function<void()> changed);
