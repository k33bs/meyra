// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
// helper sections and privacy scrubbing for the copy debug report
#pragma once
#include <string>
#include <vector>
@class NSScreen;
namespace debugreport {
std::string machine();                       // app version and build, macos, model identifier, chip, gpu, memory
std::string displays(NSScreen *windowScreen); // every screen; marks the one passed (nil: no window)
std::string settings();                      // "key = value" for every saved setting that differs from its default
std::string scrub(const std::string &s);     // privacy: see below
std::string scrubName(const std::string &s); // the same for a bare device name: an owner after it goes to the end
std::string scrubKnown(const std::string &s, std::vector<std::string> names); // scrub, the names given replaced by their scrubName first
int scrubTest();                             // --self-test: prints each case, returns how many failed
int settingsTest();                          // --self-test: which saved values count as changed, the per-source labels
std::string shortId(const std::string &id);  // a source id as far as it may be shown
std::string idHash(const std::string &id);   // "#3fa2": tells two devices apart without showing the id
std::string access(bool commandLine);        // camera / microphone permission, whether the app's signature verifies
}
