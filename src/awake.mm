// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <Metal/Metal.h>
#include "awake.h"
#include "common.h"
#include <atomic>
#include <cmath>
#include <unistd.h>

namespace awake {

static std::atomic<double> gLast{0}, gJobMs{0};
static std::atomic<bool> gFront{false}, gRunning{false}, gQuit{false}, gStarted{false};
static const double kJobMs = 1.5, kPeriod = 0.002; // a longer job now and then holds the generator's work back a whole job, a thinner duty does not keep the clock up
static const double kIdle = 0.25;                  // seconds without a frame: no picture, let the gpu rest

static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void spin(device float *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
    "    float a = float(g) * 1e-6f, b = 1.0001f;\n"
    "    for (uint i = 0; i < n; i++) { a = fma(a, b, 1e-7f); b = fma(b, 0.99999f, 1e-6f); }\n"
    "    o[g & 1023] = a;\n}\n";

static void loop() {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:nil];
    id<MTLFunction> fn = [lib newFunctionWithName:@"spin"];
    id<MTLComputePipelineState> pipe = fn ? [dev newComputePipelineStateWithFunction:fn error:nil] : nil;
    id<MTLBuffer> buf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if (!q || !pipe || !buf) { logLine("gpu awake: could not be set up, off"); return; }
    double iters = 20000; // found as it goes: the same loop is quicker once the clock is up
    while (!gQuit) {
        bool want = gSet.gpuAwake && gFront && nowSec() - gLast.load() < kIdle;
        if (want != gRunning) { gRunning = want; logLine("gpu awake: %s", want ? "running" : "resting"); }
        if (!want) { usleep(50000); continue; }
        @autoreleasepool {
            double t = nowSec();
            uint32_t n = (uint32_t)iters;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pipe];
            [e setBuffer:buf offset:0 atIndex:0];
            [e setBytes:&n length:4 atIndex:1];
            [e dispatchThreads:MTLSizeMake(32, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
            gJobMs = ms;
            if (ms > 0.01) iters = fmin(5e7, fmax(100, iters * (0.8 + 0.2 * fmin(4, kJobMs / ms)))); // slowly: behind other gpu work a job takes longer without being longer
            double w = t + kPeriod - nowSec();
            if (w > 0) usleep((useconds_t)(w * 1e6));
        }
    }
}

void touch() {
    gLast = nowSec();
    if (gSet.gpuAwake && !gStarted.exchange(true)) {
        NSThread *th = [[NSThread alloc] initWithBlock:^{ loop(); }];
        th.qualityOfService = NSQualityOfServiceUserInitiated;
        th.name = @"gpu awake";
        [th start];
    }
}
void setFront(bool f) { gFront = f; }
bool running() { return gRunning; }
double jobMs() { return gJobMs; }
void stop() { gQuit = true; }

}
