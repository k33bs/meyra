// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
// helper sections for the copy debug report (machine, displays, changed settings) and the privacy scrubbing.
#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <Security/Security.h>
#include "debugreport.h"
#include <sys/sysctl.h>
#include <unistd.h>
#include <vector>

namespace debugreport {

static std::string str(NSString *s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }

static std::string join(const std::vector<std::string> &v) {
    std::string o;
    for (size_t i = 0; i < v.size(); i++) o += (i ? "\n  " : "  ") + v[i];
    return o;
}

static std::string sysStr(const char *name) {
    size_t n = 0;
    if (sysctlbyname(name, nullptr, &n, nullptr, 0) || !n) return "";
    std::string s(n, '\0');
    if (sysctlbyname(name, &s[0], &n, nullptr, 0)) return "";
    s.resize(strnlen(s.c_str(), n));
    return s;
}

static bool sysInt(const char *name, uint64_t &out) {
    uint64_t v = 0;
    size_t n = sizeof v;
    if (sysctlbyname(name, &v, &n, nullptr, 0)) return false;
    if (n == 4) v = (uint32_t)v;
    out = v;
    return true;
}

static std::string hz(double v) {
    char b[32];
    snprintf(b, sizeof b, "%.2f", v);
    std::string s = b;
    while (s.back() == '0') s.pop_back();
    if (s.back() == '.') s.pop_back();
    return s;
}

static bool isHex(const std::string &s) {
    for (char c : s) if (!isxdigit((unsigned char)c)) return false;
    return !s.empty();
}

// a few hex digits of a hash of the whole id: two devices of the same kind can be told apart, the id cannot be read back
std::string idHash(const std::string &id) {
    uint32_t h = 2166136261u; // fnv-1a
    for (unsigned char c : id) { h ^= c; h *= 16777619u; }
    char b[16];
    snprintf(b, sizeof b, "#%04x", (h ^ (h >> 16)) & 0xffff);
    return b;
}

std::string shortId(const std::string &id) {
    size_t c = id.find(':');
    if (c == std::string::npos) return "";
    std::string pre = id.substr(0, c), rest = id.substr(c + 1);
    if (pre == "avf") {
        if (rest.compare(0, 2, "0x") == 0 && rest.size() >= 18 && isHex(rest.substr(2))) {
            std::string t = rest.substr(rest.size() - 8);
            return "avf usb " + t.substr(0, 4) + ":" + t.substr(4);
        }
        return "avf";
    }
    if (pre == "replay") {
        size_t s = rest.rfind('/');
        return "replay:" + (s == std::string::npos ? rest : rest.substr(s + 1));
    }
    return rest.size() <= 4 ? id : pre;
}

namespace {
struct Rule { NSRegularExpression *re; NSString *tpl; };

NSRegularExpression *rx(NSString *p) {
    return [NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
}

// rules in the order they must run
const std::vector<Rule> &rules() {
    static std::vector<Rule> r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *home = NSHomeDirectory();
        if (home.length > 1) r.push_back({rx([NSRegularExpression escapedPatternForString:home]), @"~"});
        r.push_back({rx(@"/Users/[^/\\s]+"), @"~"});
        char hb[256] = {};
        gethostname(hb, sizeof hb - 1); // not NSProcessInfo.hostName: that can wait on the network, on the main thread
        NSString *host = @(hb);
        if ([host.lowercaseString hasSuffix:@".local"]) host = [host substringToIndex:host.length - 6];
        if (host.length >= 3) {
            NSString *e = [NSRegularExpression escapedPatternForString:host];
            r.push_back({rx([NSString stringWithFormat:@"%@(?:\\.local)?", e]), @"(host)"});
        }
        NSString *full = NSFullUserName();
        if (full.length >= 3)
            r.push_back({rx([NSString stringWithFormat:@"(?<![\\p{L}\\p{N}_])%@(?![\\p{L}\\p{N}_])",
                                                       [NSRegularExpression escapedPatternForString:full]]), @"(name)"});
        // an owner's name in front of a device, "alex's iphone camera", "alex smith’s airpods pro": the owner goes
        r.push_back({rx(@"(?<![\\p{L}\\p{N}])(?:\\p{Lu}[\\p{L}.-]* )?\\p{Lu}[\\p{L}\\p{N}._-]*['’]s (?=\\p{Lu}|\\p{Ll}*[A-Z])"), @""});
        r.push_back({rx(@"(?<![0-9a-fA-F])[0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5}(?![0-9a-fA-F])"), @"(id)"}); // a mac address (bluetooth audio ids)
        r.push_back({rx(@"0x[0-9a-fA-F]{8}([0-9a-fA-F]{4})([0-9a-fA-F]{4})(?![0-9a-fA-F])"), @"usb $1:$2"});
        r.push_back({rx(@"0x[0-9a-fA-F]{12,}"), @"(id)"});
        r.push_back({rx(@"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"), @"(id)"});
        r.push_back({rx(@"[0-9a-fA-F]{24,}"), @"(id)"});
    });
    return r;
}
}

std::string scrub(const std::string &s) {
    NSMutableString *m = [ns(s) mutableCopy];
    if (!m) return s;
    for (auto &r : rules())
        if (r.re) [r.re replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:r.tpl];
    return str(m);
}

std::string machine() {
    std::vector<std::string> v;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *ver = info[@"CFBundleShortVersionString"], *bld = info[@"CFBundleVersion"], *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!ver && !bld && !bid) v.push_back("version unknown (not run from the app bundle)");
    else v.push_back("meyra " + (ver ? str(ver) : "?") + " (build " + (bld ? str(bld) : "?") + "), bundle " + (bid ? str(bid) : "?"));
    v.push_back("macos " + str(NSProcessInfo.processInfo.operatingSystemVersionString));
    std::string l = "model " + sysStr("hw.model") + ", chip " + sysStr("machdep.cpu.brand_string");
    uint64_t mem = 0, p = 0, e = 0;
    if (sysInt("hw.memsize", mem)) l += ", memory " + std::to_string((mem + (1ull << 29)) >> 30) + " GB";
    if (sysInt("hw.perflevel0.physicalcpu", p)) {
        l += ", cores " + std::to_string(p) + " performance";
        if (sysInt("hw.perflevel1.physicalcpu", e)) l += " + " + std::to_string(e) + " efficiency";
    }
    v.push_back(l);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    const char *th = "unknown";
    switch (pi.thermalState) {
    case NSProcessInfoThermalStateNominal: th = "nominal"; break;
    case NSProcessInfoThermalStateFair: th = "fair"; break;
    case NSProcessInfoThermalStateSerious: th = "serious"; break;
    case NSProcessInfoThermalStateCritical: th = "critical"; break;
    }
    v.push_back("gpu " + (dev ? str(dev.name) : std::string("none")) + ", thermal state " + th +
                ", low power mode " + (pi.lowPowerModeEnabled ? "on" : "off"));
    return join(v);
}

static const char *authText(AVAuthorizationStatus s) {
    switch (s) {
    case AVAuthorizationStatusAuthorized: return "allowed";
    case AVAuthorizationStatusDenied: return "denied";
    case AVAuthorizationStatusRestricted: return "restricted";
    default: return "not asked yet";
    }
}

std::string access(bool commandLine) {
    std::vector<std::string> v;
    // only asks the state, never prompts
    v.push_back(std::string("camera ") + authText([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) + ", microphone " +
                authText([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) +
                (commandLine ? " (from a terminal these are the terminal's, not meyra's)" : ""));
    // a changed or broken signature makes macos forget the camera permission, or refuse it silently
    std::string sig = "signature: not checked";
    SecStaticCodeRef code = NULL;
    NSURL *url = NSBundle.mainBundle.bundleURL;
    if (url && SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) == errSecSuccess && code) {
        OSStatus st = SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
        CFDictionaryRef info = NULL;
        std::string kind;
        if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) == errSecSuccess && info) {
            NSDictionary *d = (__bridge NSDictionary *)info;
            uint32_t flags = [d[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue];
            kind = flags & kSecCodeSignatureAdhoc ? ", ad hoc (camera permission is asked again after every new build)" : d[(__bridge NSString *)kSecCodeInfoTeamIdentifier] ? ", developer certificate" : "";
            CFRelease(info);
        }
        if (st == errSecSuccess) sig = "signature valid" + kind;
        else {
            NSString *why = CFBridgingRelease(SecCopyErrorMessageString(st, NULL));
            sig = "signature does not verify (" + str(why ?: [NSString stringWithFormat:@"%d", (int)st]) + ")" + kind;
        }
        CFRelease(code);
    } else if (!url) sig = "signature: not run from the app bundle";
    v.push_back(sig);
    return join(v);
}

std::string displays(NSScreen *windowScreen) {
    std::vector<std::string> v;
    for (NSScreen *s in NSScreen.screens) {
        CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        double scale = s.backingScaleFactor, w = s.frame.size.width, h = s.frame.size.height;
        double cur = 0;
        if (CGDisplayModeRef m = CGDisplayCopyDisplayMode(did)) {
            cur = CGDisplayModeGetRefreshRate(m);
            CFRelease(m);
        }
        double mx = (double)s.maximumFramesPerSecond;
        std::string rate = cur > 0 ? hz(cur) + " Hz" : hz(mx) + " Hz (from max, current unknown)";
        double lo = s.minimumRefreshInterval, hi = s.maximumRefreshInterval;
        std::string vrr = "no";
        if (lo > 0 && hi - lo > 0.002) vrr = "yes, " + hz(1 / hi) + "-" + hz(1 / lo) + " Hz";
        std::string l = scrub(str(s.localizedName)) + ": " + hz(w) + "x" + hz(h) + " pt, " + hz(w * scale) + "x" + hz(h * scale) +
                        " px, scale " + hz(scale) + ", refresh " + rate + ", max " + hz(mx) + " Hz, variable refresh " + vrr +
                        (CGDisplayIsBuiltin(did) ? ", built-in" : ", external") + (CGDisplayIsMain(did) ? ", main" : "");
        if (windowScreen && s == windowScreen) l += " <- window";
        v.push_back(l);
    }
    if (v.empty()) v.push_back("(no screens)");
    return join(v);
}

static std::string valueText(id o) {
    if ([o isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)o) == CFBooleanGetTypeID()) return [o boolValue] ? "true" : "false";
        return str([o stringValue]);
    }
    if ([o isKindOfClass:NSString.class]) {
        NSString *t = o;
        if ([t containsString:@"/"]) t = t.lastPathComponent;
        return scrub(str(t));
    }
    if ([o isKindOfClass:NSDictionary.class]) return "(dictionary, " + std::to_string([o count]) + " entries)";
    if ([o isKindOfClass:NSArray.class]) return "(array, " + std::to_string([o count]) + " entries)";
    if ([o isKindOfClass:NSData.class]) return "(data, " + std::to_string([o length]) + " bytes)";
    return scrub(str([o description]));
}

static bool skipKey(NSString *k) { return [k hasPrefix:@"NS"] || [k hasPrefix:@"Apple"] || [k hasPrefix:@"com.apple"]; }

std::string settings() {
    std::vector<std::string> v;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *saved = bid ? [d persistentDomainForName:bid] : nil;
    NSDictionary *reg = [d volatileDomainForName:NSRegistrationDomain];
    NSArray *idDicts = @[@"formats", @"audioInputs", @"layouts"];
    if (!saved) v.push_back("(no saved settings)");
    else {
        for (NSString *k in [saved.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id o = saved[k];
            if (skipKey(k) || [o isEqual:reg[k]]) continue;
            std::string key = str(k);
            if ([k hasPrefix:@"customPreset"]) v.push_back(key + " = (saved)");
            else if ([idDicts containsObject:k] && [o isKindOfClass:NSDictionary.class]) {
                NSDictionary *sub = o;
                if (!sub.count) v.push_back(key + " = (dictionary, 0 entries)");
                for (NSString *sk in [sub.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                    id sv = sub[sk];
                    std::string t;
                    if ([k isEqual:@"audioInputs"])
                        t = ([sv isEqual:@"auto"] || [sv isEqual:@"none"]) ? str(sv) : "(a chosen input)";
                    else t = valueText(sv);
                    v.push_back(key + "[" + shortId(str(sk)) + "] = " + t);
                }
            }
            else if ([k isEqual:@"source"] && [o isKindOfClass:NSString.class]) v.push_back(key + " = " + shortId(str(o)));
            else if ([k isEqual:@"sourceName"] && [o isKindOfClass:NSString.class]) v.push_back(key + " = " + scrub(str(o)));
            else v.push_back(key + " = " + valueText(o));
        }
        if (v.empty()) v.push_back("(all settings at default)");
    }
    NSDictionary *args = [d volatileDomainForName:NSArgumentDomain];
    for (NSString *k in [args.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (!skipKey(k)) v.push_back(str(k) + " = " + valueText(args[k]) + " (command line, this run only)");
    return join(v);
}

}
