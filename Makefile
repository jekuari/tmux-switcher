# tmux-switcher build tooling
#
# See scripts/make-cert.sh for why signing identity stability matters:
# ad-hoc signing (`codesign -s -`) rotates the app's identity on every
# rebuild, silently revoking its Accessibility (TCC) grant. The
# "tmux-switcher-dev" self-signed identity gives a stable designated
# requirement so the grant survives rebuilds.

APP_NAME      := TmuxSwitcher
BUNDLE_ID     := com.rferegrino.tmux-switcher
SIGN_IDENTITY := tmux-switcher-dev
INSTALL_DIR   := /Applications
BUILD_DIR     := .build/release
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: help build test cert bundle sign install run demo logs hooks clean

.DEFAULT_GOAL := help

help:
	@echo "tmux-switcher — available targets:"
	@echo "  make build    - swift build -c release"
	@echo "  make test     - swift test"
	@echo "  make cert     - create/verify the tmux-switcher-dev signing identity"
	@echo "  make bundle   - assemble $(APP_BUNDLE)"
	@echo "  make sign     - codesign the app bundle with a stable identity"
	@echo "  make install  - sign, then install to $(INSTALL_DIR)"
	@echo "  make run      - install, then launch the app"
	@echo "  make demo     - run the visual harness (swift run $(APP_NAME) --demo)"
	@echo "  make logs     - stream this app's unified logs"
	@echo "  make hooks    - print the optional tmux hook snippet"
	@echo "  make clean    - remove .build"

build:
	swift build -c release

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

bundle: build
	@echo "==> Assembling $(APP_BUNDLE)"
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
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
	codesign --force --deep --options runtime --sign "$(SIGN_IDENTITY)" --identifier $(BUNDLE_ID) "$(APP_BUNDLE)"
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
	rm -rf .build
