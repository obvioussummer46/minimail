# Tooling research: building, testing and shipping minimail from a CLI (no Xcode GUI)

Research date: 2026-09-11. Audience: the AI coding agent that will execute the plan headless
(Linux for editing, a macOS runner for building). Everything below is meant to be reproducible
from files + shell commands. Claims are cited inline; anything not confirmed against an official
source is tagged **UNVERIFIED**.

## 0. TL;DR (decisions)

| Topic | Decision | Why |
|---|---|---|
| Project generation | **XcodeGen 2.46.0**, `project.yml` committed, `*.xcodeproj` git-ignored | Plain YAML, no Swift manifest to compile, deterministic output, one binary from Homebrew. Tuist adds a mise-managed CLI + `Project.swift` + optional cloud; hand-written pbxproj is unmaintainable; SwiftPM alone cannot produce an iOS `.app` bundle (no Info.plist/entitlements/asset-catalog pipeline) so an `.xcodeproj` is unavoidable. |
| Xcode | **26.6 (17F113)** now; move to **27.0** once the GitHub `macos-26` image ships it as GA | 26.6 = Swift 6.3 + iOS 26.5 SDK, default on `macos-26` runners. 27 RC (Swift 6.4, iOS 27 SDK) landed 2026-09-09; iOS 27 ships 2026-09-14. |
| Deployment target | **iOS 17.0** (per PLAN.md) | All deps allow it (AppAuth 3.0 needs iOS 15+, GRDB 7 iOS 13+). Xcode 27 still supports iOS 15–27 targets. iOS 26 is on 79 % of all iPhones / 86 % of 4-year-old-or-newer devices (Apple, measured 2026-06-07), so 17 is conservative; raising to 18 or 26 later is a one-line change in `project.yml`. |
| Swift language mode | **`SWIFT_VERSION = 6`**, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` | These are the Xcode 26 new-project defaults; MainActor-by-default removes most Sendable/isolation errors in a UI app, and `@concurrent`/actors are opt-in for the sync engine. Escape hatch documented in §3.3. |
| Build/test | `xcodebuild` + `xcbeautify 3.2.1`, destination `platform=iOS Simulator,name=iPhone 17`, `CODE_SIGNING_ALLOWED=NO` | `iPhone 16` no longer exists in the iOS 26.4/26.5 simulator runtimes on the runners. |
| CI | GitHub Actions `runs-on: macos-26`, `maxim-lobanov/setup-xcode@v1` pinned to `'26.6'`, `actions/cache@v6` on `-clonedSourcePackagesDirPath` keyed by `project.yml` | ~10 min/run; 2,000 included minutes/month on Free for private repos, macOS bills at $0.062/min list. |
| Lint/format | `swift format` (bundled in the Xcode toolchain) + **SwiftLint 0.65.1** with a tiny rule set | Zero extra install for formatting; SwiftLint only for a few correctness rules. |
| Deployment | Owner joins the **Apple Developer Program ($99/yr)** → TestFlight; CLI upload via `xcodebuild -exportArchive … destination=upload` with an App Store Connect API key | Free "personal team" provisioning expires every **7 days**, max 3 apps/device, no TestFlight — unworkable for a daily-driver mail app. |
| UI/snapshot tests | XCTest unit tests (bulk) + **swift-snapshot-testing 1.19.4** for 2–3 view snapshots + **one** XCUITest smoke test | Snapshot tests run in the unit-test bundle on the simulator (fast); XCUITests are slow, keep one. |

---

## 1. Project generation

### 1.1 Options compared

| Option | Verdict | Notes |
|---|---|---|
| **XcodeGen** (`project.yml`) | **Recommended** | Latest 2.46.0 (2026-07-16) — "Added support for Swift package `traits`", targets now follow spec declaration order, XcodeProj 9.14.0 ([releases](https://github.com/yonaskolb/XcodeGen/releases), [atom feed date](https://github.com/yonaskolb/XcodeGen/releases.atom)). Spec supports `type: syncedFolder` for Xcode 16+ synchronized folders, remote packages with `exactVersion`, `info.properties` to synthesize Info.plist, `entitlements`, per-target `scheme` ([ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)). |
| Tuist | Not recommended here | Installed via `mise x tuist@latest -- tuist init` ([README](https://github.com/tuist/tuist)); needs a compiled `Project.swift` manifest, a mise-managed toolchain and pulls toward the Tuist cache/insights service. Overkill for one app + two test bundles. Latest version: **UNVERIFIED** (the GitHub releases page is dominated by sub-component tags; docs.tuist.dev is blocked from this sandbox). |
| Hand-written `.pbxproj` | No | Opaque IDs, merge-hostile, and an agent cannot validate edits without Xcode. |
| Swift Package as app | No | SwiftPM has no iOS app-bundle product type (Info.plist, entitlements, asset catalogs, signing); an `.xcodeproj` is required. **UNVERIFIED as a citation** — this is long-standing SwiftPM behaviour, not something I found a single doc page for. Use a local package for pure-Swift code instead (§7.4). |

### 1.2 Install

```sh
brew install xcodegen          # https://github.com/yonaskolb/XcodeGen#installing
# alternatives from the README:
#   mint install yonaskolb/xcodegen
#   git clone https://github.com/yonaskolb/XcodeGen.git && cd XcodeGen && make install
xcodegen --version             # expect 2.46.0
```

Usage: `xcodegen generate` "searches for `project.yml` in the current directory"; `--spec <path>` and `--project <dir>` override ([README](https://github.com/yonaskolb/XcodeGen#usage)).

### 1.3 Dependency version pins (verified 2026-09-11)

| Package | Tag | Date (GitHub atom `<updated>`) | Product to link | Requirements |
|---|---|---|---|---|
| AppAuth-iOS | `3.0.0` | 2026-08-24 | `AppAuth` (also `AppAuthCore`, `AppAuthTV`) | "Raised minimum deployment targets to iOS 15.0, macOS 12.0, tvOS 15.0 and watchOS 9.0" (for Xcode 27 compatibility); `swift-tools-version:5.7`; `resumeExternalUserAgentFlowWithURL:error:` now required in `OIDExternalUserAgentSession` ([release](https://github.com/openid/AppAuth-iOS/releases/tag/3.0.0), [Package.swift](https://raw.githubusercontent.com/openid/AppAuth-iOS/master/Package.swift)) |
| GRDB.swift | `v7.11.1` | release page 2026-06-18 (atom 2026-06-30) | `GRDB` (or `GRDB-dynamic`) | "iOS 13.0+ … Swift 6.1+ / Xcode 16.3+" ([README](https://github.com/groue/GRDB.swift/blob/master/README.md)) |
| swift-snapshot-testing | `1.19.4` | 2026-07-28 | `SnapshotTesting` (test target only) | Supports XCTest and Swift Testing ([README](https://github.com/pointfreeco/swift-snapshot-testing)) |

XcodeGen `exactVersion` takes the bare semver (`7.11.1`), not the `v`-prefixed tag; SwiftPM matches both.

### 1.4 `project.yml` (complete)

Save as `/home/user/minimail/project.yml`. Directory layout it expects:

```
minimail/                 # app sources (PLAN.md architecture folders live inside)
  Info.plist              # GENERATED by xcodegen from info.properties – do not hand-edit
  minimail.entitlements   # generated from entitlements.properties
minimailTests/            # unit + snapshot tests
minimailUITests/          # one XCUITest smoke test
Config/
  Signing.xcconfig        # DEVELOPMENT_TEAM=XXXXXXXXXX  (owner fills in; not secret)
```

```yaml
# project.yml — XcodeGen 2.46.0 spec
# Docs: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
name: minimail

options:
  minimumXcodeGenVersion: 2.46.0
  bundleIdPrefix: com
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "26.6"
  createIntermediateGroups: true
  generateEmptyDirectories: true
  developmentLanguage: en

configs:
  Debug: debug
  Release: release

# Owner-specific signing lives in an xcconfig so project.yml stays generic.
configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig

settings:
  base:
    # --- Swift language / concurrency (see §3.3) ---
    SWIFT_VERSION: "6"
    SWIFT_STRICT_CONCURRENCY: complete
    SWIFT_APPROACHABLE_CONCURRENCY: YES
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    SWIFT_TREAT_WARNINGS_AS_ERRORS: NO
    # --- platform ---
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    TARGETED_DEVICE_FAMILY: "1"            # 1 = iPhone only
    SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"
    # --- versioning ---
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    # --- signing (simulator builds override with CODE_SIGNING_ALLOWED=NO on the CLI) ---
    CODE_SIGN_STYLE: Automatic
    # --- hygiene ---
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    SWIFT_EMIT_LOC_STRINGS: YES
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
  configs:
    debug:
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
      ONLY_ACTIVE_ARCH: YES
    release:
      SWIFT_COMPILATION_MODE: wholemodule

packages:
  AppAuth:
    url: https://github.com/openid/AppAuth-iOS
    exactVersion: 3.0.0
  GRDB:
    url: https://github.com/groue/GRDB.swift
    exactVersion: 7.11.1
  SnapshotTesting:
    url: https://github.com/pointfreeco/swift-snapshot-testing
    exactVersion: 1.19.4

targets:
  minimail:
    type: application
    platform: iOS
    sources:
      - path: minimail
        excludes:
          - "**/*.md"
          - "Info.plist"
          - "minimail.entitlements"
    dependencies:
      - package: AppAuth
        product: AppAuth
      - package: GRDB
        product: GRDB
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.minimail
        PRODUCT_NAME: minimail
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        INFOPLIST_KEY_UIUserInterfaceStyle: ""   # follow system; theme handled in-app
    info:
      path: minimail/Info.plist
      properties:
        CFBundleDisplayName: minimail
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSApplicationCategoryType: public.app-category.productivity
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
        # Export compliance: HTTPS-only (exempt) → skip the App Store Connect questionnaire.
        # https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
        ITSAppUsesNonExemptEncryption: false
        # BGAppRefreshTask (PLAN.md §Sync 5). Array of reverse-DNS task ids.
        # https://developer.apple.com/documentation/bundleresources/information-property-list/bgtaskschedulerpermittedidentifiers
        BGTaskSchedulerPermittedIdentifiers:
          - com.minimail.refresh
        UIBackgroundModes:
          - fetch
        # OAuth redirect scheme (PLAN.md: com.googleusercontent.apps.<id>:/oauth2redirect)
        # https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleurltypes
        CFBundleURLTypes:
          - CFBundleTypeRole: Editor
            CFBundleURLName: com.minimail.oauth
            CFBundleURLSchemes:
              - com.googleusercontent.apps.REPLACE_WITH_GOOGLE_CLIENT_ID
    entitlements:
      path: minimail/minimail.entitlements
      properties: {}
    scheme:
      testTargets:
        - minimailTests
        - name: minimailUITests
          parallelizable: false
      gatherCoverageData: true
      environmentVariables:
        MINIMAIL_TESTING: "1"

  minimailTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: minimailTests
    dependencies:
      - target: minimail
      - package: SnapshotTesting
        product: SnapshotTesting
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.minimailTests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/minimail.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/minimail
        BUNDLE_LOADER: $(TEST_HOST)

  minimailUITests:
    type: bundle.ui-test
    platform: iOS
    sources:
      - path: minimailUITests
    dependencies:
      - target: minimail
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.minimailUITests
        TEST_TARGET_NAME: minimail
```

Notes on the spec (all keys checked against ProjectSpec.md):
* `packages.<name>.exactVersion` is one of `from`/`majorVersion`/`minorVersion`/`exactVersion`/`version`/`minVersion`+`maxVersion`/`branch`/`revision`; `github: org/repo` is a shorthand for `url`.
* `info.path` + `info.properties` makes XcodeGen write the Info.plist; the file is regenerated on every `xcodegen generate`, so it is excluded from `sources` and never edited by hand.
* `entitlements.properties: {}` creates an empty entitlements file; nothing in stage 1 needs an entitlement (Keychain access for one app needs none; `BGTaskScheduler` needs only the Info.plist keys + `UIBackgroundModes: fetch`).
* `scheme.testTargets` generates a shared scheme `minimail` that runs both test bundles with coverage.
* `UIBackgroundModes: fetch` being required for `BGAppRefreshTask` is **UNVERIFIED** from Apple docs in this session (well-known requirement; the ios-platform research doc should confirm).
* `Config/Signing.xcconfig` content (commit a template; the owner's Team ID is not a secret):
  ```
  // Config/Signing.xcconfig
  DEVELOPMENT_TEAM = REPLACE_WITH_TEAM_ID
  ```

### 1.5 `.gitignore` additions

```
# XcodeGen output — regenerate with `xcodegen generate`
minimail.xcodeproj/
# build artefacts
.build/
DerivedData/
*.xcresult
```

---

## 2. CLI build / test

### 2.1 Tool install (one-time on the macOS runner or the owner's Mac)

```sh
xcode-select -p                                   # → /Applications/Xcode.app/Contents/Developer
sudo xcode-select -s /Applications/Xcode_26.6.app  # GitHub runner path; local Macs: /Applications/Xcode.app
xcodebuild -version                               # Xcode 26.6 / Build version 17F113
xcodebuild -runFirstLaunch                        # installs simctl & components (Apple doc below)
brew install xcodegen xcbeautify swiftlint
```

`xcodebuild -runFirstLaunch` "install[s] any required system components, including the `simctl` utility" ([Apple: Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)). If the iOS 26.5 simulator runtime is missing: `xcodebuild -downloadPlatform iOS` (optionally `-buildVersion 26.5`), same doc.

### 2.2 Listing simulators and choosing a destination

```sh
xcrun simctl list runtimes                          # e.g. iOS 26.5 (23F…) - com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl list devices available                 # names + UDIDs per runtime
xcrun simctl list devices available --json | jq -r '.devices | to_entries[] | select(.key|test("iOS")) | .value[] | select(.name|test("^iPhone")) | "\(.udid) \(.name)"'
xcodebuild -project minimail.xcodeproj -scheme minimail -showdestinations
```

Destination specifier keys for iOS Simulator are `platform`, `name`, `id`, `OS` ("`OS` … iOS version or `latest`") ([Apple TN2339](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)). Device names on the GitHub `macos-26` image (readme 2026-09-07): iOS 26.5 runtime has **iPhone 17, iPhone 17 Pro, iPhone 17 Pro Max, iPhone 17e, iPhone Air** — there is **no `iPhone 16`** in the 26.4/26.5 runtimes ([macos-26-arm64-Readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)). So:

```sh
export SIM_DEST='platform=iOS Simulator,name=iPhone 17'     # canonical
# compile-only, no device needed at all:
export SIM_GENERIC='generic/platform=iOS Simulator'
```

`xcrun simctl` sub-commands used in this doc (`list`, `boot`, `shutdown`, `io … screenshot`, `create`) come from `xcrun simctl help`; Apple has no web reference page for them — treat exact flags as **UNVERIFIED** and consult `xcrun simctl help <subcommand>` on the runner.

### 2.3 Generate, resolve, build

```sh
cd /path/to/minimail
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project minimail.xcodeproj -scheme minimail \
  -clonedSourcePackagesDirPath .build/SourcePackages

set -o pipefail
xcodebuild build \
  -project minimail.xcodeproj \
  -scheme minimail \
  -configuration Debug \
  -destination "$SIM_GENERIC" \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | xcbeautify
```

* Build settings are passed as trailing `NAME=value` arguments (TN2339; also Apple forum thread "[xcodebuild is very slow unless you set CODE_SIGNING_ALLOWED=NO](https://developer.apple.com/forums/thread/766578)"). `CODE_SIGNING_ALLOWED` is **not** in Apple's Build Settings Reference page (it is an xcodebuild-level override) — the triple `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` is the widely used CI incantation ([Codemagic docs](https://docs.codemagic.io/yaml-code-signing/ios-simulator-builds/)); with it no `DEVELOPMENT_TEAM` is needed for simulator builds.
* `-clonedSourcePackagesDirPath` "Specifies the directory to which remote source packages are fetch or expected to be found" (xcodebuild man page via search snippet; the man-page mirrors are blocked from this sandbox — **partially verified**). It is what we cache in CI.
* `set -o pipefail` is required so `xcbeautify` does not swallow xcodebuild's exit code ([xcbeautify README](https://github.com/cpisciotta/xcbeautify)). For parallel test output use `NSUnbufferedIO=YES xcodebuild … 2>&1 | xcbeautify`.
* xcpretty is unmaintained (no updates since 2018); fastlane and Bitrise switched to xcbeautify ([fastlane discussion #17438](https://github.com/fastlane/fastlane/discussions/17438)). Use `xcbeautify --renderer github-actions` on CI; `--report junit` writes JUnit XML; `--quiet`/`--quieter` reduce noise (README).
* Xcode 26 builds Swift with explicit modules by default; opt out with `SWIFT_ENABLE_EXPLICIT_MODULES=NO` only if you hit a compiler bug ([Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)).

### 2.4 Run tests

```sh
rm -rf .build/results/unit.xcresult          # -resultBundlePath must not already exist
set -o pipefail
xcodebuild test \
  -project minimail.xcodeproj \
  -scheme minimail \
  -destination "$SIM_DEST" \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -resultBundlePath .build/results/unit.xcresult \
  -only-testing:minimailTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | xcbeautify --report junit --report-path .build/results
```

* Run **one test**: `-only-testing:minimailTests/MIMEBuilderTests/testReplyAllDedupesSelf`. Identifier form is `TestTarget[/TestClass[/TestMethod]]` (TN2339, colon syntax) — Apple's current doc shows the space form `-only-testing SampleAppTests/SampleAppTests/testEmptyArrayWhenNoOverlappingNotes`; both work ([Running tests and interpreting results](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results)). A whole class: `-only-testing:minimailTests/MIMEBuilderTests`. Skip the UI bundle: `-skip-testing:minimailUITests`.
* Flaky-test loop from the same Apple doc: `-run-tests-until-failure -test-iterations 20`.
* Two-phase for CI reuse: `xcodebuild build-for-testing …` then `xcodebuild test-without-building -xctestrun <path>.xctestrun …`; Xcode 26 added `-only-test-configuration <name>` for test-without-building ([Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)).
* `-resultBundlePath` "Writes a bundle to the specified path … If the path already exists, xcodebuild will exit with an error" (man page via search snippet — **partially verified**).

### 2.5 Reading results without Xcode

```sh
xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact
xcrun xcresulttool get test-results tests   --path .build/results/unit.xcresult
xcrun xcresulttool help get test-results summary      # prints the JSON schema
```

Xcode 16+ replaced the legacy `get object --format json` (now needs `--legacy`) with `get test-results {summary|tests|test-details|activities|insights}`; the DTS answer in [Apple forum thread 763050](https://developer.apple.com/forums/thread/763050) documents `summary --path <path> [--compact]` and the `Summary` schema fields (`totalTestCount`, `passedTests`, `failedTests`, `skippedTests`, `testFailures`, …).

### 2.6 Screenshots / booting a simulator explicitly (optional, for the agent to "see" the app)

```sh
UDID=$(xcrun simctl list devices available --json | jq -r '[.devices[][] | select(.name=="iPhone 17")][0].udid')
xcrun simctl boot "$UDID" || true
xcrun simctl install "$UDID" .build/DerivedData/Build/Products/Debug-iphonesimulator/minimail.app
xcrun simctl launch "$UDID" com.minimail
xcrun simctl io "$UDID" screenshot .build/shot.png
xcrun simctl shutdown "$UDID"
```
(sub-command names from `xcrun simctl help`; **UNVERIFIED** flags, see §2.2.)

### 2.7 `Makefile` (copy-paste)

```make
# Makefile — headless workflow for minimail
PROJECT      := minimail.xcodeproj
SCHEME       := minimail
DD           := .build/DerivedData
SPM          := .build/SourcePackages
RESULTS      := .build/results
SIM_DEST     ?= platform=iOS Simulator,name=iPhone 17
NOSIGN       := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
XCB          := xcbeautify --renderer $(if $(GITHUB_ACTIONS),github-actions,terminal)

.PHONY: gen resolve build test test-unit test-ui test-one lint format clean sims

gen:
	xcodegen generate

resolve: gen
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) -clonedSourcePackagesDirPath $(SPM)

build: gen
	set -o pipefail && xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) $(NOSIGN) | $(XCB)

test-unit: gen
	rm -rf $(RESULTS)/unit.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/unit.xcresult \
	  -only-testing:minimailTests $(NOSIGN) | $(XCB)
	xcrun xcresulttool get test-results summary --path $(RESULTS)/unit.xcresult --compact

test-ui: gen
	rm -rf $(RESULTS)/ui.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/ui.xcresult \
	  -only-testing:minimailUITests $(NOSIGN) | $(XCB)

# make test-one T=minimailTests/MIMEBuilderTests/testReplyAllDedupesSelf
test-one: gen
	rm -rf $(RESULTS)/one.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/one.xcresult \
	  -only-testing:$(T) $(NOSIGN) | $(XCB)

test: test-unit

lint:
	swift format lint --strict --recursive minimail minimailTests minimailUITests
	swiftlint lint --strict

format:
	swift format --in-place --recursive minimail minimailTests minimailUITests
	swiftlint --fix

sims:
	xcrun simctl list devices available

clean:
	rm -rf .build $(PROJECT)
```

---

## 3. Toolchain versions and language settings (as of 2026-09-11)

### 3.1 Xcode / Swift / iOS

| Item | Value | Source |
|---|---|---|
| Current Xcode GA | **Xcode 26.6 (17F113)**, 2026-06-25; "includes Swift 6.3 and SDKs for iOS 26.5 …"; "requires a Mac running macOS Tahoe 26.2 or later"; on-device debugging iOS 15+ | [Xcode 26.6 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_6-release-notes), [Apple releases feed](https://developer.apple.com/news/releases/) |
| Next | **Xcode 27 RC (27A266a)**, 2026-09-09; "includes Swift 6.4 and SDKs for iOS 27 …"; "requires a Mac running macOS Tahoe 26.6 or later"; on-device debugging iOS 17+; simulators iOS 17+; deployment targets iOS 15–27 | [Xcode 27 RC release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes), [Xcode support table](https://developer.apple.com/support/xcode/) |
| iOS 27 public release | 2026-09-14 (iOS 27.0 RC 24A435 on 2026-09-09) | [Apple releases feed](https://developer.apple.com/news/releases/), [9to5Mac](https://9to5mac.com/2026/09/09/apple-confirms-ios-27-release-date-september-14/) |
| Xcode 26.0 baseline | Swift 6.2, iOS 26 SDK, macOS 15.6+; Swift explicit modules default; `xcodebuild build-for-testing` emits disabled test-plan configs; XCTest gained non-failing `XCTIssue` severity | [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes) |
| iOS adoption | iOS 26: 79 % of all iPhones, 86 % of iPhones introduced in the last four years (measured 2026-06-07) | [Apple App Store support](https://developer.apple.com/support/app-store/) |

**Plan:** pin Xcode **26.6** in CI today. When the `macos-26` image lists Xcode 27.0 GA (watch the [macos-26-arm64 readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)), bump `xcode-version: '27.0'` and `options.xcodeVersion: "27.0"`. Apple historically requires the new SDK for App Store/TestFlight uploads from the following April — **UNVERIFIED** for iOS 27 specifically.

### 3.2 Deployment target

Keep **iOS 17.0** (PLAN.md decision; `@Observable`, `NavigationStack` all available). Dependencies allow it (AppAuth 3.0.0 → iOS 15; GRDB 7.11.1 → iOS 13). Xcode 27 still supports iOS 15+ deployment targets. Raising to 26 would buy Liquid-Glass-native SwiftUI defaults on the owner's phone but forfeits nothing critical for stage 1; revisit at M4.

### 3.3 Swift language mode + concurrency: choose Swift 6 + MainActor default

Exact build-setting names/descriptions from Apple's [Build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference):

* `SWIFT_VERSION` — "The language version used to compile the target's Swift code." (`5` or `6`)
* `SWIFT_STRICT_CONCURRENCY` — "Enables strict concurrency checking to produce warnings for possible data races. This is always 'complete' when in the Swift 6 language mode and produces errors instead of warnings." (values `minimal` / `targeted` / `complete`)
* `SWIFT_DEFAULT_ACTOR_ISOLATION` — "Controls default actor isolation for unannotated code. When set to 'MainActor', `@MainActor` isolation will be inferred by default to mitigate false-positive data-race safety errors in sequential code." (`nonisolated` / `MainActor`)
* `SWIFT_APPROACHABLE_CONCURRENCY` — "Enables upcoming features that aim to provide a more approachable path to Swift Concurrency: DisableOutwardActorInference, GlobalActorIsolatedTypesUsability, InferIsolatedConformances, InferSendableFromCaptures, and NonisolatedNonsendingByDefault."
* `SWIFT_TREAT_WARNINGS_AS_ERRORS` — "Treat all warnings as errors." (keep `NO` for agent velocity)

Xcode 26 new-project templates default to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`; existing projects get `nonisolated` ([Donny Wals](https://www.donnywals.com/setting-default-actor-isolation-in-xcode-26/), [SwiftLee](https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/) — secondary sources; the Apple reference above confirms the setting semantics).

**Recommendation (lowest friction for a UI-heavy app written by an agent):**

```yaml
SWIFT_VERSION: "6"
SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
SWIFT_APPROACHABLE_CONCURRENCY: YES
```

Rationale: ~80 % of minimail is main-actor UI/state code; MainActor-by-default makes that compile without annotations, and the sync engine / MIME builder are explicitly `actor` or `nonisolated`/`@concurrent`. Swift 6 mode turns data races into compile errors, which is exactly the feedback an unattended agent needs (Swift 5 mode would hide them as warnings that nobody reads).

**Escape hatch** if GRDB/AppAuth closures fight the MainActor default (how GRDB 7's `sending` closures interact with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` is **UNVERIFIED** — test in M1 on the first `DatabaseQueue.read`):

1. First try `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` (still Swift 6).
2. Only if still blocked: `SWIFT_VERSION: "5"` + `SWIFT_STRICT_CONCURRENCY: complete` (warnings, not errors) — the migration path recommended by the Swift migration guide: enable "Strict Concurrency Checking = Complete" in Swift 5 mode first, then switch "Swift Language Version" to 6 ([EnableDataRaceSafety.md](https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/EnableDataRaceSafety.md)).

Test frameworks: PLAN.md says XCTest; Swift Testing (`@Test`, `#expect`) also works under `xcodebuild test` in Xcode 26/27 and swift-snapshot-testing supports both. Keep XCTest for uniformity with XCUITest.

---

## 4. GitHub Actions

### 4.1 Runner labels (from [actions/runner-images README](https://github.com/actions/runner-images))

| Image | Labels | Notes |
|---|---|---|
| macOS 26 arm64 | `macos-latest`, `macos-26`, `macos-26-xlarge` | **Use `macos-26`.** Image 20260907.0351.1: macOS 26.6.2, Xcode 26.6 (17F113) default, plus 26.5/26.4.1/26.3/26.2/26.1.1/26.0.1; iOS 26.0/26.1/26.2/26.4/26.5 simulator runtimes; Fastlane 2.239.0, xcbeautify 3.2.1, Homebrew 6.0.22 ([macos-26-arm64 readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)). SwiftLint 0.65.1 appears in the x64 readme; the arm64 fetch did not list SwiftLint/XcodeGen — install both with brew to be safe. |
| macOS 26 x64 | `macos-latest-large`, `macos-26-intel`, `macos-26-large` | Paid larger runners; not needed. |
| Xcode 27 | `xcode-27`, `xcode-27-xlarge` | **Preview** image with Xcode 27 RC. Use once Xcode 27 is GA or when you need the iOS 27 SDK. |
| macOS 15 arm64 | `macos-15`, `macos-15-xlarge` | Xcode 16.0–16.4 only — too old for Swift 6.3 / iOS 26 SDK. |
| macOS 14 | `macos-14`, `macos-14-large`, … | deprecated |

`macos-latest` migrated from macOS 15 to macOS 26 between 2026-06-15 and 2026-07-15 ([issue #14167](https://github.com/actions/runner-images/issues/14167)); GA announcement 2026-02-26 ([GitHub changelog](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)). Always pin `macos-26`, never `macos-latest`.

### 4.2 Xcode selection

`maxim-lobanov/setup-xcode@v1` with `xcode-version:` accepting `latest`, `latest-stable`, semver (`26.3`, `^16.2.0`) or `<semver>-beta`; quote exact versions (`'26.6'`) because YAML trims trailing `.0` ([README](https://github.com/maxim-lobanov/setup-xcode)). Equivalent without the action: `sudo xcode-select -s /Applications/Xcode_26.6.app`.

### 4.3 Caching SPM

`actions/cache` examples show `actions/cache@v6` with `path: .build` and `key: ${{ runner.os }}-spm-${{ hashFiles('**/Package.resolved') }}` ([examples.md](https://github.com/actions/cache/blob/main/examples.md)). Because the `.xcodeproj` (and therefore its `Package.resolved`) is regenerated on every run, key the cache on **`project.yml`** instead — with `exactVersion` pins that is deterministic — and cache the `-clonedSourcePackagesDirPath` directory.

### 4.4 Workflow (`.github/workflows/ci.yml`)

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: macos-26
    timeout-minutes: 40
    env:
      SIM_DEST: platform=iOS Simulator,name=iPhone 17
    steps:
      - uses: actions/checkout@v7

      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '26.6'

      - name: Install tools
        run: brew install xcodegen swiftlint   # xcbeautify is preinstalled on macos-26

      - name: Generate project
        run: xcodegen generate

      - name: Cache Swift packages
        uses: actions/cache@v6
        with:
          path: .build/SourcePackages
          key: spm-${{ runner.os }}-xcode26.6-${{ hashFiles('project.yml') }}
          restore-keys: |
            spm-${{ runner.os }}-xcode26.6-

      - name: Lint
        run: |
          swift format lint --strict --recursive minimail minimailTests minimailUITests
          swiftlint lint --strict --reporter github-actions-logging

      - name: Unit + snapshot tests
        run: |
          set -o pipefail
          NSUnbufferedIO=YES xcodebuild test \
            -project minimail.xcodeproj -scheme minimail \
            -destination "$SIM_DEST" \
            -derivedDataPath .build/DerivedData \
            -clonedSourcePackagesDirPath .build/SourcePackages \
            -resultBundlePath .build/results/unit.xcresult \
            -only-testing:minimailTests \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
            2>&1 | xcbeautify --renderer github-actions --report junit --report-path .build/results

      - name: Test summary
        if: always()
        run: xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact || true

      - name: Upload results
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: xcresult
          path: .build/results
```

Versions: `actions/checkout` latest tag v7.0.1 (2026-07-20), `actions/cache` v6.1.0 (2026-06-26) ([atom feeds](https://github.com/actions/checkout/releases.atom), [cache](https://github.com/actions/cache/releases.atom)). `swiftlint --reporter github-actions-logging` is a SwiftLint reporter name — **UNVERIFIED** in this session (from memory of `swiftlint reporters`); drop the flag if it errors. `actions/upload-artifact@v4` version **UNVERIFIED** (not fetched).

Add a second job with `-only-testing:minimailUITests` only on `main` pushes (UI tests double the runtime).

### 4.5 Cost

* Included minutes (private repos): **Free 2,000 / Pro 3,000 / Team 3,000 / Enterprise 50,000 per month**; public repos are free ([github/docs actions-included-quotas](https://github.com/github/docs/blob/main/data/reusables/billing/actions-included-quotas.md), [github-actions.md](https://github.com/github/docs/blob/main/content/billing/concepts/product-billing/github-actions.md)).
* Per-minute list price: **macOS 3-/4-core $0.062**, Linux 2-core $0.006, Windows $0.010; macOS 12-core $0.077, macOS 5-core M2 Pro (`macos_xl`) $0.102 ([actions-standard-runner-prices](https://github.com/github/docs/blob/main/data/reusables/billing/actions-standard-runner-prices.md), [actions-runner-pricing.md](https://github.com/github/docs/blob/main/content/billing/reference/actions-runner-pricing.md)).
* Whether included minutes are still consumed at a **10× macOS multiplier** after GitHub's 2026 pricing change: third-party sources say yes ([cicdpipelinecost](https://cicdpipelinecost.com/github-actions-pricing), [Bitrise](https://bitrise.io/blog/post/best-github-actions-runners-in-2026-and-hidden-pricing-traps-to-avoid)); the official page that states it (docs.github.com / github.blog changelog 2025-12-16) is blocked from this sandbox — **UNVERIFIED**. Budget conservatively: a ~10-minute macOS job = 100 included-minute units → ~20 runs/month on Free for a private repo, or ~$0.62 per run pay-as-you-go. A public repo is free.
* Practical: expect 6–12 min per unit-test run on `macos-26` (cold SPM resolve ≈1–2 min, build ≈3–5 min, simulator boot ≈1 min, tests <1 min) — estimate, **UNVERIFIED**.

---

## 5. Linting / formatting

### 5.1 swift-format (bundled — no install)

"Swift 6+ (Xcode 16) includes swift-format in the toolchain … run … using `swift format` (notice the space instead of dash)" ([swift-format README](https://github.com/swiftlang/swift-format)). Flags: `-i/--in-place`, `-r/--recursive`, `lint -s/--strict` (non-zero exit on warnings), `dump-configuration` (prints default JSON to seed a config).

```sh
swift format dump-configuration > .swift-format   # then trim
swift format --in-place --recursive minimail minimailTests minimailUITests
swift format lint --strict --recursive minimail minimailTests minimailUITests
```

Minimal `.swift-format` (keys/defaults from [Configuration.md](https://github.com/swiftlang/swift-format/blob/main/Documentation/Configuration.md)):

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 4 },
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeControlFlowKeywords": false,
  "lineBreakBeforeEachArgument": false,
  "indentConditionalCompilationBlocks": true,
  "rules": {
    "AlwaysUseLowerCamelCase": true,
    "NeverForceUnwrap": true,
    "OrderedImports": true,
    "UseEarlyExits": false
  }
}
```

### 5.2 SwiftLint 0.65.1 (2026-08-21)

Install: `brew install swiftlint` (or `mint install realm/SwiftLint`); run `swiftlint lint`, `swiftlint --fix`, `--strict` promotes warnings to errors; you cannot combine `only_rules` with `disabled_rules`/`opt_in_rules` ([README](https://github.com/realm/SwiftLint)). 0.65.1 requires a Swift 6 compiler to build; fine with Xcode 26 ([releases](https://github.com/realm/SwiftLint/releases)).

Minimal `.swiftlint.yml` — correctness-only, formatting left to swift-format:

```yaml
# .swiftlint.yml
included:
  - minimail
  - minimailTests
  - minimailUITests
excluded:
  - .build
  - minimail.xcodeproj
only_rules:
  - force_cast
  - force_try
  - force_unwrapping
  - implicitly_unwrapped_optional
  - unused_closure_parameter
  - unused_optional_binding
  - empty_count
  - first_where
  - last_where
  - contains_over_first_not_nil
  - redundant_optional_initialization
  - todo
  - legacy_random
  - private_outlet
  - weak_delegate
reporter: "xcode"
```

Rule names above are standard SwiftLint rule identifiers; verify with `swiftlint rules` on the runner (**UNVERIFIED** that every identifier still exists in 0.65.1 — remove any that `swiftlint rules` does not list).

---

## 6. Deployment: TestFlight vs. free provisioning (personal app, one user)

### 6.1 What the free "personal team" gives you (Apple, [Choosing a membership](https://developer.apple.com/support/compare-memberships/))

* "Up to 10 App IDs (expire after 7 days)", "Up to 3 devices (expire after 7 days)", "Up to 3 apps per device", "Provisioning profiles expire 7 days from issuance — You'll need to rebuild and reinstall your app to your device after expiration".
* No TestFlight, no App Store Connect. Installing needs the phone attached (cable/Wi-Fi) to a Mac running Xcode/`devicectl`.

For a mail client the owner uses daily this is a non-starter (weekly re-install, and a Mac in the loop each time).

### 6.2 Recommended: Apple Developer Program → TestFlight

Manual, owner-only steps (cannot be scripted):

1. Enroll: **$99 USD/year**, Apple Account with 2FA, legal name ([enroll page](https://developer.apple.com/programs/enroll/)). Joining "creates an App Store Connect account for you and you can start uploading builds"; TestFlight and registered-device distribution require membership ([Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)).
2. In App Store Connect: create the **app record** for bundle id `com.minimail` (required before first upload — same Apple doc, "Create an app record").
3. Create an **App Store Connect API key** (Team key, role App Manager or Admin) and download the `.p8` once. Store `AuthKey_<KEYID>.p8`, key ID and issuer ID as CI secrets. (UI location in ASC: Users and Access → Integrations — **UNVERIFIED** exact menu names.)
4. On the owner's iPhone: install the TestFlight app; the owner adds themself as an internal tester.
5. Put `DEVELOPMENT_TEAM = <TeamID>` in `Config/Signing.xcconfig`.

Scriptable (agent/CI):

```sh
# 1. archive (device build; automatic signing, cloud-managed certs)
xcodebuild archive \
  -project minimail.xcodeproj -scheme minimail -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .build/minimail.xcarchive \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  | xcbeautify

# 2. export + upload to TestFlight in one step
xcodebuild -exportArchive \
  -archivePath .build/minimail.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath .build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  | xcbeautify
```

`ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>REPLACE_WITH_TEAM_ID</string>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <true/>
  <key>testFlightInternalTestingOnly</key>
  <true/>
</dict>
</plist>
```

Verification status: `method` values `app-store-connect` / `release-testing` / `debugging` / `enterprise` (`app-store` deprecated), `destination = upload`, and `-authenticationKeyPath` requiring `-authenticationKeyID` + `-authenticationKeyIssuerID` come from the `xcodebuild -help` text quoted in search results and the command shown in [Apple forum thread 742458](https://developer.apple.com/forums/thread/742458); the man-page mirrors are blocked from this sandbox, so the exact key list is **partially verified**. Run `xcodebuild -help` on the runner and grep "exportOptionsPlist" for the authoritative list; `signingStyle`, `teamID`, `uploadSymbols`, `manageAppVersionAndBuildNumber`, `testFlightInternalTestingOnly` are keys from that help text (**UNVERIFIED** individually). The "TestFlight Internal Only" option maps to "restrict access to your team … prevent a development build … from being submitted to the App Store" ([Apple distribution doc](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)).

Bump `CURRENT_PROJECT_VERSION` per upload (or rely on `manageAppVersionAndBuildNumber`). TestFlight builds expire after 90 days (**UNVERIFIED** here; standard TestFlight rule). No App Review is needed for internal testers.

fastlane (2.239.0 preinstalled on the runner) is **not** needed: `xcodebuild -exportArchive … upload` covers the whole path. Add fastlane only if you later want `pilot`/`match` conveniences.

### 6.3 If the owner refuses the $99 (fallback)

Free personal team + direct install from a Mac: build with `-destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=<personal team id>` (the owner must be signed into Xcode once so the personal team exists — GUI step), then `xcrun devicectl device install app --device <udid> <path>.app` and re-do it every 7 days. `devicectl` exists in Xcode 15+ (Xcode 27 notes reference its JSON v5 output) but the exact sub-command flags are **UNVERIFIED** — check `xcrun devicectl --help`.

---

## 7. Tests that work headless

### 7.1 Unit tests (bulk of the value)

XCTest in `minimailTests` for: MIME builder/parser, base64url, reply-all recipient logic, "Today" date logic (time-zone table-driven), sync-engine delta application against an in-memory GRDB `DatabaseQueue`, HTML sanitizer. All run on the simulator via §2.4; no UI involved, ~seconds.

### 7.2 Snapshot tests (2–3, not more) — swift-snapshot-testing 1.19.4

Add to the unit-test target (already wired in `project.yml`). Usage from the [README](https://github.com/pointfreeco/swift-snapshot-testing): `assertSnapshot(of: value, as: .image)`; first run records and fails, re-run passes. Record modes: `assertSnapshot(of: vc, as: .image, record: .all)`, `withSnapshotTesting(record: .all) { … }`, or for Swift Testing `@Suite(.snapshots(record: .failed))`.

```swift
import SnapshotTesting
import SwiftUI
import XCTest
@testable import minimail

@MainActor
final class InboxRowSnapshotTests: XCTestCase {
    func testUnreadRowDark() {
        let view = InboxRow(item: .fixtureUnread)
            .frame(width: 390)
            .environment(\.colorScheme, .dark)
        let host = UIHostingController(rootView: view)
        assertSnapshot(of: host, as: .image(on: .iPhone13, traits: .init(userInterfaceStyle: .dark)))
    }
}
```

Reference PNGs live in `minimailTests/__Snapshots__/…` and are committed. Snapshot images are device/OS-specific: always record and compare on the **same** simulator model + iOS runtime the CI uses (`iPhone 17`, iOS 26.5) or the diff will fail. The `.iPhone13` device preset name and the `SNAPSHOT_TESTING_RECORD` env var are **UNVERIFIED** in this session — confirm in the package's `Documentation.docc` before use. Keep snapshot tests to a few list rows / theme checks; they exist to catch theme-token regressions, not layout pixel drift.

### 7.3 XCUITest smoke (exactly one)

One test in `minimailUITests`: launch with `MINIMAIL_TESTING=1` (scheme env var above; use it to inject a stub Gmail client + seeded SQLite), assert the inbox list shows the seeded subject, tap "Unread", assert the filter chip state. Runs headless on the simulator under `xcodebuild test -only-testing:minimailUITests`; expect ~1–2 min including app launch. Xcode 27 adds `XCUIVoiceOverService` and XCTest/Swift Testing cross-assertion runtime issues ([Xcode 27 RC notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)) — not needed here.

Not recommended: more UI tests (slow, flaky on cold simulators), Xcode Cloud (GUI-configured), the Xcode 27 "agents can boot simulators … capture screenshots" feature (Xcode-GUI coding assistant only).

### 7.4 Optional: Linux-testable core package

Everything that does not import UIKit/SwiftUI/AppAuth/GRDB (MIME builder, base64url, date/"today" logic, DTO decoding) can live in a local SwiftPM package `Packages/MinimailCore` (add `packages: MinimailCore: { path: Packages/MinimailCore }` and a `- package: MinimailCore` dependency in `project.yml`; local-package syntax per ProjectSpec.md). The agent then runs `swift test` on Linux in seconds without a Mac in the loop (Swift 6.x toolchain via `docker run --rm -v "$PWD":/src -w /src/Packages/MinimailCore swift:6.1 swift test` — image tag **UNVERIFIED**, check hub.docker.com/_/swift). Keep `Foundation`-only code there; `import FoundationEssentials`-style differences between Darwin and Linux Foundation are the main gotcha (e.g. `NSRegularExpression`, `String(format:)` nuances).

---

## 8. Agent runbook (order of operations on the macOS runner)

```sh
brew install xcodegen swiftlint xcbeautify        # once
xcodegen generate                                  # after ANY file add/remove/rename
make build                                         # compile-only sanity (generic simulator, no signing)
make test-unit                                     # unit + snapshot tests, prints xcresult summary
make test-one T=minimailTests/MIMEBuilderTests/testReplyAllDedupesSelf
make lint && make format
make test-ui                                       # before merging to main
```

Failure triage:
* "Unable to find a destination matching … name:iPhone 16" → run `make sims`, use `iPhone 17` (§2.2).
* "Signing for "minimail" requires a development team" on a simulator build → the `CODE_SIGNING_ALLOWED=NO …` triple is missing (§2.3).
* "resultBundlePath … already exists" → `rm -rf` the `.xcresult` first.
* Swift 6 isolation errors flooding from GRDB closures → §3.3 escape hatch step 1.
* Package resolution hangs on CI → cache miss + GitHub rate limit; re-run, or commit `.build/SourcePackages` checksum key (`project.yml` hash) as in §4.4.

---

## 9. Source index

Official / primary:
* Xcode 26.6 release notes — https://developer.apple.com/documentation/xcode-release-notes/xcode-26_6-release-notes
* Xcode 26 release notes — https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes
* Xcode 27 RC release notes — https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
* Xcode support table — https://developer.apple.com/support/xcode/
* Apple releases feed — https://developer.apple.com/news/releases/
* Build settings reference — https://developer.apple.com/documentation/xcode/build-settings-reference
* Running tests and interpreting results — https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results
* TN2339 Building from the Command Line — https://developer.apple.com/library/archive/technotes/tn2339/_index.html
* Downloading and installing additional Xcode components — https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components
* Distributing your app for beta testing and releases — https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases
* Distributing your app to registered devices — https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices
* Choosing a membership (free tier limits) — https://developer.apple.com/support/compare-memberships/
* Apple Developer Program enrollment — https://developer.apple.com/programs/enroll/
* App Store iOS adoption — https://developer.apple.com/support/app-store/
* Info.plist keys — https://developer.apple.com/documentation/bundleresources/information-property-list/bgtaskschedulerpermittedidentifiers , …/itsappusesnonexemptencryption , …/cfbundleurltypes
* xcresulttool DTS answer — https://developer.apple.com/forums/thread/763050
* xcodebuild upload example — https://developer.apple.com/forums/thread/742458
* XcodeGen — https://github.com/yonaskolb/XcodeGen (README, Docs/ProjectSpec.md, releases)
* AppAuth-iOS 3.0.0 — https://github.com/openid/AppAuth-iOS/releases/tag/3.0.0 ; Package.swift
* GRDB.swift — https://github.com/groue/GRDB.swift (README, releases)
* swift-snapshot-testing — https://github.com/pointfreeco/swift-snapshot-testing (README, releases)
* SwiftLint — https://github.com/realm/SwiftLint (README, releases)
* swift-format — https://github.com/swiftlang/swift-format (README, Documentation/Configuration.md)
* xcbeautify — https://github.com/cpisciotta/xcbeautify (README, releases)
* Swift migration guide — https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/EnableDataRaceSafety.md
* GitHub runner images — https://github.com/actions/runner-images (README, images/macos/macos-26-arm64-Readme.md, issue #14167)
* setup-xcode — https://github.com/maxim-lobanov/setup-xcode
* actions/cache examples — https://github.com/actions/cache/blob/main/examples.md
* GitHub billing source files — https://github.com/github/docs/blob/main/data/reusables/billing/actions-included-quotas.md , …/actions-standard-runner-prices.md , content/billing/reference/actions-runner-pricing.md

Secondary (used only where marked):
* Codemagic simulator signing flags — https://docs.codemagic.io/yaml-code-signing/ios-simulator-builds/
* Donny Wals / SwiftLee on Xcode 26 concurrency defaults — https://www.donnywals.com/setting-default-actor-isolation-in-xcode-26/ , https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/
* fastlane xcbeautify discussion — https://github.com/fastlane/fastlane/discussions/17438
* GitHub Actions macOS 10× multiplier — https://cicdpipelinecost.com/github-actions-pricing , https://bitrise.io/blog/post/best-github-actions-runners-in-2026-and-hidden-pricing-traps-to-avoid
* iOS 27 release date — https://9to5mac.com/2026/09/09/apple-confirms-ios-27-release-date-september-14/
