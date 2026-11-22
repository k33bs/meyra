// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#pragma once

// gpuAwake: the gpu clocks down between frames, and the same work then takes two to three times as long when the
// next frame comes (measured on the second generator: 5.5 ms a frame, 2.6 with the gpu kept busy; research/speed-gen.md).
// macos has no way to ask for the clock, so this keeps a little work on it: one group of 32 threads spinning for
// about 1.5 ms out of every 2, on a queue of its own. the other cores stay free. it costs power for as long as it
// runs, apple calls the trick wasteful, and an os update can stop it working: a setting, off unless chosen
namespace awake {

void touch();          // render thread, every captured frame while a net or the second generator works on the picture. the job runs while these keep coming, the setting is on and the app is in front
void setFront(bool f); // main thread: meyra is the active app
bool running();
double jobMs();        // gpu time of the last job
void stop();           // at quit

}
