// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// ordinary capture devices through avfoundation: usb capture cards, and cameras. frames are asked for as 2vuy so the
// rest of the chain sees the same layout as from a decklink device; avfoundation converts where the device differs.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include "source.h"
#include "audio.h"
#include "capcheck.h"
#include "common.h"
#include "renderer.h"
#include <algorithm>
#include <atomic>
#include <map>
#include <os/lock.h>

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

// compressed layouts that can be chosen instead (SourceOptions::layout): jpeg only, which the video output decodes
// itself. cheap usb cards often list uncompressed 1080p60 and deliver a third of it, their mjpeg 1080p60 a full 60
static bool jpegLike(FourCharCode c) { return c == 'dmb1' || c == 'jpeg' || c == 'mjpa' || c == 'mjpb' || c == 'AVDJ'; }
static std::string layoutName(FourCharCode c) { return jpegLike(c) ? "Compressed (MJPEG)" : "Compressed (" + fourcc(c) + ")"; }

// per mode of modesOf whose pick is uncompressed: the compressed formats offered at the same size and rate, one per
// fourcc, the first seen. modesOf itself is left as it was, so its pick never changes
static std::map<std::string, std::vector<Mode>> altsOf(AVCaptureDevice *d, const std::vector<Mode> &modes) {
    std::map<std::string, std::vector<Mode>> alt;
    std::map<std::string, int> pickRank;
    for (auto &m : modes) pickRank[modeId(m.w, m.h, m.fps)] = m.rank;
    for (AVCaptureDeviceFormat *f in d.formats) {
        FourCharCode c = CMFormatDescriptionGetMediaSubType(f.formatDescription);
        if (!jpegLike(c)) continue;
        CMVideoDimensions dm = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
            std::string k = modeId(dm.width, dm.height, r.maxFrameRate);
            auto p = pickRank.find(k);
            if (p == pickRank.end() || p->second >= 5) continue; // not listed, or already compressed: nothing to choose
            auto &v = alt[k];
            bool have = false;
            for (auto &x : v) have |= CMFormatDescriptionGetMediaSubType(x.fmt.formatDescription) == c;
            if (!have) v.push_back({dm.width, dm.height, r.maxFrameRate, f, r, 5});
        }
    }
    return alt;
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
        for (auto &kv : altsOf(d, modes))
            for (auto &m : kv.second) s.layouts[kv.first].push_back({fourcc(CMFormatDescriptionGetMediaSubType(m.fmt.formatDescription)), layoutName(CMFormatDescriptionGetMediaSubType(m.fmt.formatDescription))});
        out.push_back(s);
    }
    return out;
}

// every format the device reports, by size and rate, each with its layouts. * the one a format entry opens by default,
// + offered as a compressed layout. sizes and rates the menus leave out say why
std::vector<std::string> listAVFLayouts(const std::string &id) {
    std::vector<std::string> out;
    AVCaptureDevice *d = id.rfind("avf:", 0) == 0 ? [AVCaptureDevice deviceWithUniqueID:@(id.substr(4).c_str())] : nil;
    if (!d) return out;
    auto modes = modesOf(d);
    auto alts = altsOf(d, modes);
    struct Row { int w, h; double fps, lo; std::string k, cc; };
    std::vector<Row> rows;
    for (AVCaptureDeviceFormat *f in d.formats) {
        CMVideoDimensions dm = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        FourCharCode c = CMFormatDescriptionGetMediaSubType(f.formatDescription);
        for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
            std::string k = modeId(dm.width, dm.height, r.maxFrameRate), cc = fourcc(c);
            if (cc.find('?') != std::string::npos) { char h[16]; snprintf(h, sizeof h, "0x%08x", (unsigned)c); cc = h; } // a pixel format number, not letters
            for (auto &m : modes) if (m.fmt == f && m.range == r) cc += "*";
            auto a = alts.find(k);
            if (a != alts.end()) for (auto &m : a->second) if (m.fmt == f && m.range == r) cc += "+";
            rows.push_back({dm.width, dm.height, r.maxFrameRate, r.minFrameRate, k, cc});
        }
    }
    std::stable_sort(rows.begin(), rows.end(), [](const Row &a, const Row &b) {
        if (a.w * a.h != b.w * b.h) return a.w * a.h > b.w * b.h;
        if (a.w != b.w) return a.w > b.w; // 1760x1328 and 1328x1760: not mixed
        return a.fps > b.fps;
    });
    for (size_t i = 0; i < rows.size();) {
        auto &r = rows[i];
        char b[160];
        snprintf(b, sizeof b, "%dx%d @ %.2f", r.w, r.h, r.fps);
        std::string line = b, ranges;
        std::vector<std::string> seen; // a second format of the same size, rate and layout (another colour space) adds nothing here
        for (; i < rows.size() && rows[i].k == r.k; i++) {
            std::string one = rows[i].cc;
            if (rows[i].lo < rows[i].fps - 0.01) { snprintf(b, sizeof b, " (from %.2f)", rows[i].lo); one += b; }
            std::string bare = one;
            bare.erase(std::remove(bare.begin(), bare.end(), '*'), bare.end());
            bare.erase(std::remove(bare.begin(), bare.end(), '+'), bare.end());
            if (std::find(seen.begin(), seen.end(), bare) != seen.end() && one == bare) continue;
            seen.push_back(bare);
            line += " " + one;
        }
        if (r.w < 640 || r.h < 480) line += "   not offered: smaller than 640x480";
        else if (r.w < r.h) line += "   not offered: portrait";
        else if (r.fps < 23.9) line += "   not offered: under 24 fps";
        out.push_back(line);
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

// hidden test switches for capture the way some other apps do it, as launch arguments (-avfKeepLock YES) or saved
// defaults. all unset: the path as it always was, plus the read-back after start
//   avfEarly     format and rates set right after the device input, before the outputs are added
//   avfKeepLock  the device stays locked from setting the format until after startRunning (ffmpeg does this)
//   avfReapply   NO: never set again after start. always: set format and rates again after start even if macos runs them
//   avfOut       what the output asks for: 420v (and the device's own 420v format where it lists one at that size and
//                rate), 420f, native (the device's own layout if it is 2vuy or 420v/420f). frame generation, any rate and
//                the noise filter need 2vuy: with 420v/420f they stay idle
//   avfAll       all of the above: early, keep lock, reapply always, 420v
struct AvfDiag { bool early = false, keepLock = false; int reapply = 1; std::string out; }; // reapply: 0 never, 1 where it differs, 2 always
static AvfDiag avfDiag() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    AvfDiag g;
    bool all = [d boolForKey:@"avfAll"];
    g.early = all || [d boolForKey:@"avfEarly"];
    g.keepLock = all || [d boolForKey:@"avfKeepLock"];
    id r = [d objectForKey:@"avfReapply"];
    NSString *rs = [[r description] lowercaseString];
    g.reapply = all || [rs isEqual:@"always"] ? 2 : r && ![r boolValue] ? 0 : 1;
    NSString *o = [[d objectForKey:@"avfOut"] description];
    g.out = o.length ? o.lowercaseString.UTF8String : all ? "420v" : "";
    return g;
}
static std::string diagText(const AvfDiag &g) {
    std::string t;
    if (g.early) t += " early";
    if (g.keepLock) t += " keeplock";
    if (g.reapply != 1) t += g.reapply ? " reapply-always" : " reapply-off";
    if (!g.out.empty()) t += " out-" + g.out;
    return t;
}

static double durSec(CMTime t) { return CMTIME_IS_NUMERIC(t) && t.value > 0 && t.timescale > 0 ? CMTimeGetSeconds(t) : 0; }
static std::string fmtText(const capcheck::Fmt &f) {
    if (!f.w) return "nothing";
    char b[128];
    snprintf(b, sizeof b, "%s %dx%d @ %s", fourcc(f.cc).c_str(), f.w, f.h, f.minDur > 0 ? [NSString stringWithFormat:@"%.2f", 1 / f.minDur].UTF8String : "?");
    std::string t = b;
    if (f.maxDur > 0 && f.minDur > 0 && f.maxDur > f.minDur * 1.01) { snprintf(b, sizeof b, " (may go down to %.2f)", 1 / f.maxDur); t += b; }
    return t;
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
    std::string signal_;
    std::vector<id> observers_;
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);
    // what was asked (session queue): the format object, its rate, and the same as plain numbers for the comparison
    AVCaptureDeviceFormat *askedFmt_ = nil;
    CMTime askedDur_ = kCMTimeInvalid;
    capcheck::Fmt asked_;
    // counted on the capture queues, taken once a second (takeCounts), under cl_
    os_unfair_lock cl_ = OS_UNFAIR_LOCK_INIT;
    CaptureCounts c_;
    std::vector<double> steps_;
    double lastPts_ = -1;
    bool firstSeen_ = false;
    std::string askedText_, activeText_;
    double askedFps_ = 0, activeFps_ = 0, activeMinFps_ = 0;
    bool mismatch_ = false;

    AVFSource(const std::string &id, const SourceOptions &o) : id_(id), opt_(o) { steps_.reserve(512); }
    ~AVFSource() override { stop(); }
    double frameDuration() override { return dur_; }
    bool hasAudio() override { return audioOn_; }
    bool takeCounts(CaptureCounts &out) override {
        std::vector<double> v;
        v.reserve(512); // the capture queue gets this one: no allocation there
        os_unfair_lock_lock(&cl_);
        out = c_;
        c_ = CaptureCounts();
        std::swap(v, steps_);
        out.asked = askedText_; out.active = activeText_;
        out.askedFps = askedFps_; out.activeFps = activeFps_; out.activeMinFps = activeMinFps_;
        out.mismatch = mismatch_;
        os_unfair_lock_unlock(&cl_);
        capcheck::Steps s = capcheck::steps(std::move(v));
        out.steps = s.n; out.stepMean = s.mean; out.stepMed = s.med; out.stepLo = s.lo; out.stepHi = s.hi; out.stepMin = s.min; out.stepMax = s.max;
        return true;
    }

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
        AvfDiag dg = avfDiag();
        if (!diagText(dg).empty()) logPin("avfoundation: test switches%s", diagText(dg).c_str());
        // the chosen mode, or the default one. only worked out here: nothing is set on the device yet
        auto modes = modesOf(dev_);
        std::string want = opt_.format.empty() ? defaultMode(modes) : opt_.format;
        const Mode *m = nullptr;
        for (auto &x : modes) if (modeId(x.w, x.h, x.fps) == want) m = &x;
        if (!m && !modes.empty()) { want = defaultMode(modes); for (auto &x : modes) if (modeId(x.w, x.h, x.fps) == want) m = &x; }
        // a compressed layout chosen for this source: used where the mode offers it, else the mode as always
        std::map<std::string, std::vector<Mode>> alts;
        bool packed = false;
        if (m && !opt_.layout.empty()) {
            alts = altsOf(dev_, modes);
            for (auto &x : alts[modeId(m->w, m->h, m->fps)])
                if (fourcc(CMFormatDescriptionGetMediaSubType(x.fmt.formatDescription)) == opt_.layout) { m = &x; packed = true; break; }
        }
        // avfOut 420v: the device's own 420v format at the same size and rate, where it lists one
        Mode m420{};
        if (m && !packed && dg.out == "420v")
            for (AVCaptureDeviceFormat *f in dev_.formats) {
                CMVideoDimensions dm = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
                if (CMFormatDescriptionGetMediaSubType(f.formatDescription) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || dm.width != m->w || dm.height != m->h) continue;
                for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges)
                    if (fabs(r.maxFrameRate - m->fps) < 0.01) { m420 = {dm.width, dm.height, r.maxFrameRate, f, r, 2}; break; }
                if (m420.fmt) { m = &m420; break; }
            }
        // what the output asks for: 2vuy as always. the test switch only to what the renderer takes as it is
        OSType outFmt = kCVPixelFormatType_422YpCbCr8;
        if (!dg.out.empty()) {
            OSType nat = m ? CMFormatDescriptionGetMediaSubType(m->fmt.formatDescription) : 0;
            OSType w = dg.out == "420v" ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : dg.out == "420f" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : dg.out == "native" ? nat : 0;
            if (w == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || w == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) outFmt = w;
            logPin("avfoundation: output asks for %s%s", fourcc(outFmt).c_str(), w && w != outFmt ? " (the device's own layout is not one meyra shows)" : "");
        }
        bool held = false; // avfKeepLock: still locked, until after startRunning
        auto setFormat = [&] {
            if (!m) return;
            asked_ = {m->w, m->h, CMFormatDescriptionGetMediaSubType(m->fmt.formatDescription), durSec(m->range.minFrameDuration), durSec(m->range.minFrameDuration)};
            askedFmt_ = m->fmt;
            askedDur_ = m->range.minFrameDuration;
            NSError *le = nil;
            if (![dev_ lockForConfiguration:&le]) { // it then runs whatever macos picks: the read-back after start says what
                logPin("avfoundation: the device refused the lock (%s)", le.localizedDescription.UTF8String ?: "no reason given");
                return;
            }
            @try {
                dev_.activeFormat = m->fmt;
                dev_.activeVideoMinFrameDuration = m->range.minFrameDuration;
                dev_.activeVideoMaxFrameDuration = m->range.minFrameDuration;
            } @catch (NSException *x) {
                logPin("avfoundation: setting the format failed: %s", x.reason.UTF8String ?: "?");
            }
            if (dg.keepLock) held = true;
            else [dev_ unlockForConfiguration];
            dur_ = 1.0 / m->fps;
            renderer::setFrameDur(dur_);
            char b[96];
            snprintf(b, sizeof b, "%d × %d @ %g%s", m->w, m->h, round(m->fps * 100) / 100, packed ? ", mjpeg" : "");
            signal_ = b;
        };
        if (dg.early) setFormat();
        del_ = [MeyraCaptureDelegate new];
        del_.owner = this;
        vout_ = [AVCaptureVideoDataOutput new];
        vout_.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(outFmt)};
        vout_.alwaysDiscardsLateVideoFrames = YES;
        [vout_ setSampleBufferDelegate:del_ queue:videoQ_];
        if (![session_ canAddOutput:vout_]) {
            if (held) [dev_ unlockForConfiguration];
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
        if (!dg.early) setFormat();
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
        if (held) [dev_ unlockForConfiguration];
        running_ = true;
        logPin("avfoundation: %s started, %s, audio %s%s", dev_.localizedName.UTF8String, signal_.c_str(), audioOn_ ? "on" : "off",
               ![vout_.availableVideoCVPixelFormatTypes containsObject:@(outFmt)] ? [NSString stringWithFormat:@", %s not offered by the output", fourcc(outFmt).c_str()].UTF8String : "");
        // macos can run another format or rate than was set (it may reset them at start): read back, set again where
        // it differs. where it runs what was asked nothing is set a second time. once more a second later
        verify("after start", dg.reapply);
        AVCaptureSession *s = session_;
        int again = dg.reapply == 2 ? 1 : dg.reapply;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), sessionQ_, ^{
            if (*alive && session_ == s) verify("a second later", again); // `this` only behind the alive check
        });
        report(SourceState::Starting, signal_);
    }

    // session queue. what macos runs against what was asked, as one log line. mode 0: only look, 1: set again where
    // size, layout or rate differ, 2: set again anyway. at most three tries
    capcheck::Fmt readBack() {
        capcheck::Fmt f;
        if (AVCaptureDeviceFormat *af = dev_.activeFormat) {
            CMVideoDimensions dm = CMVideoFormatDescriptionGetDimensions(af.formatDescription);
            f.w = dm.width; f.h = dm.height;
            f.cc = CMFormatDescriptionGetMediaSubType(af.formatDescription);
        }
        f.minDur = durSec(dev_.activeVideoMinFrameDuration);
        f.maxDur = durSec(dev_.activeVideoMaxFrameDuration);
        return f;
    }
    void verify(const char *tag, int mode) {
        if (!dev_ || !askedFmt_) return;
        capcheck::Fmt now = readBack();
        int d = capcheck::differs(asked_, now);
        std::string a = fmtText(asked_), was = fmtText(now);
        if (mode == 0 || (mode == 1 && !capcheck::runsOther(d))) {
            logPin("avfoundation: %s: asked %s, macos runs %s%s", tag, a.c_str(), capcheck::runsOther(d) || (d & capcheck::kMaxDur) ? was.c_str() : "the same",
                   capcheck::runsOther(d) ? " (not set again: avfReapply off)" : "");
            publish(now, d);
            return;
        }
        int tries = 0;
        std::string why;
        do {
            NSError *le = nil;
            if (![dev_ lockForConfiguration:&le]) { why = std::string(", lock refused: ") + (le.localizedDescription.UTF8String ?: "no reason given"); break; }
            @try {
                // only durations off: the format stays, setting it again would restart the device's stream
                if (mode == 2 || (d & (capcheck::kSize | capcheck::kLayout)) || ![dev_.activeFormat isEqual:askedFmt_]) dev_.activeFormat = askedFmt_;
                dev_.activeVideoMinFrameDuration = askedDur_;
                dev_.activeVideoMaxFrameDuration = askedDur_;
            } @catch (NSException *x) {
                why = std::string(", refused: ") + (x.reason.UTF8String ?: "?");
            } @finally {
                [dev_ unlockForConfiguration];
            }
            tries++;
            now = readBack();
            d = capcheck::differs(asked_, now);
        } while (tries < 3 && why.empty() && capcheck::runsOther(d));
        logPin("avfoundation: %s: asked %s, macos runs %s, after reapply %s (%d %s)%s", tag, a.c_str(), was.c_str(),
               capcheck::runsOther(d) ? fmtText(now).c_str() : "as asked", tries, tries == 1 ? "try" : "tries", why.c_str());
        publish(now, d);
    }
    void publish(const capcheck::Fmt &now, int d) {
        os_unfair_lock_lock(&cl_);
        askedText_ = fmtText(asked_);
        activeText_ = fmtText(now);
        askedFps_ = asked_.minDur > 0 ? 1 / asked_.minDur : 0;
        activeFps_ = now.minDur > 0 ? 1 / now.minDur : 0;
        activeMinFps_ = now.maxDur > 0 ? 1 / now.maxDur : 0;
        mismatch_ = capcheck::runsOther(d);
        os_unfair_lock_unlock(&cl_);
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
        // the device's own timestamp as it came, for the capture clock (ptsTime): only its steps are used
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        double p = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : -1;
        bool first = false;
        os_unfair_lock_lock(&cl_); // what the device delivers, before anything here looks at it
        if (!pb) c_.noImage++;
        else {
            c_.frames++;
            if (p >= 0 && lastPts_ >= 0 && p > lastPts_ && steps_.size() < steps_.capacity()) steps_.push_back(p - lastPts_);
            if (p >= 0) lastPts_ = p;
            first = !firstSeen_;
            firstSeen_ = true;
        }
        os_unfair_lock_unlock(&cl_);
        if (!pb) return;
        if (first) logPin("avfoundation: first frame %zux%zu %s", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), fourcc(CVPixelBufferGetPixelFormatType(pb)).c_str());
        double captured = hostTime(sb);
        double prev = last_.exchange(now);
        bool late = prev > 0 && now - prev > 1.5 * dur_.load();
        if (state_.exchange(1) != 1) report(SourceState::Running, signal_);
        CFRetain(pb);
        renderer::submit(pb, now, captured, late, p);
    }

    // a frame avfoundation threw away, with its reason
    void dropped(CMSampleBufferRef sb) {
        CFTypeRef r = CMGetAttachment(sb, kCMSampleBufferAttachmentKey_DroppedFrameReason, NULL);
        os_unfair_lock_lock(&cl_);
        if (r && CFEqual(r, kCMSampleBufferDroppedFrameReason_FrameWasLate)) c_.late++;
        else if (r && CFEqual(r, kCMSampleBufferDroppedFrameReason_OutOfBuffers)) c_.outOfBuffers++;
        else if (r && CFEqual(r, kCMSampleBufferDroppedFrameReason_Discontinuity)) c_.discontinuity++;
        else c_.otherDrop++;
        os_unfair_lock_unlock(&cl_);
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
    if (self.owner && [output isKindOfClass:AVCaptureVideoDataOutput.class]) self.owner->dropped(sb);
}
@end

std::unique_ptr<Source> makeAVFSource(const std::string &id, const SourceOptions &o) { return std::make_unique<AVFSource>(id, o); }
