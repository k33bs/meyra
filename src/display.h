// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
#pragma once
#import <Cocoa/Cocoa.h>
#include <string>

// matched display refresh: put the window's screen on a rate the source divides into evenly, for as long as the app
// runs. app-only display configuration, so macos restores the old mode when the app quits or crashes.
namespace display {

// mode: 0 leave alone, 1 auto (only when the current rate is not a whole multiple of the source rate, then the
// fastest mode that is), 2 match the source rate itself
void apply(NSScreen *screen, double sourceFps, int mode);
void restore();
std::string status(); // for the overlay

}
