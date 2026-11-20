// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#pragma once
#import <Foundation/Foundation.h>
#include <string>
#include <vector>

// updates from the project's github releases: ask releases/latest, download the Meyra-*.zip asset, check it, unpack,
// validate, swap the app bundle in place, keep the old one for a revert, relaunch.
namespace update {

struct Release {
    std::string tag, notes, assetName, assetURL, sha256; // sha256: first 64 hex digits in the notes, or empty
    std::vector<int> version;
    long long size = 0;                                  // as announced by github
};

bool parseVersion(const std::string &s, std::vector<int> &v); // "v1.0.10" -> {1,0,10}
int compareVersions(const std::vector<int> &a, const std::vector<int> &b); // <0, 0, >0. missing parts count as 0
std::string versionString(const std::vector<int> &v);          // "v1.0.10"
bool parseRelease(NSData *json, Release &r, std::string &err);
std::string bundleVersion(NSURL *app);                         // CFBundleShortVersionString of that bundle

// main queue callbacks. url empty = the project's releases api
struct CheckResult { bool ok = false, newer = false; Release release; std::string message; };
void check(const std::string &url, void (^done)(const CheckResult &));

// "" when the running app can be replaced where it is, else what is in the way, in words for the user
std::string locationProblem(NSURL *app);

// download (size capped), checksum, unpack, validate, swap. done("") means installed and ready to relaunch
void install(const Release &r, void (^progress)(double fraction), void (^done)(const std::string &err));
bool previousVersion(std::string &version);                    // a kept previous bundle exists
std::string revert();                                          // "" = reverted, ready to relaunch
void relaunch();                                               // start the bundle again once this process has quit

// steps, also driven by the --update-test flags against local files and a copy of the app
bool verifySha256(NSURL *file, const std::string &hex, std::string &err);
NSURL *unpack(NSURL *zip, const Release &r, NSURL *app, std::string &err);  // validated bundle staged on the app's volume
bool swapIn(NSURL *app, NSURL *staged, NSURL *keptDir, std::string &err);
bool revertIn(NSURL *app, NSURL *keptDir, std::string &err);
int selfTest(const std::vector<std::string> &args);             // exit code

}
