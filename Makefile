PROJECT := Platine.xcodeproj
SCHEME  := Platine
DEST    := platform=macOS
BUILD   := build
APP     := $(BUILD)/Build/Products/Release/Platine.app

# Sign with a Developer ID when one is in the keychain, so macOS keeps the
# Automation permission across rebuilds. Ad-hoc otherwise.
SIGN_ID ?= Developer ID Application
TEAM_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep -m1 "$(SIGN_ID)" | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p')
SIGNED   = $(if $(TEAM_ID),PLATINE_CODE_SIGN_IDENTITY="$(SIGN_ID)" PLATINE_DEVELOPMENT_TEAM="$(TEAM_ID)" OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO,)

.PHONY: generate build test release install run snapshots clean

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DEST)' -derivedDataPath $(BUILD) -quiet build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath $(BUILD) -quiet test

release: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DEST)' -derivedDataPath $(BUILD) -quiet $(SIGNED) build

install: release
	-killall Platine 2>/dev/null; sleep 0.5
	rm -rf /Applications/Platine.app
	cp -R $(APP) /Applications/
	open /Applications/Platine.app

run: build
	open $(BUILD)/Build/Products/Debug/Platine.app

## Render every framing at four times of day into docs/ (offscreen, no desktop needed).
snapshots: release
	./scripts/snapshots.sh $(APP)

clean:
	rm -rf $(BUILD) $(PROJECT)
