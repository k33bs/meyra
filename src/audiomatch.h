// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// system capture: which audio device is the sound half of a video device, on "automatic". plain strings, no apple
// types, so --self-test can walk it over devices that are not plugged in
#pragma once
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace audiomatch {

struct Dev { std::string name, uid, model; }; // an audio input: localizedName, uniqueID, modelID
struct Video {
    std::string name, uid, model;      // localizedName (not the menu name), uniqueID without "avf:", modelID
    std::string kind;                  // SourceInfo::kind: "camera" or "capture device"
    std::vector<std::string> linked;   // uniqueIDs of the audio devices macos links to it
};
struct Result { int index = -1; std::string how, why; }; // index into the list or -1; how it was found; why none

inline std::string lower(std::string s) { for (auto &c : s) c = (char)tolower((unsigned char)c); return s; }
inline bool hex(const std::string &s) { for (char c : s) if (!isxdigit((unsigned char)c)) return false; return !s.empty(); }

// "345f:2131" or "". macos names a uvc device "UVC Camera VendorID_13407 ProductID_8497" and builds its uniqueID from
// the usb location and vendor and product, 0x + up to 16 hex digits, leading zeros dropped: the last 8 are vid and pid
inline std::string videoUsb(const std::string &model, const std::string &uid) {
    size_t v = model.find("VendorID_"), p = model.find("ProductID_");
    if (v != std::string::npos && p != std::string::npos) {
        long a = strtol(model.c_str() + v + 9, nullptr, 10), b = strtol(model.c_str() + p + 10, nullptr, 10);
        if (a > 0 && a <= 0xffff && b >= 0 && b <= 0xffff) { char t[16]; snprintf(t, sizeof t, "%04lx:%04lx", a, b); return t; }
    }
    if (uid.size() >= 11 && uid.size() <= 18 && uid.compare(0, 2, "0x") == 0 && hex(uid.substr(2))) {
        std::string t = lower(uid.substr(uid.size() - 8));
        return t.substr(0, 4) + ":" + t.substr(4);
    }
    return "";
}

// "345f:2131" or "": a usb audio device's modelID ends in ":VID:PID" ("USB PnP Sound Device:0D8C:0166")
inline std::string audioUsb(const std::string &model) {
    if (model.size() < 10) return "";
    std::string t = model.substr(model.size() - 10);
    if (t[0] != ':' || t[5] != ':' || !hex(t.substr(1, 4)) || !hex(t.substr(6, 4))) return "";
    return lower(t.substr(1, 4) + ":" + t.substr(6, 4));
}

// a camera keeps its own microphone off on automatic: out of the speakers it feeds back. the built-in and iphone
// cameras by their kind, a usb webcam by a camera word in its name (macos lists it like any capture card)
inline bool cameraLike(const Video &v) {
    if (v.kind == "camera") return true;
    std::string n = lower(v.name);
    for (const char *w : {"camera", "webcam", "facecam", "kamera", "cam\xc3\xa9ra", "c\xc3\xa1mara", "c\xc3\xa2mera", "facetime"})
        if (n.find(w) != std::string::npos) return true;
    return false;
}

// the rules in order: macos' own link, the same name, the id up to its last colon (blackmagic), the same usb vendor and
// product, the card's name inside the audio id (AppleUSBAudioEngine:maker:product:...). the first rule with one hit
// wins. two or more hits narrow the list and the later rules go on within it: one left wins, none left after the last
// rule gives none and says which ones matched. never a microphone by default, never the default input
inline Result match(const Video &v, const std::vector<Dev> &a) {
    Result r;
    if (cameraLike(v)) {
        r.why = v.kind == "camera" ? "a camera: its own microphone is not taken on automatic, it would feed back on speakers"
                                   : "named like a webcam: its own microphone is not taken on automatic, it would feed back on speakers";
        return r;
    }
    size_t colon = v.uid.rfind(':');
    std::string prefix = colon == std::string::npos ? "" : v.uid.substr(0, colon), usb = videoUsb(v.model, v.uid), inId = ":" + v.name + ":";
    struct Step { const char *how; bool (*hit)(const Video &, const Dev &, const std::string &, const std::string &, const std::string &); };
    static const Step steps[] = {
        {"linked by macos", [](const Video &v, const Dev &d, const std::string &, const std::string &, const std::string &) {
            for (auto &l : v.linked) if (l == d.uid) return true;
            return false; }},
        {"same name", [](const Video &v, const Dev &d, const std::string &, const std::string &, const std::string &) { return !v.name.empty() && d.name == v.name; }},
        {"same id", [](const Video &, const Dev &d, const std::string &prefix, const std::string &, const std::string &) { return !prefix.empty() && d.uid.compare(0, prefix.size(), prefix) == 0; }},
        {"same usb vendor:product", [](const Video &, const Dev &d, const std::string &, const std::string &usb, const std::string &) { return !usb.empty() && audioUsb(d.model) == usb; }},
        {"card name in its id", [](const Video &v, const Dev &d, const std::string &, const std::string &, const std::string &inId) { return !v.name.empty() && d.uid.find(inId) != std::string::npos; }},
    };
    std::vector<int> left; // still in the running: all, then the hits of a rule that had more than one
    for (size_t i = 0; i < a.size(); i++) left.push_back((int)i);
    std::string tied;      // the rules that had more than one hit, in order
    for (auto &s : steps) {
        std::vector<int> hits;
        for (int i : left) if (s.hit(v, a[i], prefix, usb, inId)) hits.push_back(i);
        if (hits.size() == 1) { r.index = hits[0]; r.how = tied.empty() ? s.how : std::string(s.how) + ", of the ones alike by " + tied; return r; }
        if (hits.size() > 1) { left = hits; tied += (tied.empty() ? "" : " and ") + std::string(s.how); }
    }
    if (!tied.empty())
        r.why = std::to_string(left.size()) + " audio devices match by " + tied + " (" + a[left[0]].name + ", " + a[left[1]].name + "), which one is this card's cannot be told: choose it in source > audio input";
    else r.why = "found none for " + v.name + " (tried linked, name, id, usb vendor:product, name in id): choose one in source > audio input";
    return r;
}

// --self-test: prints each case, returns how many failed
inline int selfTest() {
    const Dev mbp{"MacBook Pro Microphone", "BuiltInMicrophoneDevice", "Digital Mic"};
    const Dev headset{"CORSAIR HS80 RGB Wireless Gaming Receiver", "AppleUSBAudioEngine:Corsair:CORSAIR HS80 RGB Wireless Gaming Receiver:3e581000:1", "CORSAIR HS80 RGB Wireless Gaming Receiver:1B1C:0A6B"};
    const Dev card{"USB3 Digital Audio", "AppleUSBAudioEngine:UltraSemi:USB3 Video:2c6a1000:3", "USB3 Video:345F:2131"};
    const Dev card2{"USB3 Digital Audio", "AppleUSBAudioEngine:UltraSemi:USB3 Video:2c6b1000:3", "USB3 Video:345F:2131"};
    const Dev cardNoModel{"USB3 Digital Audio", "AppleUSBAudioEngine:UltraSemi:USB3 Video:2c6a1000:3", ""};
    const Dev bmd{"Blackmagic UltraStudio Recorder 3G", "94:7d31f6a2:00000000:Audio", "UltraStudio Recorder 3G"};
    const Dev bmd2{"Blackmagic UltraStudio Recorder 3G", "94:52e0b9c7:00000000:Audio", "UltraStudio Recorder 3G"}; // a second unit
    const Dev pnp{"USB PnP Sound Device", "AppleUSBAudioEngine:C-Media Electronics Inc.:USB PnP Sound Device:3f2c5000:2", "USB PnP Sound Device:0D8C:0166"};
    const Dev phone{"iPhone Microphone", "5A3E9C21-7B40-4D8E-A1F6-3C9B0E7D2A17", "iPhone Mic"};
    const Dev c920{"HD Pro Webcam C920", "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:14100000:2", "HD Pro Webcam C920:046D:082D"};
    const Dev camlink{"Cam Link 4K", "AppleUSBAudioEngine:Elgato:Cam Link 4K:14200000:2", "Cam Link 4K:0FD9:0066"};
    const Video usb3{"USB3 Video", "0x3a9e40c345f2131", "UVC Camera VendorID_13407 ProductID_8497", "capture device", {}};
    Video usb3NoModel = usb3; usb3NoModel.model = "";
    const Video ultra{"Blackmagic UltraStudio Recorder 3G", "94:7d31f6a2:00000000:Video", "DeckLink", "capture device", {"94:7d31f6a2:00000000:Audio"}};
    Video ultraNoLink = ultra; ultraNoLink.linked.clear();
    const Video builtin{"MacBook Pro Camera", "4F2B8D10-3A6C-4E97-B5D1-8C0E6A29F347", "MacBook Pro Camera", "camera", {}};
    const Video iphone{"iPhone Camera", "5A3E9C21-7B40-4D8E-A1F6-3C9B0E7D2A15", "iPhone15,2", "camera", {"5A3E9C21-7B40-4D8E-A1F6-3C9B0E7D2A17"}};
    const Video webcam{"HD Pro Webcam C920", "0x14100000046d082d", "UVC Camera VendorID_1133 ProductID_2093", "capture device", {}};
    const Video camlinkV{"Cam Link 4K", "0x142000000fd90066", "UVC Camera VendorID_4057 ProductID_102", "capture device", {}};
    struct Case { const char *what; Video v; std::vector<Dev> a; int want; const char *how; };
    const Case cases[] = {
        {"usb3 video card: usb3 digital audio by usb vendor:product", usb3, {mbp, headset, card}, 2, "same usb vendor:product"},
        {"usb3 video card, audio model unknown: by its name in the audio id", usb3, {mbp, headset, cardNoModel}, 2, "card name in its id"},
        {"usb3 video card, video model unknown: vendor:product from the id", usb3NoModel, {card, mbp}, 0, "same usb vendor:product"},
        {"ultrastudio standard capture: linked audio", ultra, {pnp, bmd, mbp, phone}, 1, "linked by macos"},
        {"ultrastudio standard capture, no link: same name", ultraNoLink, {pnp, bmd, mbp}, 1, "same name"},
        {"built-in camera: none", builtin, {mbp, phone, headset}, -1, ""},
        {"iphone camera, its mic linked: none", iphone, {mbp, phone}, -1, ""},
        {"usb webcam with its own mic: none", webcam, {mbp, c920}, -1, ""},
        {"two alike ultrastudios, no link: the same name for both, the id tells", ultraNoLink, {bmd2, mbp, bmd}, 2, "same id, of the ones alike by same name"},
        {"the same, the other unit listed first", ultraNoLink, {bmd, mbp, bmd2}, 0, "same id, of the ones alike by same name"},
        {"two usb3 video cards plugged in: none", usb3, {card, mbp, card2}, -1, ""},
        {"headset as default input and output, no card audio: none", usb3, {headset, mbp}, -1, ""},
        {"cam link 4k is a card, not a camera: same name", camlinkV, {mbp, camlink}, 1, "same name"},
    };
    int bad = 0;
    for (auto &c : cases) {
        Result r = match(c.v, c.a);
        bool ok = r.index == c.want && (c.want < 0 ? !r.why.empty() : r.how == c.how);
        bad += !ok;
        printf("%s audio match: %s -> %s\n", ok ? "ok  " : "FAIL", c.what, r.index >= 0 ? (c.a[r.index].name + " (" + r.how + ")").c_str() : ("none: " + r.why).c_str());
    }
    bool two = match(usb3, {card, mbp, card2}).why.find("2 audio devices match by same usb vendor:product and card name in its id") == 0;
    printf("%s audio match: two alike cards nothing tells apart say so\n", two ? "ok  " : "FAIL");
    bad += !two;
    bool ids = videoUsb("", "0x3a9e40c345f2131") == "345f:2131" && videoUsb("UVC Camera VendorID_13407 ProductID_8497", "") == "345f:2131" &&
               audioUsb("USB3 Video:345F:2131") == "345f:2131" && audioUsb("Digital Mic") == "" && videoUsb("", "4F2B8D10-3A6C-4E97-B5D1-8C0E6A29F347") == "";
    printf("%s audio match: usb vendor:product from model and id\n", ids ? "ok  " : "FAIL");
    bad += !ids;
    return bad;
}

}
