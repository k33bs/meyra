// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#include "nets.h"
#include "common.h"
#include <algorithm>
#include <atomic>
#include <memory>
#include <sstream>
#include <unistd.h>
#include <string>
#include <vector>

namespace nets {

// out = act(bias + conv(sum of src) + sum of add). features live four to a texture, so a layer of n features writes
// (n + 3) / 4 colour attachments in one pass
struct Layer {
    std::string id;
    int k = 1, nin = 1, n = 0, act = 0; // act: 0 none, 1 relu, 2 prelu
    std::vector<int> src, add;          // layer indices, -1 = the picture's luma
    std::vector<float> w, b, a;         // w as [out][in][ky][kx]
    int slot = 0;                       // which set of textures holds the result
    int groups() const { return (n + 3) / 4; }
};
struct Net {
    std::string name, err;
    std::vector<Layer> layers;
    int scale = 2;                      // 2: the last layer has 4 features, the four pixels of a 2x2 block. 1: it has one, same size out
    int base = 0;                       // added to the result: 0 nothing, 1 the source pixel's luma, 2 bilinear luma
    std::vector<int> slotGroups;        // textures per slot
    // the shaders exist twice, built when first asked for: [0] in float, [1] with the narrow layers in half (netHalf)
    std::atomic<int> state[2] = {{0}, {0}}; // 0 not built, 1 building, 2 ready, 3 failed
    std::vector<id<MTLRenderPipelineState>> pipes[2]; // one per layer, then depth to space. written before state turns 2
    std::string berr[2];                // why a build failed
    bool anyHalf = false;               // some layer is narrow enough for half to pay
};

static id<MTLDevice> gDev; // render thread, and the build it starts
// netHalf: layers up to this many features in and out do their sums in half. measured one run a frame: 1.2x at
// 8 features, 0.8-1.3x (1.04 in the middle) at 16, 1.25x at 24, 0.9x (slower) at 32. the last layer stays in float whatever its width: a net that
// puts out the picture itself needs finer steps near white than half has. hidden -netHalfMax for tests
static int gHalfMax = 24;
static auto &gNets = *new std::vector<std::unique_ptr<Net>>; // never freed: a build may still run when the app quits
// textures of the net in use, render thread only
static struct { int net = 0; size_t w = 0, h = 0; std::vector<std::vector<id<MTLTexture>>> t; id<MTLTexture> out; } gT;

static bool parse(const std::string &text, Net &net) {
    std::string clean;
    std::istringstream lines(text);
    for (std::string l; std::getline(lines, l);) {
        l = l.substr(0, l.find('#'));
        if (!l.compare(0, 5, "name ")) { net.name = l.substr(5); while (!net.name.empty() && isspace((unsigned char)net.name.back())) net.name.pop_back(); continue; }
        clean += l + "\n";
    }
    std::istringstream in(clean);
    std::string tok;
    auto fail = [&](const std::string &why) { net.err = why; return false; };
    auto find = [&](const std::string &id) { for (size_t i = 0; i < net.layers.size(); i++) if (net.layers[i].id == id) return (int)i; return id == "y" ? -1 : -2; };
    auto floats = [&](const char *tag, std::vector<float> &v, size_t n) {
        if (!(in >> tok) || tok != tag) return false;
        v.resize(n);
        for (float &f : v) { // by way of a double: reading a float refuses anything below FLT_MIN, which a trained net can hold
            double d;
            if (!(in >> d) || !(d >= -FLT_MAX && d <= FLT_MAX)) return false;
            f = (float)d;
        }
        return true;
    };
    int ver = 0;
    if (!(in >> tok >> ver) || tok != "meyra-net" || ver != 1) return fail("not a version 1 net file");
    bool done = false;
    while (in >> tok) {
        if (done) return fail("something after out");
        if (tok == "out") {
            std::string id, b;
            if (!(in >> id) || net.layers.empty() || id != net.layers.back().id || (net.layers.back().n != 4 && net.layers.back().n != 1)) return fail("out must name the last layer, with 4 features (2x) or 1 (same size)");
            net.scale = net.layers.back().n == 4 ? 2 : 1;
            if (in >> tok) {
                if (tok != "base" || !(in >> b)) return fail("after out: base none|nearest|bilinear");
                net.base = b == "nearest" ? 1 : b == "bilinear" ? 2 : b == "none" ? 0 : -1;
                if (net.base < 0) return fail("base " + b);
            }
            done = true;
            continue;
        }
        Layer L;
        std::string kind;
        if (tok != "layer" || !(in >> L.id >> kind) || kind != "conv") return fail("expected layer ID conv, got " + tok);
        if (find(L.id) != -2) return fail("layer " + L.id + " twice");
        for (int i = 0; i < 5 && in >> tok; i++) { // k= in= out= [add=] act=, act last
            std::string key = tok.substr(0, tok.find('=')), val = tok.find('=') == std::string::npos ? "" : tok.substr(tok.find('=') + 1);
            if (key == "k") L.k = atoi(val.c_str());
            else if (key == "out") L.n = atoi(val.c_str());
            else if (key == "in" || key == "add") {
                std::istringstream ids(val);
                for (std::string id; std::getline(ids, id, '+');) {
                    int at = find(id);
                    if (at == -2) return fail("layer " + L.id + ": unknown " + id);
                    (key == "in" ? L.src : L.add).push_back(at);
                }
            } else if (key == "act") { L.act = val == "relu" ? 1 : val == "prelu" ? 2 : val == "none" ? 0 : -1; break; }
            else return fail("layer " + L.id + ": " + tok);
        }
        if (L.act < 0 || L.src.empty() || L.n < 1 || L.n > 32 || L.k < 1 || L.k > 7 || !(L.k & 1)) return fail("layer " + L.id + ": bad k, out, in or act");
        auto feat = [&](int i) { return i < 0 ? 1 : net.layers[i].n; };
        L.nin = feat(L.src[0]);
        for (int s : L.src) if (feat(s) != L.nin || (s < 0 && L.src.size() > 1)) return fail("layer " + L.id + ": inputs do not match");
        for (int s : L.add) if (s < 0 || feat(s) != L.n) return fail("layer " + L.id + ": add does not match");
        if (!floats("w", L.w, (size_t)L.n * L.nin * L.k * L.k) || !floats("b", L.b, L.n) || (L.act == 2 && !floats("a", L.a, L.n))) return fail("layer " + L.id + ": weights");
        net.layers.push_back(L);
    }
    if (!done) return fail("no out line");
    for (size_t i = 0; i + 1 < net.layers.size(); i++) net.anyHalf |= std::max(net.layers[i].n, net.layers[i].nin) <= gHalfMax;
    // a layer's textures are free again once the last layer that reads them has run
    size_t n = net.layers.size();
    std::vector<int> last(n, 0), owner; // owner: which layer holds each slot
    for (size_t i = 0; i < n; i++) for (auto *v : {&net.layers[i].src, &net.layers[i].add}) for (int s : *v) if (s >= 0) last[s] = (int)i;
    last[n - 1] = (int)n;
    for (size_t i = 0; i < n; i++) {
        int slot = -1;
        for (size_t s = 0; s < owner.size() && slot < 0; s++) if (last[owner[s]] < (int)i) slot = (int)s;
        if (slot < 0) { slot = (int)owner.size(); owner.push_back(0); net.slotGroups.push_back(0); }
        owner[slot] = (int)i;
        net.layers[i].slot = slot;
        net.slotGroups[slot] = std::max(net.slotGroups[slot], net.layers[i].groups());
    }
    return true;
}

// metal source for one net: a fragment function per layer and one pair for depth to space. weights go in as
// constants. every function is its own library (head + the function), so they compile side by side
static const char *const kHead =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "vertex V vs(uint vid [[vertex_id]]) { float2 p = float2(vid & 1, vid >> 1); V o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o; }\n"
    "constant float3 lw = float3(0.2126, 0.7152, 0.0722);\n";
static bool halfLayer(const Net &net, size_t li) { return li + 1 < net.layers.size() && std::max(net.layers[li].n, net.layers[li].nin) <= gHalfMax; }
// half: the whole layer in half, maps read as half, sums and weights half. never half products into float sums,
// that was 4x slower than either. the picture's luma is still worked out in float, one conversion per tap
static std::string layerSource(const Net &net, size_t li, bool half) {
    std::ostringstream o;
    o.precision(9);
    const char *T = half ? "half" : "float", *Z = half ? "0.0h" : "0.0";
    {
        const Layer &L = net.layers[li];
        int og = L.groups(), ig = (L.nin + 3) / 4, h = L.k / 2;
        bool luma = L.src[0] < 0;
        o << "struct O" << li << " {";
        for (int g = 0; g < og; g++) o << " " << T << "4 c" << g << " [[color(" << g << ")]];";
        o << " };\nfragment O" << li << " f" << li << "(V in [[stage_in]]";
        int nt = 0; // textures in the order run() binds them: every src layer's groups, then every add layer's
        for (size_t s = 0; s < L.src.size(); s++) for (int g = 0; g < ig; g++, nt++) o << ", texture2d<" << (luma ? "float" : T) << "> t" << nt << " [[texture(" << nt << ")]]";
        for (size_t s = 0; s < L.add.size(); s++) for (int g = 0; g < og; g++, nt++) o << ", texture2d<" << T << "> t" << nt << " [[texture(" << nt << ")]]";
        o << ") {\n  constexpr sampler s(filter::nearest, address::clamp_to_edge);\n";
        for (int g = 0; g < og; g++) {
            o << "  " << T << "4 r" << g << " = " << T << "4(";
            for (int r = 0; r < 4; r++) o << (r ? ", " : "") << (4 * g + r < L.n ? L.b[4 * g + r] : 0);
            o << ");\n";
        }
        o << "  " << T << (luma ? " x;\n" : "4 x;\n");
        auto W = [&](int out, int in, int ky, int kx) { return out < L.n && in < L.nin ? L.w[((size_t)(out * L.nin + in) * L.k + ky) * L.k + kx] : 0.0f; };
        for (int ky = 0; ky < L.k; ky++) for (int kx = 0; kx < L.k; kx++) for (int g = 0; g < ig; g++) {
            o << "  x = " << (luma && half ? "half(" : "");
            for (size_t s = 0; s < L.src.size(); s++) {
                o << (s ? " + " : "") << (luma ? "dot(" : "") << "t" << s * ig + g << ".sample(s, in.uv, int2(" << kx - h << ", " << ky - h << "))" << (luma ? ".rgb, lw)" : "");
            }
            o << (luma && half ? ");\n" : ";\n");
            for (int q = 0; q < og; q++) {
                o << "  r" << q << " += ";
                if (luma) {
                    o << T << "4(";
                    for (int r = 0; r < 4; r++) o << (r ? ", " : "") << W(4 * q + r, 0, ky, kx);
                    o << ")";
                } else {
                    o << T << "4x4(";
                    for (int c = 0; c < 4; c++) {
                        o << (c ? ", " : "") << T << "4(";
                        for (int r = 0; r < 4; r++) o << (r ? ", " : "") << W(4 * q + r, 4 * g + c, ky, kx);
                        o << ")";
                    }
                    o << ")";
                }
                o << " * x;\n";
            }
        }
        int at = (int)L.src.size() * ig;
        for (size_t s = 0; s < L.add.size(); s++) for (int g = 0; g < og; g++, at++) o << "  r" << g << " += t" << at << ".sample(s, in.uv);\n";
        for (int g = 0; g < og && L.act; g++) {
            o << "  r" << g << " = max(r" << g << ", " << Z << ")";
            if (L.act == 2) {
                o << " + " << T << "4(";
                for (int r = 0; r < 4; r++) o << (r ? ", " : "") << (4 * g + r < L.n ? L.a[4 * g + r] : 0);
                o << ") * min(r" << g << ", " << Z << ")";
            }
            o << ";\n";
        }
        o << "  O" << li << " o;";
        for (int g = 0; g < og; g++) o << " o.c" << g << " = r" << g << ";";
        o << "\n  return o;\n}\n";
    }
    return kHead + o.str();
}
static std::string outSource(const Net &net) {
    std::ostringstream o;
    // depth to space: the four features are the four pixels of a 2x2 block (a same-size net has the one). colour
    // comes from the picture, scaled bilinear for 2x, with its luma swapped for the net's
    o << "fragment float4 fout(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> n [[texture(1)]]) {\n"
         "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
         "  uint2 p = uint2(in.pos.xy);\n"
      << (net.scale == 2 ? "  float4 q = n.read(p >> 1);\n  float v = q[(p.y & 1) * 2 + (p.x & 1)];\n" : "  float v = n.read(p).x;\n")
      << "  float3 c = t.sample(s, in.uv).rgb;\n"
         "  float yb = dot(c, lw);\n"
      << (net.base == 1 && net.scale == 2 ? "  v += dot(t.read(p >> 1).rgb, lw);\n" : net.base ? "  v += yb;\n" : "")
      << "  return float4(saturate(c + (saturate(v) - yb)), 1);\n}\n";
    // the same, handing back what the net added and the luma it was given instead of the finished picture
    // (enhanceReal, enhanceHold: renderer.mm keeps that per real frame)
    o << "fragment float4 fres(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> n [[texture(1)]]) {\n"
         "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
         "  uint2 p = uint2(in.pos.xy);\n"
      << (net.scale == 2 ? "  float4 q = n.read(p >> 1);\n  float v = q[(p.y & 1) * 2 + (p.x & 1)];\n" : "  float v = n.read(p).x;\n")
      << "  float yb = dot(t.sample(s, in.uv).rgb, lw);\n"
      << (net.base == 1 && net.scale == 2 ? "  v += dot(t.read(p >> 1).rgb, lw);\n" : net.base ? "  v += yb;\n" : "")
      << "  return float4(saturate(v) - yb, yb, 0, 1);\n}\n";
    return kHead + o.str();
}

// compiled pipelines are kept per net in ~/Library/Caches/<bundle id>/nets, named by a hash of everything that goes
// into them: the generated source (so the net file, the precision, this generator), the gpu and the os build.
// that is the backend half of a build, what metal's own cache keeps too, but ours and not purged with it. measured
// it buys little once the layers compile side by side (12x32 with metal's cache gone: about 0.7 s with or without,
// the front end is what is left), and nothing is lost when the file is missing, broken or stale: a normal build
static NSString *archivePath(const std::vector<std::string> &src) {
    uint64_t h = 1469598103934665603ull; // fnv-1a
    auto mix = [&](const char *p, size_t n) { for (size_t i = 0; i < n; i++) { h ^= (uint8_t)p[i]; h *= 1099511628211ull; } h ^= 0xff; h *= 1099511628211ull; };
    for (auto &t : src) mix(t.data(), t.size());
    for (NSString *t in @[gDev.name ?: @"", NSProcessInfo.processInfo.operatingSystemVersionString ?: @""]) mix(t.UTF8String, strlen(t.UTF8String));
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"meyra"] stringByAppendingPathComponent:@"nets"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.metalarchive", h]];
}

static void build(Net *net, int v) {
    double t = nowSec();
    size_t n = net->layers.size(), np = n + 2; // the layers, the picture (fout), what was added (fres)
    std::vector<std::string> src(n + 1), errs(np);
    for (size_t i = 0; i < n; i++) src[i] = layerSource(*net, i, v && halfLayer(*net, i));
    src[n] = outSource(*net);
    std::vector<id<MTLLibrary>> libs(n + 1);
    auto *srcp = &src, *errp = &errs;
    auto *libp = &libs;
    dispatch_apply(n + 1, DISPATCH_APPLY_AUTO, ^(size_t i) {
        NSError *e = nil;
        (*libp)[i] = [gDev newLibraryWithSource:@((*srcp)[i].c_str()) options:nil error:&e];
        if (!(*libp)[i]) (*errp)[i] = std::string("shader: ") + (e.localizedDescription.UTF8String ?: "?");
    });
    std::string err;
    for (size_t i = 0; i <= n; i++) if (!libs[i] && err.empty()) err = errs[i];
    // the archive of an earlier build. unreadable, or from another os or gpu: metal refuses it or misses, and the
    // pipelines that did not come out of it are built the long way and a new archive is written
    NSString *path = err.empty() ? archivePath(src) : nil;
    id<MTLBinaryArchive> arc = nil;
    bool had = path && [NSFileManager.defaultManager fileExistsAtPath:path];
    if (had) {
        MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
        ad.url = [NSURL fileURLWithPath:path];
        arc = [gDev newBinaryArchiveWithDescriptor:ad error:nil];
    }
    std::vector<MTLRenderPipelineDescriptor *> pds(np);
    for (size_t i = 0; i < np && err.empty(); i++) {
        bool last = i >= n, res = i > n;
        int groups = last ? 1 : net->layers[i].groups();
        MTLRenderPipelineDescriptor *pd = pds[i] = [MTLRenderPipelineDescriptor new];
        id<MTLLibrary> lib = libs[last ? n : i];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        for (int g = 0; g < 8; g++) pd.colorAttachments[g].pixelFormat = g >= groups ? MTLPixelFormatInvalid : res ? MTLPixelFormatRG16Float : last ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA16Float;
        pd.fragmentFunction = [lib newFunctionWithName:res ? @"fres" : last ? @"fout" : [NSString stringWithFormat:@"f%zu", i]];
    }
    std::vector<id<MTLRenderPipelineState>> pipes(np);
    std::atomic<int> missed{0}, *missp = &missed;
    auto *pdp = &pds;
    auto *pp = &pipes;
    if (err.empty()) dispatch_apply(np, DISPATCH_APPLY_AUTO, ^(size_t i) {
        NSError *e = nil;
        MTLRenderPipelineDescriptor *pd = (*pdp)[i];
        if (arc) {
            pd.binaryArchives = @[arc];
            (*pp)[i] = [gDev newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
            pd.binaryArchives = nil;
            if ((*pp)[i]) return;
            ++*missp;
        }
        (*pp)[i] = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!(*pp)[i]) (*errp)[i] = std::string("pipeline: ") + (e.localizedDescription.UTF8String ?: "?");
    });
    for (size_t i = 0; i < np; i++) if (err.empty() && !pipes[i]) err = errs[i];
    if (err.empty()) {
        net->pipes[v] = pipes;
        logLine("enhance: %s ready, %zu passes, built in %.0f ms (%s%s)", net->name.c_str(), np - 1, (nowSec() - t) * 1000,
                !path ? "no cache folder" : !arc ? (had ? "kept pipelines unreadable" : "no kept pipelines") : missed ? "kept pipelines stale" : "from kept pipelines", v ? ", half" : "");
    } else {
        net->berr[v] = err;
        logLine("enhance: %s cannot run: %s", net->name.c_str(), err.c_str());
    }
    net->state[v] = err.empty() ? 2 : 3;
    // keep them for next time. after the net is usable: adding compiles nothing new (metal's own cache has them from
    // a moment ago) but writing takes a while. a temporary file first, so a half written one never has the name
    if (err.empty() && path && (!arc || missed)) {
        double t1 = nowSec();
        id<MTLBinaryArchive> fresh = [gDev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
        bool ok = fresh != nil;
        for (size_t i = 0; i < np && ok; i++) ok = [fresh addRenderPipelineFunctionsWithDescriptor:pds[i] error:nil];
        NSString *tmp = [path stringByAppendingFormat:@".%d.tmp", getpid()];
        ok = ok && [fresh serializeToURL:[NSURL fileURLWithPath:tmp] error:nil];
        if (ok) ok = rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
        if (!ok) unlink(tmp.fileSystemRepresentation);
        logLine("enhance: %s pipelines %s (%.0f ms)", net->name.c_str(), ok ? "kept for next time" : "could not be kept", (nowSec() - t1) * 1000);
    }
}

void load(NSString *dir) {
    if (int m = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"netHalfMax"]) gHalfMax = m;
    NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *f in files) {
        if (![f.pathExtension isEqual:@"net"]) continue;
        NSString *text = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        auto net = std::make_unique<Net>();
        net->name = f.stringByDeletingPathExtension.UTF8String;
        if (!text || !parse(text.UTF8String, *net)) { // listed all the same, so the numbers of the others do not move
            if (net->err.empty()) net->err = "unreadable";
            net->state[0] = net->state[1] = 3;
            logLine("enhance: %s cannot be used: %s", f.UTF8String, net->err.c_str());
        } else if (std::any_of(gNets.begin(), gNets.end(), [&](auto &o) { return o->name == net->name; })) {
            logLine("enhance: %s left out, there is a net with that name already", f.UTF8String); // shipped and in the user's folder too
            continue;
        } else {
            size_t params = 0;
            for (auto &L : net->layers) params += L.w.size() + L.b.size() + L.a.size();
            logLine("enhance %zu: %s, %zu layers, %zu weights", gNets.size() + 1, net->name.c_str(), net->layers.size(), params);
        }
        gNets.push_back(std::move(net));
    }
}

int count() { return (int)gNets.size(); }
static int variant(const Net &net) { return gSet.netHalf && net.anyHalf ? 1 : 0; }
bool halfApplies(int n) { return n >= 1 && n <= count() && gNets[n - 1]->anyHalf; }
bool half(int n) { return n >= 1 && n <= count() && variant(*gNets[n - 1]) && gNets[n - 1]->state[1] == 2; }
int scale(int n) { return n >= 1 && n <= count() ? gNets[n - 1]->scale : 1; }
int passes(int n) { return n >= 1 && n <= count() ? (int)gNets[n - 1]->layers.size() + 1 : 0; }
const char *name(int n) { return n >= 1 && n <= count() ? gNets[n - 1]->name.c_str() : ""; }
const char *status(int n) {
    if (n < 1 || n > count()) return "";
    Net &net = *gNets[n - 1];
    int v = variant(net), s = net.state[v];
    if (v && s == 3) { v = 0; s = net.state[0]; }
    if (s != 2 && net.state[!v] == 2) return ""; // run() goes on with the other precision meanwhile
    return s == 1 ? "starting" : s == 3 ? (net.err.empty() ? net.berr[v] : net.err).c_str() : "";
}

void idle() { if (gT.net) { gT.t.clear(); gT.out = nil; gT.net = 0; } }

id<MTLTexture> run(id<MTLCommandBuffer> cb, int n, id<MTLTexture> src, id<MTLTexture> added) {
    if (n < 1 || n > count()) return nil;
    Net *net = gNets[n - 1].get();
    int st = 0, v = variant(*net);
    if (v && net->state[1] == 3) v = 0; // half would not build
    gDev = cb.device;
    if (net->state[v].compare_exchange_strong(st, 1)) // some seconds of compiling for the bigger nets: not on this thread
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ build(net, v); });
    if (net->state[v] != 2) { // netHalf just switched: the other precision's shaders do the work until these are built
        if (net->state[!v] != 2) return nil;
        v = !v;
    }
    size_t w = src.width, h = src.height;
    if (gT.net != n || gT.w != w || gT.h != h || !gT.out) {
        idle();
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        for (int g : net->slotGroups) {
            gT.t.emplace_back();
            for (int i = 0; i < g; i++) { id<MTLTexture> t = [gDev newTextureWithDescriptor:d]; if (!t) { gT.t.clear(); return nil; } gT.t.back().push_back(t); }
        }
        d.pixelFormat = MTLPixelFormatBGRA8Unorm; d.width = net->scale * w; d.height = net->scale * h;
        gT.out = [gDev newTextureWithDescriptor:d];
        if (!gT.out) { gT.t.clear(); return nil; }
        gT.net = n; gT.w = w; gT.h = h;
    }
    for (size_t i = 0; i <= net->layers.size(); i++) {
        bool last = i == net->layers.size();
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        int groups = last ? 1 : net->layers[i].groups();
        for (int g = 0; g < groups; g++) {
            rp.colorAttachments[g].texture = last ? (added ?: gT.out) : gT.t[net->layers[i].slot][g];
            rp.colorAttachments[g].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[g].storeAction = MTLStoreActionStore;
        }
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:net->pipes[v][last && added ? i + 1 : i]];
        int at = 0;
        if (last) {
            [e setFragmentTexture:src atIndex:0];
            [e setFragmentTexture:gT.t[net->layers.back().slot][0] atIndex:1];
        } else {
            const Layer &L = net->layers[i];
            for (int s : L.src) for (int g = 0; g < (L.nin + 3) / 4; g++) [e setFragmentTexture:s < 0 ? src : gT.t[net->layers[s].slot][g] atIndex:at++];
            for (int s : L.add) for (int g = 0; g < groups; g++) [e setFragmentTexture:gT.t[net->layers[s].slot][g] atIndex:at++];
        }
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [e endEncoding];
    }
    return added ?: gT.out;
}

}
