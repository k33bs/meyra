// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

// side bars, canvas (sideFill 3): what the picture showed beside its left and right edge a moment ago, carried along
// with the picture's own motion out into the bar, over the glow. an experiment. render thread only, nothing built
// before the first call. sidefill.mm calls it, after it has made the glow
namespace canvas {
// in the frame's own command buffer, before its present: the bars at left and right (drawable px, either may be
// empty) on dst (bgra8; the picture already drawn at vp, the whole picture at the fit: no crop, no stretch), read
// only, from what the canvas holds and the motion known so far, carried on to now. glow: the glow for the whole
// drawable at an eighth a side (rgba16f), what to fall back to; it was made a frame ago. dim: 1 - sideDim. mark:
// called with each render pass before it starts (stage times). no cpu work beyond a few numbers, no allocation.
// false: nothing drawn, the caller draws the glow
bool bars(id<MTLCommandBuffer> cb, id<MTLTexture> dst, MTLViewport vp, MTLViewport left, MTLViewport right, id<MTLTexture> glow, float dim,
          void (^mark)(MTLRenderPassDescriptor *));
// after the frame's command buffer is committed, off the frame's path: a new real frame's motion (cpu) and, when pic is
// that frame's picture (real; else a generated one before it, never written), its strips written into the canvas, in
// cb (a command buffer of its own, committed by the caller after this). frame: the newest real source frame, 2vuy or
// 420v, cpu readable, may be NULL. vp, left, right: as given to bars() for this frame. no allocation once running
void after(id<MTLCommandBuffer> cb, id<MTLTexture> pic, CVPixelBufferRef frame, bool real, MTLViewport vp, MTLViewport left, MTLViewport right);
void reset(); // forget everything: the next call starts over
}
