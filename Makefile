# tmux-switcher build tooling
#
# See scripts/make-cert.sh for why signing identity stability matters:
# ad-hoc signing (`codesign -s -`) rotates the app's identity on every
# rebuild, silently revoking its Accessibility (TCC) grant. The
# "tmux-switcher-dev" self-signed identity gives a stable designated
# requirement so the grant survives rebuilds.

APP_NAME      := TmuxSwitcher
BUNDLE_ID     := com.rferegrino.tmux-switcher
SIGN_IDENTITY ?= tmux-switcher-dev
INSTALL_DIR   := /Applications
BUILD_DIR     := .build/release
DIST_DIR      ?= dist
APP_BUNDLE    := $(DIST_DIR)/$(APP_NAME).app

# Version stamped into the bundle. Defaults to whatever Resources/Info.plist
# already says, so local builds are unchanged; the release pipeline overrides
# it from the git tag (VERSION=1.2.3 BUILD_NUMBER=<run number>).
VERSION       ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD_NUMBER  ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)

DMG           := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg

# Universal (arm64 + x86_64) builds are off by default: local development only
# ever runs on this machine, and building both slices doubles compile time.
# The release pipeline turns it on with UNIVERSAL=1.
#
# Note the use of --triple rather than SwiftPM's --arch. `swift build --arch
# arm64 --arch x86_64` routes through xcbuild, which only ships with full
# Xcode, so it fails outright on a CommandLineTools-only toolchain. Building
# each triple separately uses the native SwiftPM build system and works on
# both, then lipo stitches the slices together.
UNIVERSAL     ?= 0
MACOS_MIN     := 14.0    # keep in sync with `platforms:` in Package.swift
ARM64_TRIPLE  := arm64-apple-macosx$(MACOS_MIN)
X86_64_TRIPLE := x86_64-apple-macosx$(MACOS_MIN)
UNIVERSAL_BIN := .build/universal/$(APP_NAME)

ifeq ($(UNIVERSAL),1)
BUNDLE_DEPS   := build-universal
APP_BINARY    := $(UNIVERSAL_BIN)
else
BUNDLE_DEPS   := build
APP_BINARY    := $(BUILD_DIR)/$(APP_NAME)
endif

# A secure timestamp is mandatory for anything submitted to Apple's notary
# service, but it requires a round-trip to Apple's timestamp server on every
# signature -- pointless latency for a local self-signed build, and a hard
# failure when offline. Off by default; the release pipeline sets TIMESTAMP=1.
ifeq ($(TIMESTAMP),1)
CODESIGN_TIMESTAMP := --timestamp
else
CODESIGN_TIMESTAMP := --timestamp=none
endif

.PHONY: help build build-universal test cert icon bundle sign dmg install run demo logs hooks clean

.DEFAULT_GOAL := help

help:
	@echo "tmux-switcher — available targets:"
	@echo "  make build    - swift build -c release"
	@echo "  make build-universal - build arm64 + x86_64 and lipo them together"
	@echo "  make test     - swift test"
	@echo "  make cert     - create/verify the tmux-switcher-dev signing identity"
	@echo "  make icon     - regenerate Resources/AppIcon.icns"
	@echo "  make bundle   - assemble $(APP_BUNDLE)"
	@echo "  make sign     - codesign the app bundle with a stable identity"
	@echo "  make dmg      - package the ALREADY-SIGNED bundle as a .dmg"
	@echo "                  (for a one-shot local disk image: make sign dmg)"
	@echo "  make install  - sign, then install to $(INSTALL_DIR)"
	@echo "  make run      - install, then launch the app"
	@echo "  make demo     - run the visual harness (swift run $(APP_NAME) --demo)"
	@echo "  make logs     - stream this app's unified logs"
	@echo "  make hooks    - print the optional tmux hook snippet"
	@echo "  make clean    - remove .build and $(DIST_DIR)"

build:
	swift build -c release

build-universal:
	@echo "==> Building $(ARM64_TRIPLE)"
	swift build -c release --triple $(ARM64_TRIPLE)
	@echo "==> Building $(X86_64_TRIPLE)"
	swift build -c release --triple $(X86_64_TRIPLE)
	@echo "==> Merging slices into $(UNIVERSAL_BIN)"
	mkdir -p $(dir $(UNIVERSAL_BIN))
	lipo -create -output $(UNIVERSAL_BIN) \
		.build/arm64-apple-macosx/release/$(APP_NAME) \
		.build/x86_64-apple-macosx/release/$(APP_NAME)
	lipo -info $(UNIVERSAL_BIN)

# On a CommandLineTools-only toolchain (no full Xcode), SwiftPM does not
# wire up search paths for swift-testing even though it ships in
# CommandLineTools, so a bare `swift test` fails with "no such module
# 'Testing'". Framework and rpath flags fix compiling, but a runtime dyld
# failure remains unless the linker rpath ALSO includes the sibling usr/lib
# directory: Testing.framework itself links against lib_TestingInterop.dylib,
# which lives there, not inside the framework. Both -F (for the module) and
# both -rpath entries (for the two different runtime dependencies) are
# required together; a full Xcode toolchain has a different, already-wired
# layout and doesn't need any of this, hence the existence check + fallback.
CLT_DEV_DIR := $(shell xcode-select -p)/Library/Developer
CLT_TESTING_FRAMEWORKS := $(CLT_DEV_DIR)/Frameworks
CLT_TESTING_LIB := $(CLT_DEV_DIR)/usr/lib

test:
	@if [ -d "$(CLT_TESTING_FRAMEWORKS)" ]; then \
		echo "==> Using CommandLineTools swift-testing search paths"; \
		swift test \
			-Xswiftc -F -Xswiftc "$(CLT_TESTING_FRAMEWORKS)" \
			-Xlinker -F -Xlinker "$(CLT_TESTING_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(CLT_TESTING_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(CLT_TESTING_LIB)"; \
	else \
		swift test; \
	fi

cert:
	scripts/make-cert.sh

# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift. The .icns
# is committed, so this only needs running when the artwork itself changes.
icon:
	rm -rf $(DIST_DIR)/AppIcon.iconset
	mkdir -p $(DIST_DIR)
	swift scripts/make-icon.swift $(DIST_DIR)/AppIcon.iconset
	iconutil -c icns $(DIST_DIR)/AppIcon.iconset -o Resources/AppIcon.icns
	rm -rf $(DIST_DIR)/AppIcon.iconset
	@echo "==> Wrote Resources/AppIcon.icns"

bundle: $(BUNDLE_DEPS)
	@echo "==> Assembling $(APP_BUNDLE) (version $(VERSION), build $(BUILD_NUMBER))"
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(APP_BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	# Stamp the version into the COPY, never back into Resources/Info.plist:
	# the checked-in plist stays the single source of the default, and a
	# release build must not leave the working tree dirty.
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP_BUNDLE)/Contents/Info.plist"
	@echo "==> Bundle assembled at $(APP_BUNDLE)"

# NOTE: the identity check deliberately omits `-v` (valid/trusted only).
# codesign signs happily with an untrusted self-signed cert, and what actually
# matters here is that the designated requirement is anchored to the certificate
# instead of a per-build cdhash. Trust only affects Gatekeeper validation, which
# is irrelevant for a locally built background agent.
sign: bundle
	@if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$(SIGN_IDENTITY)\""; then \
		echo "!! Signing identity \"$(SIGN_IDENTITY)\" not found."; \
		echo "!! Run 'make cert' first to create a stable self-signed identity."; \
		exit 1; \
	fi
	codesign --force --deep --options runtime $(CODESIGN_TIMESTAMP) --sign "$(SIGN_IDENTITY)" --identifier $(BUNDLE_ID) "$(APP_BUNDLE)"
	@echo "==> Checking the signature is certificate-anchored, not ad-hoc..."
	@if codesign -dvvv "$(APP_BUNDLE)" 2>&1 | grep -q '^Signature=adhoc'; then \
		echo ""; \
		echo "!! SIGNATURE IS AD-HOC. Accessibility permission will be silently"; \
		echo "!! revoked on every single rebuild, because an ad-hoc designated"; \
		echo "!! requirement is just a cdhash that changes each build."; \
		echo "!! Signing did not actually use \"$(SIGN_IDENTITY)\"."; \
		exit 1; \
	fi
	@echo "==> Designated requirement:"
	@codesign -d --requirements - "$(APP_BUNDLE)" 2>&1 | grep designated || true
	codesign -dvvv "$(APP_BUNDLE)"

# Packages whatever is currently in $(APP_BUNDLE) -- it does NOT depend on
# `sign`, because the release pipeline has to notarize and staple the .app in
# between signing it and putting it in the image (a stapled ticket lets the app
# validate offline once it's dragged out of the .dmg). For a local one-shot
# image where none of that applies, chain them yourself: `make sign dmg`.
dmg:
	@test -d "$(APP_BUNDLE)" || { echo "!! $(APP_BUNDLE) does not exist. Run 'make sign' first."; exit 1; }
	@echo "==> Staging disk image contents"
	rm -rf "$(DIST_DIR)/dmg-stage" "$(DMG)"
	mkdir -p "$(DIST_DIR)/dmg-stage"
	# ditto, not cp -R: it is the copy that reliably preserves the extended
	# attributes and resource forks a signed+stapled bundle carries. cp -R
	# can drop them and silently invalidate the signature.
	ditto "$(APP_BUNDLE)" "$(DIST_DIR)/dmg-stage/$(APP_NAME).app"
	# The /Applications symlink is what makes the window a drag-and-drop target.
	ln -s /Applications "$(DIST_DIR)/dmg-stage/Applications"
	@echo "==> Creating $(DMG)"
	hdiutil create -volname "$(APP_NAME) $(VERSION)" \
		-srcfolder "$(DIST_DIR)/dmg-stage" -ov -format UDZO "$(DMG)"
	rm -rf "$(DIST_DIR)/dmg-stage"
	@echo "==> Disk image ready at $(DMG)"

install: sign
	@echo "==> Stopping any running instance..."
	pkill -x $(APP_NAME) || true
	@echo "==> Installing to $(INSTALL_DIR)..."
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> Installed $(INSTALL_DIR)/$(APP_NAME).app"
	@$(MAKE) --no-print-directory hooks

run: install
	open -a "$(INSTALL_DIR)/$(APP_NAME).app"

demo:
	swift run $(APP_NAME) --demo

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug

hooks:
	@echo ""
	@echo "------------------------------------------------------------------------------"
	@echo "Optional tmux hooks (tmux-switcher works fine without these; they only keep"
	@echo "its session-list cache warm by nudging it whenever sessions change)."
	@echo "Paste into your own tmux.conf — this Makefile will never write to it for you:"
	@echo "------------------------------------------------------------------------------"
	@echo ""
	@echo "set-hook -ga session-created \"run -b '/Applications/TmuxSwitcher.app/Contents/MacOS/TmuxSwitcher --notify sessions-changed'\""
	@echo "set-hook -ga session-closed  \"run -b '/Applications/TmuxSwitcher.app/Contents/MacOS/TmuxSwitcher --notify sessions-changed'\""
	@echo "set-hook -ga session-renamed \"run -b '/Applications/TmuxSwitcher.app/Contents/MacOS/TmuxSwitcher --notify sessions-changed'\""
	@echo ""
	@echo "Then reload tmux's config:"
	@echo ""
	@echo "tmux source-file ~/.config/tmux/tmux.conf"
	@echo ""
	@echo "------------------------------------------------------------------------------"
	@echo ""

clean:
	rm -rf .build $(DIST_DIR)
