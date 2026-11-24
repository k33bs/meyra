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
#include "awake.h"
#include "common.h"
#include "display.h"
#include "framegen.h"
#include "flyhigh.h"
#include "superres.h"
#include "nets.h"
#include "noise.h"
#include "record.h"
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
@property (nonatomic) BOOL marking;      // the next drag on the picture marks a hud area
- (NSRect)pictureRect;                   // where the picture is in the view, in points. empty without a picture
- (void)showAreas:(double)seconds;       // draw the hud areas' outlines: while marking, with hudShow, or for this long
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation>
- (void)command:(NSString *)cmd;
- (void)hudAreaAdd:(NSRect)r;            // in parts of the picture, y from the top. empty: the drag marked nothing
- (void)say:(NSString *)t;               // a hint line that no command's table row covers
@end

static AppDelegate *gApp;

static NSString *const kCmp[] = {@"off", @"left | right", @"above / below", @"diagonal", @"side by side", @"stacked", @"stage strips", @"same strip"};
static NSString *const kCmpLong[] = {@"off", @"original left, final right", @"original above, final below", @"diagonal", @"side by side, the same part", @"one above the other, the same part", @"every stage, strips of the picture", @"every stage, the same strip"};

// presets: a whole set of switches at once, keys 1..9 and 0. each starts from the same plain base, so the same key
// always gives the same thing. levels, colour, audio, window and display settings are left as they are
static const char *const kLookName[] = {"off", "mild", "middle", "strong"};
struct Preset { const char *name, *what; NSDictionary *set; NSArray<NSString *> *nets; };
static const std::vector<Preset> &presets() {
    static const std::vector<Preset> p = {
        {"standard", "dither removal, metalfx, medium sharpening, apple's frame generation on the tick. every experiment off", @{}, nil},
        {"untouched", "plain passthrough: the frames as they came, nothing processed, nothing generated", @{@"passthrough": @YES}, nil},
        {"fastest", "no generated frames, light sharpening: the least delay, for when reaction time matters", @{@"frameGen": @NO, @"sharpen": @0.3}, nil},
        {"smooth", "frame generation with the soft still rule, hud lock and the better cut test: steadier huds", @{@"genStill": @1, @"hudLock": @YES, @"cutTest": @YES}, nil},
        {"smooth, less delay", "the same on the early schedule: frames a few ms sooner, motion a little less even", @{@"early": @YES, @"genStill": @1, @"hudLock": @YES, @"cutTest": @YES}, nil},
        {"second generator", "the second frame generator at 480 lines (needs its files, downloaded on request): sharper generated frames, keeps thin things in pans", @{@"genModel": @1, @"genStill": @1, @"hudLock": @YES, @"cutTest": @YES}, nil},
        {"second generator, less delay", "the second generator on the early schedule: frames a few ms sooner, motion a little less even (needs its files, downloaded on request)", @{@"genModel": @1, @"early": @YES, @"genStill": @1, @"hudLock": @YES, @"cutTest": @YES}, nil},
        {"GTA6 clean", "a net trained on gta vi on real frames against grain and jagged edges, light sharpening, steadier huds", @{@"enhanceReal": @YES, @"sharpen": @0.3, @"genStill": @1, @"hudLock": @YES, @"cutTest": @YES},
            @[@"teach general 6x16", @"detail pix 6x16", @"fsrcnnx"]},
        {"GTA6 clean, second generator", "the net trained on gta vi on real frames with the second generator on the early schedule: the cleanest picture of the generating presets (needs its files, downloaded on request)",
            @{@"enhanceReal": @YES, @"sharpen": @0.3, @"genModel": @1, @"early": @YES, @"genStill": @1, @"hudLock": @YES, @"cutTest": @YES}, @[@"teach general 6x16", @"detail pix 6x16", @"fsrcnnx"]},
        {"GTA6 everything", "the net trained on gta vi and most experiments at once, on the tick",
            @{@"genStill": @3, @"hudLock": @YES, @"cutTest": @YES, @"repeatTol": @YES, @"ptsTime": @YES, @"enhanceReal": @YES, @"enhanceHold": @YES, @"superSample": @YES, @"sharpen": @0.3},
            @[@"teach general 6x16", @"detail gan 6x16", @"fsrcnnx"]},
    };
    return p;
}

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

// the enhance net chosen, where it sits, and why it is not running when it is not
// the net list moves when files are added, so the choice is kept by name beside the number
static void saveNetName() {
    int n = gSet.enhance;
    [NSUserDefaults.standardUserDefaults setObject:n > 0 && n <= nets::count() ? @(nets::name(n)) : @"" forKey:@"enhanceNet"];
}
static void restoreNet() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d volatileDomainForName:NSArgumentDomain][@"enhance"]) return; // a test run names its net by number
    for (auto &kv : gArgs.set) if (kv.first == "enhance") { saveNetName(); return; } // --set enhance=N: that number, and its name from now on
    NSString *name = [d stringForKey:@"enhanceNet"];
    if (!name.length) return; // saved before names were kept: the number as it is
    for (int i = 1; i <= nets::count(); i++) if ([name isEqual:@(nets::name(i))]) { gSet.enhance = i; settingsSave("enhance"); return; }
    gSet.enhance = 0; // its file is gone
}
static NSString *enhanceText() {
    int n = gSet.enhance;
    if (!n || n > nets::count()) return @"off";
    static NSString *const kAt[] = {@"after dither removal", @"before dither removal", @"after the upscaler"};
    NSString *t = [NSString stringWithFormat:@"%@, %@, %@ to smaller windows", @(nets::name(n)), kAt[gSet.enhanceAt % 3], gSet.enhanceDown ? @"lanczos" : @"area"];
    if (gSet.passthrough) return [t stringByAppendingString:@" (off in passthrough)"];
    return *nets::status(n) ? [t stringByAppendingFormat:@" (%@)", @(nets::status(n))] : t;
}

// which upscaler ran this second, and why it is not the chosen one when it is not
static NSString *upscalerText(int up, const renderer::Stats &s, const superres::Stats &r) {
    if (int n = renderer::enhanceRan()) { // the net made the larger picture, or (placed after the upscaler) worked on the upscaler's
        NSString *t = [NSString stringWithFormat:@"enhance %@", @(nets::name(n))];
        return up == 1 ? [@"MetalFX + " stringByAppendingString:t] : up == 3 ? [@"edge-aware FSR 1 + " stringByAppendingString:t] : up == 4 ? [@"edge-aware SGSR 1 + " stringByAppendingString:t] : t;
    }
    NSString *t = s.sr ? [NSString stringWithFormat:@"Apple SR %.1f avg %.1f max ms", r.n ? r.sumMs / r.n : 0, r.maxMs] : up == 1 ? @"MetalFX" : up == 3 ? @"edge-aware FSR 1" : up == 4 ? @"edge-aware SGSR 1" : @"plain";
    if (srYields()) t = [t stringByAppendingString:@" (Apple SR waits while frame generation is on)"];
    else if (s.srLate) t = [t stringByAppendingFormat:@", %d frames by MetalFX (late)", s.srLate];
    else if (effUpscale() == 2 && !s.sr && *superres::status()) t = [t stringByAppendingFormat:@" (Apple SR %s)", superres::status()];
    return t;
}

// one table for the overlay's hint line and the menus' tooltips: what a command is called and what it does.
// key: the command as the menus carry it, a row with its value before the one without ("genstill:1", "genstill");
// "@" and the selector for items appkit runs itself; "#" and the title for a submenu; "-" for lines that only tell
struct Tip { const char *key, *name, *what; };
static const Tip kTips[] = {
    {"fullscreen", "full screen", "the picture fills the screen, esc leaves it. a screen with variable refresh then shows each frame as it comes, with much less delay"},
    {"@toggleFullScreen:", 0, "the picture fills the screen, esc leaves it. a screen with variable refresh then shows each frame as it comes, with much less delay"},
    {"overlay", "status overlay", "source, frame rate, delay, the order things run in, and every switch with its key and what it is set to"},
    {"framegen", "frame generation", "makes a frame between every two real ones when the source repeats frames (a 30 fps game in a 60 hz signal). 60 fps content is shown as it is. one cpu core stays busy"},
    {"schedule:1", 0, "generated and real frames go up a few ms sooner (about 3)"},
    {"schedule:0", 0, "frames go up on the capture tick: the steadiest motion"},
    {"schedule", "frame schedule", "when generated and real frames go up: early, or on the tick"},
    {"genmodel:0", 0, "generated frames come from apple's interpolator, on the neural engine: about 11 ms a frame whatever the gpu is doing. a little soft"},
    {"genmodel:1", 0, "generated frames come from a small flow net on the gpu, working at 480 lines: sharper, holds up on fast pans, small still things can double. shares the gpu with everything else. needs its files in application support, meyra/flyhighfg (experimental)"},
    {"genmodel:2", 0, "the same net working at 720 lines: finer on slow motion, loses fast pans. needs its files in application support, meyra/flyhighfg (experimental)"},
    {"genmodel", "frame generator", "which generator makes the frames in between: apple's, or a second one that is not part of meyra and runs from files you download or install yourself"},
    {"#Frame Generator", 0, "which generator makes the frames in between: apple's, or a second one that is not part of meyra and runs from files you download or install yourself"},
    {"gensmall:0", 0, "apple's interpolator gets the frames at full size: about 11 ms a frame, the sharpest generated frames"},
    {"gensmall:3", 0, "apple's interpolator gets a copy at 1536x864 and the result is scaled back up: about 7 ms instead of 11 a frame, a little softer. 1080p sources only"},
    {"gensmall:2", 0, "apple's interpolator gets a copy at 1344x768 and the result is scaled back up: about 6 ms instead of 11 a frame, softer. 1080p sources only"},
    {"gensmall:1", 0, "apple's interpolator gets a copy at 1280x720, its fast size, and the result is scaled back up: about 4 ms instead of 11 a frame, the softest generated frames. 1080p sources only"},
    {"gensmall", "generate at", "the size apple's interpolator works at. smaller is quicker and softer, real frames are not touched. 1080p sources only"},
    {"#Generate At", 0, "the size apple's interpolator works at. smaller is quicker and softer, real frames are not touched. 1080p sources only"},
    {"gendeadline:0", 0, "early schedule: a generated frame is waited for as long as the slowest recent one took, and never less than 12 ms. few late frames, more delay than a quick generator needs"},
    {"gendeadline:1", 0, "early schedule: a generated frame is waited for as long as 95 in 100 of the last 120 took, plus 2 ms. less delay with a quick generator, the slow few come too late"},
    {"gendeadline", "generated frame deadline", "early schedule: how long a generated frame is waited for before the picture goes on without it"},
    {"#Generated Frame Deadline", 0, "early schedule: how long a generated frame is waited for before the picture goes on without it"},
    {"genlatenext", "late generated frames", "a generated frame that is not ready when due is shown when it comes, a refresh later, instead of being left out. only on a screen that refreshes faster than the source sends (100, 120 hz, variable): at 60 hz the next refresh is the real frame's"},
    {"nethalf", "half precision", "the enhance net does the sums of its layers of up to 24 features in half precision: about 1.2 times quicker on 4x8 and 8x24 nets, next to nothing on 6x16 ones, the picture differs by a level or two of 255 at most. nets of 32 features are slower that way and stay as they are"},
    {"gpuawake", "keep the gpu awake", "a tiny job keeps the gpu busy so it does not slow its clock between frames: the enhance net and the second generator then run about one and a half times as quick, unless something else already has the gpu full. it uses more power and makes more heat for as long as meyra is in front with a picture and one of the two is on"},
    {"genstill:0", 0, "unmoved pixels in generated frames come from the real frames, only where the two real pixels are the same. safe, does little on game pictures"},
    {"genstill:1", 0, "unmoved pixels in generated frames come from the real frames, small dither differences allowed. steadier huds and backgrounds"},
    {"genstill:2", 0, "compares how much a pixel changed with how much contrast is around it. steadiest backgrounds, can fade a thin line moving over a busy area"},
    {"genstill:3", 0, "by motion against contrast, more forgiving. steadiest of all, can erase thin moving things"},
    {"genstill:4", 0, "for tests: generated frames are shown as guessed, nothing is taken from the real frames"},
    {"genstill", "still areas", "pixels that did not change between two real frames are taken from the real frames in generated ones, so huds and backgrounds do not shimmer. the rules differ in what counts as unchanged"},
    {"passthrough", "plain passthrough", "all processing off, frames shown as they came, repeats included (one is left out when the screen's queue has backed up). the other settings are kept"},
    {"levels:0", 0, "the range is told from the darkest values the source sends"},
    {"levels:1", 0, "the source's black is 16 and its white 235. pick it when blacks look grey"},
    {"levels:2", 0, "the source's black is 0 and its white 255. pick it when shadows look crushed"},
    {"levels", "levels", "which range of values the source sends. if blacks look grey or shadows look crushed, pick it by hand"},
    {"colour:0", 0, "what the source says its colours are. the same on every screen, a little flat"},
    {"colour:1", 0, "the contrast of a tv"},
    {"colour:2", 0, "no colour management: most saturated, and different on each screen"},
    {"colour", "colour", "how the picture's colours are handed to macos"},
    {"deband", "dither removal", "takes out the fine checker or noise pattern games add to hide banding, before upscaling and sharpening turn it into grain"},
    {"denoise", "noise filter", "apple's temporal noise filter on the real frames: averages out what flickers. about 10 ms a frame, hard to see on a clean signal"},
    {"hudlock", "hud lock", "pixels that stood still for over a second are taken from the real frame in generated ones, so a hud stays put (experimental)"},
    {"hudmark", "mark hud area", "the next drag on the picture marks a rectangle that always comes from the real frame in generated ones: a minimap, a health bar, subtitles. up to 8, kept as parts of the picture so they fit any window size. esc cancels"},
    {"hudclear", "hud areas", "forgets every marked rectangle"},
    {"hudshow", "show hud areas", "outlines the marked rectangles on the picture while the status overlay is on, compact or with every switch. with the overlay off the picture is clean"},
    {"cuttest", "cut test", "a closer look at whether two frames are a scene cut, so no frame is generated across one. a flash does not count as a cut (experimental)"},
    {"repeattol", "tolerant repeats", "a repeated frame may differ by a few levels and still count as a repeat. for capture devices with a noisy signal (experimental)"},
    {"ptstime", "capture clock", "frames are timed by the capture device's clock instead of by when they arrived (experimental)"},
    {"enhancereal", "enhance real frames only", "the enhance net runs on real frames only, generated frames reuse what it added where the picture is still (experimental)"},
    {"enhancehold", "steady enhance", "what the enhance net adds is held steady over time where the picture is still, against flicker (experimental)"},
    {"look:0", 0, "the picture's colours and brightness as they come"},
    {"look:1", 0, "mild: highlights a little lower, colours a little weaker. fitted on gta vi gameplay, day and night"},
    {"look:2", 0, "the middle between mild and strong"},
    {"look:3", 0, "strong: bright parts well down, shadows up. fitted on one dark gta vi cutscene, daylight gets dull"},
    {"look", "look", "a tone curve like the one of the dlss 5 look in gta vi videos. it changes brightness and colour only, no detail (experimental)"},
    {"supersample", "supersample", "the upscaler makes the picture at twice the window's size, then it is shrunk to the window. smoother edges, more gpu work (experimental)"},
    {"srpad", "super resolution padding", "apple super resolution: 16 mirrored pixels are drawn around each tile, because the scaler rings at the outer edge of what it is given"},
    {"srgen", "super resolution with frame generation", "the two take turns, about 9 ms more delay. off: metalfx is used while frame generation is on"},
    {"enhance:0", 0, "no net, the upscaler chosen under upscaling does its work"},
    {"enhance", "enhance", "a small neural net on every frame, at any window size. most make the picture at twice the size and stand in for the upscaler (experimental)"},
    {"enhanceat:0", 0, "the net runs after dither removal: the normal place"},
    {"enhanceat:1", 0, "the net runs before dither removal: there to compare"},
    {"enhanceat:2", 0, "the net runs on the upscaler's picture, at window size: there to compare"},
    {"enhanceat", "enhance runs", "where the enhance net sits among the other steps"},
    {"enhancedown:0", 0, "in a window smaller than twice the source the net's picture is brought down by averaging"},
    {"enhancedown:1", 0, "in a window smaller than twice the source the net's picture is brought down with lanczos, which keeps more of what the net added"},
    {"enhancedown", "enhance to smaller windows", "how the net's larger picture is brought down to the window"},
    {"upscale:0", 0, "bilinear. soft, free, changes nothing else"},
    {"upscale:1", 0, "apple's spatial upscaler. sharpest, but it also sharpens grain and whatever dither is left"},
    {"upscale:2", 0, "apple's super resolution scaler. cleaner than metalfx but softer, and every frame waits about 9 ms for it. metalfx stands in while it starts"},
    {"upscale:3", 0, "cleaner edges than plain, less grain and crunch than metalfx. costs nothing worth measuring"},
    {"upscale:4", 0, "only touches edges and leaves flat areas as plain, so grain stays as it came"},
    {"upscale", "upscaling", "how the picture gets from the source's size to the window's. it only runs when the window is larger than the source"},
    {"sharp:0", 0, "no sharpening"},
    {"sharp:0.3", 0, "a little. brightness only, colour is left alone. the one to pick with enhance or metalfx on"},
    {"sharp:0.6", 0, "the usual amount. brightness only, colour is left alone, edges get no bright halos"},
    {"sharp:0.9", 0, "a lot. brightness only, edges get no bright halos, grain gets sharper too"},
    {"sharp+", 0, "one step sharper. brightness only, colour is left alone"},
    {"sharp-", 0, "one step softer"},
    {"sharp", "sharpening", "brightness only, colour is left alone, and limited so edges get no bright halos. with enhance or metalfx on, go lower"},
    {"audio", "audio", "the source's sound, held back so it lands with the picture. switching it restarts the source"},
    {"trim-", "audio", "the sound 5 ms earlier, for when lips and voices are off"},
    {"trim+", "audio", "the sound 5 ms later, for when lips and voices are off"},
    {"trim0", "audio", "back to the measured delay, no nudge"},
    {"refresh:0", 0, "the display's mode is left alone"},
    {"refresh:1", 0, "the display is only switched when its rate is not a multiple of the source's, and only while meyra runs"},
    {"refresh:2", 0, "the display runs at the source's rate while meyra runs"},
    {"refresh", "match display refresh", "whether meyra may switch the display's refresh rate to fit the source"},
    {"source", "source", "show this source"},
    {"format", "format", "the signal format asked of the device. choosing one restarts the source"},
    {"ain", "audio input", "where the sound is taken from. choosing one restarts the source"},
    {"restart", "source", "stopped and started again, the levels are detected afresh"},
    {"replay", 0, "plays a folder of recorded raw frames (NAME_f000.uyvy, ...) as the source"},
    {"picker", 0, "the capture device, its format and its audio input in one window"},
    {"snapshot", "snapshot", "one processed frame as png in pictures, without the overlay"},
    {"actual", "window", "one picture pixel per screen pixel: the source's own size"},
    {"winsize+", "window size", "steps through 720p, 900p, 1080p, 1440p, 2160p, whatever fits the screen. in full screen: the size the picture is made at"},
    {"winsize", "window size", "the picture this many pixels high, the width follows the source's shape"},
    {"keys", 0, "the list of single keys that work while the picture has focus"},
    {"updates", 0, "asks github whether there is a newer meyra"},
    {"updatesAtLaunch", "check for updates at launch", "asks once at every start, quiet unless there is something newer"},
    {"revertUpdate", 0, "back to the version that was installed before the last update"},
    {"record", "recording", "what is on screen goes to a .mov in the movies folder (meyra), encoded by the mac's video encoder, with the sound. the picture on screen never waits for it. while the last seconds are kept, this saves them instead"},
    {"reckeep", "keep the last seconds", "the last 30 seconds are held in memory all the time, already encoded, and tab writes them to a file: for what just happened. an amber dot in the corner shows it is on"},
    {"recoverlay", "overlay in recordings", "the status overlay and the hint lines are part of the file. off: the picture only, the mark in the corner is never in it"},
    {"recsize", "recording size", "how high the file is at most. a bigger picture is scaled down on the gpu before it is encoded: smaller files, less work for the encoder. as shown: every pixel the window draws"},
    {"recrate", "recording bitrate", "megabits a second of video. more: a bigger file, less lost in fast motion"},
    {"recfolder", 0, "opens the folder the recordings go to"},
    {"freeze", "freeze the picture", "the newest real frame stays up and every switch but the noise filter still acts on it, to compare without it moving. the sound and the source run on"},
    {"compare:0", "compare view", "off: the finished picture alone"},
    {"compare:1", 0, "cut: the original left, the finished picture right. the original's half keeps the game's own frame rate"},
    {"compare:2", 0, "cut: the original above, the finished picture below"},
    {"compare:3", 0, "cut: a diagonal line, the original left and below it, the finished picture right and above"},
    {"compare:4", 0, "side by side: the same middle half of the picture, the original left, the finished one right"},
    {"compare:5", 0, "one above the other: the same middle half of the picture, the original above, the finished one below"},
    {"compare:6", 0, "the picture in strips, left to right as the chain goes: each strip one stage further on, the last the result"},
    {"compare:7", 0, "the same middle strip of the picture from every stage, side by side: what each stage does to the same thing"},
    {"compare", "compare view", "the original against the finished picture, or every stage of the chain, on the picture"},
    {"keepres", "full screen keeps the window's resolution", "renders at the window's size and stretches that to the screen, instead of rendering at the screen's size. lighter on the gpu"},
    {"power", 0, "off: the capture device is let go and nothing is drawn, generated or played, as if meyra were closed. the window, the settings and what the last seconds kept stay. on: the same source starts again"},
    {"vsync", "vsync", "frames wait for the display. off shows them a few ms sooner and can tear"},
    {"gamemode", "game mode", "meyra tells macos it is a game, so full screen gets game mode: more cpu and gpu priority. counts from the next start"},
    {"@orderFrontStandardAboutPanel:", 0, "version and licence"},
    {"@hide:", 0, "hides meyra. macos stops updating a window that is hidden"},
    {"@hideOtherApplications:", 0, "hides every other app"},
    {"@unhideAllApplications:", 0, "brings hidden apps back"},
    {"@quit", 0, "stops the source, gives the display its mode back and quits"},
    {"@performMiniaturize:", 0, "the window goes to the dock. macos stops updating it there"},
    {"@performZoom:", 0, "the window as large as the screen lets it be"},
    {"@arrangeInFront:", 0, "meyra's windows in front of the other apps'"},
    {"#Compare", 0, "the original against the finished picture, or every stage of the chain, on the picture"},
    {"#Presets", 0, "ten sets of switches on the number keys. shift + a number saves the switches as they are now on that key"},
    {"#Meyra", 0, "the app itself: vsync, game mode, updates"},
    {"#Source", 0, "which device or recording is shown, its format and sound, snapshots"},
    {"#Picture", 0, "what is done to every frame: levels, colour, dither removal, upscaling, enhance, sharpening"},
    {"#Motion", 0, "frame generation and how the display's refresh rate is matched"},
    {"#Audio", 0, "the source's sound and when it plays"},
    {"#Window", 0, "full screen, window size, the status overlay"},
    {"#Help", 0, "the single keys"},
    {"#Services", 0, "what other apps offer here"},
    {"#Still Areas in Generated Frames", 0, "pixels that did not change between two real frames are taken from the real frames in generated ones, so huds and backgrounds do not shimmer. the rules differ in what counts as unchanged"},
    {"-nodevices", 0, "connect a capture device, or open a replay folder"},
    {"-driver", 0, "this maker's own driver is not installed. usb capture devices need nothing extra"},
    {"@makeKeyAndOrderFront:", 0, "brings this window to the front"},
    {"-", 0, "only a label, nothing to choose"},
};
static const Tip *tipRow(NSString *key) {
    for (auto &t : kTips) if ([key isEqualToString:@(t.key)]) return &t;
    return nullptr;
}
// the row for a command with its value ("genstill:1"), else the one for the command alone
static const Tip *tipFor(NSString *cmd) {
    NSRange colon = [cmd rangeOfString:@":"];
    const Tip *t = tipRow(cmd);
    return t || colon.location == NSNotFound ? t : tipRow([cmd substringToIndex:colon.location]);
}
static NSString *tipText(NSMenuItem *i) {
    NSString *c = [i.representedObject isKindOfClass:NSString.class] ? i.representedObject : nil;
    const Tip *t = nullptr;
    if (i.submenu) {
        t = tipRow([@"#" stringByAppendingString:i.title]);
        // a submenu of one setting's values says what the setting is
        NSString *first = i.submenu.itemArray.firstObject.representedObject;
        if (!t && [first isKindOfClass:NSString.class]) t = tipRow([first componentsSeparatedByString:@":"].firstObject);
    } else if (c) t = tipFor(c);
    else if (i.action) t = tipRow([@"@" stringByAppendingString:NSStringFromSelector(i.action)]);
    else t = tipRow(@"-");
    return t ? @(t->what) : nil;
}
static void setTips(NSMenu *m) {
    for (NSMenuItem *i in m.itemArray) {
        if (i.separatorItem) continue;
        if (!i.toolTip.length) i.toolTip = tipText(i);
        if (i.submenu) setTips(i.submenu);
    }
}

// overlay text: a label and its parts, wrapped so that nothing is wider than the picture. the renderer draws the
// overlay at its own size, what does not fit is cut off
static const NSUInteger kLabelW = 9;
static void addLine(NSMutableArray<NSString *> *out, NSString *label, NSArray<NSString *> *parts, NSString *sep, NSUInteger cols) {
    NSString *indent = [@"" stringByPaddingToLength:kLabelW withString:@" " startingAtIndex:0];
    NSString *lead = [sep stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; // an arrow goes along to the next line
    NSMutableString *cur = [[label stringByPaddingToLength:kLabelW withString:@" " startingAtIndex:0] mutableCopy];
    bool first = true;
    for (NSString *p in parts) {
        if (!p.length) continue;
        if (first) [cur appendString:p];
        else if (cur.length + sep.length + p.length <= cols) [cur appendFormat:@"%@%@", sep, p];
        else {
            [out addObject:cur];
            cur = [indent mutableCopy];
            if (lead.length) [cur appendFormat:@"%@ ", lead];
            [cur appendString:p];
        }
        first = false;
        while (cur.length > cols) { // one part longer than a line: break it at a space
            NSRange sp = [cur rangeOfString:@" " options:NSBackwardsSearch range:NSMakeRange(kLabelW + 3, cols - kLabelW - 2)];
            if (sp.location == NSNotFound) break;
            [out addObject:[cur substringToIndex:sp.location]];
            cur = [[NSString stringWithFormat:@"%@  %@", indent, [cur substringFromIndex:sp.location + 1]] mutableCopy];
        }
    }
    [out addObject:cur];
}

// frame rates as people say them: 59 or 61 counted in a second is 60
static int roundRate(int v) {
    for (int c : {24, 25, 30, 50, 60, 100, 120}) if (abs(v - c) <= 1) return c;
    return v;
}

@implementation MeyraView {
    NSView *_areasView;                  // the outlines, a layer of its own above the picture. hidden when there is nothing to draw
    CAShapeLayer *_areas;
    BOOL _dragging;
    NSPoint _from, _to;
    double _areasUntil;
}
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
static CGSize gWindowed; // the picture's size in the window, what full screen keeps with keepRes. w steps it in full screen
- (void)fit {
    CGFloat s = self.window.backingScaleFactor ?: 1;
    renderer::layer().contentsScale = s;
    // keepRes: full screen goes on drawing at the size the window had, and the layer stretches that to the screen
    // (same shape, black at the sides if the screen is wider). the chain then does in full screen what it did in the window
    CGSize now = CGSizeMake(self.bounds.size.width * s, self.bounds.size.height * s);
    bool full = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (!full) gWindowed = now;
    bool keep = full && gSet.keepRes && gWindowed.width > 0;
    // the drawable keeps the screen's shape and is only made smaller, so that the picture in it is as large as it was
    // in the window. the renderer centres the picture in the drawable, so its ratio holds on any screen (a drawable in
    // the window's shape was stretched to fill an ultrawide one: the layer's gravity does not hold a metal layer back)
    CGSize draw = now;
    if (keep) {
        int w, h, fw, fh, up;
        renderer::lastSize(w, h, fw, fh, up);
        double a = w > 0 && h > 0 ? (double)w / h : 16.0 / 9;
        double was = fmin(gWindowed.width, gWindowed.height * a), is = fmin(now.width, now.height * a); // the picture's width then and now
        double k = fmin(1, was / fmax(1, is));
        draw = CGSizeMake(round(now.width * k), round(now.height * k));
    }
    renderer::layer().contentsGravity = kCAGravityResize;
    renderer::layer().drawableSize = draw;
    renderer::setScale(s);
}
- (void)setFrameSize:(NSSize)z { [super setFrameSize:z]; [self fit]; [self showAreas:0]; }
// the renderer centres the picture in the drawable (fitSize), and the layer stretches the drawable over the view, or
// with keepRes in full screen fits it in with its shape kept. the same two steps here, in points, y up
- (NSRect)pictureRect {
    int w, h, fw0, fh0, up;
    renderer::lastSize(w, h, fw0, fh0, up);
    CAMetalLayer *l = renderer::layer();
    CGSize d = l.drawableSize;
    NSSize b = self.bounds.size;
    if (w <= 0 || h <= 0 || d.width < 2 || d.height < 2 || b.width <= 0 || b.height <= 0) return NSZeroRect;
    size_t dw = (size_t)d.width, dh = (size_t)d.height, fw, fh;
    renderer::fitSize(dw, dh, w, h, fw, fh);
    double x0 = (double)((dw - fw) / 2), y0 = (double)((dh - fh) / 2); // from the drawable's top left
    double sx = b.width / dw, sy = b.height / dh, ox = 0, oy = 0;
    if ([l.contentsGravity isEqual:kCAGravityResizeAspect]) { sx = sy = fmin(sx, sy); ox = (b.width - dw * sx) / 2; oy = (b.height - dh * sy) / 2; }
    return NSMakeRect(ox + x0 * sx, b.height - (oy + (y0 + fh) * sy), fw * sx, fh * sy);
}
- (void)showAreas:(double)seconds {
    if (seconds > 0) {
        _areasUntil = nowSec() + seconds;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self showAreas:0]; });
    }
    NSRect pr = self.pictureRect;
    CGMutablePathRef path = CGPathCreateMutable();
    if (pr.size.width > 0 && (_marking || (gSet.hudShow && gSet.overlay) || nowSec() < _areasUntil)) // shown: only with the overlay
        for (int i = 0, n = gSet.hudN; i < n; i++) {
            double x = gSet.hudRect[4 * i], y = gSet.hudRect[4 * i + 1], rw = gSet.hudRect[4 * i + 2], rh = gSet.hudRect[4 * i + 3];
            CGPathAddRect(path, NULL, CGRectMake(pr.origin.x + x * pr.size.width, NSMaxY(pr) - (y + rh) * pr.size.height, rw * pr.size.width, rh * pr.size.height));
        }
    if (_dragging) CGPathAddRect(path, NULL, NSIntersectionRect(NSMakeRect(fmin(_from.x, _to.x), fmin(_from.y, _to.y), fabs(_to.x - _from.x), fabs(_to.y - _from.y)), pr));
    if (!_areasView && !CGPathIsEmpty(path)) {
        _areas = [CAShapeLayer layer];
        _areas.fillColor = NULL;
        _areas.strokeColor = [NSColor colorWithRed:1 green:0.86 blue:0.45 alpha:1].CGColor;
        _areas.lineWidth = 1.5;
        _areas.shadowOpacity = 1; _areas.shadowRadius = 1.5; _areas.shadowOffset = CGSizeZero; // a dark rim, so the line shows on a bright picture too
        _areasView = [[NSView alloc] initWithFrame:self.bounds];
        _areasView.layer = _areas;
        _areasView.wantsLayer = YES;
        _areasView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_areasView];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _areas.path = path;
    _areasView.hidden = CGPathIsEmpty(path);
    [CATransaction commit];
    CGPathRelease(path);
}
- (void)setMarking:(BOOL)m {
    _marking = m;
    if (!m) _dragging = NO;
    [self.window invalidateCursorRectsForView:self];
    [self showAreas:0];
}
- (void)resetCursorRects { if (_marking) [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (void)mouseDown:(NSEvent *)ev {
    if (!_marking) { [super mouseDown:ev]; return; }
    _from = _to = [self convertPoint:ev.locationInWindow fromView:nil];
    _dragging = YES;
}
- (void)mouseDragged:(NSEvent *)ev {
    if (!_dragging) { [super mouseDragged:ev]; return; }
    _to = [self convertPoint:ev.locationInWindow fromView:nil];
    [self showAreas:0];
}
- (void)mouseUp:(NSEvent *)ev {
    if (!_dragging) { [super mouseUp:ev]; return; }
    _to = [self convertPoint:ev.locationInWindow fromView:nil];
    NSRect pr = self.pictureRect, r = NSIntersectionRect(NSMakeRect(fmin(_from.x, _to.x), fmin(_from.y, _to.y), fabs(_to.x - _from.x), fabs(_to.y - _from.y)), pr);
    self.marking = NO;
    // a click, or a drag beside the picture: nothing
    bool ok = pr.size.width > 0 && r.size.width >= 4 && r.size.height >= 4;
    [gApp hudAreaAdd:ok ? NSMakeRect((r.origin.x - pr.origin.x) / pr.size.width, (NSMaxY(pr) - NSMaxY(r)) / pr.size.height, r.size.width / pr.size.width, r.size.height / pr.size.height) : NSZeroRect];
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fit]; }
// single key shortcuts. only reach here while the picture has focus, never while typing in a text field
- (void)keyDown:(NSEvent *)ev {
    if (ev.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) { [super keyDown:ev]; return; }
    NSString *k = ev.charactersIgnoringModifiers;
    NSDictionary *map = @{@"f": @"fullscreen", @"v": @"vsync", @"w": @"winsize+", @"h": @"overlay", @"g": @"framegen", @"e": @"schedule", @"z": @"passthrough", @"r": @"levels+", @"c": @"colour+", @"x": @"keepres",
                          @"b": @"deband", @"m": @"upscale+", @"n": @"enhance+", @"d": @"denoise", @"s": @"genstill+", @"t": @"gensmall", @"i": @"genmodel+", @"l": @"hudlock", @"k": @"cuttest", @"p": @"repeattol", @"j": @"ptstime", @"o": @"enhancereal", @"y": @"enhancehold", @"u": @"supersample", @".": @"look+", @"q": @"hudmark", @"[": @"sharp-", @"]": @"sharp+", @"a": @"audio", @";": @"trim-", @"'": @"trim+"};
    static const int kDigit[] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25}; // key codes of 0..9, shift changes the character
    int digit = -1;
    for (int i = 0; i < 10; i++) if (ev.keyCode == kDigit[i]) digit = i;
    if (ev.keyCode == 53 && _marking) [gApp command:@"hudmark"]; // esc: not this time
    // the number row by where the keys are, and before the letters: on a french keyboard the 4 key types an apostrophe,
    // which is the audio trim key, and a plain press must not save
    else if (ev.keyCode == 48) { if (!ev.isARepeat) [gApp command:(ev.modifierFlags & NSEventModifierFlagShift) ? @"reckeep" : @"record"]; } // tab
    else if (ev.keyCode == 49) { if (!ev.isARepeat) [gApp command:@"freeze"]; } // space
    else if ((ev.keyCode == 36 || ev.keyCode == 76) && gSet.genModel && framegen::available() && !flyhigh::complete()) { if (!ev.isARepeat) [gApp command:[NSString stringWithFormat:@"genget:%d", gSet.genModel.load()]]; } // return: while the second generator is chosen and missing
    else if (digit >= 0) [gApp command:[NSString stringWithFormat:(ev.modifierFlags & NSEventModifierFlagShift) ? @"presetsave:%d" : @"preset:%d", digit ? digit : 10]];
    else if (ev.keyCode == 39 && !map[k]) [gApp command:@"trim+"]; // the apostrophe's place: a french keyboard has the apostrophe on the 4, which is a preset
    else if (map[k]) [gApp command:map[k]]; // before the slash's place: dvorak types z there, turkish and russian a full stop
    else if (ev.keyCode == 44 || ev.keyCode == 75 || [k isEqual:@"/"] || [k isEqual:@"?"]) [gApp command:(ev.modifierFlags & NSEventModifierFlagShift) ? @"compare-" : @"compare+"]; // slash by what the key types or where it is, and the number pad's
    else if (k.length == 1 && [k characterAtIndex:0] >= '0' && [k characterAtIndex:0] <= '9') [gApp command:[NSString stringWithFormat:@"preset:%d", k.intValue ? k.intValue : 10]]; // the number pad
    else if (ev.keyCode == 53 && (self.window.styleMask & NSWindowStyleMaskFullScreen)) [self.window toggleFullScreen:nil];
    else [super keyDown:ev];
}
@end


// held while a source may run: the activity ends when it is given back. display sleep off too: a controller is no
// input to the mac, the screen would dim mid-game
static void liveActivity(bool on) {
    static id act;
    if (on == (act != nil)) return;
    if (on) act = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical | NSActivityIdleDisplaySleepDisabled reason:@"live video"];
    else { [NSProcessInfo.processInfo endActivity:act]; act = nil; }
}

static int recMaxH() { id v = [NSUserDefaults.standardUserDefaults objectForKey:@"recMaxHeight"]; return v ? [v intValue] : 1080; } // as shown: 0

@implementation AppDelegate {
    NSWindow *_win;
    MeyraView *_view;
    std::unique_ptr<Source> _source;
    std::string _sourceId, _sourceName;
    SourceStatus _status;
    bool _sourceAudio;
    bool _hadFrames;
    bool _goingFull; // entering full screen, or in it
    bool _off;       // turned off by hand: no source runs, the window stays
    int _framesLastSecond;
    double _fps;
    int _aspectW, _aspectH;
    std::string _missingId;        // saved device that is not connected; started when it shows up
    NSPanel *_picker;
    NSPopUpButton *_pickSource, *_pickFormat, *_pickAudio;
    NSTextField *_pickFormatLabel, *_pickAudioLabel, *_pickNote;
    std::vector<SourceInfo> _pickList;
    renderer::Stats _last;
    framegen::Stats _lastGen;
    superres::Stats _lastSr;
    int _noiseN;
    NSString *_lastCmd;            // the command last run, its row is marked in the overlay
    int _presetWas;                // the preset the switches came from before one was changed by hand
    int _preset;                   // the preset last chosen (1..), 0 once a switch was changed by hand
    int _genWant;                  // the generator to switch to when its download ends, 0 once something else was chosen
    NSString *_hint;               // what the last command set and what that does, shown until _hintUntil
    double _hintUntil;
    double _videoDelay, _noiseMs;
    NSMenu *_sourceMenu;
    std::string _curDefaultFormat;
    bool _updating;
}


- (void)applicationDidFinishLaunching:(NSNotification *)n {
    gApp = self;
    nets::load([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"nets"]);
    // your own weights: any *.net dropped here is listed after the ones that ship
    nets::load([NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Meyra/nets"]);
    restoreNet();
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
    record::init(renderer::layer().device, ^(NSString *t) { [self say:t]; });
    record::overlay([NSUserDefaults.standardUserDefaults boolForKey:@"recOverlay"]);
    record::limit(recMaxH());
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recKeep"]) { renderer::layer().framebufferOnly = NO; record::keep(true); }
    renderer::startThread();
    framegen::startThread();
    superres::startThread();
    noise::startThread();

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
    // activate (hidden): a test window that stays behind the others is never put on screen, and nothing about the display can be measured
    if (!gArgs.test || [NSUserDefaults.standardUserDefaults boolForKey:@"activate"]) [NSApp activateIgnoringOtherApps:YES];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"gpuAwakeBack"]) awake::setFront(true);
    if (gArgs.fullscreen) { _goingFull = true; [_win toggleFullScreen:nil]; } // the will-enter callback can come after the first frame

    liveActivity(true);
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *) { [self second]; }];
    watchDevices([self] { [self devicesChanged]; });
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeScreenNotification object:_win queue:nil usingBlock:^(NSNotification *) { [self applyRefresh]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:nil usingBlock:^(NSNotification *) { display::modeChanged(self->_win.screen); }];

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
// gpuAwake only works while meyra is the app in front
- (void)applicationDidBecomeActive:(NSNotification *)n { awake::setFront(true); }
- (void)applicationDidResignActive:(NSNotification *)n {
    static const bool back = [NSUserDefaults.standardUserDefaults boolForKey:@"gpuAwakeBack"]; // hidden, for tests: also behind other apps
    awake::setFront(back);
}

- (void)applicationWillTerminate:(NSNotification *)n {
    awake::stop();
    [self stopSource];
    renderer::stopThread();
    record::finish(); // closes the file
    framegen::stopThread();
    superres::stopThread();
    noise::stopThread();
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
    _off = false;
    liveActivity(true);
    bool same = id == _sourceId;
    _sourceId = id;
    _sourceName = id.rfind("replay:", 0) == 0 ? "Replay" : id;
    for (auto &s : listSources()) if (s.id == id) _sourceName = s.name;
    if (id.rfind("replay:", 0) == 0) _sourceName = std::string("Replay: ") + [ns(id.substr(7)) lastPathComponent].UTF8String;
    _win.subtitle = ns(_sourceName);
    _hadFrames = false;
    gSet.freeze = false;
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
        gSet.freeze = false;
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
    flyhigh::installed(); // the look at the disk happens here, on the main thread
    renderer::Stats s = renderer::takeStats();
    framegen::Stats g = framegen::takeStats();
    superres::Stats r = superres::takeStats();
    audio::Stats a = audio::takeStats();
    noise::Stats nz = noise::takeStats();
    _noiseMs = nz.n ? nz.sumMs / nz.n : 0;
    _noiseN = nz.n;
    if (!s.drawn) memcpy(s.did, _last.did, sizeof s.did); // nothing drawn this second (a still picture): the order line keeps what it knew
    _last = s; _lastGen = g; _lastSr = r;
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
    if (s.in > 0 && _source) { // not the last frames of a source that was just stopped: its message stays
        if (!_hadFrames) { _hadFrames = true; [self applyRefresh]; }
        [self showMessage:nil];
    } else if (_source) {
        NSString *m;
        if (_status.state == SourceState::Error) m = ns(_status.text);
        else if (_status.state == SourceState::NoSignal || s.nosignal > 0) m = [NSString stringWithFormat:@"%@\nCheck that the source is switched on and the cable is connected.", ns(_status.text.empty() ? "No signal" : _status.text)];
        else if (_status.state == SourceState::Running) m = [NSString stringWithFormat:@"No picture from %@ (%@).\nIf the source sends a mode this device cannot capture, set it to 1080p.", ns(_sourceName), ns(_status.text)];
        else m = [NSString stringWithFormat:@"%@…", ns(_status.text)];
        if (_hadFrames) { _hadFrames = false; gSet.freeze = false; renderer::clear(); }
        [self showMessage:m];
    }

    // t, and everything from "chain" on: for the test harness. chain and sched say what really runs, gpu busy counts
    // every command buffer, pre is how long the interpolator waited for the stages before it
    static const bool snapQuit = [NSUserDefaults.standardUserDefaults boolForKey:@"snapQuit"]; // hidden: quit once the numbered snapshots are saved
    if (snapQuit && renderer::snapsLeft() == 0) dispatch_async(dispatch_get_main_queue(), ^{ [self quit]; });
    const char *genState = !effFrameGen() ? "off" : !framegen::available() ? "unavailable" : *framegen::status() ? framegen::status() : gSet.early ? "early" : "tick";
    logLine("t %.1f in %d real %d repeat %d (%d inexact) late %d nosignal %d rolled %d | drawn %d superseded %d | on screen: %d uneven gaps of %d, longest %.1f ms, %d never shown | "
            "gen %s made %d late %d skipped %d, %.1f avg %.1f max ms, convert %.2f ms | gpu %.2f avg %.2f max ms | tick %.1f max, drawable wait %.1f max ms, timed wake late %.2f max ms | "
            "real->present %.1f ms | real->glass %.1f avg %.1f min %.1f max ms (%d) | %dx%d -> %dx%d %s sharpen %.1f deband %d levels %s (darkest %d) | enhance %s | "
            "chain %s sched %s thermal %d | gpu busy %.1f ms/s pre %.2f avg %.2f max noise %.1f avg %.1f max (%d raw) | "
            "net %d runs %.0f Mpx through its passes | real only %s | steady %s | supersample %s | drained %d | hud areas %d",
            sinceStart(), s.in, s.real, s.repeats, s.nearRepeats, s.late, s.nosignal, s.rolled, s.drawn, s.superseded, s.gapBad, s.gapN, s.gapMax, s.notShown,
            genState, s.gen, s.genLate, s.genSkipped, g.n ? g.sumMs / g.n : 0, g.maxMs, s.convN ? s.convSum / s.convN : 0,
            s.gpuN ? s.gpuSum / s.gpuN : 0, s.gpuMax, s.tickMax, s.drawableMax, s.schedLateMax,
            s.toPresN ? s.toPresSum / s.toPresN : 0, s.toGlassN ? s.toGlassSum / s.toGlassN : 0, s.toGlassN ? s.toGlassMin : 0, s.toGlassMax, s.toGlassN,
            w, h, fw, fh, upscalerText(up, s, r).lowercaseString.UTF8String, effSharpen(), (int)effDeband(), renderer::fullRange() ? "full" : "video", s.in ? s.darkest : -1, enhanceText().UTF8String,
            chainText(renderer::chainNow()).c_str(), !effFrameGen() ? "off" : renderer::deepNow() ? "deep" : gSet.early ? "early" : "tick", (int)NSProcessInfo.processInfo.thermalState,
            s.gpuBusy, g.waitN ? g.waitSum / g.waitN : 0, g.waitMax, _noiseMs, nz.maxMs, s.noiseRaw,
            s.net, s.netPx / 1e6, renderer::extraText(0, s).c_str(), renderer::extraText(1, s).c_str(), renderer::extraText(2, s).c_str(), s.drained, gSet.hudN.load());
    if (gSet.hudShow || _view.marking) [_view showAreas:0]; // the picture's place can have changed
    // the experimental switches: a line of their own, only while one is on
    if (gSet.hudLock || gSet.cutTest || gSet.repeatTol || gSet.ptsTime)
        logLine("extras: hud lock %.2f%% of the picture locked (-100: not counted) | cuts %d flashes %d | repeats: most samples over the band %d, largest block shift %.3f | "
                "capture clock: deviation %.2f ms margin %.2f ms, ignored %d followed %d restarts %d",
                renderer::hudLocked() * 100, s.cuts, s.flashes, s.repOver, s.repShift, s.ptsJit, s.ptsMargin, s.ptsIgnored, s.ptsMoved, s.ptsResets);
    // the speed switches: the same, only while one is on
    if (gSet.genDeadline || gSet.genLateNext || gSet.gpuAwake)
        logLine("speed: deadline %s %.1f ms after arrival | late frames shown a refresh on %d (room %d) | gpu awake %s, job %.2f ms",
                gSet.genDeadline ? "by the usual" : "by the slowest", renderer::genBudgetMs(), s.genNext, (int)renderer::genLateRoom(), awake::running() ? "running" : gSet.gpuAwake ? "resting" : "off", awake::jobMs());
    if (audio::running())
        logLine("   audio %d frames/s | delay %.0f ms (video %.0f, trim %+.0f) | underruns %d overruns %d resyncs %d gaps %d | jitter %.1f ms | "
                "peak in %.3f %.3f (any channel %.3f) out %.3f | %s",
                a.frames, a.delayMs, _videoDelay * 1000, gSet.audioTrim * 1000, a.underruns, a.overruns, a.resyncs, a.gaps, a.jitterMs,
                a.peakL, a.peakR, a.rawPeak, a.outPeak, audio::statusLine().c_str());
    if (s.in) logLine("   order %s | cadence %s%s%s", [[self orderParts:s] componentsJoinedByString:@" -> "].UTF8String, [self cadence:s].UTF8String,
                      gSet.frameGen && [self genWhy:s] ? " | not generating: " : "", gSet.frameGen ? ([self genWhy:s] ?: @"").UTF8String : "");
    if (s.stageN) logLine("   stages %s | their sum %.2f of %.2f ms, the gpu time of the %d command buffers measured", [[self stageParts:s] componentsJoinedByString:@"  "].UTF8String,
                          [self stageSum:s], s.stageCb, s.stageN);
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


static NSString *oo(bool b) { return b ? @"on" : @"off"; }

// why frame generation is on and makes nothing, in a few words. nil: it is generating
- (NSString *)genWhy:(const renderer::Stats &)s {
    if (gSet.passthrough) return @"off in plain passthrough";
    if (!framegen::available()) return @"not available on this macos (needs macos 26 and apple silicon)";
    const char *st = framegen::status();
    if (!strcmp(st, "starting")) return @"starting";
    if (*st) return [@"failed, " stringByAppendingString:@(st)];
    if (s.gen > 0) return nil;
    if (!s.in) return @"no picture";
    if (!s.real) return @"the picture is still";
    if (s.repeats * 4 < s.in) return @"source sends no repeated frames";
    if (s.genSkipped) return @"too much changes from frame to frame";
    if (s.genLate) return @"generated frames not ready in time";
    return @"waiting for a pair of frames";
}

// new frames in the signal's frames, as counted this second
- (NSString *)cadence:(const renderer::Stats &)s {
    int in = roundRate(s.in), real = roundRate(s.real);
    NSString *what = !s.in ? @"" : !s.real ? @" (still picture)" : s.repeats * 4 < s.in ? @" (no repeated frames)" : abs(2 * real - in) <= 2 ? @" (every frame comes twice)" : @"";
    return [NSString stringWithFormat:@"%d in %d%@", real, in, what];
}

// the order line: what the frames drawn this second went through, in the order it happened. a stage that is switched
// on and did not run is named with the reason
- (NSArray<NSString *> *)orderParts:(const renderer::Stats &)s {
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    using namespace renderer; // kDid*, kSt*
    NSMutableArray<NSString *> *o = [NSMutableArray new];
    bool pass = gSet.passthrough;
    auto did = [&](int i) { return s.did[i] > 0; };
    if (!s.in && !s.drawn) return @[@"no picture yet"];
    [o addObject:h ? [NSString stringWithFormat:@"input %dp%@", h, gSet.repeatTol && !pass ? @" (tolerant repeats)" : @""] : @"input"];
    if (effNoise() || (gSet.denoise && !pass && !(gSet.chain & kChainSet))) [o addObject:_noiseN ? @"noise filter" : *noise::status() ? [NSString stringWithFormat:@"noise filter idle: %s", noise::status()] : @"noise filter idle"];
    int en = gSet.enhance, ran = renderer::enhanceRan();
    NSString *net = [NSString stringWithFormat:@"enhance (%@%@%@%@)", @(nets::name(ran ?: en)).lowercaseString, gSet.enhanceReal ? @", real frames only" : @"", gSet.enhanceHold ? @", steady" : @"", nets::half(ran ?: en) ? @", half" : @""];
    if (did(kDidPreD)) [o addObject:@"dither removal"];
    if (did(kDidPreE)) [o addObject:net];
    // the interpolator works on the frames as they came, before levels
    if (gSet.frameGen && !pass) {
        NSString *why = [self genWhy:s];
        int gm = framegen::model();
        NSString *by = gm ? [NSString stringWithFormat:@", second generator at %d lines", gm == 2 ? 720 : 480] : *framegen::modelNote() ? [NSString stringWithFormat:@", apple's: %s", framegen::modelNote()] : @"";
        if (!why) [o addObject:[NSString stringWithFormat:@"frame generation (%@%@%@%@%@%@)", renderer::deepNow() ? @"in turns" : gSet.early ? @"early" : @"tick", by,
                               renderer::genSmallNow() ? [NSString stringWithFormat:@", at %dp", kGenSmallH[renderer::genSmallNow()]] : @"", gSet.hudLock ? @", hud lock" : @"", gSet.cutTest ? @", cut test" : @"",
                               gSet.hudN ? [NSString stringWithFormat:@", %d hud area%s", gSet.hudN.load(), gSet.hudN == 1 ? "" : "s"] : @""]];
        else if ([why isEqual:@"starting"]) [o addObject:@"frame generation starting"];
        else [o addObject:[@"frame generation idle: " stringByAppendingString:[why componentsSeparatedByString:@" ("].firstObject]];
    }
    [o addObject:renderer::fullRange() ? @"levels (full range)" : @"levels (video range)"];
    bool anyNet = did(kDidPreE) || did(kDidE0) || did(kDidE1) || did(kDidE2);
    if (did(kDidE1)) [o addObject:net];
    if (did(kDidD)) [o addObject:@"dither removal"];
    if (did(kDidE0)) [o addObject:net];
    if (en && !pass && !anyNet) {
        const char *st = en > nets::count() ? "no such net" : nets::status(en);
        [o addObject:!strcmp(st, "starting") ? @"enhance starting" : *st ? [NSString stringWithFormat:@"enhance idle: %@", @(st)] : @"enhance idle"];
    }
    NSString *sharp = [NSString stringWithFormat:@"sharpen %.1f", effSharpen()];
    if (did(kDidSharpFirst)) [o addObject:sharp];
    static NSString *const kUp[] = {@"plain", @"metalfx", @"apple super resolution", @"edge-aware fsr 1", @"edge-aware sgsr 1"};
    int best = 0, want = gSet.upscale;
    for (int i = 1; i <= 4; i++) if (s.did[kDidUp + i] > (best ? s.did[kDidUp + best] : 0)) best = i;
    if (best) {
        NSString *t = [NSString stringWithFormat:@"%@ %d×%d%@", kUp[best], fw, fh, gSet.superSample ? @" (supersample)" : @""];
        if (want == 2 && best != 2) t = [t stringByAppendingFormat:@" (apple super resolution %s)", srYields() ? "waits while frame generation is on" : anyNet && effFrameGen() ? "steps aside for the enhance net while frame generation is on" : *superres::status() ? superres::status() : "was late"];
        [o addObject:t];
    } else if (!pass && w) {
        bool larger = fw > w && fh > h;
        if (want && !larger) [o addObject:[kUp[want] stringByAppendingString:@" idle: window not larger than source"]];
        else if (want && anyNet) [o addObject:[kUp[want] stringByAppendingString:@" idle: enhance made the larger picture"]];
        else if (want) [o addObject:[kUp[want] stringByAppendingString:@" idle"]];
        if (!anyNet && fw != w) [o addObject:[NSString stringWithFormat:@"plain %@ %d×%d", fw > w ? @"upscale" : @"shrink", fw, fh]];
    }
    if (did(kDidE2)) [o addObject:net];
    if (did(kDidDown)) [o addObject:[NSString stringWithFormat:@"shrink %d×%d", fw, fh]];
    if (gSet.look && !pass) [o addObject:[NSString stringWithFormat:@"look %s", kLookName[gSet.look]]];
    if (did(kDidSharp)) [o addObject:sharp];
    if (gSet.freeze) [o addObject:@"frozen"];
    [o addObject:pass ? @"screen (plain passthrough: all else is off)" : gSet.ptsTime ? @"screen (capture clock)" : @"screen"];
    return o;
}

// gpu ms per stage and drawn frame. what ran between our own passes is the net, metalfx, or both
- (NSArray<NSString *> *)stageParts:(const renderer::Stats &)s {
    using namespace renderer; // kDid*, kSt*
    NSMutableArray<NSString *> *o = [NSMutableArray new];
    if (!s.stageN || !s.gpuN) return o;
    bool net = s.did[kDidPreE] || s.did[kDidE0] || s.did[kDidE1] || s.did[kDidE2], fx = s.did[kDidUp + 1] > 0;
    double v[kStN];
    for (int i = 0; i < kStN; i++) v[i] = s.stage[i] / s.gpuN;
    if (!net) v[kStEnhance] = 0; // the gap in front of dither removal, with nothing in it
    if (net != fx) { v[net ? kStEnhance : kStUpscale] += v[kStBetween]; v[kStBetween] = 0; }
    else if (!net) v[kStBetween] = 0;
    static NSString *const kName[kStN] = {@"convert", @"dither", @"enhance", @"upscale", @"net+scale", @"shrink", @"sharpen", @"overlay"};
    for (int i = 0; i < kStN; i++) if (v[i] >= 0.005) [o addObject:[NSString stringWithFormat:@"%@ %.1f", i == kStSharpen && effSharpen() <= 0 ? @"output" : kName[i], v[i]]];
    return o;
}
- (double)stageSum:(const renderer::Stats &)s { double t = 0; for (double x : s.stage) t += x; return t; }

// the order line and the hint, wrapped to the overlay's width, without a label column
- (NSArray<NSString *> *)orderLines:(const renderer::Stats &)s cols:(NSUInteger)cols {
    NSMutableArray<NSString *> *o = [NSMutableArray new], *out = [NSMutableArray new];
    addLine(o, @"", [self orderParts:s], @" → ", cols + kLabelW);
    for (NSString *l in o) [out addObject:[l substringFromIndex:MIN(kLabelW, l.length)]];
    return out;
}
- (NSArray<NSString *> *)wrap:(NSString *)t cols:(NSUInteger)cols {
    NSMutableArray<NSString *> *o = [NSMutableArray new], *out = [NSMutableArray new];
    addLine(o, @"", @[t], @" ", cols + kLabelW);
    for (NSString *l in o) [out addObject:[l substringFromIndex:MIN(kLabelW, l.length)]];
    return out;
}

// the compare view's captions: one per strip, centred in it, as wide as the picture
- (void)updateLabels {
    std::string names = renderer::compareNames();
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    if (names.empty() || fw < 64) { renderer::setLabels(nil); return; }
    NSArray<NSString *> *parts = [@(names.c_str()) componentsSeparatedByString:@"|"];
    CGFloat sc = _win.backingScaleFactor ?: 1;
    NSDictionary *at = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 * sc weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.whiteColor};
    size_t tw = (size_t)fw, th = (size_t)(22 * sc);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, tw, th, 8, tw * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    double sw = (double)tw / parts.count;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *t = gSet.compare <= 5 ? parts[i] : [NSString stringWithFormat:@"%lu  %@", (unsigned long)i + 1, parts[i]];
        NSSize z = [t sizeWithAttributes:at];
        if (z.width > sw - 8 * sc) { t = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1]; z = [t sizeWithAttributes:at]; } // too narrow for the name: the number, the overlay has the names
        NSRect r = NSMakeRect(i * sw + (sw - z.width) / 2 - 5 * sc, 2 * sc, z.width + 10 * sc, th - 4 * sc);
        [[NSColor colorWithWhite:0 alpha:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:4 * sc yRadius:4 * sc] fill];
        [t drawAtPoint:NSMakePoint(r.origin.x + 5 * sc, r.origin.y + (r.size.height - z.height) / 2) withAttributes:at];
    }
    [NSGraphicsContext restoreGraphicsState];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:tw height:th mipmapped:NO];
    id<MTLTexture> tex = [renderer::layer().device newTextureWithDescriptor:d];
    [tex replaceRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0 withBytes:CGBitmapContextGetData(ctx) bytesPerRow:tw * 4];
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    renderer::setLabels(tex);
}

- (void)updateOverlay:(const renderer::Stats &)s gen:(const framegen::Stats &)g sr:(const superres::Stats &)r {
    [self updateLabels];
    bool hinting = _hint && nowSec() < _hintUntil;
    if (!gSet.overlay && !hinting) { renderer::setHud(nil); return; }
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    CGFloat scaleF = _win.backingScaleFactor ?: 1;
    NSFont *font = [NSFont monospacedSystemFontOfSize:11 * scaleF weight:NSFontWeightMedium];
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.whiteColor};
    size_t pad = (size_t)(10 * scaleF);
    // as many characters as the picture is wide (the renderer leaves 12 points around the overlay)
    double room = (fw > 0 ? fw : _view.bounds.size.width * scaleF) - 2 * 12 * scaleF - 2 * pad;
    NSUInteger wide = (NSUInteger)fmax(48, floor(room / [@"0" sizeWithAttributes:attrs].width)); // what fits. the table may use it all
    NSUInteger cols = MIN((NSUInteger)140, wide); // and no wider than reads well
    // two sizes: compact is the order line and one line of numbers, full adds every switch as a row in two columns
    // (key, name, what it is set to). off is dimmed, so what is on stands out
    NSColor *dim = [NSColor colorWithWhite:0.6 alpha:1], *faint = [NSColor colorWithWhite:0.52 alpha:1], *keyC = [NSColor colorWithRed:0.55 green:0.8 blue:1 alpha:1],
            *idleC = [NSColor colorWithRed:1 green:0.75 blue:0.4 alpha:1], *hintC = [NSColor colorWithRed:1 green:0.86 blue:0.45 alpha:1];
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    auto put = [&](NSString *t, NSColor *c) {
        NSMutableDictionary *at = [attrs mutableCopy];
        at[NSForegroundColorAttributeName] = c;
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:t attributes:at]];
    };
    auto fit = [](NSString *t, NSUInteger n) { // exactly n wide
        if (t.length > n) return [[t substringToIndex:n - 1] stringByAppendingString:@"…"];
        return [t stringByPaddingToLength:n withString:@" " startingAtIndex:0];
    };
    if (gSet.overlay) {
    NSString *why = gSet.frameGen ? [self genWhy:s] : nil;
    int gmSet = gSet.genModel, gmNow = framegen::model();
    int gs = gSet.genStill;
    NSString *still = gs == 0 ? @"exact" : gs == 1 ? @"soft" : gs == 2 ? @"by motion" : gs == 3 ? @"by motion, soft" : @"not kept (test)";
    NSString *levels = gSet.levels == 1 ? @"video range" : gSet.levels == 2 ? @"full range" : renderer::fullRange() ? @"full range (auto)" : @"video range (auto)";
    if (s.in) levels = [levels stringByAppendingFormat:@", darkest %d", s.darkest]; // 16 on black = the source sends video range
    NSString *scale = w ? [NSString stringWithFormat:@"%d×%d → %d×%d %@", w, h, fw, fh, upscalerText(up, s, r).lowercaseString] : @"–";
    // the line says what ran. when that is not the one chosen with M, say which is chosen and why it is idle: the
    // key looked dead in a window no larger than the source
    static NSString *const kUp[] = {@"plain", @"metalfx", @"apple sr", @"edge-aware fsr 1", @"edge-aware sgsr 1"};
    int want = gSet.upscale;
    if (w && gSet.passthrough) scale = [scale stringByAppendingFormat:@" (%@ chosen, off in passthrough)", kUp[want]];
    else if (renderer::enhanceRan()) { if (want && !up && fw > w) scale = [scale stringByAppendingFormat:@" (in place of %@)", kUp[want]]; }
    else if (w && want && (fw <= w || fh <= h)) scale = [scale stringByAppendingFormat:@" (%@ chosen, idle: the picture is not larger than the source)", kUp[want]];
    double gpu = s.gpuN ? s.gpuSum / s.gpuN : 0, budget = _fps > 0 ? 1000 / _fps : 0;
    NSString *gpuT = [NSString stringWithFormat:@"%.1f of %.1f ms a frame (%.0f%%)", gpu, budget, budget > 0 ? 100 * gpu / budget : 0];
    NSArray<NSString *> *stages = [self stageParts:s];
    { // the chain left to right as it ran: each step with a dot (green ran, amber on but idle) and its key
        NSColor *ranC = [NSColor colorWithRed:0.45 green:0.9 blue:0.5 alpha:1];
        static NSString *const kKey[][2] = {{@"noise filter", @"D"}, {@"dither removal", @"B"}, {@"enhance", @"N"}, {@"frame generation", @"G"}, {@"levels", @"R"}, {@"sharpen", @"[ ]"}, {@"look", @"."},
                                            {@"plain", @"M"}, {@"metalfx", @"M"}, {@"apple super", @"M"}, {@"edge-aware", @"M"}};
        NSArray<NSString *> *parts = [self orderParts:s];
        NSUInteger col = 0;
        for (NSUInteger i = 0; i < parts.count; i++) {
            NSString *t = parts[i], *key = nil;
            for (auto &k : kKey) if ([t hasPrefix:k[0]]) key = k[1];
            bool idle = [t containsString:@" idle"] || [t hasSuffix:@"starting"], ends = !key; // input and screen have no switch
            NSUInteger len = t.length + (ends ? 0 : 2) + (key ? key.length + 1 : 0) + (i ? 3 : 0);
            if (col && col + len > cols) { put(@"\n", dim); col = 0; }
            if (i) { put(@" → ", faint); col += 3; }
            if (!ends) put(idle ? @"◐ " : @"● ", idle ? idleC : ranC);
            if (key) put([key stringByAppendingString:@" "], keyC);
            put(t, ends ? dim : idle ? idleC : NSColor.whiteColor);
            col += len - (i ? 3 : 0);
        }
        put(@"\n", dim);
    }
    double delay = s.toGlassN ? s.toGlassSum / s.toGlassN + (s.lagN ? s.lagSum / s.lagN : 0) : 0;
    put([NSString stringWithFormat:@"%d fps in, %d new   delay %.0f ms   gpu %@", s.in, s.real, delay, gpuT], dim);
    if (gSet.frameGen) put([NSString stringWithFormat:@"   %@", why ? [@"not generating: " stringByAppendingString:why] : [NSString stringWithFormat:@"generating %d /s", s.gen]], why ? idleC : dim);
    put(gSet.overlayFull ? @"   [H] hide\n" : @"   [H] all switches\n", keyC);
    { // the ten presets in a row, the one in use lit. changed by hand since: amber, with a mark
        NSColor *onP = [NSColor colorWithRed:0.45 green:0.9 blue:0.5 alpha:1];
        NSUInteger col = 0;
        auto item = [&](NSString *t, NSColor *c) { if (col && col + t.length > cols) { put(@"\n         ", dim); col = 9; } put(t, c); col += t.length; };
        item(@"presets  ", dim);
        for (int i = 1; i <= (int)presets().size(); i++) {
            bool own = [NSUserDefaults.standardUserDefaults dictionaryForKey:[NSString stringWithFormat:@"customPreset%d", i]] != nil;
            NSString *name = own ? @"your own" : @(presets()[i - 1].name);
            if (i == _preset) item([NSString stringWithFormat:@"● %d %@   ", i % 10, name], onP);
            else if (i == _presetWas) item([NSString stringWithFormat:@"◐ %d %@ (changed)   ", i % 10, name], idleC);
            else { NSUInteger c0 = col; (void)c0; if (col && col + name.length + 5 > cols) { put(@"\n         ", dim); col = 9; } put([NSString stringWithFormat:@"%d ", i % 10], keyC); put([name stringByAppendingString:@"   "], faint); col += name.length + 5; }
        }
        put(@"\n", dim);
    }
    if (gSet.overlayFull) {
        // one row per switch: a dot for its state (green on, amber on but idle, hollow off, small for a choice), the
        // key, the name, a short value. the long story is the hint line. rows sit under what they belong to
        enum { kOff, kOn, kIdle, kPick, kHead, kGap, kInfo };
        struct Row { int st; NSString *key, *name, *val, *cmd; };
        auto sw = [](bool on) { return on ? kOn : kOff; };
        auto ex = [&](int i) { std::string t = renderer::extraText(i, s); return t.rfind("off", 0) == 0 ? kOff : t.rfind("idle", 0) == 0 ? kIdle : kOn; };
        auto word = [](int st) { return st == kOn ? @"on" : st == kIdle ? @"idle" : @"off"; };
        static NSString *const kUpS[] = {@"plain", @"metalfx", @"apple sr", @"fsr 1", @"sgsr 1"};
        bool upIdle = !gSet.passthrough && want && ((renderer::enhanceRan() && !up) || (w && (fw <= w || fh <= h)));
        int en = gSet.enhance;
        bool enOn = en && en <= nets::count() && !gSet.passthrough;
        NSString *enName = enOn ? [@(nets::name(en)).lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@" "] : @"off";
        int noiseSt = !(gSet.chain & kChainSet ? effNoise() : (int)gSet.denoise) ? kOff : effNoise() && !*noise::status() ? kOn : kIdle;
        int genSt = !gSet.frameGen ? kOff : why ? kIdle : kOn;
        int e0 = ex(0), e1 = ex(1), e2 = ex(2);
        int smallSt = !gSet.genSmall ? kOff : renderer::genSmallNow() ? kOn : kIdle, hudN = gSet.hudN;
        NSString *smallT = !gSet.genSmall ? @"full size" : [NSString stringWithFormat:@"%d×%d%@", kGenSmallW[gSet.genSmall], kGenSmallH[gSet.genSmall], smallSt == kIdle ? @", idle" : @""];
        // the two only act on the early schedule resp. a screen quicker than the source: amber when chosen and idle
        bool usual = gSet.genDeadline == 1, dlOn = genSt == kOn && (gSet.early || renderer::deepNow());
        NSString *dlT = [NSString stringWithFormat:@"%@%@", dlOn ? usual ? @"usual" : @"slowest" : usual ? @"by the usual" : @"by the slowest", dlOn ? [NSString stringWithFormat:@", %.1f ms", renderer::genBudgetMs()] : usual ? @", idle" : @""];
        int lateSt = !gSet.genLateNext ? kOff : genSt == kOn && renderer::genLateRoom() ? kOn : kIdle;
        // the value column is narrow: what the net was trained on and half precision get a row of their own
        NSString *enSub = @"";
        if ([enName hasPrefix:@"gta6 "]) { enName = [enName substringFromIndex:5]; enSub = @"gta6"; }
        bool half = enOn && nets::half(en);
        int awakeSt = !gSet.gpuAwake ? kOff : awake::running() ? kOn : kIdle;
        NSString *lv = gSet.levels == 1 ? @"video" : gSet.levels == 2 ? @"full" : renderer::fullRange() ? @"auto: full" : @"auto: video";
        NSString *gm = !gmSet ? @"apple's" : [NSString stringWithFormat:@"second, %d", gmSet == 2 ? 720 : 480];
        std::vector<Row> pic = {
            {kHead, nil, @"colour", nil, nil},
            {kPick, @"R", @"levels", lv, @"levels"}, {kPick, @"C", @"colour", gSet.colour == 1 ? @"srgb" : gSet.colour == 2 ? @"screen's own" : @"bt.709", @"colour"},
            {kGap, nil, nil, nil, nil}, {kHead, nil, @"cleaning", nil, nil},
            {sw(effDeband()), @"B", @"dither removal", oo(effDeband()), @"deband"},
            {noiseSt, @"D", @"noise filter", noiseSt == kOn ? [NSString stringWithFormat:@"on, %.0f ms", _noiseMs] : word(noiseSt), @"denoise"},
            {enOn ? (renderer::enhanceRan() ? kOn : kIdle) : kOff, @"N", @"enhance", enName, @"enhance"},
            {e0, @"O", @" real frames only", word(e0), @"enhancereal"}, {e1, @"Y", @" steady", word(e1), @"enhancehold"},
            {kGap, nil, nil, nil, nil}, {kHead, nil, @"size and sharpness", nil, nil},
            {gSet.passthrough ? kOff : upIdle ? kIdle : kPick, @"M", @"upscaling", upIdle ? [kUpS[want] stringByAppendingString:@", idle"] : kUpS[want], @"upscale"},
            {e2, @"U", @" supersample", word(e2), @"supersample"},
            {effSharpen() > 0 ? kPick : kOff, @"[ ]", @"sharpening", effSharpen() > 0 ? [NSString stringWithFormat:@"%.1f", effSharpen()] : @"off", @"sharp"},
            {!gSet.look ? kOff : gSet.passthrough ? kIdle : kOn, @".", @"look", gSet.look ? @(kLookName[gSet.look]) : @"off", @"look"},
            {kGap, nil, nil, nil, nil}, {kHead, nil, @"bypass", nil, nil},
            {sw(gSet.passthrough), @"Z", @"plain passthrough", oo(gSet.passthrough), @"passthrough"}};
        if (half || enSub.length) for (size_t i = 0; i < pic.size(); i++) if ([pic[i].cmd isEqual:@"enhance"]) {
            pic.insert(pic.begin() + i + 1, {kPick, @"", enSub.length ? @" trained on" : @" precision", !enSub.length ? @"half" : half ? @"gta6, half" : enSub, nil});
            break;
        }
        std::vector<Row> mot = {
            {kHead, nil, @"frame generation", nil, nil},
            {genSt, @"G", @"frame generation", genSt == kOn ? [NSString stringWithFormat:@"on, %.0f ms each", g.n ? g.sumMs / g.n : 0] : word(genSt), @"framegen"},
            {gmSet && !gmNow ? kIdle : kPick, @"I", @" generator", gmSet && !flyhigh::complete() ? (flyhigh::downloading() ? @"downloading" : @"⏎ downloads it") : gmSet && !gmNow ? [gm stringByAppendingString:@", idle"] : gm, @"genmodel"},
            {kPick, @"S", @" still areas", still, @"genstill"},
            {sw(gSet.hudLock), @"L", @" hud lock", oo(gSet.hudLock), @"hudlock"},
            {_view.marking ? kOn : !hudN ? kPick : genSt == kOn ? kOn : kIdle, @"Q", @" hud areas", _view.marking ? @"drag one now" : hudN ? [NSString stringWithFormat:@"%d marked%@", hudN, gSet.hudShow ? @", shown" : @""] : @"mark one", @"hudmark"},
            {sw(gSet.cutTest), @"K", @" better cut test", oo(gSet.cutTest), @"cuttest"},
            {smallSt == kOff ? kPick : smallSt, @"T", @" made at", smallT, @"gensmall"},
            {usual && !dlOn ? kIdle : kPick, @"", @" deadline", dlT, @"gendeadline"},
            {lateSt, @"", @" late frames", lateSt == kOn ? @"a refresh later" : lateSt == kIdle ? @"idle" : @"left out", @"genlatenext"},
            {kGap, nil, nil, nil, nil}, {kHead, nil, @"timing", nil, nil},
            {kPick, @"E", @"schedule", renderer::deepNow() ? @"in turns" : gSet.early ? @"early" : @"on the tick", @"schedule"},
            {sw(gSet.ptsTime), @"J", @"capture clock", oo(gSet.ptsTime), @"ptstime"}, {sw(gSet.repeatTol), @"P", @"tolerant repeats", oo(gSet.repeatTol), @"repeattol"},
            {sw(gSet.vsync), @"V", @"vsync", oo(gSet.vsync), @"vsync"},
            {awakeSt, @"", @"gpu kept awake", awakeSt == kOn ? @"on, uses power" : word(awakeSt), @"gpuawake"},
            {kGap, nil, nil, nil, nil}, {kHead, nil, @"sound", nil, nil},
            {sw(audio::running()), @"A", @"audio", !audio::running() ? @"off" : fabs(gSet.audioTrim) > 0.0005 ? [NSString stringWithFormat:@"on, %+.0f ms", gSet.audioTrim * 1000] : @"on", @"audio"},
            {kPick, @"; '", @" earlier / later", @"5 ms a press", @"trim"}};
        const NSUInteger keyW = 4, nameW = 21, valW = 18, cellW = 4 + keyW + nameW + valW;
        NSString *aud = audio::running() ? @(audio::statusLine().c_str()).lowercaseString : @"off";
        std::vector<Row> inf = {
            {kHead, nil, @"now", nil, nil},
            {kInfo, nil, @"source", @(_sourceName.c_str()), nil}, {kInfo, nil, @"signal", @(_status.text.c_str()).lowercaseString, nil},
            {kInfo, nil, @"picture", w ? [NSString stringWithFormat:@"%d×%d → %d×%d", w, h, fw, fh] : @"–", nil},
            {kInfo, nil, @"cadence", [self cadence:s], nil},
            {kInfo, nil, @"frames", [NSString stringWithFormat:@"drawn %d, rolled %d, uneven %d of %d", s.drawn, s.rolled, s.gapBad, s.gapN], nil},
            {kInfo, nil, @"darkest", s.in ? [NSString stringWithFormat:@"%d (16 = video range)", s.darkest] : @"–", nil},
            {kInfo, nil, @"display", @(display::status().c_str()).lowercaseString, nil},
            {kInfo, nil, @"audio", aud, nil},
            {kGap, nil, nil, nil, nil}, {kHead, nil, @"gpu ms per stage", nil, nil}};
        for (NSString *st in stages) inf.push_back({kInfo, nil, [st componentsSeparatedByString:@" "].firstObject, [st substringFromIndex:MIN(st.length, [[st componentsSeparatedByString:@" "].firstObject length] + 1)], nil});
        if (!stages.count) inf.push_back({kInfo, nil, @"–", @"", nil});
        inf.insert(inf.end(), {{kGap, nil, nil, nil, nil}, {kHead, nil, @"window and presets", nil, nil},
            {kPick, @"F", @"full screen", @"", @"fullscreen"}, {kPick, @"W", @"window size", @"next size", @"winsize"},
            {sw(gSet.keepRes), @"X", @"keep resolution", oo(gSet.keepRes), @"keepres"},
            {gSet.freeze ? kOn : kOff, @"␣", @"freeze picture", gSet.freeze ? @"frozen" : @"off", @"freeze"},
            {!gSet.compare ? kOff : gSet.passthrough ? kIdle : kOn, @"/", @"compare", kCmp[gSet.compare & 7], @"compare"},
            {kPick, @"1-0", @"presets", _preset ? [NSString stringWithFormat:@"%d", _preset % 10] : @"", @"preset"}, {kPick, @"⇧ +", @"that: save as preset", @"", @"presetsave"},
            {kPick, @"⌘S", @"snapshot", @"", @"snapshot"}, {kPick, @"H", @"this overlay", @"hide", @"overlay"}});
        { // a long value goes on over the next lines instead of being cut off
            std::vector<Row> o;
            for (auto &r : inf) {
                if (r.st != kInfo || r.val.length <= cellW - 12) { o.push_back(r); continue; }
                NSArray<NSString *> *ls = [self wrap:r.val cols:cellW - 12];
                for (NSUInteger i = 0; i < ls.count; i++) o.push_back({kInfo, nil, i ? @"" : r.name, ls[i], nil});
            }
            inf = o;
        }
        int ncol = wide >= 3 * cellW + 6 ? 3 : wide >= 2 * cellW + 3 ? 2 : 1;
        NSColor *onC = [NSColor colorWithRed:0.45 green:0.9 blue:0.5 alpha:1];
        NSString *last = [_lastCmd stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"+-"]];
        auto cell = [&](const Row &r) {
            if (r.st == kGap) { put(fit(@"", cellW), dim); return; }
            if (r.st == kHead) { // a ruled line with the group's name: what follows belongs to it
                NSString *h = [r.name stringByAppendingString:@" "];
                put(h, dim);
                put([@"" stringByPaddingToLength:cellW > h.length ? cellW - h.length : 0 withString:@"─" startingAtIndex:0], [faint colorWithAlphaComponent:0.6]);
                return;
            }
            if (r.st == kInfo) { put(@"  ", dim); put(fit(r.name, 10), faint); put(fit(r.val ?: @"", cellW - 12), dim); return; }
            put(@"  ", dim);
            bool mine = last && [r.cmd isEqual:last], sub = [r.name hasPrefix:@" "]; // the switch just used stands out
            put(r.st == kOn ? @"● " : r.st == kIdle ? @"◐ " : r.st == kOff ? @"○ " : @"· ", r.st == kOn ? onC : r.st == kIdle ? idleC : faint);
            put(fit(r.key, keyW), r.st == kOff ? [keyC colorWithAlphaComponent:0.6] : keyC);
            if (sub) put(@" └ ", faint);
            put(fit(sub ? [r.name substringFromIndex:1] : r.name, nameW - (sub ? 3 : 0)), mine ? hintC : r.st == kOff ? faint : NSColor.whiteColor);
            put(fit(r.val, valW), mine ? hintC : r.st == kOff ? faint : r.st == kIdle ? idleC : r.st == kOn ? onC : NSColor.whiteColor);
        };
        put(@"\n", dim);
        std::vector<std::vector<Row> *> colsV = {&pic, &mot, &inf};
        size_t nowN = 1; // the "now" group alone: up to the gap after it
        while (nowN < inf.size() && inf[nowN].st != kGap) nowN++;
        std::vector<Row> now(inf.begin(), inf.begin() + nowN);
        if (ncol == 2) { mot.push_back({kGap, nil, nil, nil, nil}); mot.insert(mot.end(), now.begin(), now.end()); colsV = {&pic, &mot}; } // what does not fit beside goes below
        if (ncol == 1) { pic.push_back({kGap, nil, nil, nil, nil}); pic.insert(pic.end(), mot.begin(), mot.end()); pic.push_back({kGap, nil, nil, nil, nil}); pic.insert(pic.end(), now.begin(), now.end()); colsV = {&pic}; }
        size_t rows = 0;
        for (auto c : colsV) rows = MAX(rows, c->size());
        for (size_t i = 0; i < rows; i++) {
            for (size_t k = 0; k < colsV.size(); k++) {
                if (i < colsV[k]->size()) cell((*colsV[k])[i]); else put(fit(@"", cellW), dim);
                put(k + 1 < colsV.size() ? @"   " : @"\n", dim);
            }
        }
        if (ncol < 3) { // the rest in lines
            put(@"\n", dim);
            if (stages.count) for (NSString *l in [self wrap:[@"gpu ms per stage   " stringByAppendingString:[stages componentsJoinedByString:@"   "]] cols:cols]) put([l stringByAppendingString:@"\n"], faint);
            put(@"F", keyC); put(@" full screen   ", dim); put(@"W", keyC); put(@" window size   ", dim); put(@"X", keyC); put([NSString stringWithFormat:@" keep resolution %@   ", oo(gSet.keepRes)], dim);
            put(@"⇧ + number", keyC); put(@" save as preset   ", dim); put(@"⌘S", keyC); put(@" snapshot\n", dim);
        }
        put(@"\n● on  ", onC); put(@"◐ on, not acting now  ", idleC); put(@"○ off  · a choice or a key\n", faint);
    }
    }
    if (hinting) for (NSString *l in [self wrap:_hint cols:cols]) put([l stringByAppendingString:@"\n"], hintC);
    if (text.length && [text.string hasSuffix:@"\n"]) [text deleteCharactersInRange:NSMakeRange(text.length - 1, 1)];
    NSSize ts = [text boundingRectWithSize:NSMakeSize(4000, 4000) options:NSStringDrawingUsesLineFragmentOrigin].size;
    size_t tw = (size_t)ceil(ts.width) + 2 * pad, th = (size_t)ceil(ts.height) + 2 * pad;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, tw, th, 8, tw * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = gc;
    [[NSColor colorWithWhite:0 alpha:0.86] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, tw, th) xRadius:8 * scaleF yRadius:8 * scaleF] fill];
    [text drawInRect:NSMakeRect(pad, pad, tw - 2 * pad, th - 2 * pad)];
    [NSGraphicsContext restoreGraphicsState];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:tw height:th mipmapped:NO];
    id<MTLTexture> t = [renderer::layer().device newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0 withBytes:CGBitmapContextGetData(ctx) bytesPerRow:tw * 4];
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    renderer::setHud(t);
}

// commands from menus and single keys

- (void)menuAction:(NSMenuItem *)item { [self command:item.representedObject]; }

// the drawn picture has to be readable to be copied, and only then: switching costs a hitch of a few frames
static void recReadable(bool on) { renderer::layer().framebufferOnly = !on; }
static int recSecs() { id v = [NSUserDefaults.standardUserDefaults objectForKey:@"recKeepSeconds"]; return v ? (int)fmin(300, fmax(5, [v doubleValue])) : 30; } // hidden

// tab records, or saves the last seconds while those are kept. shift + tab switches between the two
- (void)record:(NSString *)c arg:(NSString *)arg {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    int st = record::state();
    if ([c isEqual:@"recfolder"]) {
        [NSFileManager.defaultManager createDirectoryAtPath:record::folder() withIntermediateDirectories:YES attributes:nil error:nil];
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:record::folder()]];
    } else if ([c isEqual:@"recsize"] || [c isEqual:@"recrate"]) { // while a file is open: it ends and the next one has the new values
        bool size = [c isEqual:@"recsize"];
        int v = std::max(0, arg.intValue);
        bool same = v == (size ? recMaxH() : (int)[d integerForKey:@"recMbit"]); // the one that is ticked: no new file for it
        [d setInteger:v forKey:size ? @"recMaxHeight" : @"recMbit"];
        if (!same) record::limit(recMaxH());
        [self say:size ? (v ? [NSString stringWithFormat:@"recordings: at most %dp", v] : @"recordings: every pixel shown")
                       : (v ? [NSString stringWithFormat:@"recordings: %d mbit", v] : @"recordings: bitrate by size")];
    } else if ([c isEqual:@"recoverlay"]) {
        BOOL on = arg.length ? arg.boolValue : ![d boolForKey:@"recOverlay"];
        [d setBool:on forKey:@"recOverlay"];
        record::overlay(on);
        [self say:on ? @"recordings: with the overlay and the hint lines" : @"recordings: the picture only"];
    } else if ([c isEqual:@"reckeep"]) {
        BOOL on = arg.length ? arg.boolValue : st != 1;
        [d setBool:on forKey:@"recKeep"];
        recReadable(on);
        record::keep(on);
        [self say:on ? [NSString stringWithFormat:@"%@keeping the last %d s  (tab saves them, shift + tab turns this off)", st == 2 ? @"recording stopped. " : @"", recSecs()]
                     : @"keeping the last seconds: off  (tab starts a recording)"];
    } else if (st == 1) record::save(); // says what it saved
    else {
        if (st == 0 && !_source) { [self say:@"recording: no source is running"]; return; }
        recReadable(st == 0);
        record::toggle();
        if (st == 0) [self say:@"recording  (tab stops it)"];
    }
}

- (void)command:(NSString *)c {
    NSString *arg = nil;
    NSRange colon = [c rangeOfString:@":"];
    if (colon.location != NSNotFound) { arg = [c substringFromIndex:colon.location + 1]; c = [c substringToIndex:colon.location]; }
    if ([c isEqual:@"preset"]) { [self applyPreset:arg.intValue]; return; }
    if ([c hasPrefix:@"rec"]) { [self record:c arg:arg]; return; }
    if ([c isEqual:@"presetsave"]) { [self savePreset:arg.intValue]; return; }
    if ([c isEqual:@"presetremove"]) {
        NSString *k = [NSString stringWithFormat:@"customPreset%d", arg.intValue];
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if (![d dictionaryForKey:k]) return;
        [d removeObjectForKey:k];
        if (_preset == arg.intValue) _preset = 0; // what runs is no longer what that number holds
        if (_presetWas == arg.intValue) _presetWas = 0;
        [self say:[NSString stringWithFormat:@"your preset %d is gone, the built-in one is back on that key. the switches stay as they are", arg.intValue % 10]];
        return;
    }
    if ([c isEqual:@"presetreset"]) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if (_preset && [d dictionaryForKey:[NSString stringWithFormat:@"customPreset%d", _preset]]) _preset = 0; // what runs is no longer what that number holds
        if (_presetWas && [d dictionaryForKey:[NSString stringWithFormat:@"customPreset%d", _presetWas]]) _presetWas = 0; // nor what the changed switches came from
        for (int i = 1; i <= (int)presets().size(); i++) [d removeObjectForKey:[NSString stringWithFormat:@"customPreset%d", i]];
        [self say:@"the built-in presets are back on every number"];
        return;
    }
    if ([c isEqual:@"huddrag"]) { [self testDrag:arg]; return; }
    NSDictionary *before = presetNow(); // the preset's number stays up until one of its own switches is changed
    if (![c isEqual:@"overlay"]) _lastCmd = [c hasPrefix:@"trim"] ? @"trim" : c;
    if ([c isEqual:@"fullscreen"]) [_win toggleFullScreen:nil];
    else if ([c isEqual:@"overlay"]) { // off -> compact -> every switch -> off
        if (arg) { gSet.overlay = !gSet.overlay; gSet.overlayFull = false; } // the menu item: on or off
        else if (!gSet.overlay) { gSet.overlay = true; gSet.overlayFull = false; }
        else if (!gSet.overlayFull) gSet.overlayFull = true;
        else { gSet.overlay = false; gSet.overlayFull = false; }
        settingsSave("overlay"); settingsSave("overlayFull");
        [_view showAreas:0]; // the hud areas' outlines go with the overlay
    }
    else if ([c isEqual:@"framegen"]) { gSet.frameGen = !gSet.frameGen; settingsSave("frameGen"); }
    else if ([c isEqual:@"schedule"]) { gSet.early = arg ? arg.intValue != 0 : !gSet.early; settingsSave("early"); }
    else if ([c isEqual:@"gensmall"]) { // the key steps down in size: full, 864, 768, 720 lines, full
        gSet.genSmall = arg ? MAX(0, MIN(3, arg.intValue)) : (gSet.genSmall + 3) % 4;
        settingsSave("genSmall");
    }
    else if ([c isEqual:@"gendeadline"]) { gSet.genDeadline = arg ? arg.intValue == 1 : !gSet.genDeadline; settingsSave("genDeadline"); }
    else if ([c isEqual:@"genlatenext"]) { gSet.genLateNext = !gSet.genLateNext; settingsSave("genLateNext"); }
    else if ([c isEqual:@"nethalf"]) { gSet.netHalf = !gSet.netHalf; settingsSave("netHalf"); }
    else if ([c isEqual:@"gpuawake"]) { gSet.gpuAwake = !gSet.gpuAwake; settingsSave("gpuAwake"); }
    else if ([c isEqual:@"genmodel"] || [c isEqual:@"genmodel+"]) { // choosing it again looks at the files again
        bool missing = !flyhigh::complete();
        if (missing && arg.intValue > 0) { [self command:[NSString stringWithFormat:@"genget:%d", arg.intValue]]; return; } // picked in the menu: ask. the key only hints
        _genWant = 0;
        gSet.genModel = [c hasSuffix:@"+"] ? (missing ? !gSet.genModel : (gSet.genModel + 1) % 3) : // without its files one stop, not two
                         ((arg.intValue % 3) + 3) % 3;
        flyhigh::retry();
        settingsSave("genModel");
    }
    else if ([c isEqual:@"genget"]) { // the licence first
        if (flyhigh::downloading()) { [self say:@"second generator — still downloading"]; return; }
        if (_win.attachedSheet) return; // one at a time
        int want = arg.intValue;
        void (^get)(void) = ^{
          [self say:@"second generator — downloading its files"];
          self->_genWant = want;
          flyhigh::download(^(const std::string &err) {
            int now = self->_genWant; // 0: a preset or another generator was chosen while it ran, that choice stands
            self->_genWant = 0;
            if (err.empty() && now) [self command:[NSString stringWithFormat:@"genmodel:%d", now]]; // by the command, so the presets know
            [self say:!err.empty() ? [NSString stringWithFormat:@"second generator — not downloaded: %@", ns(err)] : now ? @"second generator — downloaded, chosen now" : @"second generator — downloaded"];
          });
        };
        if (gArgs.test && [arg hasSuffix:@"go"] && [[[NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain][@"genModelDir"] description] length]) { get(); return; } // a test folder only
        NSAlert *a = [NSAlert new];
        a.messageText = @"Download the second generator's files?";
        a.informativeText = @"FlyHighFG is a frame generation model by the FlyHigh project and is not part of Meyra. Its files (1.6 MB) come from github.com/getflyhigh/flyhigh-engine and go into Application Support/Meyra/flyhighfg.\n\n"
                            @"They are licensed CC BY-NC 4.0: free to use and share for noncommercial purposes, with attribution to the FlyHigh project. Commercial use needs a licence from them.";
        [a addButtonWithTitle:@"Download"].keyEquivalent = @""; // not on return: that is the key that opened this
        [a addButtonWithTitle:@"Cancel"].keyEquivalent = @"\033";
        [a addButtonWithTitle:@"Read the Licence"];
        void (^answer)(NSModalResponse) = ^(NSModalResponse r) {
          if (r == NSAlertFirstButtonReturn) get();
          else if (r == NSAlertThirdButtonReturn) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/getflyhigh/flyhigh-engine/blob/34c3fb6383b5d94146cd36878482367f49bb06dc/models/WEIGHTS_LICENSE.md"]];
        };
        if (_win.visible) [a beginSheetModalForWindow:_win completionHandler:answer];
        else answer([a runModal]);
        return;
    }
    else if ([c isEqual:@"genstill"]) { gSet.genStill = ((arg.intValue % 5) + 5) % 5; settingsSave("genStill"); }
    else if ([c isEqual:@"genstill+"]) { gSet.genStill = (gSet.genStill + 1) % 4; settingsSave("genStill"); }
    else if ([c isEqual:@"passthrough"]) { gSet.passthrough = !gSet.passthrough; settingsSave("passthrough"); }
    else if ([c isEqual:@"levels"]) { gSet.levels = ((arg.intValue % 3) + 3) % 3; settingsSave("levels"); }
    else if ([c isEqual:@"levels+"]) { gSet.levels = (gSet.levels + 1) % 3; settingsSave("levels"); }
    else if ([c isEqual:@"colour"] || [c isEqual:@"colour+"]) {
        gSet.colour = ((([c isEqual:@"colour"] ? arg.intValue : gSet.colour + 1) % 3) + 3) % 3;
        settingsSave("colour");
        renderer::applyColour();
    }
    else if ([c isEqual:@"deband"]) { gSet.deband = !gSet.deband; settingsSave("deband"); }
    else if ([c isEqual:@"denoise"]) { gSet.denoise = !gSet.denoise; settingsSave("denoise"); }
    else if ([c isEqual:@"hudlock"]) { gSet.hudLock = !gSet.hudLock; settingsSave("hudLock"); }
    else if ([c isEqual:@"hudmark"]) { // again, or esc: not after all
        int w, h, fw, fh, up;
        renderer::lastSize(w, h, fw, fh, up);
        int cm = gSet.passthrough ? 0 : gSet.compare.load();
        if (!_view.marking && (cm == 4 || cm == 5 || cm == 7)) { [self say:@"hud areas — not while the compare view shows the picture twice or in strips: the drag would land elsewhere. / changes the view"]; return; }
        _view.marking = !_view.marking && gSet.hudN < kHudMax && w > 0;
    }
    else if ([c isEqual:@"hudclear"]) { gSet.hudN = 0; settingsSave("hudRects"); _view.marking = NO; logLine("hud areas: none"); }
    else if ([c isEqual:@"hudshow"]) { gSet.hudShow = !gSet.hudShow; settingsSave("hudShow"); [_view showAreas:0]; }
    else if ([c isEqual:@"cuttest"]) { gSet.cutTest = !gSet.cutTest; settingsSave("cutTest"); }
    else if ([c isEqual:@"repeattol"]) { gSet.repeatTol = !gSet.repeatTol; settingsSave("repeatTol"); }
    else if ([c isEqual:@"ptstime"]) { gSet.ptsTime = !gSet.ptsTime; settingsSave("ptsTime"); }
    else if ([c isEqual:@"enhancereal"]) { gSet.enhanceReal = !gSet.enhanceReal; settingsSave("enhanceReal"); }
    else if ([c isEqual:@"enhancehold"]) { gSet.enhanceHold = !gSet.enhanceHold; settingsSave("enhanceHold"); }
    else if ([c isEqual:@"look"] || [c isEqual:@"look+"]) { gSet.look = ((([c isEqual:@"look"] ? arg.intValue : gSet.look + 1) % 4) + 4) % 4; settingsSave("look"); }
    else if ([c isEqual:@"supersample"]) { gSet.superSample = !gSet.superSample; settingsSave("superSample"); }
    else if ([c isEqual:@"srpad"]) { gSet.srPad = !gSet.srPad; settingsSave("srPad"); }
    else if ([c isEqual:@"srgen"]) { gSet.srWithGen = !gSet.srWithGen; settingsSave("srWithGen"); }
    else if ([c isEqual:@"enhance"]) { gSet.enhance = MAX(0, arg.intValue); settingsSave("enhance"); saveNetName(); }
    else if ([c isEqual:@"enhance+"]) { int n = gSet.enhance;
        do n = (n + 1) % (nets::count() + 1); while (n && nets::passes(n) > 64); // the still-picture net takes far too long to land on by key, the menu has it
        gSet.enhance = n; settingsSave("enhance"); saveNetName(); }
    else if ([c isEqual:@"enhanceat"]) { gSet.enhanceAt = ((arg.intValue % 3) + 3) % 3; settingsSave("enhanceAt"); }
    else if ([c isEqual:@"enhancedown"]) { gSet.enhanceDown = ((arg.intValue % 2) + 2) % 2; settingsSave("enhanceDown"); }
    else if ([c isEqual:@"upscale"]) { gSet.upscale = ((arg.intValue % 5) + 5) % 5; settingsSave("upscale"); }
    else if ([c isEqual:@"upscale+"]) { int n = (gSet.upscale + 1) % 5; gSet.upscale = n == 2 && !superres::available() ? 3 : n; settingsSave("upscale"); }
    else if ([c isEqual:@"sharp"]) { gSet.sharpen = fminf(1, fmaxf(0, arg.floatValue)); settingsSave("sharpen"); }
    else if ([c isEqual:@"sharp+"]) { gSet.sharpen = fminf(1, roundf(gSet.sharpen * 10 + 1) / 10); settingsSave("sharpen"); }
    else if ([c isEqual:@"sharp-"]) { gSet.sharpen = fmaxf(0, roundf(gSet.sharpen * 10 - 1) / 10); settingsSave("sharpen"); }
    else if ([c isEqual:@"audio"]) { gSet.audio = !gSet.audio; settingsSave("audio"); [self audioToggled]; }
    else if ([c isEqual:@"trim+"]) { gSet.audioTrim = gSet.audioTrim + 0.005; settingsSave("audioTrimMs"); }
    else if ([c isEqual:@"trim-"]) { gSet.audioTrim = gSet.audioTrim - 0.005; settingsSave("audioTrimMs"); }
    else if ([c isEqual:@"trim0"]) { gSet.audioTrim = 0; settingsSave("audioTrimMs"); }
    else if ([c isEqual:@"refresh"]) { gSet.refresh = ((arg.intValue % 3) + 3) % 3; settingsSave("refresh"); [self applyRefresh]; }
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
    else if ([c isEqual:@"keepres"]) { gSet.keepRes = !gSet.keepRes; settingsSave("keepRes"); [_view fit]; }
    else if ([c isEqual:@"freeze"]) gSet.freeze = !gSet.freeze;
    else if ([c isEqual:@"compare"] || [c isEqual:@"compare+"] || [c isEqual:@"compare-"]) { gSet.compare = ([c isEqual:@"compare"] ? arg.intValue : gSet.compare + ([c hasSuffix:@"-"] ? 7 : 1)) & 7; settingsSave("compare"); _view.marking = NO; } // a drag is mapped by the view it started in
    else if ([c isEqual:@"power"]) { // off: the capture device is let go, nothing is drawn, generated or played. the window and the settings stay
        if (_off) { if (!_sourceId.empty()) [self startSource:_sourceId persist:NO]; else { _off = false; [self showMessage:@"Choose a source from the Source menu."]; } }
        else {
            if (record::state() == 2) [self record:@"record" arg:nil]; // closes the file
            [self stopSource];
            audio::stop();
            liveActivity(false); // the mac may sleep its display again
            _missingId.clear();
            _off = true;
            _fps = 0; _hadFrames = false; // the display gets its own mode back
            gSet.freeze = false;
            renderer::clear();
            [self showMessage:@"Meyra is off.\nTurn it on again in the Meyra menu."];
            [self applyRefresh];
        }
    }
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
    if (![before isEqual:presetNow()]) { if (_preset) _presetWas = _preset; _preset = 0; }
    [self hint:c];
    [self updateOverlay:_last gen:_lastGen sr:_lastSr];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self updateLabels]; }); // once a frame with the new stages is drawn
}

// hud areas: the view hands over what a drag marked
- (void)hudAreaAdd:(NSRect)r {
    int n = gSet.hudN;
    if (r.size.width <= 0 || r.size.height <= 0) { [self say:@"hud area: nothing marked — the drag was too small or beside the picture. Q to try again"]; return; }
    if (n >= kHudMax) return;
    gSet.hudRect[4 * n] = (float)r.origin.x; gSet.hudRect[4 * n + 1] = (float)r.origin.y; gSet.hudRect[4 * n + 2] = (float)r.size.width; gSet.hudRect[4 * n + 3] = (float)r.size.height;
    gSet.hudN = n + 1;
    settingsSave("hudRects");
    logLine("hud areas: %s", hudRectsText().c_str());
    [_view showAreas:2.5];
    [self say:[NSString stringWithFormat:@"hud area %d of %d marked — in generated frames this part of the picture now always comes from the real frame%@. Q marks another, the motion menu clears them",
               n + 1, kHudMax, effFrameGen() ? @"" : @" (nothing to do while frame generation is off)"]];
}
// for tests: huddrag:x0,y0,x1,y1 in parts of the view, y from the top. goes through the view's own mouse handling
- (void)testDrag:(NSString *)arg {
    NSArray<NSString *> *v = [arg componentsSeparatedByString:@","];
    if (v.count != 4) return;
    NSSize b = _view.bounds.size;
    NSRect pr = _view.pictureRect;
    logLine("huddrag: view %.0fx%.0f points, picture at %.1f,%.1f %.1fx%.1f (from the bottom left)", b.width, b.height, pr.origin.x, pr.origin.y, pr.size.width, pr.size.height);
    NSEventType types[] = {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseDragged, NSEventTypeLeftMouseUp};
    for (int i = 0; i < 3; i++) {
        NSPoint q = [_view convertPoint:NSMakePoint(v[i ? 2 : 0].doubleValue * b.width, (1 - v[i ? 3 : 1].doubleValue) * b.height) toView:nil];
        NSEvent *ev = [NSEvent mouseEventWithType:types[i] location:q modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:_win.windowNumber
                                          context:nil eventNumber:0 clickCount:1 pressure:i < 2 ? 1 : 0];
        if (i == 0) [_view mouseDown:ev]; else if (i == 1) [_view mouseDragged:ev]; else [_view mouseUp:ev];
    }
}

// a hint line of its own. stays while the overlay is up, else for 6 seconds
- (void)say:(NSString *)t {
    _hint = t;
    double keep = gSet.overlay ? 1e12 : 6;
    _hintUntil = nowSec() + keep;
    logLine("hint: %s", t.UTF8String);
    if (keep < 100) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(keep * 1.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (nowSec() < self->_hintUntil) return; // a later line is up
        self->_hint = nil;
        [self updateOverlay:self->_last gen:self->_lastGen sr:self->_lastSr];
    });
    [self updateOverlay:_last gen:_lastGen sr:_lastSr];
}

static NSArray<NSString *> *presetKeys() {
    return @[@"passthrough", @"deband", @"upscale", @"sharpen", @"enhance", @"enhanceAt", @"enhanceReal", @"enhanceHold", @"superSample", @"denoise", @"frameGen", @"early",
             @"genSmall", @"genStill", @"genModel", @"hudLock", @"cutTest", @"repeatTol", @"ptsTime", @"vsync", @"netHalf", @"genDeadline", @"genLateNext", @"look", @"enhanceDown", @"srWithGen", @"srPad"];
}
// what those are set to right now, as the running state has them (a command line's -key value included)
static NSDictionary *presetNow() {
    return @{@"passthrough": @((bool)gSet.passthrough), @"deband": @((bool)gSet.deband), @"upscale": @(gSet.upscale.load()), @"sharpen": @(round(gSet.sharpen * 100) / 100),
             @"enhance": @(gSet.enhance.load()), @"enhanceAt": @(gSet.enhanceAt.load()), @"enhanceReal": @((bool)gSet.enhanceReal), @"enhanceHold": @((bool)gSet.enhanceHold),
             @"superSample": @((bool)gSet.superSample), @"denoise": @((bool)gSet.denoise), @"frameGen": @((bool)gSet.frameGen), @"early": @((bool)gSet.early),
             @"genSmall": @(gSet.genSmall.load()), @"genStill": @(gSet.genStill.load()), @"genModel": @(gSet.genModel.load()), @"hudLock": @((bool)gSet.hudLock),
             @"cutTest": @((bool)gSet.cutTest), @"repeatTol": @((bool)gSet.repeatTol), @"ptsTime": @((bool)gSet.ptsTime), @"vsync": @((bool)gSet.vsync),
             @"netHalf": @((bool)gSet.netHalf), @"genDeadline": @(gSet.genDeadline.load()), @"genLateNext": @((bool)gSet.genLateNext), @"look": @(gSet.look.load()),
             @"enhanceDown": @(gSet.enhanceDown.load()), @"srWithGen": @((bool)gSet.srWithGen), @"srPad": @((bool)gSet.srPad)};
}
static void logPreset(const char *what, int n) {
    NSDictionary *v = presetNow();
    NSMutableArray<NSString *> *t = [NSMutableArray new];
    for (NSString *k in presetKeys()) [t addObject:[NSString stringWithFormat:@"%@ %@", k, v[k]]];
    logLine("preset %d %s: %s", n % 10, what, [t componentsJoinedByString:@" "].UTF8String);
}
// the switches as they are now, kept under a number. the built-in one comes back with "restore built-in presets"
- (void)savePreset:(int)n {
    if (n < 1 || n > (int)presets().size()) return;
    NSMutableDictionary *v = [presetNow() mutableCopy];
    int en = gSet.enhance;
    if (en > 0 && en <= nets::count()) v[@"enhanceName"] = @(nets::name(en)); // the number is the net's place in the list, which changes when nets are added
    [NSUserDefaults.standardUserDefaults setObject:v forKey:[NSString stringWithFormat:@"customPreset%d", n]];
    _preset = n;
    logPreset("saved", n);
    [self say:[NSString stringWithFormat:@"saved the switches as they are now as preset %d. key %d brings them back", n % 10, n % 10]];
}

- (void)applyPreset:(int)n {
    if (n < 1 || n > (int)presets().size()) return;
    const Preset &p = presets()[n - 1];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSDictionary *own = [d dictionaryForKey:[NSString stringWithFormat:@"customPreset%d", n]]; // saved over this slot with shift + the number
    NSMutableDictionary *v = [@{@"passthrough": @NO, @"deband": @YES, @"upscale": @1, @"sharpen": @0.6, @"enhance": @0, @"enhanceAt": @0, @"enhanceReal": @NO, @"enhanceHold": @NO,
                               @"superSample": @NO, @"denoise": @NO, @"frameGen": @YES, @"early": @NO, @"genSmall": @0, @"genStill": @0, @"genModel": @0, @"hudLock": @NO,
                               @"cutTest": @NO, @"repeatTol": @NO, @"ptsTime": @NO, @"vsync": @YES, @"netHalf": @NO, @"genDeadline": @0, @"genLateNext": @NO, @"look": @0, @"enhanceDown": @0, @"srWithGen": @YES, @"srPad": @YES} mutableCopy];
    [v addEntriesFromDictionary:own ?: p.set];
    NSString *netNote = @"";
    if (NSString *name = v[@"enhanceName"]) { // your own: the net by its name
        int found = 0;
        for (int i = 1; i <= nets::count() && !found; i++) if ([name isEqual:@(nets::name(i))]) found = i;
        v[@"enhance"] = @(found);
        [v removeObjectForKey:@"enhanceName"];
        if (!found) netNote = [NSString stringWithFormat:@" (its enhance net, %@, is not installed: enhance is off)", name.lowercaseString];
    }
    if (p.nets && !own) { // the first of its nets that is there
        int found = 0;
        for (NSString *want in p.nets) {
            for (int i = 1; i <= nets::count() && !found; i++)
                if ([[@(nets::name(i)).lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@" "] containsString:want]) found = i;
            if (found) break;
        }
        v[@"enhance"] = @(found);
        netNote = found ? [NSString stringWithFormat:@" (enhance: %@)", @(nets::name(found)).lowercaseString] : @" (no enhance net found)";
    }
    for (NSString *k in v) [d setObject:v[k] forKey:k];
    settingsLoad();
    saveNetName();
    renderer::layer().displaySyncEnabled = gSet.vsync;
    if (gSet.genModel) { // as choosing it in the menu: look at its files again, and say so when they are not there
        flyhigh::retry();
        if (!framegen::model()) netNote = [netNote stringByAppendingFormat:@" (second generator: %s, apple's stays in use)", !flyhigh::complete() ? "not installed, return downloads it, 1.6 mb" : *framegen::modelNote() ? framegen::modelNote() : "not in use"];
    }
    _preset = n; _presetWas = 0; _genWant = 0;
    logPreset("applied", n);
    // a command line's -key value outranks what a preset stores: say so, a test run would look like a broken preset
    NSMutableArray<NSString *> *kept = [NSMutableArray new];
    NSDictionary *now = presetNow();
    for (NSString *k in presetKeys()) if (fabs([now[k] doubleValue] - [v[k] doubleValue]) > 0.006) [kept addObject:k];
    if (kept.count) logLine("preset %d: not taken, set on the command line for this run: %s", n % 10, [kept componentsJoinedByString:@" "].UTF8String);
    [self say:own ? [NSString stringWithFormat:@"preset %d, your own — the switches as you saved them with shift + %d%@", n % 10, n % 10, netNote]
                  : [NSString stringWithFormat:@"preset %d, %s — %s%@", n % 10, p.name, p.what, netNote]];
}

// after a command: one line for about 3 seconds saying what is set now and what that does, also while the overlay
// itself is hidden (the line then stands alone and goes away again). commands that open a window say nothing
- (void)hint:(NSString *)c {
    static NSString *const kStill[] = {@"exact match only", @"soft", @"by motion against contrast", @"by motion against contrast, allows for dither", @"not kept (test)"};
    static NSString *const kLevels[] = {@"automatic", @"video range", @"full range"}, *const kColour[] = {@"bt.709", @"srgb", @"the screen's own"};
    static NSString *const kUp[] = {@"plain", @"metalfx", @"apple super resolution", @"edge-aware (fsr 1)", @"edge-aware (sgsr 1)"};
    static NSString *const kRefresh[] = {@"off", @"automatic", @"source rate"}, *const kAt[] = {@"after dither removal", @"before dither removal", @"after the upscaler"};
    if ([@[@"source", @"format", @"ain", @"replay", @"picker", @"keys", @"updates", @"revertUpdate"] containsObject:c]) return;
    NSString *b = [c stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"+-"]], *state = nil, *key = c;
    auto valued = [&](int v, NSString *name) { key = [NSString stringWithFormat:@"%@:%d", b, v]; state = name; };
    if ([b isEqual:@"genstill"]) valued(gSet.genStill, kStill[gSet.genStill % 5]);
    else if ([b isEqual:@"genmodel"]) {
        static NSString *const kGen[] = {@"apple's", @"second generator, 480 lines", @"second generator, 720 lines"};
        const char *note = framegen::modelNote();
        valued(gSet.genModel, *note ? [NSString stringWithFormat:@"%@ (%s%s, apple's stays in use)", kGen[gSet.genModel % 3], flyhigh::complete() ? note : "not installed", flyhigh::complete() ? "" : ", return downloads it, 1.6 mb"] : kGen[gSet.genModel % 3]);
    }
    else if ([b isEqual:@"gensmall"]) { int n = gSet.genSmall; valued(n, n ? [NSString stringWithFormat:@"%d×%d", kGenSmallW[n], kGenSmallH[n]] : @"full size"); }
    else if ([b isEqual:@"gendeadline"]) valued(gSet.genDeadline, gSet.genDeadline ? @"by the usual" : @"by the slowest");
    else if ([b isEqual:@"levels"]) valued(gSet.levels, kLevels[gSet.levels % 3]);
    else if ([b isEqual:@"colour"]) valued(gSet.colour, kColour[gSet.colour % 3]);
    else if ([b isEqual:@"upscale"]) valued(gSet.upscale, kUp[gSet.upscale % 5]);
    else if ([b isEqual:@"refresh"]) valued(gSet.refresh, kRefresh[gSet.refresh % 3]);
    else if ([b isEqual:@"enhanceat"]) valued(gSet.enhanceAt, kAt[gSet.enhanceAt % 3]);
    else if ([b isEqual:@"enhancedown"]) valued(gSet.enhanceDown, gSet.enhanceDown ? @"lanczos" : @"area filter");
    else if ([b isEqual:@"schedule"]) valued(gSet.early, gSet.early ? @"early" : @"on the tick");
    else if ([b isEqual:@"enhance"]) { int n = gSet.enhance; valued(n, n && n <= nets::count() ? @(nets::name(n)).lowercaseString : @"off"); }
    else if ([b isEqual:@"sharp"]) state = gSet.sharpen > 0 ? [NSString stringWithFormat:@"%.1f", gSet.sharpen.load()] : @"off";
    else if ([b hasPrefix:@"trim"]) state = fabs(gSet.audioTrim) > 0.0005 ? [NSString stringWithFormat:@"%+.0f ms", gSet.audioTrim * 1000] : @"no nudge";
    else if ([b isEqual:@"winsize"]) state = (_win.styleMask & NSWindowStyleMaskFullScreen) ? [NSString stringWithFormat:@"%.0fp%@", gSet.keepRes ? gWindowed.height : renderer::layer().drawableSize.height, gSet.keepRes ? @", stretched to the screen" : @", the screen's own"]
                                                                    : [NSString stringWithFormat:@"%.0fp", _win.contentView.bounds.size.height * (_win.backingScaleFactor ?: 1)];
    else if ([b isEqual:@"hudmark"]) {
        int w, h, fw, fh, up;
        renderer::lastSize(w, h, fw, fh, up);
        state = _view.marking ? @"drag a rectangle on the picture now" : gSet.hudN >= kHudMax ? [NSString stringWithFormat:@"all %d are in use, clear them first (motion menu)", kHudMax] : !w ? @"no picture to mark on" : @"not this time";
    }
    else if ([b isEqual:@"hudclear"]) state = @"none marked";
    else if ([b isEqual:@"look"]) valued(gSet.look, @(kLookName[gSet.look]));
    else if ([b isEqual:@"compare"]) valued(gSet.compare, gSet.compare && gSet.passthrough ? @"on, shows nothing in plain passthrough" : kCmpLong[gSet.compare & 7]);
    else if ([b isEqual:@"snapshot"]) state = @"saved";
    else if ([b isEqual:@"restart"]) state = @"restarted";
    else if ([b isEqual:@"actual"]) state = @"actual size";
    // the rest are switches: the menu's own check says on or off, and whether the thing can act at all right now
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(menuAction:) keyEquivalent:@""];
    mi.representedObject = key;
    bool can = [self validateMenuItem:mi];
    if (!state && ![b isEqual:@"fullscreen"]) state = mi.state == NSControlStateValueOn ? @"on" : @"off";
    if (!can && ![b isEqual:@"trim0"] && ![b isEqual:@"hudclear"]) state = [state stringByAppendingString:gSet.passthrough ? @" (does nothing while plain passthrough is on)" : @" (cannot run here)"];
    const Tip *t = tipFor(key), *named = tipRow(b) ?: tipRow(c) ?: t;
    if (!t || !named || !named->name) return;
    _hint = state ? [NSString stringWithFormat:@"%s: %@ — %s", named->name, state, t->what] : [NSString stringWithFormat:@"%s — %s", named->name, t->what];
    // with the overlay up the line stays until the next key. on a bare picture it goes away again
    double keep = gSet.overlay ? 1e12 : 6;
    _hintUntil = nowSec() + keep;
    logLine("hint: %s", _hint.UTF8String);
    if (keep < 100) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmin(keep, 1e6) * 1.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (nowSec() < self->_hintUntil) return; // a later command's line is up
        self->_hint = nil;
        [self updateOverlay:self->_last gen:self->_lastGen sr:self->_lastSr];
    });
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
    int w, h, fw, fh, up;
    renderer::lastSize(w, h, fw, fh, up);
    double aspect = w && h ? (double)w / h : 16.0 / 9, s = _win.backingScaleFactor ?: 1;
    if (_win.styleMask & NSWindowStyleMaskFullScreen) { // no window to resize: step the size the picture is made at, the screen stretches it
        double top = _view.bounds.size.height * s, cur = gSet.keepRes ? gWindowed.height : top;
        int next = 0;
        if (px > 0) next = px < top - 1 ? px : 0;
        else for (int z : sizes) if (z > cur + 1 && z < top - 1) { next = z; break; }
        if (!next && px <= 0 && !gSet.keepRes) next = sizes[0]; // from the screen's own size around to the smallest
        gSet.keepRes = next > 0;
        settingsSave("keepRes");
        if (next) gWindowed = CGSizeMake(round(next * aspect), next);
        [_view fit];
        return;
    }
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
                         "N  enhance            D  noise filter\n"
                         "S  still areas in generated frames\n"
                         "Q  mark a hud area: drag a rectangle that always shows the real frame\n"
                         "T  generate at: full size, 864, 768, 720 lines\n"
                         "I  frame generator: apple's, second at 480 lines, second at 720 lines\n"
                         "return  download the second generator, while it is chosen and missing\n"
                         "O  enhance on real frames only   Y  steady enhance   U  supersample\n"
                         "space  freeze the picture\n"
                         "tab  record what is on screen: start, stop. the file goes to movies/meyra\n"
                         "shift + tab  keep the last 30 s instead: tab then saves them\n"
                         "/  compare: original against final (cut, side by side), every stage, off   shift: back\n"
                         ".  look: off, mild, middle, strong\n"
                         "L  hud lock   K  better cut test   P  tolerant repeats   J  capture clock\n"
                         "[ ]  sharpening       A  audio on/off\n"
                         "C  colour             V  vsync\n"
                         "W  window size        X  full screen keeps the window's resolution\n"
                         "1 … 9, 0  presets     shift + number  save the switches as they are over that preset\n"
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
    [app addItem:item(@"Turn Meyra Off", @"power", nil)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:item(@"VSync", @"vsync", @"v", 0)];
    [app addItem:item(@"Game Mode in Full Screen", @"gamemode", nil)];
    [app addItem:item(@"Keep the GPU Awake (uses more power)", @"gpuawake", nil)];
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
    [pic addItem:item(@"Noise Filter", @"denoise", nil)];
    [pic addItem:item(@"Enhance Real Frames Only", @"enhancereal", nil)];
    [pic addItem:item(@"Steady Enhance (anti-flicker)", @"enhancehold", nil)];
    [pic addItem:item(@"Supersample (upscale 2x, then shrink)", @"supersample", nil)];
    NSMenu *lk = submenu(pic, @"Look");
    [lk addItem:item(@"Off", @"look:0", nil)];
    [lk addItem:item(@"Mild", @"look:1", nil)];
    [lk addItem:item(@"Middle", @"look:2", nil)];
    [lk addItem:item(@"Strong", @"look:3", nil)];
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
    NSMenu *en = submenu(pic, @"Enhance");
    [en addItem:item(@"Off", @"enhance:0", nil)];
    for (int i = 1; i <= nets::count(); i++) [en addItem:item(ns(nets::name(i)), [NSString stringWithFormat:@"enhance:%d", i], nil)];
    [en addItem:NSMenuItem.separatorItem];
    [en addItem:item(@"After Dither Removal", @"enhanceat:0", nil)];
    [en addItem:item(@"Before Dither Removal", @"enhanceat:1", nil)];
    [en addItem:item(@"After the Upscaler", @"enhanceat:2", nil)];
    [en addItem:NSMenuItem.separatorItem];
    [en addItem:item(@"Smaller Windows: Area Filter", @"enhancedown:0", nil)];
    [en addItem:item(@"Smaller Windows: Lanczos (Keeps More Detail)", @"enhancedown:1", nil)];
    [en addItem:NSMenuItem.separatorItem];
    [en addItem:item(@"Half Precision (faster)", @"nethalf", nil)];
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
    NSMenu *gm = submenu(mo, @"Frame Generator");
    [gm addItem:item(@"Apple's Interpolator", @"genmodel:0", nil)];
    [gm addItem:item(@"Second Generator, 480 Lines", @"genmodel:1", nil)];
    [gm addItem:item(@"Second Generator, 720 Lines", @"genmodel:2", nil)];
    NSMenu *ga = submenu(mo, @"Generate At");
    [ga addItem:item(@"Full Size", @"gensmall:0", nil)];
    [ga addItem:item(@"1536×864 (faster, a little softer)", @"gensmall:3", nil)];
    [ga addItem:item(@"1344×768 (faster, softer)", @"gensmall:2", nil)];
    [ga addItem:item(@"1280×720 (fastest, softest)", @"gensmall:1", nil)];
    NSMenu *gd = submenu(mo, @"Generated Frame Deadline");
    [gd addItem:item(@"By the Slowest", @"gendeadline:0", nil)];
    [gd addItem:item(@"By the Usual", @"gendeadline:1", nil)];
    [mo addItem:item(@"Show Late Generated Frames a Refresh Later", @"genlatenext", nil)];
    NSMenu *gs = submenu(mo, @"Still Areas in Generated Frames");
    [gs addItem:item(@"Exact Match Only", @"genstill:0", nil)];
    [gs addItem:item(@"Soft (allows for dither)", @"genstill:1", nil)];
    [gs addItem:item(@"By Motion Against Contrast", @"genstill:2", nil)];
    [gs addItem:item(@"By Motion Against Contrast, Allows for Dither", @"genstill:3", nil)];
    [mo addItem:item(@"Lock the HUD in Generated Frames", @"hudlock", nil)];
    [mo addItem:item(@"Mark HUD Area", @"hudmark", @"q", 0)];
    [mo addItem:item(@"Clear HUD Areas", @"hudclear", nil)];
    [mo addItem:item(@"Show HUD Areas", @"hudshow", nil)];
    [mo addItem:item(@"Better Scene Cut Test", @"cuttest", nil)];
    [mo addItem:item(@"Tolerant Repeat Detection", @"repeattol", nil)];
    [mo addItem:item(@"Time Frames by Capture Clock", @"ptstime", nil)];
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
    NSMenu *pm = submenu(bar, @"Presets");
    for (size_t i = 0; i < presets().size(); i++) {
        NSString *t = @(presets()[i].name);
        NSMenuItem *mi = item([[[t substringToIndex:1] uppercaseString] stringByAppendingString:[t substringFromIndex:1]], [NSString stringWithFormat:@"preset:%zu", i + 1], nil);
        mi.toolTip = @(presets()[i].what);
        [pm addItem:mi];
    }
    [pm addItem:NSMenuItem.separatorItem];
    NSMenu *ps = submenu(pm, @"Save Current Switches As");
    for (size_t i = 0; i < presets().size(); i++) {
        NSMenuItem *mi = item([NSString stringWithFormat:@"Preset %zu", (i + 1) % 10], [NSString stringWithFormat:@"presetsave:%zu", i + 1], nil);
        mi.toolTip = [NSString stringWithFormat:@"keeps every picture and motion switch as it is now under key %zu (also: shift + %zu)", (i + 1) % 10, (i + 1) % 10];
        [ps addItem:mi];
    }
    for (size_t i = 0; i < presets().size(); i++) { // only the saved ones show, see validateMenuItem
        NSMenuItem *mi = item([NSString stringWithFormat:@"Remove My Preset %zu", (i + 1) % 10], [NSString stringWithFormat:@"presetremove:%zu", i + 1], nil);
        mi.toolTip = [NSString stringWithFormat:@"forgets the preset you saved under key %zu, the built-in one is back there", (i + 1) % 10];
        mi.hidden = YES;
        [pm addItem:mi];
    }
    NSMenuItem *pr = item(@"Restore Built-in Presets", @"presetreset", nil);
    pr.toolTip = @"forgets the presets you saved, the built-in ones are back on every number";
    [pm addItem:pr];
    NSMenu *rc = submenu(bar, @"Recording");
    [rc addItem:item(@"Start Recording (Tab)", @"record", nil)];
    [rc addItem:item(@"Keep The Last 30 Seconds (Shift + Tab)", @"reckeep", nil)];
    [rc addItem:NSMenuItem.separatorItem];
    NSMenu *rs = [[NSMenu alloc] initWithTitle:@"Size"], *rb = [[NSMenu alloc] initWithTitle:@"Bitrate"];
    [rs addItem:item(@"As Shown", @"recsize:0", nil)];
    for (NSString *h in @[@"2160", @"1440", @"1080", @"720"]) [rs addItem:item([NSString stringWithFormat:@"At Most %@p", h], [@"recsize:" stringByAppendingString:h], nil)];
    [rb addItem:item(@"Automatic: By Size (17 Mbit/s At 720p, 37 At 1080p, 66 At 1440p)", @"recrate:0", nil)];
    // what they look like at 1080p: a bigger picture wants more for the same
    NSArray *rates = @[@[@"10", @"Small File, Soft In Fast Motion"], @[@"20", @"Good, Fine For Sharing"], @[@"40", @"Very Good, For Uploads"],
                       @[@"60", @"Excellent"], @[@"100", @"Close To Lossless, Large File"]];
    for (NSArray *m in rates) [rb addItem:item([NSString stringWithFormat:@"%@ Mbit/s: %@ (%d MB A Minute)", m[0], m[1], (int)lround([m[0] intValue] * 7.5)], [@"recrate:" stringByAppendingString:m[0]], nil)];
    [[rc addItemWithTitle:@"Size" action:nil keyEquivalent:@""] setSubmenu:rs];
    [[rc addItemWithTitle:@"Bitrate" action:nil keyEquivalent:@""] setSubmenu:rb];
    [rc addItem:item(@"Include Overlay In Recordings", @"recoverlay", nil)];
    [rc addItem:NSMenuItem.separatorItem];
    [rc addItem:item(@"Open Recordings Folder", @"recfolder", nil)];
    NSMenu *wm = submenu(bar, @"Window");
    NSMenuItem *fs = [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [wm addItem:item(@"Actual Size", @"actual", @"0")];
    [wm addItem:item(@"Full Screen Keeps the Window's Resolution", @"keepres", nil)];
    NSMenu *ws = submenu(wm, @"Window Size");
    [ws addItem:item(@"Next Size", @"winsize+", @"w", 0)];
    for (int z : {720, 900, 1080, 1440, 2160}) [ws addItem:item([NSString stringWithFormat:@"%dp", z], [NSString stringWithFormat:@"winsize:%d", z], nil)];
    [wm addItem:item(@"Show Status Overlay", @"overlay:menu", @"i")];
    NSMenu *cv = submenu(wm, @"Compare");
    [cv addItem:item(@"Freeze Picture (Space)", @"freeze", nil)];
    [cv addItem:NSMenuItem.separatorItem];
    [cv addItem:item(@"Off", @"compare:0", nil)];
    [cv addItem:item(@"Original Left, Final Right", @"compare:1", nil)];
    [cv addItem:item(@"Original Above, Final Below", @"compare:2", nil)];
    [cv addItem:item(@"Diagonal", @"compare:3", nil)];
    [cv addItem:item(@"Side by Side, the Same Part", @"compare:4", nil)];
    [cv addItem:item(@"One Above the Other, the Same Part", @"compare:5", nil)];
    [cv addItem:NSMenuItem.separatorItem];
    [cv addItem:item(@"Every Stage, Strips of the Picture", @"compare:6", nil)];
    [cv addItem:item(@"Every Stage, the Same Strip", @"compare:7", nil)];
    [wm addItem:NSMenuItem.separatorItem];
    [wm addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [wm addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [wm addItem:NSMenuItem.separatorItem];
    [wm addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    wm.delegate = self;
    NSApp.windowsMenu = wm;

    NSMenu *hm = submenu(bar, @"Help");
    [hm addItem:item(@"Keyboard Shortcuts", @"keys", nil)];
    NSApp.helpMenu = hm;
    setTips(bar); // every item says what it does, from the same table as the overlay's hint line
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
        if (i.toolTip.length) logLine("tip  %*s%s", depth * 2, "", i.toolTip.UTF8String);
        else logLine("tip  %*s(none) for %s", depth * 2, "", i.title.UTF8String);
        if (i.submenu) [self dumpMenu:i.submenu depth:depth + 1];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)m {
    if (m != _sourceMenu) { setTips(m); return; } // the window menu: appkit adds items of its own
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
        none.toolTip = @(tipRow(@"-nodevices")->what);
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
        n.toolTip = @(tipRow(@"-driver")->what);
    }
    setTips(m);
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
    else if ([c isEqual:@"denoise"]) { on = gSet.denoise; enabled = !pass && noise::available(); }
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
    else if ([c isEqual:@"enhance"]) {
        on = gSet.enhance == arg.intValue;
        enabled = !pass;
        const char *st = nets::status(arg.intValue);
        if (arg.intValue) mi.title = on && *st ? [NSString stringWithFormat:@"%@ (%@)", @(nets::name(arg.intValue)), @(st)] : ns(nets::name(arg.intValue));
    }
    else if ([c isEqual:@"enhanceat"]) { on = gSet.enhanceAt == arg.intValue; enabled = !pass && gSet.enhance; }
    else if ([c isEqual:@"enhancedown"]) { on = gSet.enhanceDown == arg.intValue; enabled = !pass && gSet.enhance; }
    else if ([c isEqual:@"sharp"]) { on = fabsf(gSet.sharpen - arg.floatValue) < 0.05f; enabled = !pass; }
    else if ([c isEqual:@"sharp+"] || [c isEqual:@"sharp-"]) enabled = !pass;
    else if ([c isEqual:@"passthrough"]) on = pass;
    else if ([c isEqual:@"framegen"]) { on = gSet.frameGen; enabled = framegen::available() && !pass; }
    else if ([c isEqual:@"schedule"]) on = gSet.early == (arg.intValue != 0);
    else if ([c isEqual:@"gensmall"]) { on = arg ? gSet.genSmall == arg.intValue : gSet.genSmall != 0; enabled = framegen::available() && !pass && !framegen::model(); } // apple's sizes, the second generator has its own
    else if ([c isEqual:@"gendeadline"]) { on = gSet.genDeadline == arg.intValue; enabled = framegen::available() && !pass; }
    else if ([c isEqual:@"genlatenext"]) { on = gSet.genLateNext; enabled = framegen::available() && !pass; }
    else if ([c isEqual:@"nethalf"]) { on = gSet.netHalf; enabled = !pass && nets::halfApplies(gSet.enhance); }
    else if ([c isEqual:@"gpuawake"]) on = gSet.gpuAwake;
    else if ([c isEqual:@"genmodel"]) {
        on = gSet.genModel == arg.intValue; enabled = framegen::available() && !pass;
        static NSString *const kTitle[] = {@"Apple's Interpolator", @"Second Generator, 480 Lines", @"Second Generator, 720 Lines"};
        if (arg.intValue > 0 && arg.intValue < 3 && mi.title.length) mi.title = !flyhigh::complete() ? [kTitle[arg.intValue] stringByAppendingString:@" (Download…)"] : *flyhigh::note() ? [NSString stringWithFormat:@"%@ (%s)", kTitle[arg.intValue], flyhigh::note()] : kTitle[arg.intValue];
    }
    else if ([c isEqual:@"hudlock"]) { on = gSet.hudLock; enabled = !pass; }
    else if ([c isEqual:@"hudmark"]) { on = _view.marking; enabled = !pass; mi.title = gSet.hudN ? [NSString stringWithFormat:@"Mark HUD Area (%d of %d marked)", gSet.hudN.load(), kHudMax] : @"Mark HUD Area"; }
    else if ([c isEqual:@"hudclear"]) enabled = gSet.hudN > 0;
    else if ([c isEqual:@"hudshow"]) on = gSet.hudShow;
    else if ([c isEqual:@"cuttest"]) { on = gSet.cutTest; enabled = !pass; }
    else if ([c isEqual:@"repeattol"]) { on = gSet.repeatTol; enabled = !pass; }
    else if ([c isEqual:@"ptstime"]) { on = gSet.ptsTime; enabled = !pass; }
    else if ([c isEqual:@"enhancereal"]) { on = gSet.enhanceReal; enabled = !pass; }
    else if ([c isEqual:@"enhancehold"]) { on = gSet.enhanceHold; enabled = !pass; }
    else if ([c isEqual:@"look"]) { on = gSet.look == arg.intValue; enabled = !pass; }
    else if ([c isEqual:@"supersample"]) { on = gSet.superSample; enabled = !pass; }
    else if ([c isEqual:@"genstill"]) { on = gSet.genStill == arg.intValue; enabled = framegen::available() && !pass; }
    else if ([c isEqual:@"refresh"]) on = gSet.refresh == arg.intValue;
    else if ([c isEqual:@"audio"]) on = gSet.audio;
    else if ([c isEqual:@"trim0"]) {
        mi.title = fabs(gSet.audioTrim) > 0.0005 ? [NSString stringWithFormat:@"Reset Delay (now %+.0f ms)", gSet.audioTrim * 1000] : @"Reset Delay";
        enabled = fabs(gSet.audioTrim) > 0.0005;
    }
    else if ([c isEqual:@"overlay"]) on = gSet.overlay;
    else if ([c isEqual:@"preset"]) {
        on = _preset == arg.intValue;
        int n = arg.intValue; // the title follows what the number holds
        NSString *t = @(presets()[MAX(1, MIN(n, (int)presets().size())) - 1].name);
        bool own = [NSUserDefaults.standardUserDefaults dictionaryForKey:[NSString stringWithFormat:@"customPreset%d", n]] != nil;
        mi.title = [NSString stringWithFormat:@"%d  %@", n % 10, own ? @"Your Own" : [[[t substringToIndex:1] uppercaseString] stringByAppendingString:[t substringFromIndex:1]]];
    }
    else if ([c isEqual:@"presetremove"]) mi.hidden = ![NSUserDefaults.standardUserDefaults dictionaryForKey:[NSString stringWithFormat:@"customPreset%d", arg.intValue]];
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
    else if ([c isEqual:@"power"]) mi.title = _off ? @"Turn Meyra On" : @"Turn Meyra Off";
    else if ([c isEqual:@"keepres"]) on = gSet.keepRes;
    else if ([c isEqual:@"freeze"]) on = gSet.freeze;
    else if ([c isEqual:@"record"]) { int st = record::state(); on = st == 2; mi.title = st == 1 ? [NSString stringWithFormat:@"Save The Last %d Seconds (Tab)", recSecs()] : st == 2 ? @"Stop Recording (Tab)" : @"Start Recording (Tab)"; }
    else if ([c isEqual:@"reckeep"]) { on = record::state() == 1; mi.title = [NSString stringWithFormat:@"Keep The Last %d Seconds (Shift + Tab)", recSecs()]; }
    else if ([c isEqual:@"recoverlay"]) on = [d boolForKey:@"recOverlay"];
    else if ([c isEqual:@"recsize"]) on = recMaxH() == arg.intValue;
    else if ([c isEqual:@"recrate"]) on = (int)[d integerForKey:@"recMbit"] == arg.intValue;
    else if ([c isEqual:@"compare"]) { on = gSet.compare == arg.intValue; enabled = !pass; }
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


- (void)windowDidEnterFullScreen:(NSNotification *)n { [NSCursor setHiddenUntilMouseMoves:YES]; [_view fit]; [self applyRefresh]; }
- (void)windowDidExitFullScreen:(NSNotification *)n { _goingFull = false; [_view fit]; [self applyRefresh]; } // variable refresh only works full screen
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
        logLine("settings: levels %d deband %d upscale %d sharpen %.2f framegen %d early %d passthrough %d audio %d trim %+.0f ms refresh %d overlay %d enhance %d at %d gensmall %d genstill %d denoise %d",
                gSet.levels.load(), (int)gSet.deband, gSet.upscale.load(), gSet.sharpen.load(), (int)gSet.frameGen, (int)gSet.early, (int)gSet.passthrough,
                (int)gSet.audio, gSet.audioTrim * 1000, gSet.refresh.load(), (int)gSet.overlay, gSet.enhance.load(), gSet.enhanceAt.load(), gSet.genSmall.load(), gSet.genStill.load(), (int)gSet.denoise);
        if (gSet.netHalf || gSet.genDeadline || gSet.genLateNext || gSet.gpuAwake)
            logLine("settings: nethalf %d gendeadline %d genlatenext %d gpuawake %d", (int)gSet.netHalf, gSet.genDeadline.load(), (int)gSet.genLateNext, (int)gSet.gpuAwake);
        if (gSet.genModel) logLine("settings: frame generator %d%s%s", gSet.genModel.load(), *framegen::modelNote() ? ", " : "", framegen::modelNote());
        if (gArgs.listDevices) { listDevices(); return 0; }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
