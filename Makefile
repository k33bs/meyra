# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 k33bs
#
# builds Meyra.app with the command line tools.
#   make            build $(OUT)/Meyra.app
#   make run        build and open it
#   make release    build, zip for a github release, print the sha-256 and write release notes with it
#   make clean      remove $(OUT)
# VERSION is the only place the version lives; it is stamped into Info.plist. OUT, BUNDLE_ID and SIGN can be
# overridden, e.g. make SIGN="Developer ID Application: ..." for a distributable build, or make OUT=/tmp/x for a
# second build next to one that is running.

VERSION   = 0.1.0
BUILD     = 1
BUNDLE_ID = io.github.k33bs.meyra
MIN_MACOS = 14.0
SIGN      = -
OUT       = build

APP  = $(OUT)/Meyra.app
BIN  = $(APP)/Contents/MacOS/Meyra
# vendor drivers are optional: DECKLINK=0 builds without blackmagic's sdk, every device then uses system capture
DECKLINK ?= 1
SRC  = $(filter-out $(if $(filter 0,$(DECKLINK)),src/source_decklink.mm),$(wildcard src/*.mm))
OBJ  = $(patsubst src/%.mm,$(OUT)/obj/%.o,$(SRC)) $(if $(filter 0,$(DECKLINK)),,$(OUT)/obj/DeckLinkAPIDispatch.o)
HDR  = $(wildcard src/*.h)
SDK  = vendor/decklink
ZIP  = $(OUT)/Meyra-v$(VERSION).zip

CXX      = clang++
ARCH     = -arch arm64 -mmacosx-version-min=$(MIN_MACOS)
CXXFLAGS = $(ARCH) -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wunguarded-availability -isystem $(SDK) -Isrc -DMEYRA_DECKLINK=$(DECKLINK)
FW       = -framework Cocoa -framework Metal -framework MetalFX -framework QuartzCore -framework CoreVideo -framework CoreMedia \
           -framework VideoToolbox -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework ImageIO \
           -framework IOSurface -framework Security -weak_framework ScreenCaptureKit

all: $(APP)

$(OUT)/obj/%.o: src/%.mm $(HDR) Makefile
	@mkdir -p $(OUT)/obj
	$(CXX) $(CXXFLAGS) -c $< -o $@

# vendor code, built without our warnings
$(OUT)/obj/DeckLinkAPIDispatch.o: $(SDK)/DeckLinkAPIDispatch.cpp
	@mkdir -p $(OUT)/obj
	$(CXX) $(ARCH) -std=c++17 -O2 -I$(SDK) -c $< -o $@

$(BIN): $(OBJ)
	@mkdir -p $(APP)/Contents/MacOS
	$(CXX) $(ARCH) $(OBJ) $(FW) -o $@

$(APP): $(BIN) resources/Info.plist resources/Shaders.metal resources/Meyra.entitlements Makefile
	@mkdir -p $(APP)/Contents/Resources
	sed -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/' -e 's/@VERSION@/$(VERSION)/' -e 's/@BUILD@/$(BUILD)/' -e 's/@MIN_MACOS@/$(MIN_MACOS)/' \
		resources/Info.plist > $(APP)/Contents/Info.plist
	cp resources/Shaders.metal $(APP)/Contents/Resources/
	codesign --force --options runtime --entitlements resources/Meyra.entitlements --sign "$(SIGN)" $(APP)
	@touch $(APP)

run: $(APP)
	open $(APP)

# makes the files for a github release. it does not tag, create the release or upload anything
release: $(APP)
	@rm -f $(ZIP)
	ditto -c -k --keepParent --norsrc --noextattr --noqtn $(APP) $(ZIP)
	@sha=$$(shasum -a 256 $(ZIP) | cut -d' ' -f1); \
	printf '## Meyra v%s\n\n- (what changed)\n\n### SHA-256\n\n```\n%s  %s\n```\n' "$(VERSION)" "$$sha" "$(notdir $(ZIP))" > $(OUT)/release-notes.md; \
	echo "$(ZIP)"; echo "sha-256 $$sha"; echo "release notes: $(OUT)/release-notes.md (tag v$(VERSION), upload $(notdir $(ZIP)))"

clean:
	rm -rf $(OUT)

.PHONY: all run release clean
