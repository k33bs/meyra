// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// blackmagic decklink / ultrastudio capture through the desktop video sdk. frames arrive as iosurface backed 2vuy
// pixel buffers that go into metal without a copy. no camera permission needed. the runtime is loaded on demand
// from /Library/Frameworks; without it this source simply lists nothing.
#import <Foundation/Foundation.h>
#include "DeckLinkAPI.h"
#include "source.h"
#include "audio.h"
#include "common.h"
#include "renderer.h"
#include <atomic>
#include <memory>

static std::string cfStr(CFStringRef s) {
    if (!s) return "";
    std::string r = ((__bridge NSString *)s).UTF8String ?: "";
    CFRelease(s);
    return r;
}

// 8 bit 4:2:2 for a yuv signal. an rgb signal (the xbox at 720p) has to be asked for as rgb: asked for as yuv the
// ultrastudio recorder 3g reports no signal and falls back to announcing 1080p, round and round. those frames are
// converted to 4:2:2 here, so frame generation and the analysis still see one layout
static BMDPixelFormat pixFor(BMDDetectedVideoInputFormatFlags f) { return (f & bmdDetectedVideoInputRGB444) ? bmdFormat8BitBGRA : bmdFormat8BitYUV; }

static const struct { BMDVideoConnection bit; const char *id, *name; } kConn[] = {
    {bmdVideoConnectionHDMI, "hdmi", "HDMI"}, {bmdVideoConnectionSDI, "sdi", "SDI"}, {bmdVideoConnectionOpticalSDI, "optical", "Optical SDI"},
    {bmdVideoConnectionComponent, "component", "Component"}, {bmdVideoConnectionComposite, "composite", "Composite"}, {bmdVideoConnectionSVideo, "svideo", "S-Video"}};

static std::string deviceId(IDeckLink *dl, int index) {
    IDeckLinkProfileAttributes *a = nullptr;
    char b[64];
    snprintf(b, sizeof b, "decklink:n%d", index);
    if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&a) == S_OK) {
        int64_t v = 0;
        if (a->GetInt(BMDDeckLinkPersistentID, &v) == S_OK) snprintf(b, sizeof b, "decklink:p%llx", (unsigned long long)v);
        else if (a->GetInt(BMDDeckLinkTopologicalID, &v) == S_OK) snprintf(b, sizeof b, "decklink:t%llx", (unsigned long long)v);
        a->Release();
    }
    return b;
}

// calls fn for each capture capable device until it returns true. false if the runtime is not installed
static bool eachDevice(const std::function<bool(IDeckLink *, int)> &fn) {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return false;
    IDeckLink *dl = nullptr;
    for (int i = 0; it->Next(&dl) == S_OK; i++) {
        bool capture = true;
        IDeckLinkProfileAttributes *a = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&a) == S_OK) {
            int64_t io = 0;
            if (a->GetInt(BMDDeckLinkVideoIOSupport, &io) == S_OK) capture = io & bmdDeviceSupportsCapture;
            a->Release();
        }
        bool stop = capture && fn(dl, i);
        dl->Release();
        if (stop) break;
    }
    it->Release();
    return true;
}

static std::vector<SourceInfo> listDeckLink(bool &found) {
    std::vector<SourceInfo> out;
    found = eachDevice([&](IDeckLink *dl, int i) {
        SourceInfo s;
        s.id = deviceId(dl, i);
        CFStringRef n = NULL;
        dl->GetDisplayName(&n);
        s.name = cfStr(n);
        if (s.name.empty()) s.name = "DeckLink device";
        s.formatLabel = "Input";
        s.audioLabel = "Embedded (HDMI / SDI)";
        s.group = "Capture devices";
        s.captureDevice = true;
        IDeckLinkProfileAttributes *a = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&a) == S_OK) {
            int64_t conns = 0;
            a->GetInt(BMDDeckLinkVideoInputConnections, &conns);
            for (auto &c : kConn) if (conns & c.bit) s.formats.push_back({c.id, c.name});
            a->Release();
        }
        s.defaultFormat = s.formats.empty() ? "" : s.formats[0].id;
        out.push_back(s);
        return false;
    });
    return out;
}

class DeckLinkSource : public Source, public IDeckLinkInputCallback {
    std::string id_;
    SourceOptions opt_;
    IDeckLink *dl_ = nullptr;
    IDeckLinkInput *in_ = nullptr;
    bool audioOn_ = false, detect_ = true;
    std::string connName_ = "";
    std::atomic<double> dur_{1001.0 / 60000};
    std::atomic<double> lastArrival_{0};
    std::atomic<int> state_{-1};
    std::string signal_ = "";
    std::atomic<BMDDisplayMode> mode_{0};
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);

public:
    DeckLinkSource(const std::string &id, const SourceOptions &o) : id_(id), opt_(o) {}
    ~DeckLinkSource() override { stop(); }
    double frameDuration() override { return dur_; }
    bool hasAudio() override { return audioOn_; }

    HRESULT QueryInterface(REFIID, void **) override { return E_NOINTERFACE; }
    ULONG AddRef() override { return 1; }
    ULONG Release() override { return 1; }

    bool start(std::string &err) override {
        bool found = eachDevice([&](IDeckLink *dl, int i) {
            if (deviceId(dl, i) != id_) return false;
            dl->AddRef();
            dl_ = dl;
            return true;
        });
        if (!found) { err = "The Blackmagic Desktop Video software is not installed."; return false; }
        if (!dl_) { err = "The capture device is not connected."; return false; }
        if (dl_->QueryInterface(IID_IDeckLinkInput, (void **)&in_) != S_OK) { err = "This device has no input."; stop(); return false; }

        IDeckLinkProfileAttributes *a = nullptr;
        int64_t conns = 0, maxCh = 2;
        bool fd = false;
        if (dl_->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&a) == S_OK) {
            a->GetInt(BMDDeckLinkVideoInputConnections, &conns);
            a->GetInt(BMDDeckLinkMaximumAudioChannels, &maxCh);
            if (a->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &fd) != S_OK) fd = false;
            a->Release();
        }
        detect_ = fd;
        // pick the input connection where the device offers more than one
        for (auto &c : kConn) {
            if (!(conns & c.bit) || (!opt_.format.empty() && opt_.format != c.id)) continue;
            connName_ = c.name;
            if (__builtin_popcountll(conns) > 1) {
                IDeckLinkConfiguration *cfg = nullptr;
                if (dl_->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) == S_OK) {
                    cfg->SetInt(bmdDeckLinkConfigVideoInputConnection, c.bit);
                    cfg->Release();
                }
            }
            break;
        }
        // surround order. hdmi carries lfe on channel 3 and centre on 4, the fold down in audio.mm assumes that. the
        // device can swap the two on input: logged, so a wrong-sounding centre can be traced to it
        IDeckLinkConfiguration *cfg = nullptr;
        if (dl_->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) == S_OK) {
            bool swap = false;
            if (cfg->GetFlag(bmdDeckLinkConfigSwapHDMICh3AndCh4OnInput, &swap) == S_OK) logLine("decklink: hdmi channels 3 and 4 %s on input", swap ? "swapped" : "as they come");
            cfg->Release();
        }
        in_->SetCallback(this);
        mode_ = bmdModeHD1080p5994;
        HRESULT r = in_->EnableVideoInput(mode_.load(), pix_.load(), detect_ ? bmdVideoInputEnableFormatDetection : 0);
        if (r != S_OK) {
            err = r == E_ACCESSDENIED ? "The capture device is in use by another application." : "The capture device's input could not be opened.";
            in_->SetCallback(nullptr);
            stop();
            return false;
        }
        // audio input has to be enabled before the streams start, it is refused afterwards. 8 channels where offered,
        // so a 5.1/7.1 source setting folds down to stereo instead of losing the centre. only 2, 8 or 16 are accepted
        if (opt_.audio) {
            int ch = maxCh >= 8 ? 8 : 2;
            audioOn_ = in_->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, ch) == S_OK;
            chans_ = ch;
        }
        report(SourceState::Starting, "Waiting for a signal" + (connName_.empty() ? std::string() : " on " + connName_));
        if (in_->StartStreams() != S_OK) { err = "The capture device did not start."; stop(); return false; }
        logLine("decklink: started, format detection %s, audio %s", detect_ ? "on" : "off (fixed 1080p59.94)", audioOn_ ? "on" : "off");
        return true;
    }

    void stop() override {
        *alive_ = false;
        if (in_) {
            in_->StopStreams();
            if (audioOn_) in_->DisableAudioInput();
            in_->DisableVideoInput();
            in_->SetCallback(nullptr);
            in_->Release();
            in_ = nullptr;
        }
        if (dl_) { dl_->Release(); dl_ = nullptr; }
        if (pool_) { CVPixelBufferPoolRelease(pool_); pool_ = NULL; }
    }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents, IDeckLinkDisplayMode *m, BMDDetectedVideoInputFormatFlags f) override {
        BMDDisplayMode mode = m->GetDisplayMode();
        BMDPixelFormat pix = pixFor(f);
        if (mode == mode_ && pix == pix_) return S_OK; // the same format re-fires, would loop forever
        mode_ = mode;
        pix_ = pix;
        BMDTimeValue dur; BMDTimeScale ts;
        m->GetFrameRate(&dur, &ts);
        dur_ = (double)dur / ts;
        renderer::setFrameDur(dur_);
        renderer::signalChanged();
        bool interlaced = m->GetFieldDominance() != bmdProgressiveFrame && m->GetFieldDominance() != bmdProgressiveSegmentedFrame;
        char b[128];
        snprintf(b, sizeof b, "%ldx%ld%s @ %.2f %s%s%s", m->GetWidth(), m->GetHeight(), interlaced ? "i" : "", (double)ts / dur,
                 (f & bmdDetectedVideoInputRGB444) ? "RGB" : "YUV 4:2:2", connName_.empty() ? "" : ", ", connName_.c_str());
        signal_ = b;
        logLine("decklink signal: %s ('%s')", b, fourcc(mode).c_str());
        state_ = -1;
        report(SourceState::Starting, signal_);
        restart(mode, 0, signal_);
        return S_OK;
    }

    // restarting inside the callback delivered zero frames in testing, so it happens on the main queue. a restart
    // that fails is tried again a few times (the device can still be busy with the old mode) and then reported:
    // it used to be logged only, and the window stayed black
    void restart(BMDDisplayMode mode, int attempt, std::string what) {
        auto alive = alive_;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!*alive || mode != mode_) return; // stopped, or the format changed again meanwhile
            BMDPixelFormat pix = pix_;
            in_->StopStreams();
            in_->DisableVideoInput();
            HRESULT e = in_->EnableVideoInput(mode, pix, detect_ ? bmdVideoInputEnableFormatDetection : 0);
            HRESULT s = e == S_OK ? in_->StartStreams() : E_FAIL;
            logLine("decklink: restart for '%s' as '%s' try %d: enable 0x%x start 0x%x", fourcc(mode).c_str(), fourcc(pix).c_str(), attempt + 1, (unsigned)e, (unsigned)s);
            if (e == S_OK && s == S_OK) return;
            if (attempt < 4) restart(mode, attempt + 1, what);
            else report(SourceState::Error, "The capture device could not switch to " + what + ". Choose the source again, or change the console's output.");
        });
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *fr, IDeckLinkAudioInputPacket *ap) override {
        double now = nowSec();
        bool nosig = fr && (fr->GetFlags() & bmdFrameHasNoInputSource);
        if (ap && audioOn_) {
            void *bytes = nullptr;
            long n = ap->GetSampleFrameCount();
            // while the picture is still locking the packets are silent and arrive in lumps, they only upset the timing
            if (nosig || !fr) audio::lost();
            else if (n > 0 && ap->GetBytes(&bytes) == S_OK && bytes) {
                BMDTimeValue pt = -1;
                if (ap->GetPacketTime(&pt, 48000) != S_OK) pt = -1;
                audio::pushInt32((const int32_t *)bytes, n, chans_, now, pt);
            }
        }
        if (!fr) return S_OK;
        double prev = lastArrival_.exchange(now);
        bool late = !nosig && prev > 0 && now - prev > 1.5 * dur_.load();
        if (nosig) {
            renderer::noSignalFrame();
            setState(SourceState::NoSignal, "No signal" + (connName_.empty() ? std::string() : " on " + connName_));
            return S_OK;
        }
        IDeckLinkMacVideoBuffer *mb = nullptr;
        if (fr->QueryInterface(IID_IDeckLinkMacVideoBuffer, (void **)&mb) != S_OK) return S_OK;
        void *p = nullptr;
        if (mb->CreateCVPixelBufferRef(&p) == S_OK && p) {
            CVPixelBufferRef pb = (CVPixelBufferRef)p;
            if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_422YpCbCr8) { CVPixelBufferRef y = toYuv(pb); CFRelease(pb); pb = y; }
            if (pb) {
                setState(SourceState::Running, signal_.empty() ? std::string("1920x1080 @ 59.94") : signal_);
                renderer::submit(pb, now, now, late);
            }
        }
        mb->Release();
        return S_OK;
    }

private:
    int chans_ = 2;
    std::atomic<BMDPixelFormat> pix_{bmdFormat8BitYUV};
    CVPixelBufferPoolRef pool_ = NULL; // capture thread only
    int poolW_ = 0, poolH_ = 0;

    // bgra frame -> 2vuy, +1. the numbers go through as they are: video range rgb (what a console sends by default)
    // comes out as video range yuv, full range rgb as full range yuv, and the levels detection tells them apart as for
    // any other source. videotoolbox's own conversion takes the rgb as full range and squeezed it a second time
    // (black at 30). chroma is taken at the left pixel of each pair, as 4:2:2 over hdmi has it. about 1 ms at 720p
    CVPixelBufferRef toYuv(CVPixelBufferRef src) {
        if (CVPixelBufferGetPixelFormatType(src) != kCVPixelFormatType_32BGRA) return NULL;
        int w = (int)CVPixelBufferGetWidth(src), h = (int)CVPixelBufferGetHeight(src);
        if (!pool_ || w != poolW_ || h != poolH_) {
            if (pool_) CVPixelBufferPoolRelease(pool_);
            pool_ = NULL;
            NSDictionary *a = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_422YpCbCr8), (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
            CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)a, &pool_);
            poolW_ = w; poolH_ = h;
        }
        CVPixelBufferRef dst = NULL;
        if (w < 2 || !pool_ || CVPixelBufferPoolCreatePixelBuffer(NULL, pool_, &dst) != kCVReturnSuccess) return NULL;
        tag709(dst);
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dst, 0);
        const uint8_t *sb = (const uint8_t *)CVPixelBufferGetBaseAddress(src);
        uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        size_t srb = CVPixelBufferGetBytesPerRow(src), drb = CVPixelBufferGetBytesPerRow(dst);
        // bt.709 in 16.16: y = .2126 r + .7152 g + .0722 b, cb = 128 + (b - y) / 1.8556 * 224 / 219, cr likewise with 1.5748
        auto luma = [](int r, int g, int b) { return (13933 * r + 46871 * g + 4732 * b + 32768) >> 16; };
        auto clamp8 = [](int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); };
        for (int y = 0; y < h; y++) {
            const uint8_t *s = sb + y * srb;
            uint8_t *d = db + y * drb;
            for (int x = 0; x + 1 < w; x += 2, d += 4) {
                const uint8_t *p = s + x * 4, *l = x ? p - 4 : p, *r = p + 4;
                int cb = (l[0] + 2 * p[0] + r[0] + 2) >> 2, cg = (l[1] + 2 * p[1] + r[1] + 2) >> 2, cr = (l[2] + 2 * p[2] + r[2] + 2) >> 2;
                int cy = luma(cr, cg, cb);
                d[0] = clamp8(128 + ((36124 * (cb - cy) + 32768) >> 16));
                d[1] = (uint8_t)luma(p[2], p[1], p[0]);
                d[2] = clamp8(128 + ((42566 * (cr - cy) + 32768) >> 16));
                d[3] = (uint8_t)luma(r[2], r[1], r[0]);
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return dst;
    }
    void setState(SourceState s, const std::string &t) {
        if (state_.exchange((int)s) != (int)s) report(s, t);
    }
};

static std::unique_ptr<Source> makeDeckLinkSource(const std::string &id, const SourceOptions &o) { return std::make_unique<DeckLinkSource>(id, o); }

// device arrival / removal through the sdk's discovery interface
struct Discovery : IDeckLinkDeviceNotificationCallback {
    std::function<void()> fn;
    HRESULT QueryInterface(REFIID, void **) override { return E_NOINTERFACE; }
    ULONG AddRef() override { return 1; }
    ULONG Release() override { return 1; }
    HRESULT DeckLinkDeviceArrived(IDeckLink *) override { ping(); return S_OK; }
    HRESULT DeckLinkDeviceRemoved(IDeckLink *) override { ping(); return S_OK; }
    void ping() { auto f = fn; dispatch_async(dispatch_get_main_queue(), ^{ if (f) f(); }); }
};

static void watchDeckLink(std::function<void()> changed) {
    static Discovery d;
    static IDeckLinkDiscovery *disc;
    d.fn = changed;
    if (disc) return;
    disc = CreateDeckLinkDiscoveryInstance();
    if (disc) disc->InstallDeviceNotifications(&d);
}

const Driver kDeckLinkDriver = {
    "decklink", "Blackmagic",
    "Blackmagic devices can also use their own driver once Desktop Video is installed",
    listDeckLink, makeDeckLinkSource, watchDeckLink,
};
