// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
//
// replay: plays a folder of raw uyvy frames (PREFIX_f000.uyvy, PREFIX_f001.uyvy ...) at 59.94 in a loop, as if they
// came from a capture device. for testing the whole chain on known footage and for demos
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include "source.h"
#include "common.h"
#include "renderer.h"
#include <atomic>
#include <unistd.h>

static const double kDur = 1001.0 / 60000;

// a folder (first prefix in it), one of the frame files, or the prefix itself
static std::string resolvePrefix(const std::string &path) {
    NSString *p = [@(path.c_str()) stringByExpandingTildeInPath];
    BOOL dir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && dir) {
        NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:p error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *f in files)
            if ([f hasSuffix:@"_f000.uyvy"]) return [p stringByAppendingPathComponent:[f substringToIndex:f.length - 10]].UTF8String;
        return "";
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"_f\\d+\\.uyvy$" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:p options:0 range:NSMakeRange(0, p.length)];
    if (m) return [p substringToIndex:m.range.location].UTF8String;
    return p.UTF8String;
}

class ReplaySource : public Source {
    std::string path_;
    std::vector<CVPixelBufferRef> frames_;
    std::atomic<bool> quit_{false};
    dispatch_semaphore_t done_ = dispatch_semaphore_create(0);
    bool started_ = false;
public:
    explicit ReplaySource(const std::string &p) : path_(p) {}
    ~ReplaySource() override { stop(); }
    double frameDuration() override { return kDur; }
    bool hasAudio() override { return false; }

    bool start(std::string &err) override {
        std::string prefix = resolvePrefix(path_);
        if (prefix.empty() || ![NSFileManager.defaultManager fileExistsAtPath:@((prefix + "_f000.uyvy").c_str())]) {
            err = "No replay frames (NAME_f000.uyvy) found at " + path_;
            return false;
        }
        report(SourceState::Starting, "Loading replay frames");
        started_ = true;
        NSThread *th = [[NSThread alloc] initWithBlock:^{ run(prefix); }];
        th.qualityOfService = NSQualityOfServiceUserInteractive;
        th.name = @"replay";
        [th start];
        return true;
    }

    void stop() override {
        if (!started_) return;
        started_ = false;
        quit_ = true;
        dispatch_semaphore_wait(done_, DISPATCH_TIME_FOREVER);
        for (CVPixelBufferRef f : frames_) CFRelease(f);
        frames_.clear();
    }

private:
    void run(const std::string &prefix) {
        int W = 0, H = 0;
        for (int i = 0; !quit_; i++) {
            @autoreleasepool {
                NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%s_f%03d.uyvy", prefix.c_str(), i] options:NSDataReadingMappedIfSafe error:nil];
                if (!d) break;
                if (!W) { // raw frames carry no header: tell the size from the length
                    const int sizes[][2] = {{1920, 1080}, {1280, 720}, {3840, 2160}, {2560, 1440}};
                    for (auto &s : sizes) if (d.length == (NSUInteger)s[0] * s[1] * 2) { W = s[0]; H = s[1]; }
                    if (!W) break;
                }
                if (d.length != (NSUInteger)W * H * 2) break;
                NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
                CVPixelBufferRef pb = NULL;
                if (CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_422YpCbCr8, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) break;
                CVPixelBufferLockBaseAddress(pb, 0);
                uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
                size_t rb = CVPixelBufferGetBytesPerRow(pb);
                for (int y = 0; y < H; y++) memcpy(dst + y * rb, (const uint8_t *)d.bytes + (size_t)y * W * 2, (size_t)W * 2);
                CVPixelBufferUnlockBaseAddress(pb, 0);
                frames_.push_back(pb);
            }
        }
        if (frames_.empty() || quit_) {
            if (!quit_) report(SourceState::Error, "Replay frames could not be read (expected raw 1920x1080 UYVY)");
            dispatch_semaphore_signal(done_);
            return;
        }
        logLine("replay: %zu frames %dx%d from %s", frames_.size(), W, H, prefix.c_str());
        report(SourceState::Running, [NSString stringWithFormat:@"Replay %dx%d @ 59.94, %zu frames", W, H, frames_.size()].UTF8String);
        makeRealtime(kDur); // paced by sleeping, so it needs on-time wake-ups
        double next = nowSec();
        for (size_t i = 0; !quit_; i++) {
            next += kDur;
            double wait = next - nowSec();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
            CVPixelBufferRef f = frames_[i % frames_.size()];
            CFRetain(f);
            double now = nowSec();
            renderer::submit(f, now, now, now - next > 0.003); // late = missed our own deadline
        }
        dispatch_semaphore_signal(done_);
    }
};

std::unique_ptr<Source> makeReplaySource(const std::string &path) { return std::make_unique<ReplaySource>(path); }
