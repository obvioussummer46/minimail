# minimail — Stage-1 architecture, candidate "SIMPLE"

Author angle: **simplicity-first**. Smallest codebase an AI coding agent can implement and debug from a CLI (Linux for editing + tests of the pure core, macOS runner for `xcodebuild`), with no Xcode GUI. Fewest dependencies, no generic layers, boring explicit code, still fast and battery-neutral.

Date: 2026-09-11. Inputs: `/home/user/minimail/PLAN.md` (accepted outline) and the five research files under `docs/plan/research/` (`gmail-api.md`, `ios-platform.md`, `mime-rfc.md`, `html-rendering.md`, `tooling.md`). Every platform/API fact below cites the research file and section it comes from; when a research file marks something UNVERIFIED I keep that marker.

## 0. The ten decisions that shape everything

| # | Decision | One-line rationale |
|---|---|---|
| 1 | **Two build products only**: the app target `minimail` and one local SwiftPM package `MailCore` (Foundation + SwiftSoup, no UIKit). | `MailCore` holds every pure algorithm (MIME, parsing, sanitizer, reply-all, batch codec, today-logic) and is tested with `swift test` **on Linux in seconds**; the app target is tested with `xcodebuild` on macOS. This is the single biggest lever for an agent that edits on Linux. |
| 2 | **Three dependencies**, all pinned exactly: AppAuth-iOS 3.0.0, GRDB.swift 7.11.1, SwiftSoup 2.13.9. Nothing else (no snapshot testing, no lint plugins, no DI, no Combine). | Each replaces weeks of risky code (OAuth edge cases, SQLite concurrency, an HTML5 parser). Everything else is smaller written by hand. (`ios-platform.md` §1.7 verdict, §2.1; `html-rendering.md` §1.1.) |
| 3 | **One SQLite table is the truth: `message`**. Threads are a SQL `VIEW` (`GROUP BY threadId`), never a maintained table. Labels are a JSON array column plus three mirror flags written by one function. | Zero derived-state bookkeeping in the sync engine; list filters are plain SQL. |
| 4 | **Sync = full sync (threads.list + threads.get metadata) or delta (history.list)**; bodies fetched per message on thread open (`messages.get?format=full`, batched); on history 404 the whole message cache is dropped and rebuilt. | Matches PLAN.md; no partial-resync logic. (`gmail-api.md` §13.) |
| 5 | **Every write to Gmail goes through one `outbox` table** (thread label ops + sends), processed by one actor, sequentially, with one retry policy. Local state is applied first; pending outbox deltas are re-applied after every delta sync. | One conflict rule, one retry rule. |
| 6 | **The `WKWebView` is the scroller.** A thread is one HTML document (headers + bodies + attachment rows all in HTML), one pooled web view, native UI only for nav bar and bottom toolbar. | No height measurement, no nested scrolling, no N web views. (`html-rendering.md` §4.) |
| 7 | **Swift 6 language mode + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** in the app; `MailCore` is nonisolated value types. Exactly three actors: `GmailClient`, `SyncEngine`, `Outbox`. | UI code compiles without annotations; data races are compile errors, which is the feedback an unattended agent needs. (`tooling.md` §3.3.) |
| 8 | **Composition root = one `@Observable` class `AppEnvironment`** injected with `.environment(_:)`. No protocols for dependency injection except `TokenProvider` (so AppAuth can be swapped). Tests stub the network with a `URLProtocol`, not with protocols. | Fewest abstractions; the real client + codec get exercised in tests. |
| 9 | **No UI-test target, no snapshot tests in stage 1.** One "smoke" XCTest hosts the root views against a seeded in-memory DB. | XCUITest is slow/flaky headless; snapshots need an eye. Unit tests carry the value. (`tooling.md` §7.) |
| 10 | **Settings = one `Codable` struct in `UserDefaults`; account facts live in the DB `syncState` table; tokens in Keychain.** Sign-out deletes the DB directory and the Keychain item, keeps the style settings. | Three stores, each with one obvious owner. |

Explicit simplifications versus PLAN.md (all deliberate, all reversible):
- `thread` table replaced by a SQL view; `attachment` table kept (metadata only).
- Read/unread and archive act on the **whole thread** (`threads.modify`), never per message. Opening a thread marks all its messages read.
- Compose shows the quoted original as a one-line "Quoting …" note, not a rendered web view; the quote is assembled at send time from the cached sanitized body.
- Forward attachments: JSON `raw` send path only; refuse if attachments exceed 20 MB (the media-upload path is stage 2).
- Inline `cid:` images are served lazily through a `WKURLSchemeHandler` (≈40 lines) — cheaper than embedding data: URIs in SQLite and needed for signatures with logos.

---

## 1. Tooling & project layout

### 1.1 Toolchain (from `tooling.md` §0, §3)

| Item | Value |
|---|---|
| Xcode | **26.6 (17F113)** now (Swift 6.3, iOS 26.5 SDK); bump to 27.0 when the `macos-26` GitHub image ships it GA. App Store requires the iOS 26 SDK since 2026-04-28 (`ios-platform.md` §0). |
| Deployment target | **iOS 17.0** — every stage-1 API is ≤ iOS 17 (`ios-platform.md` §0). |
| Project generator | **XcodeGen 2.46.0**; `project.yml` is committed, `minimail.xcodeproj/` is git-ignored and regenerated (`tooling.md` §1). |
| Swift mode | `SWIFT_VERSION = 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` for the app target (`tooling.md` §3.3, Apple build-settings reference confirms names). `MailCore` package: tools-version 6.2, language mode 6, default isolation nonisolated (the default). |
| Build/test | `xcodebuild` + `xcbeautify 3.2.1`; simulator destination `platform=iOS Simulator,name=iPhone 17` (no iPhone 16 on the macos-26 runtimes — `tooling.md` §2.2); `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` for simulator builds. |
| Core tests | `cd Packages/MailCore && swift test` — runs on Linux (Swift 6.2+ toolchain or `swift:6.2` Docker image — tag UNVERIFIED in `tooling.md` §7.4) and on macOS. |
| Formatting | `swift format` bundled in the Xcode toolchain, `.swift-format` from `tooling.md` §5.1. SwiftLint **not** used (one fewer install; swift-format's lint mode covers the basics). |
| Distribution | Apple Developer Program + TestFlight, uploaded with `xcodebuild archive` / `-exportArchive … destination=upload` and an App Store Connect API key (`tooling.md` §6.2). |

### 1.2 Dependencies (exact pins)

| Package | Version | Product | Used by | Why (research) |
|---|---|---|---|---|
| `https://github.com/openid/AppAuth-iOS` | `3.0.0` (2026-08-24, iOS 15+) | `AppAuth` | app target `Auth/` | PKCE, refresh, `NSSecureCoding` state (`ios-platform.md` §1) |
| `https://github.com/groue/GRDB.swift` | `7.11.1` (2026-06-18, Swift 6.1+) | `GRDB` | app target `Store/` | WAL pool, migrations, `ValueObservation` (`ios-platform.md` §2) |
| `https://github.com/scinfu/SwiftSoup` | `2.13.9` (2026-08-26, swift-tools 6.0) | `SwiftSoup` | `MailCore` (Sanitizer) | HTML5 parser + allowlist cleaner (`html-rendering.md` §1.1) |

### 1.3 Folder tree (every file named)

```
minimail/                                  # repo root
├── PLAN.md
├── project.yml                            # XcodeGen spec (§1.4)
├── Makefile                               # headless commands (§1.6)
├── .gitignore                             # minimail.xcodeproj/, .build/, DerivedData/, *.xcresult
├── .swift-format
├── ExportOptions.plist                    # TestFlight upload (tooling.md §6.2)
├── Config/
│   └── Signing.xcconfig                   # DEVELOPMENT_TEAM = <owner fills in>
├── .github/workflows/ci.yml               # job "core" (ubuntu, swift test) + job "ios" (macos-26, xcodebuild test)
│
├── Packages/MailCore/                     # pure Swift, Foundation + SwiftSoup only, Linux-testable
│   ├── Package.swift
│   ├── Sources/MailCore/
│   │   ├── Base64URL.swift                # encode (padded) / tolerant decode
│   │   ├── QuotedPrintable.swift          # QP encoder (76 cols, uppercase hex)
│   │   ├── RFC2047.swift                  # encoded-word decode (B/Q, charsets) + B-encode
│   │   ├── Mailbox.swift                  # struct Mailbox; RFC 5322 §3.4 tokenizer; serializer
│   │   ├── HeaderDate.swift               # RFC 5322 date format + attribution-line format
│   │   ├── GmailDTO.swift                 # Codable structs for every Gmail JSON shape we touch
│   │   ├── MessageParser.swift            # GmailMessage -> ParsedMessage (headers, body walk, attachments)
│   │   ├── Sanitizer.swift                # SwiftSoup whitelist + image neutralization + style scrub + dark classification
│   │   ├── ThreadDocument.swift           # [message] + theme tokens -> one self-contained HTML document
│   │   ├── ComposeStyle.swift             # font family / size / color / signature (Codable)
│   │   ├── ReplyAll.swift                 # recipient algorithm
│   │   ├── Composer.swift                 # reply/forward prep: subject, threading headers, text+html bodies (quote/forward banner)
│   │   ├── MIMEBuilder.swift              # OutgoingMessage -> RFC 5322 bytes
│   │   ├── BatchCodec.swift               # multipart/mixed batch request builder + response parser
│   │   └── DayBoundary.swift              # "today" in a time zone; relative date labels
│   └── Tests/MailCoreTests/
│       ├── Base64URLTests.swift
│       ├── QuotedPrintableTests.swift
│       ├── RFC2047Tests.swift
│       ├── MailboxTests.swift
│       ├── HeaderDateTests.swift
│       ├── GmailDTOTests.swift
│       ├── MessageParserTests.swift
│       ├── SanitizerTests.swift
│       ├── ThreadDocumentTests.swift
│       ├── ReplyAllTests.swift
│       ├── ComposerTests.swift
│       ├── MIMEBuilderTests.swift         # byte-exact: sha256 of mime-rfc.md §7.1/§7.2
│       ├── BatchCodecTests.swift
│       ├── DayBoundaryTests.swift
│       └── Fixtures/                      # see §13.2
│           ├── message-alternative.json … (Gmail format=full payloads, 8 shapes)
│           ├── thread-metadata.json
│           ├── history-mixed.json
│           ├── labels-list.json, label-get-user.json
│           ├── batch-response.txt          # multipart/mixed from gmail-api.md §12
│           ├── reply.eml, forward.eml      # mime-rfc.md §7
│           └── html/*.html                 # newsletter, plain, dark-native, tracking-pixel
│
├── minimail/                              # app target (folders = modules, §2)
│   ├── App/
│   │   ├── MinimailApp.swift              # @main, scenes, .backgroundTask, .onOpenURL
│   │   ├── AppEnvironment.swift           # composition root (one @Observable class)
│   │   └── RootView.swift                 # signed-out vs signed-in switch
│   ├── Auth/
│   │   ├── TokenProvider.swift            # protocol TokenProvider
│   │   ├── AuthStore.swift                # AppAuth flow, OIDAuthState owner, Keychain persistence
│   │   └── Keychain.swift                 # 3 static funcs (set/get/delete)
│   ├── Gmail/
│   │   ├── GmailClient.swift              # actor; one func per endpoint; batching; retry
│   │   └── GmailError.swift               # error taxonomy
│   ├── Store/
│   │   ├── Database.swift                 # open DatabasePool, run migrations
│   │   ├── Schema.swift                   # migration "v1": the CREATE TABLE/VIEW/INDEX strings of §3
│   │   ├── Records.swift                  # MessageRecord, LabelRecord, AttachmentRecord, OutboxRecord, ThreadRow, SyncState
│   │   ├── Queries.swift                  # ThreadQuery -> (sql, arguments); fetch helpers
│   │   └── Writes.swift                   # upsertMessage, setLabels, applyThreadDelta, storeBody, …
│   ├── Sync/
│   │   ├── SyncEngine.swift               # actor: fullSync, deltaSync, loadOlder, fetchBodies, labels, badge
│   │   ├── Outbox.swift                   # actor: enqueue, drain, retry policy, send idempotency
│   │   ├── MailActions.swift              # archive / read / unread / send: local apply + enqueue
│   │   └── BackgroundRefresh.swift        # schedule + handler body
│   ├── Web/
│   │   ├── MailWebView.swift              # UIViewRepresentable around a given WKWebView
│   │   ├── WebViewHost.swift              # creates/configures the pooled WKWebView, rule lists
│   │   ├── CIDSchemeHandler.swift         # minimail-cid:// -> attachments.get (cached)
│   │   └── LinkPolicy.swift               # WKNavigationDelegate: cancel + open externally
│   ├── Features/
│   │   ├── SignIn/SignInScreen.swift
│   │   ├── Inbox/
│   │   │   ├── InboxScreen.swift          # list, filters, swipe actions, outbox section, load older
│   │   │   ├── InboxModel.swift           # @Observable; ValueObservation of ThreadQuery
│   │   │   └── ThreadRowView.swift
│   │   ├── Thread/
│   │   │   ├── ThreadScreen.swift         # web view + bottom toolbar
│   │   │   ├── ThreadModel.swift          # loads messages, fetches bodies, renders document, JS bridge
│   │   │   └── AttachmentOpener.swift     # download to tmp + .quickLookPreview
│   │   ├── Compose/
│   │   │   ├── ComposeScreen.swift
│   │   │   └── ComposeModel.swift         # draft state -> SendJob
│   │   ├── Labels/LabelsScreen.swift
│   │   └── Settings/
│   │       ├── Settings.swift             # Codable struct (§11)
│   │       ├── SettingsStore.swift        # @Observable; UserDefaults JSON
│   │       ├── SettingsScreen.swift
│   │       └── SignatureEditorScreen.swift
│   ├── Theme/
│   │   ├── Theme.swift                    # protocol Theme, ThemeTokens, LightTheme, DarkTheme
│   │   └── ThemeStore.swift               # @Observable; resolves choice + colorScheme
│   ├── Support/
│   │   ├── Log.swift                      # os.Logger instances
│   │   └── Formatters.swift               # row time label, byte counts
│   └── Resources/
│       ├── Assets.xcassets/               # AppIcon, AccentColor
│       └── PrivacyInfo.xcprivacy          # UserDefaults CA92.1 (ios-platform.md §7, codes UNVERIFIED)
│
└── minimailTests/                         # XCTest on simulator (app-side only)
    ├── DatabaseTests.swift                # schema, view, queries, setLabels
    ├── SyncEngineTests.swift              # against StubURLProtocol + in-memory DB
    ├── OutboxTests.swift                  # retry, idempotency, reapply
    ├── GmailClientTests.swift             # request building, 401 retry, batch, backoff
    ├── SmokeTests.swift                   # hosts InboxScreen/ThreadScreen with seeded DB
    ├── StubURLProtocol.swift              # (method, path) -> (status, body) table
    └── Fixtures/                          # symlink or copy of Packages/MailCore/Tests/MailCoreTests/Fixtures
```

Roughly 60 Swift files in the app + 15 in `MailCore`. Anything not in this tree is not part of stage 1.

### 1.4 `project.yml`

Adapted from `tooling.md` §1.4 (verified against XcodeGen ProjectSpec there): UI-test target and SnapshotTesting removed, `MailCore` local package added.

```yaml
name: minimail
options:
  minimumXcodeGenVersion: 2.46.0
  bundleIdPrefix: com
  deploymentTarget: { iOS: "17.0" }
  xcodeVersion: "26.6"
  createIntermediateGroups: true
  developmentLanguage: en
configs: { Debug: debug, Release: release }
configFiles: { Debug: Config/Signing.xcconfig, Release: Config/Signing.xcconfig }
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
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.minimail
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
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false }
        ITSAppUsesNonExemptEncryption: false
        BGTaskSchedulerPermittedIdentifiers: [com.minimail.refresh]
        UIBackgroundModes: [fetch]
        CFBundleURLTypes:
          - CFBundleTypeRole: Editor
            CFBundleURLName: com.minimail.oauth
            CFBundleURLSchemes: [com.googleusercontent.apps.REPLACE_WITH_GOOGLE_CLIENT_ID]
    entitlements: { path: minimail/minimail.entitlements, properties: {} }
    scheme:
      testTargets: [minimailTests]
      gatherCoverageData: true
      environmentVariables: { MINIMAIL_TESTING: "1" }
  minimailTests:
    type: bundle.unit-test
    platform: iOS
    sources: [{ path: minimailTests }]
    dependencies: [{ target: minimail }]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.minimailTests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/minimail.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/minimail
        BUNDLE_LOADER: $(TEST_HOST)
```

Info.plist facts: `CFBundleURLSchemes` must be the reversed client id (`gmail-api.md` OAuth section, gotcha 19); `UIBackgroundModes: fetch` + `BGTaskSchedulerPermittedIdentifiers` for `BGAppRefreshTask` (`ios-platform.md` §3.1).

### 1.5 `Packages/MailCore/Package.swift`

```swift
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MailCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MailCore", targets: ["MailCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(name: "MailCore", dependencies: ["SwiftSoup"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"], resources: [.copy("Fixtures")]),
    ]
)
```

Rule: `MailCore` imports only `Foundation` and `SwiftSoup`. No `UIKit`, `SwiftUI`, `GRDB`, `AppAuth`, `WebKit`. A `grep -rE "^import (UIKit|SwiftUI|GRDB|AppAuth|WebKit)" Packages/MailCore/Sources` in `make lint` enforces it. SwiftSoup building on Linux is expected (pure Swift, Foundation only) but is flagged UNVERIFIED in `html-rendering.md`; fallback in §14.

### 1.6 `Makefile` (what the agent runs)

```make
PROJECT := minimail.xcodeproj
SCHEME  := minimail
DD      := .build/DerivedData
SPM     := .build/SourcePackages
RESULTS := .build/results
SIM_DEST ?= platform=iOS Simulator,name=iPhone 17
NOSIGN  := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

core-test:                      # Linux or macOS, seconds
	cd Packages/MailCore && swift test

gen:
	xcodegen generate

build: gen
	set -o pipefail && xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) $(NOSIGN) | xcbeautify

test-app: gen
	rm -rf $(RESULTS)/unit.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/unit.xcresult \
	  -only-testing:minimailTests $(NOSIGN) | xcbeautify
	xcrun xcresulttool get test-results summary --path $(RESULTS)/unit.xcresult --compact

test-one: gen                   # make test-one T=minimailTests/SyncEngineTests/testDeltaAppliesLabelRemoval
	rm -rf $(RESULTS)/one.xcresult
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DEST)' \
	  -derivedDataPath $(DD) -clonedSourcePackagesDirPath $(SPM) -resultBundlePath $(RESULTS)/one.xcresult \
	  -only-testing:$(T) $(NOSIGN) | xcbeautify

lint:
	swift format lint --strict --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
	! grep -rE "^import (UIKit|SwiftUI|GRDB|AppAuth|WebKit)" Packages/MailCore/Sources

format:
	swift format --in-place --recursive minimail minimailTests Packages/MailCore/Sources Packages/MailCore/Tests
```

Commands, flags and the xcresult summary call are from `tooling.md` §2.3–§2.7 (`-resultBundlePath` must not pre-exist; `-only-testing:Target/Class/method`).

Workflow loop for the agent: edit → `make core-test` (Linux, fast) for anything in `MailCore` → `make build` / `make test-app` on the macOS runner for app-side changes → CI runs both jobs.

---
## 2. Module map and public interfaces

### 2.1 Dependency direction

Modules are folders inside one app target plus the `MailCore` package. Arrows point from importer to imported. Nothing points up.

```
Features/*  ──►  Sync (SyncEngine, Outbox, MailActions)  ──►  Gmail (GmailClient)  ──►  Auth (TokenProvider)
   │  │  │             │                                        │
   │  │  └──►  Store (Database, Records, Queries, Writes) ◄─────┘ (SyncEngine writes; GmailClient never touches the DB)
   │  └─────►  Web (MailWebView, WebViewHost, CIDSchemeHandler, LinkPolicy)  ──►  Gmail (attachments.get)
   └────────►  Theme, Support

App/ (AppEnvironment, MinimailApp, RootView) owns every object above and hands them to Features via the environment.

Everything ──►  MailCore  (pure; imports nothing from the app)
```

Rules the agent must keep (a `grep` in `make lint` can check the first two):
1. `MailCore` never imports app modules or Apple UI frameworks.
2. `Gmail/` never imports `GRDB`; `Store/` never imports `AppAuth`/`WebKit`; `Features/` never call `URLSession` or `GmailClient` directly — they go through `SyncEngine`/`MailActions`, except `Web/CIDSchemeHandler` and `Features/Thread/AttachmentOpener`, which call `GmailClient.getAttachment` (documented exception, both are downloads for display).
3. Only `Store/Writes.swift` contains `INSERT/UPDATE/DELETE` statements. Only `Store/Queries.swift` contains `SELECT` strings used by the UI.

### 2.2 `MailCore` public interface

All types are `Sendable` value types; all functions are pure (no I/O, no globals except `Sanitizer.version`). Signatures are the contract; bodies are for the implementer.

```swift
// Base64URL.swift
public enum Base64URL {
    /// RFC 4648 §5 alphabet, single line, WITH '=' padding (mime-rfc.md §1.2 decision).
    public static func encode(_ data: Data) -> String
    /// Accepts padded/unpadded, both alphabets; nil on any other character.
    public static func decode(_ string: String) -> Data?
}

// QuotedPrintable.swift
public enum QuotedPrintable {
    /// Input must already use CRLF line breaks. 76-col soft breaks, uppercase hex, trailing WSP encoded.
    public static func encode(_ utf8: Data) -> String
}

// RFC2047.swift
public enum RFC2047 {
    /// Decodes encoded-words anywhere in an unstructured value; drops LWSP between adjacent words;
    /// concatenates bytes of adjacent same-charset words before charset decoding; unknown charset → left as-is.
    public static func decode(_ headerValue: String) -> String
    /// ASCII passthrough; otherwise UTF-8 B-encoded words ≤ 75 chars, joined with CRLF SPACE folding.
    public static func encodeIfNeeded(_ text: String) -> String
}

// Mailbox.swift
public struct Mailbox: Sendable, Equatable, Hashable, Codable {
    public var name: String?
    public var addr: String                       // original case; compare with `key`
    public var key: String { addr.lowercased() }
    public init(name: String?, addr: String)
    /// RFC 5322 §3.4 tokenizer (quoted-string, nested comments, groups flattened, obs-route dropped,
    /// legacy "addr (Name)" kept as name, encoded-words decoded). Never throws; skips unparsable members.
    public static func parseList(_ header: String) -> [Mailbox]
    /// `Name <addr>` with quoting or RFC 2047 as needed; bare addr when name is nil.
    public var headerString: String
    public static func headerList(_ list: [Mailbox]) -> String   // comma+space joined, folded at 78
}

// HeaderDate.swift
public enum HeaderDate {
    /// "Fri, 11 Sep 2026 10:00:00 +0200" in en_US_POSIX.
    public static func rfc5322(_ date: Date, timeZone: TimeZone) -> String
    /// "Thu, Sep 10, 2026 at 9:12\u{202F}AM" (Gmail attribution format, mime-rfc.md §4.1).
    public static func attribution(_ date: Date, timeZone: TimeZone) -> String
}

// GmailDTO.swift — field names mirror the Discovery document (gmail-api.md); numbers-as-strings decoded as String then converted.
public struct GmailProfile: Codable, Sendable { public var emailAddress: String; public var historyId: String }
public struct GmailLabelColor: Codable, Sendable { public var textColor: String; public var backgroundColor: String }
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
}
public struct GmailMessage: Codable, Sendable {
    public var id: String; public var threadId: String; public var labelIds: [String]?
    public var snippet: String?; public var historyId: String?; public var internalDate: String?
    public var sizeEstimate: Int?; public var payload: GmailPart?
}
public struct GmailThread: Codable, Sendable { public var id: String; public var historyId: String?; public var snippet: String?; public var messages: [GmailMessage]? }
public struct GmailThreadStub: Codable, Sendable { public var id: String; public var snippet: String?; public var historyId: String? }
public struct GmailListThreadsResponse: Codable, Sendable { public var threads: [GmailThreadStub]?; public var nextPageToken: String?; public var resultSizeEstimate: Int? }
public struct GmailMessageStub: Codable, Sendable { public var id: String; public var threadId: String }
public struct GmailListMessagesResponse: Codable, Sendable { public var messages: [GmailMessageStub]?; public var nextPageToken: String? }
public struct GmailHistoryMessage: Codable, Sendable { public var id: String; public var threadId: String; public var labelIds: [String]? }
public struct GmailHistoryMessageChange: Codable, Sendable { public var message: GmailHistoryMessage }
public struct GmailHistoryLabelChange: Codable, Sendable { public var message: GmailHistoryMessage; public var labelIds: [String]? }
public struct GmailHistory: Codable, Sendable {
    public var id: String
    public var messagesAdded: [GmailHistoryMessageChange]?; public var messagesDeleted: [GmailHistoryMessageChange]?
    public var labelsAdded: [GmailHistoryLabelChange]?;     public var labelsRemoved: [GmailHistoryLabelChange]?
}
public struct GmailListHistoryResponse: Codable, Sendable { public var history: [GmailHistory]?; public var nextPageToken: String?; public var historyId: String? }
public struct GmailSendAs: Codable, Sendable { public var sendAsEmail: String; public var displayName: String?; public var signature: String?; public var isPrimary: Bool?; public var isDefault: Bool? }
public struct GmailListSendAsResponse: Codable, Sendable { public var sendAs: [GmailSendAs]? }
public struct GmailErrorEnvelope: Codable, Sendable {
    public struct Inner: Codable, Sendable { public var code: Int?; public var message: String?; public var status: String?; public var errors: [Item]? }
    public struct Item: Codable, Sendable { public var reason: String?; public var message: String? }
    public var error: Inner
}
public enum GmailFormat: String, Sendable { case minimal, full, raw, metadata }
/// Headers requested with format=metadata (gmail-api.md gotcha 12).
public let gmailMetadataHeaders: [String] = ["From", "To", "Cc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References"]

// MessageParser.swift
public struct ParsedAttachment: Sendable, Equatable {
    public var partId: String; public var filename: String; public var mimeType: String; public var size: Int
    public var attachmentId: String?; public var contentId: String?   // contentId without <>; set for inline candidates
}
public struct ParsedBody: Sendable, Equatable {
    public var html: String?; public var text: String?
    public var deferredTextPartIds: [String]                       // text parts delivered by attachmentId only (rare)
}
public struct ParsedMessage: Sendable, Equatable {
    public var id: String; public var threadId: String; public var historyId: UInt64; public var internalDate: Int64
    public var labelIds: [String]; public var snippet: String
    public var from: Mailbox?; public var to: [Mailbox]; public var cc: [Mailbox]; public var replyTo: [Mailbox]
    public var subject: String; public var messageID: String?; public var inReplyTo: String?; public var references: [String]
    public var body: ParsedBody?                                   // nil when format was metadata/minimal
    public var attachments: [ParsedAttachment]
}
public enum MessageParser {
    /// Implements mime-rfc.md §5.2/§5.3/§5.5: first text/html and first text/plain body-text parts win,
    /// no recursion into attachmentId parts, charset from the part's Content-Type, headers case-insensitive.
    public static func parse(_ message: GmailMessage) -> ParsedMessage
    public static func decodeText(_ part: GmailPart) -> String?
}

// Sanitizer.swift
public enum DarkStrategy: String, Sendable, Codable { case plain, card, native }
public struct SanitizedBody: Sendable, Equatable {
    public var html: String; public var hasRemoteImages: Bool; public var darkStrategy: DarkStrategy
}
public enum Sanitizer {
    public static let version: Int = 1               // bump → bodies re-fetched lazily
    public static let placeholderGIF: String          // 1x1 transparent data: URI
    /// html-rendering.md §1.3 pipeline; cid: → "minimail-cid://<messageId>/<cid>"; remote src → data-src + placeholder.
    public static func sanitize(html: String, messageId: String) throws -> SanitizedBody
    /// For plain-text-only mails: escape, linkify http(s) URLs, <br> for newlines. Never throws.
    public static func fromPlainText(_ text: String) -> SanitizedBody
    /// For the owner's signature: keep https img src (no data-src swap); same tag/attr allowlist.
    public static func sanitizeSignature(_ html: String) throws -> String
}

// ThreadDocument.swift
public struct ThreadDocumentMessage: Sendable, Equatable {
    public var id: String; public var fromName: String; public var fromAddr: String
    public var toLine: String; public var ccLine: String?; public var dateLine: String
    public var bodyHTML: String; public var darkStrategy: DarkStrategy; public var hasRemoteImages: Bool
    public var isUnread: Bool; public var expanded: Bool
    public var attachments: [(partId: String, filename: String, sizeLabel: String)]
}
public struct ThemeCSSTokens: Sendable, Equatable {   // hex strings, e.g. "#000000"
    public var background, surface, text, secondaryText, accent, separator: String
}
public enum ThreadDocument {
    /// One self-contained HTML document: CSP meta (images on/off), viewport, base CSS, per-message sections
    /// with ids "m-<id>", classes "mm-plain|mm-card|mm-native", collapsed sections carry class "collapsed".
    public static func render(subject: String, messages: [ThreadDocumentMessage], tokens: ThemeCSSTokens, imagesAllowed: Bool) -> String
    public static let emptyDocument: String            // used to warm/blank the web view
}

// ComposeStyle.swift — html-rendering.md §5.4
public struct ComposeStyle: Codable, Sendable, Equatable {
    public enum Family: String, Codable, CaseIterable, Sendable { case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        public var css: String; public var displayName: String }
    public var family: Family = .helvetica
    public var sizePx: Int = 14                        // 12…18
    public var colorHex: String = "#000000"            // ^#[0-9a-f]{6}$
    public var signatureHTML: String = ""              // already sanitized when saved
    public var inlineCSS: String { "font-family:\(family.css);font-size:\(sizePx)px;color:\(colorHex)" }
    public init()
}

// ReplyAll.swift — mime-rfc.md §2.1, 16 vectors in §8.1
public struct SelfIdentity: Sendable, Equatable {
    public var primary: Mailbox                        // From: for outgoing mail (displayName from sendAs)
    public var allAddresses: Set<String>               // lowercased addr-specs: profile + every sendAs
}
public struct Recipients: Sendable, Equatable { public var to: [Mailbox]; public var cc: [Mailbox] }
public enum ReplyAll {
    public static func recipients(from: Mailbox?, replyTo: [Mailbox], to: [Mailbox], cc: [Mailbox], me: SelfIdentity) -> Recipients
}

// Composer.swift — subject/threading/quoting (mime-rfc.md §1.4, §1.5, §4)
public enum ComposeMode: String, Codable, Sendable { case replyAll, forward }
public struct OriginalMessage: Sendable, Equatable {     // the cached message the user acts on
    public var id: String; public var threadId: String
    public var from: Mailbox?; public var to: [Mailbox]; public var cc: [Mailbox]; public var replyTo: [Mailbox]
    public var subject: String; public var messageID: String?; public var inReplyTo: String?; public var references: [String]
    public var date: Date                                // from internalDate
    public var bodyHTML: String?                         // sanitized (from SQLite)
    public var bodyText: String?
}
public struct ComposePrefill: Sendable, Equatable {
    public var to: [Mailbox]; public var cc: [Mailbox]; public var subject: String
    public var inReplyTo: String?; public var references: [String]; public var threadId: String
}
public enum Composer {
    public static func prefill(mode: ComposeMode, original: OriginalMessage, me: SelfIdentity) -> ComposePrefill
    public static func replySubject(_ s: String) -> String      // "Re: " unless already re: (case-insensitive)
    public static func forwardSubject(_ s: String) -> String    // "Fwd: " unless already fwd:
    /// Full bodies: typed text (escaped, <div> per line) wrapped in ComposeStyle, signature, then Gmail quote/forward block.
    /// Remote-image placeholders in the quoted HTML are restored to their https src; minimail-cid:// → cid:.
    public static func bodies(mode: ComposeMode, typed: String, style: ComposeStyle, original: OriginalMessage, timeZone: TimeZone)
        -> (text: String, html: String)
}

// MIMEBuilder.swift — mime-rfc.md §1.3, §3
public struct OutgoingAttachment: Sendable, Equatable { public var filename: String; public var mimeType: String; public var data: Data }
public struct OutgoingMessage: Sendable, Equatable {
    public var from: Mailbox; public var to: [Mailbox]; public var cc: [Mailbox]
    public var subject: String; public var date: Date; public var timeZone: TimeZone
    public var messageID: String                         // "<UUID@domain>", generated at enqueue time
    public var inReplyTo: String?; public var references: [String]
    public var textBody: String; public var htmlBody: String
    public var attachments: [OutgoingAttachment]
}
public enum MIMEBuilder {
    /// CRLF everywhere; multipart/alternative (plain first, html last), wrapped in multipart/mixed when attachments exist;
    /// QP for text parts, 76-col base64 for attachments; RFC 2231 filename* for non-ASCII names.
    /// `boundaries` lets tests pin exact bytes (mime-rfc.md §7 sha256 vectors).
    public static func build(_ m: OutgoingMessage, boundaries: () -> String = MIMEBuilder.randomBoundary) -> Data
    public static func randomBoundary() -> String        // "=_minimail_<16 hex>"
}

// BatchCodec.swift — gmail-api.md §12 wire format
public struct BatchPart: Sendable, Equatable {
    public var id: String; public var method: String; public var path: String   // "/gmail/v1/users/me/…?query"
    public var jsonBody: Data?
}
public struct BatchPartResponse: Sendable, Equatable { public var id: String; public var status: Int; public var body: Data }
public enum BatchCodec {
    public static func encode(parts: [BatchPart], boundary: String) -> Data
    /// Splits on CRLF--boundary, reads inner status line + Content-ID "<response-ID>", maps by id (order-independent).
    public static func decode(body: Data, contentType: String) throws -> [BatchPartResponse]
}

// DayBoundary.swift
public enum DayBoundary {
    public static func startOfToday(now: Date, timeZone: TimeZone, calendar: Calendar = .init(identifier: .gregorian)) -> Int64   // epoch ms
    /// "14:32" (today), "Yesterday", "Mon" (this week), "11 Sep" (this year), "11.09.25" — locale-aware via Date.FormatStyle.
    public static func rowLabel(epochMs: Int64, now: Date, timeZone: TimeZone, locale: Locale) -> String
}
```

### 2.3 App-target module interfaces

```swift
// Auth/TokenProvider.swift
protocol TokenProvider: Sendable {
    func accessToken() async throws -> String            // fresh; refreshes when expired
    func invalidateAccessToken() async                   // after a 401; next accessToken() refreshes
}

// Auth/AuthStore.swift  (@MainActor by project default; conforms to TokenProvider because @MainActor classes are Sendable)
@Observable final class AuthStore: TokenProvider {
    enum State: Equatable { case unknown, signedOut, signedIn }
    private(set) var state: State
    private(set) var lastError: String?
    init(clientID: String, redirectURL: URL)            // both from AppConfig
    func restore()                                       // Keychain → OIDAuthState; sets state
    func signIn() async throws                           // AppAuth flow; persists; state = .signedIn
    func signOut() async                                 // revoke (best effort), delete Keychain, state = .signedOut
    func resume(url: URL)                                // onOpenURL fallback → currentFlow?.resumeExternalUserAgentFlow
    func handleUnauthorized()                            // called by AppEnvironment when GmailClient throws .unauthorized twice
    // TokenProvider
    func accessToken() async throws -> String
    func invalidateAccessToken() async
}

// Auth/Keychain.swift
enum Keychain {
    static func set(_ data: Data, account: String) throws
    static func get(account: String) throws -> Data?
    static func delete(account: String) throws
}

// Gmail/GmailError.swift
enum GmailError: Error, Sendable {
    case unauthorized                                  // 401 after one refresh, or invalid_grant
    case forbidden(reason: String?)                    // 403 (admin_policy_enforced, dailyLimitExceeded…)
    case notFound                                      // 404 (history expiry, deleted message)
    case badRequest(String)                            // 400
    case rateLimited(retryAfter: TimeInterval?)        // 429, or 403 with rateLimitExceeded/userRateLimitExceeded
    case server(status: Int)                           // 5xx
    case network(URLError)
    case decoding(String)
    var isRetryable: Bool                              // rateLimited, server, network(timeout/notConnected/…)
    static func from(status: Int, body: Data, headers: [AnyHashable: Any]) -> GmailError
}

// Gmail/GmailClient.swift
actor GmailClient {
    static let batchChunkSize = 25
    init(tokens: any TokenProvider, session: URLSession = .shared, baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!)
    func getProfile() async throws -> GmailProfile
    func listLabels() async throws -> [GmailLabel]
    func getLabels(ids: [String]) async throws -> [GmailLabel]                                    // HTTP batch
    func listThreads(labelIds: [String], maxResults: Int, pageToken: String?) async throws -> GmailListThreadsResponse
    func getThreads(ids: [String], format: GmailFormat) async throws -> [String: Result<GmailThread, GmailError>]   // batch
    func getMessages(ids: [String], format: GmailFormat) async throws -> [String: Result<GmailMessage, GmailError>] // batch
    func listHistory(startHistoryId: UInt64, pageToken: String?) async throws -> GmailListHistoryResponse
    func listMessages(q: String, maxResults: Int) async throws -> GmailListMessagesResponse
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func send(raw: Data, threadId: String?) async throws -> GmailMessage
    func getAttachment(messageId: String, attachmentId: String) async throws -> Data
    func listSendAs() async throws -> [GmailSendAs]
    // internals (not for callers): request(_:_:query:body:) with 401-retry + backoff; batch(parts:) chunked + per-part retry
}

// Store/Database.swift
enum Database {
    static func open(directory: URL) throws -> DatabasePool          // Application Support/minimail-db/db.sqlite, migrated
    static func openInMemory() throws -> DatabaseQueue               // tests
    static func destroy(directory: URL) throws                       // sign-out
}

// Store/Records.swift (all Codable, Sendable structs; GRDB FetchableRecord/PersistableRecord; column = property name)
struct MessageRecord   { static let databaseTableName = "message";    /* columns of §3.2 */ mutating func setLabels(_ ids: [String]) }
struct LabelRecord     { static let databaseTableName = "label" }
struct AttachmentRecord{ static let databaseTableName = "attachment" }
struct OutboxRecord    { static let databaseTableName = "outbox";     enum Kind: String, Codable { case modify, send }; enum State: String, Codable { case pending, inflight, failed } }
struct SyncStateRecord { static let databaseTableName = "syncState";  var key: String; var value: String }
struct ThreadRow: FetchableRecord, Identifiable { /* columns of the threadSummary view, §3.3 */ }
struct ModifyOp: Codable, Sendable { var threadId: String; var add: [String]; var remove: [String] }
struct SendJob: Codable, Sendable {
    var mode: ComposeMode; var originalMessageId: String; var threadId: String
    var messageID: String; var to: [Mailbox]; var cc: [Mailbox]; var subject: String; var typedText: String
    var inReplyTo: String?; var references: [String]; var attachmentPartIds: [String]   // forward only
    var transmitted: Bool                                                            // request bytes were sent at least once
}
enum SyncKey { static let historyId = "historyId", lastFullSyncAt = "lastFullSyncAt", nextPageToken = "nextPageToken",
               accountEmail = "accountEmail", displayName = "displayName", selfAddresses = "selfAddresses" }

// Store/Queries.swift
struct ThreadQuery: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case inbox, label(id: String) }
    var scope: Scope = .inbox
    var todayOnly: Bool = false
    var unreadOnly: Bool = false
    var startOfTodayMs: Int64                    // computed by the caller (DayBoundary) so the SQL is pure
    var limit: Int = 300
    var sql: (String, StatementArguments)       // §8.6
}
enum Queries {
    static func threads(_ q: ThreadQuery) -> SQLRequest<ThreadRow>              // raw SQL of §8.6; observed with ValueObservation
    static func messages(inThread threadId: String) -> QueryInterfaceRequest<MessageRecord>   // ORDER BY internalDate
    static func attachments(messageId: String) -> QueryInterfaceRequest<AttachmentRecord>
    static func labelsForList() -> QueryInterfaceRequest<LabelRecord>                          // INBOX + visible user labels, by sortOrder
    static func pendingOutbox() -> QueryInterfaceRequest<OutboxRecord>
    static func failedSends() -> QueryInterfaceRequest<OutboxRecord>
    static func inboxUnreadThreadCount(_ db: Database) throws -> Int
    static func syncState(_ db: Database, _ key: String) throws -> String?
}

// Store/Writes.swift — the only file with mutations
enum Writes {
    static func upsertMessage(_ db: Database, _ m: ParsedMessage) throws                     // headers/labels/attachments; keeps existing body
    static func storeBody(_ db: Database, messageId: String, _ b: SanitizedBody, text: String?) throws
    static func deleteMessage(_ db: Database, id: String) throws
    static func applyLabelDelta(_ db: Database, messageId: String, add: [String], remove: [String]) throws
    static func applyThreadDelta(_ db: Database, threadId: String, add: [String], remove: [String]) throws
    static func replaceLabels(_ db: Database, _ labels: [GmailLabel]) throws
    static func setSyncState(_ db: Database, _ key: String, _ value: String?) throws
    static func clearMessageCache(_ db: Database) throws                                      // DELETE FROM message (attachments cascade)
    static func enqueue(_ db: Database, kind: OutboxRecord.Kind, payload: Data) throws
    static func markOutbox(_ db: Database, id: Int64, state: OutboxRecord.State, attempts: Int, nextAttemptAt: Int64, error: String?) throws
    static func deleteOutbox(_ db: Database, id: Int64) throws
}

// Sync/SyncEngine.swift
actor SyncEngine {
    init(db: DatabasePool, gmail: GmailClient, outbox: Outbox, badgeEnabled: @Sendable () async -> Bool)   // reads SettingsStore.showBadge on the main actor
    func refresh() async throws                       // delta, or full when no historyId / on 404; then labels, badge, outbox drain
    func fullSync() async throws
    func loadOlderThreads() async throws              // uses SyncKey.nextPageToken
    func ensureBodies(threadId: String) async throws  // messages.get?format=full for messages with bodyFetched=0 or stale sanitizerVersion
    func refreshLabels() async throws                 // labels.list + batched labels.get
    func updateBadge() async
    var isRefreshing: Bool { get }                    // coalesces concurrent refresh() calls
}

// Sync/Outbox.swift
actor Outbox {
    init(db: DatabasePool, gmail: GmailClient, composeStyle: @Sendable () async -> ComposeStyle)   // SelfIdentity is read from syncState inside the actor
    func drain() async                                // process pending rows in id order; never throws
    func retry(id: Int64) async                       // failed → pending, nextAttemptAt = now
    func discard(id: Int64) async
    func reapplyPendingModifies(_ db: Database) throws   // called inside SyncEngine's delta transaction
}

// Sync/MailActions.swift (MainActor)
struct MailActions {
    let db: DatabasePool; let outbox: Outbox
    func archive(threadId: String) async               // local: remove INBOX from all messages; enqueue ModifyOp
    func markRead(threadId: String) async
    func markUnread(threadId: String) async
    func send(_ job: SendJob) async                    // enqueue; outbox drains immediately
}

// Sync/BackgroundRefresh.swift
enum BackgroundRefresh {
    static let taskID = "com.minimail.refresh"
    static func schedule()                             // BGAppRefreshTaskRequest, earliestBeginDate = +15 min
    static func run(_ env: AppEnvironment) async       // refresh + drain + badge; honours Task.isCancelled
}

// Web/WebViewHost.swift (MainActor)
final class WebViewHost {
    static let shared: WebViewHost
    var webView: WKWebView { get }                     // lazily created with makeConfiguration(); warm() loads emptyDocument
    func warm()
    func setImagesAllowed(_ allowed: Bool)             // swaps rule lists (blockAll ↔ imagesOnly) before a load
    static func makeConfiguration() -> WKWebViewConfiguration
    static func prepareRuleLists() async               // compile-once, lookup-by-identifier
}
// Web/MailWebView.swift
struct MailWebView: UIViewRepresentable {
    let webView: WKWebView; let html: String; let interfaceStyle: UIUserInterfaceStyle
    let onMessage: (WebMessage) -> Void                // from window.webkit.messageHandlers.mm
}
enum WebMessage: Equatable { case toggle(messageId: String), loadImages, attachment(messageId: String, partId: String), address(String) }
// Web/CIDSchemeHandler.swift
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler { init(gmail: GmailClient, db: DatabasePool) }
// Web/LinkPolicy.swift
final class LinkPolicy: NSObject, WKNavigationDelegate { var openURL: (URL) -> Void }

// Theme/Theme.swift
struct ThemeTokens: Equatable { var background, surface, text, secondaryText, accent, unread, separator, chipBackground: Color }
protocol Theme: Sendable { var id: String { get }; var name: String { get }; var colorScheme: ColorScheme { get }; var tokens: ThemeTokens { get } }
struct LightTheme: Theme {}; struct DarkTheme: Theme {}
enum ThemeChoice: String, Codable, CaseIterable, Sendable { case system, light, dark }
// Theme/ThemeStore.swift
@Observable final class ThemeStore {
    var choice: ThemeChoice                            // mirrors Settings.themeChoice
    func resolved(for systemScheme: ColorScheme) -> any Theme
    var preferredColorScheme: ColorScheme?             // nil for .system
    static let registry: [String: any Theme]           // "light", "dark"; add new themes here
}

// Features/Settings/SettingsStore.swift
@Observable final class SettingsStore {
    var settings: Settings { didSet { save() } }       // §11
    init(defaults: UserDefaults = .standard)
}

// App/AppEnvironment.swift (MainActor)
@Observable final class AppEnvironment {
    let db: DatabasePool; let auth: AuthStore; let gmail: GmailClient; let sync: SyncEngine; let outbox: Outbox
    let actions: MailActions; let settings: SettingsStore; let theme: ThemeStore
    init(testing: Bool = ProcessInfo.processInfo.environment["MINIMAIL_TESTING"] == "1")
    func signOut() async                               // auth.signOut + Database.destroy + settings.clearAccountBits + badge 0
}
```

`AppConfig.swift` is not a file: the Google client id and redirect URL are two `static let`s at the top of `AuthStore.swift`, filled from `project.yml`'s placeholder by the owner (one `sed`). Simplicity over indirection.

---
## 3. Data model (SQLite via GRDB)

### 3.1 Principles
- One `DatabasePool` (WAL) in `Application Support/minimail-db/db.sqlite` (`ios-platform.md` §2.2). Directory file protection set to `.completeUntilFirstUserAuthentication` on creation so BG refresh can write while locked (UNVERIFIED whether already the default — `ios-platform.md` §2.2; setting it explicitly is one line and harmless).
- Column names are camelCase = Swift property names → GRDB Codable records need **no key mapping**.
- Migrations are raw SQL strings in `Schema.swift` under `DatabaseMigrator.registerMigration("v1")`. Exactly this schema is what a reader sees; no schema DSL indirection. `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true` (name flagged UNVERIFIED in `ios-platform.md` §2.3; it exists in GRDB 7 — remove if it does not compile).
- `message` is the only truth. `threadSummary` is a view. Three mirror flags (`isUnread`, `inInbox`, `isHidden`) are recomputed from `labelIds` by `MessageRecord.setLabels`, the only function that writes labels.

### 3.2 Schema — migration `v1` (verbatim SQL)

```sql
CREATE TABLE label (
  id                    TEXT PRIMARY KEY NOT NULL,     -- Gmail Label.id ("INBOX", "Label_12")
  name                  TEXT NOT NULL,                 -- Label.name ("Customers/ACME")
  type                  TEXT NOT NULL,                 -- Label.type: 'system' | 'user'
  labelListVisibility   TEXT,                          -- labelShow | labelShowIfUnread | labelHide | NULL
  messageListVisibility TEXT,                          -- show | hide | NULL
  textColor             TEXT,                          -- Label.color.textColor  (user labels only)
  backgroundColor       TEXT,                          -- Label.color.backgroundColor
  messagesUnread        INTEGER NOT NULL DEFAULT 0,    -- Label.messagesUnread (labels.get)
  threadsUnread         INTEGER NOT NULL DEFAULT 0,    -- Label.threadsUnread  (badge for INBOX)
  threadsTotal          INTEGER NOT NULL DEFAULT 0,
  sortOrder             INTEGER NOT NULL DEFAULT 0     -- INBOX = 0, then user labels by name
);

CREATE TABLE message (
  id                TEXT PRIMARY KEY NOT NULL,         -- Message.id
  threadId          TEXT NOT NULL,                     -- Message.threadId
  historyId         INTEGER NOT NULL DEFAULT 0,        -- Message.historyId (uint64 string → Int64)
  internalDate      INTEGER NOT NULL,                  -- Message.internalDate (epoch ms string → Int64)
  fromName          TEXT,                              -- parsed From: display name (RFC 2047 decoded)
  fromAddr          TEXT NOT NULL DEFAULT '',          -- parsed From: addr-spec
  toList            TEXT NOT NULL DEFAULT '[]',        -- JSON [{"name":…,"addr":…}] from To:
  ccList            TEXT NOT NULL DEFAULT '[]',        -- Cc:
  replyToList       TEXT NOT NULL DEFAULT '[]',        -- Reply-To:
  subject           TEXT NOT NULL DEFAULT '',          -- Subject: decoded
  snippet           TEXT NOT NULL DEFAULT '',          -- Message.snippet (HTML-entity decoded)
  messageIdHeader   TEXT,                              -- Message-ID: with <>
  inReplyTo         TEXT,                              -- In-Reply-To:
  referencesList    TEXT NOT NULL DEFAULT '[]',        -- JSON ["<a@x>","<b@y>"] from References:
  labelIds          TEXT NOT NULL DEFAULT '[]',        -- JSON array, sorted, e.g. ["INBOX","UNREAD"]
  isUnread          INTEGER NOT NULL DEFAULT 0,        -- mirror: 'UNREAD' ∈ labelIds
  inInbox           INTEGER NOT NULL DEFAULT 0,        -- mirror: 'INBOX' ∈ labelIds
  isHidden          INTEGER NOT NULL DEFAULT 0,        -- mirror: 'TRASH' or 'SPAM' ∈ labelIds
  hasAttachments    INTEGER NOT NULL DEFAULT 0,        -- any non-inline attachment part
  bodyFetched       INTEGER NOT NULL DEFAULT 0,        -- 1 after format=full processed
  bodyHtml          TEXT,                              -- sanitized fragment (never raw HTML)
  bodyText          TEXT,                              -- text/plain part, or nil
  hasRemoteImages   INTEGER NOT NULL DEFAULT 0,
  darkStrategy      TEXT NOT NULL DEFAULT 'plain',     -- plain | card | native
  sanitizerVersion  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX message_threadId      ON message(threadId);
CREATE INDEX message_inbox_date    ON message(inInbox, isHidden, internalDate DESC);
CREATE INDEX message_internalDate  ON message(internalDate DESC);

CREATE TABLE attachment (
  messageId     TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  partId        TEXT NOT NULL,                         -- MessagePart.partId
  filename      TEXT NOT NULL,                         -- MessagePart.filename (already decoded by Gmail)
  mimeType      TEXT NOT NULL,
  size          INTEGER NOT NULL,                      -- MessagePartBody.size
  attachmentId  TEXT,                                  -- last seen; re-resolved via messages.get before download
  contentId     TEXT,                                  -- Content-ID without <>, NULL if none
  isInline      INTEGER NOT NULL DEFAULT 0,            -- referenced by cid: in the HTML
  PRIMARY KEY (messageId, partId)
);

CREATE TABLE outbox (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  kind          TEXT NOT NULL,                         -- 'modify' | 'send'
  payload       TEXT NOT NULL,                         -- JSON: ModifyOp or SendJob
  state         TEXT NOT NULL DEFAULT 'pending',       -- pending | inflight | failed
  attempts      INTEGER NOT NULL DEFAULT 0,
  nextAttemptAt INTEGER NOT NULL DEFAULT 0,            -- epoch ms
  createdAt     INTEGER NOT NULL,
  lastError     TEXT
);

CREATE TABLE syncState (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);

CREATE VIEW threadSummary AS
SELECT threadId,
       MAX(internalDate)                       AS lastDate,      -- the single min/max aggregate: bare columns below come from this row
       subject, snippet, fromName, fromAddr, labelIds, id AS latestMessageId,
       SUM(isUnread)       > 0                 AS isUnread,
       SUM(inInbox)        > 0                 AS inInbox,
       SUM(hasAttachments) > 0                 AS hasAttachments,
       COUNT(*)                                AS messageCount,
       GROUP_CONCAT(DISTINCT COALESCE(fromName, fromAddr)) AS participants
FROM message
WHERE isHidden = 0
GROUP BY threadId;
```

`PRAGMA foreign_keys = ON` is GRDB's default. The bare-column rule ("when exactly one `MIN()`/`MAX()` is used, bare columns take values from that row") is documented SQLite behaviour (sqlite.org/lang_select.html#bareagg) — `SUM`/`COUNT` do not disturb it. `DatabaseTests.testThreadSummaryPicksLatestMessage` pins it.

### 3.3 Gmail → column mapping

| Gmail field | Column | Transform |
|---|---|---|
| `Message.id`, `threadId` | `message.id`, `threadId` | verbatim |
| `Message.historyId` (string uint64) | `historyId` | `Int64(string)` — never decode as JSON number (`gmail-api.md` gotcha 3) |
| `Message.internalDate` (string int64 ms) | `internalDate` | `Int64(string)`; ordering key everywhere |
| `Message.labelIds[]` | `labelIds` (+ 3 mirrors) | sorted JSON array via `setLabels` |
| `Message.snippet` | `snippet` | HTML entities decoded (Gmail snippets contain `&#39;`) |
| `payload.headers` From/To/Cc/Reply-To | `fromName/fromAddr`, `toList`, `ccList`, `replyToList` | `Mailbox.parseList` + RFC 2047 |
| `Subject` | `subject` | `RFC2047.decode`, unfolded |
| `Message-ID`, `In-Reply-To`, `References` | `messageIdHeader`, `inReplyTo`, `referencesList` | trimmed; References split on whitespace, keep `<…>` tokens |
| `Date` header | — | **not stored**; `internalDate` is used for display and attribution (`gmail-api.md` §5: more reliable than Date) |
| `payload` parts (format=full) | `bodyHtml`, `bodyText`, `hasRemoteImages`, `darkStrategy`, `sanitizerVersion`, `bodyFetched=1` | `MessageParser.parse` → `Sanitizer.sanitize` |
| parts with `filename`/`attachmentId` | `attachment` rows | `ParsedAttachment`; `isInline` = contentId referenced by `<img src="cid:">` |
| `Label.*` | `label.*` | `labels.list` gives id/name/type/visibility; `labels.get` gives counts/color (`gmail-api.md` §10–11) |
| `Profile.emailAddress`, `SendAs[*]` | `syncState.accountEmail`, `displayName`, `selfAddresses` (JSON array) | at first sync |
| `Profile.historyId` / `ListHistoryResponse.historyId` | `syncState.historyId` | string as received |
| `ListThreadsResponse.nextPageToken` | `syncState.nextPageToken` | for "Load older" |

### 3.4 What is NOT stored, and why
- Raw HTML or raw MIME of received mail — only the sanitized fragment (`html-rendering.md` §6.2). A sanitizer bump re-fetches lazily.
- Attachment bytes — downloaded on tap to `tmp/attachments/<messageId>/<filename>`, purged on launch; inline images cached in `Caches/cid/<messageId>/<sha1(cid)>` (system may purge).
- OAuth tokens — Keychain only (`ios-platform.md` §1.5, §5.5).
- Settings (theme, compose style, signature, toggles) — `UserDefaults` JSON (§11).
- `Date:` header, `sizeEstimate`, all other headers, `resultSizeEstimate` (an estimate; never shown — `gmail-api.md` gotcha 21).
- Thread-level records — the view derives them.
- Drafts — a failed `SendJob` in `outbox` is the draft.
- Anything about SENT/other mailboxes beyond what INBOX threads contain.

### 3.5 Record example (pattern for all records)

```swift
struct MessageRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "message"
    var id: String; var threadId: String; var historyId: Int64; var internalDate: Int64
    var fromName: String?; var fromAddr: String
    var toList: [Mailbox]; var ccList: [Mailbox]; var replyToList: [Mailbox]      // JSON columns (GRDB Codable → JSON TEXT)
    var subject: String; var snippet: String
    var messageIdHeader: String?; var inReplyTo: String?; var referencesList: [String]
    var labelIds: [String]; var isUnread: Bool; var inInbox: Bool; var isHidden: Bool
    var hasAttachments: Bool; var bodyFetched: Bool
    var bodyHtml: String?; var bodyText: String?; var hasRemoteImages: Bool; var darkStrategy: DarkStrategy; var sanitizerVersion: Int

    mutating func setLabels(_ ids: [String]) {
        labelIds = Array(Set(ids)).sorted()
        isUnread = labelIds.contains("UNREAD"); inInbox = labelIds.contains("INBOX")
        isHidden = labelIds.contains("TRASH") || labelIds.contains("SPAM")
    }
    static func databaseJSONEncoder(for column: String) -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }
}
```
`sortedKeys` per `ios-platform.md` §2.4 so `ValueObservation` change detection is stable.

---

## 4. Sync engine

### 4.1 Overview

```
refresh()  ──► historyId stored?  no ──► fullSync()
                 │ yes
                 ▼
             deltaSync() ── 404 ──► clearMessageCache(); fullSync()
                 │
                 ▼
             reapply pending outbox modifies (inside the same write)
             refreshLabels()  (labels.list + batched labels.get; cheap)
             updateBadge()
             outbox.drain()
```
Triggers: app becomes active (`scenePhase == .active`, throttled to once per 60 s), pull-to-refresh (no throttle), BG app refresh, after sign-in, after a send completes (to pick up SENT + thread changes). No timers.

Quota shape (pessimistic table, `gmail-api.md` quotas — UNVERIFIED units): full sync 50 threads ≈ 10 (threads.list) + 50×40 (threads.get metadata) + 15 (labels) ≈ 2,000 units, once. Delta ≈ 2 + 20 × new messages + 15. Thread open with 3 bodies ≈ 60. Well under 6,000 units/min.

### 4.2 Initial / full sync

```
fullSync():
    profile  = gmail.getProfile()                                   // baseline historyId BEFORE listing (gmail-api.md §13 semantics 1)
    sendAs   = gmail.listSendAs()                                   // displayName + alias addresses for reply-all self-dedupe
    labels   = gmail.listLabels()
    shown    = ["INBOX"] + labels.filter{ type == "user" && labelListVisibility != "labelHide" }.ids
    details  = gmail.getLabels(ids: shown)                          // batched, counts + colors
    page     = gmail.listThreads(labelIds: ["INBOX"], maxResults: 50, pageToken: nil)
    threads  = gmail.getThreads(ids: page.threads.ids, format: .metadata)   // batches of 25; failures per id logged & skipped
    parsed   = threads.values.flatMap{ $0.messages.map(MessageParser.parse) }        // off main (actor)
    db.write:
        Writes.clearMessageCache()                                  // full sync always replaces the cache (bodies re-fetched on open)
        Writes.replaceLabels(labels merged with details)
        for m in parsed: Writes.upsertMessage(m)
        setSyncState(historyId, profile.historyId)
        setSyncState(nextPageToken, page.nextPageToken)
        setSyncState(lastFullSyncAt, now)
        setSyncState(accountEmail, profile.emailAddress); displayName; selfAddresses = {profile.email} ∪ sendAs.emails (lowercased JSON)
```
Why `threads.list + threads.get?format=metadata` and not `messages.list`: it yields **complete** threads (older messages of an inbox thread are often archived and lack INBOX), so the thread view never has holes and no completeness bookkeeping is needed. Quota cost is fine for one user (`gmail-api.md` §3, §11 budget).

`loadOlderThreads()` = same as the listing step with `pageToken = syncState.nextPageToken`, upsert only (no clear), store the new token; the inbox list shows a "Load older" row while a token exists.

### 4.3 Delta sync (history.list)

```
deltaSync():
    start = UInt64(syncState.historyId)!
    var added   = [String: [String]]()        // messageId → labelIds seed (from messagesAdded)
    var deleted = Set<String>()
    var deltas  = [(id: String, add: [String], remove: [String])]()   // in history order
    var newest  = syncState.historyId
    var token: String? = nil
    repeat:
        resp = gmail.listHistory(startHistoryId: start, pageToken: token)     // 404 propagates as GmailError.notFound
        for h in resp.history ?? []:
            for a in h.messagesAdded ?? []:   added[a.message.id] = a.message.labelIds ?? []
            for d in h.messagesDeleted ?? []: deleted.insert(d.message.id); added[d.message.id] = nil
            for l in h.labelsAdded ?? []:     deltas.append((l.message.id, l.labelIds ?? [], []))
            for l in h.labelsRemoved ?? []:   deltas.append((l.message.id, [], l.labelIds ?? []))
        newest = resp.historyId ?? newest
        token  = resp.nextPageToken
    while token != nil

    known    = db.read { ids of message rows among added.keys ∪ deltas.ids }
    toFetch  = Set(added.keys).subtracting(known).subtracting(deleted)
    // an unknown message that GAINED INBOX (moved from another client) must appear too
    for d in deltas where !known.contains(d.id) && d.add.contains("INBOX") && !deleted.contains(d.id): toFetch.insert(d.id)

    fetched  = gmail.getMessages(ids: Array(toFetch), format: .metadata)      // per-id 404 → dropped silently (gmail-api.md gotcha 5)
    parsedNew = fetched.successes.map(MessageParser.parse)
    // threads we have never seen: fetch the whole thread so it is complete
    unknownThreads = parsedNew.threadIds not in db
    wholeThreads   = gmail.getThreads(ids: unknownThreads, format: .metadata)
    parsedNew     += wholeThreads.messages.map(parse) (dedup by id, thread versions win)
    freshIds = Set(parsedNew.ids)

    db.write:
        for m in parsedNew: Writes.upsertMessage(m)                         // keeps an existing body if the row existed
        for id in deleted: Writes.deleteMessage(id)
        for d in deltas where !freshIds.contains(d.id):                      // freshly fetched rows already carry current labels
            Writes.applyLabelDelta(messageId: d.id, add: d.add, remove: d.remove)   // no-op if row missing
        outbox.reapplyPendingModifies(db)                                    // §4.6 conflict rule
        setSyncState(historyId, newest)
```
Facts used: `startHistoryId` is exclusive; ids are non-contiguous, never arithmetic; page until `nextPageToken` is absent; persist the last page's `historyId` (`gmail-api.md` §13). Trash/spam arrive as `labelsAdded: ["TRASH"]`, so `isHidden` handles them; `messagesDeleted` is permanent deletion only.

### 4.4 historyId expiry recovery

```
refresh():
    if syncState.historyId == nil: return try await fullSync()
    do { try await deltaSync() }
    catch GmailError.notFound { Log.sync.notice("history expired → full sync"); try await fullSync() }
    catch GmailError.badRequest(let m) where m.contains("historyId") { same }      // UNVERIFIED which code Google uses (gmail-api.md §13.5)
```
Full sync clears the message cache; bodies come back on next open; the outbox is untouched (its payloads carry ids, not row references). Expected after >7 days offline, rarely after hours (`gmail-api.md` §13 retention).

### 4.5 Body lazy-load

```
ensureBodies(threadId):
    ids = db.read { message ids in thread where bodyFetched == 0 || sanitizerVersion < Sanitizer.version }
    if ids.isEmpty: return
    results = gmail.getMessages(ids: ids, format: .full)                    // one batch (threads are small); 404 → skip
    for (id, msg) in results.successes:
        parsed = MessageParser.parse(msg)
        if parsed.body.deferredTextPartIds non-empty:                       // large text delivered as attachment (mime-rfc.md §5.2 h)
            for partId: data = gmail.getAttachment(messageId, attachmentId) → decode into parsed.body
        body = parsed.body.html.map { Sanitizer.sanitize(html: $0, messageId: id) } ?? Sanitizer.fromPlainText(parsed.body.text ?? "")
        db.write { Writes.upsertMessage(parsed); Writes.storeBody(id, body, text: parsed.body.text) }   // attachments rows refreshed with new attachmentIds
```
Runs inside `SyncEngine` (off main). `ThreadModel` observes the DB, so the document re-renders when bodies land. Attachments are never prefetched (PLAN.md).

### 4.6 Label / unread count derivation
- **Row state** (unread dot, inbox membership): SQL from `message` mirrors; instant, offline.
- **Unread filter count** in the UI: `SELECT COUNT(*) FROM threadSummary WHERE inInbox AND isUnread` (local).
- **Label list counts + app badge**: server values from `labels.get` (`threadsUnread`) refreshed after every sync (`gmail-api.md` §11: INBOX.threadsUnread is the badge). Local cache cannot count labels it does not hold. If the server call fails, the last stored counts stay.
- Badge: `UNUserNotificationCenter.current().setBadgeCount(threadsUnread of INBOX)` only when `settings.showBadge` (needs `.badge` authorization — `ios-platform.md` §6).

### 4.7 Conflict rules (optimistic local vs server)
1. A user action writes the DB first (`Writes.applyThreadDelta`) and enqueues a `ModifyOp` in the **same transaction**. The list updates instantly through `ValueObservation`.
2. History records are applied over the DB as they come (server wins) — including our own echoed changes (idempotent set ops).
3. After every delta write, every `pending`/`inflight` `ModifyOp` is re-applied locally (`Outbox.reapplyPendingModifies`). Net effect: an unsent local change always shows until it is acknowledged; once sent it becomes the server state. No timestamps, no vector clocks.
4. Once the server acknowledges an op the row is deleted; the next delta echo is a no-op.
5. Sends: the sent message appears through history (`messagesAdded` with SENT) like any other message; nothing is inserted locally.

### 4.8 Outbox

Ops: `modify` (payload `ModifyOp {threadId, add, remove}`) and `send` (payload `SendJob`). Processing is strictly sequential in `id` order (one actor, one loop), so a "mark read" and a later "mark unread" on the same thread never race.

```
drain():
    guard !draining else return; draining = true; defer { draining = false }
    loop:
        row = db.read { first outbox row where state != 'failed' AND nextAttemptAt <= now ORDER BY id }
        guard row else break
        db.write { markOutbox(row.id, state: inflight, attempts: row.attempts + 1) }
        do:
            switch row.kind:
            case modify: op = decode(ModifyOp); try await gmail.modifyThread(id: op.threadId, add: op.add, remove: op.remove)
            case send:   try await performSend(row)
            db.write { deleteOutbox(row.id) }
        catch let e as GmailError:
            if e.isRetryable && row.attempts < maxAttempts(row.kind):        // modify: 8, send: 5
                delay = min(300, 2^attempts) seconds + jitter(0…1); if case .rateLimited(let ra) = e, let ra { delay = max(delay, ra) }
                db.write { markOutbox(row.id, state: pending, nextAttemptAt: now + delay, error: e.description) }
                if delay > 10: break   // give up this drain; the next trigger (foreground/sync/BG) resumes
            else if row.kind == modify:
                // 4xx on a label op (thread gone, label deleted): drop it; delta sync reconciles the local view
                db.write { deleteOutbox(row.id) }; Log.outbox.error(...)
            else:
                db.write { markOutbox(row.id, state: failed, error: e.description) }   // shown in the Outbox section (§8)
        catch GmailError.unauthorized: db.write { markOutbox(pending) }; break         // AuthStore handles sign-out

performSend(row):
    job = decode(SendJob)
    if job.transmitted:                                                     // request was on the wire before → may have succeeded
        found = try await gmail.listMessages(q: "rfc822msgid:\(job.messageID)", maxResults: 1)   // gmail-api.md §14 idempotency
        if found.messages non-empty: return
    original = db.read { MessageRecord + attachments for job.originalMessageId }
    bodies   = Composer.bodies(mode: job.mode, typed: job.typedText, style: style, original: original.asOriginalMessage, timeZone: .current)
    atts: [OutgoingAttachment] = []
    if job.mode == .forward && !job.attachmentPartIds.isEmpty:
        fresh = try await gmail.getMessages(ids: [job.originalMessageId], format: .full)   // attachmentIds may change (gmail-api.md gotcha 14)
        for part in MessageParser.parse(fresh).attachments where job.attachmentPartIds.contains(part.partId):
            data = try await gmail.getAttachment(messageId: job.originalMessageId, attachmentId: part.attachmentId!)
            atts.append(.init(filename: part.filename, mimeType: part.mimeType, data: data))
        guard atts.totalBytes <= 20 MB else throw GmailError.badRequest("attachments too large")   // → failed, user sees it
    msg = OutgoingMessage(from: me.primary, to: job.to, cc: job.cc, subject: job.subject, date: now, timeZone: .current,
                          messageID: job.messageID, inReplyTo: job.inReplyTo, references: job.references,
                          textBody: bodies.text, htmlBody: bodies.html, attachments: atts)
    raw = MIMEBuilder.build(msg)
    db.write { update payload.transmitted = true }                          // BEFORE the POST
    _ = try await gmail.send(raw: raw, threadId: job.threadId)
```
Send is wrapped in `UIApplication.shared.beginBackgroundTask` by `MailActions.send` so a swipe-away does not kill it (`ios-platform.md` §3.5). Both reply and forward carry `threadId` + `In-Reply-To` + `References` (Gmail-web behaviour, `mime-rfc.md` §1.5 recommendation).

Failure UX: a `failed` send row renders as an "Outbox" section at the top of the inbox list: subject, "Not sent — <short error>", swipe actions **Retry** and **Delete**, tap → opens Compose prefilled from the job (edit and resend creates a new job and deletes the old one). Nothing modal, nothing lost. Modify failures are silent (log only) by design.

---
## 5. Auth

### 5.1 Flow (AppAuth-iOS 3.0.0, `ios-platform.md` §1)
```
SignInScreen "Sign in with Google"
  → AuthStore.signIn():
      config  = OIDServiceConfiguration(authorizationEndpoint: accounts.google.com/o/oauth2/v2/auth, tokenEndpoint: oauth2.googleapis.com/token)   // hard-coded, verified via OIDC (gmail-api.md OAuth); no discovery round-trip
      request = OIDAuthorizationRequest(configuration: config, clientId: clientID, clientSecret: nil,
                    scopes: ["https://www.googleapis.com/auth/gmail.modify"], redirectURL: redirectURL,
                    responseType: OIDResponseTypeCode, additionalParameters: ["hd": "example.com"])   // hd optional/harmless (UNVERIFIED for native)
      agent   = OIDExternalUserAgentIOS(presentingViewController: keyWindow.rootViewController, prefersEphemeralSession: false)  // shared session: one-tap if already signed in
      currentFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
                        Task { @MainActor in self.finish(state, error) } }
  → finish(): authState = state; authState.stateChangeDelegate = self; persist(); state = .signedIn
  → AppEnvironment observes .signedIn → sync.refresh()
```
- Exactly one scope, `gmail.modify` — sufficient for every stage-1 call including `send` and `sendAs.list` (`gmail-api.md` §14, §15, gotcha 1). No `openid`/`email` scope: the address comes from `getProfile`.
- Redirect: `com.googleusercontent.apps.<ID>:/oauth2redirect` (single slash), scheme registered in `CFBundleURLTypes` (`gmail-api.md` gotcha 19). `.onOpenURL` calls `auth.resume(url:)` as the documented fallback (`ios-platform.md` §1.4).
- Workspace prerequisite (owner checklist, not code): OAuth app type **Internal**; admin marks the client Trusted or enables "Trust internal, domain-owned apps", else `admin_policy_enforced` (`gmail-api.md` OAuth scopes section — SNIPPET-verified). `SignInScreen` shows that exact hint when the error string contains `admin_policy_enforced`.

### 5.2 Token storage
- Whole `OIDAuthState` archived with `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)` into the Keychain item `service = "com.minimail"`, `account = "oauth.authState"`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (BG refresh works after first unlock; item never migrates to another device) — `ios-platform.md` §1.5, §5.5. Persist again on every `OIDAuthStateChangeDelegate.didChange`.
- `Keychain.swift` is the 3-function enum from `ios-platform.md` §5.5, verbatim.
- Restore at launch: `AuthStore.restore()` (sync, before first frame) → `.signedIn` if an archived state exists, else `.signedOut`.

### 5.3 Refresh and 401 handling
```swift
func accessToken() async throws -> String {           // TokenProvider, MainActor
    guard let s = authState else { throw GmailError.unauthorized }
    return try await withCheckedThrowingContinuation { cont in
        s.performAction { token, _, error in           // refreshes if expired; AppAuth serializes internally (UNVERIFIED) —
            if let token { cont.resume(returning: token) } else { cont.resume(throwing: Self.map(error)) }
        }                                               // hop is safe: continuations are Sendable
    }
}
func invalidateAccessToken() { authState?.setNeedsTokenRefresh() }
```
- `GmailClient.request` on HTTP 401: `await tokens.invalidateAccessToken()` and retry the request once; a second 401 throws `GmailError.unauthorized`.
- `map(error)`: AppAuth `OIDOAuthTokenErrorDomain` with `invalid_grant` (revoked, password changed, 6-month idle, 50-token cap — `gmail-api.md` refresh-token rules) → `GmailError.unauthorized`; transient network errors → `GmailError.network`.
- `AppEnvironment` catches `GmailError.unauthorized` from `SyncEngine`/`Outbox` → `auth.handleUnauthorized()` → state `.signedOut`, keeps DB (re-login restores the same account instantly). No retry loops.
- Because `MainActor` is the default, `AuthStore` is main-actor isolated; a token fetch from the `GmailClient` actor is one hop and returns immediately when the token is fresh (AppAuth checks expiry locally). Measured cost is microseconds; not a bottleneck.

### 5.4 Sign-out
`AppEnvironment.signOut()`: best-effort `POST https://oauth2.googleapis.com/revoke` with the refresh token (`gmail-api.md` OAuth revocation) → `Keychain.delete` → cancel in-flight sync → close pool → `Database.destroy(directory)` → `settings.clearAccountBits()` (nothing account-specific lives there; the call is a no-op placeholder that keeps style/theme) → `setBadgeCount(0)` → state `.signedOut`. Cached attachments in `tmp/` and `Caches/cid/` are deleted too.

### 5.5 Single-account assumptions
- One `OIDAuthState`, one DB file, one `syncState.accountEmail`. Signing in with a different Google account after sign-out is fine because the DB was destroyed.
- If `getProfile().emailAddress` at first sync differs from a non-empty `syncState.accountEmail` (should be impossible after a destroy), the engine clears the cache and re-runs the full sync.

---

## 6. Networking

### 6.1 `GmailClient` shape
One `actor`, one `URLSession` (default configuration, `waitsForConnectivity = false`, `timeoutIntervalForRequest = 30`, `httpAdditionalHeaders = ["Accept": "application/json"]`), one private `request` function every public method uses:

```swift
private func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, retryAuth: Bool = true) async throws -> Data {
    var url = baseURL.appending(path: path); url.append(queryItems: (query + [("prettyPrint", "false")]).map(URLQueryItem.init))   // repeated keys allowed: labelIds=A&labelIds=B
    var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body
    if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    return try await withRetry {
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)                     // URLError → GmailError.network
        let http = resp as! HTTPURLResponse
        Log.net.debug("\(method) \(path) → \(http.statusCode)")                  // never bodies, never tokens
        switch http.statusCode {
        case 200...299: return data
        case 401 where retryAuth: await tokens.invalidateAccessToken(); return try await request(method, path, query: query, body: body, retryAuth: false)
        default: throw GmailError.from(status: http.statusCode, body: data, headers: http.allHeaderFields)
        }
    }
}
```
Field masks: `getMessages(format: .metadata)` adds `fields=id,threadId,labelIds,snippet,historyId,internalDate,payload/headers` (`gmail-api.md` gotcha 23); `format=metadata` always sends all nine `gmailMetadataHeaders` as repeated `metadataHeaders` keys. Base URL from the Discovery `rootUrl` (`gmail-api.md` common facts). Batch URL `https://www.googleapis.com/batch/gmail/v1` (`gmail-api.md` §12, probe-verified).

### 6.2 Batching strategy
- Only three call sites batch: `getThreads`, `getMessages`, `getLabels`. Everything else is a single request.
- Chunk size **25**, chunks sent **sequentially** (not concurrently) — stays far below the ~50 concurrent-request cap and the per-minute unit budget (`gmail-api.md` quotas, gotcha 24).
- Wire format from `BatchCodec` (`gmail-api.md` §12): `Content-Type: multipart/mixed; boundary=…`, inner `GET /gmail/v1/users/me/messages/{id}?format=…`, `Content-ID: <{id}>`; response parts matched by `Content-ID: <response-{id}>`, inner status line parsed per part; the outer 200 means nothing.
- Per-part results are returned as `[id: Result<T, GmailError>]`; the caller decides (sync drops 404s, logs others). Parts that fail with a retryable error (429/5xx) are collected and re-sent in one follow-up batch after backoff, up to 3 rounds; then they surface as failures.

### 6.3 Error taxonomy → behaviour

| `GmailError` | Source | Client behaviour | Caller behaviour |
|---|---|---|---|
| `.unauthorized` | 401 twice, `invalid_grant` | throw | `AppEnvironment` → sign-out screen |
| `.forbidden(reason)` | 403 not rate-related (`admin_policy_enforced`, `dailyLimitExceeded`, `insufficientPermissions`) | throw | sync: show non-blocking error banner text; outbox: send → failed, modify → drop |
| `.rateLimited(retryAfter)` | 429, or 403 with reason `rateLimitExceeded`/`userRateLimitExceeded`/`concurrent` (reason strings SNIPPET-level, `gmail-api.md` common facts) | retry with backoff (below) | if exhausted: sync shows "Try again later"; outbox reschedules |
| `.server(status)` | 5xx | retry | same |
| `.network(URLError)` | transport | retry only for timeout / not-connected / lost-connection / DNS; others throw | same |
| `.notFound` | 404 | throw | history → full sync; message → drop; attachment → "no longer available" |
| `.badRequest(msg)` | 400 | throw | log; send → failed with message; sync → surface |
| `.decoding(msg)` | JSON/batch parse | throw | log with the first 200 bytes; treat like `.server` (retry once) |

`GmailError.from` decodes `GmailErrorEnvelope` leniently and reads `error.status`, `error.errors[0].reason`, and the `Retry-After` header.

### 6.4 Rate-limit / retry policy (single function)
```swift
func withRetry<T: Sendable>(maxAttempts: Int = 4, _ op: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do { return try await op() }
        catch let e as GmailError where e.isRetryable && attempt < maxAttempts - 1 {
            var delay = min(16, pow(2.0, Double(attempt))) + Double.random(in: 0...0.5)     // 1, 2, 4, 8 (+jitter), cap 16 s
            if case .rateLimited(let ra?) = e { delay = max(delay, ra) }
            Log.net.notice("retry \(attempt + 1) in \(delay)s: \(e)")
            try await Task.sleep(for: .seconds(delay)); attempt += 1
        }
    }
}
```
Backoff numbers follow `gmail-api.md` quotas guidance (start 1 s, exponential, honour `Retry-After`). Inside BG refresh the total budget is capped by checking `Task.isCancelled` before each attempt.

### 6.5 Logging
`Support/Log.swift`: `enum Log { static let net = Logger(subsystem: "com.minimail", category: "net"); sync, outbox, db, ui, web }`. Rules: request line + status + duration at `.debug`; retries and recoveries at `.notice`; failures at `.error` with the `GmailError` description (no bodies). Never log tokens, addresses, subjects (use ids). `os_signpost` intervals (`Support/Log.swift` `Signpost.begin/end`) for: `coldStartToList`, `deltaSync`, `fullSync`, `threadOpen`, `bodiesFetch`, `documentLoad`. In DEBUG the client also records `(method, path, status, ms)` into a ring buffer of 100 shown in Settings → Advanced → "Recent requests" (the agent's substitute for Charles).

---

## 7. Compose pipeline

Stage 1 composes only replies-all and forwards. Every step is pure in `MailCore` except attachment download and the final POST (outbox).

### 7.1 Reply-all recipients (`ReplyAll.recipients`, `mime-rfc.md` §2.1)
```
me = SelfIdentity(primary: Mailbox(name: displayName, addr: accountEmail), allAddresses: selfAddresses)
isSelfReply = from != nil && me.allAddresses.contains(from.key)
toCandidates = isSelfReply ? original.to : ((replyTo.isEmpty ? [from] : replyTo) + original.to)
ccCandidates = original.cc
seen = Set<String>()
To = toCandidates.filter { !$0.key.isEmpty && !me.allAddresses.contains($0.key) && seen.insert($0.key).inserted }
Cc = ccCandidates.filter { same predicate }                       // To wins over Cc
if To.isEmpty && !Cc.isEmpty { To = Cc; Cc = [] }
if To.isEmpty, let from { To = [from] }                           // never send with an empty To
```
Tests: the 16-row table in `mime-rfc.md` §8.1 verbatim.

### 7.2 Prefill (`Composer.prefill`)
- Reply-all: `to/cc` from §7.1; `subject = replySubject(original.subject)`; `inReplyTo = original.messageID`; `references = (original.references.isEmpty ? original.inReplyTo.map{[$0]} ?? [] : original.references) + [original.messageID]` deduped in order (RFC 5322 §3.6.4, `mime-rfc.md` §1.4); `threadId = original.threadId`.
- Forward: `to = []`, `cc = []`, `subject = forwardSubject(original.subject)`, same threading headers and `threadId` (Gmail-web variant, `mime-rfc.md` §1.5 recommendation and §7.3).
- Subject prefix rules: `Re: `/`Fwd: ` only if not already prefixed case-insensitively; `FW:`/`WG:` are not normalised (table `mime-rfc.md` §8.2).

### 7.3 Bodies (`Composer.bodies`)
HTML (`html-rendering.md` §5.5 + `mime-rfc.md` §4, Gmail 2023+ markup, byte-pinned by `mime-rfc.md` §7):
```
<div dir="ltr" class="minimail_default" style="{style.inlineCSS}">
  <div>line 1</div><div><br></div><div>line 3</div>                          -- typed text: escape &<>"; one <div> per line
</div>
[<div><br></div><span class="gmail_signature_prefix">-- </span><br>
 <div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature"><div style="{style.inlineCSS}">{signatureHTML}</div></div>]   -- only if signature non-empty
<br>
reply:   <div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On {attribution} {Name} &lt;<a href="mailto:{addr}">{addr}</a>&gt; wrote:<br></div>
         <blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">{ORIGINAL_HTML}</blockquote></div>
forward: <div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>
         From: <strong class="gmail_sendername" dir="auto">{Name}</strong> <span dir="auto">&lt;<a href="mailto:{addr}">{addr}</a>&gt;</span><br>
         Date: {attribution}<br>Subject: {subject}<br>To: {to line}[<br>Cc: {cc line}]<br></div><br><br>{ORIGINAL_HTML}</div>
```
Plain text: typed text, blank line, `-- ` + signature as text (tags stripped, `<br>`/`</div>` → newline), blank line, then `On … wrote:` + `> `-prefixed lines (`>` for empty lines), or the forward banner block (10 dashes / 9 dashes) with From/Date/Subject/To[/Cc] and the original text. `{attribution}` = `HeaderDate.attribution(internalDate, tz)` (`Thu, Sep 10, 2026 at 9:12\u{202F}AM`).

`ORIGINAL_HTML` = the cached **sanitized** fragment with two reversals: `img.mm-remote[data-src]` → `src` restored (we forward the sender's real image URLs, not our placeholder) and `minimail-cid://…` → `cid:…` (forward re-attaches inline parts only when the user keeps them; otherwise the `<img>` is dropped). If only `bodyText` exists: escape + `<br>`.

### 7.4 MIME (`MIMEBuilder.build`, `mime-rfc.md` §1.3, §3)
Header order fixed: `From`, `To`, `Cc` (omitted if empty), `Subject`, `Date`, `Message-ID`, `In-Reply-To` (if any), `References` (if any), `MIME-Version: 1.0`, `Content-Type`. Structures A/B from `mime-rfc.md` §3.1; boundaries `=_minimail_<kind>_<16 hex>`; text parts `charset="UTF-8"` + quoted-printable; attachments `Content-Type: <mime>; name="<fn>"`, `Content-Disposition: attachment; filename="<fn>"; size=<n>` (+ `filename*=UTF-8''…` when non-ASCII), 76-column standard base64; CRLF everywhere; headers folded at 78; non-ASCII header text via RFC 2047 B-words. `raw = Base64URL.encode(bytes)` (padded). Unit tests compare SHA-256 to `b9f8078c…` (reply) and — after adding `In-Reply-To` per §7.3 of `mime-rfc.md` — a regenerated forward hash committed with the fixture.

### 7.5 Default font/color and signature
`ComposeStyle` (font family enum with web-safe stacks, `sizePx` 12–18, `colorHex`) wraps only the typed text; the signature sits in its own styled div so unstyled signatures inherit the defaults but inline styles inside win; the quote is outside the wrapper (`html-rendering.md` §5.2). Signature HTML is sanitized once when saved (`Sanitizer.sanitizeSignature`, keeps `https:` images). Settings offers "Import from Gmail" = `sendAs.signature` of the primary alias (`gmail-api.md` §15; the API never appends it, we embed it). Signature images: hosted `https://` only (`mime-rfc.md` §3.4).

### 7.6 Forward with attachments
Compose lists the original's non-inline attachments with toggles (all on by default); the chosen `partId`s go into `SendJob.attachmentPartIds`. Download happens in the outbox at send time (§4.8) via a fresh `messages.get?format=full` for current `attachmentId`s. Limit 20 MB total; above it the job fails with a clear message before any network call. Inline `cid:` images of the original are not re-attached in stage 1 (their `<img>` is dropped from the forwarded HTML; `mime-rfc.md` §6.1 notes Google's CLI does the same in plain mode).

### 7.7 Send via outbox
`ComposeScreen` Send → `ComposeModel.makeJob()` (generates `messageID = "<\(UUID().uuidString)@\(domain of accountEmail)>"`, `transmitted = false`) → `MailActions.send(job)` → `Writes.enqueue` → dismiss sheet immediately → `Outbox.drain()` under a UIKit background task. Success is silent (the message shows up in the thread on the next delta). Failure → Outbox section (§4.8).

---
## 8. UI

### 8.1 Screens and navigation graph

```
RootView
 ├─ auth.state == .signedOut  → SignInScreen
 └─ .signedIn → NavigationStack(path)
       └─ InboxScreen(scope: .inbox)                              [root]
            ├─ push  ThreadScreen(threadId)                        via NavigationLink(value: ThreadRoute)
            ├─ push  InboxScreen(scope: .label(id))                from LabelsScreen selection (pop LabelsScreen sheet, push)
            ├─ sheet LabelsScreen                                  toolbar "tag"
            ├─ sheet SettingsScreen  → push SignatureEditorScreen  toolbar "gearshape"
            └─ sheet ComposeScreen(job or prefill)                 from ThreadScreen toolbar, or Outbox row tap
```
`ThreadRoute(threadId: String)` and `.navigationDestination(for: ThreadRoute.self)`. Sheets are `.sheet(item:)` bound to an enum `ActiveSheet { labels, settings, compose(ComposeInput) }` on `InboxScreen`. That is the whole graph.

### 8.2 Screen contracts

| Screen | State (owned) | Actions | Empty / loading / error |
|---|---|---|---|
| **SignInScreen** | `auth.state`, `auth.lastError` | Sign in (button, `person.crop.circle.badge.checkmark`) | error text under the button; `admin_policy_enforced` → the Workspace-admin hint |
| **InboxScreen** | `InboxModel`: `query: ThreadQuery` (scope fixed, `todayOnly`, `unreadOnly` toggles), `rows: [ThreadRow]` (ValueObservation), `failedSends: [OutboxRecord]`, `hasOlder: Bool`, `isRefreshing`, `errorText: String?`, `activeSheet` | pull-to-refresh (`sync.refresh()`), segmented picker All/Today, unread toggle, tap row → push, swipe archive / read-unread, "Load older" row, Outbox row Retry/Delete/tap | `ContentUnavailableView("No Mail", systemImage: "tray")` when rows empty and not refreshing; "No unread mail"/"Nothing today" variants; first launch: `ProgressView("Loading inbox…")` while `syncState.historyId` is nil; errors: a one-line banner above the list (`exclamationmark.triangle`) with the text, auto-hides on next success |
| **ThreadScreen** | `ThreadModel`: `messages: [MessageRecord]` (ValueObservation on thread), `attachments`, `expanded: Set<String>`, `imagesAllowed: Bool`, `html: String` (rendered document), `previewURL: URL?` (QuickLook), `isLoadingBodies` | bottom toolbar: Reply all, Forward, Archive (pops), Read/Unread toggle; in-document taps: header toggle, "Load images", attachment row, address (copies to clipboard via menu) | headers render immediately from cache; bodies show a skeleton line "Loading…" per message until fetched; body fetch error → inline "Couldn't load message — Retry" inside the section |
| **ComposeScreen** | `ComposeModel`: `mode`, `to: String`, `cc: String` (comma-separated editable), `subject`, `body: String`, `attachments: [(part, included: Bool)]`, `validation: String?` | Cancel (confirm if body non-empty), Send (disabled until ≥1 valid To address) | validation text under To; never blocks on network |
| **LabelsScreen** | `labels: [LabelRecord]` (ValueObservation) | tap → set scope and push | empty: "No labels" (only after first sync) |
| **SettingsScreen** | `settings` via `@Bindable SettingsStore` | see §11 | none |
| **SignatureEditorScreen** | `html: String` draft, `preview: String` | Save (sanitizes), Import from Gmail | import error → inline text |

### 8.3 List row layout (`ThreadRowView`)
```
HStack(alignment: .top, spacing: 10)
  Circle 8pt (theme.unread) or Color.clear 8pt        // leading unread dot, vertically aligned with line 1
  VStack(alignment: .leading, spacing: 2)
    HStack: Text(participants).font(.body).fontWeight(isUnread ? .semibold : .regular).lineLimit(1)
            Spacer()
            [Image(systemName: "paperclip").font(.caption)]  Text(DayBoundary.rowLabel).font(.subheadline).foregroundStyle(theme.secondaryText)
            [Text("\(messageCount)").font(.caption2) in a capsule]   // only when > 1
    Text(subject.isEmpty ? "(No subject)" : subject).font(.subheadline).lineLimit(1)
    Text(snippet).font(.subheadline).foregroundStyle(theme.secondaryText).lineLimit(2)
    [HStack(4) { up to 2 user-label chips: Text(name).font(.caption2).padding(.horizontal 6, .vertical 2).background(labelColor.opacity(0.2)).clipShape(Capsule) }]
```
`List` with `.listStyle(.plain)`, rows identified by `threadId`, `.contentShape(Rectangle())`. System fonts only, no custom colours except theme tokens.

Swipe actions (`ios-platform.md` §5.2 signatures):
- leading, full swipe: **Archive** — `Label("Archive", systemImage: "archivebox")`, tint `theme.accent` (theme-driven rather than Mail's purple).
- trailing, full swipe: **Read/Unread** — `systemImage: isUnread ? "envelope.open" : "envelope.badge"`, tint `theme.accent.opacity(0.8)`.
- Haptics: `.sensoryFeedback(.impact(weight: .light), trigger: archiveCount)` (iOS 17) on archive; `.sensoryFeedback(.selection, trigger: unreadOnly)` on the filter toggle.

Toolbar: leading `tag` (Labels), principal title = "Inbox" or label name with `.navigationBarTitleDisplayMode(.large)`, trailing `HStack { Button(unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"), Button("gearshape") }`. Below the nav bar (`.safeAreaInset(edge: .top)`): `Picker("", selection: $todayOnly) { Text("All"); Text("Today") }.pickerStyle(.segmented)`.

### 8.4 Thread screen conventions
- `MailWebView` fills the content area; nav title = subject (`.inline`); bottom toolbar (`.toolbar { ToolbarItemGroup(placement: .bottomBar) }`): `arrowshape.turn.up.left.2` Reply all · `arrowshape.turn.up.right` Forward · `archivebox` Archive · `envelope.badge`/`envelope.open` Unread/Read.
- On appear: `sync.ensureBodies(threadId)` (async, ignore errors into `errorText`); mark read: `actions.markRead(threadId)` once bodies have been requested (not waiting for them), only if the thread `isUnread`.
- Expanded set initial: every unread message + the latest message (`html-rendering.md` §4 default).
- Attachments render as rows inside each message section (`paperclip` glyph via inline SVG data: URI, filename, size); tap → `WebMessage.attachment` → `AttachmentOpener.open(messageId, partId)` → fresh `messages.get?format=full` for the attachmentId → `attachments.get` → temp file → `.quickLookPreview($previewURL)` (`ios-platform.md` §5.4).
- Links: `LinkPolicy` cancels every `.linkActivated` navigation and calls `openURL` (`@Environment(\.openURL)`); `mailto:` is also handed to the system in stage 1 (no new-mail compose).

### 8.5 Compose screen conventions
`NavigationStack { Form { Section { TextField("To", text:) ; TextField("Cc", text:) ; TextField("Subject", text:) } Section { TextEditor(text: $body).frame(minHeight: 200) } Section("Quoting") { Text("On \(date), \(name) wrote:") or "Forwarded: \(subject)" .foregroundStyle(.secondary) } [Section("Attachments") { Toggle rows }] } .toolbar { Cancel (leading), Send (trailing, `.bold`) } }`. Plain `TextEditor` (`ios-platform.md` §5.3: sufficient, ~40 lines cheaper than `UITextView`). Keyboard toolbar not needed. `To`/`Cc` parsing uses `Mailbox.parseList` on Send; invalid → validation text.

### 8.6 Filters as SQL (`ThreadQuery.sql`)
```sql
-- base
SELECT * FROM threadSummary
WHERE 1=1
  [scope .inbox]      AND inInbox = 1
  [scope .label(id)]  AND threadId IN (SELECT threadId FROM message WHERE isHidden = 0 AND instr(labelIds, :labelToken) > 0)   -- :labelToken = "\"Label_12\""
  [todayOnly]         AND lastDate >= :startOfTodayMs          -- device time zone, DayBoundary.startOfToday (gmail-api.md gotcha 20: never server after:)
  [unreadOnly]        AND isUnread = 1
ORDER BY lastDate DESC
LIMIT :limit;
```
`instr` on the sorted JSON text is exact because ids are quoted inside the array; no `json_each` dependency. Observed with `ValueObservation.tracking { try ThreadRow.fetchAll($0, sql:, arguments:) }.start(in: db, scheduling: .immediate, …)` so the first paint is synchronous from cache (`ios-platform.md` §2.6). `startOfTodayMs` is recomputed on `.active` and at local midnight (a `Task` sleeping until midnight, cancelled on background) so "Today" rolls over.

Messages in a thread: `SELECT * FROM message WHERE threadId = ? AND isHidden = 0 ORDER BY internalDate ASC`.

### 8.7 iOS-native conventions checklist
- System fonts via text styles only (`.body`, `.subheadline`, `.caption`), Dynamic Type works automatically.
- SF Symbols used: `tray`, `tray.fill`, `tag`, `gearshape`, `archivebox`, `envelope.badge`, `envelope.open`, `arrowshape.turn.up.left.2`, `arrowshape.turn.up.right`, `paperclip`, `line.3.horizontal.decrease.circle(.fill)`, `exclamationmark.triangle`, `arrow.clockwise`, `trash`, `person.crop.circle.badge.checkmark`, `checkmark.circle`.
- `NavigationStack`, `List(.plain)`, `.refreshable`, `.swipeActions`, `.toolbar`, `Form` for settings, `ContentUnavailableView`, `.sensoryFeedback` — all iOS 17 SwiftUI, nothing custom-drawn except the unread dot and label chips.
- Colours only via `ThemeTokens`; `AccentColor` in the asset catalog equals `LightTheme.tokens.accent`.

---

## 9. HTML rendering

### 9.1 Sanitizer (`MailCore/Sanitizer.swift`, `html-rendering.md` §1)
Pipeline per message at body-fetch time, off main, result cached in SQLite:
1. `SwiftSoup.parseBodyFragment(html, "")`.
2. For each `img`: `cid:` → `minimail-cid://<messageId>/<percent-encoded cid>`; `data:image/*` kept; `http(s)` → `data-src` = original, `src` = 1×1 GIF placeholder, class `mm-remote`, `hasRemoteImages = true`; anything else → `src` removed; `srcset`/`sizes`/`loading` removed. Tracking-pixel heuristic (remote + (tiny ≤ 2px | hidden) + no `alt`) → element removed (`html-rendering.md` §1.5).
3. `[background]` attributes dropped.
4. `DarkStrategy.classify` (`html-rendering.md` §3.3): declares `prefers-color-scheme`/`color-scheme` → `native`; any author background or (≥3 images and ≥2 tables) → `card`; else `plain`.
5. `SwiftSoup.clean` with the whitelist from `html-rendering.md` §1.3 (relaxed + `center font hr s del ins abbr address style wbr`; `style class dir lang align valign width height bgcolor border cellpadding cellspacing` on all; `img data-src`; `a href title` with `http https mailto tel`; `img src` with `data minimail-cid`; enforced `a target=_self`; the enumerated CSS property allowlist).
6. `StyleScrubber` regex pass on the cleaned fragment (`@import`, `@font-face`, non-`data:` `url()`, `expression(`, `behavior:`, `-moz-binding`, `javascript:`, `position:fixed|absolute`).
Output: `SanitizedBody(html, hasRemoteImages, darkStrategy)`. `Sanitizer.version` is stored per message; bump → lazy re-fetch.

### 9.2 WKWebView setup (`Web/WebViewHost.swift`, `html-rendering.md` §2.4, `ios-platform.md` §4)
```swift
static func makeConfiguration() -> WKWebViewConfiguration {
    let c = WKWebViewConfiguration()
    c.defaultWebpagePreferences.allowsContentJavaScript = false      // content JS off; app JS (evaluateJavaScript, message handlers) still runs (WWDC20 10188)
    c.defaultWebpagePreferences.preferredContentMode = .mobile
    c.websiteDataStore = .nonPersistent()
    c.dataDetectorTypes = []
    c.suppressesIncrementalRendering = true
    c.setURLSchemeHandler(cidHandler, forURLScheme: "minimail-cid")
    c.userContentController.add(RuleLists.blockAll)                  // swapped by setImagesAllowed
    c.userContentController.add(bridge, name: "mm")                  // window.webkit.messageHandlers.mm
    return c
}
// WKWebView: allowsLinkPreview = false; isOpaque = false; backgroundColor/underPageBackgroundColor = theme.background; navigationDelegate = LinkPolicy
// DEBUG: isInspectable = true
```
Rule lists compiled once via `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContentRuleList:)` with lookup-first (`contentRuleList(forIdentifier:)`), identifiers `minimail.block-all.v1` / `minimail.images-only.v1`; JSON exactly as `html-rendering.md` §2.2 (block `^https?://`, `^wss?://`, `^ftp://`, `^file://`; images-only adds `ignore-previous-rules` for `^https://` + `resource-type: ["image"]`). Toggling uses `removeAllContentRuleLists()` + `add(_:)` — name UNVERIFIED (`html-rendering.md` §2.2); fallback is creating a second configuration/web view for the images-on state.

Document loaded with `loadHTMLString(html, baseURL: nil)` (opaque origin, no relative URL resolution). CSP meta first in `<head>`: `default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'` (`https:` added to `img-src` when images allowed). Three independent layers: no content JS, rule list, CSP.

`LinkPolicy.decidePolicyFor`: `.linkActivated` → cancel + `openURL`; `.other` allowed only for `about:blank` (our own load); everything else cancelled (`html-rendering.md` §2.5).

### 9.3 Image blocking and "Load images"
Default: `settings.loadRemoteImages == false` → placeholders. A per-message HTML button "Load images" (rendered only when `hasRemoteImages`) posts `{type:"loadImages"}`; `ThreadModel.imagesAllowed = true` → `WebViewHost.setImagesAllowed(true)` → re-render the document with the `https:` CSP variant and `data-src` restored to `src` for `img.mm-remote` (`ThreadDocument.render(imagesAllowed: true)` does the swap in Swift, no JS needed) → `loadHTMLString`. Reload is local and cheap (`html-rendering.md` §1.3 recommends reload over in-place swap because of CSP). Tracking pixels were removed at sanitize time, so they never load even after opt-in. `settings.loadRemoteImages == true` starts every thread with `imagesAllowed = true`. Scope is per thread view (no per-sender memory in stage 1).

Inline `cid:` images: `CIDSchemeHandler` resolves `minimail-cid://<messageId>/<cid>` → `attachment` row by `(messageId, contentId)` → cached file in `Caches/cid/` or `gmail.getAttachment` (attachmentId re-resolved through `messages.get?format=full` if the stored one 404s) → `didReceive(URLResponse)`, `didReceive(data)`, `didFinish()`; stopped tasks are tracked in a `Set<ObjectIdentifier>` so a late completion is ignored (`html-rendering.md` §2.6). These are not remote loads and are allowed by default.

### 9.4 Dark mode strategy (`html-rendering.md` §3)
No inversion. The template declares `<meta name="color-scheme" content="light dark">` + `:root{color-scheme:light dark}`, `body{background:transparent}` so the themed `UIView` colour shows through. Per message section class from `darkStrategy`:
- `mm-plain`: dark overrides (text `#E5E5EA`, links `#0A84FF`, `[style*="color"]{color:inherit!important}`, `font[color]{color:inherit!important}`).
- `mm-card`: untouched on a white 12px-radius card with `color-scheme: light`.
- `mm-native`: no overrides; the sender's own `prefers-color-scheme` CSS works.
The web view's `overrideUserInterfaceStyle` follows `ThemeStore.preferredColorScheme` so a forced Light/Dark theme reaches `prefers-color-scheme` (propagation UNVERIFIED — `html-rendering.md` §7; verify in M2, fallback: inject a `dark` class on `<html>` and duplicate the media rules under `.dark`). Header/attachment rows use the theme tokens as CSS custom properties (`--mm-bg`, `--mm-text`, `--mm-secondary`, `--mm-accent`, `--mm-separator`) so they match the native chrome exactly.

### 9.5 Sizing and interaction
The web view is the scroll view (`scrollView.isScrollEnabled = true`, `contentInsetAdjustmentBehavior = .automatic`); SwiftUI never measures it. No `ResizeObserver`, no height binding. Sections start collapsed/expanded via class; toggling runs `document.getElementById('m-<id>').classList.toggle('collapsed')` through `evaluateJavaScript` — no reload, scroll position kept. Message headers in HTML: `font: -apple-system-body`; viewport `width=device-width, initial-scale=1` with pinch-zoom allowed; `img,table{max-width:100%!important}`. Warm-up: `WebViewHost.warm()` runs after the first inbox paint (`Task` from `InboxScreen.task`) and loads `ThreadDocument.emptyDocument`, so the first thread open pays no process launch. Leaving `ThreadScreen` loads the empty document again to free the DOM. Signature preview in Settings uses its own throwaway `WKWebView` with the same configuration factory (the pooled one may be on screen under the sheet).

---
## 10. Theming

### 10.1 Types (`Theme/Theme.swift`)
```swift
struct ThemeTokens: Equatable, Sendable {
    var background: Color        // list/thread background
    var surface: Color           // grouped sections, chips
    var text: Color
    var secondaryText: Color
    var accent: Color            // buttons, swipe tint, links
    var unread: Color            // unread dot
    var separator: Color
    var chipBackground: Color
    var css: ThemeCSSTokens      // hex strings for ThreadDocument (computed once in init)
}
protocol Theme: Sendable {
    var id: String { get }             // "light", "dark" — stable, persisted
    var name: String { get }           // shown in the picker
    var colorScheme: ColorScheme { get }   // what SwiftUI/WebKit should render as
    var tokens: ThemeTokens { get }
}
struct LightTheme: Theme { let id = "light"; let name = "Light"; let colorScheme = ColorScheme.light
    let tokens = ThemeTokens(background: Color(hex: "#FFFFFF"), surface: "#F2F2F7", text: "#000000", secondaryText: "#6E6E73",
                             accent: "#007AFF", unread: "#007AFF", separator: "#C6C6C8", chipBackground: "#E5E5EA") }
struct DarkTheme: Theme  { let id = "dark";  let name = "Dark";  let colorScheme = ColorScheme.dark
    let tokens = ThemeTokens(background: "#000000", surface: "#1C1C1E", text: "#FFFFFF", secondaryText: "#8E8E93",
                             accent: "#0A84FF", unread: "#0A84FF", separator: "#38383A", chipBackground: "#2C2C2E") }
```
Values are the iOS system palette so the app is indistinguishable from a system app; fixed hex (not `Color(.systemBackground)`) so a theme is a self-contained value that can later come from JSON.

### 10.2 Store (`Theme/ThemeStore.swift`)
```swift
@Observable final class ThemeStore {
    static let registry: [String: any Theme] = ["light": LightTheme(), "dark": DarkTheme()]   // add a theme = one struct + one entry
    var choice: ThemeChoice                        // .system | .light | .dark ; written back to SettingsStore
    var preferredColorScheme: ColorScheme? { choice == .system ? nil : resolved(for: .light).colorScheme }
    func resolved(for systemScheme: ColorScheme) -> any Theme {
        switch choice { case .system: systemScheme == .dark ? Self.registry["dark"]! : Self.registry["light"]!
                        case .light: Self.registry["light"]!; case .dark: Self.registry["dark"]! }
    }
}
```
Usage: `RootView` applies `.preferredColorScheme(theme.preferredColorScheme)` and `.environment(themeStore)`. A view reads `@Environment(ThemeStore.self) var theme` + `@Environment(\.colorScheme) var scheme` and uses `theme.resolved(for: scheme).tokens.text`. To keep call sites short, a `View` extension `themeTokens` returns that. Views use tokens only — never raw colours (`grep -n "Color(red\|Color(\." minimail/Features` in `make lint` should find nothing outside `Theme/`).

Extensibility: `ThemeChoice` gains cases (or a `.custom(id)` case later); `registry` gains entries; JSON-defined themes would decode into a `struct JSONTheme: Theme`. Nothing else changes. `SystemTheme` is not a type — "System" is a choice that resolves to Light/Dark, which keeps `Theme` a plain value.

### 10.3 Persistence
`Settings.themeChoice` (§11) is the source of truth; `ThemeStore.choice` mirrors it (`didSet` writes back through `SettingsStore`). The web view receives `interfaceStyle` from `preferredColorScheme` (`.unspecified` for System) so its `prefers-color-scheme` matches.

---

## 11. Settings model

```swift
struct Settings: Codable, Equatable, Sendable {
    var themeChoice: ThemeChoice = .system
    var composeStyle: ComposeStyle = ComposeStyle()          // family .helvetica, 14 px, #000000, signature ""
    var loadRemoteImages: Bool = false                       // images off by default (PLAN.md)
    var showBadge: Bool = false                              // opt-in; toggling on requests .badge authorization (ios-platform.md §6)
    var markReadOnOpen: Bool = true
    var inboxPageSize: Int = 50                              // threads per full-sync / load-older page
    var schemaVersion: Int = 1                               // for future migrations of this struct
}
```
- Stored as JSON under `UserDefaults.standard` key `"settings.v1"`; `SettingsStore.init` decodes with `(try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()`. `Settings` implements `init(from:)` by hand with `decodeIfPresent` per field (about 10 lines) so a field added later never resets the owner's settings; unknown keys are ignored by `JSONDecoder` anyway.
- Settings screen (Form sections): **Account** (email from `syncState`, "Sign out" destructive) · **Appearance** (Theme picker System/Light/Dark) · **Compose** (Font family picker, Size picker 12–18, `ColorPicker("Text color")` bound through hex, Signature → editor with Import from Gmail) · **Privacy** (Load remote images automatically) · **Notifications** (Show unread count on icon) · **Advanced** (Mark read when opened, Full resync now, Recent requests (DEBUG), version).
- Account facts (`accountEmail`, `displayName`, `selfAddresses`) are deliberately **not** in `Settings`: they belong to the DB (`syncState`) and disappear with sign-out.

---

## 12. Performance & battery budget

Targets are measured with the `os_signpost` intervals from §6.5 (read in Instruments or `log stream --predicate 'subsystem == "com.minimail"'` on device / `xcrun simctl spawn booted log stream` on simulator).

| Metric | Target | How it is met |
|---|---|---|
| Cold start → first inbox paint | **< 400 ms** on iPhone 12-class | `Database.open` + migrate < 30 ms (one migration, WAL); `ValueObservation` with `.immediate` scheduling paints from SQLite before any network; AppAuth restore is a Keychain read (< 5 ms); no work on launch except `restore()` and the observation. Network starts after first frame (`.task`). |
| Delta refresh (≤ 5 new messages) | **< 1 s** end-to-end | `history.list` (1 request) + one batch of `messages.get?format=metadata` + `labels.get` batch; three round-trips total; writes in one transaction. |
| Full sync (50 threads) | < 5 s | 1 list + 2 batches of 25 `threads.get?format=metadata` + 1 labels batch; parse off main. |
| Thread open, bodies cached | **< 100 ms** to visible content | one SQL read + string concat + `loadHTMLString` on a warmed web view (`suppressesIncrementalRendering` = single paint). |
| Thread open, bodies not cached | < 1.5 s for 3 messages | one batch `format=full`; sanitize ≈ 5–20 ms per 100 KB (measure; SwiftSoup) off main. |
| Scroll | 60/120 fps, no hitching | rows are plain `Text`/`HStack`; no images in rows; `List` with stable ids; query limited to 300 rows. |
| Memory | app < 60 MB steady; WebContent separate | one `WKWebView`; DOM dropped on leaving the thread; GRDB memory management on warnings; sanitized bodies only. |
| Network bytes / delta | < 50 KB typical | `prettyPrint=false`, `fields=` masks, metadata format, no prefetch of bodies/attachments. |
| Battery | no measurable drain idle | no timers, no sockets, no location, no analytics; BG refresh is one opportunistic `BGAppRefreshTask` (system-scheduled, `earliestBeginDate` +15 min) that does delta + drain + badge and returns; web view never runs JS or loads network; `URLSession` default (no background session). |
| Quota | < 3,000 units in any minute | batching ≤ 25, sequential chunks; pessimistic unit table from `gmail-api.md` used for the estimate. |

Tactics, concretely:
- **Never block main**: all `DatabasePool.read/write` from actors use the `async` forms; UI only observes. Sanitizing runs in `SyncEngine`.
- **No speculative work**: no body prefetch, no attachment prefetch, no image loads, no label counts beyond the labels shown.
- **Throttle**: foreground `refresh()` at most once per 60 s unless the user pulls; `SyncEngine.refresh()` coalesces concurrent callers into one run.
- **Web view lifecycle**: created once after first paint, warmed, reused; `about:blank`-equivalent empty document when idle.
- **Rule lists** compiled once and looked up by identifier afterwards (persisted by the store).
- **Badge** only when enabled (avoids an authorization prompt and a call per sync).
- **BG refresh discipline**: check `Task.isCancelled` between the three steps; skip entirely when signed out or when the DB throws `SQLITE_AUTH`/`SQLITE_IOERR` (device locked, `ios-platform.md` §2.2); always reschedule first thing in the handler.

Perf regression guard in tests: `DatabaseTests.testInboxQueryUnder5msWith5000Messages` (seeds 5,000 rows, asserts `ThreadQuery` fetch < 5 ms on the simulator with `measure {}` → XCTest baseline) and `SanitizerTests.testNewsletter100KBUnder50ms` in `MailCore`.

---

## 13. Testing strategy

### 13.1 Layers
| Layer | Runner | What | Count (approx.) |
|---|---|---|---|
| `MailCore` unit tests | `swift test` (Linux + macOS), seconds | every pure algorithm, table-driven from research vectors | ~120 cases |
| App unit tests (`minimailTests`) | `xcodebuild test` on simulator, minutes | DB schema/queries/writes, sync engine and outbox against stubbed HTTP, client behaviour, smoke hosting of screens | ~40 cases |
| Manual device checklist (M2/M4) | owner's iPhone via TestFlight | OAuth on the real Workspace account, BG refresh, dark mode in web view, QuickLook, badge prompt | 1 checklist in `docs/plan/device-checklist.md` |

No XCUITest, no snapshot tests in stage 1 (decision 9). A "smoke" XCTest instantiates `InboxScreen`/`ThreadScreen`/`ComposeScreen` inside `UIHostingController` with a seeded in-memory DB and asserts the models' observable state (rows count, rendered document contains the seeded subject, prefilled recipients) — it catches crashes and wiring errors without pixels.

### 13.2 `MailCore` tests and fixtures
- `Base64URLTests`: the table in `mime-rfc.md` §8.3 (padded/unpadded/both alphabets/reject).
- `QuotedPrintableTests`: the 7-row table (`Grüße`, `a=b`, trailing space, tab, 80×x soft break, `-- ` → `--=20`).
- `RFC2047Tests`: the 9-row decode table + encode round-trips.
- `MailboxTests`: the 10-row parse table (`mime-rfc.md` §8.4) + serialisation (`"Müller, Alice"` → B-encoded).
- `HeaderDateTests`: fixed dates in `Europe/Berlin` and `UTC` → `Fri, 11 Sep 2026 10:00:00 +0200`, attribution with U+202F.
- `GmailDTOTests`: decode every fixture JSON; string-typed `historyId`/`internalDate`; unknown keys ignored.
- `MessageParserTests`: the 8 payload shapes (a)–(h) from `mime-rfc.md` §5.2 as JSON fixtures; charset handling (`ISO-8859-1` part); inline vs attachment classification; deferred large text part.
- `SanitizerTests`: script/iframe/form/meta-refresh/`javascript:` removed; `on*` removed; remote `img` → placeholder + `data-src`; `cid:` rewrite; tracking pixel removed; `<style>` scrubbed of `@import`/`url()`; `DarkStrategy` classification for plain/card/native fixtures; signature keeps `https` images; `fromPlainText` linkifies.
- `ThreadDocumentTests`: document contains CSP (both variants), one section per message with the right class and `collapsed` state, no `data-src` left when `imagesAllowed`.
- `ReplyAllTests`: the 16-row table verbatim.
- `ComposerTests`: subject table (`mime-rfc.md` §8.2), threading headers per RFC 5322 §3.6.4 cases (parent with References / only In-Reply-To / nothing), reply and forward bodies contain the exact Gmail attribution/banner markup, `data-src` restored, `minimail-cid` reverted.
- `MIMEBuilderTests`: byte-exact reply (sha256 `b9f8078c1d50352b00f1486624bb2247ec19587ccf388b652aed62da0d1fcbd3`, 2276 bytes, `raw` string) and forward (regenerated variant with `In-Reply-To`, hash committed alongside `Fixtures/forward.eml`) with injected boundaries and frozen dates; structural checks (CRLF only, line length ≤ 998, `MIME-Version` once, attachments base64 76 cols, RFC 2231 for `Ängebot.pdf`).
- `BatchCodecTests`: encode matches the request in `gmail-api.md` §12 byte-for-byte (fixed boundary); decode the probe response fixture (200 + 401 parts), out-of-order `Content-ID`s, missing part.
- `DayBoundaryTests`: `startOfToday` around DST transitions in `Europe/Berlin`, `Pacific/Auckland`, `UTC`; `rowLabel` matrix (today, yesterday, this week, this year, older) for `de_DE` and `en_US`.

### 13.3 App tests (`minimailTests`)
- `DatabaseTests`: migration runs on an empty in-memory `DatabaseQueue`; `threadSummary` picks the latest message's subject/snippet/labels; `setLabels` mirrors; `ThreadQuery` SQL for all 8 scope/today/unread combinations; cascade delete of attachments; perf case from §12.
- `GmailClientTests` with `StubURLProtocol`: header/`fields`/repeated query construction; 401 → invalidate + one retry; 429 with `Retry-After` → sleeps (use an injectable `sleep` closure); batch chunking at 25 and per-part 404 mapping; error envelope → `GmailError`.
- `SyncEngineTests` (stubbed HTTP + in-memory DB): full sync populates messages/labels/syncState; delta applies `messagesAdded` (fetch), `messagesDeleted`, `labelsAdded/Removed`, unknown-message-gains-INBOX, unknown thread → whole thread fetch, 404 → full sync path clears cache; freshly fetched rows are not double-applied; `ensureBodies` stores sanitized body and attachment rows.
- `OutboxTests`: modify success deletes row; retryable failure schedules backoff; 4xx modify drops; send failure → `failed`; `transmitted` + `rfc822msgid` found → completes without POST; reapply pending modifies after a delta that reverted them.
- `SmokeTests`: as above.
- Fixtures: reuse the `MailCore` JSON fixtures (copied into the app test bundle by `project.yml` `sources`), plus `StubURLProtocol` route tables per test.

### 13.4 CI (`.github/workflows/ci.yml`)
Job `core` on `ubuntu-latest` with `swift-actions/setup-swift` (Swift 6.2) → `swift test` in `Packages/MailCore` (≈2 min). Job `ios` on `macos-26`, Xcode `'26.6'` via `maxim-lobanov/setup-xcode@v1`, `brew install xcodegen`, cache `.build/SourcePackages` keyed on `project.yml` + `Packages/MailCore/Package.swift`, `make test-app` (`tooling.md` §4). PRs run both; the `core` job is the fast signal.

---

## 14. Risks and open questions — with chosen resolutions

| # | Risk / question | Resolution chosen |
|---|---|---|
| 1 | **SwiftSoup on Linux** (needed for `swift test` of `Sanitizer` in `MailCore`; UNVERIFIED in `html-rendering.md`). | Try first (`swift build` in M1). If it fails, move `Sanitizer.swift` + its tests into the app target; everything else in `MailCore` stays Linux-testable. |
| 2 | **Swift 6 + MainActor default vs GRDB/AppAuth closures** (UNVERIFIED interplay, `tooling.md` §3.3). | Keep `MainActor` default; mark GRDB closures `nonisolated`/`@Sendable` where needed; `@preconcurrency import AppAuth`. Escape hatch in order: `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, then Swift 5 mode + complete checking. Decide in M1 on the first `DatabasePool.read`. |
| 3 | **`evaluateJavaScript` with `allowsContentJavaScript = false`** (needed for section toggle). | Apple's WWDC20 wording says app JS keeps working (`html-rendering.md` §2.1). If a device test disagrees, fall back to re-rendering the document on toggle (still local, loses scroll position). |
| 4 | **`removeAllContentRuleLists()` name** and **CSP accepting `minimail-cid:`**. | Verify in SDK headers in M2; fallbacks: second web view/config for images-on; drop the custom scheme from CSP and rely on the rule list (custom scheme loads are not `https`). |
| 5 | **`overrideUserInterfaceStyle` → `prefers-color-scheme` in WKWebView** (UNVERIFIED). | Test in M2; fallback: `html.dark` class with duplicated rules. |
| 6 | **historyId expiry** after long offline periods. | Full sync clears and rebuilds the cache (§4.4); bodies return on open. Accepted cost: ~2,000 units + a few seconds, rare. |
| 7 | **Quota unit table for new projects** (UNVERIFIED; `messages.get` may be 20, `threads.get` 40). | Designed for the pessimistic numbers; chunks of 25, sequential; delta uses `messages.get` metadata; no prefetch. The agent should fetch the official quota page once network allows and adjust `batchChunkSize` if needed. |
| 8 | **Thread completeness** — a delta for a reply to a thread we have never seen. | Rule in §4.3: unknown thread → `threads.get?format=metadata` for the whole thread. Full sync uses `threads.get`, so initial threads are complete. |
| 9 | **Send idempotency** (no server key). | Own `Message-ID`; `transmitted` flag set before the POST; retry checks `rfc822msgid:` first (§4.8). Residual risk: the `messages.list` index lag right after a send — retries wait ≥ 2 s, which is enough in practice (UNVERIFIED). |
| 10 | **Workspace admin policy** (`admin_policy_enforced`). | Owner checklist item before first login; the sign-in screen shows the exact remedy text. Not a code risk. |
| 11 | **Badge needs notification authorization** (`ios-platform.md` §6). | Opt-in toggle requests `[.badge]` only; if denied the toggle turns itself off with an explanation. `[.badge, .provisional]` behaviour is UNVERIFIED — not relied on. |
| 12 | **BG refresh while the device is locked** → DB `SQLITE_AUTH`/`SQLITE_IOERR`. | Directory protection `.completeUntilFirstUserAuthentication` + catch-and-exit in the handler; Keychain item is `AfterFirstUnlockThisDeviceOnly`. |
| 13 | **`attachmentId` instability** (community-reported). | Never trusted: re-resolved via `messages.get?format=full` before every download (attachments and forwards). |
| 14 | **Large inline text parts by `attachmentId`** (schema-allowed). | Handled in `ensureBodies` via `deferredTextPartIds` (§4.5). |
| 15 | **Data-protection / `eraseDatabaseOnSchemaChange` / `AnyDatabaseCancellable` exact GRDB names** (flagged in `ios-platform.md`). | Compile-time facts; the agent fixes names on first build. No design impact. |
| 16 | **Today + Unread in label scope**, "Today" semantics across midnight/time-zone changes. | All three filters are independent booleans on one query (§8.6); `startOfTodayMs` recomputed on activation and at local midnight; computed on device, never via server `after:` (`gmail-api.md` gotcha 20). |
| 17 | **Whole-thread read/unread** may differ from Gmail web's per-message behaviour. | Accepted simplification (decision list); consistent and predictable; per-message toggles can be added later as `messages.modify` ops with the same outbox. |
| 18 | **Forwarding inline images** (`cid:` parts) is dropped in stage 1. | Documented; the forward HTML omits those `<img>`s; stage 2 can re-attach via `multipart/related` (`mime-rfc.md` §3.1 C). |
| 19 | **Deleting the cache on sign-out or full sync loses "Load older" pages**. | Accepted; the user taps "Load older" again. |
| 20 | **Xcode 27 arrival mid-project** (2026-09-14). | Stay on 26.6 until the `macos-26` runner has 27 GA; deployment target unaffected; `BGTaskScheduler.submit` deprecation handled with the `#available(iOS 27)` branch from `ios-platform.md` §3.3 when the SDK moves. |

---

## Appendix A — Milestone mapping (from PLAN.md, unchanged order)

- **M1 Skeleton**: §1 tooling, `MailCore` skeleton with `Base64URL`/`GmailDTO`/`BatchCodec` + tests on Linux, `Database`+`Schema`, `AuthStore`, `GmailClient` (`getProfile`, `listThreads`, `getThreads`), `SyncEngine.fullSync`, `InboxScreen` with rows, `ThemeStore` light/dark.
- **M2 Read**: `MessageParser`, `Sanitizer`, `ThreadDocument`, `WebViewHost`/`MailWebView`/`CIDSchemeHandler`, `ensureBodies`, `deltaSync`, `MailActions` archive/read/unread + `Outbox` modify path, Today/Unread/label filters, `LabelsScreen`, `AttachmentOpener`.
- **M3 Write**: `Mailbox`/`RFC2047`/`QuotedPrintable`/`HeaderDate`, `ReplyAll`, `Composer`, `MIMEBuilder` (byte-exact tests), `ComposeScreen`, `Outbox` send path with idempotency, Outbox section UX.
- **M4 Polish**: `SettingsScreen`/`SignatureEditorScreen`, `BackgroundRefresh`, badge, perf signposts and the two perf tests, device checklist, TestFlight upload.
