// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
//
// what this protects against: a broken or truncated download (size cap, sha-256 from the release notes, codesign
// verify) and a wrong file (bundle id, version). what it does not: whoever controls the github account controls the
// release, the asset and the checksum next to it. with ad-hoc signing the update is trusted because it comes from the
// project's releases over https, nothing more. once the app is signed with a developer id, the new bundle must carry
// the same team identifier as the running one, which is checked below.
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include "update.h"
#include "common.h"
#include <sys/stat.h>
#include <unistd.h>

namespace update {

static NSString *const kReleasesAPI = @"https://api.github.com/repos/k33bs/meyra/releases/latest";
static NSString *const kDownloadPrefix = @"https://github.com/k33bs/meyra/releases/download/";
static NSString *const kAssetPrefix = @"Meyra-";      // Meyra-v0.1.0.zip, a zip of Meyra.app
static const long long kMaxBytes = 50 * 1000 * 1000;  // the app zips to a few megabytes
static const double kTimeout = 15;                    // seconds, for the api request
static const double kDownloadTimeout = 300;

bool parseVersion(const std::string &str, std::vector<int> &v) {
    NSString *s = [@(str.c_str()) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([s hasPrefix:@"v"] || [s hasPrefix:@"V"]) s = [s substringFromIndex:1];
    v.clear();
    for (NSString *p in [s componentsSeparatedByString:@"."]) {
        if (p.length == 0 || p.length > 9 || [p rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return false;
        v.push_back(p.intValue);
    }
    return !v.empty() && v.size() <= 4;
}

int compareVersions(const std::vector<int> &a, const std::vector<int> &b) {
    for (size_t i = 0; i < std::max(a.size(), b.size()); i++) {
        int x = i < a.size() ? a[i] : 0, y = i < b.size() ? b[i] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

std::string versionString(const std::vector<int> &v) {
    std::string s = "v";
    for (size_t i = 0; i < v.size(); i++) s += (i ? "." : "") + std::to_string(v[i]);
    return s;
}

static NSString *ns(const std::string &s) { return @(s.c_str()); }

bool parseRelease(NSData *json, Release &r, std::string &err) {
    NSDictionary *d = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![d isKindOfClass:NSDictionary.class] || ![d[@"tag_name"] isKindOfClass:NSString.class]) { err = "GitHub's answer could not be read."; return false; }
    r = Release();
    r.tag = [d[@"tag_name"] UTF8String];
    if (!parseVersion(r.tag, r.version)) { err = "The latest release's tag \"" + r.tag + "\" is not a version number."; return false; }
    if ([d[@"body"] isKindOfClass:NSString.class]) r.notes = [d[@"body"] UTF8String];
    NSRange h = [ns(r.notes) rangeOfString:@"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])" options:NSRegularExpressionSearch];
    if (h.location != NSNotFound) r.sha256 = [[ns(r.notes) substringWithRange:h] lowercaseString].UTF8String;
    NSArray *assets = [d[@"assets"] isKindOfClass:NSArray.class] ? d[@"assets"] : @[];
    for (NSDictionary *a in assets) {
        if (![a isKindOfClass:NSDictionary.class] || ![a[@"name"] isKindOfClass:NSString.class] || ![a[@"browser_download_url"] isKindOfClass:NSString.class]) continue;
        NSString *name = a[@"name"];
        if (![name hasPrefix:kAssetPrefix] || ![name.lowercaseString hasSuffix:@".zip"]) continue;
        r.assetName = name.UTF8String;
        r.assetURL = [a[@"browser_download_url"] UTF8String];
        r.size = [a[@"size"] isKindOfClass:NSNumber.class] ? [a[@"size"] longLongValue] : 0;
        return true;
    }
    err = "The latest release (" + versionString(r.version) + ") has no " + kAssetPrefix.UTF8String + "….zip download.";
    return false;
}

static NSDictionary *infoOf(NSURL *app) { return [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Contents/Info.plist"]]; }

std::string bundleVersion(NSURL *app) {
    NSString *v = infoOf(app)[@"CFBundleShortVersionString"];
    return [v isKindOfClass:NSString.class] ? v.UTF8String : "";
}

static NSMutableURLRequest *request(NSURL *u, double timeout) {
    NSMutableURLRequest *q = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    // stated here so nothing else is sent: no identifiers, no system versions, no locale
    [q setValue:[NSString stringWithFormat:@"Meyra/%s", bundleVersion(NSBundle.mainBundle.bundleURL).c_str()] forHTTPHeaderField:@"User-Agent"];
    [q setValue:@"en" forHTTPHeaderField:@"Accept-Language"];
    return q;
}

void check(const std::string &url, void (^done)(const CheckResult &)) {
    NSMutableURLRequest *q = request([NSURL URLWithString:url.empty() ? kReleasesAPI : ns(url)], kTimeout);
    [q setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[s dataTaskWithRequest:q completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        CheckResult res;
        NSHTTPURLResponse *h = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        long code = h ? (long)h.statusCode : 0;
        std::string err;
        if (e) res.message = std::string("GitHub could not be reached (") + (e.localizedDescription.UTF8String ?: "?") + ").";
        else if (code == 404) res.message = "No published release was found. The project's releases are not public yet, or there are none.";
        else if (code == 429 || (code == 403 && [[h valueForHTTPHeaderField:@"X-RateLimit-Remaining"] isEqual:@"0"]))
            res.message = "GitHub's limit for requests without an account was reached. Try again in an hour.";
        else if (code != 200) res.message = "GitHub answered with HTTP " + std::to_string(code) + ".";
        else if (!parseRelease(data, res.release, err)) res.message = err;
        else {
            std::vector<int> mine;
            parseVersion(bundleVersion(NSBundle.mainBundle.bundleURL), mine);
            res.ok = true;
            res.newer = compareVersions(res.release.version, mine) > 0;
            res.message = res.newer ? "Meyra " + versionString(res.release.version) + " is available (this is " + versionString(mine) + ")."
                                    : "Meyra is up to date (" + versionString(mine) + ").";
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(res); });
    }] resume];
    [s finishTasksAndInvalidate];
}

std::string locationProblem(NSURL *app) {
    NSString *p = app.path;
    if ([p rangeOfString:@"/AppTranslocation/"].location != NSNotFound)
        return "Meyra is running from a temporary read-only copy that macOS makes for apps opened straight from a download. "
               "Move Meyra to the Applications folder, open it from there, and check again.";
    NSNumber *ro = nil;
    [app getResourceValue:&ro forKey:NSURLVolumeIsReadOnlyKey error:nil];
    if (ro.boolValue) return "Meyra is running from a read-only disk, such as a disk image. Copy it to the Applications folder first.";
    NSString *dir = p.stringByDeletingLastPathComponent;
    if (access(dir.fileSystemRepresentation, W_OK) != 0 || access(p.fileSystemRepresentation, W_OK) != 0)
        return std::string("Your user account cannot change files in ") + dir.UTF8String +
               ". Move Meyra to a folder you can write to, or install the update by hand from the releases page.";
    return "";
}

static int runTool(NSString *tool, NSArray<NSString *> *args, std::string *out = nullptr) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:tool];
    t.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    if (![t launchAndReturnError:nil]) return -1;
    NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (out) *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String ?: "";
    return t.terminationStatus;
}

static std::string teamOf(NSURL *app) {
    SecStaticCodeRef code = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)app, kSecCSDefaultFlags, &code) != errSecSuccess) return "";
    std::string team;
    CFDictionaryRef info = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) == errSecSuccess && info) {
        NSString *t = ((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
        if ([t isKindOfClass:NSString.class]) team = t.UTF8String;
        CFRelease(info);
    }
    CFRelease(code);
    return team;
}

// a temporary folder on the same volume as the app, so the final moves are renames
static NSURL *stagingFor(NSURL *app, std::string &err) {
    NSError *e = nil;
    NSURL *d = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:app create:YES error:&e];
    if (!d) err = std::string("No temporary folder next to the app (") + (e.localizedDescription.UTF8String ?: "?") + ").";
    return d;
}

static NSURL *keptDir() {
    NSURL *as = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [as URLByAppendingPathComponent:@"Meyra/Previous Version" isDirectory:YES];
}

bool verifySha256(NSURL *file, const std::string &hex, std::string &err) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
    if (!f) { err = "The download could not be read."; return false; }
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    for (;;) {
        @autoreleasepool {
            NSData *d = [f readDataUpToLength:1 << 20 error:nil];
            if (!d.length) break;
            CC_SHA256_Update(&c, d.bytes, (CC_LONG)d.length);
        }
    }
    [f closeFile];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &c);
    char got[65];
    for (int i = 0; i < 32; i++) snprintf(got + 2 * i, 3, "%02x", md[i]);
    if (hex == got) return true;
    err = "The download does not match the SHA-256 checksum in the release notes, it was not installed.";
    return false;
}

static bool isRealDir(NSURL *u) {
    struct stat st;
    return lstat(u.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

// the unpacked bundle, before anything is touched: ours, the announced version, newer, intact signature
static std::string validate(NSURL *nu, const Release &r, NSURL *app) {
    NSDictionary *info = infoOf(nu), *mine = infoOf(app);
    std::vector<int> v, cur;
    if (!isRealDir(nu) || !info) return "The download does not contain Meyra.app.";
    if (![info[@"CFBundleIdentifier"] isEqual:mine[@"CFBundleIdentifier"]])
        return std::string("The downloaded app has a different bundle identifier (") + ([info[@"CFBundleIdentifier"] description].UTF8String ?: "none") + ").";
    if (!parseVersion(bundleVersion(nu), v) || compareVersions(v, r.version) != 0)
        return "The downloaded app is version " + bundleVersion(nu) + ", not the announced " + versionString(r.version) + ".";
    parseVersion(bundleVersion(app), cur);
    if (compareVersions(v, cur) <= 0) return "The downloaded app (" + versionString(v) + ") is not newer than this one (" + versionString(cur) + ").";
    std::string why;
    if (runTool(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", nu.path], &why) != 0) return "The downloaded app's code signature is not valid: " + why;
    std::string team = teamOf(app);
    if (!team.empty() && teamOf(nu) != team) return "The downloaded app is not signed by the same developer as this one.";
    return "";
}

NSURL *unpack(NSURL *zip, const Release &r, NSURL *app, std::string &err) {
    // every entry must sit inside Meyra.app, nothing absolute, no way up
    std::string list;
    if (runTool(@"/usr/bin/unzip", @[@"-Z1", zip.path], &list) != 0) { err = "The download is not a zip archive."; return nil; }
    for (NSString *line in [ns(list) componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length || [line hasPrefix:@"__MACOSX/"]) continue;
        if (![line hasPrefix:@"Meyra.app/"] || [line rangeOfString:@".."].location != NSNotFound) { err = "The download contains files outside Meyra.app."; return nil; }
    }
    NSURL *stage = stagingFor(app, err);
    if (!stage) return nil;
    NSURL *nu = [stage URLByAppendingPathComponent:@"Meyra.app"];
    err = runTool(@"/usr/bin/ditto", @[@"-x", @"-k", zip.path, stage.path]) != 0 ? "The download could not be unpacked." : validate(nu, r, app);
    if (err.empty()) return nu;
    [NSFileManager.defaultManager removeItemAtURL:stage error:nil];
    return nil;
}

// app -> aside, staged -> app, aside -> kept. a failure before the second rename puts everything back
bool swapIn(NSURL *app, NSURL *staged, NSURL *kept, std::string &err) {
    NSURL *aside = [staged.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Meyra (replaced).app"];
    if (rename(app.fileSystemRepresentation, aside.fileSystemRepresentation) != 0) {
        err = std::string("The current version could not be moved aside (") + strerror(errno) + "). Nothing was changed.";
        return false;
    }
    if (rename(staged.fileSystemRepresentation, app.fileSystemRepresentation) != 0) {
        std::string why = strerror(errno);
        if (rename(aside.fileSystemRepresentation, app.fileSystemRepresentation) != 0)
            err = "The new version could not be put in place (" + why + ") and the old one could not be moved back. It is at " + aside.path.UTF8String + ".";
        else err = "The new version could not be put in place (" + why + "). The current version was left as it was.";
        return false;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dst = [kept URLByAppendingPathComponent:@"Meyra.app"];
    [fm createDirectoryAtURL:kept withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:dst error:nil];
    if (![fm moveItemAtURL:aside toURL:dst error:nil]) logLine("update: the previous version could not be kept");
    return true;
}

bool revertIn(NSURL *app, NSURL *kept, std::string &err) {
    NSURL *src = [kept URLByAppendingPathComponent:@"Meyra.app"];
    if (!isRealDir(src) || ![infoOf(src)[@"CFBundleIdentifier"] isEqual:infoOf(app)[@"CFBundleIdentifier"]]) { err = "There is no previous version to go back to."; return false; }
    std::string why;
    if (runTool(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", src.path], &why) != 0) { err = "The previous version's code signature is no longer valid: " + why; return false; }
    NSURL *stage = stagingFor(app, err);
    if (!stage) return false;
    NSURL *staged = [stage URLByAppendingPathComponent:@"Meyra.app"];
    NSError *e = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:src toURL:staged error:&e]) { err = std::string("The previous version could not be prepared (") + (e.localizedDescription.UTF8String ?: "?") + ")."; return false; }
    if (swapIn(app, staged, kept, err)) { [NSFileManager.defaultManager removeItemAtURL:stage error:nil]; return true; }
    [NSFileManager.defaultManager moveItemAtURL:staged toURL:src error:nil];
    return false;
}

bool previousVersion(std::string &version) {
    NSURL *k = [keptDir() URLByAppendingPathComponent:@"Meyra.app"];
    if (!isRealDir(k)) return false;
    version = bundleVersion(k);
    return true;
}

std::string revert() {
    NSURL *app = NSBundle.mainBundle.bundleURL;
    std::string err = locationProblem(app);
    if (err.empty()) revertIn(app, keptDir(), err);
    return err;
}

void relaunch() {
    // a detached shell waits for this process to end, then opens the bundle at the same path again
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", @"while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"", @"sh",
                    [NSString stringWithFormat:@"%d", getpid()], NSBundle.mainBundle.bundlePath];
    [t launchAndReturnError:nil];
}

}

// download with a size cap enforced while it runs, https only, also across redirects (github sends the asset from
// another host). file urls are allowed for the self test only
@interface MeyraDownload : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^progress)(double);
@property (nonatomic, copy) void (^done)(NSURL *file, NSString *failure);
@property (nonatomic) long long cap, expected;
@property (nonatomic, strong) NSURL *dest;
@property (nonatomic, copy) NSString *failure;
@end

@implementation MeyraDownload
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void (^)(NSURLRequest *))cb {
    NSString *h = q.URL.host.lowercaseString ?: @"";
    bool github = [h isEqual:@"github.com"] || [h hasSuffix:@".github.com"] || [h hasSuffix:@".githubusercontent.com"];
    if (![q.URL.scheme isEqual:@"https"] || !github) self.failure = @"The download was redirected somewhere unexpected.";
    cb(self.failure ? nil : q);
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)n totalBytesWritten:(int64_t)w totalBytesExpectedToWrite:(int64_t)x {
    if (w > self.cap) { self.failure = @"The download is larger than an app update can be."; [t cancel]; return; }
    long long total = x > 0 ? x : self.expected;
    if (self.progress && total > 0) self.progress(fmin(1.0, (double)w / total));
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)loc {
    NSHTTPURLResponse *h = [t.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)t.response : nil;
    if (h && h.statusCode != 200) { self.failure = [NSString stringWithFormat:@"The download answered with HTTP %ld.", (long)h.statusCode]; return; }
    NSNumber *size = [[NSFileManager.defaultManager attributesOfItemAtPath:loc.path error:nil] objectForKey:NSFileSize];
    if (size.longLongValue > self.cap) { self.failure = @"The download is larger than an app update can be."; return; }
    if (![NSFileManager.defaultManager moveItemAtURL:loc toURL:self.dest error:nil]) self.failure = @"The download could not be saved.";
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    NSString *f = self.failure ?: (e ? [NSString stringWithFormat:@"The download failed (%@).", e.localizedDescription] : nil);
    if (!f && ![NSFileManager.defaultManager fileExistsAtPath:self.dest.path]) f = @"Nothing was downloaded.";
    self.done(f ? nil : self.dest, f);
    [s finishTasksAndInvalidate]; // the session holds its delegate until then
}
@end

namespace update {

static void fetchAndInstall(const Release &r, NSURL *src, NSURL *app, NSURL *kept, void (^progress)(double), void (^done)(const std::string &)) {
    std::string err;
    NSURL *dir = stagingFor(app, err);
    if (!dir) { done(err); return; }
    MeyraDownload *dl = [MeyraDownload new];
    dl.cap = kMaxBytes;
    dl.expected = r.size;
    dl.progress = progress;
    dl.dest = [dir URLByAppendingPathComponent:@"update.zip"];
    Release rel = r;
    dl.done = ^(NSURL *file, NSString *failure) {
        std::string e = failure ? failure.UTF8String : "";
        NSURL *staged = nil;
        // no checksum, no install: this runs unattended at launch for everyone
        if (e.empty() && rel.sha256.empty()) e = "The release notes carry no SHA-256 checksum, so the download cannot be checked.";
        if (e.empty()) verifySha256(file, rel.sha256, e);
        if (e.empty()) staged = unpack(file, rel, app, e);
        if (e.empty()) swapIn(app, staged, kept, e);
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
        // if the app is missing its old copy may still be in there: leave it for the user (the error says where)
        if (staged && isRealDir(app)) [NSFileManager.defaultManager removeItemAtURL:staged.URLByDeletingLastPathComponent error:nil];
        done(e);
    };
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForResource = kDownloadTimeout;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:dl delegateQueue:NSOperationQueue.mainQueue];
    [[s downloadTaskWithRequest:request(src, kTimeout)] resume];
}

void install(const Release &r, void (^progress)(double), void (^done)(const std::string &)) {
    NSURL *app = NSBundle.mainBundle.bundleURL;
    std::string err = locationProblem(app);
    if (err.empty() && r.size > kMaxBytes) err = "The release's download is larger than an app update can be.";
    if (err.empty() && ![ns(r.assetURL) hasPrefix:kDownloadPrefix]) err = "The release's download is not on the project's releases page.";
    if (!err.empty()) { done(err); return; }
    fetchAndInstall(r, [NSURL URLWithString:ns(r.assetURL)], app, keptDir(), progress, done);
}

// --update-test JSON ZIP APP KEPTDIR    the whole install path on local files, against APP (a copy, not the running app)
// --update-revert-test APP KEPTDIR      revert APP to the bundle kept in KEPTDIR
// --update-check [URL]                  one real check, prints what the menu would say
int selfTest(const std::vector<std::string> &a) {
    std::vector<int> x, y;
    bool ok = parseVersion("v1.0.10", x) && parseVersion("1.0.9", y) && compareVersions(x, y) > 0 && parseVersion("V1.0", x) &&
              parseVersion("1.0.0", y) && compareVersions(x, y) == 0 && !parseVersion("1.0-beta", x) && !parseVersion("", x) && !parseVersion("v", x);
    printf("version compare: %s\n", ok ? "ok" : "FAILED");
    if (!ok) return 1;
    __block bool finished = false;
    __block int code = 0;
    void (^wait)(void) = ^{ while (!finished) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]; };
    if (a[0] == "--update-check") {
        check(a.size() > 1 ? a[1] : "", ^(const CheckResult &r) { printf("check: %s\n", r.message.c_str()); code = r.ok ? 0 : 2; finished = true; });
        wait();
        return code;
    }
    if (a[0] == "--update-revert-test" && a.size() >= 3) {
        std::string err;
        bool done = revertIn([NSURL fileURLWithPath:ns(a[1])], [NSURL fileURLWithPath:ns(a[2])], err);
        printf("revert: %s\n", done ? "ok" : err.c_str());
        return done ? 0 : 2;
    }
    if (a[0] != "--update-test" || a.size() < 5) { printf("usage: --update-test JSON ZIP APP KEPTDIR | --update-revert-test APP KEPTDIR | --update-check [URL]\n"); return 1; }
    Release r;
    std::string err;
    NSURL *app = [NSURL fileURLWithPath:ns(a[3])];
    if (!parseRelease([NSData dataWithContentsOfFile:ns(a[1])], r, err)) { printf("rejected: %s\n", err.c_str()); return 2; }
    std::vector<int> cur;
    parseVersion(bundleVersion(app), cur);
    printf("release %s, asset %s, %lld bytes, sha-256 %s; app is %s\n", versionString(r.version).c_str(), r.assetName.c_str(), r.size,
           r.sha256.empty() ? "none in the notes" : r.sha256.c_str(), versionString(cur).c_str());
    if (compareVersions(r.version, cur) <= 0) { printf("rejected: not newer than the app, nothing to install\n"); return 2; }
    err = locationProblem(app);
    if (!err.empty()) { printf("rejected: %s\n", err.c_str()); return 2; }
    fetchAndInstall(r, [NSURL fileURLWithPath:ns(a[2])], app, [NSURL fileURLWithPath:ns(a[4])], nil, ^(const std::string &e) {
        printf("%s%s\n", e.empty() ? "installed " : "rejected: ", e.empty() ? bundleVersion(app).c_str() : e.c_str());
        code = e.empty() ? 0 : 2;
        finished = true;
    });
    wait();
    return code;
}

}
