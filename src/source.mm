// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 k33bs
// additional terms under section 7 of the licence: see "licence" in README.md
#import <AVFoundation/AVFoundation.h>
#include "source.h"

// vendor drivers built into this binary. the system capture path below needs none of them
const std::vector<const Driver *> &drivers() {
    static const std::vector<const Driver *> d = {
#if MEYRA_DECKLINK
        &kDeckLinkDriver,
#endif
    };
    return d;
}

std::vector<SourceInfo> listSources(std::vector<std::string> *hints) {
    std::vector<SourceInfo> v;
    std::vector<std::string> vendors;
    for (auto d : drivers()) {
        bool found = false;
        auto l = d->list(found);
        for (auto &i : l) i.name += std::string(" (") + d->vendor + " driver)"; // the same device is listed again below
        v.insert(v.end(), l.begin(), l.end());
        if (found) vendors.push_back(d->vendor);
        else if (hints && d->missing) hints->push_back(d->missing);
    }
    auto avf = listAVF(vendors);
    v.insert(v.end(), avf.begin(), avf.end());
    return v;
}

std::unique_ptr<Source> makeSource(const std::string &id, const SourceOptions &o) {
    if (id.rfind("avf:", 0) == 0) return makeAVFSource(id, o);
    if (id.rfind("replay:", 0) == 0) return makeReplaySource(id.substr(7));
    for (auto d : drivers())
        if (id.rfind(std::string(d->prefix) + ":", 0) == 0) return d->make(id, o);
    return nullptr;
}

void watchDevices(std::function<void()> changed) {
    for (auto d : drivers()) if (d->watch) d->watch(changed);
    for (NSNotificationName n in @[AVCaptureDeviceWasConnectedNotification, AVCaptureDeviceWasDisconnectedNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) { changed(); }];
}
