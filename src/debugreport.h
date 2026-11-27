// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
// helper sections and privacy scrubbing for the copy debug report
#pragma once
#include <string>
@class NSScreen;
namespace debugreport {
std::string machine();                       // app version and build, macos, model identifier, chip, gpu, memory
std::string displays(NSScreen *windowScreen); // every screen; marks the one passed (nil: no window)
std::string settings();                      // "key = value" for every saved setting that differs from its default
std::string scrub(const std::string &s);     // privacy: see below
std::string shortId(const std::string &id);  // a source id as far as it may be shown
std::string idHash(const std::string &id);   // "#3fa2": tells two devices apart without showing the id
std::string access(bool commandLine);        // camera / microphone permission, whether the app's signature verifies
}
