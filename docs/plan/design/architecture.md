# minimail — Stage-1 architecture (FINAL)

Date: 2026-09-11. Base: candidate **SIMPLE** (winner, 134 points), with every compatible graft from SPEED and ROBUST that the three judges asked for, and every listed flaw fixed. Section numbering follows the candidates (§0–§14) so the judges' references stay valid; §15 is the decision log, §16 the non-goals, Appendix A the module list for the detailed specs.

Inputs: `/home/user/minimail/PLAN.md` (accepted outline) and the research files under `docs/plan/research/` — cited as `[gmail-api §n]`, `[ios-platform §n]`, `[mime-rfc §n]`, `[html-rendering §n]`, `[tooling §n]`. Facts those files mark UNVERIFIED stay UNVERIFIED here; each has a written fallback (§14).

Reader: an AI coding agent working headless (Linux for editing and `swift test` of the pure packages, a macOS runner for `xcodebuild`). Everything is reproducible from files and CLI commands; nothing needs the Xcode GUI.

---

## 0. Decisions at a glance

| # | Decision | Why |
|---|---|---|
| 1 | **Three build products**: app target `minimail`, local SwiftPM package `Packages/MailCore` with two libraries — `MailCore` (Foundation only, zero dependencies) and `MailHTML` (SwiftSoup). | `MailCore` (MIME, headers, DTOs, batch codec, history reduction, label algebra, thread aggregation, day boundary, compose assembly) is tested with `swift test` on Linux in seconds and never depends on SwiftSoup building on Linux (UNVERIFIED, `[html-rendering §1.1]`). |
| 2 | **Three dependencies**, pinned exactly: AppAuth-iOS 3.0.0, GRDB.swift 7.11.1, SwiftSoup 2.13.9. No snapshot-testing, no SwiftLint, no DI framework. | Each replaces weeks of risky code; everything else is smaller written by hand `[ios-platform §1.7, §2.1; html-rendering §1.1]`. |
| 3 | **Two label columns per message**: `serverLabelIds` (S, what Gmail last said) and `labelIds` (E = S ⊕ pending outbox deltas P). Sync writes S only; E is recomputed by one function after every S write. | Makes optimistic actions, history echoes, body fetches and re-hydration commute; removes the mark-read/archive race all judges found in SIMPLE `[gmail-api §13 item 7]`. |
| 4 | **Denormalised `thread` table** (+ `thread_label` junction) maintained by a pure aggregator inside the same write transaction; partial covering indexes; `message_body` in its own table. | List observation ticks cost one indexed read, never a GROUP BY over `message`; bodies never enter list pages. |
| 5 | **Hydration** = `messages.list?labelIds=INBOX&maxResults=100` + batched `messages.get?format=metadata` (25/batch, sequential). Threads are `isComplete = 0` until first open, which does **one** `threads.get?format=full` (headers + bodies of every message, one round trip). | Half the pessimistic quota of `threads.get` per message `[gmail-api gotcha 11]`; complete threads and bodies arrive in a single round trip on open. |
| 6 | **Delta** = `history.list` reduced by a pure `HistoryReducer`; only messages in scope (INBOX, cached label views, known threads) are fetched (`HydrationPolicy`). **404 → generation-based resync**, never a cache wipe. | Cheap expected path `[gmail-api §13.5–6]`; cached bodies of still-listed threads and outbox-referenced rows survive. |
| 7 | **Every write to Gmail is an outbox row** created in the same transaction as the optimistic local change. Modify ops: one pending op per thread (coalesced, inverse cancels), sent as `threads.modify` parts inside one HTTP batch with per-part results. Transient failures never delete an op. Sends carry their own `Message-ID` and a `transmitState` for the `rfc822msgid:` idempotency check. | One conflict rule, one retry rule, no `batchModify` (204, no per-id result, UNVERIFIED failure status `[gmail-api §8]`). |
| 8 | **Bodies fetched lazily on open only**; never prefetched, never in BG refresh; sanitised once (off main, outside the write transaction) and cached. Attachments downloaded on tap; inline `cid:` images through a `WKURLSchemeHandler` with a 2-in-flight cap. | PLAN.md "Body fetched lazily on open", "nothing speculative". |
| 9 | **The single pooled `WKWebView` is the scroller**; a thread is one HTML document; expand/collapse toggles a class via `evaluateJavaScript`; reload only when bodies arrive, images are enabled, or theme/Dynamic Type changes. Compose quote preview is SwiftUI `Text`; the signature editor uses a throwaway second instance only while visible. | No height measuring, no scroll jumps `[html-rendering §4]`. |
| 10 | **Swift 6 language mode + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** in the app; packages nonisolated. Exactly four actors: `AppAuthTokenProvider`, `GmailClient`, `SyncEngine`, `Outbox`. Composition root = one `@Observable AppEnvironment`. | UI compiles unannotated; races are compile errors `[tooling §3.3]`. |
| 11 | **Launch order is fixed**: settings decode + DB open + Keychain existence check + `.immediate` observation → first frame from SQLite; token unarchive, sync, rule lists, web-view warm-up and BG scheduling only after it. `UILaunchScreen.UIColorName = LaunchBackground`. | Cold start < 400 ms to first list paint; no white flash in dark mode. |
| 12 | **Stock Light/Dark themes resolve to system semantic colours** (`.systemBackground`, `.label`, …); hex only for the web template's CSS variables (resolved via `UIColor` per scheme); the template carries both `@media (prefers-color-scheme)` and `html[data-theme]` selectors. | Honours Increase Contrast etc.; free fallback for the UNVERIFIED `overrideUserInterfaceStyle` propagation `[html-rendering §7]`. |
| 13 | **Whole-thread read/unread and archive** (`threads.modify`); opening a thread marks it read. Reply-all and forward keep `threadId` + `In-Reply-To` + `References` (Gmail-web behaviour). | Simplest consistent model `[gmail-api gotcha 8; mime-rfc §1.5]`. |
| 14 | **Settings = one `Codable` struct in `UserDefaults`**; account facts live in `syncState`; tokens in the Keychain. Sign-out deletes the DB directory and the Keychain item, keeps style settings. | Three stores, each with one obvious owner. |
| 15 | **No UI-test target, no snapshot tests, no CI launch-time gate** in stage 1. Smoke XCTests host the root views against a seeded in-memory DB; launch metrics are measured on device with signposts. | Simulator perf gates flake; pixels need an eye `[tooling §7]`. |

Explicit simplifications versus PLAN.md (deliberate, reversible): the `thread` table is derived (never edited by hand); read/unread is per thread; forward attachments use the JSON `raw` path only (refuse > 20 MB); inline `cid:` images are not re-attached on forward (their `<img>` is removed from the quoted HTML, the part is offered as a normal attachment); "Today" = threads with a message **received into INBOX today** (device time zone).

---

## 1. Tooling & project layout

### 1.1 Toolchain

| Item | Value |
|---|---|
| Xcode | **26.6 (17F113)** now (Swift 6.3, iOS 26.5 SDK); bump to 27.0 when the `macos-26` GitHub image ships it GA `[tooling §3.1]`. |
| Deployment target | **iOS 17.0** — every stage-1 API is ≤ iOS 17 `[ios-platform §0]`. |
| Project generator | **XcodeGen 2.46.0**; `project.yml` committed, `minimail.xcodeproj/` git-ignored and regenerated `[tooling §1]`. |
| Swift mode | App: `SWIFT_VERSION = 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Package: tools-version 6.1, language mode 6, nonisolated default `[tooling §3.3]`. |
| Build/test | `xcodebuild` + `xcbeautify 3.2.1`; destination `platform=iOS Simulator,name=iPhone 17` (no iPhone 16 on the runner runtimes `[tooling §2.2]`); `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` for simulator builds. |
| Core tests | `cd Packages/MailCore && swift test` on Linux (Swift 6.1+ toolchain; `swift:6.1` Docker tag UNVERIFIED `[tooling §7.4]`) and on macOS. |
| Formatting | `swift format` (bundled). No SwiftLint. `make lint` also greps the package boundary and the raw-colour rule (§1.6). |
| Distribution | Apple Developer Program + TestFlight, `xcodebuild archive` / `-exportArchive … destination=upload` with an App Store Connect API key `[tooling §6.2]`. |

### 1.2 Dependencies (exact pins)

| Package | Version | Product | Linked by |
|---|---|---|---|
| `https://github.com/openid/AppAuth-iOS` | `3.0.0` | `AppAuth` | app (`Auth/`) |
| `https://github.com/groue/GRDB.swift` | `7.11.1` | `GRDB` | app (`Store/`) |
| `https://github.com/scinfu/SwiftSoup` | `2.13.9` | `SwiftSoup` | `MailHTML` only |
| `Packages/MailCore` (local) | — | `MailCore`, `MailHTML` | app, `minimailTests` |

### 1.3 Folder tree (every file)

```
minimail/                                  # repo root
├── PLAN.md
├── project.yml                            # XcodeGen spec (§1.4) — complete, no deltas
├── Makefile                               # §1.6
├── .gitignore                             # minimail.xcodeproj/, .build/, DerivedData/, *.xcresult
├── .swift-format                          # tooling §5.1
├── ExportOptions.plist                    # tooling §6.2
├── Config/
│   ├── Signing.xcconfig                   # DEVELOPMENT_TEAM = REPLACE_WITH_TEAM_ID ; #include "Google.xcconfig"
│   └── Google.xcconfig                    # GOOGLE_CLIENT_ID = REPLACE.apps.googleusercontent.com ; GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.REPLACE
├── .github/workflows/ci.yml               # jobs: core (ubuntu, swift test) + ios (macos-26, xcodebuild test)
├── docs/plan/…                            # this document, research, device-checklist.md (written in M2)
│
├── Packages/MailCore/
│   ├── Package.swift                      # §1.5
│   ├── Sources/MailCore/                  # Foundation only; nonisolated; all public types Sendable
│   │   ├── Encoding/Base64URL.swift
│   │   ├── Encoding/QuotedPrintable.swift
│   │   ├── Encoding/RFC2047.swift
│   │   ├── Encoding/RFC2231.swift
│   │   ├── Encoding/Charsets.swift        # IANA name → String.Encoding table (no CoreFoundation)
│   │   ├── Headers/Mailbox.swift          # struct + serializer
│   │   ├── Headers/AddressParser.swift    # RFC 5322 §3.4 tokenizer
│   │   ├── Headers/HeaderDate.swift       # RFC 5322 date format/parse + attribution format
│   │   ├── Headers/HeaderFolding.swift
│   │   ├── Headers/ContentTypeParams.swift
│   │   ├── Headers/MessageIDs.swift
│   │   ├── Gmail/GmailDTO.swift           # Codable mirrors of the Discovery shapes; StringUInt64/StringInt64
│   │   ├── Gmail/MessageParser.swift      # GmailMessage → ParsedMessage (headers, body walk, attachments)
│   │   ├── Gmail/BatchCodec.swift         # multipart/mixed request encoder + response parser
│   │   ├── MIME/OutgoingMessage.swift
│   │   ├── MIME/MIMEBuilder.swift
│   │   ├── Compose/ComposeStyle.swift
│   │   ├── Compose/ReplyAll.swift
│   │   ├── Compose/SubjectPrefix.swift
│   │   ├── Compose/Quoting.swift          # QuoteSource, attribution, gmail_quote / forward banner, text quoting
│   │   ├── Compose/OutgoingBodies.swift   # typed text + style + signature + quote → (text, html)
│   │   ├── Compose/PlainTextHTML.swift    # escape + linkify + <div> per line
│   │   ├── Render/ThreadDocument.swift    # thread → one self-contained HTML document (template + CSS)
│   │   ├── Sync/LabelAlgebra.swift        # LabelDelta, effective(server:pending:), flags, sortedJSON
│   │   ├── Sync/HistoryReducer.swift
│   │   ├── Sync/HydrationPolicy.swift
│   │   ├── Sync/OutboxCoalescer.swift     # merge(existing:new:)
│   │   ├── Sync/Backoff.swift
│   │   ├── Sync/ThreadAggregator.swift    # [AggregateInput] → ThreadAggregate
│   │   └── Support/DayBoundary.swift      # today range in a TZ; row date labels
│   ├── Sources/MailHTML/                  # imports MailCore + SwiftSoup
│   │   ├── Sanitizer.swift                # allowlist pipeline (§9.1), size guard, fromPlainText bridge
│   │   ├── StyleScrubber.swift
│   │   ├── TrackingPixel.swift
│   │   ├── DarkStrategyClassifier.swift
│   │   ├── SignatureSanitizer.swift
│   │   └── QuoteExtractor.swift           # sanitized fragment → quotable HTML (data-src restore, cid img removal)
│   └── Tests/
│       ├── MailCoreTests/                 # one test file per source file + Fixtures/ (§13.2)
│       │   └── Fixtures/                  # gmail/*.json, mime/*.eml + .sha256, vectors/*.json
│       └── MailHTMLTests/
│           └── Fixtures/html/*.html
│
├── minimail/                              # app target (MainActor default)
│   ├── Info.plist                         # GENERATED by xcodegen — never hand-edit
│   ├── minimail.entitlements              # generated, empty
│   ├── App/
│   │   ├── MinimailApp.swift              # @main; scene; .backgroundTask; .onOpenURL; scenePhase → triggers
│   │   ├── AppEnvironment.swift           # composition root (§2.3); launch order (§12.2)
│   │   ├── RootView.swift                 # signed-out vs signed-in switch; reauth banner host
│   │   ├── BackgroundRefresh.swift
│   │   └── Maintenance.swift              # once-per-24h cleanup (§4.9)
│   ├── Auth/
│   │   ├── OAuthConfig.swift              # endpoints, scope, client id from Info.plist, redirect URL
│   │   ├── TokenProvider.swift            # protocol
│   │   ├── AppAuthTokenProvider.swift     # actor; owns OIDAuthState; single-flight refresh
│   │   ├── AuthStore.swift                # @Observable state machine + sign-in presentation
│   │   └── Keychain.swift                 # 4 static funcs (exists/set/get/delete)
│   ├── Gmail/
│   │   ├── GmailClient.swift              # actor; one func per endpoint; batching; retry
│   │   ├── GmailError.swift
│   │   ├── RequestLimiter.swift           # actor semaphore(2)
│   │   └── RequestLog.swift               # DEBUG ring buffer (100 entries) for Settings → Advanced
│   ├── Store/
│   │   ├── Database.swift                 # open pool, migrate, file protection, destroy, in-memory for tests
│   │   ├── Schema.swift                   # migration "v1": verbatim DDL of §3.2
│   │   ├── Records.swift                  # LabelRecord, ThreadRecord, ThreadLabelRecord, MessageRecord, MessageBodyRecord, AttachmentRecord, OutboxRecord, SyncStateRecord
│   │   ├── Queries.swift                  # ThreadQuery → SQL; ThreadRow projection; thread detail; labels; outbox; counts
│   │   ├── MessageRepository.swift        # upsertMetadata, applyServerLabels/Delta, recomputeEffective, delete
│   │   ├── ThreadRepository.swift         # recomputeAggregates, markComplete, messageIds
│   │   ├── BodyRepository.swift           # storeBody, missingBodyIds, attachments
│   │   ├── LabelRepository.swift
│   │   ├── OutboxRepository.swift         # enqueueModify (coalescing), enqueueSend, claim, ack, retryLater, fail, discard, releaseInFlight, rearmFailed
│   │   └── SyncStateRepository.swift
│   ├── Sync/
│   │   ├── SyncEngine.swift               # actor: run(reason), fullSync, deltaSync, hydrate, ensureThreadLoaded, labels, badge
│   │   ├── Outbox.swift                   # actor: kick/drain, modify batches, performSend
│   │   ├── MailActions.swift              # MainActor façade: archive/markRead/markUnread/send
│   │   └── SyncStatus.swift               # @Observable: phase, offline, lastError, outbox counts
│   ├── Web/
│   │   ├── WebViewHost.swift              # pooled WKWebView, configuration factory, rule lists, warm/recycle
│   │   ├── MailWebView.swift              # UIViewRepresentable
│   │   ├── WebBridge.swift                # WKScriptMessageHandler → WebMessage
│   │   ├── CIDSchemeHandler.swift         # minimail-cid:// → InlineImageStore
│   │   ├── InlineImageStore.swift         # actor: cache + attachments.get with re-resolve, 2 in flight, failure cache
│   │   └── LinkPolicy.swift               # WKNavigationDelegate
│   ├── Features/
│   │   ├── SignIn/SignInScreen.swift
│   │   ├── Inbox/InboxScreen.swift
│   │   ├── Inbox/InboxModel.swift
│   │   ├── Inbox/ThreadRowView.swift
│   │   ├── Inbox/StatusBanner.swift       # offline / error / reauth / failed-send rows
│   │   ├── Thread/ThreadScreen.swift
│   │   ├── Thread/ThreadModel.swift
│   │   ├── Thread/AttachmentOpener.swift  # download (stored id, re-resolve on 404) → QuickLook
│   │   ├── Compose/ComposeScreen.swift
│   │   ├── Compose/ComposeModel.swift
│   │   ├── Labels/LabelsScreen.swift
│   │   ├── Labels/LabelsModel.swift
│   │   ├── Settings/Settings.swift        # Codable struct (§11)
│   │   ├── Settings/SettingsStore.swift
│   │   ├── Settings/SettingsScreen.swift
│   │   └── Settings/SignatureEditorScreen.swift
│   ├── Theme/
│   │   ├── Theme.swift                    # protocol, ThemeTokens, LightTheme, DarkTheme, registry
│   │   └── ThemeStore.swift
│   ├── Support/
│   │   ├── Log.swift                      # os.Logger categories + OSSignposter intervals
│   │   └── Formatters.swift               # byte counts
│   └── Resources/
│       ├── Assets.xcassets/               # AppIcon, AccentColor, LaunchBackground (light/dark variants)
│       └── PrivacyInfo.xcprivacy          # NSPrivacyAccessedAPICategoryUserDefaults CA92.1
│
└── minimailTests/
    ├── Support/StubURLProtocol.swift      # (method, path) → scripted responses
    ├── Support/TestDatabase.swift         # in-memory DatabaseQueue + migrations + seed helpers
    ├── Support/InvariantChecks.swift      # §3.5 invariants, run after every repository/sync test
    ├── Support/FixtureLoader.swift        # loads the package fixtures copied into the bundle
    ├── Store/DatabaseTests.swift
    ├── Store/RepositoryTests.swift
    ├── Store/QueriesTests.swift
    ├── Sync/SyncEngineTests.swift
    ├── Sync/ResyncTests.swift
    ├── Sync/OutboxTests.swift
    ├── Sync/ConflictTests.swift
    ├── Sync/SendTests.swift
    ├── Gmail/GmailClientTests.swift
    ├── Auth/KeychainTests.swift
    ├── Web/WebViewHostTests.swift
    └── SmokeTests.swift
```

≈ 75 app files, ≈ 30 package source files. Anything not in this tree is not part of stage 1.

### 1.4 `project.yml` (complete)

```yaml
name: minimail
options:
  minimumXcodeGenVersion: 2.46.0
  bundleIdPrefix: de.newtelco
  deploymentTarget: { iOS: "17.0" }
  xcodeVersion: "26.6"
  createIntermediateGroups: true
  generateEmptyDirectories: true
  developmentLanguage: en
configs: { Debug: debug, Release: release }
configFiles:
  Debug: Config/Signing.xcconfig          # Signing.xcconfig does `#include "Google.xcconfig"`
  Release: Config/Signing.xcconfig
settings:
  base:
    SWIFT_VERSION: "6"
    SWIFT_STRICT_CONCURRENCY: complete
    SWIFT_APPROACHABLE_CONCURRENCY: YES
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    SWIFT_TREAT_WARNINGS_AS_ERRORS: NO
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    TARGETED_DEVICE_FAMILY: "1"
    SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGN_STYLE: Automatic
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    SWIFT_EMIT_LOC_STRINGS: YES
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
  configs:
    debug:   { SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG, ONLY_ACTIVE_ARCH: YES }
    release: { SWIFT_COMPILATION_MODE: wholemodule }
packages:
  AppAuth:  { url: https://github.com/openid/AppAuth-iOS, exactVersion: 3.0.0 }
  GRDB:     { url: https://github.com/groue/GRDB.swift,   exactVersion: 7.11.1 }
  MailCore: { path: Packages/MailCore }
targets:
  minimail:
    type: application
    platform: iOS
    sources:
      - path: minimail
        excludes: ["**/*.md", "Info.plist", "minimail.entitlements"]
    dependencies:
      - { package: AppAuth,  product: AppAuth }
      - { package: GRDB,     product: GRDB }
      - { package: MailCore, product: MailCore }
      - { package: MailCore, product: MailHTML }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.newtelco.minimail
        PRODUCT_NAME: minimail
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: minimail/Info.plist
      properties:
        CFBundleDisplayName: minimail
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSApplicationCategoryType: public.app-category.productivity
        UILaunchScreen: { UIColorName: LaunchBackground }   # theme-matched colour asset → no white flash
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false }
        ITSAppUsesNonExemptEncryption: false
        BGTaskSchedulerPermittedIdentifiers: [de.newtelco.minimail.refresh]
        UIBackgroundModes: [fetch]
        GoogleClientID: $(GOOGLE_CLIENT_ID)                  # read by OAuthConfig.fromInfoPlist()
        CFBundleURLTypes:
          - CFBundleTypeRole: Editor
            CFBundleURLName: de.newtelco.minimail.oauth
            CFBundleURLSchemes: [$(GOOGLE_REVERSED_CLIENT_ID)]
    entitlements: { path: minimail/minimail.entitlements, properties: {} }
    scheme:
      testTargets: [minimailTests]
      gatherCoverageData: true
      environmentVariables: { MINIMAIL_TESTING: "1" }
  minimailTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: minimailTests
      - path: Packages/MailCore/Tests/MailCoreTests/Fixtures
        type: folder
        buildPhase: resources
    dependencies:
      - { target: minimail }
      - { package: MailCore, product: MailCore }
      - { package: MailCore, product: MailHTML }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.newtelco.minimailTests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/minimail.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/minimail
        BUNDLE_LOADER: $(TEST_HOST)
```

Facts: `CFBundleURLSchemes` = reversed client id, single-slash redirect path `[gmail-api gotcha 19]`; `UIBackgroundModes: fetch` + `BGTaskSchedulerPermittedIdentifiers` for `BGAppRefreshTask` `[ios-platform §3.1]`; `GoogleClientID` is a plain custom Info.plist key (a made-up `INFOPLIST_KEY_*` setting is ignored by Xcode). If XcodeGen rejects the `type: folder` fixture entry, fall back to a `sources` entry with `excludes: ["**/*.swift"]`.

### 1.5 `Packages/MailCore/Package.swift`

```swift
// swift-tools-version: 6.1
import PackageDescription

// Fallback if SwiftSoup does not build on Linux (UNVERIFIED): `MAILCORE_SKIP_HTML=1 swift test` omits MailHTML.
let includeHTML = Context.environment["MAILCORE_SKIP_HTML"] == nil

var products: [Product] = [.library(name: "MailCore", targets: ["MailCore"])]
var targets: [Target] = [
    .target(name: "MailCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "MailCoreTests", dependencies: ["MailCore"], resources: [.copy("Fixtures")]),
]
var dependencies: [Package.Dependency] = []
if includeHTML {
    products.append(.library(name: "MailHTML", targets: ["MailHTML"]))
    dependencies.append(.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"))
    targets += [
        .target(name: "MailHTML", dependencies: ["MailCore", "SwiftSoup"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MailHTMLTests", dependencies: ["MailHTML"], resources: [.copy("Fixtures")]),
    ]
}
let package = Package(name: "MailCore", platforms: [.iOS(.v17), .macOS(.v14)],
                      products: products, dependencies: dependencies, targets: targets)
```

Rules: `MailCore` imports only `Foundation` (no CoreFoundation, UIKit, SwiftUI, GRDB, AppAuth, WebKit, Security); `MailHTML` adds `SwiftSoup`. Fixtures live **inside** each test target directory (SwiftPM rejects resources outside the target). Regexes: Swift `Regex` literals or `NSRegularExpression` only where Linux Foundation agrees (both are used by the research snippets; `StyleScrubber` uses `NSRegularExpression`, which exists on Linux Foundation).

### 1.6 `Makefile`

```make
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
```

Commands and flags from `[tooling §2.3–§2.7]`. Agent loop: edit → `make core-test` (Linux, fast) for package changes → `make build` / `make test-app` on the macOS runner for app changes → CI runs both jobs.

### 1.7 CI (`.github/workflows/ci.yml`)

- Job `core` on `ubuntu-latest`: `swift-actions/setup-swift` (Swift 6.1) → `make core-test`; if it fails only because SwiftSoup does not compile on Linux, the job runs `make core-test-nohtml` (documented fallback; `MailHTMLTests` then run on macOS only).
- Job `ios` on `macos-26`, `maxim-lobanov/setup-xcode@v1` with `'26.6'`, `brew install xcodegen`, cache `.build/SourcePackages` keyed on `project.yml` + `Package.swift`, then `make core-test` (always — the macOS run of the package tests is the safety net for the Linux job) and `make test-app` `[tooling §4]`.
- No launch-metric gate, no UI-test job.

---

## 2. Module map and public interfaces

### 2.1 Dependency direction

```
Features/*  ──►  Sync (SyncEngine, Outbox, MailActions, SyncStatus)  ──►  Gmail (GmailClient)  ──►  Auth (TokenProvider)
   │  │  │             │
   │  │  └──►  Store (Database, Records, Queries, *Repository) ◄─ Sync writes; GmailClient never touches the DB
   │  └─────►  Web (WebViewHost, MailWebView, WebBridge, CIDSchemeHandler, InlineImageStore, LinkPolicy) ──► Gmail (attachments.get only)
   └────────►  Theme, Settings, Support
App/ (AppEnvironment, MinimailApp, RootView, BackgroundRefresh, Maintenance) owns every object above and injects them via the environment.
Everything ──►  MailCore / MailHTML  (pure; import nothing from the app)
```

Rules (`make lint` checks the package boundary and the raw-colour rule):
1. `MailCore` imports only Foundation; `MailHTML` imports MailCore + SwiftSoup.
2. `Gmail/` never imports GRDB; `Store/` never imports AppAuth/WebKit; `Features/` never call `URLSession` or `GmailClient` directly — exceptions: `Web/InlineImageStore` and `Features/Thread/AttachmentOpener` call `GmailClient.getAttachment`/`getMessage` (downloads for display).
3. Only `Store/*Repository.swift` contain `INSERT/UPDATE/DELETE`; only `Store/Queries.swift` contains `SELECT`s used by the UI.
4. Sanitising and MIME building never run inside `pool.write { }` (the single writer lock is held only for SQL).
5. Isolation: `Features`, `Theme`, `Settings`, `Web`, `AuthStore`, `SyncStatus`, `AppEnvironment` are `@MainActor` (implicit); `AppAuthTokenProvider`, `GmailClient`, `SyncEngine`, `Outbox`, `InlineImageStore`, `RequestLimiter` are `actor`s; packages are nonisolated.

### 2.2 `MailCore` public interface

```swift
// Encoding/Base64URL.swift
public enum Base64URL {
    public static func encode(_ data: Data) -> String          // RFC 4648 §5, single line, WITH '=' padding [mime-rfc §1.2]
    public static func decode(_ string: String) -> Data?       // padded/unpadded, both alphabets; nil on other chars
}
// Encoding/QuotedPrintable.swift
public enum QuotedPrintable {
    public static func encode(_ utf8: Data) -> Data            // input already CRLF; 76-col soft breaks; uppercase hex; trailing WSP encoded
    public static func decode(_ data: Data) -> Data            // tolerant
}
// Encoding/RFC2047.swift
public enum RFC2047 {
    public static func decode(_ headerValue: String) -> String                     // B/Q, LWSP between adjacent words dropped, bytes of adjacent same-charset words concatenated, unknown charset left as-is
    public static func encodeIfNeeded(_ text: String, firstLineOffset: Int) -> String   // ASCII passthrough; else UTF-8 B-words ≤ 75 chars joined with CRLF SPACE
}
// Encoding/RFC2231.swift
public enum RFC2231 {
    public static func parameter(named: String, in params: [(String, String)]) -> String?   // continuations, charset'lang'%xx, extended wins
    public static func encodeFilenameParams(_ filename: String) -> String                    // `filename="ascii"; filename*=UTF-8''%…` when non-ASCII
}
// Encoding/Charsets.swift — pure table: utf-8, us-ascii, iso-8859-1/2/15, windows-1250/1252, koi8-r, shift_jis, euc-jp, iso-2022-jp, gb2312/gbk, big5 (+ aliases)
public enum Charsets {
    public static func encoding(forIANA name: String) -> String.Encoding?   // strips "*lang", case-insensitive
    public static func decode(_ data: Data, charset: String?) -> String      // charset → utf8 → isoLatin1 (never fails)
}
// Headers/Mailbox.swift
public struct Mailbox: Sendable, Hashable, Codable {
    public var name: String?; public var addr: String
    public init(name: String?, addr: String)
    public var key: String { addr.lowercased() }
    public var displayName: String { name ?? addr }
    public func serialized() -> String                          // `Name <addr>` quoted or RFC 2047-encoded as needed
}
// Headers/AddressParser.swift
public enum AddressParser {
    public static func parseList(_ headerValue: String) -> [Mailbox]   // RFC 5322 §3.4 tokenizer: quoted-string, nested comments, groups flattened, obs-route dropped, legacy "addr (Name)", encoded-words decoded; never throws
    public static func parseFirst(_ headerValue: String) -> Mailbox?
}
// Headers/HeaderDate.swift
public enum HeaderDate {
    public static func rfc5322(_ date: Date, timeZone: TimeZone) -> String       // "Fri, 11 Sep 2026 10:00:00 +0200" (en_US_POSIX)
    public static func parse(_ value: String) -> Date?                          // tolerant of obsolete forms
    public static func attribution(_ date: Date, timeZone: TimeZone) -> String  // "Thu, Sep 10, 2026 at 9:12\u{202F}AM" [mime-rfc §4.1]
}
// Headers/HeaderFolding.swift
public enum HeaderFolding {
    public static func unfold(_ raw: String) -> String
    public static func foldAddressList(_ list: [Mailbox], fieldName: String) -> String   // ≤ 78 per line, CRLF SP after commas
    public static func foldMessageIDs(_ ids: [String], fieldName: String) -> String
}
// Headers/ContentTypeParams.swift
public struct ContentTypeValue: Sendable, Equatable { public var type: String; public var params: [(String, String)]; public func param(_ name: String) -> String? }
public enum ContentTypeParams { public static func parse(_ headerValue: String) -> ContentTypeValue }
// Headers/MessageIDs.swift
public enum MessageIDs {
    public static func split(_ referencesValue: String) -> [String]           // "<a> <b>" → ["<a>","<b>"], junk tokens dropped
    public static func normalize(_ id: String) -> String?                    // ensures <…>, trims
    public static func generate(domain: String, uuid: UUID = UUID()) -> String   // "<UUID@domain>"
    public static func referencesChain(parentReferences: [String], parentInReplyTo: String?, parentMessageID: String?) -> [String]  // RFC 5322 §3.6.4, deduped in order
}

// Gmail/GmailDTO.swift — Codable mirrors of the Discovery shapes [gmail-api]; everything optional except ids
public struct StringUInt64: Codable, Sendable, Equatable, Comparable { public var value: UInt64 }   // decodes JSON string OR number
public struct StringInt64:  Codable, Sendable, Equatable, Comparable { public var value: Int64 }
public struct GmailProfile: Codable, Sendable { public var emailAddress: String; public var historyId: StringUInt64 }
public struct GmailLabelColor: Codable, Sendable { public var textColor: String?; public var backgroundColor: String? }
public struct GmailLabel: Codable, Sendable {
    public var id: String; public var name: String; public var type: String?
    public var messageListVisibility: String?; public var labelListVisibility: String?
    public var messagesTotal: Int?; public var messagesUnread: Int?; public var threadsTotal: Int?; public var threadsUnread: Int?
    public var color: GmailLabelColor?
}
public struct GmailListLabelsResponse: Codable, Sendable { public var labels: [GmailLabel]? }
public struct GmailHeader: Codable, Sendable { public var name: String; public var value: String }
public struct GmailPartBody: Codable, Sendable { public var attachmentId: String?; public var size: Int?; public var data: String? }
public struct GmailPart: Codable, Sendable {
    public var partId: String?; public var mimeType: String?; public var filename: String?
    public var headers: [GmailHeader]?; public var body: GmailPartBody?; public var parts: [GmailPart]?
    public func header(_ name: String) -> String?              // case-insensitive, first match, unfolded
}
public struct GmailMessage: Codable, Sendable {
    public var id: String; public var threadId: String?; public var labelIds: [String]?; public var snippet: String?
    public var historyId: StringUInt64?; public var internalDate: StringInt64?; public var sizeEstimate: Int?; public var payload: GmailPart?
}
public struct GmailThread: Codable, Sendable { public var id: String; public var historyId: StringUInt64?; public var snippet: String?; public var messages: [GmailMessage]? }
public struct GmailMessageRef: Codable, Sendable, Equatable { public var id: String; public var threadId: String?; public var labelIds: [String]? }
public struct GmailListMessagesResponse: Codable, Sendable { public var messages: [GmailMessageRef]?; public var nextPageToken: String?; public var resultSizeEstimate: Int? }
public struct GmailHistoryMessageChange: Codable, Sendable { public var message: GmailMessageRef }
public struct GmailHistoryLabelChange: Codable, Sendable { public var message: GmailMessageRef; public var labelIds: [String]? }
public struct GmailHistory: Codable, Sendable {
    public var id: StringUInt64
    public var messagesAdded: [GmailHistoryMessageChange]?; public var messagesDeleted: [GmailHistoryMessageChange]?
    public var labelsAdded: [GmailHistoryLabelChange]?;     public var labelsRemoved: [GmailHistoryLabelChange]?
}
public struct GmailListHistoryResponse: Codable, Sendable { public var history: [GmailHistory]?; public var nextPageToken: String?; public var historyId: StringUInt64? }
public struct GmailSendAs: Codable, Sendable { public var sendAsEmail: String; public var displayName: String?; public var signature: String?; public var isPrimary: Bool?; public var isDefault: Bool?; public var verificationStatus: String? }
public struct GmailListSendAsResponse: Codable, Sendable { public var sendAs: [GmailSendAs]? }
public struct GmailModifyRequest: Encodable, Sendable { public var addLabelIds: [String]?; public var removeLabelIds: [String]? }
public struct GmailSendRequest: Encodable, Sendable { public var raw: String; public var threadId: String? }
public struct GmailErrorEnvelope: Codable, Sendable {
    public struct Item: Codable, Sendable { public var reason: String?; public var message: String? }
    public struct Inner: Codable, Sendable { public var code: Int?; public var message: String?; public var status: String?; public var errors: [Item]? }
    public var error: Inner
    public var primaryReason: String? { error.errors?.first?.reason }
}
public enum GmailFormat: String, Sendable { case minimal, full, raw, metadata }
public let gmailMetadataHeaders = ["From", "To", "Cc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References"]

// Gmail/MessageParser.swift
public struct ParsedHeaders: Sendable, Equatable {
    public var from: Mailbox?; public var to: [Mailbox]; public var cc: [Mailbox]; public var replyTo: [Mailbox]
    public var subject: String; public var messageID: String?; public var inReplyTo: String?; public var references: [String]
}
public struct ParsedAttachment: Sendable, Equatable {
    public var partId: String; public var filename: String; public var mimeType: String; public var size: Int
    public var contentId: String?      // without <>
    public var attachmentId: String?
    public var inlineData: Data?       // small parts delivered inline
}
public struct ParsedBody: Sendable, Equatable {
    public var html: String?; public var text: String?
    public var deferredTextParts: [ParsedAttachment]   // text parts delivered by attachmentId only (rare)
}
public struct ParsedMessage: Sendable, Equatable {
    public var id: String; public var threadId: String; public var historyId: UInt64; public var internalDate: Int64
    public var labelIds: [String]; public var snippet: String          // snippet HTML-entity-decoded
    public var headers: ParsedHeaders
    public var topMimeType: String?                                     // payload.mimeType (present in format=metadata)
    public var body: ParsedBody?                                        // nil for metadata/minimal
    public var attachments: [ParsedAttachment]                          // every fetchable part (incl. inline images)
}
public enum MessageParser {
    public static func parse(_ message: GmailMessage) -> ParsedMessage   // works for metadata and full [mime-rfc §5.2, §5.5]
    public static func decodeText(_ part: GmailPart) -> String?          // base64url → charset → "\n" line endings
}

// Gmail/BatchCodec.swift [gmail-api §12]
public struct BatchCall: Sendable, Equatable { public var id: String; public var method: String; public var path: String; public var jsonBody: Data? }
public struct BatchPartResponse: Sendable, Equatable { public var id: String; public var status: Int; public var body: Data }
public enum BatchCodec {
    public static func encode(_ calls: [BatchCall], boundary: String) -> Data
    public static func boundary(fromContentType ct: String) -> String?
    public static func decode(body: Data, boundary: String) throws -> [BatchPartResponse]   // split on CRLF--boundary; inner status line; Content-ID "<response-ID>"; order-independent
}

// MIME/OutgoingMessage.swift + MIMEBuilder.swift [mime-rfc §1.3, §3, §7]
public struct OutgoingAttachment: Sendable, Equatable { public var filename: String; public var mimeType: String; public var data: Data }
public struct OutgoingMessage: Sendable, Equatable {
    public var from: Mailbox; public var to: [Mailbox]; public var cc: [Mailbox]
    public var subject: String; public var date: Date; public var timeZone: TimeZone
    public var messageID: String; public var inReplyTo: String?; public var references: [String]
    public var textBody: String; public var htmlBody: String           // htmlBody = full <html> document
    public var attachments: [OutgoingAttachment]
}
public struct BoundaryGenerator: Sendable {
    public static let random: BoundaryGenerator                          // "=_minimail_<kind>_<16 hex>"
    public static func fixed(alt: String, mixed: String) -> BoundaryGenerator
    public func boundary(kind: String) -> String
}
public enum MIMEBuilder {
    /// CRLF; header order From, To, Cc?, Subject, Date, Message-ID, In-Reply-To?, References?, MIME-Version, Content-Type;
    /// structure A (alternative: plain then html, QP) or B (mixed ⊃ A + base64 76-col attachments, RFC 2231 names).
    public static func build(_ m: OutgoingMessage, boundaries: BoundaryGenerator = .random) -> Data
}

// Compose/*
public struct ComposeStyle: Codable, Equatable, Sendable {
    public enum Family: String, Codable, CaseIterable, Sendable { case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        public var css: String; public var displayName: String }         // stacks from [html-rendering §5.3]
    public var family: Family = .helvetica
    public var sizePx: Int = 14                                            // clamped 12…18
    public var colorHex: String = "#000000"                                // ^#[0-9a-f]{6}$
    public var inlineCSS: String { "font-family:\(family.css);font-size:\(sizePx)px;color:\(colorHex)" }
    public init()
}
public struct SelfIdentity: Sendable, Equatable { public var primary: Mailbox; public var allAddresses: Set<String> }   // lowercased addr-specs
public struct Recipients: Sendable, Equatable { public var to: [Mailbox]; public var cc: [Mailbox] }
public enum ReplyAll { public static func recipients(from: Mailbox?, replyTo: [Mailbox], to: [Mailbox], cc: [Mailbox], me: SelfIdentity) -> Recipients }   // §7.1
public enum SubjectPrefix {
    public static func reply(_ s: String) -> String            // "Re: " unless hasPrefix("re:") case-insensitively
    public static func forward(_ s: String) -> String          // "Fwd: " unless hasPrefix("fwd:")
    public static func stripForDisplay(_ s: String) -> String  // repeated re:/fwd:/fw:/aw:/wg: → thread title
}
public enum ComposeMode: String, Codable, Sendable { case replyAll, forward }
public struct QuoteSource: Codable, Sendable, Equatable {      // snapshot of the original taken at compose time
    public var author: Mailbox?; public var date: Date; public var subject: String
    public var to: [Mailbox]; public var cc: [Mailbox]
    public var html: String?     // quotable HTML (QuoteExtractor output) — data-src restored, cid <img> removed, mm-* classes removed
    public var text: String?     // plain text alternative
}
public enum Quoting {
    public static func attributionLine(author: Mailbox?, date: Date, timeZone: TimeZone) -> String
    public static func replyHTML(_ q: QuoteSource, timeZone: TimeZone) -> String     // gmail_quote_container + gmail_attr + blockquote [mime-rfc §4.1]
    public static func replyText(_ q: QuoteSource, timeZone: TimeZone) -> String     // attribution + "> " lines (">" for empty lines)
    public static func forwardHTML(_ q: QuoteSource, timeZone: TimeZone) -> String   // "---------- Forwarded message ---------" banner, body not blockquoted [mime-rfc §4.2]
    public static func forwardText(_ q: QuoteSource, timeZone: TimeZone) -> String
    public static func textFromHTML(_ html: String) -> String                          // crude tag strip + entity decode
}
public enum OutgoingBodies {
    public static func escape(_ s: String) -> String
    /// <div dir="ltr" class="minimail_default" style="{inlineCSS}"> one <div> per line </div> [+ signature block] + quote OUTSIDE the wrapper [html-rendering §5.5]
    public static func html(typed: String, style: ComposeStyle, signatureHTML: String?, quoteHTML: String?) -> String
    public static func document(bodyFragment: String) -> String     // <html><head><meta charset="utf-8"></head><body>…</body></html>, no color-scheme meta
    public static func text(typed: String, signatureText: String?, quoteText: String?) -> String   // typed, blank, "-- " + sig, blank, quote
}
public enum PlainTextHTML { public static func convert(_ text: String) -> String }   // escape, linkify https?:// and www., <div> per line, wrapped in <div class="mm-plaintext">

// Render/ThreadDocument.swift (§9.2 template; pure string building)
public struct ThreadDocumentMessage: Sendable, Equatable {
    public var id: String; public var fromName: String; public var fromAddr: String
    public var toLine: String; public var ccLine: String?; public var dateLabel: String; public var dateFull: String
    public var snippet: String; public var isUnread: Bool; public var expanded: Bool
    public var bodyHTML: String?                  // nil → skeleton "Loading…"; "unavailable" state via bodyState
    public var bodyState: Int                     // 0 loading, 1 cached, 2 unavailable
    public var darkStrategy: String               // "plain" | "card" | "native"
    public var hasRemoteImages: Bool; public var imagesAllowed: Bool
    public var attachments: [(partId: String, filename: String, sizeLabel: String)]
}
public struct ThemeCSSTokens: Sendable, Equatable {   // hex strings resolved by the app per scheme
    public var background, surface, text, secondaryText, accent, separator, link, cardBackground: String
}
public enum ThreadDocument {
    public static let maxBodyBytes = 1_500_000          // per body: truncated + "Message truncated" note
    public static let maxDocumentBytes = 6_000_000      // beyond: oldest collapsed messages become previews only
    public static func render(subject: String, messages: [ThreadDocumentMessage], light: ThemeCSSTokens, dark: ThemeCSSTokens,
                              forcedScheme: String?, imagesAllowed: Bool) -> String   // forcedScheme "light"|"dark"|nil → html[data-theme]
    public static func empty(light: ThemeCSSTokens, dark: ThemeCSSTokens) -> String     // warm-up / recycle document
    public static func toggleScript(messageId: String) -> String                        // classList.toggle('mm-collapsed') on section[data-id]
}

// Sync/LabelAlgebra.swift
public struct LabelDelta: Codable, Sendable, Equatable {
    public var add: Set<String>; public var remove: Set<String>
    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
    public func applied(to labels: Set<String>) -> Set<String>     // (labels − remove) ∪ add
}
public struct DerivedFlags: Sendable, Equatable { public var isUnread: Bool; public var inInbox: Bool; public var isHidden: Bool }
public enum LabelAlgebra {
    public static func effective(server: Set<String>, pending: [LabelDelta]) -> Set<String>   // fold applied(to:) in order
    public static func flags(_ labels: Set<String>) -> DerivedFlags   // hidden = TRASH ∨ SPAM ∨ DRAFT ∨ CHAT
    public static func sortedJSON(_ labels: Set<String>) -> String
    public static func userVisible(_ labels: Set<String>) -> [String] // excludes system ids (INBOX, UNREAD, SENT, DRAFT, CHAT, SPAM, TRASH, STARRED, IMPORTANT, CATEGORY_*)
}
// Sync/HistoryReducer.swift
public struct HistoryChanges: Sendable, Equatable {
    public var added: [String: GmailMessageRef]        // net of later deletes; last wins
    public var deleted: Set<String>
    public var labelOps: [String: [LabelDelta]]        // chronological per message id; excludes deleted
    public var finalLabels: [String: Set<String>]      // last message.labelIds seen in any change record
    public var touchedThreads: Set<String>
    public var recordCount: Int
    public var newHistoryId: UInt64?
}
public enum HistoryReducer { public static func reduce(_ pages: [GmailListHistoryResponse]) -> HistoryChanges }
// Sync/HydrationPolicy.swift
public struct HydrationScope: Sendable, Equatable { public var cachedLabelIds: Set<String>; public var knownThreadIds: Set<String> }
public enum HydrationPolicy { public static func shouldFetch(ref: GmailMessageRef, scope: HydrationScope) -> Bool }   // §4.3
// Sync/OutboxCoalescer.swift
public enum OutboxCoalescer { public static func merge(existing: LabelDelta, new: LabelDelta) -> LabelDelta }   // add = (e.add − n.remove) ∪ n.add; remove = (e.remove − n.add) ∪ n.remove
// Sync/Backoff.swift
public struct Backoff: Sendable, Equatable {
    public var base: TimeInterval, factor: Double, cap: TimeInterval, jitter: Double
    public func delay(attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval   // random ∈ [0,1) injected
    public static let transient: Backoff   // 1 s → 16 s cap
    public static let outbox: Backoff      // 2 s → 300 s cap
}
// Sync/ThreadAggregator.swift
public struct AggregateInput: Sendable, Equatable {   // one VISIBLE (isHidden = 0) message
    public var id: String; public var internalDate: Int64; public var subject: String; public var snippet: String
    public var fromName: String?; public var fromAddr: String; public var isFromMe: Bool
    public var isUnread: Bool; public var inInbox: Bool; public var hasAttachments: Bool; public var bodyState: Int
    public var labelIds: Set<String>
}
public struct ThreadAggregate: Sendable, Equatable {
    public var subject: String         // oldest message, prefixes stripped
    public var snippet: String         // newest message
    public var lastDate: Int64; public var lastInboxDate: Int64?
    public var messageCount: Int; public var unreadCount: Int; public var inInbox: Bool; public var hasAttachments: Bool
    public var participants: String    // "Alice, Bob, Me" — first names of distinct senders chronologically, "Me" for self, max 3 + "…"
    public var userLabelIds: [String]  // sorted union of userVisible labels
    public var allLabelIds: Set<String>   // union of every label (drives thread_label)
    public var bodiesMissing: Int
}
public enum ThreadAggregator { public static func aggregate(_ messages: [AggregateInput], selfAddresses: Set<String>) -> ThreadAggregate? }   // nil if no visible message
// Support/DayBoundary.swift
public struct DayBoundary: Sendable, Equatable {
    public let startMs: Int64; public let endMs: Int64
    public static func today(now: Date, timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian)) -> DayBoundary
    public func contains(_ epochMs: Int64) -> Bool
}
public enum RowDateLabel {
    public static func label(epochMs: Int64, now: Date, timeZone: TimeZone, locale: Locale) -> String   // "14:32" today, "Yesterday", "Mon", "11 Sep", "11.09.25" (locale-aware)
}
```

### 2.3 `MailHTML` public interface

```swift
public enum DarkStrategy: String, Sendable, Codable { case plain, card, native }
public struct SanitizedBody: Sendable, Equatable {
    public var html: String; public var hasRemoteImages: Bool; public var darkStrategy: DarkStrategy; public var referencedContentIDs: Set<String>
}
public enum Sanitizer {
    public static let version: Int = 1                     // bump → bodies re-fetched lazily on open
    public static let maxInputBytes = 2_097_152             // 2 MiB; larger → caller falls back to plain text
    public static let placeholderGIF: String                // 1×1 transparent data: URI
    public static func sanitize(html: String, messageId: String) throws -> SanitizedBody   // §9.1; throws SanitizerError.tooLarge / SwiftSoup errors
    public static func fromPlainText(_ text: String) -> SanitizedBody                     // PlainTextHTML.convert, strategy .plain
}
public enum SignatureSanitizer { public static func sanitize(_ html: String) throws -> String }   // same allowlist; keeps https img src; no placeholders
public enum QuoteExtractor { public static func quotable(_ sanitizedHTML: String) -> String }     // data-src → src, placeholder removed, mm-* classes removed, <img src="minimail-cid:…"> REMOVED
```

### 2.4 App-target interfaces

```swift
// Auth/OAuthConfig.swift
struct OAuthConfig: Sendable {
    let clientID: String                                        // "<prefix>.apps.googleusercontent.com" from Info.plist GoogleClientID
    let redirectURL: URL                                        // com.googleusercontent.apps.<prefix>:/oauth2redirect
    let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    let scopes = ["https://www.googleapis.com/auth/gmail.modify"]
    static func fromInfoPlist() -> OAuthConfig
}
// Auth/TokenProvider.swift
protocol TokenProvider: Sendable {
    func accessToken() async throws -> String       // fresh; refreshes when expired; single-flight
    func invalidateAccessToken() async              // after a 401
}
// Auth/AppAuthTokenProvider.swift
actor AppAuthTokenProvider: TokenProvider {
    init(keychainAccount: String = "oauth.authState")
    func load() async -> Bool                                        // unarchive OIDAuthState from Keychain (off main); true if authorized
    func adopt(_ state: sending OIDAuthState) async throws           // after interactive sign-in; persists; installs delegates
    func accessToken() async throws -> String
    func invalidateAccessToken() async
    func revokeAndClear() async                                      // POST /revoke (best effort, 3 s) + Keychain.delete
    var refreshToken: String? { get async }
    nonisolated let onNeedsReauth: @Sendable () -> Void              // invalid_grant → AuthStore.markNeedsReauth on main
}
enum AuthError: Error, Sendable, Equatable { case signedOut, needsReauth, userCancelled, flowFailed(String), missingRefreshToken, accountMismatch(expected: String, got: String), keychain(Int32) }
// Auth/AuthStore.swift (@MainActor by default)
@Observable final class AuthStore {
    enum State: Equatable { case signedOut, signedIn(email: String?), needsReauth(email: String?) }
    private(set) var state: State
    private(set) var lastError: String?
    var currentFlow: OIDExternalUserAgentSession?
    init(tokens: AppAuthTokenProvider, config: OAuthConfig, hasKeychainItem: Bool, cachedEmail: String?)   // synchronous routing decision (§5.2)
    func signIn() async throws                       // AppAuth flow → adopt → state .signedIn
    func signOut() async                             // §5.4
    func resume(url: URL) -> Bool                    // onOpenURL fallback
    func markNeedsReauth()                           // from token provider / GmailClient 401×2
}
// Auth/Keychain.swift  [ios-platform §5.5]
enum Keychain {
    static let service = "de.newtelco.minimail"
    static func exists(account: String) -> Bool      // SecItemCopyMatching with kSecReturnAttributes; < 5 ms
    static func set(_ data: Data, account: String) throws
    static func get(account: String) throws -> Data?
    static func delete(account: String) throws
}

// Gmail/GmailError.swift
enum GmailError: Error, Sendable, Equatable {
    case offline                                  // URLError notConnectedToInternet / networkConnectionLost / dataNotAllowed / internationalRoamingOff
    case network(code: Int)                       // other URLError (timeouts, resets)
    case unauthorized                             // 401 after one refresh, or invalid_grant
    case forbidden(reason: String?)               // 403 non-quota (admin_policy_enforced, insufficientPermissions, dailyLimitExceeded)
    case rateLimited(retryAfter: TimeInterval?)   // 429, or 403 with rateLimitExceeded / userRateLimitExceeded / concurrent
    case notFound                                 // 404 on message/thread/attachment
    case historyExpired                           // 404 on history.list, or 400 failedPrecondition / message mentioning historyId
    case badRequest(reason: String?, message: String?)
    case server(status: Int)
    case decoding(String)
    case batchMalformed
    case cancelled
    var isTransient: Bool          // offline, network, rateLimited, server, batchMalformed
    var countsAsAttempt: Bool      // everything except offline, cancelled, unauthorized
    static func map(status: Int, body: Data, headers: [AnyHashable: Any], endpoint: String) -> GmailError
    static func map(_ urlError: URLError) -> GmailError
}
// Gmail/RequestLimiter.swift
actor RequestLimiter { init(max: Int = 2); func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T }
// Gmail/GmailClient.swift
struct ThreadModifyCall: Sendable, Equatable { var opId: Int64; var threadId: String; var add: [String]; var remove: [String] }
actor GmailClient {
    static let batchChunkSize = 25
    init(tokens: any TokenProvider, session: URLSession, limiter: RequestLimiter, log: RequestLog?, sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
    func getProfile() async throws -> GmailProfile
    func listLabels() async throws -> [GmailLabel]
    func getLabels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>]                         // batch
    func listMessages(labelIds: [String], q: String?, maxResults: Int, pageToken: String?) async throws -> GmailListMessagesResponse
    func getMessage(id: String, format: GmailFormat, fields: String?) async throws -> GmailMessage
    func getMessages(ids: [String], format: GmailFormat) async throws -> [String: Result<GmailMessage, GmailError>]   // batch; metadata adds metadataHeaders + fields mask
    func getThread(id: String, format: GmailFormat) async throws -> GmailThread
    func listHistory(startHistoryId: UInt64, pageToken: String?) async throws -> GmailListHistoryResponse        // maxResults=500, all four historyTypes, fields mask
    func modifyThreads(_ calls: [ThreadModifyCall]) async throws -> [Int64: Result<GmailThread, GmailError>]        // batch of threads.modify parts, keyed by opId
    func send(raw: Data, threadId: String?) async throws -> GmailMessage                                           // JSON path; 0 automatic retries
    func getAttachment(messageId: String, attachmentId: String) async throws -> Data                               // base64url-decoded bytes
    func listSendAs() async throws -> [GmailSendAs]
}
// Gmail/RequestLog.swift (DEBUG)
final class RequestLog: Sendable { func record(method: String, path: String, status: Int, ms: Int); func snapshot() -> [String] }   // ring buffer 100

// Store/Database.swift
enum Database {
    static func open(directory: URL) throws -> DatabasePool           // Application Support/minimail-db/db.sqlite; migrates; sets .completeUntilFirstUserAuthentication on the directory
    static func openInMemory() throws -> DatabaseQueue               // tests
    static func destroy(directory: URL) throws                       // sign-out (whole directory incl. -wal/-shm)
}
// Store/Records.swift — Codable, FetchableRecord, PersistableRecord, Sendable structs; column = property name; JSON columns via .sortedKeys
struct LabelRecord, ThreadRecord, ThreadLabelRecord, MessageRecord, MessageBodyRecord, AttachmentRecord, OutboxRecord, SyncStateRecord { … §3.2 columns … }
enum OutboxKind: String, Codable { case modify, send }
enum OutboxState: String, Codable { case pending, inFlight, failed }
enum TransmitState: String, Codable { case notSent, maybeSent }
struct SendJob: Codable, Sendable, Equatable {                     // outbox.sendJob JSON
    var mode: ComposeMode; var originalMessageId: String; var threadId: String
    var messageID: String; var to: [Mailbox]; var cc: [Mailbox]; var subject: String; var typedText: String
    var inReplyTo: String?; var references: [String]
    var quoteSource: QuoteSource                                     // snapshot (never re-read from the cache at drain time)
    var attachments: [ForwardAttachmentRef]                          // forward only, user-selected
    var includeSignature: Bool
}
struct ForwardAttachmentRef: Codable, Sendable, Equatable { var partId: String; var filename: String; var mimeType: String; var size: Int; var attachmentId: String? }
enum SyncKey: String { case historyId, syncGeneration, lastFullSyncAt, lastDeltaSyncAt, lastLabelCountsAt, lastCleanupAt, accountEmail, displayName, selfAddresses, sendAsSignature, inboxNextPageToken }

// Store/Queries.swift
struct ThreadQuery: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case inbox, today(DayBoundary), label(id: String) }
    var scope: Scope; var unreadOnly: Bool; var limit: Int          // limit 60, +60 per page
}
struct ThreadRow: Identifiable, Equatable, Sendable {                // fully precomputed row projection
    var id: String; var participants: String; var subject: String; var snippet: String
    var dateLabel: String; var isUnread: Bool; var messageCount: Int; var hasAttachments: Bool
    var chips: [(id: String, name: String, textColor: String?, backgroundColor: String?)]   // ≤ 2 user labels
}
struct ThreadDetail: Sendable { var thread: ThreadRecord; var messages: [MessageRecord]; var bodies: [String: MessageBodyRecord]; var attachments: [AttachmentRecord] }
enum Queries {
    static func threads(_ q: ThreadQuery, now: Date, timeZone: TimeZone, locale: Locale, labels: [String: LabelRecord]) -> (Database) throws -> [ThreadRow]   // §8.6 SQL + row mapping (runs on the reader)
    static func threadDetail(_ db: Database, threadId: String) throws -> ThreadDetail?
    static func labelsForSheet(_ db: Database) throws -> [LabelRecord]
    static func failedSends(_ db: Database) throws -> [OutboxRecord]
    static func inboxUnreadThreadCount(_ db: Database) throws -> Int
    static func todayThreadCount(_ db: Database, _ day: DayBoundary) throws -> Int
    static func outboxCounts(_ db: Database) throws -> (pending: Int, failed: Int)
}
// Store/*Repository.swift — enums of static funcs taking GRDB `Database` so they compose inside ONE transaction
enum MessageRepository {
    static func upsertMetadata(_ db: Database, parsed: [ParsedMessage], selfAddresses: Set<String>, generation: Int, now: Int64) throws -> Set<String>   // writes S (+syncGeneration), keeps body row; recomputes E for these ids; returns touched thread ids
    static func applyServerLabels(_ db: Database, messageId: String, labels: Set<String>) throws
    static func applyServerDelta(_ db: Database, messageId: String, delta: LabelDelta) throws
    static func recomputeEffective(_ db: Database, messageIds: Set<String>) throws -> Set<String>   // E = effective(S, pending ops whose affectedMessageIds contain id); flags; returns thread ids
    static func delete(_ db: Database, ids: Set<String>) throws -> Set<String>
    static func idsExisting(_ db: Database, among ids: [String]) throws -> Set<String>
    static func staleIds(_ db: Database, olderThanGeneration g: Int) throws -> Set<String>   // excludes ids referenced by pending/inFlight outbox rows
}
enum ThreadRepository {
    static func recomputeAggregates(_ db: Database, threadIds: Set<String>, selfAddresses: Set<String>) throws   // ThreadAggregator; rewrites thread + thread_label rows; deletes thread rows with no visible message
    static func markComplete(_ db: Database, threadId: String, complete: Bool) throws
    static func messageIds(_ db: Database, threadId: String) throws -> [String]
}
enum BodyRepository {
    static func storeBody(_ db: Database, messageId: String, body: SanitizedBody?, text: String?, attachments: [ParsedAttachment], referenced: Set<String>, now: Int64) throws   // sets bodyState=1, hasAttachments exact; attachment rows replaced
    static func markUnavailable(_ db: Database, messageId: String) throws                                     // bodyState=2
    static func missingBodyIds(_ db: Database, threadId: String, sanitizerVersion: Int) throws -> [String]
    static func attachment(_ db: Database, messageId: String, partId: String) throws -> AttachmentRecord?
    static func updateAttachmentIds(_ db: Database, messageId: String, parsed: [ParsedAttachment]) throws
}
enum LabelRepository {
    static func replaceAll(_ db: Database, labels: [GmailLabel]) throws                  // keeps counts/view state of labels that still exist
    static func updateCounts(_ db: Database, labels: [GmailLabel], now: Int64) throws
    static func markViewFetched(_ db: Database, labelId: String, nextPageToken: String?, now: Int64) throws
    static func cachedViewLabelIds(_ db: Database) throws -> [String]
}
enum OutboxRepository {
    static func enqueueModify(_ db: Database, threadId: String, delta: LabelDelta, affectedMessageIds: [String], now: Int64) throws -> Int64?   // coalesces into the pending op for the thread; nil if it cancelled out; recomputes E
    static func enqueueSend(_ db: Database, job: SendJob, now: Int64) throws -> Int64
    static func claimModifies(_ db: Database, limit: Int, now: Int64) throws -> [OutboxRecord]   // pending & due → inFlight, attempts+1
    static func claimSend(_ db: Database, now: Int64) throws -> OutboxRecord?
    static func ackModify(_ db: Database, opId: Int64, serverLabelsByMessage: [String: Set<String>]?) throws -> Set<String>   // S := delta(S) (or server labels); delete op; recompute E; thread ids
    static func discardModify(_ db: Database, opId: Int64) throws -> Set<String>            // delete op; recompute E (reverts optimistic state)
    static func retryLater(_ db: Database, opId: Int64, error: GmailError, now: Int64, random: Double) throws
    static func fail(_ db: Database, opId: Int64, error: GmailError) throws
    static func setTransmitState(_ db: Database, opId: Int64, _ s: TransmitState) throws
    static func deleteSend(_ db: Database, opId: Int64) throws
    static func retrySend(_ db: Database, opId: Int64) throws                              // failed → pending, attempts 0
    static func releaseInFlight(_ db: Database) throws                                     // launch: inFlight → pending
    static func rearmFailedModifies(_ db: Database) throws                                 // foreground / pull: failed modify → pending, attempts 0
    static func pendingModifies(_ db: Database) throws -> [OutboxRecord]
}
enum SyncStateRepository { static func get(_ db: Database, _ key: SyncKey) throws -> String?; static func set(_ db: Database, _ key: SyncKey, _ value: String?) throws }

// Sync/SyncStatus.swift
@Observable final class SyncStatus {
    enum Phase: Equatable { case idle, syncing, initialSync }
    var phase: Phase = .idle; var isOffline = false; var lastError: String?; var lastSyncAt: Date?
    var pendingOps = 0; var failedSends = 0
}
// Sync/SyncEngine.swift
enum SyncReason: Sendable, Equatable { case launch, foreground, pullToRefresh, background, afterSend, labelOpened(String), loadOlderInbox, loadOlderLabel(String) }
actor SyncEngine {
    init(db: DatabasePool, gmail: GmailClient, outbox: Outbox, status: SyncStatus, settings: @Sendable () async -> Settings, auth: AuthStore, clock: @Sendable () -> Date = Date.init)
    func run(_ reason: SyncReason) async                 // never throws; single-flight with rerun flag; reports via SyncStatus
    func ensureThreadLoaded(threadId: String) async throws   // §4.5; deduped per thread
    func refreshLabelCounts(force: Bool) async           // §4.6; throttled 5 min unless force
    func requestFullResync() async                       // Settings → Advanced
    func updateBadge() async
}
// Sync/Outbox.swift
actor Outbox {
    init(db: DatabasePool, gmail: GmailClient, status: SyncStatus, identity: @Sendable () async -> (SelfIdentity, ComposeStyle, signatureHTML: String?), clock: @Sendable () -> Date = Date.init, random: @Sendable () -> Double)
    func kick()                                          // debounce 300 ms then drain (lets a burst of swipes coalesce)
    func drain() async                                   // §4.8; awaited by BG refresh and after sign-in
    func retrySend(id: Int64) async; func discardSend(id: Int64) async
    func rearmFailedModifies() async
}
// Sync/MailActions.swift (MainActor)
struct MailActions {
    let db: DatabasePool; let outbox: Outbox; let sync: SyncEngine
    func archive(threadId: String) async         // write { enqueueModify(remove INBOX, affected = messageIds) } → kick
    func markRead(threadId: String) async        // remove UNREAD
    func markUnread(threadId: String) async      // add UNREAD
    func send(_ job: SendJob) async              // write { enqueueSend } → beginBackgroundTask → drain
}
// App/BackgroundRefresh.swift
enum BackgroundRefresh {
    static let taskID = "de.newtelco.minimail.refresh"
    static func schedule()                               // BGAppRefreshTaskRequest, earliestBeginDate +15 min; iOS 27 async submit branch
    static func run(_ env: AppEnvironment) async         // §4.10
}
// App/Maintenance.swift
enum Maintenance { static func cleanup(_ db: DatabasePool, now: Date) async }   // §4.9

// Web/WebViewHost.swift (MainActor)
final class WebViewHost {
    init(cid: CIDSchemeHandler, bridge: WebBridge)
    var webView: WKWebView { get }                       // lazily created with makeConfiguration()
    func prepare() async                                 // compile/look up rule lists, create + warm the instance
    func setImagesAllowed(_ allowed: Bool)               // swaps rule lists before a load (fallback §14 #4)
    func recycle()                                       // loads the empty document (drops DOM), keeps the process
    static func makeConfiguration(cid: CIDSchemeHandler, bridge: WebBridge) -> WKWebViewConfiguration
    func makeThrowawayWebView() -> WKWebView             // signature preview only (no cid handler, block-all list)
}
struct MailWebView: UIViewRepresentable { let host: WebViewHost; let document: String; let revision: Int; let interfaceStyle: UIUserInterfaceStyle }
enum WebMessage: Equatable { case toggle(messageId: String), loadImages(messageId: String), attachment(messageId: String, partId: String), link(URL) }
final class WebBridge: NSObject, WKScriptMessageHandler { var onMessage: (WebMessage) -> Void }
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler { init(store: InlineImageStore) }   // tracks stopped tasks; never completes a stopped task
actor InlineImageStore {
    init(gmail: GmailClient, db: DatabasePool, cacheDirectory: URL)
    func bytes(messageId: String, contentId: String) async throws -> (Data, String)   // memory/disk cache → attachments.get (stored id, re-resolve on 404); ≤ 2 in flight; failures cached 60 s
    func purge() async
}
final class LinkPolicy: NSObject, WKNavigationDelegate { var openURL: (URL) -> Void }

// Theme / Settings / AppEnvironment: see §10, §11, §12.2
```

---

## 3. Data model (SQLite via GRDB)

### 3.1 Principles
- One `DatabasePool` (WAL) at `Application Support/minimail-db/db.sqlite` `[ios-platform §2.2]`; the directory gets `FileProtectionType.completeUntilFirstUserAuthentication` so BG refresh after first unlock can write (attribute failure → log and continue; the BG handler tolerates `SQLITE_AUTH`/`SQLITE_IOERR`).
- Schema is raw SQL in `DatabaseMigrator.registerMigration("v1")` — the executed DDL is exactly §3.2. `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true` (name UNVERIFIED `[ios-platform §2.3]`; remove if it does not compile).
- Column names are camelCase = Swift property names (no CodingKeys mapping). JSON columns are **sorted** JSON strings so equality and `ValueObservation` change detection are exact `[ios-platform §2.4]`.
- `message` carries S (`serverLabelIds`) and E (`labelIds`); `thread` and `thread_label` are derived by `ThreadRepository.recomputeAggregates` in the same transaction as every message write. No FK from `message` to `thread` (a hidden-only thread has message rows and no thread row).

### 3.2 DDL (migration `v1`, verbatim)

```sql
CREATE TABLE label (
  id                    TEXT PRIMARY KEY NOT NULL,      -- "INBOX", "Label_12"
  name                  TEXT NOT NULL,
  type                  TEXT NOT NULL,                  -- 'system' | 'user'
  labelListVisibility   TEXT,                           -- labelShow | labelShowIfUnread | labelHide | NULL
  messageListVisibility TEXT,                           -- show | hide | NULL
  textColor             TEXT,                           -- '#rrggbb' (user labels)
  backgroundColor       TEXT,
  messagesUnread        INTEGER,                        -- NULL until labels.get
  threadsUnread         INTEGER,
  threadsTotal          INTEGER,
  countsFetchedAt       INTEGER,                        -- epoch ms
  sortOrder             INTEGER NOT NULL DEFAULT 1000,  -- system pinned first, then user labels by name
  viewFetchedAt         INTEGER,                        -- non-NULL once messages.list for this label ran (label view cached)
  viewNextPageToken     TEXT                            -- "Load older" inside the label view
);

CREATE TABLE thread (
  id              TEXT PRIMARY KEY NOT NULL,
  subject         TEXT NOT NULL DEFAULT '',             -- oldest visible message, prefixes stripped
  snippet         TEXT NOT NULL DEFAULT '',             -- newest visible message
  lastDate        INTEGER NOT NULL,                     -- max(internalDate) of visible messages
  lastInboxDate   INTEGER,                              -- max(internalDate) of visible messages with INBOX in labelIds; NULL if none
  messageCount    INTEGER NOT NULL,
  unreadCount     INTEGER NOT NULL,
  inInbox         INTEGER NOT NULL,                     -- any visible message has INBOX (effective)
  hasAttachments  INTEGER NOT NULL,
  participants    TEXT NOT NULL DEFAULT '',             -- precomputed "Alice, Bob, Me"
  userLabelIds    TEXT NOT NULL DEFAULT '[]',           -- sorted JSON of user labels across visible messages (chips)
  isComplete      INTEGER NOT NULL DEFAULT 0,           -- 1 after threads.get was ingested
  bodiesMissing   INTEGER NOT NULL DEFAULT 0            -- visible messages with bodyState = 0
);
CREATE INDEX thread_inbox_date   ON thread(lastDate DESC)      WHERE inInbox = 1;
CREATE INDEX thread_inbox_unread ON thread(lastDate DESC)      WHERE inInbox = 1 AND unreadCount > 0;
CREATE INDEX thread_inbox_today  ON thread(lastInboxDate DESC) WHERE inInbox = 1;

CREATE TABLE thread_label (                             -- one row per (label, thread) over ALL labels of visible messages
  labelId     TEXT NOT NULL,
  threadId    TEXT NOT NULL,
  lastDate    INTEGER NOT NULL,                         -- copy of thread.lastDate
  unreadCount INTEGER NOT NULL,                         -- copy of thread.unreadCount
  PRIMARY KEY (labelId, threadId)
) WITHOUT ROWID;
CREATE INDEX thread_label_date ON thread_label(labelId, lastDate DESC);

CREATE TABLE message (
  id               TEXT PRIMARY KEY NOT NULL,
  threadId         TEXT NOT NULL,
  historyId        INTEGER NOT NULL DEFAULT 0,          -- uint64 string → Int64 (informational)
  internalDate     INTEGER NOT NULL,                    -- epoch ms; ordering key everywhere
  fromName         TEXT,
  fromAddr         TEXT NOT NULL DEFAULT '',
  isFromMe         INTEGER NOT NULL DEFAULT 0,          -- fromAddr ∈ selfAddresses
  toList           TEXT NOT NULL DEFAULT '[]',          -- JSON [{"addr":…,"name":…}]
  ccList           TEXT NOT NULL DEFAULT '[]',
  replyToList      TEXT NOT NULL DEFAULT '[]',
  subject          TEXT NOT NULL DEFAULT '',            -- RFC 2047-decoded, prefix kept
  snippet          TEXT NOT NULL DEFAULT '',            -- entity-decoded
  messageIdHeader  TEXT,                                -- '<…>'
  inReplyTo        TEXT,
  referencesList   TEXT NOT NULL DEFAULT '[]',          -- JSON ["<a>","<b>"]
  topMimeType      TEXT,                                -- payload.mimeType (format=metadata)
  serverLabelIds   TEXT NOT NULL DEFAULT '[]',          -- S: sorted JSON, last state told by the server
  labelIds         TEXT NOT NULL DEFAULT '[]',          -- E: sorted JSON = effective(S, pending deltas); the ONLY column the UI reads
  isUnread         INTEGER NOT NULL DEFAULT 0,          -- derived from labelIds
  inInbox          INTEGER NOT NULL DEFAULT 0,
  isHidden         INTEGER NOT NULL DEFAULT 0,          -- TRASH ∨ SPAM ∨ DRAFT ∨ CHAT
  hasAttachments   INTEGER NOT NULL DEFAULT 0,          -- hint (topMimeType = multipart/mixed) until bodyState = 1, then exact
  bodyState        INTEGER NOT NULL DEFAULT 0,          -- 0 none, 1 cached, 2 unavailable (404 / parse failure)
  syncGeneration   INTEGER NOT NULL DEFAULT 0,          -- generation of the full sync that (re)wrote this row
  fetchedAt        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX message_thread_date ON message(threadId, internalDate);
CREATE INDEX message_generation  ON message(syncGeneration);

CREATE TABLE message_body (
  messageId        TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  bodyHtml         TEXT NOT NULL,                       -- sanitized fragment (plain-text mails converted); never raw HTML
  bodyText         TEXT,                                -- decoded text/plain part, for quoting
  hasRemoteImages  INTEGER NOT NULL DEFAULT 0,
  darkStrategy     TEXT NOT NULL DEFAULT 'plain',       -- plain | card | native
  sanitizerVersion INTEGER NOT NULL,
  fetchedAt        INTEGER NOT NULL
);

CREATE TABLE attachment (
  messageId    TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  partId       TEXT NOT NULL,
  filename     TEXT NOT NULL,
  mimeType     TEXT NOT NULL,
  size         INTEGER NOT NULL DEFAULT 0,
  contentId    TEXT,                                    -- without <>
  isInline     INTEGER NOT NULL DEFAULT 0,              -- referenced by cid: in the sanitized HTML
  attachmentId TEXT,                                    -- TRANSIENT cache; re-resolved via messages.get on 404 [gmail-api §6]
  PRIMARY KEY (messageId, partId)
) WITHOUT ROWID;

CREATE TABLE outbox (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT, -- execution order
  kind               TEXT NOT NULL,                     -- 'modify' | 'send'
  state              TEXT NOT NULL DEFAULT 'pending',   -- pending | inFlight | failed
  attempts           INTEGER NOT NULL DEFAULT 0,
  nextAttemptAt      INTEGER NOT NULL DEFAULT 0,        -- epoch ms
  createdAt          INTEGER NOT NULL,
  lastError          TEXT,
  -- kind = 'modify' (thread-level ops only in stage 1)
  threadId           TEXT,
  addLabelIds        TEXT,                              -- sorted JSON
  removeLabelIds     TEXT,                              -- sorted JSON
  affectedMessageIds TEXT,                              -- JSON: message ids the delta applies to locally (snapshot at enqueue, unioned on coalesce)
  -- kind = 'send'
  sendJob            TEXT,                              -- JSON SendJob (§2.4)
  rfc822MessageId    TEXT,                              -- '<uuid@domain>'
  transmitState      TEXT                               -- notSent | maybeSent
);
CREATE INDEX outbox_due    ON outbox(state, nextAttemptAt);
CREATE INDEX outbox_thread ON outbox(threadId) WHERE kind = 'modify';

CREATE TABLE syncState (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;
```

`syncState` keys (`SyncKey`): `historyId` (decimal string), `syncGeneration` (int), `lastFullSyncAt`, `lastDeltaSyncAt`, `lastLabelCountsAt`, `lastCleanupAt` (epoch ms), `accountEmail`, `displayName`, `selfAddresses` (JSON `[String]`, lowercased), `sendAsSignature` (raw HTML from `sendAs`, import source only), `inboxNextPageToken`.

### 3.3 Gmail → column mapping

| Gmail field | Column | Transform |
|---|---|---|
| `Message.id`, `threadId` | `message.id`, `threadId` | verbatim |
| `historyId` (string uint64) | `historyId` | `StringUInt64` → Int64 `[gmail-api gotcha 3]` |
| `internalDate` (string int64 ms) | `internalDate` | `StringInt64` |
| `labelIds[]` (get / history / modify response) | `serverLabelIds` → `labelIds`, flags | `LabelAlgebra.sortedJSON`; `recomputeEffective` |
| `snippet` | `message.snippet`, `thread.snippet` | HTML entities decoded |
| `payload.headers` From/To/Cc/Reply-To | `fromName`, `fromAddr`, `isFromMe`, `toList`, `ccList`, `replyToList` | `AddressParser` + `RFC2047` |
| `Subject` | `message.subject` (verbatim) / `thread.subject` (`SubjectPrefix.stripForDisplay` of the oldest) | `RFC2047.decode`, unfolded |
| `Message-ID`, `In-Reply-To`, `References` | `messageIdHeader`, `inReplyTo`, `referencesList` | `MessageIDs` |
| `Date` header | not stored — `internalDate` is used everywhere `[gmail-api §5]` | |
| `payload.mimeType` | `topMimeType`, `hasAttachments` hint | hint = `multipart/mixed` |
| `payload` parts (`format=full`) | `message_body.*`, `attachment.*`, `hasAttachments` exact | `MessageParser.parse` → `Sanitizer.sanitize` |
| `Label.*` | `label.*` | `labels.list` fills identity/visibility; `labels.get` fills counts/colour `[gmail-api §10–11]` |
| `Profile.emailAddress`, `historyId` | `syncState.accountEmail`, `historyId` | |
| `SendAs[]` | `syncState.displayName`, `selfAddresses`, `sendAsSignature` | primary/default alias |
| `ListMessagesResponse.nextPageToken` | `syncState.inboxNextPageToken` / `label.viewNextPageToken` | |

### 3.4 Not stored (deliberately)
Raw HTML/MIME/`payload` JSON; attachment bytes (file cache `Caches/attachments/<messageId>/<partId>/<filename>`, purgeable; inline images in `Caches/cid/`); OAuth tokens (Keychain); settings (UserDefaults); `Date` header; `resultSizeEstimate`; history records; Gmail drafts (a failed `send` outbox row **is** the draft); messages outside INBOX unless their thread is cached or a label view was opened.

### 3.5 Invariants (`InvariantChecks.assertAll(db)` runs after every repository/sync/outbox test)
1. `message.labelIds == sortedJSON(LabelAlgebra.effective(serverLabelIds, pendingDeltas(message)))` for every message, where pending deltas = `pending`/`inFlight` modify ops whose `affectedMessageIds` contain the id, in `outbox.id` order.
2. `isUnread/inInbox/isHidden == LabelAlgebra.flags(labelIds)`.
3. Every `thread` row has ≥ 1 visible message and its columns equal `ThreadAggregator.aggregate(visible messages)`; every message with `isHidden = 0` has a thread row; `thread_label` rows == `allLabelIds` of the aggregate with copied `lastDate`/`unreadCount`.
4. At most one `pending` modify op per `threadId`.
5. `syncState.historyId` never decreases except in a full resync (which bumps `syncGeneration`).
6. `bodiesMissing == COUNT(visible messages with bodyState = 0)`.

---

## 4. Sync engine

### 4.1 Overview and coordination

```
SyncEngine.run(reason)   — single-flight: a second caller sets rerunRequested and returns; the active run loops once more at its end
   ├─ no historyId            → fullSync() → deltaSync() → refreshLabelCounts(force: true) → outbox.drain()
   ├─ else                    → deltaSync() (historyExpired / tooManyRecords → fullSync()) → refreshLabelCounts(force: false) → outbox.drain()
   ├─ .labelOpened(id)        → hydrateLabelView(id) if label.viewFetchedAt == nil or older than 24 h, then the normal path
   ├─ .loadOlderInbox         → next messages.list page (inboxNextPageToken) + metadata batch; no delta
   ├─ .loadOlderLabel(id)     → same with label.viewNextPageToken
   ├─ .afterSend              → deltaSync only (picks up the SENT copy)
   └─ .background             → deltaSync + throttled counts; never bodies; checks Task.isCancelled between network calls
ensureThreadLoaded(id)     — thread completion + bodies (§4.5), independent of run()
```

Triggers (only these; no timers): app launch after first frame (`.launch`), `scenePhase == .active` if `lastDeltaSyncAt` older than 60 s (`.foreground`; also re-arms failed modify ops), pull-to-refresh (always; re-arms failed ops), BG app refresh, after a send is acknowledged (`.afterSend`), label view opened, list end reached with a page token, thread opened (`ensureThreadLoaded`). Every DB write is one transaction, so a cancelled run never leaves partial state.

Quota (pessimistic table `[gmail-api "Quotas"]`, UNVERIFIED): initial sync = 1 + 1 + 1 + 5 + 100×20 ≈ 2,010 units; idle delta = 2; delta with n new messages = 2 + 20n; thread open (incomplete) = 40; thread open (bodies only, k messages) = 20k; label counts ≤ 60; send = 100 (+5 for the `rfc822msgid:` check on retry). Batches are 25 parts, sent sequentially, at most 2 HTTP requests in flight (`RequestLimiter`).

### 4.2 Full sync (first launch, or after `historyId` expiry) — generation based

```
fullSync():
    status.phase = .initialSync (only if no historyId ever)
    profile  = gmail.getProfile()                                   // baseline BEFORE listing [gmail-api §13 item 1]
    if let cached = syncState.accountEmail, cached != profile.emailAddress { throw AuthError.accountMismatch }   // AuthStore: wipe + sign out
    sendAs   = try? gmail.listSendAs()                               // tolerated failure → selfAddresses = {profile.email}
    labels   = gmail.listLabels()
    gen      = (syncState.syncGeneration ?? 0) + 1
    db.write { set accountEmail, displayName (default/primary sendAs), selfAddresses, sendAsSignature, syncGeneration = gen
               LabelRepository.replaceAll(labels) }
    page = gmail.listMessages(labelIds: ["INBOX"], q: nil, maxResults: settings.inboxPageSize /*100*/, pageToken: nil)   // 5 units
    hydrateMetadata(ids: page.messages.ids, generation: gen)        // §4.4: chunks of 25, one write per chunk → the list fills progressively
    db.write { inboxNextPageToken = page.nextPageToken }
    for labelId in LabelRepository.cachedViewLabelIds():             // cached label views survive a resync
        p = gmail.listMessages(labelIds: [labelId], maxResults: 50, pageToken: nil)
        hydrateMetadata(p.ids, gen); db.write { markViewFetched(labelId, p.nextPageToken, now) }
    db.write {
        stale   = MessageRepository.staleIds(olderThanGeneration: gen)          // excludes ids referenced by pending/inFlight outbox rows (affectedMessageIds, send originalMessageId)
        threads = threadIds(of: stale)
        MessageRepository.delete(stale)                                          // cascades message_body + attachment
        for t in threads: ThreadRepository.markComplete(t, complete: false)     // survivors lost members → re-completed on next open
        ThreadRepository.recomputeAggregates(threads)                            // deletes empty threads
        historyId = profile.historyId; lastFullSyncAt = now
    }
    deltaSync()                                                                  // catches changes during the listing; idempotent
```

Why delete non-relisted rows: after a `historyId` expiry we cannot know what happened to messages we did not re-list; keeping them would show stale inbox rows forever. Bodies of **re-listed** messages survive (`upsertMetadata` never touches `message_body`). Rows referenced by pending outbox ops are kept so the user's intent still applies. Accepted loss: "Load older" pages beyond the first 100 inbox messages (the user taps Load older again). Never `clearMessageCache()`.

### 4.3 Delta sync (`history.list`)

```
deltaSync():
    start = UInt64(syncState.historyId)!
    pages = []; token = nil
    repeat:
        page = gmail.listHistory(startHistoryId: start, pageToken: token)         // 500/page, all four historyTypes, no labelId filter [gmail-api §13]
            GmailError.historyExpired → throw SyncError.historyExpired            // 404, or 400 failedPrecondition/"historyId" (UNVERIFIED code [gmail-api §13.5])
        pages.append(page); token = page.nextPageToken
        if pages.recordCount > 5_000 → throw SyncError.tooManyRecords             // cheaper to resync than to apply
    until token == nil
    changes  = HistoryReducer.reduce(pages)                                        // pure
    existing = db.read { MessageRepository.idsExisting(among: changes.added.keys ∪ changes.labelOps.keys ∪ changes.deleted) }
    scope    = HydrationScope(cachedLabelIds: {"INBOX"} ∪ cachedViewLabelIds, knownThreadIds: db thread ids ∩ changes.touchedThreads)
    toFetch  = [id for (id, ref) in changes.added if id ∉ existing && HydrationPolicy.shouldFetch(ref, scope)]
             ∪ [id for (id, deltas) in changes.labelOps if id ∉ existing && id ∉ changes.added && deltas.any { $0.add ∩ scope.cachedLabelIds ≠ ∅ }]   // moved into scope from another client
    hydrateMetadata(ids: toFetch, generation: syncState.syncGeneration)            // §4.4; per-id 404 dropped silently [gmail-api gotcha 5]
    db.write (one transaction):
        touched  = MessageRepository.delete(changes.deleted ∩ existing)
        for id in existing − changes.deleted:
            if let final = changes.finalLabels[id]: applyServerLabels(id, final)   // full set beats deltas when present [gmail-api §13 SNIPPET]
            else: for d in changes.labelOps[id] ?? []: applyServerDelta(id, d)
        touched ∪= MessageRepository.recomputeEffective(those ids)
        ThreadRepository.recomputeAggregates(touched)
        historyId = max(start, changes.newHistoryId ?? pages.last.historyId ?? start)   // never decreases
        lastDeltaSyncAt = now
```

`HistoryReducer.reduce` rules: records in order (pages concatenated); `messagesAdded` → `added[id] = ref` (last wins), removed from `deleted`; `messagesDeleted` → `deleted.insert(id)`, removes `added`/`labelOps`/`finalLabels` entries (added-then-deleted cancels); `labelsAdded`/`labelsRemoved` → append `LabelDelta` to `labelOps[id]`; whenever a change record's `message.labelIds` is non-nil, `finalLabels[id]` := that set (last wins); `touchedThreads` = every `threadId` seen; `newHistoryId` = last page's `historyId`.

`HydrationPolicy.shouldFetch(ref, scope)`: `true` if `ref.labelIds == nil` (unknown → fetch and let the row's flags decide), or `ref.threadId ∈ scope.knownThreadIds` (a reply in a thread we show, including our own SENT), or `ref.labelIds ∩ scope.cachedLabelIds ≠ ∅`; `false` otherwise (SPAM/TRASH/DRAFT-only mail, label-only mail we never opened). Trash/spam arrive as `labelsAdded: ["TRASH"]`, so `isHidden` handles them; `messagesDeleted` is permanent deletion only `[gmail-api gotcha 6]`.

Recovery: `SyncError.historyExpired` / `tooManyRecords` → log `sync.history.expired` → `fullSync()` in the same run. Never surfaces to the user beyond "Syncing…".

### 4.4 Metadata hydration

```
hydrateMetadata(ids, generation):
    for chunk in ids.chunked(25):                                                  // 25 × 20 = 500 units per HTTP batch
        results = gmail.getMessages(ids: chunk, format: .metadata)                 // per-part retry inside the client (§6.3)
        parsed  = results.compactMap { id, r in
            switch r { case .success(m): MessageParser.parse(m)
                       case .failure(.notFound): nil                               // deleted meanwhile
                       case .failure(e): log; nil } }                             // transient after retries → picked up by the next delta
        db.write {
            touched = MessageRepository.upsertMetadata(parsed, selfAddresses, generation, now)   // writes S + syncGeneration; keeps message_body; recomputeEffective(ids)
            ThreadRepository.recomputeAggregates(touched)
        }
```

Request shape: `GET /gmail/v1/users/me/messages/{id}?format=metadata&metadataHeaders=From&…&fields=id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers&prettyPrint=false` `[gmail-api gotcha 12, 23]`. `upsertMetadata` for an existing row updates headers/labels/`topMimeType` and keeps `bodyState`, `hasAttachments` (if exact) and the body row.

### 4.5 Thread open: completion + bodies (one round trip)

```
ensureThreadLoaded(threadId):                          // called from ThreadModel.onAppear; deduped by an in-flight Set<String> inside the actor
    guard let t = db.read { thread[threadId] } else return
    if t.isComplete == 0:
        thread = gmail.getThread(id: threadId, format: .full)                  // 40 units, headers + bodies of EVERY message [gmail-api §3]
            .notFound → db.write { delete messages of thread; recomputeAggregates } ; return
        prepared = thread.messages.map(prepareBody)                            // parse + sanitize OUTSIDE the write (actor thread, not the writer lock)
        db.write {
            touched = upsertMetadata(prepared.parsed, selfAddresses, currentGeneration, now)
            for p in prepared: storeBody(p) ; applyServerLabels(p.id, p.labelIds)
            recomputeEffective(ids); markComplete(threadId, true); recomputeAggregates(touched)
        }
    else:
        missing = db.read { BodyRepository.missingBodyIds(threadId, Sanitizer.version) }   // bodyState = 0 or stale sanitizerVersion
        if missing.isEmpty: return
        for chunk in missing.sorted(newestFirst).chunked(10):                  // bodies are big; small batches
            results = gmail.getMessages(ids: chunk, format: .full)
            prepared = results.map { .success → prepareBody ; .notFound → delete ; transient → leave for next open }
            db.write { store bodies; applyServerLabels; recomputeEffective; recomputeAggregates }

prepareBody(msg) -> Prepared:
    parsed = MessageParser.parse(msg)
    if parsed.body.html == nil && parsed.body.text == nil, let part = parsed.body.deferredTextParts.first:
        data = gmail.getAttachment(msg.id, part.attachmentId); decode with part charset → html or text   // [mime-rfc §5.2 (h)]
    if let html = parsed.body.html, html.utf8.count <= Sanitizer.maxInputBytes:
        body = (try? Sanitizer.sanitize(html, messageId: msg.id)) ?? Sanitizer.fromPlainText(parsed.body.text ?? "")
    else: body = Sanitizer.fromPlainText(parsed.body.text ?? msg.snippet ?? "")
    isInline(att) = att.contentId ∈ body.referencedContentIDs
```

Bodies are never fetched by the BG task, by list scrolling, or speculatively. `applyServerLabels` on a body fetch is "free freshness" and — because `recomputeEffective` follows — cannot flip a just-marked-read thread back to unread (the flaw all judges found in SIMPLE).

### 4.6 Labels, unread counts, badge
- `refreshLabelCounts(force:)`: skipped unless `force` or `lastLabelCountsAt` older than 5 min. Then `labels.list` (1 unit; picks up renamed/new labels) + one batch of `labels.get` for displayed labels (`INBOX`, `STARRED`, `IMPORTANT`, `SENT` + user labels with `labelListVisibility != labelHide`, cap 60). Also called with `force: true` when the Labels sheet opens and counts are older than 5 min.
- Inbox / Today / Unread counts and the app badge are **local** SQL (`Queries.inboxUnreadThreadCount`, `todayThreadCount`) — they match what the list shows, including optimistic state. Other labels show the server `threadsUnread` (footer: "Counts from Gmail").
- Badge: only when `settings.showBadge` and `[.badge]` authorization was granted; `UNUserNotificationCenter.current().setBadgeCount(inboxUnreadThreadCount)` after every run and after every outbox ack (foreground and BG); `0` on sign-out `[ios-platform §6]`.

### 4.7 Conflict rules (S / P / E)

Definitions: `S` = `serverLabelIds`, `P` = ordered pending deltas for the message (pending/inFlight modify ops whose `affectedMessageIds` contain it), `E` = `labelIds` = `LabelAlgebra.effective(S, P)`. The UI only ever reads `E`.

| Event | S | P | E |
|---|---|---|---|
| User action (archive/read/unread) | unchanged | enqueue/coalesce delta | recomputed → instant UI (same transaction) |
| History record (delta sync) | `S := finalLabels` or `d_hist(S)` | unchanged | recomputed; pending intent still on top |
| Metadata re-hydration / body fetch | `S := fetched labelIds` | unchanged | recomputed (no flicker) |
| Outbox op acked (2xx) | `S := d(S)` per affected message; response `messages[].labelIds` override when present | op removed | converges to server |
| Op 404 (thread gone) | unchanged | op removed | delta sync deletes the messages soon |
| Op permanent 4xx (400 / non-quota 403) | unchanged | op removed (`discardModify`) | reverts to server state; `lastError` logged |
| Full resync | fresh S; non-relisted rows deleted unless referenced by P | unchanged | recomputed |
| New message arrives in a thread with a pending op | S = fetched | not in `affectedMessageIds` → unaffected | server truth (correct: `threads.modify` applied server-side to the messages that existed then) |

Because E is a function of (S, P) and both updates are commutative set operations, the interleaving of acks, history echoes and user actions cannot lose an update. The only semantic conflict left — another client changes the same label between the local action and its upload — is resolved as "the user's op wins" (it is applied last). Our own `modify` echoes arrive as history records and are idempotent `[gmail-api §13 item 7]`.

### 4.8 Outbox

Enqueue (same transaction as the optimistic update; `MailActions`):
```
enqueueModify(threadId, delta, affected, now):
    if let op = pending (state = 'pending') op for threadId:
        merged = OutboxCoalescer.merge(existing: op.delta, new: delta)
        if merged.isEmpty: delete op                                   // read then unread → nothing to send
        else: update op (delta = merged, affectedMessageIds ∪= affected)
    else: insert (pending, nextAttemptAt = 0)                          // an inFlight op is never merged into
    recomputeEffective(affected) → recomputeAggregates
```
Drain:
```
kick(): schedule drain after 300 ms if not already scheduled/running
drain():
    guard !running else return; running = true; defer running = false
    loop:
        mods = db.write { OutboxRepository.claimModifies(limit: 25, now) }            // pending & due → inFlight, attempts += 1
        if !mods.isEmpty:
            results = try await gmail.modifyThreads(mods.map(ThreadModifyCall.init))  // one HTTP batch, per-part results
              (outer throw → every part = .failure(error))
            stop = false
            db.write { for (opId, r) in results:
                switch r {
                case .success(let thread):            ackModify(opId, thread.messages?.map { ($0.id, Set($0.labelIds ?? [])) })
                case .failure(.notFound):             ackModify(opId, nil)                       // target gone; S unchanged
                case .failure(.badRequest), .failure(.forbidden) where !isQuotaReason: discardModify(opId); log .error
                case .failure(.unauthorized):         retryLater(opId, countsAsAttempt: false); stop = true   // AuthStore already flipped to needsReauth
                case .failure(.offline):              retryLater(opId, countsAsAttempt: false); stop = true
                case .failure(let e) where e.isTransient: retryLater(opId, e)                    // attempts already counted by claim
                case .failure(let e):                 fail(opId, e)                              // decoding etc.: user-invisible, re-armed next foreground
                } }
            if stop: break
        if let s = db.write { claimSend(now) }: outcome = await performSend(s); if outcome == .stop: break
        if mods.isEmpty && s == nil: break
    status.pendingOps / failedSends = db.read { outboxCounts }
    if any modify acked: sync.updateBadge()
```
Retry policy: `retryLater` sets `nextAttemptAt = now + Backoff.outbox.delay(attempts, retryAfter, random)` (2, 4, 8 … 300 s ± 25 %, `Retry-After` honoured). `attempts` is not incremented for `offline`/`cancelled`/`unauthorized` (claim increments; `retryLater(countsAsAttempt: false)` decrements back). After **8** counted transient attempts a modify op becomes `failed` — **never deleted** — and `rearmFailedModifies()` (state → pending, attempts → 0) runs on every foreground activation and pull-to-refresh, so intent survives any offline stretch. Only a permanent 4xx removes a modify op (and reverts E). The next drain is triggered by the next `kick()`/sync/BG refresh; while foregrounded the actor also sleeps until the earliest `nextAttemptAt` (a continuation of a user action, not a polling timer).

At launch: `OutboxRepository.releaseInFlight()` (inFlight → pending) because a kill mid-request leaves the state unknown; sends with `transmitState = maybeSent` run the `rfc822msgid:` check before any retry (§7.7).

Failure UX: transient/offline → nothing beyond the optimistic state and a nav-bar subtitle "Offline — changes will sync" (`wifi.slash`). Failed send → an "Outbox" section at the top of the inbox list: subject, "Not sent — <short error>", swipe **Retry** / **Delete**, tap → Compose prefilled from the job (Send creates a new job and deletes the old one). Failed modify → silent (log only), re-armed automatically.

### 4.9 Cache bounds (`Maintenance.cleanup`, once per 24 h, after the first successful sync of a launch, never during a full sync)
1. Delete threads (cascade messages/bodies/attachments/thread_label) where `inInbox = 0 AND unreadCount = 0 AND lastDate < now − 30 d` and no `thread_label` row for a cached-view label and no pending/inFlight outbox op references the thread.
2. Delete `message_body` rows beyond the newest 2,000 by `fetchedAt`; set `bodyState = 0` and recompute `bodiesMissing` for their threads.
3. Purge `Caches/attachments` and `Caches/cid` files older than 7 days; delete `failed` send rows older than 30 days.
Three statements, not a Pruner; `lastCleanupAt` in `syncState`.

### 4.10 Background refresh `[ios-platform §3]`
```
.backgroundTask(.appRefresh("de.newtelco.minimail.refresh")) { await BackgroundRefresh.run(env) }
run(env):
    BackgroundRefresh.schedule()                       // request consumed; re-arm first
    guard env.auth.state is .signedIn else return
    await env.sync.run(.background)                    // delta + throttled counts; NO bodies; Task.isCancelled between calls
    await env.outbox.drain()                           // pending modifies + sends
    await env.sync.updateBadge()
```
DB protection: `SQLITE_AUTH`/`SQLITE_IOERR` (locked before first unlock) → log and return. `earliestBeginDate = now + 15 min`; `schedule()` also runs on `scenePhase == .background`. Nothing else ever runs in the background; a foreground send is wrapped in `beginBackgroundTask` `[ios-platform §3.5]`. No `NWPathMonitor`, no timers, no sockets.

---

## 5. Auth

### 5.1 Flow (AppAuth-iOS 3.0.0, `[ios-platform §1]`)
1. `OAuthConfig.fromInfoPlist()`: client id from `GoogleClientID`; redirect `com.googleusercontent.apps.<prefix>:/oauth2redirect` (single slash `[gmail-api gotcha 19]`); endpoints hard-coded from the OIDC document (no discovery round trip).
2. `SignInScreen` → `AuthStore.signIn()`:
   ```
   request = OIDAuthorizationRequest(configuration: OIDServiceConfiguration(authorizationEndpoint:tokenEndpoint:), clientId: config.clientID, clientSecret: nil,
                scopes: config.scopes, redirectURL: config.redirectURL, responseType: OIDResponseTypeCode,
                additionalParameters: ["login_hint": settings.lastSignedInEmail, "hd": "newtelco.de"].compactMapValues { $0 })
   agent   = OIDExternalUserAgentIOS(presentingViewController: keyWindow.rootViewController, prefersEphemeralSession: false)
   currentFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in Task { @MainActor in finish(state, error) } }
   finish: guard state else throw flowFailed/userCancelled
           if state.refreshToken == nil && !retried: retry once with additionalParameters["prompt"] = "consent"; if still nil → throw missingRefreshToken (UNVERIFIED that native clients always get one [gmail-api OAuth])
           try await tokens.adopt(state); profile = try await gmail.getProfile()
           if let cached = syncState.accountEmail, cached != profile.emailAddress { wipe DB + caches }   // single account
           settings.lastSignedInEmail = profile.emailAddress; state = .signedIn(email); sync.run(.launch)
   ```
   `hd` and `prompt=consent` are optional parameters (UNVERIFIED for the native flow); a failure that mentions them is retried once without them — sign-in never blocks on them.
3. Exactly one scope, `gmail.modify` — sufficient for every stage-1 call including `send` and `sendAs.list` `[gmail-api §14, §15, gotcha 1]`; the address comes from `getProfile`.
4. `.onOpenURL` → `auth.resume(url:)` → `currentFlow?.resumeExternalUserAgentFlow(url)` (documented fallback `[ios-platform §1.4]`).
5. Workspace prerequisite (owner checklist): OAuth app type **Internal**; admin marks the client Trusted or enables "Trust internal, domain-owned apps"; `SignInScreen` shows that exact remedy when the error contains `admin_policy_enforced` `[gmail-api "Workspace"]`.

### 5.2 Token storage and launch routing
- Whole `OIDAuthState` archived with `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)` into Keychain item `service = "de.newtelco.minimail"`, `account = "oauth.authState"`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` `[ios-platform §1.5, §5.5]`; re-archived on every `OIDAuthStateChangeDelegate.didChange`.
- **Routing before the first frame** uses two cheap facts: `Keychain.exists("oauth.authState")` (one `SecItemCopyMatching` for attributes, < 5 ms) and `syncState.accountEmail` (read during the same synchronous DB open). Truth table:

| Keychain item | `accountEmail` | `AuthStore.state` | Behaviour |
|---|---|---|---|
| yes | yes | `.signedIn(email)` | normal |
| yes | no (reinstall: Keychain survives, DB does not) | `.signedIn(nil)` | list empty + "Loading your inbox…"; `run(.launch)` performs the initial sync |
| no | yes | `.needsReauth(email)` | cached list stays readable; dismissable banner "Sign in again" |
| no | no | `.signedOut` | `SignInScreen` |

- The actual `OIDAuthState` unarchive (`tokens.load()`) runs after the first frame; until then nothing needs a token.

### 5.3 Refresh and 401 handling
```swift
actor AppAuthTokenProvider {
    private var state: OIDAuthState?; private var refreshTask: Task<String, Error>?
    func accessToken() async throws -> String {
        guard let state else { throw AuthError.signedOut }
        if let refreshTask { return try await refreshTask.value }                 // single flight: N concurrent callers share one refresh
        let task = Task { try await withCheckedThrowingContinuation { cont in
            state.performAction(freshTokens: { token, _, error in                 // refreshes if expired [ios-platform §1.6]
                if let token { cont.resume(returning: token) } else { cont.resume(throwing: Self.map(error)) } }) } }
        refreshTask = task; defer { refreshTask = nil }
        return try await task.value
    }
    func invalidateAccessToken() { state?.setNeedsTokenRefresh() }
}
```
`map(error)`: `OIDOAuthTokenErrorDomain` `invalid_grant` → `AuthError.needsReauth` (+ `onNeedsReauth()`); transport errors → `GmailError.offline/.network` (retryable, never signs out); other → `flowFailed`. `GmailClient.request` on HTTP 401: `invalidateAccessToken()`, retry once; a second 401 → `GmailError.unauthorized` → `AuthStore.markNeedsReauth()`. A 401 inside a batch part: refresh once and re-send the whole chunk once. `needsReauth` UI = a dismissable banner on the list (tap → sign-in flow); cache and outbox stay intact; sync and drain pause. Re-auth with the same email resumes everything; a different email wipes (§5.1 step 2).

### 5.4 Sign-out
`AuthStore.signOut()`: cancel running sync/drain → `tokens.revokeAndClear()` (`POST /revoke token=<refresh>`, best effort, 3 s) → Keychain delete → close pool → `Database.destroy(directory)` → purge `Caches/attachments`, `Caches/cid`, `tmp/attachments` → `WebViewHost.recycle()` → `setBadgeCount(0)` → state `.signedOut`. `Settings` (theme, compose style, signature) are kept; `lastSignedInEmail` is kept as `login_hint`.

### 5.5 Single-account assumptions
One Keychain item, one DB, one `accountEmail`. `selfAddresses` = profile email ∪ `sendAs` aliases (`isPrimary` or `verificationStatus == accepted`), refreshed by every full sync. `From:` = default/primary `sendAs.displayName` + profile email (Gmail rewrites mismatching From `[gmail-api §14]`).

---

## 6. Networking

### 6.1 `URLSession` and client shape
One `URLSessionConfiguration.default` session (`URLSession.minimail`): `timeoutIntervalForRequest = 30`, `timeoutIntervalForResource = 120`, `waitsForConnectivity = false` (fail fast into `.offline`; retried on the next trigger), `httpMaximumConnectionsPerHost = 2`, `urlCache = nil`, `httpAdditionalHeaders = ["Accept": "application/json"]`, `allowsExpensiveNetworkAccess = true`, `allowsConstrainedNetworkAccess = true`. Base URL `https://gmail.googleapis.com/gmail/v1/users/me/` (Discovery `rootUrl`); batch URL `https://www.googleapis.com/batch/gmail/v1` `[gmail-api §12]`. Every request: `prettyPrint=false`, repeated keys for `labelIds`/`metadataHeaders`/`historyTypes` `[gmail-api gotcha 22]`, `fields=` masks on chatty endpoints (§4.4; history: `history(id,messagesAdded(message(id,threadId,labelIds)),messagesDeleted(message(id,threadId)),labelsAdded(message(id,threadId,labelIds),labelIds),labelsRemoved(message(id,threadId,labelIds),labelIds)),nextPageToken,historyId`).

```swift
private func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, policy: RetryPolicy) async throws -> Data {
    try await limiter.withPermit {
        var attempt = 0
        while true {
            var req = makeRequest(method, path, query, body)                 // absolute URL, Content-Type for bodies
            req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let started = clock()
            let (data, http): (Data, HTTPURLResponse)
            do { (data, http) = try await session.data(for: req) as! (Data, HTTPURLResponse) }
            catch let e as URLError { let g = GmailError.map(e); if policy.allows(g, attempt) { try await backoff(attempt, nil); attempt += 1; continue }; throw g }
            log.record(method, path, http.statusCode, ms(started))            // never bodies, never tokens
            switch http.statusCode {
            case 200...299: return data
            case 401 where !didRefresh: await tokens.invalidateAccessToken(); didRefresh = true; continue
            case 401: throw GmailError.unauthorized                          // caller → AuthStore.markNeedsReauth
            default:
                let g = GmailError.map(status: http.statusCode, body: data, headers: http.allHeaderFields, endpoint: path)
                if policy.allows(g, attempt) { try await backoff(attempt, g.retryAfter); attempt += 1; continue }
                throw g
            }
        }
    }
}
```

### 6.2 Error taxonomy and mapping
```
map(status, body, endpoint):
    env = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body); reason = env?.primaryReason
    400: reason ∈ {failedPrecondition} || message contains "historyId", and endpoint is history → .historyExpired ; else .badRequest(reason, message)
    401: .unauthorized
    403: reason ∈ {rateLimitExceeded, userRateLimitExceeded, quotaExceeded, concurrentLimitExceeded} → .rateLimited(retryAfter: header) ; else .forbidden(reason)   // dailyLimitExceeded is .forbidden (pauses the outbox until next launch)
    404: endpoint is history → .historyExpired ; else .notFound
    429: .rateLimited(retryAfter: Retry-After seconds or HTTP-date)
    5xx: .server(status) ; other 4xx: .badRequest
map(URLError): notConnectedToInternet, networkConnectionLost, dataNotAllowed, internationalRoamingOff → .offline ; cancelled → .cancelled ; else .network(code)
```

| Error | Retries (reads) | Retries (`send`) | Backoff |
|---|---|---|---|
| `.rateLimited` | 4 | 0 | `Retry-After` else `Backoff.transient` (1, 2, 4, 8, 16 s ± 25 %) |
| `.server` | 3 | 0 | `Backoff.transient` |
| `.network` | 2 | 0 | `Backoff.transient` |
| `.offline` | 0 | 0 | fail fast |
| `.unauthorized` | 1 (after refresh) | 1 | none |
| `.batchMalformed` | 1 | — | 1 s |
| everything else | 0 | 0 | — |

`send` is never retried automatically by the client (non-idempotent); the outbox owns send retries with the `rfc822msgid:` check (§7.7). Inside BG refresh `Task.isCancelled` is checked before each attempt.

### 6.3 Batching
- Batched: `messages.get` (metadata, full), `labels.get`, `threads.modify`. Never batched: `history.list`, `messages.list`, `threads.get`, `send`, `attachments.get`, `getProfile`, `sendAs.list`.
- Chunk size **25**, chunks sent sequentially (with `RequestLimiter(2)` nothing exceeds 2 in-flight requests — far below the UNVERIFIED ~50 concurrent cap `[gmail-api gotcha 24]`).
- Wire format from `BatchCodec` `[gmail-api §12]`: outer 200 means nothing; each part's inner status line is mapped with §6.2; results are matched by `Content-ID` `<response-ID>`, never by order. Parts with `.rateLimited`/`.server` are collected and re-sent as a smaller batch after `Backoff.transient` (max 3 rounds); a 401 part → refresh once + re-send the chunk once; a part id missing from the response → `.batchMalformed` for that id; unparsable outer body → `.batchMalformed` once (retry after 1 s) then every part fails with it.
- `modifyThreads` parts: `POST /gmail/v1/users/me/threads/{id}/modify` with `{"addLabelIds":[…],"removeLabelIds":[…]}`; response `Thread` decoded leniently (`messages[].labelIds` may be absent — UNVERIFIED depth `[gmail-api §9]`).

### 6.4 Rate limiting
No token bucket. `RequestLimiter(max: 2)` + sequential 25-part batches + the retry table above keep any minute under ~2,600 pessimistic units (initial sync) and idle deltas at 2 units. A third consecutive `.rateLimited` in one run aborts the run with `SyncStatus.lastError = "Rate limited — try again later"`; the next trigger retries.

### 6.5 Logging
`Support/Log.swift`: `os.Logger(subsystem: "de.newtelco.minimail", category:)` with categories `auth`, `net`, `sync`, `outbox`, `db`, `web`, `ui`, `bg`. Rules: method + path + status + ms at `.debug`; retries/recoveries at `.notice`; failures at `.error` with the `GmailError` description; ids `%{public}`, addresses/subjects/snippets `%{private}`; never tokens, headers, bodies. `OSSignposter` intervals: `coldStartToList`, `fullSync`, `deltaSync`, `hydrateBatch`, `threadOpen`, `bodyLoad`, `documentLoad`, `outboxDrain`. In DEBUG `RequestLog` keeps the last 100 `(method, path, status, ms)` for Settings → Advanced → "Recent requests" (the agent's substitute for a proxy).

---

## 7. Compose pipeline (reply-all / forward)

Every step is pure in `MailCore`/`MailHTML` except attachment download and the final POST (outbox).

### 7.1 Reply-all recipients (`ReplyAll.recipients`, `[mime-rfc §2.1]`)
```
isSelfReply  = from != nil && me.allAddresses.contains(from.key)
toCandidates = isSelfReply ? to : ((replyTo.isEmpty ? [from].compactMap{$0} : replyTo) + to)
ccCandidates = cc
seen = Set<String>()
To = toCandidates.filter { !$0.key.isEmpty && !me.allAddresses.contains($0.key) && seen.insert($0.key).inserted }
Cc = ccCandidates.filter { same predicate }                       // To wins over Cc
if To.isEmpty && !Cc.isEmpty { To = Cc; Cc = [] }
if To.isEmpty, let from { To = [from] }                           // note-to-self: never empty To
```
Display names: first-seen wins; comparison on lowercased addr-spec only. Tests: the 16 vectors of `[mime-rfc §8.1]`.

### 7.2 Prefill (`ComposeModel.makeDraft`, main actor, from cached data only)
- Reply-all: `to/cc` from §7.1; `subject = SubjectPrefix.reply(original.subject)`; `inReplyTo = original.messageIdHeader`; `references = MessageIDs.referencesChain(original.referencesList, original.inReplyTo, original.messageIdHeader)` (RFC 5322 §3.6.4); `threadId = original.threadId`.
- Forward: `to = cc = []`, `subject = SubjectPrefix.forward(original.subject)`, **same** threading headers and `threadId` (Gmail-web behaviour `[mime-rfc §1.5, §7.3]`); attachments = the original's non-inline `attachment` rows as `ForwardAttachmentRef`s, all selected.
- `messageID = MessageIDs.generate(domain: domain(of: accountEmail))`, frozen in the draft.
- `quoteSource` snapshot: `html = QuoteExtractor.quotable(bodyHtml)` if a body row exists (`data-src` → `src`, placeholder removed, `mm-*` classes removed, `<img src="minimail-cid:…">` **removed**), `text = bodyText ?? Quoting.textFromHTML(html)`, headers/date from the message row. Opening Compose on a thread whose body is still loading shows "Loading original…" and enables Send once the body arrived (or after `bodyState == 2` with the snippet as text). The snapshot is what the outbox uses at drain time — a cache wipe between compose and send cannot break the quote.
- Subject table `[mime-rfc §8.2]`: `Re: `/`Fwd: ` only if not already prefixed (case-insensitive); `FW:`/`WG:` not normalised.

### 7.3 Bodies (`OutgoingBodies` + `Quoting`, `[html-rendering §5.5; mime-rfc §4]`)
```
<div dir="ltr" class="minimail_default" style="{style.inlineCSS}"><div>line 1</div><div><br></div><div>line 3</div></div>   -- typed text: escape &<>"; one <div> per line
[<div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature"><div style="{style.inlineCSS}">{signatureHTML}</div></div>]
<br>
reply:   <div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On {attribution} {Name} &lt;<a href="mailto:{addr}">{addr}</a>&gt; wrote:<br></div>
         <blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">{quoteSource.html}</blockquote></div>
forward: <div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>
         From: <strong class="gmail_sendername" dir="auto">{Name}</strong> <span dir="auto">&lt;<a href="mailto:{addr}">{addr}</a>&gt;</span><br>
         Date: {attribution}<br>Subject: {subject}<br>To: {to line}[<br>Cc: {cc line}]<br></div><br><br>{quoteSource.html}</div>
```
Plain text: typed text, blank line, `-- ` + signature text (tags stripped), blank line, then `On … wrote:` + `> `-prefixed lines (`>` for empty lines) or the forward banner (10 dashes / 9 dashes, From/Date/Subject/To[/Cc]) + the original text. `{attribution}` = `HeaderDate.attribution(internalDate, tz)` with U+202F. If `quoteSource.html == nil`: `PlainTextHTML.convert(text)`. The quote sits **outside** the styled wrapper; the whole HTML part is wrapped by `OutgoingBodies.document` (no `color-scheme` meta).

### 7.4 MIME (`MIMEBuilder.build`, `[mime-rfc §1.3, §3]`)
Fixed header order `From, To, Cc?, Subject, Date, Message-ID, In-Reply-To?, References?, MIME-Version: 1.0, Content-Type`; `Date` stamped at **build time** (`OutgoingMessage.date = now`, not the draft's creation time); folding ≤ 78 (address lists after commas, `References` one id per continuation); non-ASCII via RFC 2047 B-words; structure A (`multipart/alternative`: `text/plain` then `text/html`, both `charset="UTF-8"`, quoted-printable) or B (`multipart/mixed` ⊃ A + attachments: `Content-Type: <mime>; name="…"`, `Content-Disposition: attachment; filename="…"; size=<n>` + RFC 2231 `filename*=` for non-ASCII, base64 76-col CRLF); boundaries `=_minimail_<alt|mixed>_<16 hex>`; CRLF everywhere; no line > 998 octets. `raw = Base64URL.encode(bytes)` (padded). Tests pin `[mime-rfc §7.1]` (sha256 `b9f8078c…`, 2276 bytes) with fixed boundaries/date/UUID, the §7.2 forward variant without `In-Reply-To` (sha256 `2127dc54…`), and the Gmail-web forward variant (hash recorded on first run and committed).

### 7.5 Default font/colour and signature
`ComposeStyle` wraps only the typed text; the signature sits in its own styled `div` so unstyled signatures inherit the defaults and inline styles inside win; the quote is outside `[html-rendering §5.2]`. `Settings.signatureHTML` is sanitized once on save (`SignatureSanitizer.sanitize`, keeps `https:` images); "Import from Gmail" copies `syncState.sendAsSignature` into the editor `[gmail-api §15]`. The editor warns on `data:` image URIs (Gmail does not render them `[mime-rfc §3.4]`). `Settings.signatureEnabled` toggles inclusion without deleting.

### 7.6 Forward with attachments (`[mime-rfc §6]`)
At **drain time** (never earlier; attachments are never prefetched): for each `ForwardAttachmentRef` still selected → `attachments.get(messageId, attachmentId)` using the stored id; on `nil`/404 → one `messages.get?format=full&fields=payload` to re-map by `partId`, `BodyRepository.updateAttachmentIds`, retry once. Verify `bytes.count == size` (log mismatch, continue). Budget check **before any network call**: `Σ size > 20 MB` → the job fails permanently with "Attachments too large to forward (x MB)" (Compose already disables Send above that). JSON `raw` path only in stage 1. Inline `cid:` parts are not re-attached; their `<img>` was removed from the quote (§7.2) and they are listed as normal attachments the user may include.

### 7.7 Send via outbox (`Outbox.performSend`)
```
performSend(op) -> Outcome:
    job = decode(op.sendJob)
    if op.transmitState == .maybeSent:
        found = gmail.listMessages(labelIds: [], q: "rfc822msgid:\(job.messageID)", maxResults: 1, pageToken: nil)   // [gmail-api §14 idempotency]
        if found.messages non-empty: db.write { deleteSend(op.id) }; sync.run(.afterSend); return .continue
    (me, style, signature) = await identity()
    atts = try fetchAttachments(job)                     // §7.6; permanent failure → fail(op) → .continue
    quoteHTML/Text = job.mode == .replyAll ? Quoting.replyHTML/Text(job.quoteSource, tz) : Quoting.forwardHTML/Text(…)
    html = OutgoingBodies.document(bodyFragment: OutgoingBodies.html(typed: job.typedText, style: style, signatureHTML: job.includeSignature ? signature : nil, quoteHTML: quoteHTML))
    text = OutgoingBodies.text(typed: job.typedText, signatureText: signature.map(Quoting.textFromHTML), quoteText: quoteText)
    bytes = MIMEBuilder.build(OutgoingMessage(from: me.primary, to: job.to, cc: job.cc, subject: job.subject, date: now, timeZone: .current,
                                              messageID: job.messageID, inReplyTo: job.inReplyTo, references: job.references, textBody: text, htmlBody: html, attachments: atts))
    db.write { setTransmitState(op.id, .maybeSent) }     // BEFORE the request leaves
    do { _ = try await gmail.send(raw: bytes, threadId: job.threadId); db.write { deleteSend(op.id) }; sync.run(.afterSend); return .continue }
    catch let e as GmailError {
        switch e {
        case .offline: retryLater(op, e, countsAsAttempt: false); return .stop
        case .unauthorized: retryLater(op, e, countsAsAttempt: false); return .stop
        case .network, .server, .rateLimited: retryLater(op, e); return .stop        // next attempt starts with the rfc822msgid check
        default: fail(op, e); return .continue                                     // 400 / 403 / decoding → Outbox section
        } }
```
A send becomes `failed` after 5 counted transient attempts or immediately on a permanent error; `Retry` resets it. `MailActions.send` wraps the first drain in `UIApplication.shared.beginBackgroundTask` `[ios-platform §3.5]`. The sent message appears through history (`messagesAdded` with `SENT`, known thread → fetched); nothing is inserted locally.

---

## 8. UI

### 8.1 Screens and navigation graph
```
RootView
 ├─ auth.state == .signedOut                → SignInScreen
 └─ .signedIn / .needsReauth                → NavigationStack(path)
       └─ InboxScreen                                          [root; scope switched IN PLACE via the title menu]
            ├─ push  ThreadScreen(threadId)                    NavigationLink(value: ThreadRoute)
            │         ├─ sheet ComposeScreen(input)            reply-all / forward
            │         └─ .quickLookPreview($previewURL)
            ├─ sheet LabelsScreen                              title menu "Labels…" → sets scope .label(id) and dismisses
            ├─ sheet SettingsScreen → push SignatureEditorScreen
            └─ sheet ComposeScreen(job)                        from an Outbox row
```
`ThreadRoute(threadId)`; `.navigationDestination(for: ThreadRoute.self)`; sheets via one `enum ActiveSheet { labels, settings, compose(ComposeInput) }`. Filter changes replace the observation in place (no push). That is the whole graph.

### 8.2 Screen contracts

| Screen | State (owned) | Actions | Empty / loading / error |
|---|---|---|---|
| **SignInScreen** | `auth.lastError`, `isSigningIn` | "Sign in with Google" (`.borderedProminent`) | error text under the button; `admin_policy_enforced` → Workspace-admin remedy text |
| **InboxScreen** / `InboxModel` | `query: ThreadQuery` (scope inbox/today/label, `unreadOnly`, `limit`), `rows: [ThreadRow]` (ValueObservation `.immediate`), `day: DayBoundary`, `counts (inboxUnread, today)`, `failedSends: [OutboxRecord]`, `hasOlder: Bool`, `syncStatus`, `activeSheet` | pull-to-refresh → `sync.run(.pullToRefresh)`; title menu Inbox / Today / Labels…; unread toggle; tap row → push; swipe leading Archive / trailing Read-Unread → `MailActions`; last row appears → `limit += 60`, then `sync.run(.loadOlderInbox/.loadOlderLabel)` when a page token exists; Outbox rows Retry/Delete/tap; `dayChanged()` on `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange`, scene active | `ContentUnavailableView("No Mail", systemImage: "tray")` / "Nothing today" (`sun.max`) / "All caught up" (`checkmark.circle`) / "No messages" (`tag`); first-ever sync: footer `ProgressView("Loading your inbox…")` while `phase == .initialSync`; `StatusBanner` rows (offline / "Couldn't refresh · Retry" / "Sign in again") — never a blocking alert |
| **ThreadScreen** / `ThreadModel` | `detail: ThreadDetail?` (ValueObservation on thread+messages+bodies+attachments), `expanded: Set<String>` (default: all unread + newest), `imagesAllowed: Set<String>`, `document: String`, `revision: Int`, `loading: Bool`, `previewURL: URL?`, `errorText` | onAppear → `sync.ensureThreadLoaded` + `markRead` if `settings.markReadOnOpen && unreadCount > 0` (not waiting for bodies); bottom bar Reply all · Forward · Archive (pops) · Read/Unread; in-document taps: header toggle (`evaluateJavaScript`, no reload), "Load images" (reload with images-on CSP + rule list), attachment (QuickLook), link (`openURL`) | headers render instantly from cache; per-message skeleton "Loading…" until the body lands; `bodyState == 2` → "Couldn't load this message · Retry"; thread gone → pop |
| **ComposeScreen** / `ComposeModel` | `draft` (mode, `to`/`cc` as comma-separated editable text, `subject`, `body: String`, `attachments: [(ref, included)]`, `includeSignature`), `quotePreview: String` (SwiftUI `Text`, read-only), `validation: String?`, `quoteReady: Bool` | Cancel (confirm if body non-empty), Send (disabled until ≥ 1 valid To and `quoteReady` and attachments ≤ 20 MB) → `MailActions.send(job)` → dismiss immediately (`.sensoryFeedback(.success)`) | validation text under To; never blocks on network |
| **LabelsScreen** / `LabelsModel` | Mailboxes section (Inbox with local unread count, Today with local count), Labels section (`Queries.labelsForSheet`, observed); refresh counts on appear if stale | tap → `onSelect(scope)` (dismiss + scope change); pull-to-refresh → `refreshLabelCounts(force: true)` | "No labels" before the first sync; footer "Counts from Gmail" |
| **SettingsScreen** | `@Bindable SettingsStore`, sync status line | see §11 | — |
| **SignatureEditorScreen** | `html` draft (monospaced `TextEditor`), throwaway `WKWebView` preview (`WebViewHost.makeThrowawayWebView`), `warning: String?` | Save (`SignatureSanitizer`), Import from Gmail | sanitizer error → inline text; `data:` image warning |

### 8.3 List row (`ThreadRowView`) — iOS Mail conventions
```
HStack(alignment: .top, spacing: 10)
  Circle 10pt (theme.unread) or Color.clear                        // leading, space always reserved
  VStack(alignment: .leading, spacing: 2)
    HStack { Text(participants).font(.headline).fontWeight(isUnread ? .semibold : .regular).lineLimit(1)
             [Text("\(messageCount)").font(.caption).foregroundStyle(theme.secondaryText)]   // only when > 1
             Spacer(); [Image(systemName: "paperclip").foregroundStyle(theme.secondaryText)]
             Text(dateLabel).font(.subheadline).foregroundStyle(theme.secondaryText) }
    Text(subject.isEmpty ? "(No subject)" : subject).font(.subheadline).lineLimit(1)
    HStack(alignment: .top) { Text(snippet).font(.footnote).foregroundStyle(theme.secondaryText).lineLimit(2); Spacer(minLength: 8); chips (≤ 2 capsules, .caption2, Gmail colours, fallback theme.chipBackground) }
.listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16))
```
Every string (`participants`, `dateLabel`, chip colours) is precomputed in the `ThreadRow` mapping on the reader thread (`trackingConstantRegion`); `body` does string → `Text` only, no formatting, no `Task`. `List(.plain)`, rows keyed by `id`, `Equatable` rows. Swipe actions `[ios-platform §5.2]`: leading full-swipe **Archive** (`Label("Archive", systemImage: "archivebox")`, `.tint(theme.swipeArchive)`); trailing full-swipe **Read/Unread** (`envelope.open` / `envelope.badge`, `.tint(theme.swipeRead)`). Haptics: `.sensoryFeedback(.impact(weight: .light), trigger: lastActionId)`, `.selection` on filter change, `.success` on send enqueue.

Toolbar: nav title = "Inbox" / "Today" / label name with `.toolbarTitleMenu { Inbox (tray) · Today (sun.max) · Labels… (tag) }`; trailing: unread-only toggle (`line.3.horizontal.decrease.circle` / `.fill`), `gearshape`. Thread bottom bar: `arrowshape.turn.up.left.2` Reply All · `arrowshape.turn.up.right` Forward · `archivebox` Archive · `envelope.badge`/`envelope.open`. Compose: leading Cancel, trailing Send (`paperplane.fill`). System text styles only; Dynamic Type honoured; colours only via theme tokens (`make lint` greps).

### 8.4 Thread screen conventions
- `MailWebView` fills the content area (the web view is the scroller); nav title = `SubjectPrefix.stripForDisplay(thread.subject)` inline; native bottom toolbar.
- Document = `ThreadDocument.render(...)` from `ThreadDetail`; rebuilt (string concat) and reloaded **only** when `detail` changes (bodies arrived), `imagesAllowed` changes, or theme / Dynamic Type changes; `revision` increments to signal `updateUIView`. Expand/collapse = `evaluateJavaScript(ThreadDocument.toggleScript(id))` — app JS keeps working with content JS disabled `[html-rendering §2.1]`; scroll position kept.
- Attachments render as rows inside each section (`paperclip` inline SVG, filename, size); tap → `AttachmentOpener.open(messageId, partId)` → stored `attachmentId` first, `messages.get?format=full&fields=payload` re-resolve on 404 → `tmp/attachments/<messageId>/<filename>` → `.quickLookPreview($previewURL)` `[ios-platform §5.4]`; "no longer available" note on a second 404.
- Links: `LinkPolicy` cancels every `.linkActivated` navigation; `http(s)`, `mailto:`, `tel:` are handed to `@Environment(\.openURL)` (system) in stage 1.
- Leaving the screen: `WebViewHost.recycle()` (empty document, process kept).

### 8.5 Compose screen conventions
`NavigationStack { Form { Section { TextField("To") ; TextField("Cc") ; TextField("Subject") } Section { TextEditor(text: $body).frame(minHeight: 200) } [Section("Attachments") { Toggle rows with size }] Section("Quoted") { Text(quotePreview).font(.footnote).foregroundStyle(.secondary).lineLimit(12) } } }` — plain `TextEditor` `[ios-platform §5.3]`; `AddressParser.parseList` on Send; the quoted original is shown read-only as `Text` built from `quoteSource.text` (no second web view, no height measuring).

### 8.6 Filters as SQL (`Queries.threads`)
```sql
-- Inbox                                                                     idx thread_inbox_date / thread_inbox_unread
SELECT id, subject, snippet, participants, lastDate, unreadCount, messageCount, hasAttachments, userLabelIds
FROM thread WHERE inInbox = 1 [AND unreadCount > 0] ORDER BY lastDate DESC LIMIT :limit;
-- Today (received into INBOX today, device time zone)                      idx thread_inbox_today
… FROM thread WHERE inInbox = 1 AND lastInboxDate >= :startMs AND lastInboxDate < :endMs [AND unreadCount > 0] ORDER BY lastInboxDate DESC LIMIT :limit;
-- Label                                                                     idx thread_label_date + PK lookup
SELECT t.id, t.subject, … FROM thread_label tl JOIN thread t ON t.id = tl.threadId
WHERE tl.labelId = :labelId [AND tl.unreadCount > 0] ORDER BY tl.lastDate DESC LIMIT :limit;
-- Counts
SELECT COUNT(*) FROM thread WHERE inInbox = 1 AND unreadCount > 0;
SELECT COUNT(*) FROM thread WHERE inInbox = 1 AND lastInboxDate >= :startMs AND lastInboxDate < :endMs;
```
`ValueObservation.trackingConstantRegion { db in try Queries.threads(q, now:, timeZone:, locale:, labels:)(db) }.start(in: pool, scheduling: .immediate, …)` — first paint synchronously from cache `[ios-platform §2.6]`; the observation is recreated when scope / unreadOnly / limit / `DayBoundary` change (day change also refreshes `dateLabel`s). "Today" is never a server `after:` query `[gmail-api gotcha 20]`. Thread detail: `SELECT * FROM message WHERE threadId = ? AND isHidden = 0 ORDER BY internalDate ASC` + bodies + attachments.

---

## 9. HTML rendering

### 9.1 Sanitizer (`MailHTML.Sanitizer`, runs in `SyncEngine` off main, outside the write transaction, `[html-rendering §1]`)
1. Guard `html.utf8.count <= maxInputBytes` (2 MiB), else throw `SanitizerError.tooLarge` (caller falls back to the plain part / snippet).
2. `SwiftSoup.parseBodyFragment(html, "")`.
3. For every `img`: `cid:X` → `minimail-cid://<messageId>/<percent-encoded X>` (X recorded in `referencedContentIDs`); `data:image/*` kept; `http(s)` → `data-src` = original, `src` = placeholder GIF, class `mm-remote`, `hasRemoteImages = true`; anything else → `src` removed; `srcset`/`sizes`/`loading` removed; `[background]` attributes dropped. Tracking-pixel heuristic (remote + (≤ 2 px or hidden) + no `alt`) → element removed `[html-rendering §1.5]`.
4. `DarkStrategyClassifier.classify(doc)`: declares `prefers-color-scheme` / `color-scheme:` / `supported-color-schemes` → `.native`; any author background (`background(-color):`, `bgcolor=`, `background=`) or (≥ 3 images and ≥ 2 tables) → `.card`; else `.plain` `[html-rendering §3.3]`.
5. `SwiftSoup.clean` with the exact whitelist of `[html-rendering §1.3]` (relaxed + `center font hr s del ins abbr address style wbr`; `style class dir lang align valign width height bgcolor border cellpadding cellspacing` on `:all`; `img[data-src]`; `font[face size color]`; `a[href title]`; `blockquote[type]`; protocols `a: http https mailto tel`, `img: data minimail-cid`; the enumerated CSS property allowlist; `preserveRelativeLinks(true)`; enforced `a[target=_self]`).
6. `StyleScrubber.scrub` regex pass (`@import`, `@font-face`, non-`data:` `url()`, `expression(`, `behavior:`, `-moz-binding`, `javascript:`, `position:fixed|absolute`).
7. Output `SanitizedBody`; any SwiftSoup throw → the caller uses `Sanitizer.fromPlainText(text ?? "")`; no text either → `"<p><i>This message could not be displayed.</i></p>"` + log `web.sanitize.failed`.

### 9.2 Thread document (`ThreadDocument.render`, `[html-rendering §2.7, §4]`)
```html
<!doctype html><html{ data-theme="dark|light" when forced }><head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: minimail-cid:{ https: when imagesAllowed}; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<style>
:root{color-scheme:light dark;--mm-bg:{light.bg};--mm-surface:…;--mm-text:…;--mm-secondary:…;--mm-accent:…;--mm-sep:…;--mm-link:…;--mm-card:…}
@media (prefers-color-scheme:dark){:root{--mm-bg:{dark.bg};…}}          /* primary path */
html[data-theme=dark]{--mm-bg:{dark.bg};…} html[data-theme=light]{--mm-bg:{light.bg};…}   /* fallback for forced themes (UNVERIFIED overrideUserInterfaceStyle propagation) */
html{-webkit-text-size-adjust:100%} body{margin:0;background:transparent;color:var(--mm-text);font:-apple-system-body;font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;overflow-wrap:break-word;-webkit-touch-callout:none}
h1.mm-subject{font:600 22px/1.2 -apple-system;margin:12px 16px 4px}
.mm-msg{border-top:1px solid var(--mm-sep)} .mm-hdr{padding:10px 16px;display:flex;gap:8px;align-items:baseline}
.mm-from{font-weight:600;flex:1} .mm-msg.mm-unread .mm-from::before{content:"";display:inline-block;width:8px;height:8px;border-radius:4px;background:var(--mm-accent);margin-right:6px}
.mm-date{color:var(--mm-secondary);font-size:13px} .mm-to{color:var(--mm-secondary);font-size:13px;padding:0 16px 8px}
.mm-body{padding:8px 16px 16px} .mm-collapsed .mm-body,.mm-collapsed .mm-to,.mm-collapsed .mm-att,.mm-collapsed .mm-images{display:none}
.mm-snippet{display:none} .mm-collapsed .mm-snippet{display:block;color:var(--mm-secondary);padding:0 16px 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mm-att{display:flex;gap:8px;padding:0 16px 12px;flex-wrap:wrap} .mm-att a{border:1px solid var(--mm-sep);border-radius:8px;padding:6px 10px;color:var(--mm-accent);text-decoration:none;font-size:13px}
.mm-images{margin:0 16px 8px;font-size:13px} .mm-images a{color:var(--mm-accent)} .mm-skeleton{color:var(--mm-secondary);font-style:italic}
img{max-width:100% !important;height:auto} table{max-width:100% !important} pre{white-space:pre-wrap} blockquote[type=cite]{margin:0 0 0 .8ex;border-left:2px solid var(--mm-sep);padding-left:1ex} .mm-remote{min-width:1px;min-height:1px} .mm-plaintext{white-space:pre-wrap}
@media (prefers-color-scheme:dark){ .mm-plain .mm-body{color:#E5E5EA} .mm-plain .mm-body a{color:var(--mm-link)} .mm-plain .mm-body [style*="color"]{color:inherit !important} .mm-plain .mm-body font[color]{color:inherit !important}
  .mm-card .mm-body{background:var(--mm-card);color:#000;color-scheme:light;border-radius:12px;margin:0 12px 12px;padding:12px;overflow:hidden} }
html[data-theme=dark] .mm-plain .mm-body{color:#E5E5EA} …same rules duplicated under html[data-theme=dark]…
</style></head><body>
<h1 class="mm-subject">{subject}</h1>
{for each message}
<section class="mm-msg {mm-unread?} {mm-collapsed|mm-expanded} {mm-plain|mm-card|mm-native}" data-id="{id}">
  <div class="mm-hdr" data-action="toggle"><span class="mm-from" title="{fromAddr}">{fromName}</span><span class="mm-date">{dateLabel}</span></div>
  <div class="mm-snippet">{snippet}</div>
  <div class="mm-to">To: {toLine}{<br>Cc: ccLine}</div>
  {if hasRemoteImages && !imagesAllowed}<div class="mm-images"><a data-action="images" href="#">Load images</a></div>{endif}
  <div class="mm-body">{bodyHTML | <span class="mm-skeleton">Loading…</span> | <span class="mm-skeleton">Couldn't load this message · <a data-action="retry" href="#">Retry</a></span>}</div>
  {attachments: <div class="mm-att">{<a data-action="att" data-part="{partId}" href="#">{svg paperclip} {filename} · {sizeLabel}</a>}</div>}
</section>
</body></html>
```
Taps are delivered by one `WKUserScript` (`.atDocumentEnd`, `forMainFrameOnly: true`) that installs a delegated `click` listener and posts `{action, id, part}` to `window.webkit.messageHandlers.mm`; `WebBridge` maps them to `WebMessage`. Per-body cap 1.5 MB (truncated + "Message truncated"), document cap 6 MB (oldest collapsed messages keep only the snippet until expanded). Plain-text-only mails render inside `<div class="mm-plaintext">`.

### 9.3 WKWebView setup (`WebViewHost`, `[html-rendering §2.4]`)
```swift
static func makeConfiguration(cid: CIDSchemeHandler, bridge: WebBridge) -> WKWebViewConfiguration {
    let c = WKWebViewConfiguration()
    c.defaultWebpagePreferences.allowsContentJavaScript = false          // content JS off; app JS on (WWDC20 10188)
    c.defaultWebpagePreferences.preferredContentMode = .mobile
    c.websiteDataStore = .nonPersistent()
    c.dataDetectorTypes = []
    c.suppressesIncrementalRendering = true
    c.setURLSchemeHandler(cid, forURLScheme: "minimail-cid")
    c.userContentController.add(RuleLists.blockAll)                      // swapped by setImagesAllowed
    c.userContentController.add(bridge, name: "mm")
    c.userContentController.addUserScript(WKUserScript(source: clickDelegateJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    return c
}
// WKWebView: allowsLinkPreview = false; isOpaque = false; backgroundColor = underPageBackgroundColor = theme background (set BEFORE the first load); navigationDelegate = LinkPolicy; scrollView.contentInsetAdjustmentBehavior = .automatic; overrideUserInterfaceStyle from ThemeStore; DEBUG: isInspectable = true
```
Rule lists compiled once via `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContentRuleList:)` after a `contentRuleList(forIdentifier:)` lookup, identifiers `minimail.block-all.v1` / `minimail.images-only.v1`, JSON exactly as `[html-rendering §2.2]`. `setImagesAllowed` uses `removeAllContentRuleLists()` + `add(_:)` (name UNVERIFIED → fallback §14 #4). Document loaded with `loadHTMLString(html, baseURL: nil)`. `LinkPolicy.decidePolicyFor`: `.linkActivated` → cancel + `openURL`; `.other` allowed only for `about:blank`; everything else cancelled `[html-rendering §2.5]`. `prepare()` runs ~1 s after the first inbox paint: rule lists, instance creation, `ThreadDocument.empty` warm-up. On memory warning or 60 s after leaving the thread screen the instance is recycled (DOM dropped, process kept).

### 9.4 Image blocking and "Load images"
Default (`settings.loadRemoteImages == false`): block-all rule list + CSP `img-src data: minimail-cid:` + placeholders → the web view never touches the network. Tap "Load images" (per message) or the setting on → `imagesAllowed.insert(id)` → `ThreadDocument.render(imagesAllowed: true)` restores `data-src` → `src` **for that message only**, CSP gains `https:`, rule list swapped to images-only → `loadHTMLString` (local, tens of ms). Tracking pixels were removed at sanitize time. Scope is per thread view (no per-sender memory in stage 1). Inline `cid:` images load automatically through `CIDSchemeHandler` → `InlineImageStore.bytes` (`Caches/cid/<messageId>/<sha1(cid)>` → `attachments.get` with the stored id, re-resolve once on 404; ≤ 2 requests in flight; failures cached 60 s so a newsletter with 30 broken references costs one burst, not a storm); stopped `WKURLSchemeTask`s are tracked in a `Set<ObjectIdentifier>` so a late completion is never delivered.

### 9.5 Dark mode
No inversion `[html-rendering §3]`. `color-scheme: light dark` + transparent body so the themed `UIView` colour shows through; per section `mm-plain` (dark overrides), `mm-card` (white card, `color-scheme: light`), `mm-native` (sender's own dark CSS). `webView.overrideUserInterfaceStyle` follows `ThemeStore.preferredColorScheme`; the template additionally carries `html[data-theme]` selectors and the app sets `data-theme` on `<html>` for forced themes, so the fallback is free (`[html-rendering §7]`). Dynamic Type change (`UIContentSizeCategory.didChangeNotification`) → rebuild + reload.

### 9.6 Sizing
None. The web view is the scroller; no `scrollHeight` measuring, no `ResizeObserver`, no per-message web views `[html-rendering §4]`. Viewport `width=device-width, initial-scale=1` with pinch-zoom allowed; `img,table{max-width:100%!important}`.

---

## 10. Theming

```swift
struct ThemeTokens: Equatable, Sendable {
    var background, groupedBackground, surface, text, secondaryText, accent, unread, separator, link, chipBackground, swipeArchive, swipeRead: Color
}
protocol Theme: Sendable {
    var id: String { get }                       // "light", "dark" — stable, persisted
    var name: String { get }
    var colorScheme: ColorScheme { get }         // what SwiftUI/WebKit render as when this theme is forced
    var tokens: ThemeTokens { get }
    func cssTokens(for scheme: ColorScheme) -> ThemeCSSTokens   // hex via UIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle:))
}
struct LightTheme: Theme { let id = "light"; let name = "Light"; let colorScheme = ColorScheme.light; let tokens = ThemeTokens.system }
struct DarkTheme:  Theme { let id = "dark";  let name = "Dark";  let colorScheme = ColorScheme.dark;  let tokens = ThemeTokens.system }
extension ThemeTokens {   // stock themes = system semantic colours (adapt to Increase Contrast, Smart Invert, etc.)
    static let system = ThemeTokens(background: Color(.systemBackground), groupedBackground: Color(.systemGroupedBackground), surface: Color(.secondarySystemBackground),
        text: Color(.label), secondaryText: Color(.secondaryLabel), accent: Color(.tintColor), unread: Color(.systemBlue), separator: Color(.separator),
        link: Color(.link), chipBackground: Color(.tertiarySystemFill), swipeArchive: Color(.systemIndigo), swipeRead: Color(.systemBlue))
}
enum ThemeChoice: String, Codable, CaseIterable, Sendable { case system, light, dark }
@Observable final class ThemeStore {
    static let registry: [String: any Theme] = ["light": LightTheme(), "dark": DarkTheme()]   // add a theme = one struct + one entry
    var choice: ThemeChoice { didSet { settings.update { $0.themeChoice = choice } } }
    func resolved(for systemScheme: ColorScheme) -> any Theme      // .system → light/dark by systemScheme
    var preferredColorScheme: ColorScheme? { choice == .system ? nil : resolved(for: .light).colorScheme }
    var forcedDocumentTheme: String? { preferredColorScheme.map { $0 == .dark ? "dark" : "light" } }   // html[data-theme]
    var interfaceStyle: UIUserInterfaceStyle                       // for overrideUserInterfaceStyle and UIWindow chrome
}
```
`RootView` applies `.preferredColorScheme(theme.preferredColorScheme)`, `.tint(tokens.accent)` and `.environment(themeStore)`; views read `@Environment(ThemeStore.self)` + `@Environment(\.colorScheme)` through a `themeTokens` view helper and never raw colours (`make lint`). The web template receives both `cssTokens(for: .light)` and `cssTokens(for: .dark)` so the media query and `data-theme` paths both work. `LaunchBackground` colour asset = light `systemBackground` / dark `systemBackground` (any-appearance + dark variant). Extensibility: a future theme (e.g. a JSON `struct JSONTheme: Theme`) supplies its own `tokens`/`cssTokens`; `ThemeChoice` gains a `.custom(id)` case later; nothing in the views changes.

---

## 11. Settings model

```swift
struct Settings: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var themeChoice: ThemeChoice = .system
    var composeStyle: ComposeStyle = ComposeStyle()          // helvetica / 14 px / #000000
    var signatureHTML: String = ""                           // sanitized on save
    var signatureEnabled: Bool = true
    var loadRemoteImages: Bool = false                       // images off by default (PLAN.md)
    var markReadOnOpen: Bool = true
    var showBadge: Bool = false                              // flips true only after [.badge] authorization succeeds
    var inboxPageSize: Int = 100                             // 50…200
    var lastSignedInEmail: String? = nil                     // login_hint only; identity lives in syncState
}
@Observable final class SettingsStore {
    static let key = "de.newtelco.minimail.settings"
    private(set) var settings: Settings
    init(defaults: UserDefaults = .standard)                 // JSON decode with decodeIfPresent per field; failure → defaults + log
    func update(_ change: (inout Settings) -> Void)          // encodes .sortedKeys, writes synchronously
    var snapshot: Settings { settings }                      // Sendable copy for actors
}
```
Settings screen (Form): **Account** (email from `syncState`, "Sign out" destructive) · **Appearance** (Theme: System / Light / Dark) · **Compose** (Font family, Size 12–18, `ColorPicker` bound through hex, Signature → editor with Import from Gmail, Use signature toggle) · **Reading** (Load remote images automatically; Mark as read when opened) · **Notifications** (Show unread count on icon → `requestAuthorization([.badge])` in context; denied → toggle turns itself off with an explanation) · **Advanced** (Sync status line: last sync, historyId, pending/failed outbox counts; "Full resync now"; DEBUG: "Recent requests"; version/build). `PrivacyInfo.xcprivacy` declares `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` `[ios-platform §7]`.

---

## 12. Performance & battery budget

### 12.1 Targets (iPhone 12-class, Release, cached inbox of 100 threads; measured with the `OSSignposter` intervals of §6.5 via `log stream --predicate 'subsystem == "de.newtelco.minimail"'` on device — no CI gate)

| Metric | Target | How it is met |
|---|---|---|
| Cold start → first list paint | **< 400 ms** (stretch 250 ms) | launch order §12.2: settings decode + DB open/migrate (< 10 ms) + one indexed read before the first frame; nothing else |
| Delta refresh, no changes | < 600 ms, 1 request | single `history.list`; counts throttled |
| Delta refresh, ≤ 5 new messages | < 1 s | history + one 25-part metadata batch; one transaction |
| Initial sync (100 messages) | < 6 s | list + 4 sequential metadata batches, each its own transaction (list fills progressively) |
| Thread open, cached & complete | < 16 ms to `loadHTMLString`, < 120 ms painted | one SQL read + string concat on a warm web view |
| Thread open, incomplete | 1 round trip; < 1.5 s on LTE | `threads.get?format=full`; sanitize off main |
| Scroll | 0 hitches at 120 Hz | precomputed rows, one partial index, `limit` paging, no images in rows |
| Swipe archive → row gone | next frame | one transaction (label delta + outbox row + aggregate) → observation tick |
| Memory | app < 60 MB steady; WebContent out of process | one `WKWebView`; DOM dropped on recycle; bodies only for the open thread |
| Network / foreground sync | ≤ 3 requests, 20–80 KB | `fields=`, `prettyPrint=false`, metadata format, no prefetch |
| Background | ≤ 1 `history.list` + ≤ 2 batches per BG refresh; 0 body fetches | §4.10 |
| Quota | ≤ 2,600 pessimistic units in any minute | sequential 25-part batches; limiter(2); no speculative work |
| Battery | no measurable idle drain; BG activity < 1 %/24 h | no timers, sockets, location, analytics, path monitor, background URLSession; web view cannot reach the network |

### 12.2 Launch order (strict; `AppEnvironment.init` + `RootView`)
1. `MinimailApp.init` → `AppEnvironment.init`: `SettingsStore` (one UserDefaults JSON decode), `Database.open` (+ migrate: no-op when current), `Keychain.exists` (attributes only), `syncState.accountEmail` read, `AuthStore.init` (routing state), `ThemeStore`. Budget < 15 ms. No AppAuth, no network, no `WKWebView`, no `UNUserNotificationCenter`, no `BGTaskScheduler`, no NotificationCenter observers beyond scene phase.
2. `RootView` routes on `auth.state`; `InboxScreen` starts the `.immediate` observation → synchronous fetch of ≤ 60 `ThreadRow`s from the covering index → **first frame**.
3. `.task` after the first frame (`await Task.yield()` twice): `tokens.load()` (Keychain unarchive off main) → `OutboxRepository.releaseInFlight()` → `sync.run(.launch)`; **+1 s**: `WebViewHost.prepare()`; **+2 s**: `BackgroundRefresh.schedule()`, `Maintenance.cleanup()`, `sync.updateBadge()`.
4. Static SPM linking, `ONLY_ACTIVE_ARCH` in Debug, `LaunchBackground` colour asset instead of a storyboard.

### 12.3 Tactics
Never block main: all `DatabasePool.read/write` from actors use the `async` forms; UI only observes. Sanitize and MIME build on the actor, outside the writer lock. No speculative work: no body/attachment/image prefetch, no label counts beyond the displayed labels, no reconcile. Throttle: foreground `run` at most once per 60 s unless pulled; `run` coalesces callers; label counts 5 min. Web view: created once after first paint, warmed, reused, recycled on leave. Rule lists compiled once, looked up by identifier. Badge only when enabled. BG discipline: `Task.isCancelled` between steps; bail on `SQLITE_AUTH`/`SQLITE_IOERR`; reschedule first. Perf tests: `QueriesTests.testInboxQueryUnder5msWith5000Messages` (`measure {}` + `EXPLAIN QUERY PLAN` contains the intended index) and `SanitizerTests.testNewsletter500KBUnder150ms`.

---

## 13. Testing strategy

### 13.1 Layers
| Layer | Runner | What | Count |
|---|---|---|---|
| `MailCoreTests` | `swift test` (Linux + macOS), seconds | every pure algorithm, table-driven from the research vectors | ~150 |
| `MailHTMLTests` | `swift test` (macOS; Linux if SwiftSoup builds) | sanitizer, classifier, scrubber, quote extractor, signature sanitizer | ~35 |
| `minimailTests` | `xcodebuild test` on the simulator, minutes | DB schema/queries/repositories + invariants, sync engine, resync, outbox + conflicts, sends, client, keychain, web host config, smoke hosting of screens | ~60 |
| Manual device checklist | owner's iPhone via TestFlight (`docs/plan/device-checklist.md`, written in M2) | real OAuth, BG refresh while locked, dark mode in the web view, QuickLook, badge prompt, rule-list/CSP/JS-toggle verification, quota page fetch | 1 checklist |

No XCUITest target, no snapshot tests, no CI launch gate (decision 15). `SmokeTests` instantiates `InboxScreen`/`ThreadScreen`/`ComposeScreen` inside `UIHostingController` with a seeded in-memory DB (`MINIMAIL_TESTING=1` → `AppEnvironment(testing: true)` uses `StubURLProtocol` + `DatabaseQueue`) and asserts observable model state (row count, rendered document contains the seeded subject, prefilled recipients).

### 13.2 `MailCore` / `MailHTML` tests and fixtures
- `Base64URLTests` (§8.3 vectors), `QuotedPrintableTests` (7 rows incl. `-- ` → `--=20`), `RFC2047Tests` (9 decode rows + encode round-trips), `RFC2231Tests` (6 filename rows + encoder for `Ängebot.pdf`), `CharsetsTests` (alias table, `*lang`, fallback chain), `AddressParserTests` (§8.4 table + groups/obs-route/folded), `MailboxSerializationTests`, `HeaderDateTests` (format in Europe/Berlin and UTC; attribution with U+202F; tolerant parse), `HeaderFoldingTests`, `ContentTypeParamsTests`, `MessageIDsTests` (split, normalize, references chain per RFC 5322 §3.6.4 cases).
- `GmailDTOTests`: every fixture JSON decodes; `StringUInt64` from string and number; unknown keys ignored; metadata payload without `parts`.
- `MessageParserTests`: shapes (a)–(h) of `[mime-rfc §5.2]`; charset handling (ISO-8859-1, windows-1252, missing); inline vs attachment classification; deferred text parts; `topMimeType` and headers from a metadata payload.
- `BatchCodecTests`: encode byte-exact against `[gmail-api §12]`; decode the probe response (200 + 401 parts), out-of-order ids, missing part, garbage.
- `MIMEBuilderTests`: byte-exact reply (`b9f8078c…`, 2276 bytes) and forward (`2127dc54…`, 2927 bytes) with fixed boundaries/date/UUID; Gmail-web forward variant (recorded on first run); structural checks (CRLF only, ≤ 998 octets, `MIME-Version` once, base64 76 cols, RFC 2231 name, folding at 78).
- `ReplyAllTests` (16 rows), `SubjectPrefixTests` (§8.2 + `stripForDisplay`), `QuotingTests` (attribution, reply skeleton, `> `/`>` rules, forward banner 10/9 dashes, header order, Cc omitted when empty, `textFromHTML`), `OutgoingBodiesTests` (wrapper, `<div><br></div>`, escaping, signature block, quote outside, no color-scheme meta), `PlainTextHTMLTests`, `ComposeStyleTests` (clamp, hex validation).
- `ThreadDocumentTests`: CSP variants, `data-theme` attribute, one section per message with the right classes, `data-src` restored only for the allowed message, caps (1.5 MB / 6 MB), escaping of header fields, `toggleScript`.
- `LabelAlgebraTests`, `HistoryReducerTests` (add→delete cancels, delete→add re-adds, chronological ops, `finalLabels` last-wins, multi-page, empty history keeps historyId, touchedThreads), `HydrationPolicyTests` (rule matrix), `OutboxCoalescerTests` (inverse cancels, merge, idempotent), `BackoffTests` (injected random, cap, Retry-After precedence), `ThreadAggregatorTests` (subject from oldest, snippet from newest, counts, `lastInboxDate` ignores non-INBOX and self-sent, participants "Me"/dedupe/max 3, `allLabelIds`, empty → nil), `DayBoundaryTests` (DST edges Europe/Berlin, Pacific/Auckland, UTC; 23:59:59 vs 00:00:00; `RowDateLabel` matrix for `de_DE` and `en_US`).
- `MailHTMLTests`: script/iframe/form/meta/`javascript:`/`on*` removed; remote img → placeholder + `data-src`; cid rewrite + referenced set; data: image kept; tracking pixel removed; `<style>` scrub cases; classifier matrix (plain/card/native fixtures); malformed HTML (`<!--[if mso]>`, unclosed tags) does not throw; 2 MiB guard throws; `SignatureSanitizer` keeps https img, drops script; `QuoteExtractor` restores `data-src`, removes cid `<img>` and `mm-*` classes; performance case.
- Fixtures (`Tests/MailCoreTests/Fixtures/`): `gmail/profile.json`, `labels.list.json`, `labels.get.{inbox,user}.json`, `messages.list.inbox.{1,2}.json`, `messages.get.metadata.{plain,multipart,nonascii,folded-references,no-message-id}.json`, `messages.get.full.{a..h}.json`, `messages.get.full.large-text-attachmentid.json`, `threads.get.full.json`, `attachments.get.{png,pdf}.json`, `history.{empty,added,deleted,labels,mixed,added-then-deleted,paged-1,paged-2,own-modify-echo,trash}.json`, `history.404.json`, `error.{401,403-rate,403-admin,429,500,400-invalid-history}.json`, `threads.modify.response.json`, `send.response.json`, `sendas.list.json`, `batch.request.sample.txt`, `batch.response.{sample,mixed,all-fail}.txt`; `mime/reply-all.eml` + `.sha256` + `.raw.txt`, `mime/forward-pdf.eml` (+ gmail-web variant), `mime/stub.pdf`; `vectors/*.json` (QP, RFC 2047, base64, RFC 2231, addresses, reply-all, subject, today). `Tests/MailHTMLTests/Fixtures/html/`: `newsletter.html`, `plain-mail.html`, `dark-native.html`, `tracking-pixels.html`, `malformed.html`, `inline-cid.html`, `signature.html`, `xss-samples.html`. The app test bundle copies the `MailCoreTests/Fixtures` folder (project.yml).

### 13.3 App tests (`minimailTests`)
- `DatabaseTests`: fresh DB matches the DDL (`sqlite_master` compare), foreign keys on, invariants hold on an empty DB, cascade deletes.
- `RepositoryTests`: `upsertMetadata` keeps the body row and recomputes E; `applyServerLabels/Delta`; `enqueueModify` coalescing (read→unread → 0 rows; archive + read → one merged op; inFlight not merged); `ackModify` with and without server labels; `discardModify` reverts E; `releaseInFlight`; `rearmFailedModifies`; `staleIds` excludes outbox-referenced ids; `recomputeAggregates` deletes empty threads and rewrites `thread_label` — each followed by `InvariantChecks.assertAll`.
- `QueriesTests`: seeded 5,000 messages; each scope × unreadOnly returns the expected ids; Today boundary with `lastInboxDate`; label scope via `thread_label`; `EXPLAIN QUERY PLAN` names the intended index; `measure` < 5 ms; `ThreadRow` precomputation (participants, dateLabel, chips).
- `SyncEngineTests` (`StubURLProtocol` + in-memory DB): full sync request sequence and count; progressive per-chunk commits; delta applies added (fetch)/deleted/labels/finalLabels/unknown-message-gains-INBOX; hydration policy skips SPAM-only; `historyId` never decreases; `tooManyRecords` → resync; label view hydration; load older pages; `ensureThreadLoaded` incomplete → one `threads.get?format=full`, complete → bodies batch; deferred text part; sanitizer failure fallback; body fetch does not undo a pending read op (the SIMPLE race).
- `ResyncTests`: 404 and 400-invalid → generation resync; non-relisted rows deleted except outbox-referenced; bodies of relisted messages survive; `isComplete` reset for threads that lost members; cached label views re-hydrated; delta from the new baseline.
- `OutboxTests`: batch of mixed part results (200/404/400/429/500/401); backoff scheduling with injected random; attempts not counted for offline/unauthorized; failed after 8 → re-armed on foreground; permanent 4xx reverts E; debounce coalesces a burst of swipes into one batch; drain stops on offline.
- `ConflictTests` (interleavings, invariants after each step): (1) archive locally, history says another client marked unread, ack arrives → E = server ∖ INBOX with UNREAD; (2) ack before history echo; (3) echo before ack; (4) full resync while an op is pending → message kept, op applied after resync; (5) op 404 → row removed by next delta; (6) two rapid toggles → zero network calls; (7) thread op + later-arriving message untouched locally; (8) body fetch during a pending mark-read keeps the thread read.
- `SendTests`: `maybeSent` + `rfc822msgid:` found → no second POST; not found → resend; attachment re-resolution on 404; > 20 MB refused before network; permanent 400 → failed row + Outbox section state; quote built from the snapshot after the body cache was wiped; Date stamped at build time.
- `GmailClientTests`: URL shape (repeated params, fields, prettyPrint), status → error mapping table, `historyExpired` only for the history endpoint, 401 → refresh → retry → 401 → unauthorized, retry counts per error, `Retry-After`, batch chunking at 25, per-part retry rounds, limiter caps concurrency at 2, send never auto-retried.
- `KeychainTests` (simulator round trip, `exists`), `WebViewHostTests` (configuration flags, rule-list JSON compiles, CSP variants in the document), `SmokeTests`.

### 13.4 CI
See §1.7. The `core` job is the fast signal (~2 min); the `ios` job also runs the package tests so a Linux toolchain problem never blocks a merge.

---

## 14. Risks and open questions — with chosen resolutions

| # | Risk / UNVERIFIED item | Resolution |
|---|---|---|
| 1 | SwiftSoup on Linux (`[html-rendering §1.1]`) | `MailHTML` is a separate product; `MAILCORE_SKIP_HTML=1` omits it on Linux; `MailHTMLTests` then run on macOS only. |
| 2 | Swift 6 + MainActor default vs GRDB/AppAuth closures (`[tooling §3.3]`) | Packages are nonisolated; engine/store code is explicit actors/`nonisolated`; `@preconcurrency import AppAuth`; `OIDAuthState` owned by the token actor (`sending` on adopt). Escape hatch order: `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, then Swift 5 + complete checking. Decide in M1 on the first `pool.write`. |
| 3 | `evaluateJavaScript` / message handlers with `allowsContentJavaScript = false` | WWDC20 wording says app JS keeps working `[html-rendering §2.1]`; device check in M2; fallback: rebuild + reload on toggle with `scrollTo` restore (local, loses nothing but position). |
| 4 | `removeAllContentRuleLists()` name; CSP `img-src minimail-cid:` acceptance; newer `resource-type` values | Verify in SDK headers / on device in M2. Fallbacks: a second `WKWebViewConfiguration` (images-on) with its own instance swapped in for that document; drop `minimail-cid:` from the CSP and rely on the rule list (custom-scheme loads are not `https`); images-only list without `resource-type` + CSP carrying the images-on policy. |
| 5 | `overrideUserInterfaceStyle` → `prefers-color-scheme` propagation | Template ships `html[data-theme]` selectors from day one (§9.5); both paths written. |
| 6 | `historyId` expiry after long offline periods; 400 code for malformed ids | Generation resync (§4.2) is the routine path; 404 and 400-`failedPrecondition`/"historyId" both map to `.historyExpired`. |
| 7 | Quota-unit table (`messages.get` 20 vs 5; 6,000/min) `[gmail-api "Quotas"]` | Designed for the pessimistic numbers; the agent fetches the quota page in M1 and may only relax `inboxPageSize`/batch size upward. |
| 8 | History change records may lack `message.labelIds` | `HistoryReducer` carries both `finalLabels` and deltas; both paths tested. |
| 9 | Send idempotency (no server key); `rfc822msgid:` index lag | Own `Message-ID`; `transmitState = maybeSent` before the POST; check before any retry, which runs ≥ 2 s later. Residual duplicate risk logged as `outbox.send.duplicate-risk`. |
| 10 | Workspace admin policy (`admin_policy_enforced`) | Owner checklist before first login; sign-in screen shows the exact remedy. |
| 11 | Badge needs notification authorization; `[.badge, .provisional]` UNVERIFIED | Opt-in toggle requests `[.badge]` only; denied → toggle off with explanation. |
| 12 | BG refresh while locked → `SQLITE_AUTH`/`SQLITE_IOERR` | Directory `.completeUntilFirstUserAuthentication`; handler bails; Keychain item `AfterFirstUnlockThisDeviceOnly`. |
| 13 | `attachmentId` instability | Transient column; stored id tried first, one re-resolve via `messages.get` on 404 (attachments, inline images, forwards). |
| 14 | Large text bodies delivered by `attachmentId` | `deferredTextParts` path in `prepareBody`. |
| 15 | `hd` / `prompt=consent` for the native flow UNVERIFIED | Optional; retried without them on failure; sign-in never blocks on them. |
| 16 | Refresh token missing after sign-in | One retry with `prompt=consent`, then `missingRefreshToken` error shown (stay signed out). |
| 17 | GRDB API names (`eraseDatabaseOnSchemaChange`, `AnyDatabaseCancellable`) and `Context.environment` in `Package.swift` | Compile-time facts; fixed on first build; no design impact. |
| 18 | Thread completeness — a delta reply to a thread we have never seen | Fetched with metadata (in scope), `isComplete = 0`; first open does `threads.get?format=full`. |
| 19 | "Today" across midnight / time-zone changes | `DayBoundary` recomputed on `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange`, scene active; no timers; device time zone; never server `after:`. |
| 20 | Whole-thread read/unread differs from Gmail web's per-message state | Accepted; per-message ops can be added later through the same outbox (`affectedMessageIds` already supports it). |
| 21 | Inline `cid:` images not re-attached on forward | Documented; `<img>` removed from the quote, part listed as a normal attachment; stage 2: `multipart/related`. |
| 22 | Generation resync drops "Load older" pages | Accepted (rare: > 7 days offline); the user taps Load older again; bodies of relisted threads survive. |
| 23 | Xcode 27 arrival (2026-09-14) | Stay on 26.6 until the runner has 27 GA; `BGTaskScheduler.submitTaskRequest` branch under `#available(iOS 27)` `[ios-platform §3.3]`. |
| 24 | XcodeGen `type: folder` for the fixture copy | Fallback: `sources` entry with `excludes: ["**/*.swift"]`. |
| 25 | `URLSession` cannot report whether a send body was fully transmitted | Every network error after `maybeSent` is treated as "maybe sent" → the idempotency check decides. |
| 26 | Dynamic Type inside the web view without reload | Reload on `UIContentSizeCategory.didChangeNotification`. |

---

## 15. Decision log (where the judges disagreed, or where this design departs from SIMPLE)

| # | Topic | Decision | Rationale |
|---|---|---|---|
| D1 | Base candidate | SIMPLE (aggregate 134 vs 126 vs 117; 2 of 3 judges), grafted with SPEED's launch path / thread table / limiter and ROBUST's S/P/E model / outbox semantics / generation resync / hydration policy / Linux-clean core. | Highest implementability for a headless agent; every correctness hole the judges found is closed by a graft, not by adding machinery. |
| D2 | Label state: two columns (S/P/E) vs "re-apply pending deltas in every write" | **Two columns + `recomputeEffective`.** | Judges 2 and 3 asked for it; Judge 3 accepted the alternative only "at minimum". One column and one pure function make the invariant testable and remove the race class entirely. |
| D3 | Threads: maintained table vs SQL VIEW | **Maintained `thread` table + `thread_label` junction**, aggregator inside the write transaction. | Judge 1 graft, Judge 2 flaw on SIMPLE; list ticks must be one indexed read; label views need an index, not `instr` over JSON or a correlated `json_group_array`. |
| D4 | Hydration: `threads.list`+`threads.get` (SIMPLE) vs `messages.list`+`messages.get` (SPEED/ROBUST) | **`messages.list` + metadata batches; `isComplete` flag; one `threads.get?format=full` on first open.** | Half the pessimistic quota `[gmail-api gotcha 11]`; fixes SIMPLE §4.3's `threads.get` for every unknown thread; fixes ROBUST's two round trips on open (Judges 1 and 2). |
| D5 | Resync after `historyId` 404 | **Generation-based deletion** (rows not relisted and not outbox-referenced), `isComplete` reset for survivors; **no** reconcile via `messages.get?format=minimal`, **no** daily Reconciler. | Judges 1–3 rejected the wipe and the reconciler; a minimal-format reconcile of 200 cached ids costs 4,000 pessimistic units — not cheap. Load-older loss accepted (§14 #22). |
| D6 | Outbox transport | **`threads.modify` parts in one HTTP batch with per-part results; one pending op per thread; no `batchModify`.** | Judge 2 flaw on SPEED §4.9; `[gmail-api §8]` (204, no per-id result). |
| D7 | Transient modify failures | **Never delete; `failed` after 8 counted attempts, re-armed on foreground/pull.** Permanent 4xx removes + reverts. | Judge 1 flaw on SIMPLE §4.8; Judge 2 graft. |
| D8 | Send transmit state | `transmitState ∈ {notSent, maybeSent}` (ROBUST's third value `sent` is the row's deletion). | Same semantics as ROBUST §7.7, one fewer state. |
| D9 | Undo toast, compose autosave, Diagnostics screen, configurable swipes, `hapticsEnabled`, `forwardKeepsThread`, per-scheme theme ids, token-bucket limiter, Pruner | **Dropped** (non-goals §16). Settings → Advanced keeps a sync-status line, "Full resync now" and a DEBUG request log (~40 lines). | Judges 1 and 3 called them stage-1 scope creep; Judge 2's Diagnostics graft is satisfied by the Advanced section. |
| D10 | Body prefetch | **None.** Bodies only on open, never in BG. | PLAN.md; all three judges. |
| D11 | Network reachability | **No `NWPathMonitor`.** `.offline` comes from `URLError`; the next trigger retries. | Judges 1 and 2 listed the monitor as speculative/battery cost. |
| D12 | Second `WKWebView` | **Thread view only.** Compose quote = SwiftUI `Text`; signature editor uses a throwaway instance only while visible. | PLAN's one-instance rule; Judges 1–3. The pooled instance may sit under the Settings sheet, so a throwaway is safer than reuse. |
| D13 | Tests | **No UI-test target, no snapshot tests, no CI launch gate.** | Judge 1 flaw on SPEED §12.3; SIMPLE decision 9. |
| D14 | Theme colours | **System semantic colours for stock themes; hex only for CSS variables.** | Judges 1 and 3 flaw on fixed hex palettes. |
| D15 | Filter UI | **`.toolbarTitleMenu` (Inbox / Today / Labels…) + trailing unread toggle**, not a segmented control. | Judges 2 and 3 preferred the Mail-like title menu. |
| D16 | "Today" semantics | **Threads with a message received into INBOX today** (`lastInboxDate` within the day; upper bound included). | Judge 2 flaw on `lastDate` (counts own replies); Judge 1 flaw on ROBUST including archived threads. |
| D17 | Package split | **`MailCore` (zero deps) + `MailHTML` (SwiftSoup)**; fixtures inside each test target. | Judge 3 graft; ROBUST's `../Fixtures` rejected by SwiftPM. |
| D18 | Cache bounds | **Three-statement `Maintenance.cleanup`** once per 24 h. | Judge 2 wanted a bound; Judges 1/3 rejected a Pruner with byte accounting. |
| D19 | Read/unread granularity | **Whole thread.** | SIMPLE simplification; consistent with `threads.modify` archive `[gmail-api gotcha 8]`. |
| D20 | `mailto:` links | **Handed to the system** (`openURL`). | Compose-new is out of scope; nothing in-app can act on it yet. |
| D21 | Label counts | **Local for Inbox/Today/Unread and the badge; server `threadsUnread` for other labels, throttled to 5 min / sheet open.** | Judges 1–3 (throttle); SPEED §4.7. |
| D22 | Launch routing | **Keychain existence check (sync, < 5 ms) + `syncState.accountEmail`** (truth table §5.2); token unarchive after the first frame; reauth = dismissable banner over the cached list. | Judge 2 flaw on SPEED §12.2; Judge 1 flaw on ROBUST §8.1. |
| D23 | BG refresh content | delta + throttled counts + outbox drain + badge; no bodies. | `[ios-platform §3.4]` plus the drain (small, user-initiated intent). |
| D24 | Forward threading & inline images | `threadId` + `In-Reply-To` + `References` on forwards; cid `<img>` removed from the quote, part offered as attachment; JSON `raw` path only, 20 MB cap. | `[mime-rfc §1.5, §7.3]`; Judge 2 "all three" flaw. |
| D25 | Hidden labels | `isHidden` = TRASH ∨ SPAM ∨ DRAFT ∨ CHAT. | ROBUST §3.3; Judge 2 graft. |
| D26 | Signature preview | Throwaway `WKWebView` with the block-all list (no cid handler). | Judge 2 graft. |
| D27 | Concurrency cap | `RequestLimiter(2)` + sequential 25-part batches, no token bucket. | Judge 1 graft (SPEED §6.2); `[gmail-api gotcha 24]`. |

---

## 16. Non-goals (explicitly deferred to stage 2+)

Compose new mail (and therefore in-app `mailto:` handling); search / FTS5; multiple accounts or account switching; push (`watch` + Pub/Sub + APNs); snooze; Gmail drafts UI / draft autosave / "Resume draft"; undo toast; per-message read/unread; move-to-label / star / trash / spam actions; configurable swipe actions; haptics toggle; per-scheme theme ids or JSON themes (the `Theme` protocol is ready for them); Diagnostics screen with copy/export; daily reconcile pass; body prefetch; network path monitoring; media-upload send path for > 20 MB forwards; re-attaching inline `cid:` images on forward (`multipart/related`); per-sender "always load images" memory; UI tests and snapshot tests; CI launch-time gates; iPad / landscape; localisation beyond English strings.

---

## Appendix A — Detailed-spec module list (implementation order)

| id | name | dependsOn |
|---|---|---|
| 01-project-setup | Project, tooling, CI, app skeleton incl. Theme/ThemeStore and Settings struct/store (no screens) | — |
| 02-mailcore-mime | MailCore: encodings, headers, MIME builder, compose assembly | 01 |
| 03-mailcore-gmail-model | MailCore: Gmail DTOs, payload parser, batch codec | 01, 02 |
| 04-auth | AppAuth token actor, AuthStore, Keychain, sign-in screen | 01 |
| 05-gmail-client | GmailClient actor, error taxonomy, limiter, retries, batching | 03, 04 |
| 06-storage | Schema, records, repositories, queries, label algebra, aggregator, day boundary | 01, 03 |
| 07-sync-outbox | SyncEngine, HistoryReducer/HydrationPolicy, Outbox, MailActions, BG refresh, maintenance | 05, 06 |
| 08-html-rendering | MailHTML sanitizer, ThreadDocument template, WebViewHost, cid handler, link policy | 02, 05, 06 |
| 09-inbox-list | Inbox screen/model, rows, filters, swipe actions, banners, paging | 01, 06, 07 |
| 10-thread-view | Thread screen/model, actions bar, attachments/QuickLook, mark read | 07, 08, 09 |
| 11-compose | Compose screen/model, draft prefill, quote snapshot, SendJob, failed-send reopen | 02, 07, 10 |
| 12-labels | Labels sheet/model, label view hydration wiring, counts throttle, chips | 07, 09 |
| 13-settings-theme-signature | Settings screen, theme picker wiring, signature editor + import, compose style UI, badge toggle, Advanced section | 01, 06, 07, 08 |
| 14-qa | Fixtures catalog, stubs, invariant helper, conflict/sync/send tests, smoke tests, device checklist, TestFlight runbook | all |

Module scopes (what each contains, its public interface, what it must not contain) are in `docs/plan/design/modules.md`. Milestones map as in PLAN.md: M1 = 01–06 + a read-only inbox; M2 = 07–10, 12; M3 = 11; M4 = 13, 14, TestFlight.
