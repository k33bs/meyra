// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
//
// app shell: window, menus, source picker, status overlay text, updates, command line flags for automated runs.
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#include "audio.h"
#include "common.h"
#include "display.h"
#include "framegen.h"
#include "superres.h"
#include "renderer.h"
#include "source.h"
#include "update.h"

static const unsigned kAudioIoFrames = 128;     // output buffer. research ran at 64; 128 leaves room on a busy machine
static const double kDefaultVideoDelay = 0.03;  // seconds, for the audio until the picture delay has been measured

struct Args {
    std::string source, log, snapshot, captureTest, screen;
    double seconds = 0, snapshotAt = -1, captureAt = -1;
    bool listDevices = false, fullscreen = false, test = false;
    int winW = 0, winH = 0;
    std::vector<std::pair<std::string, std::string>> set;
    std::vector<std::string> commands;
    bool menuDump = false;
};
static Args gArgs;

static NSString *ns(const std::string &s) { return @(s.c_str()); }


@interface MeyraView : NSView
@property (nonatomic, strong) NSTextField *message;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation>
- (void)command:(NSString *)cmd;
@end

static AppDelegate *gApp;

// game mode: macos turns it on for a full screen app whose Info.plist says it is a game and supports it (the build's
// plist does). there is no call to switch it per run, so "off" takes the keys out of the installed app's own plist.
// launch services only reads a bundle again when its date changes, hence the touch and the re-register, and it only
// counts from the next start.
// this edits a signed bundle. fine for the ad hoc builds (still starts, same permissions, only
// `codesign --verify` complains); with developer id + notarisation it has to become something else
static bool gGameModeChanged;
static NSString *infoPlist() { return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"]; }
static bool gameModeDeclared() { return [[NSDictionary dictionaryWithContentsOfFile:infoPlist()][@"LSSupportsGameMode"] boolValue]; }
static bool setGameMode(bool on) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:infoPlist()];
    if (!d) return false;
    bool had = [d[@"LSSupportsGameMode"] boolValue];
    if (!on && had) update::keepSignedPlist(NSBundle.mainBundle.bundleURL); // the untouched one (if it still is), see update.mm
    if (on && !had && update::restoreSignedPlist(NSBundle.mainBundle.bundleURL)) d = nil; // back to the signed bytes, nothing to write
    else if (on) { d[@"LSSupportsGameMode"] = @YES; d[@"GCSupportsGameMode"] = @YES; d[@"LSApplicationCategoryType"] = @"public.app-category.games"; }
    else { [d removeObjectsForKeys:@[@"LSSupportsGameMode", @"GCSupportsGameMode"]]; d[@"LSApplicationCategoryType"] = @"public.app-category.video"; }
    NSData *x = d ? [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] : nil;
    if (d && (!x || ![x writeToFile:infoPlist() atomically:YES])) return false; // read-only place, e.g. run from a disk image
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:NSBundle.mainBundle.bundlePath error:nil];
    LSRegisterURL((__bridge CFURLRef)NSBundle.mainBundle.bundleURL, true);
    logLine("game mode: %s in the app's Info.plist, counts from the next start", on ? "declared" : "removed");
    return true;
}

// which upscaler ran this second, and why it is not the chosen one when it is not
static NSString *upscalerText(int up, const renderer::Stats &s, const superres::Stats &r) {
    NSString *t = s.sr ? [NSString stringWithFormat:@"Apple SR %.1f avg %.1f max ms", r.n ? r.sumMs / r.n : 0, r.maxMs] : up == 1 ? @"MetalFX" : up == 3 ? @"edge-aware FSR 1" : up == 4 ? @"edge-aware SGSR 1" : @"plain";
    if (srYields()) t = [t stringByAppendingString:@" (Apple SR waits while frame generation is on)"];
    else if (s.srLate) t = [t stringByAppendingFormat:@", %d frames by MetalFX (late)", s.srLate];
    else if (effUpscale() == 2 && !s.sr && *superres::status()) t = [t stringByAppendingFormat:@" (Apple SR %s)", superres::status()];
    return t;
}

@implementation MeyraView
- (instancetype)initWithFrame:(NSRect)r {
    if ((self = [super initWithFrame:r])) {
        self.wantsLayer = YES;
        _message = [NSTextField wrappingLabelWithString:@""];
        _message.textColor = [NSColor colorWithWhite:0.85 alpha:1];
        _message.font = [NSFont systemFontOfSize:15 weight:NSFontWeightRegular];
        _message.alignment = NSTextAlignmentCenter;
        _message.translatesAutoresizingMaskIntoConstraints = NO;
        _message.selectable = NO;
        [self addSubview:_message];
        [NSLayoutConstraint activateConstraints:@[
            [_message.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_message.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_message.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor multiplier:0.8],
        ]];
    }
    return self;
}
- (CALayer *)makeBackingLayer { return renderer::layer(); }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }
- (void)fit {
    CGFloat s = self.window.backingScaleFactor ?: 1;
    renderer::layer().contentsScale = s;
    renderer::layer().drawableSize = CGSizeMake(self.bounds.size.width * s, self.bounds.size.height * s);
    renderer::setScale(s);
}
- (void)setFrameSize:(NSSize)z { [super setFrameSize:z]; [self fit]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fit]; }
// single key shortcuts. only reach here while the picture has focus, never while typing in a text field
- (void)keyDown:(NSEvent *)ev {
    if (ev.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) { [super keyDown:ev]; return; }
    NSString *k = ev.charactersIgnoringModifiers;
    NSDictionary *map = @{@"f": @"fullscreen", @"v": @"vsync", @"w": @"winsize+", @"h": @"overlay", @"g": @"framegen", @"e": @"schedule", @"z": @"passthrough", @"r": @"levels+", @"c": @"colour+",
                          @"b": @"deband", @"m": @"upscale+", @"[": @"sharp-", @"]": @"sharp+", @"a": @"audio", @";": @"trim-", @"'": @"trim+"};
    if (map[k]) [gApp command:map[k]];
    else if (ev.keyCode == 53 && (self.window.styleMask & NSWindowStyleMaskFullScreen)) [self.window toggleFullScreen:nil];
    else [super keyDown:ev];
}
@end


@implementation AppDelegate {
    NSWindow *_win;
    MeyraView *_view;
    std::unique_ptr<Source> _source;
    std::string _sourceId, _sourceName;
    SourceStatus _status;
    bool _sourceAudio;
    bool _hadFrames;
    bool _goingFull; // entering full screen, or in it
    int _framesLastSecond;
    double _fps;
    int _aspectW, _aspectH;
    std::string _missingId;        // saved device that is not connected; started when it shows up
    NSPanel *_picker;
    NSPopUpButton *_pickSource, *_pickFormat, *_pickAudio;
    NSTextField *_pickFormatLabel, *_pickAudioLabel, *_pickNote;
    std::vector<SourceInfo> _pickList;
    renderer::Stats _last;
    double _videoDelay;
    NSMenu *_sourceMenu;
    std::string _curDefaultFormat;
    bool _updating;
}


- (void)applicationDidFinishLaunching:(NSNotification *)n {
    gApp = self;
    [self buildMenus];
    NSString *shaderPath = [NSBundle.mainBundle pathForResource:@"Shaders" ofType:@"metal"];
    NSString *shader = shaderPath ? [NSString stringWithContentsOfFile:shaderPath encoding:NSUTF8StringEncoding error:nil] : nil;
    std::string err;
    if (!shader || !renderer::init(shader, err)) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Meyra cannot start";
        a.informativeText = shader ? ns(err) : @"The app bundle is incomplete (Shaders.metal is missing).";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }
    renderer::startThread();
    framegen::startThread();
    superres::startThread();

    NSRect frame = NSMakeRect(0, 0, gArgs.winW ?: 1280, gArgs.winH ?: 720);
    _win = [[NSWindow alloc] initWithContentRect:frame
                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                         backing:NSBackingStoreBuffered defer:NO];
    // a stable title, so window pickers (screen sharing, streaming, recording) can find and keep finding it
    _win.title = @"Meyra";
    _win.delegate = self;
    _win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _win.sharingType = NSWindowSharingReadOnly; // the default, stated so nobody turns capture off by accident
    _win.backgroundColor = NSColor.blackColor;
    _win.contentAspectRatio = NSMakeSize(16, 9);
    _win.contentMinSize = NSMakeSize(320, 180);
    _win.releasedWhenClosed = NO;
    _aspectW = 16; _aspectH = 9;
    _view = [[MeyraView alloc] initWithFrame:frame];
    _win.contentView = _view;
    [_win center];
    if (!gArgs.test) [_win setFrameAutosaveName:@"Main"];
    if (!gArgs.screen.empty())
        for (NSScreen *sc in NSScreen.screens)
            if ([sc.localizedName rangeOfString:ns(gArgs.screen) options:NSCaseInsensitiveSearch].location != NSNotFound) {
                NSRect f = sc.visibleFrame;
                [_win setFrameOrigin:NSMakePoint(NSMidX(f) - _win.frame.size.width / 2, NSMidY(f) - _win.frame.size.height / 2)];
            }
    [_win makeKeyAndOrderFront:nil];
    [_win makeFirstResponder:_view];
    [_view fit];
    if (!gArgs.test) [NSApp activateIgnoringOtherApps:YES];
    if (gArgs.fullscreen) { _goingFull = true; [_win toggleFullScreen:nil]; } // the will-enter callback can come after the first frame

    // kept for the life of the app: the activity ends when its token goes away. display sleep off too: a controller
    // is no input to the mac, the screen would dim mid-game
    static id act;
    act = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical | NSActivityIdleDisplaySleepDisabled reason:@"live video"];
    (void)act;
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *) { [self second]; }];
    watchDevices([self] { [self devicesChanged]; });
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeScreenNotification object:_win queue:nil usingBlock:^(NSNotification *) { [self applyRefresh]; }];

    [self chooseInitialSource];
    // --command NAME[@SECONDS]: run a menu command after launch (or that many seconds later), the same path a menu
    // click or key press takes
    for (auto &c : gArgs.commands) {
        size_t at = c.find('@');
        std::string name = c.substr(0, at);
        double t = at == std::string::npos ? 0 : atof(c.c_str() + at + 1);
        void (^run)(void) = ^{ logLine("command: %s", name.c_str()); [self command:ns(name)]; };
        if (t > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), run);
        else run();
    }

    if (gArgs.snapshotAt < 0 && gArgs.seconds > 0) gArgs.snapshotAt = gArgs.seconds * 0.6;
    if (gArgs.captureAt < 0 && gArgs.seconds > 0) gArgs.captureAt = gArgs.seconds * 0.7;
    if (!gArgs.snapshot.empty())
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(0.5, gArgs.snapshotAt) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ renderer::snapshot(ns(gArgs.snapshot)); });
    if (!gArgs.captureTest.empty())
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(0.5, gArgs.captureAt) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self captureTest]; });
    if (gArgs.menuDump)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self dumpMenu:NSApp.mainMenu depth:0]; });
    if (gArgs.seconds > 0)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gArgs.seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self quit]; });
    // on by default, quiet unless there is something newer. it contacts api.github.com, the readme says what is sent
    // an update brings a fresh plist: put the choice back
    if (!gArgs.test && [NSUserDefaults.standardUserDefaults boolForKey:@"gameMode"] != gameModeDeclared())
        gGameModeChanged = setGameMode([NSUserDefaults.standardUserDefaults boolForKey:@"gameMode"]);
    if (!gArgs.test && [NSUserDefaults.standardUserDefaults boolForKey:@"checkUpdatesAtLaunch"]) [self checkForUpdates:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

// an open sheet would otherwise make appkit refuse to quit
- (void)quit {
    if (_win.attachedSheet) [_win endSheet:_win.attachedSheet];
    [NSApp terminate:nil];
}

// order matters: nothing may still feed or run a thread when static objects start going away at exit
- (void)applicationWillTerminate:(NSNotification *)n {
    [self stopSource];
    renderer::stopThread();
    framegen::stopThread();
    superres::stopThread();
    audio::stop();
    display::restore();
    logLine("quit");
}

- (void)chooseInitialSource {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!gArgs.source.empty()) { [self startSource:gArgs.source persist:NO]; return; }
    NSString *saved = [d stringForKey:@"source"];
    auto list = listSources();
    if (saved.length) {
        std::string id = saved.UTF8String;
        bool present = id.rfind("replay:", 0) == 0;
        for (auto &s : list) if (s.id == id) present = true;
        if (present) { [self startSource:id persist:NO]; return; }
        _missingId = id;
        NSString *name = [d stringForKey:@"sourceName"] ?: @"The last used device";
        [self showMessage:[NSString stringWithFormat:@"%@ is not connected.\nConnect it, or choose another source from the Source menu.", name]];
        [self showPicker];
        return;
    }
    std::vector<SourceInfo> devices;
    for (auto &s : list) if (s.captureDevice) devices.push_back(s);
    if (devices.size() == 1) { [self startSource:devices[0].id persist:YES]; return; }
    [self showMessage:devices.empty() ? @"No capture device found.\nConnect one, or open a folder of recorded frames with Source > Open Replay Folder."
                                      : @"Choose a source from the Source menu."];
    [self showPicker];
}


- (SourceOptions)optionsFor:(const std::string &)id {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    SourceOptions o;
    o.format = [[d dictionaryForKey:@"formats"][ns(id)] description].UTF8String ?: "";
    o.audioInput = [[d dictionaryForKey:@"audioInputs"][ns(id)] description].UTF8String ?: "auto";
    o.audio = gSet.audio;
    o.mayPrompt = !gArgs.test;
    return o;
}

- (void)stopSource {
    if (_source) {
        _source->stop(); // first: capture threads may still be reporting
        _source->onStatus = nullptr;
        _source.reset();
    }
}

- (void)startSource:(const std::string &)id persist:(BOOL)persist {
    [self stopSource];
    _missingId.clear();
    bool same = id == _sourceId;
    _sourceId = id;
    _sourceName = id.rfind("replay:", 0) == 0 ? "Replay" : id;
    for (auto &s : listSources()) if (s.id == id) _sourceName = s.name;
    if (id.rfind("replay:", 0) == 0) _sourceName = std::string("Replay: ") + [ns(id.substr(7)) lastPathComponent].UTF8String;
    _win.subtitle = ns(_sourceName);
    _hadFrames = false;
    _fps = 0;
    _status = {SourceState::Starting, "Starting"};
    _source = makeSource(id, [self optionsFor:id]);
    if (!_source) { [self showMessage:@"Unknown source."]; return; }
    __weak AppDelegate *weak = self;
    _source->onStatus = [weak](const SourceStatus &st) {
        SourceStatus copy = st;
        dispatch_async(dispatch_get_main_queue(), ^{ [weak statusChanged:copy]; });
    };
    renderer::beginSource(_source->frameDuration(), same);
    renderer::clear();
    audio::stop();
    audio::reset();
    // replay has no sound; capture sources start the output now so it is ready when the first packet comes
    _sourceAudio = id.rfind("replay:", 0) != 0 && gSet.audio;
    audio::setMute([NSUserDefaults.standardUserDefaults boolForKey:@"muteOutput"]);
    if (_sourceAudio && !audio::start(kAudioIoFrames)) logLine("audio output could not start");
    std::string err;
    logLine("source: %s (%s)", _sourceName.c_str(), id.c_str());
    if (!_source->start(err)) {
        logLine("source failed: %s", err.c_str());
        _status = {SourceState::Error, err};
        _source.reset();
        audio::stop();
        [self showMessage:ns(err)];
        return;
    }
    [self showMessage:@"Starting…"];
    if (persist) {
        [NSUserDefaults.standardUserDefaults setObject:ns(id) forKey:@"source"];
        [NSUserDefaults.standardUserDefaults setObject:ns(_sourceName) forKey:@"sourceName"];
    }
}

- (void)statusChanged:(const SourceStatus &)st {
    if (!_source) return;
    _status = st;
    logLine("status: %s", st.text.c_str());
    if (st.state == SourceState::Gone) {
        _missingId = _sourceId;
        [self stopSource];
        renderer::clear();
        [self showMessage:[NSString stringWithFormat:@"%@ was disconnected.\nIt will start again when it is plugged back in.", ns(_sourceName)]];
    } else if (st.state == SourceState::Error) {
        [self showMessage:ns(st.text)];
    }
    _fps = _source ? 1 / _source->frameDuration() : 0;
    [self applyRefresh];
}

- (void)devicesChanged {
    auto list = listSources();
    if (!_missingId.empty()) {
        for (auto &s : list) if (s.id == _missingId) { logLine("device back: %s", s.name.c_str()); [self startSource:_missingId persist:NO]; return; }
    }
    if (_source && _sourceId.rfind("replay:", 0) != 0) {
        bool present = false;
        for (auto &s : list) if (s.id == _sourceId) present = true;
        if (!present) {
            SourceStatus gone{SourceState::Gone, "disconnected"};
            [self statusChanged:gone];
        }
    }
    if (_picker.visible) [self fillPicker];
}

// once a second: stats, log, overlay, messages

- (void)second {
    renderer::Stats s = renderer::takeStats();
    framegen::Stats g = framegen::takeStats();
    superres::Stats r = superres::takeStats();
    audio::Stats a = audio::takeStats();
    _last = s;
    _framesLastSecond = s.in;
    // audio follows the picture: aim at the measured capture -> glass time of real frames
    if (s.toGlassN) {
        double vd = s.toGlassSum / s.toGlassN / 1000 + (s.lagN ? s.lagSum / s.lagN / 1000 : 0);
        _videoDelay = _videoDelay > 0 ? _videoDelay + (vd - _videoDelay) * 0.5 : vd; // halfway each second: steady, still quick
    }
    // muteOutput: automated tests keep the speakers quiet while still measuring the sound path
    audio::retarget(_videoDelay > 0 ? _videoDelay : kDefaultVideoDelay, gSet.audioTrim, !gSet.audio || [NSUserDefaults.standardUserDefaults boolForKey:@"muteOutput"]);

    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    if (w > 0 && h > 0 && (w * _aspectH != h * _aspectW)) {
        _aspectW = w; _aspectH = h;
        _win.contentAspectRatio = NSMakeSize(w, h);
        if (!(_win.styleMask & NSWindowStyleMaskFullScreen)) {
            NSRect f = _win.frame;
            NSSize c = [_win contentRectForFrameRect:f].size;
            [_win setContentSize:NSMakeSize(c.width, round(c.width * h / w))];
        }
    }

    // what to tell the user when there is no picture
    if (s.in > 0) {
        if (!_hadFrames) { _hadFrames = true; [self applyRefresh]; }
        [self showMessage:nil];
    } else if (_source) {
        NSString *m;
        if (_status.state == SourceState::Error) m = ns(_status.text);
        else if (_status.state == SourceState::NoSignal || s.nosignal > 0) m = [NSString stringWithFormat:@"%@\nCheck that the source is switched on and the cable is connected.", ns(_status.text.empty() ? "No signal" : _status.text)];
        else if (_status.state == SourceState::Running) m = [NSString stringWithFormat:@"No picture from %@ (%@).\nIf the source sends a mode this device cannot capture, set it to 1080p.", ns(_sourceName), ns(_status.text)];
        else m = [NSString stringWithFormat:@"%@…", ns(_status.text)];
        if (_hadFrames) { _hadFrames = false; renderer::clear(); }
        [self showMessage:m];
    }

    const char *genState = !effFrameGen() ? "off" : !framegen::available() ? "unavailable" : *framegen::status() ? framegen::status() : gSet.early ? "early" : "tick";
    logLine("in %d real %d repeat %d (%d inexact) late %d nosignal %d rolled %d | drawn %d superseded %d | on screen: %d uneven gaps of %d, longest %.1f ms, %d never shown | "
            "gen %s made %d late %d skipped %d, %.1f avg %.1f max ms, convert %.2f ms | gpu %.2f avg %.2f max ms | tick %.1f max, drawable wait %.1f max ms, timed wake late %.2f max ms | "
            "real->present %.1f ms | real->glass %.1f avg %.1f min %.1f max ms (%d) | %dx%d -> %dx%d %s sharpen %.1f deband %d levels %s (darkest %d)",
            s.in, s.real, s.repeats, s.nearRepeats, s.late, s.nosignal, s.rolled, s.drawn, s.superseded, s.gapBad, s.gapN, s.gapMax, s.notShown,
            genState, s.gen, s.genLate, s.genSkipped, g.n ? g.sumMs / g.n : 0, g.maxMs, s.convN ? s.convSum / s.convN : 0,
            s.gpuN ? s.gpuSum / s.gpuN : 0, s.gpuMax, s.tickMax, s.drawableMax, s.schedLateMax,
            s.toPresN ? s.toPresSum / s.toPresN : 0, s.toGlassN ? s.toGlassSum / s.toGlassN : 0, s.toGlassN ? s.toGlassMin : 0, s.toGlassMax, s.toGlassN,
            w, h, fw, fh, upscalerText(up, s, r).lowercaseString.UTF8String, effSharpen(), (int)effDeband(), renderer::fullRange() ? "full" : "video", s.in ? s.darkest : -1);
    if (audio::running())
        logLine("   audio %d frames/s | delay %.0f ms (video %.0f, trim %+.0f) | underruns %d overruns %d resyncs %d gaps %d | jitter %.1f ms | "
                "peak in %.3f %.3f (any channel %.3f) out %.3f | %s",
                a.frames, a.delayMs, _videoDelay * 1000, gSet.audioTrim * 1000, a.underruns, a.overruns, a.resyncs, a.gaps, a.jitterMs,
                a.peakL, a.peakR, a.rawPeak, a.outPeak, audio::statusLine().c_str());
    [self updateOverlay:s gen:g sr:r];
    if (_win.styleMask & NSWindowStyleMaskFullScreen) [NSCursor setHiddenUntilMouseMoves:YES];
}

- (void)showMessage:(NSString *)m {
    _view.message.stringValue = m ?: @"";
    _view.message.hidden = m == nil;
}

- (void)applyRefresh {
    bool fs = _goingFull || (_win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    // a source that is (re)starting keeps the matched mode: giving it back and taking it again is two black re-syncs
    if (!_hadFrames || _fps <= 0) { if (!_source) display::apply(_win.screen, 0, 0, fs); return; }
    display::apply(_win.screen, _fps, gSet.refresh, fs);
}


- (void)updateOverlay:(const renderer::Stats &)s gen:(const framegen::Stats &)g sr:(const superres::Stats &)r {
    if (!gSet.overlay) { renderer::setHud(nil); return; }
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    NSString *genLine;
    if (gSet.passthrough) genLine = @"off (passthrough)";
    else if (!gSet.frameGen) genLine = @"off";
    else if (!framegen::available()) genLine = @"not available on this Mac";
    else if (*framegen::status()) genLine = ns(framegen::status());
    else genLine = [NSString stringWithFormat:@"%@, %d real + %d made /s, %.0f ms each%@", renderer::deepNow() ? @"in turns with Apple SR" : gSet.early ? @"[E] early" : @"[E] on the tick", s.real, s.gen,
                    g.n ? g.sumMs / g.n : 0, (s.genLate || s.genSkipped) ? [NSString stringWithFormat:@", missed %d", s.genLate + s.genSkipped] : @""];
    NSString *levels = gSet.levels == 1 ? @"video range" : gSet.levels == 2 ? @"full range" : renderer::fullRange() ? @"full range (auto)" : @"video range (auto)";
    if (s.in) levels = [levels stringByAppendingFormat:@", darkest %d", s.darkest]; // 16 on black = the source sends video range
    NSString *scale = w ? [NSString stringWithFormat:@"%d×%d → %d×%d %@", w, h, fw, fh, upscalerText(up, s, r)] : @"–";
    // the line says what ran. when that is not the one chosen with M, say which is chosen and why it is idle: the
    // key looked dead in a window no larger than the source
    static NSString *const kUp[] = {@"plain", @"MetalFX", @"Apple SR", @"edge-aware FSR 1", @"edge-aware SGSR 1"};
    int want = gSet.upscale;
    if (w && gSet.passthrough) scale = [scale stringByAppendingFormat:@" (%@ chosen, off in passthrough)", kUp[want]];
    else if (w && want && (fw <= w || fh <= h)) scale = [scale stringByAppendingFormat:@" (%@ chosen, idle: the picture is not larger than the source)", kUp[want]];
    NSString *text = [NSString stringWithFormat:
        @"source   %@  %@\n"
        @"input    %d fps (%d new)   rolled %d   drawn %d   uneven %d of %d\n"
        @"delay    capture → screen %.0f ms   gpu %.1f ms\n"
        @"picture  [R] %@   [M] %@   [B] dither removal %@   [ [ ] ] sharpen %@\n"
        @"motion   [G] frame generation %@\n"
        @"audio    [A] %@%@   [ ; ' ] trim\n"
        @"display  %@\n"
        @"keys     [F] full screen   [W] window size   [Z] plain passthrough   [H] hide this   ⌘S snapshot",
        ns(_sourceName), ns(_status.text), s.in, s.real, s.rolled, s.drawn, s.gapBad, s.gapN,
        s.toGlassN ? s.toGlassSum / s.toGlassN + (s.lagN ? s.lagSum / s.lagN : 0) : 0, s.gpuN ? s.gpuSum / s.gpuN : 0,
        levels, scale, effDeband() ? @"on" : @"off", effSharpen() > 0 ? [NSString stringWithFormat:@"%.1f", effSharpen()] : @"off",
        genLine, audio::running() ? ns(audio::statusLine()) : @"off", fabs(gSet.audioTrim) > 0.0005 ? [NSString stringWithFormat:@", trim %+.0f ms", gSet.audioTrim * 1000] : @"",
        [ns(display::status()) stringByAppendingFormat:@"   [V] vsync %@   [C] colour %@", gSet.vsync ? @"on" : @"off", gSet.colour == 1 ? @"srgb" : gSet.colour == 2 ? @"screen's own" : @"bt.709"]];
    CGFloat scaleF = _win.backingScaleFactor ?: 1;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 * scaleF weight:NSFontWeightMedium], NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize ts = [text boundingRectWithSize:NSMakeSize(4000, 4000) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs].size;
    size_t pad = (size_t)(10 * scaleF);
    size_t tw = (size_t)ceil(ts.width) + 2 * pad, th = (size_t)ceil(ts.height) + 2 * pad;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, tw, th, 8, tw * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = gc;
    [[NSColor colorWithWhite:0 alpha:0.62] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, tw, th) xRadius:8 * scaleF yRadius:8 * scaleF] fill];
    [text drawInRect:NSMakeRect(pad, pad, tw - 2 * pad, th - 2 * pad) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:tw height:th mipmapped:NO];
    id<MTLTexture> t = [renderer::layer().device newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0 withBytes:CGBitmapContextGetData(ctx) bytesPerRow:tw * 4];
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    renderer::setHud(t);
}

// commands from menus and single keys

- (void)menuAction:(NSMenuItem *)item { [self command:item.representedObject]; }

- (void)command:(NSString *)c {
    NSString *arg = nil;
    NSRange colon = [c rangeOfString:@":"];
    if (colon.location != NSNotFound) { arg = [c substringFromIndex:colon.location + 1]; c = [c substringToIndex:colon.location]; }
    if ([c isEqual:@"fullscreen"]) [_win toggleFullScreen:nil];
    else if ([c isEqual:@"overlay"]) { gSet.overlay = !gSet.overlay; settingsSave("overlay"); [self updateOverlay:_last gen:framegen::Stats() sr:superres::Stats()]; }
    else if ([c isEqual:@"framegen"]) { gSet.frameGen = !gSet.frameGen; settingsSave("frameGen"); }
    else if ([c isEqual:@"schedule"]) { gSet.early = arg ? arg.intValue != 0 : !gSet.early; settingsSave("early"); }
    else if ([c isEqual:@"passthrough"]) { gSet.passthrough = !gSet.passthrough; settingsSave("passthrough"); }
    else if ([c isEqual:@"levels"]) { gSet.levels = arg.intValue % 3; settingsSave("levels"); }
    else if ([c isEqual:@"levels+"]) { gSet.levels = (gSet.levels + 1) % 3; settingsSave("levels"); }
    else if ([c isEqual:@"colour"] || [c isEqual:@"colour+"]) {
        gSet.colour = ([c isEqual:@"colour"] ? arg.intValue : gSet.colour + 1) % 3;
        settingsSave("colour");
        renderer::applyColour();
    }
    else if ([c isEqual:@"deband"]) { gSet.deband = !gSet.deband; settingsSave("deband"); }
    else if ([c isEqual:@"srpad"]) { gSet.srPad = !gSet.srPad; settingsSave("srPad"); }
    else if ([c isEqual:@"srgen"]) { gSet.srWithGen = !gSet.srWithGen; settingsSave("srWithGen"); }
    else if ([c isEqual:@"upscale"]) { gSet.upscale = arg.intValue % 5; settingsSave("upscale"); }
    else if ([c isEqual:@"upscale+"]) { int n = (gSet.upscale + 1) % 5; gSet.upscale = n == 2 && !superres::available() ? 3 : n; settingsSave("upscale"); }
    else if ([c isEqual:@"sharp"]) { gSet.sharpen = arg.floatValue; settingsSave("sharpen"); }
    else if ([c isEqual:@"sharp+"]) { gSet.sharpen = fminf(1, roundf(gSet.sharpen * 10 + 1) / 10); settingsSave("sharpen"); }
    else if ([c isEqual:@"sharp-"]) { gSet.sharpen = fmaxf(0, roundf(gSet.sharpen * 10 - 1) / 10); settingsSave("sharpen"); }
    else if ([c isEqual:@"audio"]) { gSet.audio = !gSet.audio; settingsSave("audio"); [self audioToggled]; }
    else if ([c isEqual:@"trim+"]) { gSet.audioTrim = gSet.audioTrim + 0.005; settingsSave("audioTrimMs"); }
    else if ([c isEqual:@"trim-"]) { gSet.audioTrim = gSet.audioTrim - 0.005; settingsSave("audioTrimMs"); }
    else if ([c isEqual:@"trim0"]) { gSet.audioTrim = 0; settingsSave("audioTrimMs"); }
    else if ([c isEqual:@"refresh"]) { gSet.refresh = arg.intValue % 3; settingsSave("refresh"); [self applyRefresh]; }
    else if ([c isEqual:@"source"]) [self startSource:arg.UTF8String persist:YES];
    else if ([c isEqual:@"format"]) [self setPerSource:@"formats" value:arg];
    else if ([c isEqual:@"ain"]) [self setPerSource:@"audioInputs" value:arg];
    else if ([c isEqual:@"restart"]) { // a deliberate restart also forgets the detected levels
        std::string id = _sourceId;
        _sourceId.clear();
        if (!id.empty()) [self startSource:id persist:NO];
    }
    else if ([c isEqual:@"replay"]) [self openReplay];
    else if ([c isEqual:@"picker"]) [self showPicker];
    else if ([c isEqual:@"snapshot"]) [self saveSnapshot];
    else if ([c isEqual:@"actual"]) [self actualSize];
    else if ([c isEqual:@"winsize"]) [self windowHeight:arg.intValue];
    else if ([c isEqual:@"winsize+"]) [self windowHeight:0];
    else if ([c isEqual:@"keys"]) [self showKeys];
    else if ([c isEqual:@"updates"]) [self checkForUpdates:NO];
    else if ([c isEqual:@"vsync"]) { gSet.vsync = !gSet.vsync; settingsSave("vsync"); renderer::layer().displaySyncEnabled = gSet.vsync; }
    else if ([c isEqual:@"gamemode"]) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        bool on = ![d boolForKey:@"gameMode"];
        if (setGameMode(on)) { [d setBool:on forKey:@"gameMode"]; gGameModeChanged = !gGameModeChanged; }
        else NSBeep();
    }
    else if ([c isEqual:@"updatesAtLaunch"]) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setBool:![d boolForKey:@"checkUpdatesAtLaunch"] forKey:@"checkUpdatesAtLaunch"];
    }
    else if ([c isEqual:@"revertUpdate"]) [self revertUpdate];
    if (gSet.overlay) [self updateOverlay:_last gen:framegen::Stats() sr:superres::Stats()];
}

// updates from github releases, see update.mm

- (void)tell:(NSString *)title text:(NSString *)text {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text;
    if (_win.attachedSheet) [a runModal];
    else [a beginSheetModalForWindow:_win completionHandler:nil];
}

- (void)checkForUpdates:(BOOL)quiet {
    if (_updating) return;
    update::check("", ^(const update::CheckResult &r) {
        logLine("update check: %s", r.message.c_str());
        if (r.newer) [self offerUpdate:r.release];
        else if (!quiet) [self tell:r.ok ? @"No update" : @"Could not check for updates" text:ns(r.message)];
    });
}

- (void)offerUpdate:(const update::Release &)r {
    NSString *notes = ns(r.notes);
    if (notes.length > 1200) notes = [[notes substringToIndex:1200] stringByAppendingString:@"…"];
    std::vector<int> mine;
    update::parseVersion(update::bundleVersion(NSBundle.mainBundle.bundleURL), mine);
    NSMutableString *t = [NSMutableString stringWithFormat:@"You have %s.%@%@", update::versionString(mine).c_str(), notes.length ? @"\n\n" : @"", notes];
    if (r.sha256.empty()) [t appendString:@"\n\nThe release notes contain no SHA-256 checksum, so Meyra will not install it. Download it from the project page instead."];
    [t appendString:@"\n\nMeyra restarts after installing. The current version is kept and can be restored from the Meyra menu."];
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Meyra %s is available", update::versionString(r.version).c_str()];
    a.informativeText = t;
    [a addButtonWithTitle:@"Install"];
    [a addButtonWithTitle:@"Later"];
    update::Release rel = r;
    auto go = ^(NSModalResponse resp) { if (resp == NSAlertFirstButtonReturn) [self installUpdate:rel]; };
    if (_win.attachedSheet) go([a runModal]);
    else [a beginSheetModalForWindow:_win completionHandler:go];
}

- (void)installUpdate:(const update::Release &)r {
    _updating = true;
    NSString *sub = _win.subtitle;
    _win.subtitle = @"Downloading update…";
    update::install(r, ^(double f) { self->_win.subtitle = [NSString stringWithFormat:@"Downloading update, %.0f%%", f * 100]; },
                    ^(const std::string &err) {
        self->_updating = false;
        self->_win.subtitle = sub;
        logLine("update: %s", err.empty() ? "installed, relaunching" : err.c_str());
        if (!err.empty()) { [self tell:@"The update was not installed" text:ns(err)]; return; }
        update::relaunch();
        [self quit];
    });
}

- (void)revertUpdate {
    std::string v;
    if (_updating || !update::previousVersion(v)) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Go back to Meyra %s?", v.c_str()];
    a.informativeText = @"Meyra restarts with the previous version. The current one is kept, so you can switch back the same way.";
    [a addButtonWithTitle:@"Revert"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    std::string err = update::revert();
    logLine("update: revert %s", err.empty() ? "done, relaunching" : err.c_str());
    if (!err.empty()) { [self tell:@"Could not go back" text:ns(err)]; return; }
    update::relaunch();
    [self quit];
}

- (void)audioToggled {
    // turning sound on or off reopens the source, since embedded audio has to be enabled before capture starts
    if (!_sourceId.empty()) [self startSource:_sourceId persist:NO];
}

- (void)setPerSource:(NSString *)key value:(NSString *)v {
    if (_sourceId.empty()) return;
    NSMutableDictionary *m = [[NSUserDefaults.standardUserDefaults dictionaryForKey:key] mutableCopy] ?: [NSMutableDictionary new];
    m[ns(_sourceId)] = v;
    [NSUserDefaults.standardUserDefaults setObject:m forKey:key];
    [self startSource:_sourceId persist:NO];
}

- (void)openReplay {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = YES;
    p.allowsMultipleSelection = NO;
    p.message = @"Choose a folder of raw 1920×1080 UYVY frames named NAME_f000.uyvy, NAME_f001.uyvy, …";
    [p beginSheetModalForWindow:_win completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        if (self->_picker.visible) [self->_win endSheet:self->_picker];
        [self startSource:std::string("replay:") + p.URL.path.UTF8String persist:YES];
    }];
}

- (void)saveSnapshot {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSPicturesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"Meyra %@.png", [f stringFromDate:NSDate.date]]];
    renderer::snapshot(path);
}

// picture height in pixels for the window, width from the source's shape. 0 = the next size up that fits the screen,
// back to the smallest after the biggest
- (void)windowHeight:(int)px {
    static const int sizes[] = {720, 900, 1080, 1440, 2160};
    if (_win.styleMask & NSWindowStyleMaskFullScreen) return;
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    double aspect = w && h ? (double)w / h : 16.0 / 9, s = _win.backingScaleFactor ?: 1;
    NSSize room = [_win contentRectForFrameRect:_win.screen.visibleFrame].size;
    auto fits = [&](int p) { return p / s <= room.height && p * aspect / s <= room.width; };
    if (px <= 0) {
        double cur = _win.contentView.bounds.size.height * s;
        px = sizes[0];
        for (int z : sizes) if (z > cur + 1 && fits(z)) { px = z; break; }
    }
    [_win setContentSize:NSMakeSize(round(px * aspect) / s, px / s)];
    NSRect f = _win.frame, v = _win.screen.visibleFrame; // keep it on the screen
    f.origin.x = fmax(v.origin.x, fmin(f.origin.x, NSMaxX(v) - f.size.width));
    f.origin.y = fmax(v.origin.y, fmin(f.origin.y, NSMaxY(v) - f.size.height));
    [_win setFrameOrigin:f.origin];
}

- (void)actualSize {
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    if (!w || (_win.styleMask & NSWindowStyleMaskFullScreen)) return;
    CGFloat s = _win.backingScaleFactor ?: 1;
    [_win setContentSize:NSMakeSize(w / s, h / s)];
}

- (void)showKeys {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Single-key shortcuts";
    a.informativeText = @"These work while the picture has keyboard focus.\n\n"
                         "F  full screen        H  status overlay\n"
                         "G  frame generation   E  frame schedule\n"
                         "Z  plain passthrough  R  levels\n"
                         "B  dither removal     M  upscaling\n"
                         "[ ]  sharpening       A  audio on/off\n"
                         ";  '  audio earlier / later\n"
                         "Esc  leave full screen";
    [a beginSheetModalForWindow:_win completionHandler:nil];
}


static NSMenuItem *item(NSString *title, NSString *cmd, NSString *key, NSEventModifierFlags mods = NSEventModifierFlagCommand) {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:@selector(menuAction:) keyEquivalent:key ?: @""];
    i.keyEquivalentModifierMask = mods;
    i.representedObject = cmd;
    return i;
}

static NSMenu *submenu(NSMenu *parent, NSString *title) {
    NSMenuItem *i = [parent addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    i.submenu = m;
    return m;
}

- (void)buildMenus {
    NSMenu *bar = [NSMenu new];
    NSMenu *app = submenu(bar, @"Meyra");
    [app addItemWithTitle:@"About Meyra" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:item(@"VSync", @"vsync", @"v", 0)];
    [app addItem:item(@"Game Mode in Full Screen", @"gamemode", nil)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:item(@"Check for Updates…", @"updates", nil)];
    [app addItem:item(@"Check for Updates at Launch", @"updatesAtLaunch", nil)];
    [app addItem:item(@"Revert to Previous Version…", @"revertUpdate", nil)];
    [app addItem:NSMenuItem.separatorItem];
    NSMenuItem *services = [app addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
    services.submenu = [NSMenu new];
    NSApp.servicesMenu = services.submenu;
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Hide Meyra" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *others = [app addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    others.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [app addItemWithTitle:@"Quit Meyra" action:@selector(quit) keyEquivalent:@"q"];
    quit.target = self;

    NSWindow.allowsAutomaticWindowTabbing = NO;
    _sourceMenu = submenu(bar, @"Source");
    _sourceMenu.delegate = self; // filled when it opens

    NSMenu *pic = submenu(bar, @"Picture");
    NSMenu *lv = submenu(pic, @"Levels");
    [lv addItem:item(@"Automatic", @"levels:0", nil)];
    [lv addItem:item(@"Video Range (16–235)", @"levels:1", nil)];
    [lv addItem:item(@"Full Range (0–255)", @"levels:2", nil)];
    NSMenu *co = submenu(pic, @"Colour");
    [co addItem:item(@"BT.709 (Exact)", @"colour:0", nil)];
    [co addItem:item(@"sRGB (More Contrast)", @"colour:1", nil)];
    [co addItem:item(@"The Screen's Own (Most Saturated)", @"colour:2", nil)];
    [pic addItem:item(@"Dither Removal", @"deband", @"b", NSEventModifierFlagCommand | NSEventModifierFlagOption)];
    NSMenu *up = submenu(pic, @"Upscaling");
    [up addItem:item(@"Plain", @"upscale:0", nil)];
    [up addItem:item(@"MetalFX", @"upscale:1", nil)];
    [up addItem:item(@"Edge-Aware (FSR 1)", @"upscale:3", nil)];
    [up addItem:item(@"Edge-Aware (SGSR 1)", @"upscale:4", nil)];
    [up addItem:item(@"Apple Super Resolution", @"upscale:2", nil)];
    [up addItem:NSMenuItem.separatorItem];
    [up addItem:item(@"Super Resolution: Pad Edges", @"srpad", nil)];
    [up addItem:item(@"Super Resolution: Run With Frame Generation (9 ms more delay)", @"srgen", nil)];
    NSMenu *sh = submenu(pic, @"Sharpening");
    [sh addItem:item(@"Off", @"sharp:0", nil)];
    [sh addItem:item(@"Low", @"sharp:0.3", nil)];
    [sh addItem:item(@"Medium", @"sharp:0.6", nil)];
    [sh addItem:item(@"High", @"sharp:0.9", nil)];
    [sh addItem:NSMenuItem.separatorItem];
    [sh addItem:item(@"Sharper", @"sharp+", @"]")];
    [sh addItem:item(@"Softer", @"sharp-", @"[")];
    [pic addItem:NSMenuItem.separatorItem];
    [pic addItem:item(@"Plain Passthrough", @"passthrough", @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift)];

    NSMenu *mo = submenu(bar, @"Motion");
    [mo addItem:item(@"Frame Generation", @"framegen", @"g", NSEventModifierFlagCommand | NSEventModifierFlagOption)];
    NSMenu *sc = submenu(mo, @"Frame Schedule");
    [sc addItem:item(@"Early (less delay)", @"schedule:1", nil)];
    [sc addItem:item(@"On the Tick", @"schedule:0", nil)];
    [mo addItem:NSMenuItem.separatorItem];
    NSMenu *rf = submenu(mo, @"Match Display Refresh");
    [rf addItem:item(@"Off", @"refresh:0", nil)];
    [rf addItem:item(@"Automatic", @"refresh:1", nil)];
    [rf addItem:item(@"Source Rate", @"refresh:2", nil)];

    NSMenu *au = submenu(bar, @"Audio");
    [au addItem:item(@"Play Audio", @"audio", @"a", NSEventModifierFlagCommand | NSEventModifierFlagOption)];
    [au addItem:NSMenuItem.separatorItem];
    [au addItem:item(@"Earlier by 5 ms", @"trim-", @";")];
    [au addItem:item(@"Later by 5 ms", @"trim+", @"'")];
    [au addItem:item(@"Reset Delay", @"trim0", nil)];

    // no view menu: the app has one window and no tabs, so its few items live under window
    NSMenu *wm = submenu(bar, @"Window");
    NSMenuItem *fs = [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [wm addItem:item(@"Actual Size", @"actual", @"0")];
    NSMenu *ws = submenu(wm, @"Window Size");
    [ws addItem:item(@"Next Size", @"winsize+", @"w", 0)];
    for (int z : {720, 900, 1080, 1440, 2160}) [ws addItem:item([NSString stringWithFormat:@"%dp", z], [NSString stringWithFormat:@"winsize:%d", z], nil)];
    [wm addItem:item(@"Show Status Overlay", @"overlay", @"i")];
    [wm addItem:NSMenuItem.separatorItem];
    [wm addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [wm addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [wm addItem:NSMenuItem.separatorItem];
    [wm addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    NSApp.windowsMenu = wm;

    NSMenu *hm = submenu(bar, @"Help");
    [hm addItem:item(@"Keyboard Shortcuts", @"keys", nil)];
    NSApp.helpMenu = hm;
    NSApp.mainMenu = bar;
}

// --menu-dump: build and validate every menu the way opening it would, and log what the user would see
- (void)dumpMenu:(NSMenu *)m depth:(int)depth {
    if (m == NSApp.servicesMenu) return;
    if ([m.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [m.delegate menuNeedsUpdate:m];
    [m update];
    for (NSMenuItem *i in m.itemArray) {
        if (i.separatorItem) continue;
        NSMutableString *k = [NSMutableString string];
        if (i.keyEquivalent.length) {
            NSEventModifierFlags f = i.keyEquivalentModifierMask;
            if (f & NSEventModifierFlagFunction) [k appendString:@"globe-"];
            if (f & NSEventModifierFlagControl) [k appendString:@"ctrl-"];
            if (f & NSEventModifierFlagOption) [k appendString:@"opt-"];
            if (f & NSEventModifierFlagShift) [k appendString:@"shift-"];
            if (f & NSEventModifierFlagCommand) [k appendString:@"cmd-"];
            [k appendString:i.keyEquivalent];
        }
        logLine("menu %*s%s%s%s%s", depth * 2, "", i.state == NSControlStateValueOn ? "[x] " : "", i.title.UTF8String,
                k.length ? [NSString stringWithFormat:@"  (%@)", k].UTF8String : "",
                [NSString stringWithFormat:@"%@%@%@", i.enabled || i.submenu ? @"" : @"  [disabled]", i.hidden ? @"  [hidden]" : @"", i.alternate ? @"  [alternate]" : @""].UTF8String);
        if (i.submenu) [self dumpMenu:i.submenu depth:depth + 1];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)m {
    if (m != _sourceMenu) return;
    [m removeAllItems];
    std::vector<std::string> hints;
    auto list = listSources(&hints);
    std::string group;
    const SourceInfo *cur = nullptr;
    for (auto &s : list) {
        if (s.group != group) {
            if (!group.empty()) [m addItem:NSMenuItem.separatorItem];
            group = s.group;
            [m addItem:[NSMenuItem sectionHeaderWithTitle:ns(group)]];
        }
        [m addItem:item(ns(s.name), ns("source:" + s.id), nil)];
        if (s.id == _sourceId) { cur = &s; _curDefaultFormat = s.defaultFormat; }
    }
    if (list.empty()) {
        NSMenuItem *none = [m addItemWithTitle:@"No capture devices found" action:nil keyEquivalent:@""];
        none.enabled = NO;
    }
    if (_sourceId.rfind("replay:", 0) == 0) {
        [m addItem:NSMenuItem.separatorItem];
        [m addItem:item(ns(_sourceName), ns("source:" + _sourceId), nil)];
    }
    [m addItem:NSMenuItem.separatorItem];
    if (cur && !cur->formats.empty()) {
        if (cur->pickAudio || cur->formats.size() > 1) {
            NSMenu *f = submenu(m, ns(cur->formatLabel));
            for (auto &c : cur->formats) [f addItem:item(ns(c.name), ns("format:" + c.id), nil)];
        }
    }
    if (cur && cur->pickAudio) {
        NSMenu *a = submenu(m, @"Audio Input");
        [a addItem:item(@"Automatic", @"ain:auto", nil)];
        [a addItem:item(@"None", @"ain:none", nil)];
        [a addItem:NSMenuItem.separatorItem];
        for (auto &c : listAVFAudioInputs()) [a addItem:item(ns(c.name), ns("ain:" + c.id), nil)];
    }
    [m addItem:item(@"Choose Source…", @"picker", @"o", NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [m addItem:item(@"Open Replay Folder…", @"replay", @"o")];
    [m addItem:item(@"Restart Source", @"restart", @"r")];
    [m addItem:NSMenuItem.separatorItem];
    [m addItem:item(@"Save Snapshot", @"snapshot", @"s")];
    for (auto &h : hints) { // a vendor driver whose software is not installed
        [m addItem:NSMenuItem.separatorItem];
        NSMenuItem *n = [m addItemWithTitle:ns(h) action:nil keyEquivalent:@""];
        n.enabled = NO;
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)mi {
    if (mi.action == @selector(toggleFullScreen:)) {
        mi.title = (_win.styleMask & NSWindowStyleMaskFullScreen) ? @"Exit Full Screen" : @"Enter Full Screen";
        return YES;
    }
    if (mi.action != @selector(menuAction:)) return YES;
    NSString *c = mi.representedObject, *arg = nil;
    NSRange colon = [c rangeOfString:@":"];
    if (colon.location != NSNotFound) { arg = [c substringFromIndex:colon.location + 1]; c = [c substringToIndex:colon.location]; }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    bool on = false, enabled = true;
    bool pass = gSet.passthrough;
    if ([c isEqual:@"levels"]) on = gSet.levels == arg.intValue;
    else if ([c isEqual:@"colour"]) on = gSet.colour == arg.intValue;
    else if ([c isEqual:@"deband"]) { on = gSet.deband; enabled = !pass; }
    else if ([c isEqual:@"srpad"]) { on = gSet.srPad; enabled = !pass && superres::available(); }
    else if ([c isEqual:@"srgen"]) { on = gSet.srWithGen; enabled = !pass && superres::available(); }
    else if ([c isEqual:@"upscale"]) {
        on = gSet.upscale == arg.intValue;
        enabled = !pass && (arg.intValue != 2 || superres::available());
        if (arg.intValue == 2) { // say why it is off or not running
            const char *st = superres::status();
            mi.title = !superres::available() ? @"Apple Super Resolution (needs macOS 26 and Apple silicon)"
                     : on && srYields() ? @"Apple Super Resolution (frame generation off only, using MetalFX)"
                     : on && *st && strcmp(st, "starting") ? [NSString stringWithFormat:@"Apple Super Resolution (%s, using MetalFX)", st] : @"Apple Super Resolution";
        }
    }
    else if ([c isEqual:@"sharp"]) { on = fabsf(gSet.sharpen - arg.floatValue) < 0.05f; enabled = !pass; }
    else if ([c isEqual:@"sharp+"] || [c isEqual:@"sharp-"]) enabled = !pass;
    else if ([c isEqual:@"passthrough"]) on = pass;
    else if ([c isEqual:@"framegen"]) { on = gSet.frameGen; enabled = framegen::available() && !pass; }
    else if ([c isEqual:@"schedule"]) on = gSet.early == (arg.intValue != 0);
    else if ([c isEqual:@"refresh"]) on = gSet.refresh == arg.intValue;
    else if ([c isEqual:@"audio"]) on = gSet.audio;
    else if ([c isEqual:@"trim0"]) {
        mi.title = fabs(gSet.audioTrim) > 0.0005 ? [NSString stringWithFormat:@"Reset Delay (now %+.0f ms)", gSet.audioTrim * 1000] : @"Reset Delay";
        enabled = fabs(gSet.audioTrim) > 0.0005;
    }
    else if ([c isEqual:@"overlay"]) on = gSet.overlay;
    else if ([c isEqual:@"source"]) on = _sourceId == arg.UTF8String;
    else if ([c isEqual:@"format"]) {
        NSString *v = [d dictionaryForKey:@"formats"][ns(_sourceId)];
        if (!v) v = ns(_curDefaultFormat);
        on = [v isEqual:arg];
    }
    else if ([c isEqual:@"ain"]) on = [([d dictionaryForKey:@"audioInputs"][ns(_sourceId)] ?: @"auto") isEqual:arg];
    else if ([c isEqual:@"restart"] || [c isEqual:@"snapshot"] || [c isEqual:@"actual"]) enabled = !_sourceId.empty();
    else if ([c isEqual:@"updates"]) enabled = !_updating;
    else if ([c isEqual:@"updatesAtLaunch"]) on = [d boolForKey:@"checkUpdatesAtLaunch"];
    else if ([c isEqual:@"vsync"]) on = gSet.vsync;
    else if ([c isEqual:@"gamemode"]) {
        on = [d boolForKey:@"gameMode"];
        mi.title = gGameModeChanged ? @"Game Mode in Full Screen (from the next start of Meyra)" : @"Game Mode in Full Screen";
    }
    else if ([c isEqual:@"revertUpdate"]) {
        std::string v;
        mi.hidden = !update::previousVersion(v);
        mi.title = [NSString stringWithFormat:@"Revert to Meyra %s…", v.empty() ? "" : ("v" + v).c_str()];
        enabled = !_updating;
    }
    mi.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return enabled;
}


- (void)showPicker {
    if (!_picker) {
        _picker = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 230) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
        _picker.title = @"Choose a Source";
        NSView *v = _picker.contentView;
        auto label = [&](NSString *t, CGFloat y) {
            NSTextField *l = [NSTextField labelWithString:t];
            l.frame = NSMakeRect(20, y, 110, 20);
            l.alignment = NSTextAlignmentRight;
            [v addSubview:l];
            return l;
        };
        auto popup = [&](CGFloat y) {
            NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(136, y - 3, 304, 26) pullsDown:NO];
            [v addSubview:p];
            return p;
        };
        label(@"Source:", 186);
        _pickSource = popup(186);
        _pickSource.target = self;
        _pickSource.action = @selector(pickerSourceChanged:);
        _pickFormatLabel = label(@"Format:", 152);
        _pickFormat = popup(152);
        _pickAudioLabel = label(@"Audio input:", 118);
        _pickAudio = popup(118);
        _pickNote = [NSTextField wrappingLabelWithString:@""];
        _pickNote.frame = NSMakeRect(20, 52, 420, 56);
        _pickNote.textColor = NSColor.secondaryLabelColor;
        _pickNote.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        [v addSubview:_pickNote];
        NSButton *replay = [NSButton buttonWithTitle:@"Open Replay Folder…" target:self action:@selector(pickerReplay:)];
        replay.frame = NSMakeRect(14, 12, 170, 32);
        NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(pickerCancel:)];
        cancel.frame = NSMakeRect(270, 12, 86, 32);
        cancel.keyEquivalent = @"\033";
        NSButton *ok = [NSButton buttonWithTitle:@"Start" target:self action:@selector(pickerStart:)];
        ok.frame = NSMakeRect(360, 12, 86, 32);
        ok.keyEquivalent = @"\r";
        for (NSButton *b in @[replay, cancel, ok]) [v addSubview:b];
    }
    [self fillPicker];
    if (!_picker.visible) [_win beginSheet:_picker completionHandler:nil];
}

- (void)fillPicker {
    std::vector<std::string> hints;
    _pickList = listSources(&hints);
    [_pickSource removeAllItems];
    NSInteger sel = -1;
    for (size_t i = 0; i < _pickList.size(); i++) {
        auto &s = _pickList[i];
        NSString *title = [NSString stringWithFormat:@"%@ — %@", ns(s.name), ns(s.kind)];
        [_pickSource addItemWithTitle:title];
        _pickSource.lastItem.tag = (NSInteger)i;
        if (s.id == _sourceId || (sel < 0 && s.captureDevice)) sel = (NSInteger)i;
    }
    if (_pickList.empty()) { [_pickSource addItemWithTitle:@"No devices found"]; _pickSource.enabled = NO; }
    else { _pickSource.enabled = YES; [_pickSource selectItemAtIndex:sel < 0 ? 0 : sel]; }
    NSString *note = @"Devices with their maker's driver installed can use it; every device also works through the system's capture support.";
    if (!hints.empty()) note = [ns(hints[0]) stringByAppendingString:@". USB capture devices need nothing extra."];
    // the window's own message is hidden behind the sheet, so repeat it here
    if (!_view.message.hidden && _view.message.stringValue.length)
        note = [[_view.message.stringValue stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByAppendingFormat:@"\n%@", note];
    _pickNote.stringValue = note;
    [self pickerSourceChanged:nil];
}

- (void)pickerSourceChanged:(id)sender {
    [_pickFormat removeAllItems];
    [_pickAudio removeAllItems];
    NSInteger i = _pickSource.selectedItem.tag;
    bool has = !_pickList.empty() && i >= 0 && i < (NSInteger)_pickList.size();
    const SourceInfo *s = has ? &_pickList[i] : nullptr;
    _pickFormatLabel.stringValue = [ns(s ? s->formatLabel : "Format") stringByAppendingString:@":"];
    if (s) {
        NSString *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"formats"][ns(s->id)] ?: ns(s->defaultFormat);
        for (auto &c : s->formats) {
            [_pickFormat addItemWithTitle:ns(c.name)];
            _pickFormat.lastItem.representedObject = ns(c.id);
            if ([saved isEqual:ns(c.id)]) [_pickFormat selectItem:_pickFormat.lastItem];
        }
        if (!s->pickAudio && s->formats.size() <= 1) [_pickFormat addItemWithTitle:@"Automatic"];
    }
    _pickFormat.enabled = s && s->formats.size() > 1;
    bool avf = s && s->pickAudio;
    [_pickAudio addItemWithTitle:avf ? @"Automatic" : s && !s->audioLabel.empty() ? ns(s->audioLabel) : @"None"];
    _pickAudio.lastItem.representedObject = @"auto";
    if (avf) {
        [_pickAudio addItemWithTitle:@"None"];
        _pickAudio.lastItem.representedObject = @"none";
        NSString *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"audioInputs"][ns(s->id)] ?: @"auto";
        if ([saved isEqual:@"none"]) [_pickAudio selectItem:_pickAudio.lastItem];
        for (auto &c : listAVFAudioInputs()) {
            [_pickAudio addItemWithTitle:ns(c.name)];
            _pickAudio.lastItem.representedObject = ns(c.id);
            if ([saved isEqual:ns(c.id)]) [_pickAudio selectItem:_pickAudio.lastItem];
        }
    }
    _pickAudio.enabled = avf;
}

- (void)pickerStart:(id)sender {
    NSInteger i = _pickSource.selectedItem.tag;
    if (_pickList.empty() || i < 0 || i >= (NSInteger)_pickList.size()) return;
    std::string id = _pickList[i].id;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[@"formats", @"audioInputs"]) {
        NSString *v = ([key isEqual:@"formats"] ? _pickFormat : _pickAudio).selectedItem.representedObject;
        if (!v) continue;
        NSMutableDictionary *m = [[d dictionaryForKey:key] mutableCopy] ?: [NSMutableDictionary new];
        m[ns(id)] = v;
        [d setObject:m forKey:key];
    }
    [_win endSheet:_picker];
    [self startSource:id persist:YES];
}

- (void)pickerCancel:(id)sender { [_win endSheet:_picker]; }
- (void)pickerReplay:(id)sender { [_win endSheet:_picker]; [self openReplay]; }


- (void)windowDidEnterFullScreen:(NSNotification *)n { [NSCursor setHiddenUntilMouseMoves:YES]; [self applyRefresh]; }
- (void)windowDidExitFullScreen:(NSNotification *)n { _goingFull = false; [self applyRefresh]; } // variable refresh only works full screen
// on the way in counts as in: a first frame arriving mid-animation must not put a variable refresh screen on a fixed mode
- (void)windowWillEnterFullScreen:(NSNotification *)n { _goingFull = true; [self applyRefresh]; }
- (void)windowDidFailToEnterFullScreen:(NSWindow *)w {
    _goingFull = false;
    [self applyRefresh];
    // happens when another full screen app was just closed and its space is still going away. once more, a bit later
    static bool again;
    if (again) return;
    again = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!(w.styleMask & NSWindowStyleMaskFullScreen)) { self->_goingFull = true; [w toggleFullScreen:nil]; }
    });
}
- (void)windowWillExitFullScreen:(NSNotification *)n { _goingFull = false; }

// automated test: capture our own window the way other apps would (screencapturekit)

- (void)captureTest {
    logLine("window: id %ld title \"%s\" sharing %ld level %ld fullscreen %d", (long)_win.windowNumber, _win.title.UTF8String, (long)_win.sharingType,
            (long)_win.level, (_win.styleMask & NSWindowStyleMaskFullScreen) != 0);
    if (@available(macOS 14.4, *)) {
        CGWindowID wid = (CGWindowID)_win.windowNumber;
        NSString *path = ns(gArgs.captureTest);
        CGFloat scale = _win.backingScaleFactor;
        NSSize sz = _win.frame.size;
        [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
            SCWindow *mine = nil;
            for (SCWindow *w in c.windows) if (w.windowID == wid) mine = w;
            if (!mine) { logLine("capture test: window not offered (%s)", e.localizedDescription.UTF8String ?: "no error"); return; }
            SCContentFilter *f = [[SCContentFilter alloc] initWithDesktopIndependentWindow:mine];
            SCStreamConfiguration *cfg = [SCStreamConfiguration new];
            cfg.width = (size_t)(sz.width * scale);
            cfg.height = (size_t)(sz.height * scale);
            cfg.showsCursor = NO;
            [SCScreenshotManager captureImageWithFilter:f configuration:cfg completionHandler:^(CGImageRef img, NSError *err) {
                if (!img) { logLine("capture test failed: %s", err.localizedDescription.UTF8String ?: "?"); return; }
                // mean brightness of the middle, so the log says whether the picture itself came through
                size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                std::vector<uint8_t> px(w * h * 4);
                CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
                CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
                double sum = 0; long n = 0;
                for (size_t y = h / 4; y < h * 3 / 4; y += 4) for (size_t x = w / 4; x < w * 3 / 4; x += 4) { uint8_t *p = &px[(y * w + x) * 4]; sum += (p[0] + p[1] + p[2]) / 3.0; n++; }
                CGContextRelease(ctx); CGColorSpaceRelease(cs);
                CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
                if (dst) { CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst); CFRelease(dst); }
                logLine("capture test: %zux%zu, mean level in the middle %.1f of 255, saved %s", w, h, n ? sum / n : 0, path.UTF8String);
            }];
        }];
    } else logLine("capture test needs macOS 14.4");
}

@end


static void listDevices() {
    std::vector<std::string> hints;
    for (auto &s : listSources(&hints)) {
        printf("  %s  [%s]  %s, %s:", s.name.c_str(), s.id.c_str(), s.kind.c_str(), s.formatLabel.c_str());
        for (auto &c : s.formats) printf(" %s%s", c.name.c_str(), c.id == s.defaultFormat ? "*" : "");
        printf("\n");
    }
    for (auto &h : hints) printf("note: %s\n", h.c_str());
    printf("avfoundation audio inputs:\n");
    for (auto &c : listAVFAudioInputs()) printf("  %s  [%s]\n", c.name.c_str(), c.id.c_str());
    printf("frame generation: %s\n", framegen::available() ? "available" : "not available");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strncmp(argv[1], "--update-", 9)) return update::selfTest(std::vector<std::string>(argv + 1, argv + argc));
        for (int i = 1; i < argc; i++) {
            bool more = i + 1 < argc;
            std::string a = argv[i];
            if (a == "--source" && more) gArgs.source = argv[++i];
            else if (a == "--seconds" && more) gArgs.seconds = atof(argv[++i]);
            else if (a == "--log" && more) gArgs.log = argv[++i];
            else if (a == "--snapshot" && more) gArgs.snapshot = argv[++i];
            else if (a == "--snapshot-at" && more) gArgs.snapshotAt = atof(argv[++i]);
            else if (a == "--capture-test" && more) gArgs.captureTest = argv[++i];
            else if (a == "--capture-at" && more) gArgs.captureAt = atof(argv[++i]);
            else if (a == "--screen" && more) gArgs.screen = argv[++i];
            else if (a == "--window" && more) sscanf(argv[++i], "%dx%d", &gArgs.winW, &gArgs.winH);
            else if (a == "--fullscreen") gArgs.fullscreen = true;
            else if (a == "--list-devices") gArgs.listDevices = true;
            else if (a == "--command" && more) gArgs.commands.push_back(argv[++i]);
            else if (a == "--menu-dump") gArgs.menuDump = true;
            else if (a == "--set" && more) {
                std::string kv = argv[++i];
                size_t eq = kv.find('=');
                if (eq != std::string::npos) gArgs.set.push_back({kv.substr(0, eq), kv.substr(eq + 1)});
            }
        }
        // anything automated must never ask for permissions or keep running
        gArgs.test = gArgs.seconds > 0 || gArgs.listDevices;
        if (!gArgs.log.empty()) logOpen(gArgs.log.c_str());
        // --set key=value: store a setting as if chosen in the menu (for testing that settings persist)
        for (auto &kv : gArgs.set) {
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            NSString *v = ns(kv.second);
            NSScanner *sc = [NSScanner scannerWithString:v];
            double num;
            if ([sc scanDouble:&num] && sc.atEnd) [d setDouble:num forKey:ns(kv.first)];
            else if ([v isEqual:@"YES"] || [v isEqual:@"NO"]) [d setBool:[v isEqual:@"YES"] forKey:ns(kv.first)];
            else [d setObject:v forKey:ns(kv.first)];
        }
        settingsLoad();
        logLine("settings: levels %d deband %d upscale %d sharpen %.2f framegen %d early %d passthrough %d audio %d trim %+.0f ms refresh %d overlay %d",
                gSet.levels.load(), (int)gSet.deband, gSet.upscale.load(), gSet.sharpen.load(), (int)gSet.frameGen, (int)gSet.early, (int)gSet.passthrough,
                (int)gSet.audio, gSet.audioTrim * 1000, gSet.refresh.load(), (int)gSet.overlay);
        if (gArgs.listDevices) { listDevices(); return 0; }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
