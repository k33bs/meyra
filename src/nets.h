// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <Metal/Metal.h>

// small convolutional nets run as shader passes: luma in, luma out at twice the size, colour carried along.
// one text file of weights per net in Resources/nets (format: resources/nets/README.md), turned into metal source
// here. a file dropped into that folder is one more net, nothing else to write
namespace nets {

void load(NSString *dir);                    // read the weight files, before the menus are made. cheap: shaders are built on first use
int count();
const char *name(int n);                     // n from 1, as in the enhance setting
const char *status(int n);                   // "" when fine or not asked for yet, else "starting" or what is wrong
// the picture `src` (gamma rgb) through net n, as passes on cb. returns the result (at 2x, or the same size for a net that only restores), or nil while the net's
// shaders are still being built or when it cannot run. render thread only
// added (rg16f, the result's size): filled with what the net added to luma (r) and the luma it was given (g) instead, and handed back
id<MTLTexture> run(id<MTLCommandBuffer> cb, int n, id<MTLTexture> src, id<MTLTexture> added = nil);
int scale(int n);                            // 2: the result is twice the size, 1: the same size
int passes(int n);                           // render passes one run takes
bool half(int n);                            // netHalf is on, this net has layers it applies to and their shaders are built
bool halfApplies(int n);                     // net n has layers narrow enough for netHalf
void idle();                                 // not in use: let go of the textures

}
