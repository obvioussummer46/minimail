# minimail — Stage-1 architecture, candidate "SPEED"

Angle: **performance-first**. Every decision below is optimised for (1) time-to-first-painted-list on cold start, (2) zero jank while scrolling, (3) the smallest possible number of network round trips, (4) aggressive local caching so that the common path never touches the network, and (5) no self-initiated background work.

Date: 2026-09-11. Inputs: `/home/user/minimail/PLAN.md` (accepted outline) and the research files under `docs/plan/research/` — cited as `[gmail-api §N]`, `[ios-platform §N]`, `[mime-rfc §N]`, `[html-rendering §N]`, `[tooling §N]`. Facts marked UNVERIFIED in those files stay UNVERIFIED here and are listed in §14 with the resolution I chose.

Target reader: an AI coding agent working headless (Linux for editing, a macOS runner for `xcodebuild`). Everything is reproducible from files + CLI.

---

## 0. Decisions at a glance

| Topic | Decision | Why (performance lens) |
|---|---|---|
| Time-to-first-list | First frame is painted from SQLite via a **synchronous** `ValueObservation(.immediate)` over a **denormalised `thread` table** (no joins, one covering index, `LIMIT 60`). Nothing else runs before the first frame. | Cold start < 300 ms is only reachable if launch = open DB (~3 ms) + one indexed read (~2 ms) + SwiftUI first layout. Auth restore, sync, rule-list compile, WKWebView warm-up all start **after** the first frame. |
| Project | XcodeGen 2.46.0 `project.yml`, Xcode 26.6, iOS 17.0, Swift 6 + `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` for the app; a local SwiftPM package `MinimailCore` (nonisolated, Foundation + SwiftSoup only) for all pure logic, testable on Linux with `swift test`. | Static linking (SPM default) → fewer dylibs to load at launch; pure core = fast unit tests without a simulator. |
| Storage | GRDB 7.11.1 `DatabasePool` (WAL) in Application Support; list rows come from `thread` only; bodies live in a separate `message_body` table. | WAL lets the list re-read while the sync actor writes; small hot rows keep page reads minimal. |
| Sync | Initial: `getProfile` + `messages.list?labelIds=INBOX&maxResults=100` + **one** HTTP batch of `messages.get?format=metadata`. Delta: **one** `history.list` + at most **one** batch. Recovery from 404: cheap reconcile (two `messages.list` calls), never a wipe. | 2–3 round trips per foreground sync, 1–2 in BG refresh. |
| Bodies | Lazy on open, **plus** an idle-time prefetch of the newest 25 inbox threads (`threads.get?format=full`, batched) right after the first sync, skipped on Low Power / Low Data mode. | Thread open is a SQLite read in the common case — 0 network. |
| Rendering | SwiftSoup sanitizer runs once, off-main, at ingest; one pooled `WKWebView` **is the scroller**; whole thread = one HTML document. | No height measuring, no re-layout, one WebContent process, warmed after first paint. |
| Writes | Optimistic local mutation → `outbox` row → coalescing worker (`threads.modify` / `messages.batchModify` / `messages.send`). | UI never waits on the network; swipes coalesce into one request. |
| Auth | AppAuth-iOS 3.0.0 behind `TokenProvider`; hard-coded endpoints (no discovery round trip); `OIDAuthState` archived into Keychain (`AfterFirstUnlockThisDeviceOnly`). | Zero network at launch for auth; BG refresh works while locked. |
| Background | Only the system-scheduled `BGAppRefreshTask` (opt-out in Settings), budget: 1 `history.list` + ≤ 1 batch, then badge. No timers, sockets, push, or background `URLSession`. | Battery. |
| Theming | `Theme` struct (Codable) with light+dark palettes; `ThemeStore` `@Observable`; `System / Light / Dark` mode; new theme = one value + registry entry. | Views read semantic tokens only; theme switch re-renders without relaunch. |

---

## 1. Tooling & project layout

### 1.1 Toolchain (pinned)

| Item | Value | Source |
|---|---|---|
| Xcode | **26.6 (17F113)**, Swift 6.3, iOS 26.5 SDK; bump to 27.0 when the `macos-26` GitHub image ships it GA | `[tooling §3.1]` |
| Deployment target | **iOS 17.0** (`IPHONEOS_DEPLOYMENT_TARGET=17.0`); every Stage-1 API is ≤ iOS 17 | `[ios-platform §0]`, `[tooling §3.2]` |
| Language | `SWIFT_VERSION=6`, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY=YES` (app target). `MinimailCore` package: Swift 6 language mode, **nonisolated** default (pure, `Sendable` code). | `[tooling §3.3]`, `[ios-platform §5.6]` |
| Project generator | **XcodeGen 2.46.0**; `minimail.xcodeproj` is git-ignored and regenerated | `[tooling §1]` |
| Build helpers | `xcbeautify 3.2.1`, `swift format` (bundled), SwiftLint 0.65.1 | `[tooling §2, §5]` |
| Simulator | `platform=iOS Simulator,name=iPhone 17` (no iPhone 16 on the runner images) | `[tooling §2.2]` |
| CI | GitHub Actions `runs-on: macos-26`, `maxim-lobanov/setup-xcode@v1` → `'26.6'`, `actions/cache@v6` keyed on `project.yml` | `[tooling §4]` |
| Distribution | Apple Developer Program + TestFlight via `xcodebuild -exportArchive … destination=upload` | `[tooling §6]` |

### 1.2 SPM dependencies (exact pins)

| Package | Version | Product | Linked by | Source |
|---|---|---|---|---|
| `https://github.com/openid/AppAuth-iOS` | `3.0.0` | `AppAuth` | app | `[ios-platform §1.1]`, `[tooling §1.3]` |
| `https://github.com/groue/GRDB.swift` | `7.11.1` | `GRDB` | app | `[ios-platform §2.1]` |
| `https://github.com/scinfu/SwiftSoup` | `2.13.9` | `SwiftSoup` | `MinimailCore` | `[html-rendering §1.1]` |
| `https://github.com/pointfreeco/swift-snapshot-testing` | `1.19.4` | `SnapshotTesting` | `minimailTests` only | `[tooling §1.3]` |
| `Packages/MinimailCore` (local) | — | `MinimailCore` | app, `minimailTests` | this doc |

Nothing else. No Google SDK, no Alamofire, no Kingfisher, no GRDBQuery.

### 1.3 Folder tree (every file)

```
minimail/
├── PLAN.md
├── project.yml                         # XcodeGen spec (§1.4)
├── Makefile                            # gen / build / test-unit / test-core / test-ui / lint / format / archive
├── ExportOptions.plist                 # TestFlight upload [tooling §6.2]
├── .gitignore                          # minimail.xcodeproj/, .build/, DerivedData/, *.xcresult
├── .swift-format                       # [tooling §5.1]
├── .swiftlint.yml                      # [tooling §5.2]
├── .github/workflows/ci.yml            # [tooling §4.4] + a `core-linux` job running `swift test` in Packages/MinimailCore
├── Config/
│   ├── Signing.xcconfig                # DEVELOPMENT_TEAM = <owner fills in>
│   └── Google.xcconfig                 # GOOGLE_CLIENT_ID = <client-id-prefix>  (not secret; feeds Info.plist)
├── docs/plan/…                         # this document and research
├── Packages/MinimailCore/
│   ├── Package.swift
│   ├── Sources/MinimailCore/
│   │   ├── Base64URL.swift             # padded encode, tolerant decode [mime-rfc §1.2]
│   │   ├── HTMLEscape.swift
│   │   ├── DayBoundary.swift           # "today" logic, TZ-aware [gmail-api §Searching]
│   │   ├── GmailDTO/
│   │   │   ├── GmailMessage.swift      # Message, MessagePart, MessagePartBody, MessagePartHeader
│   │   │   ├── GmailThread.swift
│   │   │   ├── GmailLabel.swift        # Label, LabelColor, visibility enums
│   │   │   ├── GmailHistory.swift      # History, ListHistoryResponse
│   │   │   ├── GmailLists.swift        # ListMessagesResponse, ListThreadsResponse, ListLabelsResponse
│   │   │   ├── GmailProfile.swift      # Profile, SendAs, ListSendAsResponse
│   │   │   ├── GmailRequests.swift     # ModifyRequest, BatchModifyRequest, SendRequest
│   │   │   └── GmailErrorEnvelope.swift
│   │   ├── MIME/
│   │   │   ├── Mailbox.swift           # struct Mailbox(name, addr) + serialisation
│   │   │   ├── AddressParser.swift     # RFC 5322 §3.4 tokenizer [mime-rfc §2.2]
│   │   │   ├── RFC2047.swift           # encoded-word decode/encode [mime-rfc §2.3]
│   │   │   ├── RFC2231.swift           # parameter decoding [mime-rfc §2.4]
│   │   │   ├── ContentTypeParams.swift # `type/subtype; k=v` parser
│   │   │   ├── QuotedPrintable.swift   # encoder (76 col, uppercase) + tolerant decoder
│   │   │   ├── HeaderEncoding.swift    # ASCII/RFC2047 header values, folding at 78
│   │   │   ├── DateHeader.swift        # RFC 5322 date format/parse (en_US_POSIX)
│   │   │   ├── MessageID.swift         # <UUID@domain>, References chain [mime-rfc §1.4]
│   │   │   ├── MIMEPart.swift          # value types: OutgoingMessage, TextParts, AttachmentPart
│   │   │   ├── MIMEBuilder.swift       # RFC 5322 bytes for messages.send [mime-rfc §1, §3]
│   │   │   ├── PayloadParser.swift     # Gmail payload walk → ParsedPayload [mime-rfc §5]
│   │   │   ├── Charset.swift           # IANA charset → String
│   │   │   └── CIDMap.swift            # cid → part map, RFC 2392 [mime-rfc §5.4]
│   │   ├── Compose/
│   │   │   ├── ComposeStyle.swift      # family/size/color [html-rendering §5.4]
│   │   │   ├── ReplyAllResolver.swift  # recipient algorithm [mime-rfc §2.1]
│   │   │   ├── SubjectPrefix.swift     # Re:/Fwd: [mime-rfc §1.4, §1.5]
│   │   │   ├── Quoting.swift           # attribution line, gmail_quote markup, forward banner [mime-rfc §4]
│   │   │   ├── OutgoingHTML.swift      # styled wrapper, signature, quote [html-rendering §5.5]
│   │   │   ├── OutgoingText.swift      # text/plain alternative
│   │   │   └── ComposeDraft.swift      # value type the UI edits and the outbox serialises
│   │   ├── Sanitize/
│   │   │   ├── Sanitizer.swift         # SwiftSoup whitelist pipeline [html-rendering §1]
│   │   │   ├── StyleScrubber.swift
│   │   │   ├── TrackingPixel.swift
│   │   │   ├── DarkStrategy.swift
│   │   │   ├── PlainTextToHTML.swift   # escape + linkify text/plain bodies
│   │   │   └── ThreadDocument.swift    # HTML template for the thread web view [html-rendering §2.7, §4]
│   │   └── SyncLogic/
│   │       ├── LabelSet.swift          # ordered set of label ids + derived flags
│   │       ├── HistoryDelta.swift      # pure: history records → per-message label deltas / adds / deletes
│   │       └── ThreadSummary.swift     # pure: [MessageSummary] → ThreadSummary (denormalised row)
│   └── Tests/MinimailCoreTests/
│       ├── Base64URLTests.swift
│       ├── AddressParserTests.swift
│       ├── RFC2047Tests.swift
│       ├── RFC2231Tests.swift
│       ├── QuotedPrintableTests.swift
│       ├── DateHeaderTests.swift
│       ├── MIMEBuilderTests.swift      # pins the byte-exact examples (sha256) [mime-rfc §7]
│       ├── PayloadParserTests.swift
│       ├── ReplyAllResolverTests.swift # 16 vectors [mime-rfc §8.1]
│       ├── SubjectPrefixTests.swift
│       ├── QuotingTests.swift
│       ├── OutgoingHTMLTests.swift
│       ├── SanitizerTests.swift
│       ├── DarkStrategyTests.swift
│       ├── ThreadDocumentTests.swift
│       ├── HistoryDeltaTests.swift
│       ├── ThreadSummaryTests.swift
│       ├── DayBoundaryTests.swift
│       ├── GmailDTODecodingTests.swift
│       └── Fixtures/                   # see §13.2 for the list
├── minimail/                           # app target (MainActor default)
│   ├── Info.plist                      # GENERATED by xcodegen – never hand-edit
│   ├── minimail.entitlements           # generated, empty
│   ├── Resources/
│   │   ├── Assets.xcassets/            # AppIcon, AccentColor, LaunchBackground
│   │   ├── PrivacyInfo.xcprivacy       # UserDefaults CA92.1, file timestamp C617.1 [ios-platform §7]
│   │   └── Localizable.xcstrings
│   ├── App/
│   │   ├── MinimailApp.swift           # @main; scene, onOpenURL, backgroundTask, scenePhase
│   │   ├── AppContainer.swift          # composition root, lazily built services
│   │   ├── RootView.swift              # signed-in? list : sign-in
│   │   ├── LaunchTimeline.swift        # os_signpost markers for §12 targets
│   │   └── BackgroundRefresh.swift     # BG task body + scheduling
│   ├── Auth/
│   │   ├── OAuthConfig.swift           # endpoints, scope, clientID from Info.plist, redirect URL
│   │   ├── TokenProvider.swift         # protocol
│   │   ├── AppAuthTokenProvider.swift  # actor wrapping OIDAuthState + single-flight refresh
│   │   ├── AuthStore.swift             # @Observable session state, sign-in/out
│   │   └── Keychain.swift
│   ├── Gmail/
│   │   ├── HTTPTransport.swift         # protocol + URLSessionTransport
│   │   ├── GmailEndpoint.swift         # typed endpoint descriptions (path, query, body, fields=)
│   │   ├── GmailAPI.swift              # actor: typed calls, auth header, retries, batching
│   │   ├── BatchRequest.swift          # multipart/mixed builder [gmail-api §12]
│   │   ├── BatchResponse.swift         # parser
│   │   ├── GmailError.swift            # taxonomy §6.3
│   │   ├── Backoff.swift
│   │   └── RequestLimiter.swift        # semaphore(2)
│   ├── Store/
│   │   ├── AppDatabase.swift           # open pool, migrate, paths
│   │   ├── Migrations.swift            # v1 schema (§3)
│   │   ├── Records/
│   │   │   ├── LabelRecord.swift
│   │   │   ├── ThreadRecord.swift
│   │   │   ├── ThreadLabelRecord.swift
│   │   │   ├── MessageRecord.swift
│   │   │   ├── MessageBodyRecord.swift
│   │   │   ├── AttachmentRecord.swift
│   │   │   ├── OutboxRecord.swift
│   │   │   └── SyncStateRecord.swift
│   │   ├── Queries/
│   │   │   ├── ThreadListQuery.swift   # MailFilter → SQL (§8.6)
│   │   │   ├── ThreadDetailQuery.swift
│   │   │   └── LabelListQuery.swift
│   │   └── Ingest/
│   │       ├── MessageIngestor.swift   # DTO → records, sanitizer call, thread re-aggregation
│   │       └── ThreadAggregator.swift  # recompute thread row + thread_label from messages
│   ├── Sync/
│   │   ├── SyncEngine.swift            # actor; public entry points; state machine
│   │   ├── InitialSync.swift
│   │   ├── DeltaSync.swift
│   │   ├── Resync.swift                # 404 recovery
│   │   ├── BodyFetcher.swift           # thread open path
│   │   ├── BodyPrefetcher.swift        # idle prefetch
│   │   ├── LabelSync.swift             # labels.list + batched labels.get
│   │   └── SyncStatus.swift            # @Observable status for the UI
│   ├── Outbox/
│   │   ├── OutboxOp.swift              # Codable payloads
│   │   ├── OutboxWorker.swift          # actor; drain loop, backoff, idempotency
│   │   ├── OutboxCoalescer.swift       # pure merge of pending modify ops
│   │   ├── SendPipeline.swift          # draft → attachments → MIME → send (JSON or upload path)
│   │   └── AttachmentStore.swift       # on-disk cache Caches/attachments/<msg>/<part>
│   ├── Features/
│   │   ├── SignIn/SignInScreen.swift
│   │   ├── Inbox/
│   │   │   ├── MailFilter.swift        # enum + title + SQL binding
│   │   │   ├── MailListScreen.swift
│   │   │   ├── MailListModel.swift     # ValueObservation → rows, paging, actions
│   │   │   ├── ThreadRowView.swift
│   │   │   ├── ThreadRow.swift         # row projection (FetchableRecord)
│   │   │   ├── FilterMenu.swift        # title menu Inbox/Today/Label
│   │   │   ├── SyncStatusBar.swift
│   │   │   └── OutboxBanner.swift
│   │   ├── Thread/
│   │   │   ├── ThreadScreen.swift
│   │   │   ├── ThreadModel.swift
│   │   │   ├── ThreadWebView.swift     # UIViewRepresentable
│   │   │   ├── WebViewPool.swift
│   │   │   ├── RuleLists.swift
│   │   │   ├── CIDSchemeHandler.swift
│   │   │   ├── LinkPolicy.swift
│   │   │   ├── WebBridge.swift         # WKScriptMessageHandler for header taps / load images / attachment taps
│   │   │   └── AttachmentPreview.swift # QuickLook
│   │   ├── Compose/
│   │   │   ├── ComposeScreen.swift
│   │   │   ├── ComposeModel.swift
│   │   │   ├── RecipientsView.swift
│   │   │   └── QuotePreviewView.swift  # read-only WKWebView of the quoted original (pooled instance #2)
│   │   ├── Labels/
│   │   │   ├── LabelsSheet.swift
│   │   │   ├── LabelsModel.swift
│   │   │   └── LabelChip.swift
│   │   └── Settings/
│   │       ├── SettingsScreen.swift
│   │       ├── SignatureEditorScreen.swift
│   │       ├── ComposeStyleScreen.swift
│   │       ├── ThemePickerScreen.swift
│   │       └── AccountSection.swift
│   ├── Theme/
│   │   ├── Theme.swift                 # Theme, Palette, ThemeMode
│   │   ├── BuiltInThemes.swift         # system, light, dark
│   │   ├── ThemeStore.swift            # @Observable
│   │   └── ThemeEnvironment.swift      # EnvironmentKey + View helpers
│   ├── Settings/
│   │   ├── Preferences.swift           # Codable struct (§11)
│   │   └── PreferencesStore.swift      # @Observable, UserDefaults JSON
│   └── Support/
│       ├── Log.swift                   # os.Logger categories
│       ├── Signposts.swift
│       ├── DateLabel.swift             # cached formatters for list rows
│       ├── Haptics.swift
│       ├── SafariView.swift
│       └── LowPower.swift              # Low Power / Low Data checks
├── minimailTests/
│   ├── TestSupport/InMemoryDatabase.swift
│   ├── TestSupport/StubTransport.swift
│   ├── TestSupport/Fixtures.swift      # loads JSON from the core package fixtures
│   ├── Store/MigrationsTests.swift
│   ├── Store/ThreadListQueryTests.swift
│   ├── Store/IngestorTests.swift
│   ├── Sync/InitialSyncTests.swift
│   ├── Sync/DeltaSyncTests.swift
│   ├── Sync/ResyncTests.swift
│   ├── Outbox/OutboxCoalescerTests.swift
│   ├── Outbox/OutboxWorkerTests.swift
│   ├── Gmail/BatchRequestTests.swift
│   ├── Gmail/BatchResponseTests.swift
│   ├── Gmail/GmailErrorTests.swift
│   ├── Auth/KeychainTests.swift
│   ├── Theme/ThemeTests.swift
│   ├── Settings/PreferencesTests.swift
│   ├── Snapshots/ThreadRowSnapshotTests.swift
│   └── __Snapshots__/…
└── minimailUITests/
    └── SmokeTests.swift                # one launch → seeded inbox → Unread toggle
```

### 1.4 `project.yml` deltas vs. `[tooling §1.4]`

Use the research file's `project.yml` verbatim with these changes:

```yaml
configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig
# add:
include: []
packages:
  AppAuth:        { url: https://github.com/openid/AppAuth-iOS,             exactVersion: 3.0.0 }
  GRDB:           { url: https://github.com/groue/GRDB.swift,               exactVersion: 7.11.1 }
  SnapshotTesting:{ url: https://github.com/pointfreeco/swift-snapshot-testing, exactVersion: 1.19.4 }
  MinimailCore:   { path: Packages/MinimailCore }
targets:
  minimail:
    dependencies:
      - package: AppAuth
        product: AppAuth
      - package: GRDB
        product: GRDB
      - package: MinimailCore
        product: MinimailCore
    settings:
      base:
        # Google.xcconfig provides GOOGLE_CLIENT_ID; both keys below are substituted at build time
        INFOPLIST_KEY_MinimailGoogleClientID: $(GOOGLE_CLIENT_ID)
    info:
      properties:
        MinimailGoogleClientID: $(GOOGLE_CLIENT_ID)
        CFBundleURLTypes:
          - CFBundleTypeRole: Editor
            CFBundleURLName: com.minimail.oauth
            CFBundleURLSchemes:
              - com.googleusercontent.apps.$(GOOGLE_CLIENT_ID)
        UILaunchScreen:
          UIColorName: LaunchBackground      # asset colour = theme background (light/dark) → no white flash
  minimailTests:
    dependencies:
      - target: minimail
      - package: SnapshotTesting
        product: SnapshotTesting
      - package: MinimailCore
        product: MinimailCore
```

`Config/Google.xcconfig` is `GOOGLE_CLIENT_ID = 1234567890-abcdefg` (the part before `.apps.googleusercontent.com`). The redirect URI is derived at runtime: `com.googleusercontent.apps.<id>:/oauth2redirect` `[gmail-api §OAuth 2.0 for iOS]`.

### 1.5 `Packages/MinimailCore/Package.swift`

```swift
// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "MinimailCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MinimailCore", targets: ["MinimailCore"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
    ],
    targets: [
        .target(
            name: "MinimailCore",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")],
            swiftSettings: [.swiftLanguageMode(.v6)]      // nonisolated default: pure, Sendable code
        ),
        .testTarget(
            name: "MinimailCoreTests",
            dependencies: ["MinimailCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

Rule: **nothing in `MinimailCore` imports UIKit, SwiftUI, WebKit, GRDB or AppAuth.** `swift test` must pass on Linux (`docker run --rm -v "$PWD":/src -w /src/Packages/MinimailCore swift:6.1 swift test`, image tag UNVERIFIED `[tooling §7.4]`). Foundation-on-Linux gotchas: use `Regex` literals / `NSRegularExpression` only where both platforms agree; avoid `CFStringConvertIANACharSetNameToEncoding` in core — `Charset.swift` uses a small hand-written IANA→`String.Encoding` table (utf-8, us-ascii, iso-8859-1/2/15, windows-1250/1252, koi8-r, shift_jis, euc-jp, iso-2022-jp, gb2312/gbk, big5) and falls back to UTF-8 then Latin-1.

### 1.6 Makefile targets (in addition to `[tooling §2.7]`)

```make
test-core:            # Linux or macOS, no simulator
	cd Packages/MinimailCore && swift test
perf-launch:          # XCTApplicationLaunchMetric via the UI test bundle, prints ms
	$(MAKE) test-one T=minimailUITests/SmokeTests/testColdLaunchMetric
```

---

## 2. Module map and public interfaces

### 2.1 Dependency direction

```
                 ┌──────────────────────────────────────────────────────────────┐
                 │  Features/* (SwiftUI screens + @Observable models)          │
                 └───────┬───────────────┬───────────────┬──────────────┬───────┘
                         │               │               │              │
                    Theme, Settings   Store (read)    Sync / Outbox   Auth
                         │               │               │              │
                         │               └──────┬────────┴──────────────┘
                         │                      │
                         │                Gmail (API client)
                         │                      │
                         └──────────────► MinimailCore ◄──────────────┘
                                          (DTOs, MIME, Compose, Sanitize, SyncLogic)
```

Rules: arrows point downward only. `MinimailCore` depends on nothing in the app. `Gmail` knows `MinimailCore` DTOs and `Auth.TokenProvider`. `Store` knows `MinimailCore` and GRDB. `Sync`/`Outbox` know `Gmail` + `Store`. Features know everything below but never `Gmail` directly (all network goes through `SyncEngine`/`OutboxWorker`). `App/AppContainer` wires it.

Concurrency model `[ios-platform §5.6]`: app default is `@MainActor`. Explicit actors: `GmailAPI`, `SyncEngine`, `OutboxWorker`, `AppAuthTokenProvider`, `AttachmentStore`. CPU-heavy pure functions in `MinimailCore` are `nonisolated` and are called from those actors (never from the main actor for anything > 1 ms).

### 2.2 `MinimailCore` public interface

```swift
// MARK: Base64URL.swift
public enum Base64URL {
    public static func encode(_ data: Data) -> String            // padded, single line (Google sample keeps '=')
    public static func decode(_ s: String) -> Data?              // accepts padded/unpadded, both alphabets
}

// MARK: DayBoundary.swift
public struct DayBoundary: Sendable, Equatable {
    public let startMs: Int64          // local midnight, epoch ms
    public let endMs: Int64            // next local midnight
    public init(containing date: Date, calendar: Calendar = .current)   // calendar.timeZone decides
    public static func today(calendar: Calendar = .current, now: Date = Date()) -> DayBoundary
    public func contains(internalDateMs: Int64) -> Bool
}

// MARK: GmailDTO (all Decodable, Sendable; uint64/int64 fields are String on the wire [gmail-api §Common facts])
public struct GmailMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    public let internalDate: String?          // epoch ms as string
    public let sizeEstimate: Int?
    public let payload: GmailMessagePart?
    public let raw: String?
    public var internalDateMs: Int64? { internalDate.flatMap(Int64.init) }
    public var historyIdValue: UInt64? { historyId.flatMap(UInt64.init) }
}
public struct GmailMessagePart: Decodable, Sendable {
    public let partId: String?
    public let mimeType: String?
    public let filename: String?
    public let headers: [GmailHeader]?
    public let body: GmailMessagePartBody?
    public let parts: [GmailMessagePart]?
    public func header(_ name: String) -> String?   // case-insensitive, first match
}
public struct GmailHeader: Decodable, Sendable { public let name: String; public let value: String }
public struct GmailMessagePartBody: Decodable, Sendable {
    public let attachmentId: String?
    public let size: Int?
    public let data: String?
}
public struct GmailThread: Decodable, Sendable {
    public let id: String; public let historyId: String?; public let snippet: String?
    public let messages: [GmailMessage]?
}
public struct GmailLabel: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case system, user }
    public enum MessageListVisibility: String, Decodable, Sendable { case show, hide }
    public enum LabelListVisibility: String, Decodable, Sendable { case labelShow, labelShowIfUnread, labelHide }
    public struct Color: Decodable, Sendable { public let textColor: String?; public let backgroundColor: String? }
    public let id: String; public let name: String; public let type: Kind?
    public let messageListVisibility: MessageListVisibility?
    public let labelListVisibility: LabelListVisibility?
    public let messagesTotal: Int?; public let messagesUnread: Int?
    public let threadsTotal: Int?;  public let threadsUnread: Int?
    public let color: Color?
}
public struct GmailHistoryRecord: Decodable, Sendable {
    public struct MessageRef: Decodable, Sendable { public let message: GmailMessage }
    public struct LabelChange: Decodable, Sendable { public let message: GmailMessage; public let labelIds: [String] }
    public let id: String
    public let messagesAdded: [MessageRef]?
    public let messagesDeleted: [MessageRef]?
    public let labelsAdded: [LabelChange]?
    public let labelsRemoved: [LabelChange]?
}
public struct GmailListHistoryResponse: Decodable, Sendable {
    public let history: [GmailHistoryRecord]?; public let nextPageToken: String?; public let historyId: String?
}
public struct GmailListMessagesResponse: Decodable, Sendable {
    public struct Ref: Decodable, Sendable { public let id: String; public let threadId: String }
    public let messages: [Ref]?; public let nextPageToken: String?; public let resultSizeEstimate: Int?
}
public struct GmailListThreadsResponse: Decodable, Sendable {
    public struct Ref: Decodable, Sendable { public let id: String; public let snippet: String?; public let historyId: String? }
    public let threads: [Ref]?; public let nextPageToken: String?
}
public struct GmailListLabelsResponse: Decodable, Sendable { public let labels: [GmailLabel]? }
public struct GmailProfile: Decodable, Sendable {
    public let emailAddress: String; public let historyId: String?
    public let messagesTotal: Int?; public let threadsTotal: Int?
}
public struct GmailSendAs: Decodable, Sendable {
    public let sendAsEmail: String; public let displayName: String?; public let replyToAddress: String?
    public let signature: String?; public let isPrimary: Bool?; public let isDefault: Bool?
}
public struct GmailListSendAsResponse: Decodable, Sendable { public let sendAs: [GmailSendAs]? }
public struct GmailModifyRequest: Encodable, Sendable { public var addLabelIds: [String]?; public var removeLabelIds: [String]? }
public struct GmailBatchModifyRequest: Encodable, Sendable { public var ids: [String]; public var addLabelIds: [String]?; public var removeLabelIds: [String]? }
public struct GmailSendRequest: Encodable, Sendable { public var raw: String; public var threadId: String? }
public struct GmailErrorEnvelope: Decodable, Sendable {
    public struct Inner: Decodable, Sendable {
        public struct Item: Decodable, Sendable { public let reason: String?; public let message: String?; public let domain: String? }
        public let code: Int?; public let message: String?; public let status: String?; public let errors: [Item]?
    }
    public let error: Inner
    public var reason: String? { error.errors?.first?.reason }
}

// MARK: MIME/Mailbox.swift
public struct Mailbox: Sendable, Hashable, Codable {
    public var name: String?           // RFC 2047-decoded display name
    public var addr: String            // addr-spec, original case
    public init(name: String?, addr: String)
    public var key: String { addr.lowercased() }
    public var displayName: String      // name ?? local-part
    public func headerValue() -> String // `name <addr>` with quoting / RFC 2047-B [mime-rfc §2.2]
}
public enum AddressParser {
    public static func parse(_ headerValue: String) -> [Mailbox]      // tolerant, never throws
}
public enum RFC2047 {
    public static func decode(_ header: String) -> String
    public static func encodeIfNeeded(_ text: String) -> String       // ASCII passthrough else B-words ≤ 75 chars
}
public enum RFC2231 { public static func parameter(_ name: String, in headerValue: String) -> String? }
public struct ContentType: Sendable { public let type: String; public let subtype: String; public let params: [String: String]
    public init?(parsing headerValue: String); public var mime: String { "\(type)/\(subtype)" } }
public enum QuotedPrintable {
    public static func encode(_ utf8: Data) -> String                 // CRLF preserved, 76-col soft breaks
    public static func decode(_ s: String) -> Data
}
public enum HeaderEncoding {
    public static func fold(_ name: String, _ value: String) -> String  // "Name: value" folded ≤ 78, CRLF SP
    public static func mailboxList(_ list: [Mailbox]) -> String
}
public enum DateHeader {
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String   // "Fri, 11 Sep 2026 10:00:00 +0200"
    public static func parse(_ s: String) -> Date?                                     // tolerant of obsolete forms
    public static func attribution(_ date: Date, timeZone: TimeZone = .current) -> String // "Thu, Sep 10, 2026 at 9:12\u{202F}AM"
}
public enum MessageID {
    public static func make(domain: String, uuid: UUID = UUID()) -> String           // "<UUID@domain>"
    public static func referencesChain(parentReferences: [String], parentInReplyTo: [String], parentMessageID: String?) -> [String]
    public static func split(_ headerValue: String) -> [String]                       // "<a> <b>" → ["<a>","<b>"]
}

// MARK: MIME/MIMEPart.swift + MIMEBuilder.swift
public struct AttachmentPart: Sendable {
    public var filename: String; public var mimeType: String; public var data: Data
    public init(filename: String, mimeType: String, data: Data)
}
public struct OutgoingMessage: Sendable {
    public var from: Mailbox
    public var to: [Mailbox]; public var cc: [Mailbox]
    public var subject: String
    public var date: Date
    public var messageID: String                     // "<...>"
    public var inReplyTo: String?
    public var references: [String]
    public var textBody: String                      // full text/plain alternative (LF line endings; builder converts)
    public var htmlBody: String                      // full HTML fragment (no <html>); builder wraps
    public var attachments: [AttachmentPart]
    public var timeZone: TimeZone
}
public struct BoundarySource: Sendable { public var next: @Sendable (String) -> String }   // kind → boundary; deterministic in tests
public enum MIMEBuilder {
    public static func build(_ m: OutgoingMessage, boundaries: BoundarySource = .random) -> Data   // CRLF RFC 5322 bytes
    public static func rawForJSON(_ bytes: Data) -> String                                       // Base64URL.encode
}

// MARK: MIME/PayloadParser.swift
public struct ParsedAttachment: Sendable, Equatable {
    public let partId: String; public let filename: String; public let mimeType: String; public let size: Int
    public let contentId: String?          // without <>
    public let attachmentId: String?       // may be nil if data inline
    public let inlineData: Data?           // small parts delivered in `data`
    public let isInline: Bool              // referenced by cid: from the HTML or disposition inline
}
public struct ParsedPayload: Sendable {
    public var html: String?               // decoded, charset-honoured
    public var text: String?
    public var attachments: [ParsedAttachment]
    public var deferredTextParts: [(partId: String, attachmentId: String, mimeType: String, charset: String?)] // large bodies by attachmentId
    public var headers: ParsedHeaders
}
public struct ParsedHeaders: Sendable {
    public var from: Mailbox?; public var to: [Mailbox]; public var cc: [Mailbox]; public var replyTo: [Mailbox]
    public var subject: String; public var date: Date?; public var messageID: String?
    public var inReplyTo: [String]; public var references: [String]
    public var listUnsubscribe: String?
}
public enum PayloadParser {
    public static func headers(_ payload: GmailMessagePart) -> ParsedHeaders
    public static func parse(_ payload: GmailMessagePart) -> ParsedPayload       // walk [mime-rfc §5.2]
}
public enum Charset { public static func decode(_ data: Data, charset: String?) -> String }

// MARK: Compose
public struct ComposeStyle: Codable, Equatable, Sendable {
    public enum Family: String, Codable, CaseIterable, Identifiable, Sendable { case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        public var id: String { rawValue }; public var css: String; public var displayName: String }
    public var family: Family = .helvetica
    public var sizePx: Int = 14                       // 12…18
    public var colorHex: String = "#000000"           // ^#[0-9a-f]{6}$
    public var inlineCSS: String
    public init()
}
public struct SelfIdentity: Sendable {
    public var primary: Mailbox                       // From: for outgoing
    public var allAddresses: Set<String>              // lowercased: profile + sendAs
    public init(primary: Mailbox, aliases: [String])
}
public enum ReplyAllResolver {
    public struct Result: Sendable, Equatable { public var to: [Mailbox]; public var cc: [Mailbox] }
    public static func resolve(from: Mailbox?, replyTo: [Mailbox], to: [Mailbox], cc: [Mailbox], me: SelfIdentity) -> Result
}
public enum SubjectPrefix {
    public static func reply(_ subject: String) -> String        // "Re: " unless hasPrefix("re:") ci
    public static func forward(_ subject: String) -> String      // "Fwd: " unless hasPrefix("fwd:") ci
    public static func stripped(_ subject: String) -> String     // display only: strip leading Re:/Fwd:/AW:/WG: chains
}
public struct QuotedOriginal: Sendable {
    public var from: Mailbox?; public var to: [Mailbox]; public var cc: [Mailbox]
    public var date: Date; public var subject: String
    public var html: String                  // sanitized fragment from the cache, remote src restored, cid: restored
    public var text: String?                 // plain alternative if cached, else derived from html
}
public enum Quoting {
    public static func replyHTML(_ o: QuotedOriginal, timeZone: TimeZone) -> String     // gmail_quote_container markup [mime-rfc §4.1]
    public static func replyText(_ o: QuotedOriginal, timeZone: TimeZone) -> String     // "On … wrote:" + "> " lines
    public static func forwardHTML(_ o: QuotedOriginal, timeZone: TimeZone) -> String   // banner block [mime-rfc §4.2]
    public static func forwardText(_ o: QuotedOriginal, timeZone: TimeZone) -> String
}
public enum OutgoingHTML {
    public static func body(text: String, style: ComposeStyle, signatureHTML: String?, quoteHTML: String?) -> String
}
public enum OutgoingText {
    public static func body(text: String, signatureText: String?, quoteText: String?) -> String
    public static func signatureText(fromHTML: String) -> String   // tags stripped, <br>/<div> → newline
}
public enum ComposeKind: String, Codable, Sendable { case replyAll, forward }
public struct ComposeDraft: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: ComposeKind
    public var originalMessageId: String            // Gmail id
    public var threadId: String
    public var to: [Mailbox]; public var cc: [Mailbox]
    public var subject: String
    public var bodyText: String                     // what the user typed
    public var includeAttachments: Bool             // forward only
    public var attachmentPartIds: [String]          // forward: which original parts to carry
    public var messageID: String                    // generated at draft creation; idempotency key
    public var inReplyTo: String?; public var references: [String]
    public var createdAt: Date
}

// MARK: Sanitize
public enum DarkStrategy: String, Codable, Sendable { case plain, card, native }
public struct SanitizedBody: Sendable, Equatable {
    public var html: String; public var hasRemoteImages: Bool; public var darkStrategy: DarkStrategy
    public var referencedCIDs: [String]
}
public enum Sanitizer {
    public static let version: Int                                   // bump → re-sanitize lazily
    public static let maxInputBytes: Int                             // 2 MiB; larger → plain text fallback
    public static func sanitize(html: String, gmailMessageId: String) throws -> SanitizedBody
    public static func sanitizeSignature(html: String) throws -> String   // keeps https img src, no placeholders
}
public enum PlainTextToHTML { public static func convert(_ text: String) -> String }   // escape + linkify + <div> lines
public struct ThreadDocumentMessage: Sendable {
    public var id: String; public var fromName: String; public var fromAddr: String
    public var toSummary: String; public var dateLabel: String; public var dateFull: String
    public var isUnread: Bool; public var isExpanded: Bool
    public var bodyHTML: String?; public var darkStrategy: DarkStrategy; public var hasRemoteImages: Bool; public var imagesLoaded: Bool
    public var attachments: [(partId: String, filename: String, sizeLabel: String, icon: String)]
    public var snippet: String
}
public struct ThreadDocumentTheme: Sendable {   // CSS custom properties, hex strings
    public var bg: String; public var surface: String; public var text: String; public var secondaryText: String
    public var accent: String; public var separator: String; public var unread: String; public var cardBg: String
    public var colorScheme: String            // "light dark" | "light" | "dark"
}
public enum ThreadDocument {
    public static func render(subject: String, messages: [ThreadDocumentMessage], theme: ThreadDocumentTheme, allowRemoteImages: Bool) -> String
    public static func empty(theme: ThreadDocumentTheme) -> String   // warm-up document
}

// MARK: SyncLogic
public struct LabelSet: Sendable, Equatable, Codable {
    public private(set) var ids: [String]           // ordered, unique
    public init(_ ids: [String])
    public var isUnread: Bool { contains("UNREAD") }; public var inInbox: Bool { contains("INBOX") }
    public var isHidden: Bool { contains("TRASH") || contains("SPAM") }
    public func contains(_ id: String) -> Bool
    public mutating func apply(add: [String], remove: [String])
    public var userVisible: [String]                // excludes UNREAD/INBOX/SENT/DRAFT/CATEGORY_*/IMPORTANT/STARRED/CHAT/TRASH/SPAM
}
public struct HistoryDelta: Sendable, Equatable {
    public var added: [String: (threadId: String, labels: LabelSet?)]   // messageId → …
    public var deleted: Set<String>
    public var labelChanges: [String: (add: [String], remove: [String], threadId: String, finalLabels: LabelSet?)]
    public var latestHistoryId: UInt64?
    public static func reduce(_ records: [GmailHistoryRecord]) -> HistoryDelta     // in order; later records win
}
public struct MessageSummary: Sendable {  // input for ThreadSummary
    public var id: String; public var internalDateMs: Int64; public var labels: LabelSet
    public var fromName: String; public var fromAddr: String; public var subject: String; public var snippet: String
    public var hasAttachments: Bool; public var isFromMe: Bool
}
public struct ThreadSummary: Sendable, Equatable {
    public var lastDateMs: Int64; public var lastInboxDateMs: Int64?; public var subject: String; public var snippet: String
    public var lastFromName: String; public var participants: String; public var messageCount: Int; public var unreadCount: Int
    public var inInbox: Bool; public var hidden: Bool; public var hasAttachments: Bool; public var labelIds: [String]
    public static func make(_ messages: [MessageSummary], me: Set<String>) -> ThreadSummary
}
```

### 2.3 App-target interfaces

```swift
// MARK: Auth
public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String              // fresh; refreshes if needed; single-flight
    func invalidateAccessToken() async                     // after a 401
    var isSignedIn: Bool { get async }
}
actor AppAuthTokenProvider: TokenProvider {
    init(keychain: Keychain, config: OAuthConfig)
    func restore() async -> Bool                           // load OIDAuthState from Keychain (off main)
    func store(_ state: OIDAuthState) async throws
    func signOut(revoke: Bool) async                       // revoke refresh token (best effort), delete Keychain item
}
@MainActor @Observable final class AuthStore {
    enum State: Equatable { case unknown, signedOut, signedIn(email: String), signingIn, needsReauth(reason: String) }
    private(set) var state: State
    var currentFlow: OIDExternalUserAgentSession?          // for onOpenURL fallback
    init(tokens: AppAuthTokenProvider, db: AppDatabase, config: OAuthConfig)
    func restoreSession() async                            // called after first frame
    func signIn(presenting: UIViewController) async throws
    func resume(url: URL) -> Bool
    func signOut() async                                   // revoke, wipe Keychain + DB + caches; keep theme prefs
    func handleAuthFailure(_ error: GmailError)            // 401 twice / invalid_grant → .needsReauth
}
struct OAuthConfig: Sendable {
    let clientID: String                                   // "<prefix>.apps.googleusercontent.com"
    let redirectURL: URL                                   // com.googleusercontent.apps.<prefix>:/oauth2redirect
    let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    let scopes = ["https://www.googleapis.com/auth/gmail.modify"]
    static func fromInfoPlist() -> OAuthConfig
}
enum Keychain {   // [ios-platform §5.5]
    static func set(_ data: Data, account: String) throws
    static func get(account: String) throws -> Data?
    static func delete(account: String) throws
}

// MARK: Gmail
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct URLSessionTransport: HTTPTransport { init(session: URLSession = .minimail) }
enum GmailEndpoint {  // pure descriptions, no auth
    case profile
    case listMessages(labelIds: [String], q: String?, maxResults: Int, pageToken: String?)
    case getMessage(id: String, format: MessageFormat, metadataHeaders: [String], fields: String?)
    case getThread(id: String, format: MessageFormat, metadataHeaders: [String], fields: String?)
    case getAttachment(messageId: String, id: String)
    case modifyMessage(id: String, GmailModifyRequest)
    case modifyThread(id: String, GmailModifyRequest)
    case batchModify(GmailBatchModifyRequest)
    case listLabels
    case getLabel(id: String)
    case listHistory(startHistoryId: UInt64, pageToken: String?, maxResults: Int)
    case send(GmailSendRequest)
    case sendUpload(rfc822: Data, threadId: String?)        // multipart/related upload path
    case listSendAs
    enum MessageFormat: String { case minimal, metadata, full, raw }
    var method: String; var path: String; var query: [URLQueryItem]; var body: Data?; var contentType: String?
    func urlRequest(base: URL) -> URLRequest                // adds prettyPrint=false
}
actor GmailAPI {
    init(transport: HTTPTransport, tokens: TokenProvider, limiter: RequestLimiter = .init(max: 2), log: Logger)
    func call<T: Decodable>(_ endpoint: GmailEndpoint, as: T.Type) async throws -> T
    func callEmpty(_ endpoint: GmailEndpoint) async throws                       // 204 endpoints
    func batch(_ endpoints: [GmailEndpoint]) async throws -> [BatchResult]       // ≤ 50 per HTTP request; chunks automatically
    // Typed conveniences used by Sync/Outbox:
    func profile() async throws -> GmailProfile
    func listInboxMessageIds(unreadOnly: Bool, max: Int, pageToken: String? = nil) async throws -> (refs: [(id: String, threadId: String)], nextPageToken: String?)
    func getMessages(ids: [String], format: GmailEndpoint.MessageFormat) async throws -> [String: Result<GmailMessage, GmailError>]
    func getThreads(ids: [String], format: GmailEndpoint.MessageFormat) async throws -> [String: Result<GmailThread, GmailError>]
    func history(since: UInt64) async throws -> (records: [GmailHistoryRecord], newHistoryId: UInt64)   // pages internally
    func labels() async throws -> [GmailLabel]
    func labelsWithCounts(ids: [String]) async throws -> [GmailLabel]
    func attachment(messageId: String, id: String) async throws -> Data
    func modify(threadId: String, add: [String], remove: [String]) async throws
    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws
    func send(raw: Data, threadId: String?) async throws -> (id: String, threadId: String)
    func findByRFC822MessageID(_ id: String) async throws -> String?             // messages.list?q=rfc822msgid:
}
struct BatchResult: Sendable { let contentID: String; let status: Int; let headers: [String: String]; let body: Data }
enum BatchRequest {
    static func build(_ parts: [(id: String, request: URLRequest)], boundary: String) -> (body: Data, contentType: String)
}
enum BatchResponse { static func parse(_ data: Data, contentType: String) throws -> [BatchResult] }
struct RequestLimiter: Sendable { init(max: Int); func withPermit<T>(_ op: () async throws -> T) async throws -> T }
enum Backoff { static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval }  // 1,2,4,…,32 s + jitter

// MARK: Store
final class AppDatabase: Sendable {
    let pool: DatabasePool
    static func open(directory: URL = AppDatabase.defaultDirectory) throws -> AppDatabase   // creates dir, migrates
    static func inMemory() throws -> AppDatabase                                            // tests (DatabaseQueue-backed wrapper)
    static var defaultDirectory: URL                                                        // AppSupport/minimail-db/
    func wipe() throws                                                                      // sign-out
}
// Records: Codable + FetchableRecord + PersistableRecord structs mirroring §3 (snake_case columns via CodingKeys)
struct ThreadRow: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {   // list projection
    var id: String; var subject: String; var snippet: String; var lastFromName: String; var participants: String
    var lastDateMs: Int64; var unreadCount: Int; var messageCount: Int; var hasAttachments: Bool; var labelIds: [String]
}
enum ThreadListQuery {
    static func request(filter: MailFilter, unreadOnly: Bool, today: DayBoundary, limit: Int) -> SQLRequest<ThreadRow>
}
enum ThreadDetailQuery {
    struct Detail: Sendable { var thread: ThreadRecord; var messages: [MessageRecord]; var bodies: [String: MessageBodyRecord]; var attachments: [AttachmentRecord] }
    static func fetch(_ db: Database, threadId: String) throws -> Detail?
}
struct MessageIngestor {    // used by Sync; runs inside pool.write
    init(sanitizerVersion: Int, me: Set<String>)
    func ingest(_ db: Database, messages: [GmailMessage], full: Bool) throws -> Set<String>   // returns touched thread ids
    func applyLabelDelta(_ db: Database, messageId: String, add: [String], remove: [String]) throws -> String?  // thread id
    func delete(_ db: Database, messageIds: [String]) throws -> Set<String>
}
enum ThreadAggregator { static func recompute(_ db: Database, threadIds: Set<String>, me: Set<String>) throws }

// MARK: Sync
@MainActor @Observable final class SyncStatus {
    enum Phase: Equatable { case idle, syncing, offline, error(String), needsReauth }
    var phase: Phase; var lastSyncAt: Date?; var pendingOutboxCount: Int; var failedOutboxCount: Int
}
actor SyncEngine {
    init(api: GmailAPI, db: AppDatabase, outbox: OutboxWorker, prefs: PreferencesSnapshotProvider, status: SyncStatus)
    func syncNow(reason: SyncReason) async              // foreground/pull/BG; serialised; coalesces concurrent callers
    func ensureThreadLoaded(threadId: String) async throws // open path: fetch missing bodies (threads.get full) if needed
    func loadImages(messageId: String) async             // marks images allowed; nothing to fetch (web view loads them)
    func resolveAttachment(messageId: String, partId: String) async throws -> URL   // download → temp file
    func inlineImage(messageId: String, contentId: String) async throws -> (Data, String)
    func refreshLabelCounts(force: Bool) async
    func loadOlderInbox() async throws -> Bool           // next messages.list page (sync_state.inbox_next_page) + metadata batch; false = no more
    enum SyncReason: Sendable { case launch, foreground, pullToRefresh, background, afterSend }
}

// MARK: Outbox
enum OutboxOp: Codable, Sendable, Equatable {
    case modify(ModifyOp)
    case send(SendOp)
    struct ModifyOp: Codable, Sendable, Equatable {
        enum Scope: String, Codable, Sendable { case thread, messages }
        var scope: Scope; var ids: [String]; var add: [String]; var remove: [String]
    }
    struct SendOp: Codable, Sendable, Equatable { var draft: ComposeDraft; var transmitted: Bool }
}
actor OutboxWorker {
    init(api: GmailAPI, db: AppDatabase, attachments: AttachmentStore, status: SyncStatus, me: () async -> SelfIdentity?)
    func enqueue(_ op: OutboxOp) async                  // writes row, applies nothing (caller already mutated DB)
    func kick() async                                   // start drain if idle (debounced 300 ms for modify ops)
    func retryFailed() async
    func discard(id: String) async
}
enum OutboxCoalescer {
    static func coalesce(_ pending: [OutboxRecord]) -> [OutboxRecord]   // merges modify ops, preserves order of sends
}
struct SendPipeline {
    func prepare(_ draft: ComposeDraft, me: SelfIdentity, style: ComposeStyle, signatureHTML: String?, db: AppDatabase, attachments: AttachmentStore, api: GmailAPI) async throws -> OutgoingMessage
}
actor AttachmentStore {
    init(directory: URL = Caches/attachments)
    func cached(messageId: String, partId: String) -> URL?
    func store(_ data: Data, messageId: String, partId: String, filename: String) throws -> URL
    func purge(olderThan: TimeInterval)
}

// MARK: Theme / Settings (see §10, §11)
```

---

## 3. Data model (SQLite via GRDB)

### 3.1 Principles

1. **The list never joins.** `thread` is a denormalised projection; the list query touches one table and one covering index.
2. **Hot rows are small.** Bodies (`message_body`) and MIME trees are in separate tables so scanning `message`/`thread` pages stays cheap.
3. **Local truth for labels.** `message.label_ids` is the app's view (server state ⊕ optimistic ops). Thread flags are recomputed from messages by `ThreadAggregator` in the same write transaction.
4. All integers that come from Gmail as strings (`historyId`, `internalDate`) are stored as `INTEGER` (SQLite 64-bit).
5. Booleans are `INTEGER 0/1`; JSON columns are `TEXT` with `.sortedKeys` `[ios-platform §2.4]`.

### 3.2 Schema (migration `v1`, executed via `db.execute(sql:)` verbatim)

```sql
PRAGMA journal_mode = WAL;          -- set by DatabasePool automatically; listed for clarity
PRAGMA foreign_keys = ON;           -- GRDB enables per connection

CREATE TABLE sync_state (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;
-- keys: 'history_id' (uint64 as text), 'last_full_sync_at' (epoch s), 'last_delta_sync_at',
--       'profile_email', 'profile_display_name', 'self_addresses' (JSON [String]),
--       'send_as_signature' (raw HTML from sendAs, import source only), 'label_counts_at',
--       'initial_sync_done' ('1'), 'prefetch_done_history_id',
--       'inbox_next_page' (pageToken of messages.list for the "Load older" footer; NULL/absent = no more pages)

CREATE TABLE label (
  id                       TEXT PRIMARY KEY NOT NULL,
  name                     TEXT NOT NULL,
  type                     TEXT NOT NULL,                  -- 'system' | 'user'
  message_list_visibility  TEXT,                           -- 'show' | 'hide'
  label_list_visibility    TEXT,                           -- 'labelShow' | 'labelShowIfUnread' | 'labelHide'
  text_color               TEXT,                           -- '#rrggbb' (user labels)
  background_color         TEXT,
  messages_unread          INTEGER NOT NULL DEFAULT 0,
  threads_unread           INTEGER NOT NULL DEFAULT 0,
  messages_total           INTEGER NOT NULL DEFAULT 0,
  threads_total            INTEGER NOT NULL DEFAULT 0,
  counts_updated_at        INTEGER,                        -- epoch s; NULL = never fetched
  sort_order               INTEGER NOT NULL DEFAULT 0      -- system first (fixed order), then user by name
) WITHOUT ROWID;

CREATE TABLE thread (
  id                 TEXT PRIMARY KEY NOT NULL,
  history_id         INTEGER NOT NULL DEFAULT 0,
  subject            TEXT NOT NULL DEFAULT '',            -- of the OLDEST cached message, Re:/Fwd: stripped for display
  snippet            TEXT NOT NULL DEFAULT '',            -- of the NEWEST cached message
  last_from_name     TEXT NOT NULL DEFAULT '',            -- newest message sender display ("Me" if from self)
  participants       TEXT NOT NULL DEFAULT '',            -- "Alice, Bob, Me" (max 3 names + "…")
  last_date          INTEGER NOT NULL,                    -- max(internal_date) ms over cached messages
  last_inbox_date    INTEGER,                             -- max(internal_date) over messages with INBOX; NULL if none
  message_count      INTEGER NOT NULL DEFAULT 0,
  unread_count       INTEGER NOT NULL DEFAULT 0,
  in_inbox           INTEGER NOT NULL DEFAULT 0,          -- any message has INBOX
  hidden             INTEGER NOT NULL DEFAULT 0,          -- every message is TRASH/SPAM
  has_attachments    INTEGER NOT NULL DEFAULT 0,
  label_ids          TEXT NOT NULL DEFAULT '[]',          -- JSON: union of user-visible labels across messages (chips)
  is_complete        INTEGER NOT NULL DEFAULT 0,          -- 1 after a threads.get?format=full was ingested
  bodies_missing     INTEGER NOT NULL DEFAULT 0           -- count of messages with body_state = 0 (cheap "needs network?" check)
) WITHOUT ROWID;

-- Covering indexes for the four list queries (§8.6). Partial: hidden rows never enter them.
CREATE INDEX thread_inbox_date   ON thread(last_date DESC)               WHERE in_inbox = 1 AND hidden = 0;
CREATE INDEX thread_inbox_unread ON thread(last_date DESC)               WHERE in_inbox = 1 AND hidden = 0 AND unread_count > 0;
CREATE INDEX thread_inbox_today  ON thread(last_inbox_date DESC)         WHERE in_inbox = 1 AND hidden = 0;
CREATE INDEX thread_all_date     ON thread(last_date DESC)               WHERE hidden = 0;

CREATE TABLE thread_label (                                 -- junction for label-filtered lists
  label_id   TEXT NOT NULL,
  thread_id  TEXT NOT NULL,
  last_date  INTEGER NOT NULL,                              -- denormalised copy of thread.last_date
  unread     INTEGER NOT NULL DEFAULT 0,                    -- thread.unread_count > 0
  PRIMARY KEY (label_id, thread_id)
) WITHOUT ROWID;
CREATE INDEX thread_label_date ON thread_label(label_id, last_date DESC);

CREATE TABLE message (
  id               TEXT PRIMARY KEY NOT NULL,
  thread_id        TEXT NOT NULL,
  history_id       INTEGER NOT NULL DEFAULT 0,
  internal_date    INTEGER NOT NULL,                        -- epoch ms
  label_ids        TEXT NOT NULL DEFAULT '[]',              -- JSON array; LOCAL TRUTH (server ⊕ pending ops)
  is_unread        INTEGER NOT NULL DEFAULT 0,              -- derived from label_ids at write
  in_inbox         INTEGER NOT NULL DEFAULT 0,
  hidden           INTEGER NOT NULL DEFAULT 0,              -- TRASH or SPAM
  from_name        TEXT NOT NULL DEFAULT '',
  from_addr        TEXT NOT NULL DEFAULT '',
  is_from_me       INTEGER NOT NULL DEFAULT 0,
  to_json          TEXT NOT NULL DEFAULT '[]',              -- [{"name":"Alice","addr":"a@x"}]
  cc_json          TEXT NOT NULL DEFAULT '[]',
  reply_to_json    TEXT NOT NULL DEFAULT '[]',
  subject          TEXT NOT NULL DEFAULT '',                -- RFC 2047-decoded, prefix kept
  snippet          TEXT NOT NULL DEFAULT '',
  rfc_message_id   TEXT,                                    -- "<...>" as received
  in_reply_to      TEXT,                                    -- first msg-id
  references_json  TEXT NOT NULL DEFAULT '[]',              -- ["<a>","<b>"]
  size_estimate    INTEGER NOT NULL DEFAULT 0,
  has_attachments  INTEGER NOT NULL DEFAULT 0,
  body_state       INTEGER NOT NULL DEFAULT 0,              -- 0 none, 1 cached, 2 unavailable (404/parse fail)
  images_loaded    INTEGER NOT NULL DEFAULT 0,              -- user tapped "Load images" (per message, persistent)
  fetched_at       INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
CREATE INDEX message_thread_date ON message(thread_id, internal_date);
CREATE INDEX message_body_missing ON message(thread_id) WHERE body_state = 0;

CREATE TABLE message_body (
  message_id         TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  html               TEXT NOT NULL,                         -- sanitized fragment (text/plain mails converted)
  text               TEXT,                                  -- text/plain part if present (for quoting)
  has_remote_images  INTEGER NOT NULL DEFAULT 0,
  dark_strategy      TEXT NOT NULL DEFAULT 'plain',         -- 'plain' | 'card' | 'native'
  sanitizer_version  INTEGER NOT NULL,
  source_was_html    INTEGER NOT NULL DEFAULT 1
) WITHOUT ROWID;

CREATE TABLE attachment (
  message_id     TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  part_id        TEXT NOT NULL,
  filename       TEXT NOT NULL,
  mime_type      TEXT NOT NULL,
  size           INTEGER NOT NULL DEFAULT 0,
  content_id     TEXT,                                      -- without <>
  is_inline      INTEGER NOT NULL DEFAULT 0,                -- referenced by cid: from the HTML
  attachment_id  TEXT,                                      -- last seen; NOT a stable key, re-resolve on 404
  PRIMARY KEY (message_id, part_id)
) WITHOUT ROWID;

CREATE TABLE outbox (
  id               TEXT PRIMARY KEY NOT NULL,               -- UUID
  seq              INTEGER NOT NULL,                        -- monotonic (max+1) → execution order
  kind             TEXT NOT NULL,                           -- 'modify' | 'send'
  payload          TEXT NOT NULL,                           -- JSON OutboxOp
  state            TEXT NOT NULL DEFAULT 'pending',         -- 'pending' | 'inflight' | 'failed'
  attempts         INTEGER NOT NULL DEFAULT 0,
  next_attempt_at  INTEGER NOT NULL DEFAULT 0,              -- epoch s
  created_at       INTEGER NOT NULL,
  last_error       TEXT
) WITHOUT ROWID;
CREATE INDEX outbox_state_seq ON outbox(state, seq);
```

No FTS table in v1 (search is out of scope). Adding `message_ft` later is an additive migration `[ios-platform §2.7]`.

### 3.3 Gmail → column mapping

| Gmail field | Column | Transform |
|---|---|---|
| `Message.id` / `threadId` | `message.id`, `message.thread_id` | as-is |
| `Message.historyId` (string uint64) | `message.history_id` | `UInt64(...)` |
| `Message.internalDate` (string int64 ms) | `message.internal_date` | `Int64(...)` |
| `Message.labelIds[]` | `message.label_ids` (JSON) + `is_unread`, `in_inbox`, `hidden` | `LabelSet` |
| `Message.snippet` | `message.snippet`, `thread.snippet` (newest) | HTML entities decoded |
| `payload.headers` From/To/Cc/Reply-To | `from_name`, `from_addr`, `is_from_me`, `to_json`, `cc_json`, `reply_to_json` | `AddressParser` + `RFC2047` |
| `Subject` | `message.subject` (as decoded); `thread.subject` (oldest message, `SubjectPrefix.stripped`) | |
| `Message-ID`, `In-Reply-To`, `References` | `rfc_message_id`, `in_reply_to`, `references_json` | `MessageID.split` |
| `Date` header | not stored — `internal_date` is authoritative for ordering and display `[gmail-api §5]` | |
| `sizeEstimate` | `size_estimate` | |
| `payload` (full) | `message_body.html/text/…`, `attachment.*` | `PayloadParser` + `Sanitizer` |
| `MessagePartBody.attachmentId` | `attachment.attachment_id` (cache only) | re-resolved on 404 `[gmail-api §6]` |
| `Thread.historyId` | `thread.history_id` | |
| `Label.*` | `label.*` | `labels.list` fills identity/visibility; `labels.get` fills counts/colour `[gmail-api §10–11]` |
| `Profile.emailAddress`, `SendAs[*].sendAsEmail/displayName/signature` | `sync_state` | |
| `history.historyId` | `sync_state.history_id` | only after a complete, fully applied page set |

### 3.4 Not stored (deliberately)

- Raw HTML, `Message.raw`, unsanitised anything; attachment bytes (disk cache under `Caches/attachments/`, purgeable); full header lists; `Date` header; `resultSizeEstimate`; history records themselves; labels' palette validity; `CATEGORY_*`/`IMPORTANT`/`STARRED` as chips (kept inside `label_ids` for correctness only); messages outside INBOX unless their thread is cached; SPAM/TRASH threads (ingested only to flip `hidden`, then pruned by the nightly-on-launch cleanup); drafts; OAuth tokens (Keychain only); per-message read receipts / tracking state.

### 3.5 Retention & cleanup (runs once per launch, after the first sync, inside one write)

- Delete `thread` rows (cascade `message`, `message_body`, `attachment`, `thread_label`) where `hidden = 1` for more than 24 h, or `in_inbox = 0 AND last_date < now − 30 days` (archived threads the user opened — keep a month for back-navigation).
- Cap total cached bodies at 3,000 messages: delete oldest `message_body` rows beyond that and set `body_state = 0`, `bodies_missing` recomputed.
- `AttachmentStore.purge(olderThan: 7 days)`.
- `outbox` rows in `failed` older than 30 days → deleted (the user has been shown the banner for a month).

---

## 4. Sync engine

All algorithms run inside `actor SyncEngine`. Network via `GmailAPI`; writes via `db.pool.write { … }` in **one transaction per page/batch** so the list observation fires once per batch, not once per row. `Task.isCancelled` is checked between steps (BG refresh).

### 4.1 State machine

```
signedOut ──restore()──► idle
idle ──syncNow──► syncing ──ok──► idle
syncing ──401 twice / invalid_grant──► needsReauth
syncing ──offline / 5xx / 429 exhausted──► idle (status.phase = .offline / .error, retried next trigger)
```
`syncNow` is serialised: a second caller while syncing sets `rerunRequested = true` and returns; the running sync loops once more at the end.

Triggers (and only these): app launch (after first frame), `scenePhase → .active` if `lastSyncAt` older than 60 s, pull-to-refresh, BG app refresh, after a successful send (to ingest the SENT message into the thread). No timers.

### 4.2 Request budget per sync

| Step | Calls | Pessimistic units `[gmail-api §Quotas]` |
|---|---|---|
| Initial sync | `getProfile` (1) + `messages.list` (1) + 1 HTTP batch of ≤ 100 `messages.get?format=metadata` (1 request) + `labels.list` (1) + 1 batch `labels.get` (1) | 1 + 5 + 100×20 + 1 + n×1 ≈ 2,020 |
| Delta sync | `history.list` (1, paged only if > 500 records) + ≤ 1 batch (`messages.get` for added ids) + optional label counts batch | 2 + 20×added + n |
| Prefetch (idle) | 1 batch `threads.get?format=full` for ≤ 25 threads | 25×40 = 1,000 |
| Thread open (miss) | 1 `threads.get?format=full` or 1 batch `messages.get?format=full` | 40 / 20×k |

All well under 6,000 units/user/min; the initial sync + prefetch are deliberately spaced (prefetch starts ≥ 5 s after the initial batch completes) so they never share a minute window with > 4,000 units.

### 4.3 Initial sync (first launch after sign-in, or `sync_state.initial_sync_done` missing)

```
func initialSync():
    profile = api.profile()                                       // 1 RT — historyId BEFORE listing (safe: replay is idempotent)
    write: sync_state[profile_email] = profile.emailAddress; self_addresses = [email]
    (sendAs) = api.listSendAs()  — batched together with labels.list in ONE HTTP batch:
        batch = api.batch([.listLabels, .listSendAs])             // 1 RT
    write: label rows (identity/visibility, sort_order); self_addresses ∪= sendAs emails;
           sync_state[profile_display_name] = primary sendAs displayName; send_as_signature = primary.signature
    refs = api.listInboxMessageIds(unreadOnly: false, max: 100)   // 1 RT; ids + threadIds only; nextPageToken → sync_state[inbox_next_page]
    metas = api.getMessages(ids: refs.ids, format: .metadata,
                            metadataHeaders: [From,To,Cc,Reply-To,Subject,Date,Message-ID,In-Reply-To,References,List-Unsubscribe],
                            fields: "id,threadId,labelIds,snippet,historyId,internalDate,sizeEstimate,payload/headers,payload/mimeType,payload/parts/filename")   // 1–2 RT (≤ 50 per batch)
    write (single transaction):
        touched = ingestor.ingest(db, messages: metas.successes, full: false)
        ThreadAggregator.recompute(db, touched)
        sync_state[history_id] = profile.historyId
        sync_state[initial_sync_done] = "1"; last_full_sync_at = now
    labelCountsBatch = api.labelsWithCounts(ids: visibleUserLabelIds + ["INBOX"])   // 1 RT, may be skipped if Low Data
    write: label counts
    schedule: prefetchBodies() after 5 s idle (not on Low Power / Low Data / cellular-constrained)
```
`has_attachments` for metadata rows is inferred from `payload/parts/filename` being non-empty anywhere in the tree (the `fields` mask keeps the tree tiny: only filenames). Attachment rows are created only on the `full` ingest.

Why `messages.list` + `messages.get` rather than `threads.list` + `threads.get`: half the pessimistic quota, smaller payloads, and the metadata mask gives everything the list needs `[gmail-api §Gotchas 11]`.

### 4.4 Delta sync (`history.list`)

```
func deltaSync():
    start = sync_state[history_id] as UInt64  (missing → initialSync())
    do { (records, newId) = api.history(since: start) }         // pages of 500 internally; historyTypes = all four; no labelId filter [gmail-api §13]
    catch GmailError.historyExpired { return resync() }         // HTTP 404 / failedPrecondition
    delta = HistoryDelta.reduce(records)                        // pure; later records win per message
    // Decide which added messages we want:
    cachedThreads = db.read { thread ids ∩ delta.added.threadIds }
    wanted = delta.added.filter { $0.labels?.inInbox == true || cachedThreads.contains($0.threadId) }
    fullIds   = wanted where (threadIsComplete || wanted.count ≤ 50)        // few adds → fetch bodies now
    metaIds   = wanted − fullIds
    fetched = api.getMessages(ids: fullIds, format: .full) ∪ api.getMessages(ids: metaIds, format: .metadata)   // ≤ 1–2 RT, 404s dropped silently
    write (single transaction):
        touched = ingestor.ingest(db, messages: fetched.successes, full: perId)
        for (id, ch) in delta.labelChanges where message exists locally:
            if let final = ch.finalLabels { set label_ids = final }            // sync guide says current labelIds are included (UNVERIFIED) …
            else { applyLabelDelta(add: ch.add, remove: ch.remove) }           // … otherwise apply the delta
            touched ∪= threadId
        touched ∪= ingestor.delete(db, delta.deleted ∩ local)
        reapplyPendingOutboxDeltas(db, messageIdsIn: touched)                 // §4.8 conflict rule
        ThreadAggregator.recompute(db, touched)
        sync_state[history_id] = newId; last_delta_sync_at = now
    if touched contains any thread with in_inbox change or unread change: refreshLabelCounts(force: false)   // ≤ 1 RT, throttled to once / 5 min
    prefetchBodies(for: touched threads in inbox, limit: 10)                                                    // only foreground, not Low Power
```
Messages added with `TRASH`/`SPAM` and no cached thread are ignored entirely. Messages whose `labelIds` is absent in the history record are fetched with `format=minimal` first only if they belong to a cached thread (rare path).

### 4.5 historyId expiry recovery (`resync`) — never a wipe

```
func resync():
    profile = api.profile()                                  // new baseline BEFORE listing
    inboxNow  = api.listInboxMessageIds(unreadOnly: false, max: 100)   // 5 units
    unreadNow = api.listInboxMessageIds(unreadOnly: true,  max: 100)   // 5 units: labelIds=INBOX&labelIds=UNREAD
    local = db.read { messages where in_inbox = 1 }
    gone   = local.ids − inboxNow.ids            // archived/trashed elsewhere → remove INBOX locally
    new    = inboxNow.ids − local.ids            // fetch metadata (or full if ≤ 50)
    metas  = api.getMessages(ids: new, format: new.count ≤ 50 ? .full : .metadata)
    write:
        for id in gone: applyLabelDelta(add: [], remove: ["INBOX"])
        for id in local ∩ inboxNow: set UNREAD present iff id ∈ unreadNow
        ingest(metas); reapplyPendingOutboxDeltas; recompute touched
        sync_state[history_id] = profile.historyId; last_full_sync_at = now
```
Cost: 3 small list calls + one batch. Cached bodies survive. Threads not in INBOX are left untouched (they may be stale on read state; acceptable, they are only reachable via label views which refresh their counts from the server anyway).

### 4.6 Body lazy-load (thread open) and prefetch

```
func ensureThreadLoaded(threadId):
    t = db.read { thread[threadId] }
    if t.is_complete && t.bodies_missing == 0 { return }                        // common path: 0 network
    if !t.is_complete:
        thread = api.getThreads(ids: [threadId], format: .full)[threadId]       // 1 RT, all messages incl. SENT
        write: ingest(full) ; is_complete = 1 ; recompute
    else:
        ids = db.read { messages in thread where body_state = 0 }
        msgs = api.getMessages(ids, format: .full)                               // 1 RT batch
        write: ingest(full); recompute
    deferred text parts (large body delivered by attachmentId) → api.attachment(...) → re-run Sanitizer → update message_body   // rare

func prefetchBodies(limit = 25):
    guard foreground, !LowPower.isEnabled, !LowPower.isConstrained, prefs.prefetchBodies
    ids = db.read { inbox threads ORDER BY last_date DESC LIMIT limit WHERE is_complete = 0 OR bodies_missing > 0 }
    results = api.getThreads(ids, format: .full)                                // 1 batch (≤ 25 → 1 RT)
    write per 5 threads (keeps the write lock short): ingest(full), is_complete = 1, recompute
```
Sanitizing runs inside the ingest on the sync actor (off main). A `format=full` message with an HTML part > `Sanitizer.maxInputBytes` (2 MiB) falls back to the plain part, else to the snippet, with `body_state = 1` and `source_was_html = 0`.

### 4.7 Label list & unread counts

- **INBOX / Today / Unread counts are local**: `SELECT COUNT(*) FROM thread WHERE …` using the same partial indexes (sub-millisecond). Shown in the filter menu and as the app badge (`INBOX unread` = `COUNT(*) WHERE in_inbox=1 AND hidden=0 AND unread_count>0`).
- **User labels** show server counts (`labels.get.threadsUnread`) because only INBOX messages are cached. Fetched in one HTTP batch after initial sync, after delta syncs that changed labels/unread state (throttled: at most once per 5 minutes), and when the Labels sheet opens if `counts_updated_at` is older than 5 min.
- Labels displayed: `labelListVisibility != labelHide`, or `labelShowIfUnread` with `threads_unread > 0`. System labels shown: Inbox, Sent, Starred, Important, Drafts (counts only), Spam/Trash hidden in stage 1.

### 4.8 Conflict rules (optimistic local state vs. server)

1. Local mutation first: swipe/tap → `db.write { applyLabelDelta; recompute }` → `outbox.enqueue(.modify)` → `kick()`. The list updates on the next observation tick (< 16 ms).
2. History records for our own ops arrive later and are **idempotent set operations** on `label_ids`; re-applying them is a no-op.
3. After applying any history page, `reapplyPendingOutboxDeltas` re-applies every `pending`/`inflight` modify op that targets touched message/thread ids on top of the server state. Effect: pending intent always wins locally until acknowledged.
4. Genuine conflict (user changed the same flag in webmail between our local change and our upload): **last writer wins = ours** (the outbox will still send it). Accepted; the window is seconds.
5. A message deleted on the server (`messagesDeleted`, or 404 on modify) cancels pending ops for that id (`GmailError.notFound` → op dropped, no banner).
6. Sending: the SENT message shows up via delta sync (`syncNow(reason: .afterSend)`), never synthesised locally — one fewer code path, and it lands within ~1 s.

### 4.9 Outbox design

Ops (`OutboxOp`): `modify(scope: thread|messages, ids, add, remove)` and `send(draft, transmitted)`.

Coalescing (`OutboxCoalescer.coalesce`, pure, run at every drain start over all `pending` rows in `seq` order):
- Same scope + same id set + inverse deltas (`add:[UNREAD]` then `remove:[UNREAD]`) → both dropped.
- Same scope + same id + additive deltas → merged into one op (`add ∪ add − remove`, `remove ∪ remove − add`; the later op wins on contradiction).
- Different ids, identical `(add, remove)`, scope `messages` → merged into one `batchModify` (≤ 1000 ids).
- Thread-scoped ops stay `threads.modify` (one call each; typical archive-from-list). If ≥ 4 thread ops share the same delta, they are converted to one `batchModify` over all cached message ids of those threads (we know them all once threads are complete; otherwise keep per-thread calls).
- `send` ops are never merged or reordered relative to each other; modify ops may run before a send.

Drain loop (`OutboxWorker`):
```
kick(): if draining { return }; debounce 300 ms for modify-only queues (lets a burst of swipes coalesce); drain()
drain():
    loop:
        ops = coalesce(db.read pending where next_attempt_at ≤ now, ORDER BY seq)
        if ops.isEmpty: break
        for op in ops:
            mark inflight
            do:
                switch op:
                  .modify(thread):   api.modify(threadId, add, remove)
                  .modify(messages): api.batchModify(ids, add, remove)
                  .send(s):          try sendOnce(s)
                delete rows merged into op
            catch GmailError.notFound:            delete op (target gone)
            catch GmailError.unauthenticated:     tokens.invalidateAccessToken(); retry once; then status.needsReauth; stop
            catch GmailError.rateLimited(retryAfter), .server, .network:
                attempts += 1; next_attempt_at = now + Backoff.delay(attempts, retryAfter); state = pending
                if attempts ≥ 8 (modify) or ≥ 5 (send): state = failed; status.failedOutboxCount += 1
                stop (do not hammer)
            catch GmailError.badRequest / .forbidden(non-quota): state = failed; last_error = message
    status.pendingOutboxCount = count(pending)
```
Backoff: 1, 2, 4, 8, 16, 32, 60, 60 s (+ ±20 % jitter), `Retry-After` honoured `[gmail-api §Quotas]`. Retries are only attempted while the app is foreground or inside the BG refresh task (which drains the outbox first, then syncs).

Send idempotency (`sendOnce`):
```
if s.transmitted:                                       // a previous attempt may have reached Google
    if let id = api.findByRFC822MessageID(s.draft.messageID) { markSent(); return }
outgoing = SendPipeline.prepare(draft …)                // fetches forward attachments now (never earlier)
bytes = MIMEBuilder.build(outgoing)
write: payload.transmitted = true                       // BEFORE the request leaves
if bytes.count > 5 MiB: api.send(upload: bytes, threadId) else: api.send(raw: Base64URL.encode(bytes), threadId)
markSent(): delete op; syncNow(.afterSend)
```
A timeout after `transmitted = true` therefore never double-sends `[gmail-api §14]`.

Failure UX:
- Pending/in-flight: no UI except a subtle `SyncStatusBar` line ("Sending…") under the nav bar when a `send` is pending > 2 s.
- Failed modify: silent retry on next launch; after final failure the local state is **kept** (the user's intent) and a one-line banner "Some changes couldn't be saved — Retry" appears; Retry resets `attempts`.
- Failed send: banner "Message not sent — Open / Discard". Open → `ComposeScreen` prefilled from the stored `ComposeDraft` (the outbox row *is* the draft; no separate drafts table). Discard → delete row.
- Sign-out with pending ops: confirmation alert lists the count; sign-out drops them.

### 4.10 Background refresh

`BackgroundRefresh.run()` `[ios-platform §3]`:
```
scheduleNext()                                 // consumed request must be re-submitted first
guard prefs.backgroundRefreshEnabled, auth.isSignedIn else return
try? await outbox.drainOnce()                  // ≤ 1 RT typically
await sync.syncNow(reason: .background)        // history.list + ≤ 1 batch; prefetch disabled in BG
await Badge.update()                           // if authorised
```
Data-protection: DB directory set to `.completeUntilFirstUserAuthentication`; on `SQLITE_AUTH`/`SQLITE_IOERR` the task ends immediately. `earliestBeginDate = now + 15 min`. Nothing else ever runs in the background; a `send` started in foreground is wrapped in `beginBackgroundTask` so a swipe-away does not kill it `[ios-platform §3.5]`.

---

## 5. Auth

### 5.1 Prerequisites (owner, one-time; from `[gmail-api §OAuth scopes and Workspace policy]`)
GCP project inside the example.com org → OAuth consent **Internal** → Gmail API enabled → OAuth client type **iOS**, bundle id `com.minimail` → Admin console: mark the client **Trusted** or enable "Trust internal, domain-owned apps" (otherwise `admin_policy_enforced`). Put the client-id prefix in `Config/Google.xcconfig`.

### 5.2 Flow
1. `SignInScreen` → `AuthStore.signIn(presenting:)` → `OIDAuthorizationRequest(configuration: hardcodedEndpoints, clientId:, scopes: [gmail.modify], redirectURL:, responseType: code, additionalParameters: ["login_hint": lastEmail?, "hd": "example.com"])` → `OIDExternalUserAgentIOS(presentingViewController:prefersEphemeralSession: false)` → `OIDAuthState.authState(byPresenting:externalUserAgent:callback:)` bridged with `withCheckedThrowingContinuation` `[ios-platform §1.4]`. No discovery call (saves a round trip and a failure mode).
2. On success: `tokens.store(state)` (Keychain), `db` opened/migrated already, `syncEngine.syncNow(.launch)`; `RootView` switches to the list.
3. `onOpenURL` → `authStore.resume(url:)` fallback (ASWebAuthenticationSession normally completes via its handler).

### 5.3 Token storage & refresh
- `OIDAuthState` archived with `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)` into `kSecClassGenericPassword` service `com.minimail`, account `oauth.authState`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` `[ios-platform §1.5, §5.5]`. Re-archived on every `OIDAuthStateChangeDelegate.didChange`.
- `AppAuthTokenProvider.accessToken()` wraps `performAction(freshTokens:)`; the actor keeps one in-flight refresh `Task` so N concurrent callers share one token refresh (AppAuth serialisation is UNVERIFIED → guarded by the actor).
- Restore happens **after the first frame** (`RootView.task`), so a Keychain read never delays launch. Until restore completes the list renders from SQLite as usual; only the sync waits.

### 5.4 401 handling
`GmailAPI` on HTTP 401: `tokens.invalidateAccessToken()` (→ `setNeedsTokenRefresh()`), retry the same request once. Second 401, or a token-endpoint `invalid_grant` → throw `GmailError.unauthenticated(permanent: true)` → `AuthStore.handleAuthFailure` → state `.needsReauth`. UI: a non-blocking banner "Sign in again" on the list; cached mail stays readable; outbox pauses. Never a loop `[gmail-api §Gotchas 18]`.

### 5.5 Sign-out
Revoke (`POST /revoke token=<refresh>` best effort, 5 s timeout) → delete Keychain item → `AppDatabase.wipe()` (delete the whole `minimail-db/` directory, reopen empty) → purge `Caches/attachments` → reset `Preferences` except `themeMode/themeID` → `Badge.clear()`.

### 5.6 Single-account assumptions
One `OIDAuthState`, one `AppDatabase`, `sync_state.profile_email` is the identity; every `From:` uses `profile_display_name <profile_email>`; self-dedupe uses `self_addresses`. A second sign-in with a different account is only possible after sign-out (which wipes). No account switcher UI.

---

## 6. Networking

### 6.1 `URLSession.minimail` configuration
`URLSessionConfiguration.default` with: `timeoutIntervalForRequest = 20`, `timeoutIntervalForResource = 60`, `waitsForConnectivity = false` (fail fast, retry on next trigger), `httpMaximumConnectionsPerHost = 2`, `allowsExpensiveNetworkAccess = true`, `allowsConstrainedNetworkAccess = true` (mail is essential; prefetch is the only thing gated on Low Data), `urlCache = nil` (we cache in SQLite), `httpAdditionalHeaders = ["Accept": "application/json", "Accept-Encoding": "gzip"]`, `multipathServiceType = .none`. HTTP/2 multiplexing is automatic.

### 6.2 `GmailAPI` shape
- Every call: `prettyPrint=false`, explicit `fields=` mask where the endpoint is chatty (`messages.get`, `threads.get`, `history.list` → `history(id,messagesAdded(message(id,threadId,labelIds)),messagesDeleted(message(id,threadId)),labelsAdded(message(id,threadId,labelIds),labelIds),labelsRemoved(message(id,threadId,labelIds),labelIds)),nextPageToken,historyId`).
- `RequestLimiter(max: 2)`: at most two HTTP requests in flight per process. Batches make more parallelism unnecessary and the per-mailbox concurrency cap is UNVERIFIED `[gmail-api §Gotchas 24]`.
- Retry policy inside `GmailAPI` (transport level): 429/503/network error → `Backoff.delay` up to 3 attempts for reads; **0 automatic retries for `send`** (the outbox owns send retries with its idempotency check); 401 → one refresh+retry (§5.4).

### 6.3 Batching strategy
- Endpoint `https://www.googleapis.com/batch/gmail/v1`, `multipart/mixed`, CRLF, `Content-ID: <n>` per part; responses matched by `Content-ID: <response-n>` `[gmail-api §12]`.
- Chunk size **50** (research: 100 max, ≤ 50 recommended). A batch of k parts counts as k quota units but **one round trip** — the metric we optimise.
- Per-part 429 → only those parts are retried after backoff (max 2 extra batches); per-part 404 → surfaced as `Result.failure(.notFound)` and ignored by ingest.
- Batched: `messages.get`, `threads.get`, `labels.get`, `labels.list + sendAs.list` (first sync). Never batched: `history.list`, `send`, `modify`, `batchModify`, `attachments.get` (single, on demand).

### 6.4 Error taxonomy

```swift
enum GmailError: Error, Sendable, Equatable {
    case unauthenticated(permanent: Bool)          // 401 / invalid_grant
    case forbidden(reason: String)                 // 403: dailyLimitExceeded, insufficientPermissions, admin_policy_enforced …
    case notFound                                  // 404 on message/thread/attachment
    case historyExpired                            // 404 on history.list, or 400 failedPrecondition on startHistoryId
    case rateLimited(retryAfter: TimeInterval?)    // 429 (rateLimitExceeded, userRateLimitExceeded, concurrent)
    case badRequest(message: String)               // 400 other (e.g. invalid raw)
    case server(status: Int)                       // 5xx
    case network(URLError.Code)                    // offline, timeout, cancelled
    case decoding(String)
    case batchMalformed
    var isRetryable: Bool   // rateLimited, server, network(timeout/notConnected/networkConnectionLost)
}
```
Mapping: HTTP status first, then `GmailErrorEnvelope.error.status`/`reason` `[gmail-api §Common facts]`. `historyExpired` is only produced for the history endpoint.

### 6.5 Rate-limit handling
`Retry-After` header wins; otherwise exponential backoff with jitter (1 → 32 s). On the third consecutive 429 across the sync, the sync aborts and `SyncStatus.phase = .error("Rate limited")`; the next trigger retries. Daily-limit 403 pauses the outbox until next launch.

### 6.6 Logging
`os.Logger(subsystem: "com.minimail", category:)` categories: `launch`, `sync`, `outbox`, `net`, `auth`, `render`, `db`. `net` logs method + path + status + duration + byte counts only — **never** headers, tokens, bodies, or addresses (use `privacy: .private` for ids). `os_signpost` intervals: `launch.firstFrame`, `sync.initial`, `sync.delta`, `sync.batch`, `render.threadOpen`, `render.loadHTML`, `outbox.drain`. In DEBUG, `MINIMAIL_NETLOG=1` env dumps request/response summaries to the console.

---

## 7. Compose pipeline (reply-all / forward)

Everything except the network lives in `MinimailCore/Compose` + `MIME` and is unit-tested against the vectors in `[mime-rfc §7–8]`.

### 7.1 Entry: creating a `ComposeDraft` (main actor, from cached data only)

```
func makeDraft(kind, original: MessageRecord, thread: ThreadRecord, me: SelfIdentity) -> ComposeDraft
    headers = (from: original.from, replyTo: original.reply_to_json, to: original.to_json, cc: original.cc_json)
    switch kind:
      .replyAll: r = ReplyAllResolver.resolve(from:replyTo:to:cc:me:)    // §7.2
                 subject = SubjectPrefix.reply(original.subject)
      .forward:  r = (to: [], cc: [])
                 subject = SubjectPrefix.forward(original.subject)
    messageID = MessageID.make(domain: me.primary.addr.domainPart)
    inReplyTo = original.rfc_message_id                                  // both kinds — mirror Gmail web [mime-rfc §1.5]
    references = MessageID.referencesChain(parentReferences: original.references_json,
                                           parentInReplyTo: [original.in_reply_to].compact, parentMessageID: original.rfc_message_id)
    return ComposeDraft(kind, originalMessageId, threadId, to: r.to, cc: r.cc, subject, bodyText: "",
                        includeAttachments: kind == .forward, attachmentPartIds: non-inline attachment part ids, messageID, inReplyTo, references)
```
Decision: **forwards keep `threadId` + `In-Reply-To` + `References`** (Gmail-web behaviour; the RFC-purist variant is a one-line change in `makeDraft`). The original must have a cached body; `ComposeScreen` calls `sync.ensureThreadLoaded` first (0 network if prefetched).

### 7.2 Reply-all recipient algorithm (`ReplyAllResolver.resolve`) — `[mime-rfc §2.1]`

```
isSelfReply = from != nil && me.allAddresses.contains(from.key)
toCandidates = isSelfReply ? to : ((replyTo.isEmpty ? [from].compact : replyTo) + to)
ccCandidates = cc
seen = Set<String>()
To = toCandidates.filter { !$0.key.isEmpty && !me.allAddresses.contains($0.key) && seen.insert($0.key).inserted }
Cc = ccCandidates.filter { same predicate }            // To wins over Cc
if To.isEmpty && !Cc.isEmpty { To = Cc; Cc = [] }
if To.isEmpty, let f = from { To = [f] }               // never empty To (note-to-self case)
```
Display names: first-seen name kept; comparison on lowercased addr-spec only. The 16 vectors in `[mime-rfc §8.1]` are the test table.

### 7.3 Quoting (`Quoting`) — `[mime-rfc §4]`
- Reply HTML: `<br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On {DateHeader.attribution} {name} &lt;<a href="mailto:{addr}">{addr}</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">{ORIGINAL_HTML}</blockquote></div>`.
- Reply text: attribution line, then original text lines prefixed `> ` (`>` for empty lines).
- Forward HTML/text: the exact banner `---------- Forwarded message ---------` + From/Date/Subject/To[/Cc] lines, body **not** blockquoted, `<strong class="gmail_sendername" dir="auto">`.
- `ORIGINAL_HTML` = `message_body.html` with: `img.mm-remote[data-src]` → `src` restored (we forward the sender's mail, not our placeholder), `minimail-cid://…` → `cid:…` (forward with inline images re-attached via `multipart/related` is **stage 2**; in stage 1 inline images are dropped from the HTML and listed as normal attachments), the `mm-*` classes removed. If the original was plain text: `PlainTextToHTML.convert(text)`.
- Attribution uses `en_US_POSIX`, `EEE, MMM d, yyyy 'at' h:mm\u{202F}a`, device time zone.

### 7.4 Outgoing body assembly — `[html-rendering §5]`

```
html = OutgoingHTML.body(text: draft.bodyText, style: prefs.composeStyle,
                         signatureHTML: prefs.signatureEnabled ? prefs.signatureHTMLSanitized : nil,
                         quoteHTML: kind == .replyAll ? Quoting.replyHTML(o) : Quoting.forwardHTML(o))
   = <div dir="ltr" class="minimail_default" style="{inlineCSS}">{one <div> per line; empty → <div><br></div>}</div>
     [<div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature"><div style="{inlineCSS}">{signature}</div></div>]
     {quote block — OUTSIDE the styled wrapper}
text = OutgoingText.body(text, signatureText: OutgoingText.signatureText(fromHTML: signature), quoteText)
     = body + "\n\n-- \n" + signatureText + "\n\n" + quoteText
```
Signature: stored as raw HTML in `Preferences.signatureHTML`; sanitized once on save with `Sanitizer.sanitizeSignature` (keeps `https:` images, drops scripts/remote CSS). "Import from Gmail" copies `sync_state.send_as_signature` into the editor `[gmail-api §15]`. Images in signatures: hosted `https://` only (data: URIs are not rendered by Gmail) `[mime-rfc §3.4]`.

### 7.5 MIME builder (`MIMEBuilder.build`) — `[mime-rfc §1.3, §3]`

Header order (fixed for byte-exact tests): `From, To, Cc?, Subject, Date, Message-ID, In-Reply-To?, References?, MIME-Version: 1.0, Content-Type`. Non-ASCII header text → RFC 2047 B-words; mailboxes via `Mailbox.headerValue()`; folding ≤ 78 at commas / between msg-ids; every line CRLF; no line > 998 octets.

Structure: `multipart/alternative[text/plain(QP), text/html(QP)]`; with attachments wrap in `multipart/mixed[alternative, attachment*]`. Attachments: `Content-Type: {mime}; name="{ascii}"`, `Content-Disposition: attachment; filename="{ascii}"; filename*=UTF-8''{pct}` (only when non-ASCII), `size={n}`, `Content-Transfer-Encoding: base64` (76-col CRLF, standard alphabet). Boundaries `=_minimail_{alt|mixed}_{16 hex}` (injectable for tests). HTML part wrapped as `<html><head><meta charset="utf-8"></head><body>…</body></html>` without any `color-scheme` meta.

Pinned tests: the two byte-exact examples (`sha256 b9f8078c…` reply-all 2276 bytes; `2127dc54…` forward 2927 bytes) using fixed date/UUID/boundaries; plus a regenerated Gmail-web-variant forward (adds `In-Reply-To`) whose hash the agent records on first run.

### 7.6 Forward with attachments — `[mime-rfc §6]`
At **send time** in `SendPipeline.prepare` (never earlier, never prefetched): for each selected `attachment` row → `AttachmentStore.cached` else `api.attachment(messageId, attachment_id)`; on 404 re-run `messages.get?format=full` once to refresh `attachment_id`, then retry. Verify `bytes.count == size` (warn, don't fail). Total budget: Σ size × 1.37 + body > 25 MiB → compose shows "Attachments too large to forward (x MB)" and disables Send; Σ > 5 MiB → the upload transport (`Content-Type: message/rfc822`, `threadId` in multipart metadata) `[gmail-api §14]`.

### 7.7 Send via outbox
`ComposeScreen` Send → `outbox.enqueue(.send(draft, transmitted: false))` → dismiss immediately (haptic `.success`) → `outbox.kick()`. Everything else is §4.9. `SyncStatusBar` shows "Sending…" only if it takes > 2 s.

---

## 8. UI

### 8.1 Screen list & navigation graph

```
RootView
 ├─ SignInScreen                       (state .signedOut / .needsReauth without cache)
 └─ NavigationStack(path)
     └─ MailListScreen(filter)         ROOT — launches straight into Inbox
         ├─ .toolbarTitleMenu → FilterMenu (Inbox / Today / Labels…)      changes filter in place
         ├─ toolbar trailing: Unread toggle, Settings (gear) → sheet SettingsScreen
         ├─ .sheet LabelsSheet         (from FilterMenu "Labels…") → selects filter .label(id)
         ├─ push ThreadScreen(threadId)
         │    ├─ bottom toolbar: Reply all · Forward · Archive · Read/Unread
         │    ├─ .sheet ComposeScreen(draft)   (fullScreenCover)
         │    ├─ .quickLookPreview(attachmentURL)
         │    └─ .sheet SafariView(url)
         └─ SettingsScreen (sheet, own NavigationStack)
              ├─ push SignatureEditorScreen
              ├─ push ComposeStyleScreen
              └─ push ThemePickerScreen
```
No Mailboxes root screen: the app opens on the Inbox list (one tap fewer, one screen fewer to build on launch). Filter changes replace the list's query in place (no push, no animation cost); the nav title shows the current filter.

### 8.2 Per-screen state and actions

**MailListScreen** — `MailListModel` (`@Observable`):
- state: `filter: MailFilter` (`.inbox | .today | .label(id, name)`), `unreadOnly: Bool`, `rows: [ThreadRow]`, `limit: Int = 60`, `todayBoundary: DayBoundary`, `counts: (inbox, today, unread)`, `syncStatus`, `outboxFailed: Int`.
- actions: `open(thread)`, `archive(threadId)`, `toggleUnread(threadId)`, `refresh()` (pull), `loadMore()` (last row appears → `limit += 60`; if the cached rows are exhausted and `sync_state.inbox_next_page` exists, calls `syncEngine.loadOlderInbox()` which fetches the next `messages.list` page + one metadata batch — Inbox filter only), `setFilter`, `toggleUnreadOnly`, `dayChanged()` (`NSCalendarDayChanged` / scene active).
- observation: `ValueObservation.trackingConstantRegion { ThreadListQuery.request(...).fetchAll }` `.start(in: pool, scheduling: .immediate)`; recreated when `filter/unreadOnly/limit/todayBoundary` change.
- states: **loading** = never (rows come from SQLite instantly; an empty DB before the first sync shows the empty state with a small "Loading your inbox…" footer while `syncStatus == .syncing`); **empty** = `ContentUnavailableView("No Mail", systemImage: "tray")` (Today: "Nothing today", `sun.max`; Unread: "All caught up", `checkmark.circle`); **error** = `SyncStatusBar` line under the nav bar ("Offline — showing cached mail", "Sign in again", "Couldn't refresh · Retry"); never a blocking alert.

**ThreadScreen** — `ThreadModel`:
- state: `threadId`, `detail: ThreadDetailQuery.Detail?` (observed), `expanded: Set<messageId>` (default: all unread + the newest), `imagesAllowed: Set<messageId>` (from `images_loaded` ∪ session), `loading: Bool` (only when `ensureThreadLoaded` must hit the network), `previewURL: URL?`, `linkURL: URL?`, `error`.
- actions: `onAppear` → `markReadIfNeeded()` (prefs.markReadOnOpen: all unread messages in thread → local + outbox `threads.modify remove UNREAD`), `ensureThreadLoaded()`, `toggleExpanded(id)`, `loadImages(id)` (sets `images_loaded=1`, re-renders document with images-on CSP + rule list), `openAttachment(id, partId)`, `replyAll()`, `forward()`, `archive()` (→ pop with haptic), `toggleThreadUnread()`, `openLink(url)`.
- render: `ThreadWebView(html: ThreadDocument.render(...), allowRemoteImages:)`; reloads only when the document string changes.
- states: loading spinner **inside** the web view area only when `bodies_missing > 0` (native `ProgressView` overlay); body unavailable → message section shows the snippet + "Couldn't load this message · Retry".

**ComposeScreen** — `ComposeModel`: `draft: ComposeDraft`, `bodyText` bound to `TextEditor`, recipients editable as comma-separated chips (`RecipientsView`: tap to remove, "+" adds via a text field validated by `AddressParser`), `subject` editable, `includeAttachments` toggle (forward) with total size label, `QuotePreviewView` read-only below the editor. Actions: `send()` (validates non-empty To, then enqueues), `cancel()` (confirmation if body non-empty). Keyboard toolbar: none (stage 1).

**LabelsSheet** — `LabelsModel`: rows from `LabelListQuery` (observed), tap → `onSelect(filter)`; refreshes counts on appear if stale. Row: colour dot (user labels, `background_color`), name, right-aligned unread count (`threads_unread`), `chevron`. Sections: "Mailboxes" (Inbox/Today/Unread with local counts), "Labels".

**SettingsScreen**: Account (email, "Sign out"), Appearance (Theme picker → System/Light/Dark + theme list), Compose (Default font & colour → `ComposeStyleScreen` with live preview; Signature → `SignatureEditorScreen`: raw HTML `TextEditor` + live preview in a pooled web view + "Import from Gmail" + "Use signature" toggle), Reading (Load remote images automatically: off; Mark as read when opened: on; Prefetch messages for offline reading: on), Background (Background refresh: on; Show unread count on icon: off → triggers the `.badge` authorisation prompt when enabled `[ios-platform §6]`), About (version, build).

**SignInScreen**: app name, one `Button("Sign in with Google")` (`.borderedProminent`), footer text about the example.com account; `needsReauth` variant shows the reason.

### 8.3 List row layout (`ThreadRowView`) — iOS Mail conventions
```
┌──────────────────────────────────────────────────────────────┐
│ ●  Alice Müller, Bob, Me                        Yesterday  › │   .headline (semibold if unread) / .subheadline secondary
│    Angebot für die Erweiterung             📎                │   .subheadline, primary, 1 line
│    ist das Angebot schon unterwegs? …                        │   .subheadline secondary, 2 lines
│    [ACME] [Projects]                                         │   LabelChip capsules (max 3), .caption2
└──────────────────────────────────────────────────────────────┘
```
- Leading unread dot: 10 pt circle, `theme.unread` (system blue), hidden but space-reserved when read.
- Trailing: `dateLabel` (`DateLabel.short`: `9:41` today, `Yesterday`, `Mon`, `11/09/26` — cached `DateFormatter`s, computed on the reader thread in `ThreadRow` mapping, never in `body`), then `chevron.right` via `NavigationLink`.
- Message count badge (`3`) after the name when `message_count > 1`, `.caption`, secondary.
- Paperclip `paperclip` SF Symbol when `has_attachments`.
- Row body does **no** formatting, **no** image loading, **no** `Task`; every string is precomputed in `ThreadRow`.
- `List` with `.listStyle(.plain)`, `.id(thread.id)`; `ForEach(rows)` keyed by `id`; `.listRowInsets` 12/16.

### 8.4 Swipe actions (PLAN.md)
- Leading, full swipe: **Archive** — `Label("Archive", systemImage: "archivebox.fill")`, `.tint(.indigo)`; haptic `UIImpactFeedbackGenerator(.medium)`; row disappears from Inbox immediately (local `remove INBOX` on the thread).
- Trailing, full swipe: **Read/Unread toggle** — `envelope.open.fill` "Mark Read" / `envelope.badge.fill` "Mark Unread", `.tint(.blue)`.
- No destructive actions in stage 1 (no Trash).

### 8.5 Toolbar & symbols
Nav title = filter name with `.toolbarTitleMenu { Inbox (tray), Today (sun.max), Labels… (tag) }`; trailing `ToolbarItemGroup`: unread-only toggle (`envelope.badge` / `envelope.badge.fill`, tinted when on), Settings (`gearshape`). Thread bottom bar: `arrowshape.turn.up.left.2` Reply All, `arrowshape.turn.up.right` Forward, `archivebox` Archive, `envelope.badge`/`envelope.open` Read state. Compose: leading `Cancel`, trailing `Send` (`paperplane.fill`, `.borderedProminent`). Fonts: system text styles only (`.headline`, `.subheadline`, `.caption`, `.caption2`), Dynamic Type honoured. Haptics: `.medium` impact on archive, `.selection` on filter change, `.success` notification on send enqueue, `.error` on failed send banner appearance.

### 8.6 Filters as SQL (`ThreadListQuery.request`)

All queries return `ThreadRow` columns only; `?` are bound parameters; each hits exactly one partial index from §3.2.

```sql
-- Inbox
SELECT id, subject, snippet, last_from_name, participants, last_date, unread_count, message_count, has_attachments, label_ids
FROM thread WHERE in_inbox = 1 AND hidden = 0
ORDER BY last_date DESC LIMIT ?;                                           -- idx thread_inbox_date

-- Inbox, unread only
… WHERE in_inbox = 1 AND hidden = 0 AND unread_count > 0 ORDER BY last_date DESC LIMIT ?;   -- idx thread_inbox_unread

-- Today (received today in local tz; :start/:end from DayBoundary)
… WHERE in_inbox = 1 AND hidden = 0 AND last_inbox_date >= :start AND last_inbox_date < :end
ORDER BY last_inbox_date DESC LIMIT ?;                                     -- idx thread_inbox_today
-- Today + unread: add AND unread_count > 0 (same index; filter is cheap on ≤ a day of rows)

-- Label
SELECT t.id, t.subject, … FROM thread_label tl JOIN thread t ON t.id = tl.thread_id
WHERE tl.label_id = :label AND t.hidden = 0 [AND tl.unread = 1]
ORDER BY tl.last_date DESC LIMIT ?;                                        -- idx thread_label_date, then PK lookup

-- Counts (filter menu + badge)
SELECT COUNT(*) FROM thread WHERE in_inbox = 1 AND hidden = 0 AND unread_count > 0;
SELECT COUNT(*) FROM thread WHERE in_inbox = 1 AND hidden = 0 AND last_inbox_date >= :start AND last_inbox_date < :end;
```
"Today" is computed locally from `internal_date` in the device time zone `[gmail-api §Searching]`; the boundary is refreshed on scene activation and on `NSCalendarDayChanged`.

### 8.7 Empty / loading / error states (summary)
| Situation | UI |
|---|---|
| Fresh install, initial sync running | Empty list + footer `ProgressView("Loading your inbox…")`; rows appear when the first batch commits (single observation tick) |
| Filter has no rows | `ContentUnavailableView` per filter (§8.2) |
| Offline | `SyncStatusBar`: "Offline — showing cached mail"; pull-to-refresh ends immediately |
| Rate limited / 5xx | `SyncStatusBar`: "Couldn't refresh · Retry" |
| Reauth needed | `SyncStatusBar` (tap → sign-in sheet); list still usable |
| Failed send / modify | `OutboxBanner` above the list (Open / Discard · Retry) |
| Thread body missing & offline | Section shows snippet + "Not available offline" |

---

## 9. HTML rendering

### 9.1 Sanitizer (at ingest, off main) — `[html-rendering §1]`
Pipeline `Sanitizer.sanitize(html:gmailMessageId:)`:
1. Guard size ≤ 2 MiB, else throw `.tooLarge` (caller falls back to text).
2. `SwiftSoup.parseBodyFragment`; for every `img`: `cid:` → `minimail-cid://<msgId>/<pct(cid)>` (record in `referencedCIDs`); `data:image/*` kept; `http(s)` → `data-src` + 1×1 GIF placeholder + `class="mm-remote"`, `hasRemoteImages = true`; tracking-pixel heuristic (`width/height ≤ 2` or hidden, alt-less, remote) → element removed; drop `srcset/sizes/loading`; drop `[background]`.
3. `DarkStrategy.classify(doc)` → `plain | card | native`.
4. `SwiftSoup.clean` with the whitelist from `[html-rendering §1.3]` (relaxed + `style`, `class`, table attrs, `font`, protocols `a: http https mailto tel`, `img: data minimail-cid`, enforced `a target=_self`, CSS property allowlist).
5. `StyleScrubber.scrub` regex pass over `<style>` contents (`@import`, `@font-face`, non-data `url()`, `expression`, `behavior`, `position:fixed|absolute`).
6. Output `SanitizedBody` → `message_body` row. `Sanitizer.version` stored; on bump, bodies with an older version are re-fetched lazily on open (`body_state` treated as 0).

Plain-text mails: `PlainTextToHTML.convert` (escape, `\n` → `<div>`/`<br>`, linkify `https?://` and emails, `white-space: pre-wrap` class), `dark_strategy = plain`.

### 9.2 Thread document (`ThreadDocument.render`) — one HTML document per thread `[html-rendering §2.7, §4]`
```html
<!doctype html><html><head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: minimail-cid: {https: if allowRemoteImages}; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="{theme.colorScheme}">
<style>
:root{color-scheme:{theme.colorScheme};--mm-bg:{bg};--mm-surface:{surface};--mm-text:{text};--mm-secondary:{secondaryText};--mm-accent:{accent};--mm-sep:{separator};--mm-unread:{unread};--mm-card:{cardBg}}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:transparent;color:var(--mm-text);font:-apple-system-body;font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;overflow-wrap:break-word;-webkit-touch-callout:none}
h1.mm-subject{font:600 22px/1.2 -apple-system;margin:12px 16px 4px}
.mm-msg{border-top:1px solid var(--mm-sep)} .mm-hdr{padding:10px 16px;display:flex;gap:8px;align-items:baseline;cursor:pointer}
.mm-from{font-weight:600;flex:1} .mm-msg.unread .mm-from::before{content:"";display:inline-block;width:8px;height:8px;border-radius:4px;background:var(--mm-unread);margin-right:6px}
.mm-date{color:var(--mm-secondary);font-size:13px} .mm-to{color:var(--mm-secondary);font-size:13px;padding:0 16px 8px}
.mm-body{padding:8px 16px 16px} .mm-collapsed .mm-body,.mm-collapsed .mm-to{display:none} .mm-collapsed .mm-snippet{display:block;color:var(--mm-secondary);padding:0 16px 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mm-att{display:flex;gap:8px;padding:0 16px 12px;flex-wrap:wrap} .mm-att a{border:1px solid var(--mm-sep);border-radius:8px;padding:6px 10px;color:var(--mm-accent);text-decoration:none;font-size:13px}
.mm-images{margin:0 16px 8px;font-size:13px} .mm-images a{color:var(--mm-accent)}
img{max-width:100% !important;height:auto} table{max-width:100% !important} pre{white-space:pre-wrap} blockquote[type=cite]{margin:0 0 0 .8ex;border-left:2px solid var(--mm-sep);padding-left:1ex} .mm-remote{min-width:1px;min-height:1px}
@media (prefers-color-scheme:dark){ .mm-plain{color:#E5E5EA} .mm-plain a{color:#0A84FF} .mm-plain [style*="color"]{color:inherit !important} .mm-plain font[color]{color:inherit !important}
  .mm-card .mm-body{background:var(--mm-card);color:#000;color-scheme:light;border-radius:12px;margin:0 12px 12px;padding:12px;overflow:hidden} }
</style></head><body>
<h1 class="mm-subject">{subject}</h1>
{for each message:}
<section class="mm-msg {unread} {mm-collapsed|mm-expanded} {mm-plain|mm-card|mm-native}" data-id="{id}">
  <div class="mm-hdr" onclick="" data-action="toggle"><span class="mm-from">{fromName}</span><span class="mm-date">{dateLabel}</span></div>
  <div class="mm-snippet">{snippet}</div>
  <div class="mm-to">To: {toSummary}</div>
  {if hasRemoteImages && !imagesLoaded}<div class="mm-images"><a data-action="images" href="#">Load images</a></div>{endif}
  <div class="mm-body">{bodyHTML or "Loading…" placeholder}</div>
  {attachments: <div class="mm-att">{<a data-action="att" data-part="{partId}" href="#">{icon} {filename} · {size}</a>}</div>}
</section>
</body></html>
```
Taps are delivered by a `WKUserScript` (`.atDocumentEnd`, app JS is allowed) that installs one delegated `click` listener and posts `{action, id, part}` to `window.webkit.messageHandlers.mm` `[html-rendering §2.1]`. `WebBridge` maps: `toggle` → `ThreadModel.toggleExpanded` → `evaluateJavaScript("document.querySelector('[data-id=…]').classList.toggle('mm-collapsed')")` (no reload); `images` → `loadImages(id)` → reload with images-on CSP + `imagesOnly` rule list; `att` → `openAttachment`. Link clicks are `.linkActivated` navigations → `LinkPolicy` cancels and opens `SafariView` (http/https) or `UIApplication.open` (mailto/tel).

### 9.3 WKWebView setup — `[html-rendering §2.4]`
`WebViewPool` creates **two** instances lazily (thread screen; compose quote/signature preview) with one shared configuration: `allowsContentJavaScript = false`, `preferredContentMode = .mobile`, `websiteDataStore = .nonPersistent()`, `dataDetectorTypes = []`, `setURLSchemeHandler(CIDSchemeHandler(), forURLScheme: "minimail-cid")`, `userContentController.add(RuleLists.blockAll)`, `add(WebBridge, name: "mm")`, `addUserScript(clickDelegate)`, `suppressesIncrementalRendering = true`; view: `allowsLinkPreview = false`, `isOpaque = false`, `backgroundColor = underPageBackgroundColor = theme.bg`, `overrideUserInterfaceStyle` from `ThemeStore`, `scrollView.contentInsetAdjustmentBehavior = .automatic`, `isInspectable` in DEBUG. `loadHTMLString(_, baseURL: nil)`.

Warm-up: after the first list frame + 1 s idle, `RuleLists.prepare()` (compile-once, looked up by identifier `minimail.block-all.v1` / `minimail.images-only.v1`) then `pool.warm()` loads `ThreadDocument.empty` so the WebContent process exists before the first thread tap. On memory warning or 60 s after leaving the thread screen the instance loads the empty document (drops the DOM, keeps the process).

### 9.4 Image blocking + Load images
Default: rule list `blockAll` + CSP `img-src data: minimail-cid:` + placeholders → **no network from the web view, ever**. Tap "Load images" (or `Preferences.remoteImagesDefault == true`): set `message.images_loaded = 1`, re-render the document with `allowRemoteImages: true` (CSP adds `https:`, placeholders restored to `src` server-side in `ThreadDocument`), swap to `RuleLists.imagesOnly` (`ignore-previous-rules` for `resource-type: image` over https only) and reload. Tracking pixels were already removed at ingest. `cid:` images are always allowed (they are attachment bytes fetched through `CIDSchemeHandler` → `SyncEngine.inlineImage` → `AttachmentStore` cache → `attachments.get` once).

### 9.5 Dark mode strategy — `[html-rendering §3]`
No inversion. Document declares `color-scheme` from the theme (`light dark` for System, else the forced scheme) and the web view gets `overrideUserInterfaceStyle`. Per message: `plain` → recolour text/links; `card` → untouched on a white 12 px card with `color-scheme: light`; `native` → nothing (sender's own dark CSS). Message headers/subject use theme CSS vars, so they match the native chrome exactly.

### 9.6 Sizing
None. The web view fills the area between the nav bar and the bottom toolbar and **is** the scroller; no `scrollHeight` measuring, no `ResizeObserver`, no per-message web views `[html-rendering §4]`. Dynamic Type changes reload the document (`UIContentSizeCategory.didChangeNotification`).

---

## 10. Theming

```swift
enum ThemeMode: String, Codable, CaseIterable, Sendable { case system, light, dark
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .light ? .light : .dark) } }

struct Palette: Codable, Equatable, Sendable {           // hex strings → resolved to Color/UIColor once per theme change
    var background: String, surface: String, text: String, secondaryText: String, accent: String
    var unread: String, separator: String, chipBackground: String, chipText: String, cardBackground: String
}
struct Theme: Codable, Equatable, Identifiable, Sendable {
    var id: String; var name: String
    var light: Palette; var dark: Palette
    var fonts: Fonts = .system                            // Fonts { var body: TextStyle = .body; var headline: TextStyle = .headline }
    var listRowSpacing: CGFloat = 12                     // future knobs live here, never in views
}
struct ResolvedTheme: Equatable, Sendable {               // what views read; one struct, value-typed, cheap to diff
    let background, surface, text, secondaryText, accent, unread, separator, chipBackground, chipText, cardBackground: Color
    let uiBackground: UIColor; let scheme: ColorScheme
    var documentTheme: ThreadDocumentTheme               // for ThreadDocument
}
enum BuiltInThemes {   // registry; adding a theme = one entry
    static let system = Theme(id: "system", name: "System", light: iOSLightPalette, dark: iOSDarkPalette)  // uses UIColor.system* hex equivalents
    static let graphite = Theme(id: "graphite", name: "Graphite", …)   // example second theme; optional
    static var all: [Theme] { [system, graphite] }
    static func theme(id: String) -> Theme                // fallback system
}
@MainActor @Observable final class ThemeStore {
    var mode: ThemeMode { didSet { persist(); resolve() } }
    var themeID: String { didSet { persist(); resolve() } }
    private(set) var resolved: ResolvedTheme
    init(prefs: PreferencesStore, systemScheme: ColorScheme)
    func systemSchemeChanged(_ scheme: ColorScheme)       // RootView reads @Environment(\.colorScheme) and forwards
    func register(_ theme: Theme)                         // stage 2: JSON themes decoded into Theme and registered
}
```
- Injection: `RootView().environment(themeStore).preferredColorScheme(themeStore.mode.colorScheme)`; views read `@Environment(ThemeStore.self)` and use `theme.resolved.*` tokens only — **never** `Color.black`/`.white` in views (SwiftLint custom regex rule `no_raw_colors` forbids `Color(red:`, `.white`, `.black` outside `Theme/`).
- Light/Dark/System: `mode == .system` → `resolved` follows the environment `colorScheme`; explicit modes force `preferredColorScheme` and `overrideUserInterfaceStyle` on web views and `UIWindow` chrome.
- Persistence: `Preferences.themeMode`, `Preferences.themeID` (§11); the launch screen colour asset `LaunchBackground` matches `system` palette so the first frame does not flash. Because the first frame renders before `Preferences` is decoded? No — `PreferencesStore` decodes one small JSON blob from `UserDefaults` synchronously in `AppContainer.init` (< 0.5 ms); the theme is correct on frame one.
- Extensibility: a theme is data; stage 2 can load `Theme` JSON files from Application Support and call `register`.

---

## 11. Settings model

```swift
struct Preferences: Codable, Equatable, Sendable {
    // Appearance
    var themeMode: ThemeMode = .system
    var themeID: String = "system"
    // Compose
    var composeStyle: ComposeStyle = .init()              // helvetica / 14 px / #000000
    var signatureHTML: String = ""                        // raw, as edited
    var signatureHTMLSanitized: String = ""               // Sanitizer.sanitizeSignature output, kept in sync on save
    var signatureEnabled: Bool = true
    // Reading
    var remoteImagesDefault: Bool = false
    var markReadOnOpen: Bool = true
    var prefetchBodies: Bool = true
    var prefetchThreadLimit: Int = 25
    // Background / badge
    var backgroundRefreshEnabled: Bool = true
    var badgeEnabled: Bool = false                        // flips true only after .badge authorisation succeeds
    // Diagnostics
    var lastKnownEmail: String? = nil                     // login_hint; not the identity (that is sync_state)
    var schemaVersion: Int = 1
}
@MainActor @Observable final class PreferencesStore {
    private(set) var prefs: Preferences
    init(defaults: UserDefaults = .standard)              // key "prefs.v1"; decode failure → defaults (never crash)
    func update(_ change: (inout Preferences) -> Void)    // mutates, then writes JSON (sortedKeys) synchronously; UserDefaults write is ~µs
    var snapshot: Preferences { prefs }                   // Sendable copy for actors (PreferencesSnapshotProvider)
}
```
protocol PreferencesSnapshotProvider: Sendable { var snapshot: Preferences { get async } }   // implemented by PreferencesStore (main-actor hop); actors never touch UserDefaults directly

Unknown keys are ignored on decode (forward-compatible); new fields must have defaults (`decodeIfPresent`).

---

## 12. Performance & battery budget

### 12.1 Targets (measured on an iPhone 12 or newer, Release build, cached inbox of 100 threads)

| Metric | Target | How measured |
|---|---|---|
| Cold start → first painted list (process start to first `List` row on screen) | **< 300 ms** (stretch 220 ms) | `XCTApplicationLaunchMetric` in `SmokeTests.testColdLaunchMetric` (5 iterations) + `os_signpost` `launch.firstFrame` from `main` to `MailListScreen.onAppear` |
| Warm resume (background → active, list visible) | < 50 ms to interactive; delta sync result visible < 800 ms on LTE | signposts `sync.delta` |
| Pull-to-refresh with no changes | 1 request, < 400 ms end to end | `net` log |
| Thread open, cached & complete | < 16 ms to `loadHTMLString`, < 120 ms to painted body (warm web view) | signposts `render.threadOpen`, `render.loadHTML` |
| Thread open, network miss | 1 round trip; < 900 ms on LTE | same |
| Scrolling 100+ rows | 0 dropped frames at 120 Hz (row `body` < 0.5 ms; no allocation-heavy work) | Instruments "Animation Hitches" + `XCTOSSignpostMetric` on `scroll` in the smoke test (manual) |
| Swipe archive → row gone | next frame (< 16 ms); network op coalesced within 300 ms | signposts `outbox.drain` |
| Memory (app process, foreground, list + one thread) | < 60 MB; WebContent is out-of-process | Xcode memory gauge / `xcrun xctrace` |
| Binary | < 12 MB download size (static SPM, no assets beyond icon) | App Store Connect / `xcodebuild -exportArchive` size report |
| Network per foreground sync (steady state) | ≤ 3 requests (history + ≤ 1 batch + optional counts), typically 20–80 KB | `net` log |
| Background | 0 self-initiated work; BG refresh ≤ 2 requests, < 5 s CPU | Console `backgroundtask` logs |
| Battery (Settings → Battery, 24 h normal use) | "Background activity" < 1 % | manual |

### 12.2 Tactics (each one maps to code)

**Launch path (in order; nothing else before the first frame):**
1. `main` → `MinimailApp.init`: `AppContainer` constructed lazily; only `PreferencesStore` (UserDefaults JSON decode) and `AppDatabase.open` (create dir, `DatabasePool`, `DatabaseMigrator.migrate` — a no-op check when current) run synchronously. Measured budget: < 8 ms.
2. `RootView` decides `signedIn` from `sync_state.profile_email` (one indexed read, part of the same `.immediate` observation start) — **not** from the Keychain (Keychain restore happens later; if it fails we show the reauth banner over the cached list).
3. `MailListScreen` starts `ValueObservation … scheduling: .immediate` → synchronous fetch of ≤ 60 `ThreadRow`s from the covering index → first frame.
4. `.task` after first frame (`Task.yield()` twice, then): `authStore.restoreSession()` → `syncEngine.syncNow(.launch)`; `+1 s`: `RuleLists.prepare()`, `WebViewPool.warm()`; `+2 s`: `BackgroundRefresh.scheduleNext()`, cleanup (§3.5), `Badge.update()`.
5. No `AppAuth` discovery, no `labels.list` before first frame, no `WKWebView`, no `UNUserNotificationCenter` calls, no `BGTaskScheduler` calls, no `NotificationCenter` observers beyond scene phase — all deferred.
6. Static linking (default for SPM in Xcode), `ONLY_ACTIVE_ARCH`, dead-strip; no `@objc` runtime scanning frameworks; `LaunchBackground` colour asset instead of a storyboard.

**List:**
- `ThreadRow` is fully precomputed (`participants`, `dateLabel`); `body` does string→Text only.
- `trackingConstantRegion` + `DatabasePool` → subsequent fetches off the main thread; one observation tick per sync transaction (ingest batches commit once).
- `limit` paging (60 → +60) instead of fetching everything.
- Stable identities (`id: String`), `Equatable` rows → SwiftUI diffing skips untouched cells.
- Label chips: at most 3, plain `Text` in a `Capsule` background; colours resolved once per theme into `Color` values held in `ThemeStore`, and per-label colours cached in a `[String: Color]` map inside `MailListModel` (rebuilt only when `label` rows change).

**Network:**
- Round trips, not bytes, are the budget: batch everything batchable; one `history.list`; `fields=` masks; gzip; HTTP/2 connection reuse (`URLSession` keeps the connection warm for ~30 s — sync bursts happen within it).
- Prefetch bodies once (top 25) so opens are local; never prefetch attachments.
- `RequestLimiter(2)` avoids 429s that would cost extra round trips.

**Rendering:**
- Sanitize at ingest, off main; store once; render = string concat + `loadHTMLString`.
- Web view warmed post-launch; process kept alive; `suppressesIncrementalRendering` avoids double paints; no measuring.

**Battery:**
- No timers, no polling, no sockets, no location, no analytics, no background `URLSession`, no push.
- BG refresh opportunistic, opt-out, minimal.
- Prefetch and label-count refresh skipped under Low Power Mode / Low Data Mode: `LowPower.swift` combines `ProcessInfo.processInfo.isLowPowerModeEnabled` with the `isConstrained` / `isExpensive` flags of a single `NWPathMonitor` that is started after the first frame and cancelled when the scene goes to background (no monitor runs in the background).
- WKWebView cannot make network requests (rule list + CSP + no JS) → no hidden radio wake-ups.
- SQLite in WAL with `automaticMemoryManagement` (GRDB default) releases caches on background.

### 12.3 Instrumentation checklist for the agent
- `Signposts.swift` defines the intervals in §6.6; `LaunchTimeline.mark(_:)` records `launch.*` events with `mach_absolute_time` deltas from process start (`ProcessInfo.processInfo.systemUptime` vs. `kinfo_proc` start time) and logs one line `launch: db=3ms firstFetch=2ms firstFrame=187ms`.
- `make perf-launch` runs the launch metric test and prints p50/p90; CI fails if p50 > 400 ms on the simulator (a loose guard; device numbers are the real target).

---

## 13. Testing strategy

### 13.1 Layers
| Layer | Runner | What |
|---|---|---|
| `MinimailCoreTests` (pure) | `swift test` on Linux/macOS, seconds | base64url, address parsing, RFC 2047/2231, QP, date headers, MIME builder (byte-exact + sha256), payload parser (8 shapes), reply-all (16 vectors), subject prefix, quoting markup, outgoing HTML/text, sanitizer (allowlist, remote images, cid, tracking pixels, style scrub, size guard), dark-strategy classification, thread document rendering (snapshot as string), `HistoryDelta.reduce`, `ThreadSummary.make`, `DayBoundary` (DST edges, TZ table: Europe/Berlin, UTC, America/Los_Angeles, Pacific/Auckland), DTO decoding of every fixture |
| `minimailTests` (simulator, in-memory GRDB, `StubTransport`) | `make test-unit` | migrations (fresh + idempotent), `ThreadListQuery` (each filter uses the intended index — assert with `EXPLAIN QUERY PLAN` contains the index name), ingestor + aggregator (thread flags, `bodies_missing`, `thread_label`), initial sync (request sequence & count assertions: exactly N HTTP calls), delta sync (adds/deletes/label changes/404-dropped/paging/expired → resync), resync reconcile, outbox coalescer (inverse cancel, merge, batchModify conversion, send ordering), outbox worker (backoff, `transmitted` idempotency via `rfc822msgid`, notFound drop, 401 → reauth), batch request builder (byte-exact against the `[gmail-api §12]` sample), batch response parser (200-with-failed-parts sample), error mapping table, Keychain round trip (simulator), theme resolution, preferences decode with unknown keys |
| Snapshot (2–3) | same bundle, `swift-snapshot-testing` | `ThreadRowView` unread/light, read/dark, label chips |
| `minimailUITests` (1 test class) | `make test-ui` | `MINIMAIL_TESTING=1` launches with a seeded DB (`Fixtures/seed.sqlite` copied at launch by `AppContainer` in testing mode) and a stub transport; asserts the seeded subject is visible, toggles Unread, asserts the row set; plus `testColdLaunchMetric` (`XCTApplicationLaunchMetric`) |

### 13.2 Fixtures (`Packages/MinimailCore/Tests/MinimailCoreTests/Fixtures/`)
- Gmail JSON (hand-built to the Discovery shapes in `[gmail-api]`): `profile.json`, `labels_list.json`, `label_get_user.json`, `label_get_inbox.json`, `messages_list_inbox.json`, `messages_list_inbox_page2.json`, `message_metadata.json`, `message_full_alternative.json`, `message_full_mixed_pdf.json`, `message_full_related_cid.json`, `message_full_plain_only.json`, `message_full_html_attachmentId.json`, `message_full_outlook_nested.json`, `message_full_signed.json`, `thread_full.json`, `history_mixed.json` (adds, deletes, labelsAdded TRASH, labelsRemoved UNREAD, duplicates), `history_paged_1.json`/`_2.json`, `history_empty.json`, `error_401.json`, `error_404_history.json`, `error_429.json`, `sendas_list.json`, `batch_response_mixed.txt` (multipart with a 200 and a 404 part), `batch_response_all_fail.txt`.
- MIME: `reply_expected.eml` (2276 bytes, sha256 `b9f8078c…`), `forward_expected.eml` (2927 bytes, `2127dc54…`), `forward_gmailweb_expected.eml` (generated on first run, then pinned), `stub.pdf` (125 bytes), `signature.html`.
- HTML: `newsletter_tables.html`, `plain_reply.html`, `tracking_pixels.html`, `cid_inline.html`, `dark_native.html`, `style_import.html`, `huge_3mb.html` (generated in test), `xss_samples.html` (script, javascript: href, onerror, meta refresh, iframe, svg, form).
- Seed DB for the UI test: `seed.sql` (10 threads, 2 unread, 1 label) applied at app start in testing mode.

### 13.3 What is not tested automatically
Real OAuth (manual once per device), real `messages.send` (manual against the owner's account during M3 with a `+minimail-test` recipient), BG refresh (LLDB `_simulateLaunchForTaskWithIdentifier:` manual), web-view pixel output (manual, both themes), quota behaviour.

---

## 14. Risks and open questions (with the chosen resolution)

| # | Risk / open question | Resolution |
|---|---|---|
| 1 | Quota units per method after May 2026 are UNVERIFIED (`messages.get` 5 vs 20; 6,000 vs 15,000 units/user/min) `[gmail-api §Quotas]` | Design for the pessimistic table (§4.2); batch size 50; prefetch spaced ≥ 5 s after the initial batch; `RequestLimiter(2)`. Agent fetches the quota page in M1 and adjusts `prefetchThreadLimit` only upward. |
| 2 | `history.list` change records may lack current `labelIds` (sync guide is UNVERIFIED) | `HistoryDelta` carries both `finalLabels?` and the delta; ingest uses final labels when present, else the delta (§4.4). Either path is unit-tested. |
| 3 | `historyId` may expire within hours, not a week | `resync()` is cheap (3 list calls + 1 batch) and keeps all cached bodies; a 404 is an expected path, never an error surface. |
| 4 | Cold start < 300 ms may be unreachable on older devices because of SwiftUI + dyld cost | Launch path does exactly one DB read before the first frame and links statically; `LaunchTimeline` gives the breakdown from day one. If the device p50 is > 300 ms after M1, the fallback is a plain `UICollectionView`-backed list (UIKit) for the root screen only; everything else stays SwiftUI. Decided threshold: switch only if SwiftUI list accounts for > 100 ms of the budget. |
| 5 | `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` vs GRDB 7 / AppAuth closures (UNVERIFIED) `[tooling §3.3]` | Core package is nonisolated (no friction there). App: try MainActor default first; escape hatch order: `nonisolated` default → Swift 5 + complete checking. Decide in M1 on the first `pool.write`. |
| 6 | AppAuth callbacks are not `Sendable`-annotated | `AppAuthTokenProvider` actor owns `OIDAuthState`; `@preconcurrency import AppAuth`; continuations for all callbacks. |
| 7 | `attachmentId` instability (community-reported) | Stored only as a cache; on 404 re-run `messages.get?format=full` once and retry (§7.6). |
| 8 | CSP `img-src minimail-cid:` acceptance for a custom scheme (UNVERIFIED) | Test on device in M2; if blocked, drop the CSP meta for cid images and rely on the rule list + `allowsContentJavaScript=false` (still two layers). |
| 9 | Content-rule `resource-type` values / `ignore-previous-rules` semantics (partially UNVERIFIED) | Verify with a proxy in M2; fallback for "Load images" is `blockAll` removed entirely for that document (images-on documents have no scripts/CSS anyway after sanitizing). |
| 10 | SwiftSoup cost on huge newsletters | 2 MiB input guard + off-main sanitize; measure `SanitizerTests.testPerformanceNewsletter` (< 150 ms for 500 KB on the simulator). |
| 11 | "Today" semantics (device TZ vs. Gmail account TZ) | Local `internal_date` in device TZ (§8.6); no server query. Documented in Settings footer. |
| 12 | Data protection during BG refresh (`SQLITE_AUTH`) | Directory set to `.completeUntilFirstUserAuthentication` at creation; BG task bails on the error. |
| 13 | Badge requires notification authorisation; provisional behaviour UNVERIFIED | Opt-in toggle triggers `requestAuthorization([.badge])`; default off. |
| 14 | Forward threading choice (`In-Reply-To` on forwards) | Mirror Gmail web (all three set). One-line switch documented in §7.1. |
| 15 | Stage-1 forwards drop inline `cid:` images from the HTML | Accepted; listed as attachments instead. Stage 2: `multipart/related`. |
| 16 | Label counts for user labels are server-side and may be minutes stale | Refresh on Labels sheet open if > 5 min; local counts for Inbox/Today/Unread are always exact. |
| 17 | iOS 27 SDK / Xcode 27 timing | Pin 26.6 now; bump when the runner image has 27.0 GA; deployment target unchanged. |
| 18 | Free provisioning (7-day profiles) is unusable for a daily driver | Apple Developer Program + TestFlight (owner action, M4). |
| 19 | Prefetch may download bodies the user never reads (data/battery) | Capped at 25 threads, foreground-only, skipped on Low Power/Low Data, toggle in Settings; measured against the "≤ 2 MB per cold sync" expectation in M2. |
| 20 | Concurrency between `SyncEngine` writes and `OutboxWorker` writes | Both go through the single `DatabasePool` writer (serialised); every write is one transaction; `reapplyPendingOutboxDeltas` runs inside the sync transaction so the UI never observes a server-overwritten intermediate state. |
| 21 | `messages.list?labelIds=INBOX&maxResults=100` limits the cold inbox to 100 messages (~60–90 threads) | Deliberate for speed; "Load older" footer in the Inbox list requests the next page (`pageToken` stored in `sync_state.inbox_next_page`) via the same metadata batch path (stage-1 feature, cheap). |
| 22 | Signature import from `sendAs.signature` may reference Google-proxied image URLs | Kept as-is (hosted https); the sanitizer keeps https `img src` for signatures. |
| 23 | `TextEditor` lacks a keyboard accessory / attributed text on iOS 17 | Accepted: plain-text compose per PLAN; styling applied at MIME build time. |
