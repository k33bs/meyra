// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Cocoa/Cocoa.h>
#include <string>

// matched display refresh: put the window's screen on a rate the source divides into evenly, for as long as the app
// runs. app-only display configuration, so macos restores the old mode when the app quits or crashes.
namespace display {

// mode: 0 leave alone, 1 auto (nothing while full screen on a variable refresh screen whose range holds the source rate, else only when the current rate is not a whole multiple of the source rate, then the
// fastest mode that is), 2 match the source rate itself
void apply(NSScreen *screen, double sourceFps, int mode, bool fullScreen);
void restore();
std::string status(); // for the overlay
bool variable();      // the screen follows the source by itself (variable refresh), nothing was switched

}
