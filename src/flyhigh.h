// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once
#import <CoreVideo/CoreVideo.h>

// the second frame generator (genModel 1, 2): a small flow net on the gpu. the net is not part of meyra: its op
// graph, tensor list and weights are three files the user puts in ~/Library/Application Support/Meyra/flyhighfg/
// (graph.json, flyhighfg.json, flyhighfg.bin). nothing of them is in this source, the graph is read and built at
// start. what is here is the meaning of each op name and the two passes around the net, see THIRD_PARTY_NOTICES.md
#include <string>

namespace flyhigh {

bool installed();     // the three files are there and have not been refused. cheap, any thread
const char *note();   // why not: "frame generator files not installed", or what was wrong with them. "" when fine
// fetches the files from their own project at one fixed commit, checked against the checksums in flyhigh.mm, into an
// empty or incomplete folder only. only ever called after the user has seen the licence and said yes. done on the main
// queue, with what went wrong or ""
void download(void (^done)(const std::string &err));
bool downloading();
bool complete();      // all three files are there, usable or not
void retry();         // forget a refusal (the user chose the generator again, the files may be new)
// generator thread only. start: read the files, build the net for this picture size and working size (rung: the
// net's own input height, 480 or 720), run it once so the first real pair does not pay for the compile
bool start(int w, int h, int rung);
void stop();
// prev, cur, dst: 420v, w x h. full / sd: the range and matrix of the values in them (meyra hands capture values on
// as they came). dst comes back holding the frame halfway between the two
bool generate(CVPixelBufferRef prev, CVPixelBufferRef cur, CVPixelBufferRef dst, bool full, bool sd);

}
