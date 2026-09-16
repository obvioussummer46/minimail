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

.PHONY: core-test core-test-nohtml gen build test-app test-one lint format clean qa

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
format:
	swift format --in-place --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
clean:
	rm -rf .build $(PROJECT)
# The automated QA gate. `fixtures-check` is intentionally omitted until the MailCore fixture catalog exists
# (modules 02/03 inlined their fixtures); see docs/plan/spec/14-qa.md.
qa: core-test lint test-app
