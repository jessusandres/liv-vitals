# Makefile for LivVitals (macOS Swift App)

XCODE_APP ?= /Applications/Xcode.app
DEVELOPER_DIR ?= $(XCODE_APP)/Contents/Developer
export DEVELOPER_DIR

PROJECT = LivVitals.xcodeproj
SCHEME = LivVitals
CONFIGURATION = Release
CORE_PACKAGE = LivCore
BUILD_DIR = ./build
APP_NAME = LivVitals.app
BUILT_APP = $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/$(APP_NAME)
INSTALL_DIR = /Applications
SNAPSHOT_DIR = $(BUILD_DIR)/snapshots
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ICONSET_DIR = LivVitals/Assets.xcassets/AppIcon.appiconset

.PHONY: all setup install-xcode accept-xcode-license ensure-xcode-license check-xcode check-xcode-installation build test test-app verify icon snapshots install run clean help strings check-strings perf

all: build

## setup: Checks Xcode and its licence before building
setup: check-xcode

## install-xcode: Opens the official Xcode page in the App Store
install-xcode:
	@if [ -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" ]; then \
		echo "==> Xcode is already available at $(DEVELOPER_DIR)."; \
	else \
		echo "==> Xcode is required to build this macOS app."; \
		echo "==> Opening its official App Store page..."; \
		open "macappstore://itunes.apple.com/app/id497799835"; \
		echo "==> Install the full Xcode app, then run: make setup"; \
		exit 1; \
	fi

## accept-xcode-license: Explicitly accepts the Xcode and Apple SDK licence
accept-xcode-license: check-xcode-installation
	@echo "==> Accepting the Xcode and Apple SDK licence..."
	@sudo xcodebuild -license accept
	@echo "==> Xcode licence accepted."

## ensure-xcode-license: Checks the licence and asks for sudo only when acceptance is needed
ensure-xcode-license: check-xcode-installation
	@if xcodebuild -license check >/dev/null 2>&1; then \
		echo "==> Xcode and Apple SDK licence already accepted."; \
	else \
		echo "==> Xcode and Apple SDK licence needs acceptance."; \
		echo "==> sudo will request your password before accepting it."; \
		sudo xcodebuild -license accept; \
		echo "==> Xcode licence accepted."; \
	fi

## check-xcode: Fails early with actionable Xcode and licence instructions
check-xcode: check-xcode-installation
	@if ! xcodebuild -license check >/dev/null 2>&1; then \
		echo "error: The Xcode and Apple SDK licence has not been accepted." >&2; \
		echo "Review it, then explicitly accept it with: make accept-xcode-license" >&2; \
		echo "Then run 'make install' again." >&2; \
		exit 1; \
	fi

check-xcode-installation:
	@if [ ! -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" ]; then \
		echo "error: Full Xcode was not found at $(DEVELOPER_DIR)." >&2; \
		echo "Run 'make install-xcode', finish the App Store installation, then retry." >&2; \
		echo "The smaller Command Line Tools package is not enough for this Xcode project." >&2; \
		exit 1; \
	fi

## build: Compiles the app in Release configuration, signed with the personal team
build: check-xcode
	@echo "==> Building $(APP_NAME) ($(CONFIGURATION))..."
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates build
	@echo "==> Build succeeded: $(BUILT_APP)"

## test: Runs the LivCore unit tests
test: check-xcode
	@echo "==> Running $(CORE_PACKAGE) tests..."
	swift test --package-path $(CORE_PACKAGE)

## test-app: Runs the app's unit tests (models with fake services)
test-app: check-xcode
	@echo "==> Running $(SCHEME) app tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates -destination 'platform=macOS'

## verify: Runs both test suites and then compiles the app
verify: test test-app build

## icon: Redraws the app icon and regenerates every macOS size in the asset catalog
icon: check-xcode
	@echo "==> Drawing app icon..."
	@mkdir -p $(ICONSET_DIR)
	swift scripts/make-app-icon.swift $(ICONSET_DIR)/icon_512x512@2x.png
	@for size in 16 32 128 256 512; do \
		sips -z $$size $$size $(ICONSET_DIR)/icon_512x512@2x.png --out $(ICONSET_DIR)/icon_$${size}x$${size}.png >/dev/null; \
		double=$$((size * 2)); \
		if [ $$size -ne 512 ]; then \
			sips -z $$double $$double $(ICONSET_DIR)/icon_512x512@2x.png --out $(ICONSET_DIR)/icon_$${size}x$${size}@2x.png >/dev/null; \
		fi; \
	done
	@echo "==> Icon sizes written to $(ICONSET_DIR)"

## snapshots: Renders every module to PNG (light and dark) from a Debug build into build/snapshots
snapshots: check-xcode
	@echo "==> Building Debug app for snapshots..."
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates build -quiet
	@rm -rf $(SNAPSHOT_DIR)
	"$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME)/Contents/MacOS/LivVitals" -LivSnapshotDir "$(abspath $(SNAPSHOT_DIR))"
	@echo "==> Snapshots written to $(SNAPSHOT_DIR)"

## strings: Updates LivVitals/Localizable.xcstrings from a Debug build and lists stale strings
strings: check-xcode
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates build -quiet
	scripts/sync-strings.sh
	python3 scripts/catalog-plurals.py
	python3 scripts/check-strings.py

## check-strings: Fails on a stale or empty catalog entry, or a plural form that drops its number or specifiers
check-strings:
	python3 scripts/check-strings.py

## perf: Times the Cleanup, Smart Care, Space Lens and Uninstaller scans on this Mac (read-only)
perf:
	scripts/perf-probe.sh

## install: Compiles and installs the app to /Applications
install: ensure-xcode-license build
	@echo "==> Installing $(APP_NAME) to $(INSTALL_DIR)..."
	@osascript -e 'quit app id "dev.asger.LivVitals"' >/dev/null 2>&1 || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@cp -R "$(BUILT_APP)" "$(INSTALL_DIR)/"
	@$(LSREGISTER) -f "$(INSTALL_DIR)/$(APP_NAME)" >/dev/null 2>&1 || true
	@/usr/bin/pluginkit -a "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/LivVitalsWidgets.appex" >/dev/null 2>&1 || true
	@echo "==> $(APP_NAME) installed successfully in $(INSTALL_DIR)."

## run: Launches the app
run:
	@echo "==> Launching $(APP_NAME)..."
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
		open "$(INSTALL_DIR)/$(APP_NAME)"; \
	else \
		open "$(BUILT_APP)"; \
	fi

## clean: Removes build artifacts
clean: check-xcode
	@echo "==> Cleaning build directories..."
	@rm -rf $(BUILD_DIR) $(CORE_PACKAGE)/.build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean

## help: Shows available Makefile targets
help:
	@echo "Available commands:"
	@echo "  make setup    - Validate Xcode and its Apple SDK licence"
	@echo "  make install-xcode - Open the official Xcode App Store page"
	@echo "  make accept-xcode-license - Explicitly accept the Xcode licence"
	@echo "  make install  - Accept the licence if needed, compile, and install the app"
	@echo "  make build    - Compile the Release app bundle"
	@echo "  make test     - Run the LivCore unit tests"
	@echo "  make test-app - Run the app's unit tests"
	@echo "  make verify   - Run all tests and compile the app"
	@echo "  make icon     - Redraw the app icon in every macOS size"
	@echo "  make snapshots - Render every module to PNG in build/snapshots"
	@echo "  make strings  - Sync the String Catalog with the code"
	@echo "  make check-strings - Check the String Catalog for stale, empty or mismatched entries"
	@echo "  make perf     - Time the real scans (read-only)"
	@echo "  make run      - Launch the app"
	@echo "  make clean    - Remove build artifacts"
