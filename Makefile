PROJECT := minimail.xcodeproj
SCHEME  := minimail
DD      := .build/DerivedData
SPM     := .build/SourcePackages
RESULTS := .build/results
SIM_DEST ?= platform=iOS Simulator,name=iPhone 17
NOSIGN  := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
XCB     := xcbeautify --renderer $(if $(GITHUB_ACTIONS),github-actions,terminal)

.PHONY: core-test core-test-nohtml gen build test-app test-one lint format clean

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
	  -only-testing:minimailTests $(NOSIGN) | $(XCB)
	xcrun xcresulttool get test-results summary --path $(RESULTS)/unit.xcresult --compact
test-one: gen                   # make test-one T=minimailTests/OutboxTests/testInverseOpsCancel
	rm -rf $(RESULTS)/one.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/one.xcresult \
	  -only-testing:$(T) $(NOSIGN) | $(XCB)
lint:
	swift format lint --strict --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
	! grep -rE "^import (UIKit|SwiftUI|GRDB|AppAuth|WebKit|Security|CoreFoundation)" Packages/MailCore/Sources
	! grep -rE "^import SwiftSoup" Packages/MailCore/Sources/MailCore
	! grep -rnE "Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)|\.tint\(\.(blue|indigo|green|red)\)" minimail/Features minimail/Web
format:
	swift format --in-place --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
clean:
	rm -rf .build $(PROJECT)
