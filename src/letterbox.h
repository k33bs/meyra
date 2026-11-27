// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#include <cstddef>
#include <cstdint>

// letterbox crop (setting letterboxCrop): a wide picture with black bands above and below it, inside the source, told
// apart from a dark scene, so the renderer can scale the picture up to fill the screen. render thread only: one caller,
// state in statics, no locks, no allocation, no logging
namespace letterbox {
// the source's luma, one byte a pixel: p[y * stride + x * step]. 2vuy: p = base + 1, step 2. 420v: plane 0, step 1
struct Plane { const uint8_t *p; size_t stride, step, w, h; };
// rows [top, bottom) are the picture to show; top 0 and bottom h: all of it, no crop
struct Band { int top, bottom; };
// one real frame at time t (seconds, monotonic), once: a frame shown again or a generated one keeps the band it got.
// black: the luma of black, 16 video range, 0 full range
Band look(const Plane &y, double t, int black);
void seen(double t); // the frame last looked at is shown again at t: no pause, the gap rule leaves the crop alone
void reset(); // new source, size change, no signal, switch turned off
}
