// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

// side bars (setting sideFill): what the window leaves free around the picture glows in the colours of the picture's
// edge next to it. render thread only. nothing is built before the first draw
namespace sidefill {
// the bars around vp (the picture, drawable pixels) on dst (the bgra8 drawable), in passes of their own after the
// picture's, from pic (what goes up now). a small copy of pic goes into the running mean they are drawn from first.
// the picture's own pixels are not touched: every draw has a viewport outside vp. mark: called with each render pass
// before it starts (stage times). no bars (the picture fills the window), no shaders or no memory: nothing is drawn
// all: where the whole picture is drawn, the same as vp but with the letterbox crop (then vp is the part that shows).
// fw x fh: the picture's size without the crop
// frame: the newest real frame from the source (2vuy or 420v, cpu readable), for the canvas (sideFill 3); may be NULL.
// real: pic is that frame's picture, not a generated one before it. the glow drawn is the one made after the frame
// before (at a new size: made now); the next is left for after()
void draw(id<MTLCommandBuffer> cb, id<MTLTexture> pic, CVPixelBufferRef frame, bool real, id<MTLTexture> dst, MTLViewport vp, MTLViewport all, double fw, double fh,
          void (^mark)(MTLRenderPassDescriptor *));
// after the frame's command buffer is committed: a command buffer (from q) with what draw() left, the small copy, the
// mips and the next glow, and the canvas's work on the new frame (cpu, then its strips), for the caller to commit
// right away. nil: nothing to do (off, grey, or draw not called since)
id<MTLCommandBuffer> after(id<MTLCommandQueue> q);
// letterbox crop (setting letterboxCrop): rows [top, bottom) of the source, H high, are the picture; it is at vp (the
// fit) in a dw x dh drawable. all: where the whole picture goes to make that band fill the drawable, past its edges;
// shown: the band's part of it inside the drawable, whole pixels. eased in over 200 ms, out at once. false: no crop
// (no band, or the band fills the window already)
bool zoom(int top, int bottom, int H, MTLViewport vp, double dw, double dh, MTLViewport &all, MTLViewport &shown, double *ease = nullptr);
// the same from the source frame itself: its band (letterbox.h) looked for in pb (2vuy or 420v; anything else: no
// crop), once a frame however often it is shown, then zoom
bool crop(CVPixelBufferRef pb, bool fullRange, MTLViewport vp, double dw, double dh, MTLViewport &all, MTLViewport &shown, double *ease = nullptr);
// the crop not wanted this frame (switched off, passthrough, a compare view): the detector forgets its band and holds,
// so it starts over with its full hold when it is back. nothing to do when it was not on
void cropOff();
// sides-only stretch (setting sideStretch): how wide the picture at vp gets, in widths of vp, for step 1, 2, 3 (a third,
// two thirds, all of the side bars filled). 1: no side bars, or step 0
double stretchWidth(int step, MTLViewport vp, double dw);
// the stretch by r on all (widened about its middle) and shown (its part in the drawable, whole pixels), and fsOutWarp's
// constants: the middle (|x| <= centre, in half widths) stays at the scale of the fit, the cubic of bjin's hyperview.hook
// past it. false: r too close to 1 to bother
bool stretch(double r, double centre, double dw, MTLViewport &all, MTLViewport &shown, float w[4]);
// the stretch's last pass (fsOut at the bent spot, w at buffer 1), made on the first call. nil: none, logged once
id<MTLRenderPipelineState> warpPipe(id<MTLDevice> dev);
}
