# Purser build entry points. `make build` needs no signing; `make build-signed` uses Config/Signing.local.xcconfig.
PROJECT := Purser.xcodeproj
SCHEME := Purser
DERIVED := build/DerivedData

.PHONY: generate test build build-signed check-endpoints clean

generate:
	xcodegen generate --spec project.yml

test:
	swift test --package-path Packages/PurserCore

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

build-signed: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

check-endpoints:
	python3 -I Tools/check-asc-endpoints.py

clean:
	rm -rf $(DERIVED) $(PROJECT)

# --- TestFlight (M5) ---------------------------------------------------------
TF_DIR      := build/testflight
TF_ARCHIVE  := $(TF_DIR)/Purser.xcarchive
TF_EXPORT   := $(TF_DIR)/export
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null)

.PHONY: require-clean require-signing archive testflight

require-clean:
	@git diff --quiet && git diff --cached --quiet || { echo "error: uncommitted changes; commit first so the build number maps to a commit"; exit 1; }

require-signing:
	@grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' Config/Signing.local.xcconfig 2>/dev/null || { echo "error: Config/Signing.local.xcconfig must set DEVELOPMENT_TEAM (copy Config/Signing.local.xcconfig.example)"; exit 1; }

archive: require-clean require-signing generate
	rm -rf $(TF_ARCHIVE)
	xcodebuild archive \
	  -project Purser.xcodeproj \
	  -scheme Purser \
	  -configuration Release \
	  -destination 'generic/platform=macOS' \
	  -archivePath $(TF_ARCHIVE) \
	  -allowProvisioningUpdates \
	  CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)
	@echo "Archived Purser build $(BUILD_NUMBER) from commit $$(git rev-parse --short HEAD) at $(TF_ARCHIVE)"

testflight: archive
	rm -rf $(TF_EXPORT)
	xcodebuild -exportArchive \
	  -archivePath $(TF_ARCHIVE) \
	  -exportOptionsPlist Config/ExportOptions.plist \
	  -exportPath $(TF_EXPORT) \
	  -allowProvisioningUpdates
	@echo "Uploaded Purser build $(BUILD_NUMBER) from commit $$(git rev-parse --short HEAD) to App Store Connect"

# --- Developer ID release (notarized DMG) --------------------------------------
# Needs a notarytool keychain profile: xcrun notarytool store-credentials $(NOTARY_PROFILE)
REL_DIR        := build/release
REL_ARCHIVE    := $(REL_DIR)/Purser.xcarchive
REL_EXPORT     := $(REL_DIR)/export
REL_APP        := $(REL_EXPORT)/Purser Pricing.app
REL_VERSION    := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
REL_DMG        := $(REL_DIR)/Purser-Pricing-$(REL_VERSION).dmg
NOTARY_PROFILE ?= purser-notary

.PHONY: release

release: require-clean require-signing generate
	rm -rf $(REL_DIR) && mkdir -p $(REL_DIR)
	xcodebuild archive \
	  -project Purser.xcodeproj \
	  -scheme Purser \
	  -configuration Release \
	  -destination 'generic/platform=macOS' \
	  -archivePath $(REL_ARCHIVE) \
	  -allowProvisioningUpdates \
	  CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)
	xcodebuild -exportArchive \
	  -archivePath $(REL_ARCHIVE) \
	  -exportOptionsPlist Config/ExportOptions-DeveloperID.plist \
	  -exportPath $(REL_EXPORT) \
	  -allowProvisioningUpdates
	ditto -c -k --keepParent "$(REL_APP)" $(REL_DIR)/app.zip
	xcrun notarytool submit $(REL_DIR)/app.zip --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple "$(REL_APP)"
	rm -rf $(REL_DIR)/dmg && mkdir $(REL_DIR)/dmg
	cp -R "$(REL_APP)" $(REL_DIR)/dmg/ && ln -s /Applications $(REL_DIR)/dmg/Applications
	hdiutil create -volname "Purser Pricing" -srcfolder $(REL_DIR)/dmg -ov -format UDZO $(REL_DMG)
	codesign --sign "Developer ID Application" --timestamp $(REL_DMG)
	xcrun notarytool submit $(REL_DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(REL_DMG)
	spctl -a -vv -t open --context context:primary-signature $(REL_DMG)
	@echo "Release $(REL_VERSION) build $(BUILD_NUMBER) from commit $$(git rev-parse --short HEAD): $(REL_DMG)"
