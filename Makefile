PROJECT := minimail.xcodeproj
SCHEME  := minimail
DD      := .build/DerivedData
SPM     := .build/SourcePackages
RESULTS := .build/results
SIM_DEST ?= platform=iOS Simulator,name=iPhone 17
# Ad-hoc signing (no team needed) so simulator keychain access works in tests; NOSIGN name kept for call sites.
NOSIGN  := CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
XCB     := xcbeautify --renderer $(if $(GITHUB_ACTIONS),github-actions,terminal)
# A hung test (WebKit never calling back, an expectation that can never be met) must fail the test, not eat
# the whole job: 120 s per test, enforced by XCTest.
TIMEOUTS := -test-timeouts-enabled YES -default-test-execution-time-allowance 120
ARCHIVE := .build/minimail.xcarchive
EXPORT  := .build/export
ASC_KEY_ID     ?=
ASC_ISSUER_ID  ?=
ASC_KEY_PATH   ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8

.PHONY: core-test core-test-nohtml gen build test-app test-one lint format appicon fixtures-check \
        sims bump-build archive upload-testflight clean qa

core-test:                      # Linux or macOS, seconds
	cd Packages/MailCore && swift test
core-test-nohtml:               # fallback when SwiftSoup fails to build on Linux
	cd Packages/MailCore && MAILCORE_SKIP_HTML=1 swift test
gen:
	xcodegen generate
build: gen
	set -o pipefail && xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) $(NOSIGN) | $(XCB)
test-app: gen
	rm -rf $(RESULTS)/unit.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/unit.xcresult \
	  -only-testing:minimailTests $(TIMEOUTS) $(NOSIGN) | $(XCB)
	xcrun xcresulttool get test-results summary --path $(RESULTS)/unit.xcresult --compact
test-one: gen                   # make test-one T=minimailTests/OutboxTests/testInverseOpsCancel
	rm -rf $(RESULTS)/one.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/one.xcresult \
	  -only-testing:$(T) $(TIMEOUTS) $(NOSIGN) | $(XCB)
lint:
	swift format lint --strict --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
	! grep -rE "^import (UIKit|SwiftUI|GRDB|AppAuth|WebKit|Security|CoreFoundation)" Packages/MailCore/Sources
	! grep -rE "^import SwiftSoup" Packages/MailCore/Sources/MailCore
	! grep -rnE "Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)|\.tint\(\.(blue|indigo|green|red)\)" minimail/Features minimail/Web
appicon:                        # regenerates AppIcon.png from the three-dot mark
	python3 scripts/make-appicon.py
format:
	swift format --in-place --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
clean:
	rm -rf .build $(PROJECT)
fixtures-check:                 # Linux or macOS, no toolchain needed
	python3 scripts/check-fixtures.py --check-order

sims:
	xcrun simctl list devices available | grep -E "iPhone"

bump-build:                     # CURRENT_PROJECT_VERSION n -> n+1 in project.yml
	@n=$$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9][0-9]*\)".*/\1/p' project.yml | head -1); \
	 test -n "$$n" || { echo "CURRENT_PROJECT_VERSION not found in project.yml"; exit 1; }; \
	 next=$$(expr $$n + 1); \
	 sed -i.bak "s/CURRENT_PROJECT_VERSION: \"$$n\"/CURRENT_PROJECT_VERSION: \"$$next\"/" project.yml; \
	 rm -f project.yml.bak; \
	 echo "CURRENT_PROJECT_VERSION $$n -> $$next"

archive: gen
	@test -n "$(ASC_KEY_ID)" || { echo "set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (docs/plan/testflight-runbook.md)"; exit 1; }
	@! grep -q REPLACE Config/Signing.xcconfig Config/Google.xcconfig || { echo "Config/*.xcconfig still contains REPLACE placeholders"; exit 1; }
	rm -rf $(ARCHIVE)
	set -o pipefail && xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) \
	  -allowProvisioningUpdates \
	  -authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID "$(ASC_KEY_ID)" \
	  -authenticationKeyIssuerID "$(ASC_ISSUER_ID)" | $(XCB)

upload-testflight: archive
	rm -rf $(EXPORT)
	set -o pipefail && xcodebuild -exportArchive -archivePath $(ARCHIVE) \
	  -exportOptionsPlist ExportOptions.plist -exportPath $(EXPORT) \
	  -allowProvisioningUpdates \
	  -authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID "$(ASC_KEY_ID)" \
	  -authenticationKeyIssuerID "$(ASC_ISSUER_ID)" | $(XCB)
	@echo "uploaded — check App Store Connect > TestFlight > iOS builds"

# The automated QA gate.
qa: core-test fixtures-check lint test-app
