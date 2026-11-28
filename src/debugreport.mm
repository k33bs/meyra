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
#include <algorithm>
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
        if (rest.compare(0, 2, "0x") == 0 && rest.size() >= 17 && isHex(rest.substr(2))) { // the location's leading zero can be missing
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

// the parts of a device name around an owner. an apple device word is kept, and so is what kind of part it is
// (camera, microphone, in a few languages); a name is a capitalised word that is neither, with "de la", "van der" in it
#define MODEL_RE "(?:iPhone|iPad|iPod|iMac|MacBook|Mac|AirPods|HomePod|Apple|Beats|Vision)(?!\\p{Ll})"
#define ROLE_RE "(?i:camera|kamera|caméra|cámara|câmera|fotocamera|microphone|mikrofon|micro|micrófono|microfono|microfone|microfoon)(?!\\p{L})"
#define WORD_RE "(?!" MODEL_RE ")(?!" ROLE_RE ")\\p{Lu}[\\p{L}\\p{M}'’.-]*"
#define PART_RE "(?:de|da|do|dos|das|del|della|di|van|von|der|den|la|le|du|y|e|zu)"
#define PREP_RE "(?:von|van|de|di|da|do|dos|das)"
#define OWNER_RE WORD_RE "(?:(?: " PART_RE ")* " WORD_RE "){0,3}"
// a personal apple device in a name: then the name is rebuilt from the device words, the words right after them that
// say which one (pro, max, 15) and the kind words, and everything else goes, whatever the order or the owner's script
// ("alex iphone", "alexin iphone", "アレックスのiphone", "iphone (alex)", "alex's iphone" in capitals, "alex mac"). "apple" alone or a
// screen ("apple cinema display") is not one, nor a card made "for mac" or "(for ipad)": its own name stays
#define DEVW_RE "(?:(?<!\\p{Latin})(?i:iPhone|iPad|iPod|iMac|MacBook|AirPods|HomePod)(?!\\p{Latin})|(?<!\\p{Latin})Mac(?!\\p{Latin})|(?:Apple (?:Watch|TV|Vision)|Vision Pro)(?!\\p{Ll}))"
#define BEATS_RE "(?:Beats|Powerbeats)(?!\\p{Ll})"
#define NOTFOR_RE "(?<![Ff]or )(?<![Ff]or \\()"
#define TRIG_RE NOTFOR_RE "(?:" DEVW_RE "|" BEATS_RE ")"
#define QUAL_RE "(?:Pro|Max|Air|mini|Studio|Plus|Ultra|SE|touch|Watch|TV|Vision|\\d+(?:\\.\\d+)?)(?![\\p{L}\\p{N}])"
#define BQUAL_RE "(?:Fit|Flex|Studio|Solo\\d*|Buds\\+?|Pill\\+?|Pro|Plus|Max|X|\\d+)(?![\\p{L}\\p{N}])" // beats models: fit pro, studio buds+, solo3
#define KEEP_RE NOTFOR_RE "(?:" BEATS_RE "(?: +" BQUAL_RE ")*|" DEVW_RE "(?: +" QUAL_RE ")*)|(?<!\\p{L})(?:" ROLE_RE "|Desk View(?!\\p{L})|Sidecar(?: Display)?(?!\\p{L})|\\(\\d+\\))"
// a localised built-in or other device as macos names its parts: "câmera do studio display", "micrófono de logitech
// brio". what follows is kept as a device only when it looks like one (a digit, two capitals in a row, or a screen
// or camera word); else it is taken as an owner ("kamera von alex", "câmera do joão" lose it)
#define ROLEOF_RE "^" ROLE_RE " (?:de|da|do|dos|das|del|della|di|du|des|von|van|of) (?=\\p{Lu})"
#define PRODUCT_RE "\\p{N}|\\p{Lu}{2}|(?<!\\p{L})(?i:display|studio|webcam|facecam|capture|retina|facetime|monitor)(?!\\p{L})"
// an owner behind a device: words without digits up to the end, a closing quote or bracket, or a kind word ("bose qc35
// ii von alex"; "philips de luxe 4k" stays, a name has no 4k after it)
#define NAMEW_RE "[^\\s„“”\"«»()\\[\\]\\p{N}]+"
#define TAIL_RE NAMEW_RE "(?: (?!" ROLE_RE ")" NAMEW_RE "){0,5}(?: \\d{1,2})?(?=$| ?[”\"»’)\\]]| \\(| " ROLE_RE ")" // "von alex 2" too

// what this mac knows about its owner: home folder, host name, full name
const std::vector<Rule> &machineRules() {
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
    });
    return r;
}

// the same on every mac, in the order they must run
// an owner's name in front of a device, "alex's iphone camera", "alex smith’s airpods pro", "james’ ipad": the owner
// goes. without the apostrophe ("alexs ipad", swedish too) only in front of an apple device word
const std::vector<Rule> &frontRules() {
    static std::vector<Rule> r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r.push_back({rx(@"(?<![\\p{L}\\p{N}])(?:\\p{Lu}[\\p{L}.-]* )?\\p{Lu}[\\p{L}\\p{N}._-]*(?:['’]s|s['’]) (?=\\p{Lu}|\\p{Ll}*[A-Z])"), @""});
        r.push_back({rx(@"(?<![\\p{L}\\p{N}])(?:\\p{Lu}[\\p{L}.-]* )?\\p{Lu}[\\p{L}\\p{N}._-]*s (?=" MODEL_RE ")"), @""});
    });
    return r;
}

// usb serials, mac addresses and other long ids
const std::vector<Rule> &idRules() {
    static std::vector<Rule> r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r.push_back({rx(@"(?<![0-9a-fA-F])[0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5}(?![0-9a-fA-F])"), @"(id)"}); // a mac address (bluetooth audio ids)
        r.push_back({rx(@"0x[0-9a-fA-F]{7,8}([0-9a-fA-F]{4})([0-9a-fA-F]{4})(?![0-9a-fA-F])"), @"usb $1:$2"});
        r.push_back({rx(@"0x[0-9a-fA-F]{12,}"), @"(id)"});
        r.push_back({rx(@"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"), @"(id)"});
        r.push_back({rx(@"[0-9a-fA-F]{24,}"), @"(id)"});
    });
    return r;
}

// running text: owner in front, then behind ("iphone von alex", "iphone de alex", "iphone d’alex", "ipad van jan de
// vries", "iphone di marco"; only a capitalised name, and not a device word: "microfone do macbook pro" stays), then ids
const std::vector<Rule> &rules() {
    static std::vector<Rule> r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r = frontRules();
        r.push_back({rx(@"(?<=[\\p{L}\\p{N}\\p{Pf}\\p{Pe}\"'’]) " PREP_RE " [„“\"«]?" OWNER_RE), @""});
        r.push_back({rx(@"(?<=[\\p{L}\\p{N}]) d['’]" OWNER_RE), @""});
        r.insert(r.end(), idRules().begin(), idRules().end());
    });
    return r;
}

// a bare device name, nothing after it: the owner behind it goes, lower case too ("iphone von alex", "kamera von „iphone
// von alex“" keeps "kamera von „iphone“"), in front with an apostrophe, capitals too ("jean’s bose"), and before a
// chinese, japanese or korean possessive ("张伟的galaxy buds", "알렉스의 galaxy buds")
const std::vector<Rule> &nameRules() {
    static std::vector<Rule> r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r.push_back({rx(@"(?<=[\\p{L}\\p{N}\\p{Pf}\\p{Pe}\"'’]) " PREP_RE " (?:[„“\"«‘] ?)?(?!" MODEL_RE ")" TAIL_RE "(?: ?[”\"»’])?"), @""});
        r.push_back({rx(@"(?<=[\\p{L}\\p{N}]) d['’](?!" MODEL_RE ")" TAIL_RE), @""});
        r.push_back({rx(@"^(?:[\\p{L}\\p{N}._-]+ )?[\\p{L}\\p{N}._-]+(?:['’][sS]|[sS]['’]) (?=\\p{Lu}|\\p{Ll}*[A-Z])"), @""});
        r.push_back({rx(@"^(?:[\\p{L}\\p{N}._-]+ )?[\\p{L}\\p{N}._-]+s (?=" MODEL_RE ")"), @""});
        r.push_back({rx(@"^[^A-Za-z0-9]{1,40}?(?:的|の|의) ?(?=[A-Za-z0-9])"), @""});
        r.push_back({rx(@"  +"), @" "});
    });
    return r;
}

void apply(NSMutableString *m, const std::vector<Rule> &rs) {
    for (auto &r : rs)
        if (r.re) [r.re replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:r.tpl];
}
}

std::string scrub(const std::string &s) {
    NSMutableString *m = [ns(s) mutableCopy];
    if (!m) return s;
    apply(m, machineRules());
    apply(m, rules());
    return str(m);
}

// the name rules alone, without this mac's own: for the self-test
static NSString *nameOnly(NSMutableString *m) {
    static NSRegularExpression *trig = rx(@TRIG_RE), *keep = rx(@KEEP_RE), *roleOf = rx(@ROLEOF_RE), *product = rx(@PRODUCT_RE);
    if (trig && keep && [trig firstMatchInString:m options:0 range:NSMakeRange(0, m.length)]) {
        NSMutableArray<NSString *> *kept = [NSMutableArray new];
        for (NSTextCheckingResult *r in [keep matchesInString:m options:0 range:NSMakeRange(0, m.length)]) [kept addObject:[m substringWithRange:r.range]];
        if (kept.count) return [kept componentsJoinedByString:@" "];
    }
    NSTextCheckingResult *r = [roleOf firstMatchInString:m options:0 range:NSMakeRange(0, m.length)];
    if (r && [product firstMatchInString:m options:0 range:NSMakeRange(NSMaxRange(r.range), m.length - NSMaxRange(r.range))]) { // "câmera do " + the device's own rules
        NSString *rest = nameOnly([[m substringFromIndex:NSMaxRange(r.range)] mutableCopy]);
        if (rest.length) return [[m substringToIndex:NSMaxRange(r.range)] stringByAppendingString:rest];
    }
    apply(m, frontRules());
    apply(m, idRules());
    apply(m, nameRules());
    return [m stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

std::string scrubName(const std::string &s) {
    NSMutableString *m = [ns(s) mutableCopy];
    if (!m) return s;
    apply(m, machineRules());
    return str(nameOnly(m));
}

// each known name is held out of the running-text rules by a private-use mark while they run, then put back as its
// scrubName: so "câmera do studio display" is not cut by the rule for "iphone do alex"
std::string scrubKnown(const std::string &s, std::vector<std::string> names) {
    NSMutableString *m = [ns(s) mutableCopy];
    if (!m) return scrub(s);
    std::sort(names.begin(), names.end(), [](const std::string &a, const std::string &b) { return a.size() > b.size(); }); // "iphone von alex kamera" before "iphone von alex"
    NSMutableArray<NSString *> *marks = [NSMutableArray new], *clean = [NSMutableArray new];
    for (auto &n : names) {
        NSString *raw = ns(n);
        if (n.size() < 3 || !raw || marks.count >= 0x1000 || ![m containsString:raw]) continue;
        unichar u = 0xE000 + marks.count;
        NSString *mark = [NSString stringWithCharacters:&u length:1];
        [m replaceOccurrencesOfString:raw withString:mark options:0 range:NSMakeRange(0, m.length)];
        [marks addObject:mark];
        [clean addObject:ns(scrubName(n)) ?: @""];
    }
    apply(m, machineRules());
    apply(m, rules());
    for (NSUInteger i = 0; i < marks.count; i++) [m replaceOccurrencesOfString:marks[i] withString:clean[i] options:0 range:NSMakeRange(0, m.length)];
    return str(m);
}

// --self-test: the rules alone (not this mac's own name) on names as macos makes them in a few languages
int scrubTest() {
    struct Case { const char *in, *want; bool name; };
    static const Case cases[] = {
        {"Alex's iPhone Camera", "iPhone Camera", true}, {"Alex Smith’s AirPods Pro", "AirPods Pro", true},
        {"Alexs iPad", "iPad", true}, {"James’ iPhone", "iPhone", true}, {"alex's iPhone", "iPhone", true},
        {"iPhone von Alex", "iPhone", true}, {"iPhone von alex", "iPhone", true}, {"MacBook Pro von Alex Müller", "MacBook Pro", true},
        {"Kamera von „iPhone von Alex“", "Kamera iPhone", true}, {"iPhone de Alex", "iPhone", true},
        {"iPhone d’Alex", "iPhone", true}, {"iPhone d'Émilie", "iPhone", true}, {"iPhone di Marco", "iPhone", true},
        {"iPad van Jan de Vries", "iPad", true}, {"iPhone de Ana de la Cruz", "iPhone", true}, {"Câmera do iPhone de Ana Souza", "Câmera iPhone", true},
        {"iPhone von Alex Kamera", "iPhone Kamera", true}, {"Microfone do MacBook Pro", "Microfone MacBook Pro", true},
        {"USB Video", "USB Video", true}, {"Cam Link 4K", "Cam Link 4K", true}, {"Elgato HD60 X", "Elgato HD60 X", true},
        {"FaceTime HD Camera", "FaceTime HD Camera", true}, {"MacBook Pro Microphone", "MacBook Pro Microphone", true},
        {"Mac mini", "Mac mini", true}, {"Studio Display Camera", "Studio Display Camera", true},
        {"UltraStudio Recorder 3G", "UltraStudio Recorder 3G", true}, {"Game Capture HD60 S+", "Game Capture HD60 S+", true},
        {"Alex iPhone", "iPhone", true}, {"Alex’ iPhone", "iPhone", true}, {"Alexin iPhone", "iPhone", true},
        {"Alex’in iPhone’u", "iPhone", true}, {"アレックスのiPhone", "iPhone", true}, {"iPhone (Alex)", "iPhone", true},
        {"iPhone d’alex", "iPhone", true}, {"alexs iPad", "iPad", true}, {"Apple TV von Alex", "Apple TV", true},
        {"iPhone 15 Pro Max de Alex", "iPhone 15 Pro Max", true}, {"iPhone von Max", "iPhone", true},
        {"Kamera von alex", "Kamera", true}, {"Caméra d’alex", "Caméra", true}, {"alexs Mac", "Mac", true}, {"alex's Mac", "Mac", true},
        {"Apple Cinema Display", "Apple Cinema Display", true}, {"Pro Display XDR", "Pro Display XDR", true},
        {"Built-in Retina Display", "Built-in Retina Display", true}, {"AVerMedia Live Gamer EXTREME 3", "AVerMedia Live Gamer EXTREME 3", true},
        // 0.6.1 review: owner in any script or case, plain mac, other makes' devices; and names that must stay usable
        {"Alexin iPhone Camera", "iPhone Camera", true}, {"アレックスのiPhoneのカメラ", "iPhone", true}, {"张伟的iPhone相机", "iPhone", true},
        {"Alex iPhone-kamera", "iPhone kamera", true}, {"iPhone (Алекс) Camera", "iPhone Camera", true}, {"ALEX'S IPHONE", "IPHONE", true},
        {"alex iphone", "iphone", true}, {"アレックスのMac", "Mac", true}, {"Alexin Mac", "Mac", true}, {"Mac (Alex)", "Mac", true},
        {"Alex Mac", "Mac", true}, {"张伟的Galaxy Buds", "Galaxy Buds", true}, {"알렉스의 Galaxy Buds", "Galaxy Buds", true},
        {"アレックスのWH-1000XM4", "WH-1000XM4", true}, {"JEAN’S BOSE QC35", "BOSE QC35", true}, {"Bose QC35 II von Alex", "Bose QC35 II", true},
        {"Câmera de “Alex”", "Câmera", true}, {"Samsung Q80 de la sala", "Samsung Q80", true}, {"iPhone von Alex (2)", "iPhone (2)", true},
        {"Alex’s iPhone Desk View Camera", "iPhone Desk View Camera", true}, {"Beats Fit Pro", "Beats Fit Pro", true},
        {"Alex’s Beats Flex", "Beats Flex", true}, {"Beats Studio Buds", "Beats Studio Buds", true},
        {"Câmera do Studio Display", "Câmera do Studio Display", true}, {"Cámara de Studio Display", "Cámara de Studio Display", true},
        {"Micrófono de Logitech BRIO", "Micrófono de Logitech BRIO", true}, {"Philips de Luxe 4K", "Philips de Luxe 4K", true},
        {"Studio Displayのカメラ", "Studio Displayのカメラ", true}, {"HDMI Capture for iPad Pro", "HDMI Capture for iPad Pro", true},
        {"Cam Link 4K (for Mac mini)", "Cam Link 4K (for Mac mini)", true}, {"MacroSilicon USB Video", "MacroSilicon USB Video", true},
        {"MACROSILICON USB VIDEO", "MACROSILICON USB VIDEO", true}, {"Kamera von Alex", "Kamera", true}, {"Câmera do João", "Câmera", true},
        {"Cámara de Ana Souza", "Cámara", true}, {"Mikrofon von Alex Müller", "Mikrofon", true}, {"Bose QC35 II von Alex 2", "Bose QC35 II", true},
        {"Cámara de Elgato Facecam", "Cámara de Elgato Facecam", true}, {"Câmera do LG UltraFine", "Câmera do LG UltraFine", true},
        {"source iPhone von Alex [avf #1a2b], system capture", "source iPhone [avf #1a2b], system capture", false},
        {"audio input Alex’s AirPods Pro, state 2 \"running\"", "audio input AirPods Pro, state 2 \"running\"", false},
        {"order input 1080p -> dither removal -> metalfx 3840×2160 -> screen", "order input 1080p -> dither removal -> metalfx 3840×2160 -> screen", false},
    };
    int bad = 0;
    for (auto *rs : {&machineRules(), &rules(), &nameRules()}) // a pattern that does not compile is left out silently in use
        for (auto &r : *rs) if (!r.re) { printf("FAIL a scrub rule does not compile\n"); bad++; }
    if (!rx(@TRIG_RE) || !rx(@KEEP_RE) || !rx(@ROLEOF_RE) || !rx(@PRODUCT_RE)) { printf("FAIL the device word rule does not compile\n"); bad++; }
    for (auto &c : cases) {
        NSMutableString *m = [@(c.in) mutableCopy];
        std::string got;
        if (c.name) got = str(nameOnly(m));
        else { apply(m, rules()); got = str([m stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]); }
        bool ok = got == c.want;
        bad += !ok;
        printf("%s scrub%s \"%s\" -> \"%s\"%s\n", ok ? "ok  " : "FAIL", c.name ? "Name" : "", c.in, got.c_str(), ok ? "" : (" (want \"" + std::string(c.want) + "\")").c_str());
    }
    // a line with a name known at report time (a log line, the last message, macos' error text) gets the name's own
    // rule, and the running-text rules leave the cleaned name alone
    struct Known { const char *in, *name, *want; };
    static const Known known[] = {
        {"source start: iPhone von alex, format default", "iPhone von alex", "source start: iPhone, format default"},
        {"last message: Alexin iPhone Camera was disconnected.", "Alexin iPhone Camera", "last message: iPhone Camera was disconnected."},
        {"last message: アレックスのiPhoneのカメラ was disconnected.", "アレックスのiPhoneのカメラ", "last message: iPhone was disconnected."},
        {"last message: 张伟的iPhone相机 was disconnected.", "张伟的iPhone相机", "last message: iPhone was disconnected."},
        {"last message: Alex iPhone-kamera was disconnected.", "Alex iPhone-kamera", "last message: iPhone kamera was disconnected."},
        {"last message: iPhone (Алекс) Camera was disconnected.", "iPhone (Алекс) Camera", "last message: iPhone Camera was disconnected."},
        {"last message: No picture from iPhone von alex (running).", "iPhone von alex", "last message: No picture from iPhone (running)."},
        {"last error: Câmera do Studio Display is in use", "Câmera do Studio Display", "last error: Câmera do Studio Display is in use"},
        {"avfoundation: audio from Alexin iPhone Microphone (chosen), device runs 48000 Hz 1 ch", "Alexin iPhone Microphone", "avfoundation: audio from iPhone Microphone (chosen), device runs 48000 Hz 1 ch"},
        {"sound no sound coming in (input: Alex’s AirPods Pro, chosen; output: Alex’s AirPods Pro)", "Alex’s AirPods Pro", "sound no sound coming in (input: AirPods Pro, chosen; output: AirPods Pro)"},
        {"sound in step with the picture (input: Alexin iPhone Microphone, auto: same name; output: MacBook Pro Speakers)", "Alexin iPhone Microphone", "sound in step with the picture (input: iPhone Microphone, auto: same name; output: MacBook Pro Speakers)"},
        {"avfoundation: USB Video started, 1920 × 1080 @ 60, audio from Alex’s AirPods Pro (auto: same id, of the ones alike by same name)", "Alex’s AirPods Pro", "avfoundation: USB Video started, 1920 × 1080 @ 60, audio from AirPods Pro (auto: same id, of the ones alike by same name)"},
    };
    for (auto &c : known) {
        std::string got = scrubKnown(c.in, {c.name, "USB Video"});
        bool ok = got == c.want;
        bad += !ok;
        printf("%s scrubKnown \"%s\" -> \"%s\"%s\n", ok ? "ok  " : "FAIL", c.in, got.c_str(), ok ? "" : (" (want \"" + std::string(c.want) + "\")").c_str());
    }
    return bad;
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
        std::string l = scrubName(str(s.localizedName)) + ": " + hz(w) + "x" + hz(h) + " pt, " + hz(w * scale) + "x" + hz(h * scale) +
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

// a saved value that is what meyra uses anyway. most settings have no registered default: missing reads as 0, no or
// "", so a preset that writes them all off is not a change. a few count as something else when missing, and some
// change things by being there at all: those are always listed
static bool atDefault(NSString *k, id o, NSDictionary *reg) {
    static NSDictionary *implied = @{@"genFloor": @12, @"rateSnap": @0.1, @"drawables": @3, @"sideDim": @0.7, @"sideBlur": @1, @"sideSmooth": @200,
                                     @"stretchCentre": @0.3, @"recMaxHeight": @1080, @"recKeepSeconds": @30};
    static NSSet *present = [NSSet setWithArray:@[@"avfOut", @"avfReapply", @"chain", @"drain", @"enhanceAhead", @"genSpinWait", @"holdMargin",
                                                  @"snapFrames", @"stageTimes", @"gameModeOff", @"replayJitterSeed"]];
    id def = reg[k];
    if (!def) {
        if ([present containsObject:k]) return false;
        def = implied[k];
    }
    if ([o isKindOfClass:NSNumber.class]) { // a float saved as 0.6f is not equal to the double 0.6
        if (def && ![def isKindOfClass:NSNumber.class]) return false;
        double v = [o doubleValue], dv = def ? [def doubleValue] : 0;
        return fabs(v - dv) <= 1e-5 * fmax(1, fabs(dv));
    }
    if ([o isKindOfClass:NSString.class]) return def ? [o isEqual:def] : [o length] == 0;
    return def && [o isEqual:def];
}

// one entry of a per-source dictionary: its id as far as it may be shown, and the short hash that tells two apart
static std::string entryLabel(const std::string &key, const std::string &id) {
    std::string k = shortId(id);
    return key + "[" + (k.empty() ? "" : k + " ") + idHash(id) + "]";
}

int settingsTest() {
    int bad = 0;
    auto check = [&](const char *what, bool ok) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); bad += !ok; };
    NSDictionary *reg = @{@"sharpen": @0.6, @"deband": @YES, @"gameMode": @YES};
    check("settings: sharpen saved as a float 0.6 is the default", atDefault(@"sharpen", @(0.6f), reg));
    check("settings: deband off is a change", !atDefault(@"deband", @NO, reg));
    check("settings: genShift off with no registered default is not a change", atDefault(@"genShift", @NO, reg));
    check("settings: rate 0 is not a change, rate 2 is", atDefault(@"rate", @0, reg) && !atDefault(@"rate", @2, reg));
    check("settings: rateSnap 0.1 is not a change, 0.2 is", atDefault(@"rateSnap", @(0.1f), reg) && !atDefault(@"rateSnap", @0.2, reg));
    check("settings: avfReapply off is listed (being there changes it)", !atDefault(@"avfReapply", @NO, reg));
    check("settings: drawables 3 is not a change", atDefault(@"drawables", @3, reg));
    check("settings: a dictionary is listed", !atDefault(@"formats", @{@"avf:x": @"1"}, reg));
    check("settings: two sources with the same short id get two labels",
          entryLabel("audioInputs", "avf:4F2B8D10-3A6C-4E97-B5D1-8C0E6A29F347") != entryLabel("audioInputs", "avf:5A3E9C21-7B40-4D8E-A1F6-3C9B0E7D2A15"));
    check("settings: a uvc source's label shows usb vendor:product", entryLabel("formats", "avf:0x3a9e40c345f2131").rfind("formats[avf usb 345f:2131 #", 0) == 0);
    return bad;
}

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
            if (skipKey(k) || atDefault(k, o, reg)) continue;
            if ([k isEqual:@"muteOutput"] || [k isEqual:@"frameLog"]) continue; // saved by 0.6.0, no effect since: command line only
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
                    v.push_back(entryLabel(key, str(sk)) + " = " + t);
                }
            }
            else if ([k isEqual:@"source"] && [o isKindOfClass:NSString.class]) v.push_back(key + " = " + shortId(str(o)));
            else if ([k isEqual:@"sourceName"] && [o isKindOfClass:NSString.class]) v.push_back(key + " = " + scrubName(str(o)));
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
