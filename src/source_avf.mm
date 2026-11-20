// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
//
// ordinary capture devices through avfoundation: usb capture cards, and cameras. frames are asked for as 2vuy so the
// rest of the chain sees the same layout as from a decklink device; avfoundation converts where the device differs.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include "source.h"
#include "audio.h"
#include "common.h"
#include "renderer.h"
#include <atomic>
#include <map>

static NSArray<AVCaptureDevice *> *videoDevices() {
    NSArray *types = @[AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeContinuityCamera];
    return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices;
}

static NSArray<AVCaptureDevice *> *audioDevices() {
    return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified].devices;
}

struct Mode { int w, h; double fps; AVCaptureDeviceFormat *fmt; AVFrameRateRange *range; int rank; };

// the device's own pixel layout, best first. compressed formats need decoding and add delay
static int rankOf(FourCharCode c) {
    switch (c) {
    case kCVPixelFormatType_422YpCbCr8: return 0;
    case kCVPixelFormatType_422YpCbCr8_yuvs: return 1;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return 2;
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 2;
    case kCVPixelFormatType_32BGRA: return 3;
    default: return 5;
    }
}

static std::string modeId(int w, int h, double fps) {
    char b[48];
    snprintf(b, sizeof b, "%dx%d@%.2f", w, h, fps);
    return b;
}

// sensible modes only: landscape, at least 640x480, at least 24 fps. one entry per size and rate, the device's
// best native layout for it. sorted biggest and fastest first
static std::vector<Mode> modesOf(AVCaptureDevice *d) {
    std::map<std::string, Mode> best;
    for (AVCaptureDeviceFormat *f in d.formats) {
        CMVideoDimensions dm = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        if (dm.width < 640 || dm.height < 480 || dm.width < dm.height) continue;
        int rank = rankOf(CMFormatDescriptionGetMediaSubType(f.formatDescription));
        for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
            if (r.maxFrameRate < 23.9) continue;
            std::string k = modeId(dm.width, dm.height, r.maxFrameRate);
            auto it = best.find(k);
            if (it == best.end() || rank < it->second.rank) best[k] = {dm.width, dm.height, r.maxFrameRate, f, r, rank};
        }
    }
    std::vector<Mode> v;
    for (auto &kv : best) v.push_back(kv.second);
    std::sort(v.begin(), v.end(), [](const Mode &a, const Mode &b) {
        if (a.w * a.h != b.w * b.h) return a.w * a.h > b.w * b.h;
        return a.fps > b.fps;
    });
    return v;
}

// 1080p at the highest rate up to 60 if offered, else the biggest mode at its highest rate
static std::string defaultMode(const std::vector<Mode> &v) {
    const Mode *pick = nullptr;
    for (auto &m : v) if (m.w == 1920 && m.h == 1080 && m.fps < 61 && (!pick || m.fps > pick->fps)) pick = &m;
    if (!pick && !v.empty()) pick = &v[0];
    return pick ? modeId(pick->w, pick->h, pick->fps) : "";
}

std::vector<SourceInfo> listAVF(const std::vector<std::string> &vendorsWithDriver) {
    std::vector<SourceInfo> out;
    for (AVCaptureDevice *d in videoDevices()) {
        SourceInfo s;
        s.id = std::string("avf:") + d.uniqueID.UTF8String;
        s.name = d.localizedName.UTF8String ?: "Camera";
        // a device that also has a vendor driver is listed twice: through the driver, and here through the system
        // like any other card. say which is which
        for (auto &v : vendorsWithDriver)
            if ([d.manufacturer rangeOfString:@(v.c_str()) options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [d.localizedName rangeOfString:@(v.c_str()) options:NSCaseInsensitiveSearch].location != NSNotFound) { s.name += " (standard capture)"; break; }
        bool camera = d.continuityCamera || [d.deviceType isEqual:AVCaptureDeviceTypeBuiltInWideAngleCamera] || [d.deviceType isEqual:AVCaptureDeviceTypeContinuityCamera];
        s.group = camera ? "Cameras" : "Capture devices";
        s.captureDevice = !camera && s.name.find(" (standard capture)") == std::string::npos; // the driver entry counts, once
        if (camera) s.kind = "camera";
        s.pickAudio = true;
        auto modes = modesOf(d);
        for (auto &m : modes) {
            char n[64];
            snprintf(n, sizeof n, "%d × %d, %g fps", m.w, m.h, round(m.fps * 100) / 100);
            s.formats.push_back({modeId(m.w, m.h, m.fps), n});
        }
        s.defaultFormat = defaultMode(modes);
        out.push_back(s);
    }
    return out;
}

std::vector<Choice> listAVFAudioInputs() {
    std::vector<Choice> v;
    for (AVCaptureDevice *d in audioDevices()) v.push_back({d.uniqueID.UTF8String, d.localizedName.UTF8String ?: "?"});
    return v;
}

// the audio half of a capture card is a separate device. match it by name, or by a shared id prefix
static AVCaptureDevice *matchingAudio(AVCaptureDevice *video) {
    NSString *vid = video.uniqueID;
    NSRange colon = [vid rangeOfString:@":" options:NSBackwardsSearch];
    NSString *prefix = colon.location != NSNotFound ? [vid substringToIndex:colon.location] : nil;
    for (AVCaptureDevice *a in audioDevices()) {
        if ([a.localizedName isEqualToString:video.localizedName]) return a;
        if (prefix && [a.uniqueID hasPrefix:prefix]) return a;
    }
    return nil;
}

class AVFSource;
@interface MeyraCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, assign) AVFSource *owner;
@end

class AVFSource : public Source {
public:
    std::string id_;
    SourceOptions opt_;
    AVCaptureSession *session_ = nil;
    AVCaptureDevice *dev_ = nil;
    AVCaptureVideoDataOutput *vout_ = nil;
    AVCaptureAudioDataOutput *aout_ = nil;
    MeyraCaptureDelegate *del_ = nil;
    dispatch_queue_t sessionQ_ = dispatch_queue_create("capture session", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t videoQ_ = dispatch_queue_create("capture video", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_queue_t audioQ_ = dispatch_queue_create("capture audio", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    std::atomic<double> dur_{1.0 / 60};
    std::atomic<double> last_{0};
    std::atomic<bool> running_{false}, audioOn_{false};
    std::atomic<int> drops_{0};
    std::string signal_;
    std::vector<id> observers_;
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);

    AVFSource(const std::string &id, const SourceOptions &o) : id_(id), opt_(o) {}
    ~AVFSource() override { stop(); }
    double frameDuration() override { return dur_; }
    bool hasAudio() override { return audioOn_; }

    bool start(std::string &err) override {
        NSString *uid = @(id_.substr(4).c_str());
        dev_ = [AVCaptureDevice deviceWithUniqueID:uid];
        if (!dev_) { err = "The capture device is not connected."; return false; }
        AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted) {
            err = "Meyra is not allowed to use capture devices. Turn it on in System Settings > Privacy & Security > Camera.";
            return false;
        }
        if (st == AVAuthorizationStatusNotDetermined && !opt_.mayPrompt) { err = "Camera access has not been granted yet."; return false; }
        auto alive = alive_;
        report(SourceState::Starting, "Opening " + std::string(dev_.localizedName.UTF8String ?: ""));
        // the microphone question is asked here, before the session queue gets anything to do: asked from that
        // queue it blocked it until answered, and stop() waiting for the queue froze the app behind the prompt
        dispatch_queue_t q = sessionQ_; // by value: the answer can come after this source is gone
        SourceOptions opt = opt_;
        AVCaptureDevice *dev = dev_;
        auto go = [this, alive, q, opt, dev] { // `this` only on the session queue, behind the alive check
            void (^run)(BOOL) = ^(BOOL) { dispatch_async(q, ^{ if (*alive) configure(); }); };
            bool wanted = opt.audio && opt.audioInput != "none" && opt.mayPrompt;
            bool have = wanted && (opt.audioInput.empty() || opt.audioInput == "auto" ? matchingAudio(dev) : [AVCaptureDevice deviceWithUniqueID:@(opt.audioInput.c_str())]) != nil;
            bool ask = have && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined;
            if (ask) [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:run];
            else run(YES);
        };
        if (st == AVAuthorizationStatusNotDetermined) {
            report(SourceState::Starting, "Waiting for camera access");
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                if (!*alive) return;
                if (granted) go();
                else report(SourceState::Error, "Camera access was not granted. Turn it on in System Settings > Privacy & Security > Camera.");
            }];
        } else go();
        return true;
    }

    // session queue
    void configure() {
        AVCaptureDevice *audioDev = nil;
        if (opt_.audio && opt_.audioInput != "none") {
            audioDev = opt_.audioInput.empty() || opt_.audioInput == "auto" ? matchingAudio(dev_) : [AVCaptureDevice deviceWithUniqueID:@(opt_.audioInput.c_str())];
            if (audioDev && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
                logLine("avfoundation: no microphone access, picture only");
                audioDev = nil;
            }
        }
        session_ = [AVCaptureSession new];
        [session_ beginConfiguration];
        NSError *e = nil;
        AVCaptureDeviceInput *vin = [AVCaptureDeviceInput deviceInputWithDevice:dev_ error:&e];
        if (!vin || ![session_ canAddInput:vin]) {
            [session_ commitConfiguration];
            report(SourceState::Error, std::string("The capture device could not be opened") + (e ? ": " + std::string(e.localizedDescription.UTF8String) : "."));
            return;
        }
        [session_ addInput:vin];
        del_ = [MeyraCaptureDelegate new];
        del_.owner = this;
        vout_ = [AVCaptureVideoDataOutput new];
        vout_.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_422YpCbCr8)};
        vout_.alwaysDiscardsLateVideoFrames = YES;
        [vout_ setSampleBufferDelegate:del_ queue:videoQ_];
        if (![session_ canAddOutput:vout_]) {
            [session_ commitConfiguration];
            report(SourceState::Error, "The capture device cannot deliver frames to Meyra.");
            return;
        }
        [session_ addOutput:vout_];
        if (audioDev) {
            AVCaptureDeviceInput *ain = [AVCaptureDeviceInput deviceInputWithDevice:audioDev error:nil];
            if (ain && [session_ canAddInput:ain]) {
                [session_ addInput:ain];
                aout_ = [AVCaptureAudioDataOutput new];
                aout_.audioSettings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2,
                                        AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsNonInterleaved: @NO, AVLinearPCMIsBigEndianKey: @NO};
                [aout_ setSampleBufferDelegate:del_ queue:audioQ_];
                if ([session_ canAddOutput:aout_]) { [session_ addOutput:aout_]; audioOn_ = true; }
            }
        }
        // the chosen mode, or the default one
        auto modes = modesOf(dev_);
        std::string want = opt_.format.empty() ? defaultMode(modes) : opt_.format;
        const Mode *m = nullptr;
        for (auto &x : modes) if (modeId(x.w, x.h, x.fps) == want) m = &x;
        if (!m && !modes.empty()) { want = defaultMode(modes); for (auto &x : modes) if (modeId(x.w, x.h, x.fps) == want) m = &x; }
        if (m && [dev_ lockForConfiguration:nil]) {
            dev_.activeFormat = m->fmt;
            dev_.activeVideoMinFrameDuration = m->range.minFrameDuration;
            dev_.activeVideoMaxFrameDuration = m->range.minFrameDuration;
            [dev_ unlockForConfiguration];
            dur_ = 1.0 / m->fps;
            renderer::setFrameDur(dur_);
            char b[96];
            snprintf(b, sizeof b, "%d × %d @ %g", m->w, m->h, round(m->fps * 100) / 100);
            signal_ = b;
        }
        [session_ commitConfiguration];
        auto alive = alive_;
        id o1 = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:session_ queue:nil usingBlock:^(NSNotification *n) {
            if (!*alive) return;
            NSError *err = n.userInfo[AVCaptureSessionErrorKey];
            report(SourceState::Error, std::string("Capture stopped: ") + (err.localizedDescription.UTF8String ?: "unknown error"));
        }];
        id o2 = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:dev_ queue:nil usingBlock:^(NSNotification *) {
            if (*alive) report(SourceState::Gone, "The capture device was disconnected.");
        }];
        observers_ = {o1, o2};
        [session_ startRunning];
        running_ = true;
        logLine("avfoundation: %s started, %s, audio %s", dev_.localizedName.UTF8String, signal_.c_str(), audioOn_ ? "on" : "off");
        report(SourceState::Starting, signal_);
    }

    void stop() override {
        *alive_ = false;
        dispatch_sync(sessionQ_, ^{
            if (session_) [session_ stopRunning];
            [vout_ setSampleBufferDelegate:nil queue:NULL];
            [aout_ setSampleBufferDelegate:nil queue:NULL];
        });
        dispatch_sync(videoQ_, ^{}); // flush callbacks already queued
        dispatch_sync(audioQ_, ^{});
        for (id o : observers_) [NSNotificationCenter.defaultCenter removeObserver:o];
        observers_.clear();
        session_ = nil; vout_ = nil; aout_ = nil; del_ = nil; dev_ = nil;
        running_ = false;
    }

    void video(CMSampleBufferRef sb) {
        double now = nowSec();
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (!pb) return;
        double captured = hostTime(sb);
        double prev = last_.exchange(now);
        bool late = prev > 0 && now - prev > 1.5 * dur_.load();
        if (state_.exchange(1) != 1) report(SourceState::Running, signal_);
        CFRetain(pb);
        renderer::submit(pb, now, captured, late);
    }

    void audioIn(CMSampleBufferRef sb) {
        AudioBufferList abl;
        CMBlockBufferRef block = NULL;
        if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, NULL, &abl, sizeof abl, NULL, NULL, 0, &block) != noErr) return;
        long n = CMSampleBufferGetNumSamples(sb);
        if (abl.mNumberBuffers >= 1 && abl.mBuffers[0].mData) audio::pushFloat((const float *)abl.mBuffers[0].mData, n, (int)abl.mBuffers[0].mNumberChannels, hostTime(sb));
        if (block) CFRelease(block);
    }

    std::atomic<int> state_{0};

private:
    // presentation time on the host clock: when the device captured it, not when we got it
    double hostTime(CMSampleBufferRef sb) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        CMClockRef clock = session_.synchronizationClock;
        if (clock) pts = CMSyncConvertTime(pts, clock, CMClockGetHostTimeClock());
        double t = CMTimeGetSeconds(pts);
        double now = nowSec();
        return (t > now - 1 && t <= now + 0.001) ? t : now; // not plausible: fall back to arrival
    }
};

@implementation MeyraCaptureDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    AVFSource *o = self.owner;
    if (!o) return;
    if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) o->video(sb);
    else o->audioIn(sb);
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    if (self.owner) self.owner->drops_++;
}
@end

std::unique_ptr<Source> makeAVFSource(const std::string &id, const SourceOptions &o) { return std::make_unique<AVFSource>(id, o); }
