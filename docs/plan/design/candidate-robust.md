# minimail — Stage-1 technical architecture (candidate: ROBUSTNESS-FIRST)

Date: 2026-09-11. Author angle: correctness of sync (never lose or duplicate state), offline-safe optimistic actions with a durable outbox, precise error handling, thorough unit-test coverage of MIME and sync — while staying feature-minimal. Baseline decisions from `PLAN.md` (SwiftUI, iOS 17+, Gmail REST, AppAuth-iOS, GRDB, WKWebView, URLSession, single scope `gmail.modify`) are kept unchanged.

Facts are cited to the research files in `docs/plan/research/` as `[gmail-api §n]`, `[ios-platform §n]`, `[mime-rfc §n]`, `[html-rendering §n]`, `[tooling §n]`. Where those files mark something UNVERIFIED, this design treats it as a hypothesis and says what the code does if the hypothesis is false.

How to read this document: it is written for an AI coding agent working headless (Linux for editing, macOS runner for building). Every file is named, every public type has a signature, every algorithm has pseudocode, every SQL statement is spelled out. "Decision:" lines are final choices; "Fallback:" lines are what to do if an UNVERIFIED assumption fails on the real account.

---

## 0. Design principles that drive every choice below

1. **The database is the only source of truth for the UI.** Views observe SQLite; network results are written to SQLite; the UI never awaits a network call. `[PLAN.md "Local-first"]`
2. **Two label columns, not one.** Every message stores `server_label_ids` (what Gmail last told us) and `label_ids` (effective = server state with every pending outbox delta re-applied). Sync writes only the former; the latter is always recomputed from the former plus the outbox. This is the mechanism that makes optimistic actions and server deltas commute — nothing is lost or duplicated no matter in which order acknowledgements and history records arrive. `[gmail-api §13 item 7]`
3. **Every mutation is an outbox row first.** UI actions (`archive`, `read`, `unread`, `send`) insert a durable row in the same SQLite transaction that updates the optimistic state. The app can be killed at any instant without losing the intent or the local state.
4. **Idempotent replay everywhere.** Full sync, delta sync, outbox acknowledgement and history replay are all set operations; running any of them twice yields the same database. `historyId` is advanced only after the batch it describes is committed.
5. **Pure core, thin shell.** MIME, header parsing, reply-all, quoting, base64url, batch multipart, history reduction, label-state algebra, backoff and coalescing are pure Swift in a local SwiftPM package (`MinimailCore`) with no Apple-framework dependency, so the agent runs `swift test` on Linux in seconds. Only the actors that touch URLSession, GRDB, AppAuth and WebKit live in the app target.
6. **Pessimistic quota model.** All budgets assume the higher 2026 quota-unit figures (`messages.get` 20, `threads.get` 40, 6,000 units/user/min) `[gmail-api "Quotas"]`.
7. **Minimal features, maximal correctness.** No feature beyond PLAN.md stage 1 is added; a few internal safety mechanisms (reconcile pass, sync generation, draft autosave, diagnostics screen) are added because they protect the owner's mail state.

---

## 1. Tooling & project layout

### 1.1 Decisions

| Topic | Decision | Rationale |
|---|---|---|
| Project generator | **XcodeGen 2.46.0**, `project.yml` committed, `minimail.xcodeproj` git-ignored | Deterministic, YAML, no Xcode GUI `[tooling §1]` |
| Xcode | **26.6 (17F113)**; bump to 27.0 when the `macos-26` runner image ships it GA | iOS 26 SDK requirement satisfied; Swift 6.3 `[tooling §3.1]` |
| Deployment target | **iOS 17.0** | Every stage-1 API is ≤ iOS 17 `[ios-platform §0]` |
| Swift | **Language mode 6**, app target `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`; the `MinimailCore` package is **nonisolated by default** (pure code, `Sendable` value types) `[tooling §3.3]` | Data races are compile errors; the UI compiles without annotations; the engine is explicit actors |
| Packages | AppAuth-iOS **3.0.0** (`AppAuth`), GRDB.swift **7.11.1** (`GRDB`), SwiftSoup **2.13.9** (`SwiftSoup`, via the local package), swift-snapshot-testing **1.19.4** (tests only) | Versions verified 2026-09-11 `[tooling §1.3]`, `[html-rendering §1.1]` |
| Local package | `Packages/MinimailCore` with two library products: `MinimailCore` (zero dependencies) and `MinimailHTML` (depends on SwiftSoup) | Linux-testable core `[tooling §7.4]` |
| Build/test | `make build`, `make test-unit`, `make test-core` (Linux or macOS `swift test`), `make test-ui`; simulator `iPhone 17` | `[tooling §2]` |
| CI | GitHub Actions `macos-26` (unit + snapshot) plus an `ubuntu-latest` job running `swift test` on the core package | The Linux job gives feedback in ~2 min without macOS minutes |
| Lint | `swift format lint --strict` + SwiftLint 0.65.1 (`only_rules`) | `[tooling §5]` |
| Deployment | Apple Developer Program + TestFlight via `xcodebuild -exportArchive … destination=upload` | 7-day free profiles are unusable for a daily-driver mail app `[tooling §6]` |

### 1.2 Repository tree (every file)

```
minimail/
├── PLAN.md
├── README.md                              # 1-page: how to build/test headless (make targets), GCP setup checklist
├── project.yml                            # XcodeGen spec (§1.3)
├── Makefile                               # gen / build / test-unit / test-core / test-ui / lint / format / archive
├── ExportOptions.plist                    # TestFlight upload options [tooling §6.2]
├── .gitignore                             # minimail.xcodeproj/, .build/, DerivedData/, *.xcresult, Config/Google.xcconfig? (no: committed, not secret)
├── .swift-format
├── .swiftlint.yml
├── .github/workflows/ci.yml               # jobs: core-linux (swift test), ios-unit (macos-26), ios-ui (main only)
├── Config/
│   ├── Signing.xcconfig                   # DEVELOPMENT_TEAM = REPLACE_WITH_TEAM_ID
│   └── Google.xcconfig                    # GOOGLE_CLIENT_ID = REPLACE.apps.googleusercontent.com ; GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.REPLACE
├── docs/plan/…                            # (this document and research)
├── Packages/MinimailCore/
│   ├── Package.swift
│   ├── Sources/MinimailCore/
│   │   ├── Encoding/Base64URL.swift                 # encode (padded) / decode (tolerant)
│   │   ├── Encoding/QuotedPrintable.swift           # encode 76-col / tolerant decode
│   │   ├── Encoding/RFC2047.swift                   # encoded-word encode (B) / decode (B,Q, adjacent-word LWSP rule)
│   │   ├── Encoding/RFC2231.swift                   # parameter continuations + charset'lang'%xx
│   │   ├── Encoding/Charsets.swift                  # IANA charset name → String.Encoding map (pure table; CoreFoundation-free)
│   │   ├── Headers/Mailbox.swift                    # struct Mailbox {name, addr}; serialize (quote / RFC 2047)
│   │   ├── Headers/AddressParser.swift              # RFC 5322 §3.4 tokenizer (quoted-string, comments, groups, obs-route)
│   │   ├── Headers/HeaderFolding.swift              # unfold; fold To/Cc/References at 78
│   │   ├── Headers/RFC5322Date.swift                # parse Date header incl. obsolete forms; format outgoing Date
│   │   ├── Headers/ContentTypeParams.swift          # parse "type/sub; k=v; k*=…" (used for charset, boundary, filename)
│   │   ├── Headers/MessageIDs.swift                 # split References, normalise <…>
│   │   ├── MIME/OutgoingMessage.swift               # value type (§7.4)
│   │   ├── MIME/MIMEBuilder.swift                   # OutgoingMessage → Data (RFC 5322 bytes, CRLF)
│   │   ├── MIME/Boundary.swift                      # BoundaryGenerator (random / fixed for tests)
│   │   ├── Compose/ReplyAll.swift                   # recipient algorithm (§7.1)
│   │   ├── Compose/SubjectPrefix.swift              # Re: / Fwd: rules
│   │   ├── Compose/Quoting.swift                    # Gmail attribution + quote markup, plain "> " quoting, forward banner
│   │   ├── Compose/OutgoingHTML.swift               # typed text → styled HTML body, signature wrapping
│   │   ├── Compose/ComposeStyle.swift               # Codable font/size/colour config
│   │   ├── Compose/ComposeDraft.swift               # Codable draft (outbox payload)
│   │   ├── Gmail/DTO/GmailMessage.swift             # Message, MessagePart, MessagePartBody, MessagePartHeader
│   │   ├── Gmail/DTO/GmailThread.swift
│   │   ├── Gmail/DTO/GmailLabel.swift               # Label, LabelColor, ListLabelsResponse
│   │   ├── Gmail/DTO/GmailHistory.swift             # ListHistoryResponse, History, HistoryMessageAdded/Deleted, HistoryLabelAdded/Removed
│   │   ├── Gmail/DTO/GmailProfile.swift
│   │   ├── Gmail/DTO/GmailSendAs.swift
│   │   ├── Gmail/DTO/GmailListResponses.swift       # ListMessagesResponse, ListThreadsResponse
│   │   ├── Gmail/DTO/GmailErrorEnvelope.swift       # {"error":{code,message,status,errors[{reason}]}}
│   │   ├── Gmail/DTO/StringNumber.swift             # UInt64/Int64 decoded from JSON strings
│   │   ├── Gmail/PayloadParser.swift                # MessagePart tree → ParsedMessage (headers, html, text, attachments, cid map)
│   │   ├── Gmail/Batch/BatchRequestEncoder.swift    # [BatchCall] → multipart/mixed body + boundary
│   │   ├── Gmail/Batch/BatchResponseParser.swift    # multipart/mixed → [BatchPart(contentID, status, headers, body)]
│   │   ├── Sync/LabelAlgebra.swift                  # LabelDelta, effectiveLabels(server:pending:), derived flags
│   │   ├── Sync/HistoryReducer.swift                # [ListHistoryResponse] → HistoryChanges
│   │   ├── Sync/OutboxCoalescer.swift               # merge(existing:new:) rules
│   │   ├── Sync/Backoff.swift                       # exponential + jitter, Retry-After
│   │   ├── Sync/QuotaTable.swift                    # pessimistic unit costs per method
│   │   ├── Sync/HydrationPolicy.swift               # shouldFetch(unknownMessage:) rule (§4.3)
│   │   ├── Support/TodayRange.swift                 # startOfDay(in tz) as epoch ms
│   │   ├── Support/HTMLEscape.swift
│   │   └── Support/ThreadAggregate.swift            # pure aggregation of message rows → thread row fields
│   ├── Sources/MinimailHTML/
│   │   ├── Sanitizer.swift                          # SwiftSoup allowlist pipeline (§9.1)
│   │   ├── StyleScrubber.swift
│   │   ├── TrackingPixel.swift
│   │   ├── DarkStrategy.swift
│   │   ├── SignatureSanitizer.swift                 # owner-authored signature: keep https img src
│   │   └── QuoteExtractor.swift                     # body_html → quotable HTML (restore data-src, cid handling) for compose
│   └── Tests/
│       ├── MinimailCoreTests/                        # (§13 lists every file)
│       ├── MinimailHTMLTests/
│       └── Fixtures/                                 # JSON payloads, .eml, expected outputs (§13.2)
├── minimail/                                         # app target (MainActor default)
│   ├── Info.plist                                    # GENERATED by xcodegen — never edit
│   ├── minimail.entitlements                         # generated, empty
│   ├── App/
│   │   ├── MinimailApp.swift                         # @main, scene, .backgroundTask, .onOpenURL, scenePhase hooks
│   │   ├── AppContainer.swift                        # composition root: builds DB, API, engine, stores; test hooks (MINIMAIL_TESTING)
│   │   ├── RootView.swift                            # auth gate + NavigationStack + reauth sheet
│   │   ├── BackgroundRefresh.swift                   # BGAppRefresh scheduling + handler body
│   │   └── AppLifecycle.swift                        # foreground/background transitions → engine triggers
│   ├── Auth/
│   │   ├── TokenProvider.swift                       # protocol
│   │   ├── AppAuthTokenProvider.swift                # actor around OIDAuthState; single-flight refresh
│   │   ├── AuthStore.swift                           # @Observable @MainActor: auth state machine, sign-in flow presentation
│   │   ├── KeychainStore.swift                       # SecItem wrapper
│   │   └── AuthError.swift
│   ├── Gmail/
│   │   ├── HTTPTransport.swift                       # protocol + URLSessionTransport
│   │   ├── GmailAPI.swift                            # actor: endpoints, retry, batch conveniences
│   │   ├── GmailError.swift                          # taxonomy + mapping from HTTP/URLError
│   │   ├── RequestBuilder.swift                      # URL/URLRequest construction (repeated params, fields, prettyPrint=false)
│   │   ├── RateLimiter.swift                         # actor: token bucket (units) + concurrency gate
│   │   └── BatchClient.swift                         # runs BatchCalls, per-part retry rounds
│   ├── Store/
│   │   ├── Database.swift                            # DatabasePool factory, paths, file protection, in-memory for tests
│   │   ├── Migrations.swift                          # DatabaseMigrator with raw SQL v1
│   │   ├── Records/LabelRecord.swift
│   │   ├── Records/ThreadRecord.swift
│   │   ├── Records/MessageRecord.swift
│   │   ├── Records/MessageLabelRecord.swift
│   │   ├── Records/MessageBodyRecord.swift
│   │   ├── Records/AttachmentRecord.swift
│   │   ├── Records/OutboxRecord.swift
│   │   ├── Records/SyncStateRecord.swift
│   │   ├── Repositories/MessageRepository.swift      # upsert metadata, apply server label state, recompute effective
│   │   ├── Repositories/ThreadRepository.swift       # aggregate recompute, list queries
│   │   ├── Repositories/LabelRepository.swift
│   │   ├── Repositories/BodyRepository.swift
│   │   ├── Repositories/OutboxRepository.swift       # enqueue+coalesce, claim, ack, fail
│   │   ├── Repositories/SyncStateRepository.swift
│   │   ├── Queries/ThreadListQuery.swift             # InboxFilter → SQL (§8.5)
│   │   ├── Queries/ThreadRowDTO.swift                # row projection for the list
│   │   ├── Queries/ThreadDetailDTO.swift             # messages + bodies + attachments for a thread
│   │   └── Maintenance/Pruner.swift                  # cache bounds (§4.9)
│   ├── Sync/
│   │   ├── SyncEngine.swift                          # actor: coordinator, run(reason:), status publication
│   │   ├── FullSync.swift
│   │   ├── DeltaSync.swift
│   │   ├── MetadataHydrator.swift                    # ids → batched messages.get metadata → DB
│   │   ├── ThreadCompleter.swift                     # threads.get metadata on open when thread incomplete
│   │   ├── BodyLoader.swift                          # actor: messages.get full → parse → sanitize → DB (dedupe in-flight)
│   │   ├── LabelSync.swift                           # labels.list + batched labels.get counts
│   │   ├── Reconciler.swift                          # daily minimal re-fetch of visible messages' labelIds
│   │   ├── OutboxWorker.swift                        # actor: drain loop, modify batches, sends
│   │   ├── SendOperation.swift                       # draft → MIME (+attachments) → send/upload, rfc822msgid idempotency
│   │   ├── NetworkMonitor.swift                      # NWPathMonitor → engine trigger
│   │   ├── SyncStatus.swift                          # @Observable @MainActor: phase, offline, lastError, outbox counts
│   │   └── SyncReason.swift
│   ├── Rendering/
│   │   ├── ThreadDocumentBuilder.swift               # thread rows → single HTML document (headers + bodies + attachment lists)
│   │   ├── ThreadTemplate.swift                      # HTML/CSS template strings (CSP variants, theme vars)
│   │   ├── MailWebView.swift                         # UIViewRepresentable around the pooled WKWebView
│   │   ├── WebViewPool.swift                         # 1 instance, warm-up, recycle
│   │   ├── WebViewConfigurationFactory.swift
│   │   ├── RuleLists.swift                           # compile-once content rule lists
│   │   ├── LinkPolicy.swift                          # WKNavigationDelegate
│   │   ├── WebBridge.swift                           # WKScriptMessageHandler: toggle, loadImages, openAttachment, tapAddress
│   │   ├── CIDSchemeHandler.swift                    # minimail-cid:// → InlineImageStore
│   │   ├── InlineImageStore.swift                    # actor: cid bytes cache (attachments.get)
│   │   └── AttachmentFileCache.swift                 # Caches/attachments/<msg>/<file>; LRU
│   ├── Features/
│   │   ├── SignIn/SignInScreen.swift
│   │   ├── Inbox/InboxScreen.swift
│   │   ├── Inbox/InboxModel.swift                    # @Observable: rows via ValueObservation, filter, actions
│   │   ├── Inbox/InboxFilter.swift                   # enum: inbox, today, unread, label(id) + unreadOnly toggle
│   │   ├── Inbox/ThreadRow.swift
│   │   ├── Inbox/LabelChip.swift
│   │   ├── Inbox/ViewMenu.swift                      # toolbar menu Inbox/Today/Unread/Labels…
│   │   ├── Inbox/StatusBanner.swift                  # offline / syncing / error / failed-send banners
│   │   ├── Thread/ThreadScreen.swift
│   │   ├── Thread/ThreadModel.swift                  # @Observable: detail observation, expansion state, body loading, actions
│   │   ├── Thread/ThreadActionBar.swift              # bottom toolbar
│   │   ├── Thread/AttachmentPreview.swift            # QuickLook binding + download
│   │   ├── Compose/ComposeScreen.swift
│   │   ├── Compose/ComposeModel.swift                # @Observable: draft, autosave, send → outbox
│   │   ├── Compose/RecipientsView.swift              # read-only chips + edit sheet (add/remove addresses)
│   │   ├── Compose/QuotePreviewView.swift            # read-only quoted original as SwiftUI Text (no second WKWebView; see §8.4)
│   │   ├── Compose/ForwardAttachmentsView.swift
│   │   ├── Labels/LabelsScreen.swift
│   │   ├── Labels/LabelsModel.swift
│   │   ├── Labels/LabelRow.swift
│   │   ├── Settings/SettingsScreen.swift
│   │   ├── Settings/SignatureScreen.swift            # raw HTML editor + live preview
│   │   ├── Settings/ComposeStyleScreen.swift         # family / size / colour with preview
│   │   ├── Settings/ThemeScreen.swift
│   │   ├── Settings/AccountSection.swift
│   │   ├── Settings/DiagnosticsScreen.swift          # sync state, outbox, last errors, log export (DEBUG + Release)
│   │   ├── Settings/Settings.swift                   # Codable struct (§11)
│   │   └── Settings/SettingsStore.swift              # @Observable, UserDefaults JSON persistence
│   ├── Theme/
│   │   ├── Theme.swift                               # protocol + token structs
│   │   ├── LightTheme.swift
│   │   ├── DarkTheme.swift
│   │   ├── ThemeRegistry.swift
│   │   ├── ThemeStore.swift                          # @Observable: resolves System/Light/Dark, exposes tokens + CSS vars
│   │   └── ThemeEnvironment.swift                    # view modifiers / environment key helpers
│   ├── Support/
│   │   ├── Log.swift                                 # os.Logger categories, signposts, privacy helpers
│   │   ├── Haptics.swift
│   │   ├── DateFormatting.swift                      # list time formatting (today → time, this week → weekday, else date)
│   │   ├── SafariView.swift
│   │   ├── Toast.swift
│   │   └── FileProtection.swift
│   └── Resources/
│       ├── Assets.xcassets/ (AppIcon, AccentColor)
│       ├── Localizable.xcstrings
│       ├── PrivacyInfo.xcprivacy
│       ├── RuleLists/block-all.json
│       ├── RuleLists/images-only.json
│       └── Web/thread.css                            # base CSS (§9.5)
├── minimailTests/                                    # app-level XCTest (needs simulator)
│   ├── Store/MigrationsTests.swift
│   ├── Store/MessageRepositoryTests.swift
│   ├── Store/ThreadListQueryTests.swift
│   ├── Store/OutboxRepositoryTests.swift
│   ├── Sync/FullSyncTests.swift
│   ├── Sync/DeltaSyncTests.swift
│   ├── Sync/HistoryExpiryTests.swift
│   ├── Sync/OutboxWorkerTests.swift
│   ├── Sync/SendOperationTests.swift
│   ├── Sync/ConflictTests.swift                      # optimistic vs server interleavings
│   ├── Gmail/GmailAPITests.swift                     # error mapping, retry, 401 refresh path, batch part retry
│   ├── Rendering/ThreadDocumentBuilderTests.swift
│   ├── Snapshots/ThreadRowSnapshotTests.swift
│   ├── Snapshots/__Snapshots__/…
│   ├── Support/FakeTransport.swift                   # scripted HTTP responses (URL pattern → response queue)
│   ├── Support/FakeTokenProvider.swift
│   ├── Support/TestDatabase.swift                    # in-memory DatabaseQueue + migrations
│   └── Support/FixtureLoader.swift                   # reads Packages/MinimailCore/Tests/Fixtures via bundle copy
└── minimailUITests/
    └── SmokeTests.swift                              # one test: seeded DB → inbox shows subject → Unread chip toggles
```

### 1.3 `project.yml` (complete)

Differences from the research draft `[tooling §1.4]`: local package, SwiftSoup arrives through the package, Google IDs come from `Config/Google.xcconfig`, `MINIMAIL_TESTING` env var, `GoogleClientID` custom Info.plist key.

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
  Debug: Config/Signing.xcconfig
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
    debug: { SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG, ONLY_ACTIVE_ARCH: YES }
    release: { SWIFT_COMPILATION_MODE: wholemodule }
packages:
  AppAuth: { url: https://github.com/openid/AppAuth-iOS, exactVersion: 3.0.0 }
  GRDB: { url: https://github.com/groue/GRDB.swift, exactVersion: 7.11.1 }
  SnapshotTesting: { url: https://github.com/pointfreeco/swift-snapshot-testing, exactVersion: 1.19.4 }
  MinimailCore: { path: Packages/MinimailCore }
targets:
  minimail:
    type: application
    platform: iOS
    sources:
      - path: minimail
        excludes: ["**/*.md", "Info.plist", "minimail.entitlements"]
    dependencies:
      - { package: AppAuth, product: AppAuth }
      - { package: GRDB, product: GRDB }
      - { package: MinimailCore, product: MinimailCore }
      - { package: MinimailCore, product: MinimailHTML }
    configFiles:
      Debug: Config/Google.xcconfig
      Release: Config/Google.xcconfig
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
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false }
        ITSAppUsesNonExemptEncryption: false
        BGTaskSchedulerPermittedIdentifiers: [de.newtelco.minimail.refresh]
        UIBackgroundModes: [fetch]
        GoogleClientID: $(GOOGLE_CLIENT_ID)
        CFBundleURLTypes:
          - CFBundleTypeRole: Editor
            CFBundleURLName: de.newtelco.minimail.oauth
            CFBundleURLSchemes: [$(GOOGLE_REVERSED_CLIENT_ID)]
    entitlements: { path: minimail/minimail.entitlements, properties: {} }
    scheme:
      testTargets:
        - minimailTests
        - { name: minimailUITests, parallelizable: false }
      gatherCoverageData: true
      environmentVariables: { MINIMAIL_TESTING: "1" }
  minimailTests:
    type: bundle.unit-test
    platform: iOS
    sources: [minimailTests]
    dependencies:
      - { target: minimail }
      - { package: SnapshotTesting, product: SnapshotTesting }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.newtelco.minimailTests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/minimail.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/minimail
        BUNDLE_LOADER: $(TEST_HOST)
  minimailUITests:
    type: bundle.ui-test
    platform: iOS
    sources: [minimailUITests]
    dependencies: [{ target: minimail }]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.newtelco.minimailUITests
        TEST_TARGET_NAME: minimail
```

Note: XcodeGen's `configFiles` at target level is valid per ProjectSpec; if the generator rejects a target-level `configFiles` together with project-level ones, fold `Google.xcconfig` into `Signing.xcconfig` with `#include "Google.xcconfig"`.

### 1.4 `Packages/MinimailCore/Package.swift`

```swift
// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "MinimailCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MinimailCore", targets: ["MinimailCore"]),
        .library(name: "MinimailHTML", targets: ["MinimailHTML"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
    ],
    targets: [
        .target(name: "MinimailCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MinimailHTML", dependencies: ["MinimailCore", "SwiftSoup"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MinimailCoreTests", dependencies: ["MinimailCore"], resources: [.copy("../Fixtures")]),
        .testTarget(name: "MinimailHTMLTests", dependencies: ["MinimailHTML"], resources: [.copy("../Fixtures")]),
    ]
)
```

Rules for the package: `import Foundation` only (no CoreFoundation, UIKit, WebKit, Security); no `@MainActor`; all public types `Sendable`. Regex usage via Swift `Regex` literals (available on Linux with Swift 6.1). `String(data:encoding:)` charsets limited to what Linux Foundation supports; the `Charsets.swift` table maps IANA names to `String.Encoding` and falls back to `.isoLatin1`.

### 1.5 Makefile targets (additions to `[tooling §2.7]`)

```make
test-core:
	cd Packages/MinimailCore && swift test --parallel
test-core-docker:            # from Linux without a Swift toolchain
	docker run --rm -v "$(PWD)":/src -w /src/Packages/MinimailCore swift:6.1 swift test
archive:                     # Release archive + TestFlight upload (needs ASC_* env vars)
	… (exact commands from tooling §6.2)
```

CI `ci.yml` job list: `core-linux` (ubuntu-latest, `swift:6.1` container, `swift test`), `ios-unit` (macos-26, `make test-unit`), `ios-ui` (macos-26, only on push to `main`). The Linux job runs first and gates the macOS job to save minutes.

---

## 2. Module map and public interfaces

### 2.1 Dependency direction

```
                    ┌────────────────────────────┐
                    │  App (composition root)    │
                    └──────────────┬─────────────┘
                                   │
        ┌──────────────────────────┼────────────────────────────┐
        ▼                          ▼                            ▼
  Features/* (SwiftUI)     Rendering (WebKit)              Theme, Settings
        │                          │                            │
        ▼                          ▼                            │
      Sync  ─────────────►  Store (GRDB)  ◄─────────────────────┘
        │                          │
        ▼                          │
      Gmail (URLSession)  ◄── Auth (AppAuth, Keychain)
        │
        ▼
  MinimailCore / MinimailHTML  (pure Swift; no dependency on anything above)
```

Rules (enforced by review, and by the package boundary for the bottom layer):
- Arrows point downward only. `Store` never imports `Sync`; `Gmail` never imports `Store`; `Features` never import `Gmail` directly (they talk to `SyncEngine`, `OutboxRepository`-backed actions and observe `Store`).
- `MinimailCore` contains every algorithm that can be tested without a device: it is the only place where MIME, headers, history reduction, label algebra and coalescing are implemented.
- All cross-actor types are `Sendable` structs. GRDB record structs are `Codable, FetchableRecord, PersistableRecord, Sendable` `[ios-platform §2.5]`.
- Isolation: `Features`, `Theme`, `Settings`, `Rendering`, `AuthStore`, `SyncStatus` are `@MainActor` (implicit via build setting). `SyncEngine`, `OutboxWorker`, `BodyLoader`, `GmailAPI`, `RateLimiter`, `AppAuthTokenProvider`, `InlineImageStore` are `actor`s. The package is nonisolated.

### 2.2 `MinimailCore` public interface

```swift
// Encoding/Base64URL.swift
public enum Base64URL {
    /// RFC 4648 §5 alphabet, single line, WITH '=' padding (matches Google's sample) [mime-rfc §1.2]
    public static func encode(_ data: Data) -> String
    /// Accepts padded/unpadded, '-_' and '+/' alphabets; nil on any other character.
    public static func decode(_ string: String) -> Data?
}

// Encoding/QuotedPrintable.swift
public enum QuotedPrintable {
    /// Input must already use CRLF line breaks. 76-col soft breaks, uppercase hex, trailing SP/TAB → =20/=09. [mime-rfc §3.3]
    public static func encode(_ utf8: Data) -> Data
    public static func decode(_ data: Data) -> Data   // tolerant: lowercase hex, lone '=', trailing whitespace
}

// Encoding/RFC2047.swift
public enum RFC2047 {
    /// Pure ASCII → unchanged; else B-encoded UTF-8 words ≤ 75 chars joined by CRLF SPACE when needed. [mime-rfc §2.3]
    public static func encodeHeaderText(_ text: String, firstLineOffset: Int) -> String
    /// Decodes encoded-words anywhere in an unstructured value; drops LWSP between adjacent encoded-words;
    /// concatenates bytes of adjacent same-charset words before charset decoding; unknown charset → left as-is.
    public static func decodeHeaderText(_ raw: String) -> String
}

// Encoding/RFC2231.swift
public enum RFC2231 {
    /// Resolves filename / filename*N / filename*N* / filename* into one value; extended form wins. [mime-rfc §2.4]
    public static func parameter(named name: String, in params: [(String, String)]) -> String?
    /// filename → ("filename=\"ascii-fallback\"", "filename*=UTF-8''%…") pair for output.
    public static func encodeFilenameParams(_ filename: String) -> String
}

// Encoding/Charsets.swift
public enum Charsets {
    public static func encoding(forIANA name: String) -> String.Encoding?   // strips "*lang"; case-insensitive; aliases
    public static func decode(_ data: Data, charset: String?) -> String      // charset → utf8 → isoLatin1 fallback chain
}

// Headers/Mailbox.swift
public struct Mailbox: Sendable, Codable, Hashable {
    public var name: String?     // RFC 2047-decoded display name, no quotes
    public var addr: String      // addr-spec, original case
    public init(name: String?, addr: String)
    public var key: String { addr.lowercased() }             // comparison key
    /// "Name <addr>" with quoting or RFC 2047 as needed; addr never encoded. [mime-rfc §2.2]
    public func serialized() -> String
    public var displayName: String { name ?? addr }
}

// Headers/AddressParser.swift
public enum AddressParser {
    /// RFC 5322 §3.4 tokenizer: quoted-strings, nested comments, groups (flattened), obs-route, legacy "addr (Name)". [mime-rfc §2.2, §8.4]
    public static func parseList(_ headerValue: String) -> [Mailbox]
    public static func parseFirst(_ headerValue: String) -> Mailbox?
}

// Headers/HeaderFolding.swift
public enum HeaderFolding {
    public static func unfold(_ raw: String) -> String                       // CRLF+WSP → single SP? no: removes CRLF, keeps WSP
    public static func foldAddressList(_ mailboxes: [Mailbox], fieldName: String) -> String   // "To: a,\r\n b" ≤ 78 per line
    public static func foldMessageIDs(_ ids: [String], fieldName: String) -> String
}

// Headers/RFC5322Date.swift
public enum RFC5322Date {
    public static func parse(_ value: String) -> Date?         // incl. 2-digit years, zone names, comments, missing seconds
    public static func format(_ date: Date, timeZone: TimeZone) -> String   // "Fri, 11 Sep 2026 10:00:00 +0200", en_US_POSIX
}

// Headers/ContentTypeParams.swift
public struct ContentTypeValue: Sendable, Equatable {
    public var type: String              // "text/html" lowercased
    public var params: [(String, String)] // raw (unquoted) k=v pairs in order, names lowercased
    public func param(_ name: String) -> String?
}
public enum ContentTypeParams { public static func parse(_ headerValue: String) -> ContentTypeValue }

// Headers/MessageIDs.swift
public enum MessageIDs {
    public static func split(_ referencesValue: String) -> [String]          // "<a> <b>" → ["<a>","<b>"], drops non-<…> tokens
    public static func normalize(_ id: String) -> String?                   // ensures <…>, trims
    public static func generate(domain: String) -> String                   // "<UUID@domain>"
}

// MIME/OutgoingMessage.swift
public struct OutgoingAttachment: Sendable, Equatable {
    public var filename: String; public var mimeType: String; public var data: Data
}
public struct OutgoingMessage: Sendable, Equatable {
    public var from: Mailbox
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var subject: String              // decoded text; builder RFC 2047-encodes
    public var date: Date
    public var timeZone: TimeZone
    public var messageID: String            // "<uuid@domain>"
    public var inReplyTo: String?
    public var references: [String]
    public var textBody: String             // "\n" line breaks; builder normalises to CRLF
    public var htmlBody: String             // full <html> document
    public var attachments: [OutgoingAttachment]
}

// MIME/Boundary.swift
public struct BoundaryGenerator: Sendable {
    public static let random: BoundaryGenerator                     // "=_minimail_<kind>_<16 hex>"
    public static func fixed(alt: String, mixed: String) -> BoundaryGenerator   // byte-exact tests
    public func boundary(kind: String) -> String
}

// MIME/MIMEBuilder.swift
public enum MIMEBuilder {
    /// RFC 5322/2045/2046 bytes, CRLF, header order fixed: From, To, Cc, Subject, Date, Message-ID, In-Reply-To, References, MIME-Version, Content-Type.
    /// Structure A (multipart/alternative) or B (multipart/mixed ⊃ alternative + attachments). [mime-rfc §3.1, §7]
    public static func build(_ message: OutgoingMessage, boundaries: BoundaryGenerator = .random) -> Data
}

// Compose/ReplyAll.swift
public struct ReplyAllInput: Sendable, Equatable {
    public var from: Mailbox?; public var replyTo: [Mailbox]; public var to: [Mailbox]; public var cc: [Mailbox]
    public var selfAddresses: Set<String>    // lowercased addr-specs: profile email ∪ sendAs aliases
}
public struct Recipients: Sendable, Equatable { public var to: [Mailbox]; public var cc: [Mailbox] }
public enum ReplyAll { public static func recipients(_ input: ReplyAllInput) -> Recipients }   // §7.1

// Compose/SubjectPrefix.swift
public enum SubjectPrefix {
    public static func reply(_ subject: String) -> String      // "Re: " unless hasPrefix("re:") case-insensitive
    public static func forward(_ subject: String) -> String    // "Fwd: " unless hasPrefix("fwd:")
    public static func stripForDisplay(_ subject: String) -> String   // repeated re:/fwd:/fw:/aw:/wg: prefixes → for thread title
}

// Compose/Quoting.swift
public struct QuoteSource: Sendable, Equatable {
    public var author: Mailbox; public var date: Date; public var subject: String
    public var to: [Mailbox]; public var cc: [Mailbox]
    public var html: String?     // quotable HTML fragment (already sanitized, data-src restored)
    public var text: String?     // plain text
}
public enum Quoting {
    public static func attributionLine(author: Mailbox, date: Date, timeZone: TimeZone) -> String
    // "On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice Müller <alice@example.com> wrote:" [mime-rfc §4.1]
    public static func replyHTML(_ src: QuoteSource, timeZone: TimeZone) -> String     // gmail_quote_container markup
    public static func replyText(_ src: QuoteSource, timeZone: TimeZone) -> String     // attribution + "> " lines
    public static func forwardHTML(_ src: QuoteSource, timeZone: TimeZone) -> String   // banner block, body not blockquoted [mime-rfc §4.2]
    public static func forwardText(_ src: QuoteSource, timeZone: TimeZone) -> String
    public static func textFromHTML(_ html: String) -> String   // crude tag-strip + entity decode for the text/plain alternative
}

// Compose/OutgoingHTML.swift
public enum OutgoingHTML {
    public static func escape(_ s: String) -> String
    /// <div class="minimail_default" style="…"> one <div> per line </div> + signature block + quote (outside the styled wrapper). [html-rendering §5.5]
    public static func body(text: String, style: ComposeStyle, signatureHTML: String?, quoteHTML: String?) -> String
    public static func document(bodyFragment: String) -> String   // <html><head><meta charset=utf-8></head><body>…</body></html>
    public static func plain(text: String, signatureText: String?, quoteText: String?) -> String
}

// Compose/ComposeStyle.swift  (as in html-rendering §5.4, minus signatureHTML which lives in Settings)
public struct ComposeStyle: Codable, Equatable, Sendable {
    public enum Family: String, Codable, CaseIterable, Sendable { case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        public var css: String; public var displayName: String }
    public var family: Family = .helvetica
    public var sizePx: Int = 14            // clamped 12…18
    public var colorHex: String = "#000000" // validated ^#[0-9a-f]{6}$
    public var inlineCSS: String
}

// Compose/ComposeDraft.swift
public struct ForwardAttachmentRef: Codable, Sendable, Equatable {
    public var messageId: String; public var partId: String; public var filename: String; public var mimeType: String; public var size: Int
}
public struct ComposeDraft: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case replyAll, forward }
    public var id: UUID
    public var kind: Kind
    public var sourceMessageId: String
    public var threadId: String
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var subject: String
    public var bodyText: String
    public var includeSignature: Bool
    public var attachments: [ForwardAttachmentRef]
    public var rfc822MessageId: String      // frozen when the draft is created
    public var quoteSource: QuoteSource     // snapshot of the original at compose time (so send works offline even if body cache is evicted)
    public var createdAt: Date
}

// Gmail/DTO/*.swift — Codable mirrors of the Discovery schema [gmail-api §5, §10, §11, §13]. All optional except ids.
public struct GmailMessagePartHeader: Codable, Sendable, Equatable { public var name: String; public var value: String }
public struct GmailMessagePartBody: Codable, Sendable, Equatable { public var attachmentId: String?; public var size: Int?; public var data: String? }
public struct GmailMessagePart: Codable, Sendable, Equatable {
    public var partId: String?; public var mimeType: String?; public var filename: String?
    public var headers: [GmailMessagePartHeader]?; public var body: GmailMessagePartBody?; public var parts: [GmailMessagePart]?
    public func header(_ name: String) -> String?   // case-insensitive, first match, unfolded
}
public struct GmailMessage: Codable, Sendable, Equatable {
    public var id: String; public var threadId: String?; public var labelIds: [String]?; public var snippet: String?
    public var historyId: StringUInt64?; public var internalDate: StringInt64?; public var sizeEstimate: Int?
    public var payload: GmailMessagePart?; public var raw: String?
}
public struct GmailThread: Codable, Sendable, Equatable { public var id: String; public var historyId: StringUInt64?; public var snippet: String?; public var messages: [GmailMessage]? }
public struct GmailLabelColor: Codable, Sendable, Equatable { public var textColor: String?; public var backgroundColor: String? }
public struct GmailLabel: Codable, Sendable, Equatable {
    public var id: String; public var name: String; public var type: String?
    public var messageListVisibility: String?; public var labelListVisibility: String?
    public var messagesTotal: Int?; public var messagesUnread: Int?; public var threadsTotal: Int?; public var threadsUnread: Int?
    public var color: GmailLabelColor?
}
public struct GmailListLabelsResponse: Codable, Sendable { public var labels: [GmailLabel]? }
public struct GmailMessageRef: Codable, Sendable, Equatable { public var id: String; public var threadId: String?; public var labelIds: [String]? }
public struct GmailListMessagesResponse: Codable, Sendable { public var messages: [GmailMessageRef]?; public var nextPageToken: String?; public var resultSizeEstimate: Int? }
public struct GmailHistoryMessageChange: Codable, Sendable, Equatable { public var message: GmailMessageRef }
public struct GmailHistoryLabelChange: Codable, Sendable, Equatable { public var message: GmailMessageRef; public var labelIds: [String]? }
public struct GmailHistory: Codable, Sendable, Equatable {
    public var id: StringUInt64; public var messages: [GmailMessageRef]?
    public var messagesAdded: [GmailHistoryMessageChange]?; public var messagesDeleted: [GmailHistoryMessageChange]?
    public var labelsAdded: [GmailHistoryLabelChange]?; public var labelsRemoved: [GmailHistoryLabelChange]?
}
public struct GmailListHistoryResponse: Codable, Sendable, Equatable { public var history: [GmailHistory]?; public var nextPageToken: String?; public var historyId: StringUInt64? }
public struct GmailProfile: Codable, Sendable, Equatable { public var emailAddress: String; public var messagesTotal: Int?; public var threadsTotal: Int?; public var historyId: StringUInt64 }
public struct GmailSendAs: Codable, Sendable, Equatable { public var sendAsEmail: String; public var displayName: String?; public var replyToAddress: String?; public var signature: String?; public var isPrimary: Bool?; public var isDefault: Bool?; public var verificationStatus: String? }
public struct GmailListSendAsResponse: Codable, Sendable { public var sendAs: [GmailSendAs]? }
public struct GmailErrorEnvelope: Codable, Sendable, Equatable {
    public struct Inner: Codable, Sendable, Equatable { public struct Item: Codable, Sendable, Equatable { public var reason: String?; public var message: String?; public var domain: String? }
        public var code: Int?; public var message: String?; public var status: String?; public var errors: [Item]? }
    public var error: Inner
    public var primaryReason: String?   // errors[0].reason
}
/// JSON strings holding integers; decoding also tolerates a bare JSON number. [gmail-api "Common facts"]
public struct StringUInt64: Codable, Sendable, Equatable, Comparable { public var value: UInt64 }
public struct StringInt64: Codable, Sendable, Equatable, Comparable { public var value: Int64 }

// Gmail/PayloadParser.swift
public struct ParsedHeaders: Sendable, Equatable {
    public var subject: String; public var from: Mailbox?; public var replyTo: [Mailbox]; public var to: [Mailbox]; public var cc: [Mailbox]
    public var date: String?; public var messageID: String?; public var inReplyTo: String?; public var references: [String]
    public var listUnsubscribe: String?; public var contentType: ContentTypeValue?
}
public struct ParsedAttachment: Sendable, Equatable {
    public var partId: String; public var filename: String; public var mimeType: String; public var size: Int
    public var contentId: String?; public var attachmentId: String?; public var inlineData: Data?   // small parts delivered inline
}
public struct ParsedMessage: Sendable, Equatable {
    public var headers: ParsedHeaders
    public var html: String?; public var text: String?
    public var deferredTextParts: [ParsedAttachment]   // text parts delivered with attachmentId only
    public var attachments: [ParsedAttachment]         // everything fetchable (incl. inline images)
    public var inlineByContentID: [String: ParsedAttachment]
}
public enum PayloadParser {
    public static func headers(_ payload: GmailMessagePart) -> ParsedHeaders                // works for format=metadata
    public static func parse(_ message: GmailMessage) -> ParsedMessage                       // format=full [mime-rfc §5.2]
    public static func decodeText(_ part: GmailMessagePart) -> String?                       // base64url → charset decode → "\n"
}

// Gmail/Batch/*.swift  [gmail-api §12]
public struct BatchCall: Sendable, Equatable {
    public var id: String                 // Content-ID (without <>)
    public var method: String             // GET/POST
    public var path: String               // "/gmail/v1/users/me/…?…" host-relative
    public var jsonBody: Data?
}
public struct BatchPart: Sendable, Equatable {
    public var id: String                 // from "<response-ID>"
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data
}
public enum BatchRequestEncoder {
    public static func encode(_ calls: [BatchCall], boundary: String) -> Data
    public static func makeBoundary() -> String   // "batch_minimail_<16hex>"
}
public enum BatchResponseParser {
    public struct ParseError: Error, Sendable, Equatable { public var reason: String }
    public static func boundary(fromContentType ct: String) -> String?
    public static func parse(_ body: Data, boundary: String) throws(ParseError) -> [BatchPart]
}

// Sync/LabelAlgebra.swift
public struct LabelDelta: Codable, Sendable, Equatable {
    public var add: Set<String>; public var remove: Set<String>
    public var isEmpty: Bool
    public func applied(to labels: Set<String>) -> Set<String>     // (labels − remove) ∪ add
}
public struct DerivedFlags: Sendable, Equatable { public var isUnread: Bool; public var inInbox: Bool; public var isHidden: Bool }
public enum LabelAlgebra {
    public static func effective(server: Set<String>, pending: [LabelDelta]) -> Set<String>
    public static func flags(_ labels: Set<String>) -> DerivedFlags   // hidden = TRASH ∨ SPAM ∨ DRAFT ∨ CHAT
    public static func sortedJSON(_ labels: Set<String>) -> String    // deterministic storage form
}

// Sync/HistoryReducer.swift
public struct HistoryChanges: Sendable, Equatable {
    public var added: [String: GmailMessageRef]          // messages added (net of later deletes)
    public var deleted: Set<String>
    public var labelOps: [String: [LabelDelta]]          // per message id, chronological, excluding deleted/added-then-deleted
    public var finalLabels: [String: Set<String>]        // when any record carried message.labelIds, the LAST seen full set
    public var touchedThreads: Set<String>
    public var recordCount: Int
    public var newHistoryId: UInt64?
}
public enum HistoryReducer { public static func reduce(_ pages: [GmailListHistoryResponse]) -> HistoryChanges }

// Sync/OutboxCoalescer.swift
public enum OutboxCoalescer {
    /// add = (existing.add − new.remove) ∪ new.add ; remove = (existing.remove − new.add) ∪ new.remove
    public static func merge(existing: LabelDelta, new: LabelDelta) -> LabelDelta
}

// Sync/Backoff.swift
public struct Backoff: Sendable, Equatable {
    public var base: TimeInterval = 1, factor: Double = 2, cap: TimeInterval = 32, jitter: Double = 0.25
    public func delay(attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval   // random ∈ [0,1) injected for tests
    public static let transient: Backoff           // 1s → 32s cap (in-request retries)
    public static let outbox: Backoff              // 2s → 300s cap (between drain attempts)
}

// Sync/QuotaTable.swift
public enum QuotaTable {   // pessimistic 2026 figures [gmail-api "Quotas"]
    public static func units(for method: GmailMethod) -> Int
    public static let perUserPerMinute = 6_000
}
public enum GmailMethod: Sendable { case getProfile, listLabels, getLabel, listMessages, getMessage, getAttachment, modifyMessage, modifyThread, batchModify, listHistory, send, listSendAs, getThread, listThreads }

// Sync/HydrationPolicy.swift
public struct HydrationScope: Sendable, Equatable { public var cachedLabelIds: Set<String>; public var knownThreadIds: Set<String> }
public enum HydrationPolicy {
    /// true if the unknown message should be fetched during delta sync (§4.3 rule)
    public static func shouldFetch(ref: GmailMessageRef, scope: HydrationScope) -> Bool
}

// Support/TodayRange.swift
public enum TodayRange { public static func startOfTodayMillis(now: Date, timeZone: TimeZone, calendar: Calendar) -> Int64 }

// Support/ThreadAggregate.swift
public struct AggregateInput: Sendable, Equatable {   // one visible message
    public var id: String; public var internalDate: Int64; public var snippet: String; public var subject: String
    public var from: Mailbox?; public var isUnread: Bool; public var inInbox: Bool; public var hasAttachmentHint: Bool; public var isFromSelf: Bool
}
public struct ThreadAggregate: Sendable, Equatable {
    public var subject: String; public var snippet: String; public var lastDate: Int64; public var firstDate: Int64
    public var messageCount: Int; public var unreadCount: Int; public var inInbox: Bool; public var hasAttachments: Bool
    public var participantsJSON: String   // [{"n":"Alice","a":"alice@…","s":false}] deduped, chronological
}
public enum ThreadAggregator { public static func aggregate(_ messages: [AggregateInput], selfAddresses: Set<String>) -> ThreadAggregate? }  // nil if empty
```

### 2.3 `MinimailHTML` public interface

```swift
public enum DarkStrategy: String, Sendable, Codable { case plain, card, native }
public struct SanitizedBody: Sendable, Equatable {
    public var html: String; public var hasRemoteImages: Bool; public var darkStrategy: DarkStrategy; public var referencedContentIDs: Set<String>
}
public enum Sanitizer {
    public static let version: Int = 1
    public static func sanitize(rawHTML: String, messageId: String) throws -> SanitizedBody      // §9.1
    public static func plainTextToHTML(_ text: String) -> String                                // escape + linkify + <div> per line
}
public enum SignatureSanitizer { public static func sanitize(_ html: String) throws -> String }     // keeps https img src; drops scripts/forms
public enum QuoteExtractor {
    /// body_html → HTML for quoting in a reply/forward: data-src → src, mm-remote class removed, minimail-cid:// → cid:, placeholder GIF removed.
    public static func quotable(_ sanitizedHTML: String) -> String
}
```

### 2.4 App-target module interfaces

```swift
// Auth/TokenProvider.swift
protocol TokenProvider: Sendable {
    func accessToken() async throws -> String          // fresh; performs refresh if needed (single-flight)
    func invalidateAccessToken() async                 // call after a 401; next accessToken() forces refresh
}
enum AuthError: Error, Sendable, Equatable { case signedOut, needsReauth(String?), userCancelled, flowFailed(String), keychain(OSStatus), accountMismatch(expected: String, got: String) }

// Auth/AppAuthTokenProvider.swift
actor AppAuthTokenProvider: TokenProvider {
    init(keychain: KeychainStore)
    func load() async -> Bool                                          // restores OIDAuthState; true if authorized
    func adopt(_ state: sending OIDAuthState) async throws             // after interactive sign-in; persists
    func accessToken() async throws -> String
    func invalidateAccessToken() async
    func revokeAndClear() async                                        // POST /revoke (best effort) + keychain delete
    var onNeedsReauth: (@Sendable () -> Void)?                         // invoked on invalid_grant
}

// Auth/AuthStore.swift
@Observable @MainActor final class AuthStore {
    enum State: Equatable { case loading, signedOut, signedIn(email: String), needsReauth(email: String) }
    private(set) var state: State
    var currentFlow: OIDExternalUserAgentSession?
    func bootstrap() async
    func signIn(from vc: UIViewController) async throws               // AppAuth flow, profile fetch, account check
    func signOut() async                                               // revoke, wipe keychain, wipe DB, reset stores
    func resume(url: URL) -> Bool                                      // onOpenURL fallback
}

// Auth/KeychainStore.swift
struct KeychainStore: Sendable {
    let service: String     // "de.newtelco.minimail"
    func set(_ data: Data, account: String) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
}

// Gmail/HTTPTransport.swift
protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
final class URLSessionTransport: HTTPTransport { init(session: URLSession = .minimail) }   // ephemeral config, timeouts 30s/120s, waitsForConnectivity=false

// Gmail/GmailError.swift
enum GmailError: Error, Sendable, Equatable {
    case offline                                  // URLError .notConnectedToInternet / .networkConnectionLost / .dataNotAllowed
    case network(code: Int)                       // other URLError codes (timeouts etc.)
    case unauthenticated                          // 401
    case forbidden(reason: String?)               // 403 non-quota (admin_policy, insufficientPermissions…)
    case rateLimited(retryAfter: TimeInterval?, reason: String?)   // 429, or 403 with quota reasons
    case notFound                                 // 404
    case badRequest(reason: String?, message: String?)             // 400
    case payloadTooLarge                          // 413
    case conflict                                 // 409/412
    case server(status: Int)                      // 5xx
    case decoding(String)
    case batchMalformed
    case cancelled
    var isTransient: Bool          // offline, network, rateLimited, server, batchMalformed
    var countsAsAttempt: Bool      // everything except offline & cancelled
    static func map(status: Int, body: Data, headers: [AnyHashable: Any]) -> GmailError
    static func map(_ urlError: URLError) -> GmailError
}

// Gmail/GmailAPI.swift
enum MessageFormat: String, Sendable { case minimal, full, raw, metadata }
struct ModifyCall: Sendable, Equatable { var opId: String; var target: OutboxTarget; var add: [String]; var remove: [String] }
enum OutboxTarget: Sendable, Equatable, Codable { case message(String), thread(String) }
actor GmailAPI {
    static let metadataHeaders = ["From","To","Cc","Reply-To","Subject","Date","Message-ID","In-Reply-To","References","List-Unsubscribe","Content-Type"]
    init(transport: HTTPTransport, tokens: TokenProvider, limiter: RateLimiter, clock: @Sendable () -> Date = Date.init)
    func getProfile() async throws -> GmailProfile
    func listLabels() async throws -> [GmailLabel]
    func getLabels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>]              // HTTP batch
    func listMessages(labelIds: [String], q: String?, maxResults: Int, pageToken: String?) async throws -> GmailListMessagesResponse
    func getMessage(id: String, format: MessageFormat) async throws -> GmailMessage
    func getMessages(ids: [String], format: MessageFormat) async throws -> [String: Result<GmailMessage, GmailError>]   // batches of ≤25
    func getThread(id: String, format: MessageFormat) async throws -> GmailThread
    func getAttachment(messageId: String, attachmentId: String) async throws -> GmailMessagePartBody
    func modify(_ calls: [ModifyCall]) async throws -> [String: Result<[String: [String]], GmailError>]   // opId → (messageId → labelIds) per part
    func listHistory(startHistoryId: UInt64, pageToken: String?, maxResults: Int) async throws -> GmailListHistoryResponse
    func send(raw: Data, threadId: String?) async throws -> GmailMessage            // JSON path
    func sendUpload(rfc822: Data, threadId: String?) async throws -> GmailMessage   // multipart upload path (> 5 MB)
    func listSendAs() async throws -> [GmailSendAs]
}

// Gmail/RateLimiter.swift
actor RateLimiter {
    init(unitsPerSecond: Double = 80, burst: Int = 400, maxConcurrent: Int = 3)
    func acquire(units: Int) async      // waits for tokens and a concurrency slot
    func release()
}

// Store/Database.swift
enum Database {
    static func open(at url: URL) throws -> DatabasePool           // Application Support/minimail-db/db.sqlite, WAL, FileProtection .completeUntilFirstUserAuthentication
    static func inMemory() throws -> DatabaseQueue                 // tests
    static func wipe(at url: URL) throws
}
// Store/Records/*.swift — see §3 for columns. Each: struct XRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable

// Store/Repositories (all are structs of static funcs taking `Database` — GRDB's db connection — so they compose inside one transaction)
enum MessageRepository {
    static func upsertMetadata(_ db: Database, parsed: [(GmailMessage, ParsedHeaders)], selfAddresses: Set<String>, now: Date) throws -> Set<String>   // returns touched thread ids
    static func applyServerLabels(_ db: Database, messageId: String, labels: Set<String>) throws
    static func applyServerDelta(_ db: Database, messageId: String, delta: LabelDelta) throws
    static func recomputeEffective(_ db: Database, messageIds: Set<String>) throws -> Set<String>   // reads outbox; returns touched thread ids
    static func delete(_ db: Database, ids: Set<String>) throws -> Set<String>
    static func idsExisting(_ db: Database, among ids: [String]) throws -> Set<String>
}
enum ThreadRepository {
    static func recomputeAggregates(_ db: Database, threadIds: Set<String>, selfAddresses: Set<String>) throws   // deletes empty threads
    static func markComplete(_ db: Database, threadId: String) throws
    static func messageIds(_ db: Database, threadId: String) throws -> [String]
}
enum LabelRepository { static func replaceAll(_ db: Database, labels: [GmailLabel]) throws; static func updateCounts(_ db: Database, labels: [GmailLabel], now: Date) throws; static func markCachedView(_ db: Database, labelId: String, pageToken: String?, now: Date) throws }
enum BodyRepository { static func store(_ db: Database, messageId: String, body: SanitizedBody?, text: String?, attachments: [ParsedAttachment], now: Date) throws; static func touch(_ db: Database, messageId: String, now: Date) throws; static func missingBodyIds(_ db: Database, threadId: String) throws -> [String] }
enum OutboxRepository {
    static func enqueueModify(_ db: Database, target: OutboxTarget, delta: LabelDelta, affectedMessageIds: [String], now: Date) throws -> String?   // coalesces; returns op id (nil if cancelled out)
    static func enqueueSend(_ db: Database, draft: ComposeDraft, now: Date) throws -> String
    static func claimBatch(_ db: Database, kind: OutboxKind, limit: Int, now: Date) throws -> [OutboxRecord]        // pending & due → in_flight
    static func ack(_ db: Database, opId: String, serverLabelsByMessage: [String: [String]]?) throws -> Set<String>  // applies delta to server_label_ids, deletes op, recomputes effective; returns touched threads
    static func retryLater(_ db: Database, opId: String, error: GmailError, backoff: Backoff, now: Date) throws
    static func fail(_ db: Database, opId: String, error: GmailError) throws                                        // state=failed (user-visible)
    static func discard(_ db: Database, opId: String) throws -> Set<String>                                          // deletes op, recomputes effective (reverts optimistic state)
    static func pendingDeltas(_ db: Database, messageId: String) throws -> [LabelDelta]
    static func releaseInFlight(_ db: Database) throws                                                              // at launch: in_flight → pending
}
enum SyncStateRepository { static func get(_ db: Database, _ key: SyncKey) throws -> String?; static func set(_ db: Database, _ key: SyncKey, _ value: String?) throws }
enum SyncKey: String { case historyId, syncGeneration, lastFullSyncAt, lastDeltaSyncAt, lastReconcileAt, accountEmail, displayName, sendAsJSON, inboxNextPageToken, unreadViewFetchedAt, schemaNote }

// Store/Queries/ThreadListQuery.swift
struct ThreadRowDTO: Codable, FetchableRecord, Sendable, Identifiable, Equatable { … §8.3 }
enum ThreadListQuery {
    static func request(_ filter: InboxFilter, unreadOnly: Bool, startOfTodayMs: Int64, limit: Int) -> SQLRequest<ThreadRowDTO>
    static func inboxUnreadThreadCount(_ db: Database) throws -> Int
}

// Sync/SyncEngine.swift
enum SyncReason: Sendable, Equatable { case launch, foreground, pullToRefresh, background, afterOutbox, labelOpened(String), unreadViewOpened, loadOlderInbox, threadOpened(String) }
actor SyncEngine {
    init(db: DatabasePool, api: GmailAPI, status: SyncStatus, settings: SettingsStore, clock: @Sendable () -> Date)
    func run(_ reason: SyncReason) async                    // coalesces concurrent requests; never throws; reports via SyncStatus
    func ensureThreadComplete(_ threadId: String) async     // ThreadCompleter + BodyLoader for the thread
    func loadBodies(messageIds: [String]) async
    func requestFullResync() async                          // Settings → Diagnostics
}
@Observable @MainActor final class SyncStatus {
    enum Phase: Equatable { case idle, syncing(String), initialSync(progress: Double) }
    var phase: Phase = .idle
    var isOffline = false
    var lastError: PresentableError?          // {title, message, retryable}
    var lastSuccessfulSync: Date?
    var pendingOps = 0, failedSends = 0
}

// Sync/OutboxWorker.swift
actor OutboxWorker {
    init(db: DatabasePool, api: GmailAPI, status: SyncStatus, network: NetworkMonitor, clock: @Sendable () -> Date)
    func kick()                              // debounced 300 ms; starts drain if not running
    func drainNow() async                    // used by BG refresh (awaits completion)
    func retry(opId: String) async; func discard(opId: String) async
}

// Rendering
@MainActor final class WebViewPool { static let shared: WebViewPool; func prepare() async; func dequeue() -> WKWebView; func recycle(_ v: WKWebView) }
struct MailWebView: UIViewRepresentable { let document: ThreadDocument; let theme: ThemeTokens; let bridge: WebBridge }
struct ThreadDocument: Equatable, Sendable { var html: String; var allowsRemoteImages: Bool; var revision: Int }
enum ThreadDocumentBuilder { static func build(detail: ThreadDetailDTO, expanded: Set<String>, imagesAllowed: Set<String>, theme: ThemeTokens, settings: Settings) -> ThreadDocument }
@MainActor final class WebBridge: NSObject, WKScriptMessageHandler { var onToggle: (String) -> Void; var onLoadImages: (String) -> Void; var onOpenAttachment: (String, String) -> Void; var onTapLink: (URL) -> Void }
actor InlineImageStore { func bytes(messageId: String, contentId: String) async throws -> (Data, String) }
actor AttachmentFileCache { func fileURL(messageId: String, partId: String, filename: String) async throws -> URL }   // downloads if missing; re-resolves attachmentId

// Theme / Settings: see §10, §11
```

---

## 3. Data model (SQLite via GRDB)

### 3.1 Decisions

- One `DatabasePool` (WAL) at `Application Support/minimail-db/db.sqlite` `[ios-platform §2.2]`; the directory gets `FileProtectionType.completeUntilFirstUserAuthentication` so BG refresh after first unlock can write (if the attribute call fails, log and continue — the BG handler already tolerates `SQLITE_AUTH`/`SQLITE_IOERR` by ending early).
- Schema is created with **raw SQL** inside `DatabaseMigrator.registerMigration("v1")` so the executed DDL is exactly what this document says (no GRDB DSL translation surprises). `foreign_keys` ON. `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true`.
- Records are `Codable` structs; JSON-array columns are stored as **sorted** JSON strings (`LabelAlgebra.sortedJSON`) so equality and `ValueObservation` change detection are exact `[ios-platform §2.4]`.
- Label membership is duplicated into a join table (`message_label`) so label filtering is an indexed join, never `LIKE` on JSON.
- Bodies live in a separate table so list queries never touch large TEXT columns.

### 3.2 DDL (migration `v1`)

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE label (
  id                       TEXT PRIMARY KEY NOT NULL,
  name                     TEXT NOT NULL,
  type                     TEXT NOT NULL CHECK (type IN ('system','user')),
  message_list_visibility  TEXT,                      -- 'show' | 'hide' | NULL
  label_list_visibility    TEXT,                      -- 'labelShow' | 'labelShowIfUnread' | 'labelHide' | NULL
  text_color               TEXT,                      -- '#rrggbb' (user labels only)
  background_color         TEXT,
  messages_total           INTEGER,                   -- from labels.get; NULL until fetched
  messages_unread          INTEGER,
  threads_total            INTEGER,
  threads_unread           INTEGER,
  counts_fetched_at        REAL,                      -- unix seconds
  sort_order               INTEGER NOT NULL DEFAULT 1000,
  cached_view_at           REAL,                      -- non-NULL once this label's message list was fetched (label view cached)
  cached_view_page_token   TEXT
);

CREATE TABLE thread (
  id               TEXT PRIMARY KEY NOT NULL,
  subject          TEXT NOT NULL DEFAULT '',          -- earliest visible message's decoded subject, prefixes stripped for display
  snippet          TEXT NOT NULL DEFAULT '',          -- newest visible message's snippet
  last_date        INTEGER NOT NULL,                  -- max(internal_date) of visible messages, epoch ms
  first_date       INTEGER NOT NULL,
  message_count    INTEGER NOT NULL,                  -- visible (is_hidden = 0) messages known locally
  unread_count     INTEGER NOT NULL,
  is_unread        INTEGER NOT NULL,                  -- unread_count > 0
  in_inbox         INTEGER NOT NULL,                  -- any visible message has INBOX (effective)
  has_attachments  INTEGER NOT NULL,
  participants     TEXT NOT NULL DEFAULT '[]',        -- JSON [{"n":name,"a":addr,"s":isSelf}], chronological, deduped by addr
  is_complete      INTEGER NOT NULL DEFAULT 0,        -- 1 after threads.get metadata succeeded (all messages known)
  updated_at       REAL NOT NULL
);
CREATE INDEX thread_inbox_date  ON thread(in_inbox, last_date DESC);
CREATE INDEX thread_unread_date ON thread(is_unread, last_date DESC);
CREATE INDEX thread_last_date   ON thread(last_date DESC);

CREATE TABLE message (
  id                  TEXT PRIMARY KEY NOT NULL,
  thread_id           TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
  internal_date       INTEGER NOT NULL,               -- epoch ms (Gmail internalDate)
  history_id          TEXT,                           -- last known Message.historyId (informational)
  size_estimate       INTEGER,
  snippet             TEXT NOT NULL DEFAULT '',
  subject             TEXT NOT NULL DEFAULT '',       -- RFC 2047-decoded, verbatim (prefix kept)
  from_name           TEXT,
  from_addr           TEXT,
  reply_to            TEXT NOT NULL DEFAULT '[]',     -- JSON [Mailbox]
  to_list             TEXT NOT NULL DEFAULT '[]',
  cc_list             TEXT NOT NULL DEFAULT '[]',
  date_header         TEXT,                           -- raw Date header
  message_id_header   TEXT,                           -- '<…>' normalised
  in_reply_to         TEXT,
  references_json     TEXT NOT NULL DEFAULT '[]',     -- JSON [String] of '<…>' ids
  list_unsubscribe    TEXT,
  top_mime_type       TEXT,                           -- payload.mimeType (metadata format) → attachment hint
  server_label_ids    TEXT NOT NULL DEFAULT '[]',     -- sorted JSON: last state told by the server
  label_ids           TEXT NOT NULL DEFAULT '[]',     -- sorted JSON: EFFECTIVE = server ⊕ pending outbox deltas
  is_unread           INTEGER NOT NULL,               -- derived from label_ids (UNREAD ∈)
  in_inbox            INTEGER NOT NULL,               -- derived (INBOX ∈)
  is_hidden           INTEGER NOT NULL,               -- derived (TRASH ∨ SPAM ∨ DRAFT ∨ CHAT ∈)
  is_from_self        INTEGER NOT NULL DEFAULT 0,
  attachment_hint     INTEGER NOT NULL DEFAULT 0,     -- top_mime_type = multipart/mixed (before body fetch)
  fetched_at          REAL NOT NULL,
  sync_generation     INTEGER NOT NULL                -- generation of the full sync that (re)wrote this row (§4.2)
);
CREATE INDEX message_thread_date  ON message(thread_id, internal_date);
CREATE INDEX message_date         ON message(internal_date DESC);
CREATE INDEX message_inbox_unread ON message(in_inbox, is_unread);
CREATE INDEX message_msgid_header ON message(message_id_header);

CREATE TABLE message_label (                          -- mirrors message.label_ids (effective) for indexed filtering
  message_id  TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  label_id    TEXT NOT NULL,
  PRIMARY KEY (message_id, label_id)
) WITHOUT ROWID;
CREATE INDEX message_label_by_label ON message_label(label_id, message_id);

CREATE TABLE message_body (
  message_id         TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  body_html          TEXT,                            -- sanitized fragment; NULL when the mail had no text/html part
  body_text          TEXT,                            -- decoded text/plain; NULL when absent
  has_remote_images  INTEGER NOT NULL DEFAULT 0,
  dark_strategy      TEXT NOT NULL DEFAULT 'plain' CHECK (dark_strategy IN ('plain','card','native')),
  sanitizer_version  INTEGER NOT NULL,
  byte_size          INTEGER NOT NULL,                -- length(body_html)+length(body_text), for cache accounting
  fetched_at         REAL NOT NULL,
  last_opened_at     REAL NOT NULL
);
CREATE INDEX message_body_lru ON message_body(last_opened_at);

CREATE TABLE attachment (
  message_id     TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  part_id        TEXT NOT NULL,
  filename       TEXT NOT NULL,                       -- decoded; sanitised for the file system at use time
  mime_type      TEXT NOT NULL,
  size           INTEGER NOT NULL,
  content_id     TEXT,                                -- without <>
  is_inline      INTEGER NOT NULL DEFAULT 0,          -- referenced by cid: in body_html
  attachment_id  TEXT,                                -- TRANSIENT; NULL-able; re-resolved via messages.get when a fetch 404s [gmail-api §6]
  PRIMARY KEY (message_id, part_id)
);

CREATE TABLE outbox (
  id                     TEXT PRIMARY KEY NOT NULL,   -- UUID string
  seq                    INTEGER NOT NULL,            -- monotonic (max(seq)+1 at insert) → FIFO order & delta ordering
  kind                   TEXT NOT NULL CHECK (kind IN ('modify','send')),
  state                  TEXT NOT NULL CHECK (state IN ('pending','in_flight','failed')),
  created_at             REAL NOT NULL,
  updated_at             REAL NOT NULL,
  attempts               INTEGER NOT NULL DEFAULT 0,
  next_attempt_at        REAL NOT NULL DEFAULT 0,
  last_error             TEXT,                        -- GmailError description (user-presentable)
  -- kind = 'modify'
  target_kind            TEXT CHECK (target_kind IN ('message','thread')),
  target_id              TEXT,
  add_label_ids          TEXT,                        -- sorted JSON
  remove_label_ids       TEXT,                        -- sorted JSON
  affected_message_ids   TEXT,                        -- JSON: messages the delta applies to locally (snapshot at enqueue; refreshed on coalesce)
  -- kind = 'send'
  draft_json             TEXT,                        -- ComposeDraft
  rfc822_message_id      TEXT,                        -- '<uuid@domain>'
  transmit_state         TEXT CHECK (transmit_state IN ('not_sent','maybe_sent','sent')),
  sent_gmail_id          TEXT
);
CREATE UNIQUE INDEX outbox_seq     ON outbox(seq);
CREATE INDEX outbox_due            ON outbox(state, next_attempt_at);
CREATE INDEX outbox_target         ON outbox(target_kind, target_id);

CREATE TABLE sync_state (
  key    TEXT PRIMARY KEY NOT NULL,
  value  TEXT NOT NULL
) WITHOUT ROWID;
```

`sync_state` keys: `historyId` (decimal string), `syncGeneration` (int), `lastFullSyncAt`, `lastDeltaSyncAt`, `lastReconcileAt` (unix seconds), `accountEmail`, `displayName`, `sendAsJSON` (JSON `[GmailSendAs]`), `inboxNextPageToken` (for "load older"), `unreadViewFetchedAt`, `schemaNote`.

### 3.3 Gmail → column mapping

| Gmail field | Column | Transform |
|---|---|---|
| `Message.id`, `threadId` | `message.id`, `thread_id` | verbatim |
| `internalDate` (string int64 ms) | `internal_date` | `StringInt64` |
| `historyId` (string uint64) | `history_id` | kept as decimal string |
| `sizeEstimate` | `size_estimate` | int |
| `snippet` | `snippet` | HTML entities decoded (Gmail snippets contain `&#39;` etc.) |
| `labelIds` (from get/history/modify) | `server_label_ids` | sorted JSON; then `label_ids` = effective, flags derived, `message_label` rewritten |
| `payload.headers[Subject]` | `subject` | `RFC2047.decodeHeaderText`, unfolded, trimmed |
| `From` | `from_name`, `from_addr`, `is_from_self` | `AddressParser.parseFirst`; self = addr ∈ selfAddresses |
| `Reply-To`, `To`, `Cc` | `reply_to`, `to_list`, `cc_list` | `AddressParser.parseList` → JSON `[Mailbox]` |
| `Date` | `date_header` | raw; UI uses `internal_date` for ordering and display |
| `Message-ID`, `In-Reply-To`, `References` | `message_id_header`, `in_reply_to`, `references_json` | normalised `<…>` tokens |
| `List-Unsubscribe` | `list_unsubscribe` | raw (unused in UI, kept for stage 2) |
| `payload.mimeType` | `top_mime_type`, `attachment_hint` | hint = `multipart/mixed` |
| `format=full` parts | `message_body.*`, `attachment.*` | `PayloadParser.parse` → `Sanitizer.sanitize` |
| `Label.*` | `label.*` | `color.textColor/backgroundColor` → `text_color/background_color`; counts from `labels.get` only |
| `Profile.emailAddress`, `historyId` | `sync_state.accountEmail`, `historyId` | |
| `SendAs[]` | `sync_state.sendAsJSON` | display name for `From:`, aliases for self-dedupe, signature import source |

`is_hidden` also covers `DRAFT` and `CHAT` because such messages are noise in a reading client; they are still stored (history may reference them) but excluded from every view and aggregate.

### 3.4 Not stored (deliberately)

- Raw RFC 5322 bytes, un-sanitized HTML, `payload` JSON (only the parsed projection above).
- Attachment bytes (file cache in `Caches/attachments/<messageId>/<partId>/<filename>`, purgeable) and `attachmentId` as a durable key (transient column, re-resolved).
- OAuth tokens (Keychain), settings (UserDefaults), theme.
- `resultSizeEstimate`, `messagesTotal/threadsTotal` of the profile.
- Gmail drafts (stage 1 has no drafts UI; unsent minimail drafts are outbox rows, not Gmail drafts).
- Per-message read-timestamps, analytics, logs (os_log only).
- Full mailbox: only INBOX (paged), UNREAD (once opened), cached label views, threads touched by delta sync, and threads completed on open. Bounded by the pruner (§4.9).

### 3.5 Invariants (checked by `DatabaseInvariantTests` on every test database)

1. `message.label_ids == LabelAlgebra.effective(server_label_ids, pendingDeltas(message))` for every message.
2. `message.is_unread/in_inbox/is_hidden == LabelAlgebra.flags(label_ids)`.
3. `message_label` rows == the set in `message.label_ids`.
4. Every `thread` row has ≥ 1 visible message and its aggregate columns equal `ThreadAggregator.aggregate(visibleMessages)`.
5. `outbox.seq` strictly increasing with `created_at`; no two `pending` modify ops share `(target_kind, target_id)`.
6. `sync_state.historyId` is only ever set to a value ≥ the previous one, except by a full resync (which bumps `syncGeneration`).

---

## 4. Sync engine

### 4.1 Overview and coordination

```
SyncEngine (actor)
  ├─ run(reason)  ── single-flight: if a run is active, remember "rerun requested" and return; the active run loops once more at its end
  │     ├─ if no historyId          → FullSync → DeltaSync(from baseline) → LabelSync → OutboxWorker.kick()
  │     ├─ else                     → DeltaSync → LabelSync (counts) → OutboxWorker.kick()
  │     ├─ reason-specific extras   → labelOpened → hydrate label view; unreadViewOpened → hydrate UNREAD; loadOlderInbox → next page; threadOpened → ThreadCompleter + BodyLoader
  │     └─ daily                    → Reconciler (visible messages' labelIds, format=minimal)
  ├─ ensureThreadComplete(id)
  ├─ loadBodies(ids)               → BodyLoader
  └─ requestFullResync()           → clears historyId, bumps syncGeneration, run(.launch)
```

Triggers (`AppLifecycle.swift`): app launch (`.launch`), `scenePhase == .active` if last delta > 60 s ago (`.foreground`), pull-to-refresh (always), `NetworkMonitor` path satisfied after being unsatisfied (`.foreground` semantics), BG app refresh (`.background`), after an outbox drain that acknowledged a send (`.afterOutbox`, so the SENT copy appears), thread open (`.threadOpened`), label/unread view open, inbox end reached (`.loadOlderInbox`). No timers `[PLAN.md]`.

Cancellation: `run(.background)` checks `Task.isCancelled` between every network call; every DB write is one transaction so a cancellation never leaves partial state.

### 4.2 Full sync (first launch, or after `historyId` expiry)

```
func fullSync():
    status.phase = .initialSync(progress: 0)
    profile   = api.getProfile()                              // 1 unit; baseline BEFORE listing [gmail-api §13 item 1]
    baseline  = profile.historyId
    sendAs    = api.listSendAs()                              // display name + aliases (1 unit)
    selfAddrs = {profile.emailAddress} ∪ {s.sendAsEmail for s in sendAs}   (lowercased)
    generation = (syncState.syncGeneration ?? 0) + 1
    db.write:  syncState[accountEmail] = profile.emailAddress (assert equal to the signed-in account, else throw accountMismatch)
               syncState[sendAsJSON], [displayName]; syncState[syncGeneration] = generation

    labels = api.listLabels()                                 // 1 unit
    db.write: LabelRepository.replaceAll(labels)              // keeps counts of labels that still exist

    page = api.listMessages(labelIds: ["INBOX"], q: nil, maxResults: settings.inboxPageSize (100), pageToken: nil)   // 5 units
    ids  = page.messages.map(\.id)
    hydrate(ids, generation)                                  // §4.4 — batched metadata, writes in chunks of 25 (progress updates)
    db.write: syncState[inboxNextPageToken] = page.nextPageToken

    if syncState[unreadViewFetchedAt] != nil:                  // keep the Unread view populated across resyncs
        hydrate(api.listMessages(labelIds: ["UNREAD"], maxResults: 100).ids, generation)
    for label in labels where label.cached_view_at != nil:      // cached label views survive a resync
        hydrate(api.listMessages(labelIds: [label.id], maxResults: 50).ids, generation)

    db.write:
        // rows not rewritten by this generation that are not protected are stale (their labels may have changed while we had no history)
        delete from message where sync_generation < generation and id not in (select target/affected ids of pending outbox ops)
        ThreadRepository.recomputeAggregates(all touched threads)
        syncState[historyId] = baseline; syncState[lastFullSyncAt] = now
    deltaSync()                                               // catches everything that changed during the full sync; idempotent
```

Why delete rows of the previous generation: after a `historyId` expiry we cannot know what happened to messages we did not re-list (e.g. archived from another client); keeping them would show stale inbox rows forever. Messages referenced by pending outbox ops are kept so the user's intent is still applied (§4.7). Bodies cascade-delete with their message; that is acceptable (re-fetched on open).

Cost with pessimistic units: 1 + 1 + 1 + 5 + 100×20 = 2,008 units ≈ 33 % of the per-minute budget `[gmail-api "Quotas"]`. The hydrator's rate limiter spaces batches so a full sync plus an immediate delta never exceeds 80 units/s.

### 4.3 Delta sync (`history.list`)

```
func deltaSync():
    start = UInt64(syncState[historyId])!
    pages = []
    token = nil
    repeat:
        page = api.listHistory(startHistoryId: start, pageToken: token, maxResults: 500)     // 2 units per page
          on GmailError.notFound                        → throw SyncError.historyExpired
          on GmailError.badRequest(reason: r) where r ∈ {"failedPrecondition","invalidArgument"} or message contains "historyId"
                                                        → throw SyncError.historyExpired          // [gmail-api §13 item 5]
        pages.append(page); token = page.nextPageToken
        if pages.recordCount > 5_000                    → throw SyncError.tooManyRecords          // cheaper to resync than to apply
    until token == nil

    changes = HistoryReducer.reduce(pages)              // pure; unit-tested
    scope   = HydrationScope(cachedLabelIds: {"INBOX","UNREAD"} ∪ cached label ids, knownThreadIds: db threads)
    toFetch = [id for (id, ref) in changes.added if !db.exists(id) && HydrationPolicy.shouldFetch(ref, scope)]
    fetched = hydrateMetadata(toFetch)                  // §4.4; 404 per id → dropped silently [gmail-api §13 item 4]

    db.write (one transaction):
        touched = ∅
        touched ∪= MessageRepository.delete(changes.deleted)
        for (id, labels) in changes.finalLabels where db.exists(id):
            MessageRepository.applyServerLabels(id, labels)          // full set beats deltas when present [gmail-api §13 SNIPPET]
        for (id, deltas) in changes.labelOps where db.exists(id) && changes.finalLabels[id] == nil:
            for d in deltas: MessageRepository.applyServerDelta(id, d)
        for (id, deltas) in changes.labelOps where !db.exists(id) && !changes.added.contains(id):
            // label change on an unknown message: fetch it if it just entered our scope (e.g. INBOX/UNREAD added), else ignore
            if deltas.any { $0.add ∩ scope.cachedLabelIds ≠ ∅ }: lateFetch.append(id)
        touched ∪= MessageRepository.recomputeEffective(all ids above ∪ fetched ids)
        ThreadRepository.recomputeAggregates(touched ∪ changes.touchedThreads)
        syncState[historyId] = changes.newHistoryId ?? (pages.last.historyId ?? start)   // never decrease
        syncState[lastDeltaSyncAt] = now
    if lateFetch non-empty: hydrateMetadata(lateFetch) in a second transaction (same recompute)
    // The message's own labelIds in the history record, when present, are the truth at that record's time; if the
    // sync-guide claim is false (labelIds absent) the delta path above still yields the right state.
```

`HydrationPolicy.shouldFetch(ref, scope)`: `true` if `ref.labelIds == nil` (unknown) OR `ref.threadId ∈ scope.knownThreadIds` (a reply in a thread we show, incl. our own SENT) OR `ref.labelIds ∩ scope.cachedLabelIds ≠ ∅`; `false` if `ref.labelIds ⊇ {DRAFT}` or contains `SPAM`/`TRASH` and none of the above.

`HistoryReducer.reduce` rules:
1. Iterate records in order (pages concatenated; ids increase).
2. `messagesAdded` → `added[id] = ref` (last wins), remove from `deleted`.
3. `messagesDeleted` → `deleted.insert(id)`, `added.removeValue(id)`, `labelOps.removeValue(id)`, `finalLabels.removeValue(id)`.
4. `labelsAdded`/`labelsRemoved` → append `LabelDelta(add:…)` / `(remove:…)` to `labelOps[id]`; if `change.message.labelIds != nil` set `finalLabels[id]` to that set (last wins).
5. `touchedThreads` collects every `threadId` seen. `newHistoryId` = last page's `historyId` (or the last record id if the field is absent).

Recovery on `SyncError.historyExpired` / `tooManyRecords`: `db.write { syncState[historyId] = nil }`, log `sync.history.expired`, then `fullSync()` in the same run. Never surfaces to the user beyond the "Syncing…" phase.

### 4.4 Metadata hydration (`MetadataHydrator`)

```
func hydrateMetadata(ids, generation) -> Set<String> fetched:
    for chunk in ids.chunked(25):                                    // 25 × 20 units = 500 units per HTTP batch
        results = api.getMessages(ids: chunk, format: .metadata)     // uses BatchClient; per-part retry for 429/5xx
        parsed = []
        for (id, r) in results:
            switch r:
              .success(msg): parsed.append((msg, PayloadParser.headers(msg.payload)))
              .failure(.notFound): skip (deleted meanwhile)
              .failure(e) where e.isTransient: remember for one re-batch after backoff; if still failing → skip this run (will be picked up by reconcile/next delta)
              .failure(other): log, skip
        db.write:
            touched = MessageRepository.upsertMetadata(parsed, selfAddresses, now)   // writes server_label_ids AND recomputes effective for these ids
            ThreadRepository.recomputeAggregates(touched)
        status.phase = .initialSync(progress: done/total)          // only during full sync
```

`upsertMetadata` sets `server_label_ids = msg.labelIds`, `sync_generation = generation`, keeps an existing body row untouched, then calls `recomputeEffective` for the ids (pending outbox deltas re-applied — this is what makes an optimistic archive survive a re-hydration of the same message).

Request shape: `GET /gmail/v1/users/me/messages/{id}?format=metadata&metadataHeaders=From&…&fields=id,threadId,labelIds,snippet,historyId,internalDate,sizeEstimate,payload/mimeType,payload/headers&prettyPrint=false` `[gmail-api gotcha 23]`.

### 4.5 Thread completion and body lazy-load

```
func ensureThreadComplete(threadId):                   // on ThreadScreen appear
    if thread.is_complete == 0:
        t = api.getThread(id: threadId, format: .metadata)        // 40 units; one call gives every message's headers
          on notFound: mark thread for deletion (delete messages/thread in db) and return
        db.write: upsertMetadata(t.messages); markComplete(threadId); recomputeAggregates([threadId])
    missing = BodyRepository.missingBodyIds(threadId)   // messages with no body row or sanitizer_version < Sanitizer.version
    await bodyLoader.load(missing, priority: newestFirst)

actor BodyLoader:
    inFlight: Set<String>
    func load(ids):
        ids = ids − inFlight; inFlight ∪= ids
        for chunk in ids.chunked(10):                                // 10 × 20 units; bodies are big, keep batches small
            results = api.getMessages(ids: chunk, format: .full)     // fields=id,threadId,labelIds,payload,snippet,internalDate
            for (id, r) in results:
                guard case .success(msg) = r else { handle 404 → delete message; transient → leave for next open }
                parsed = PayloadParser.parse(msg)
                if parsed.html == nil && parsed.text == nil && !parsed.deferredTextParts.isEmpty:
                    part = parsed.deferredTextParts.first
                    data = api.getAttachment(messageId: id, attachmentId: part.attachmentId)
                    decode with part charset → parsed.html/text accordingly
                sanitized = parsed.html.map { try Sanitizer.sanitize(rawHTML: $0, messageId: id) }   // off-main (actor)
                db.write:
                    BodyRepository.store(id, sanitized, parsed.text, parsed.attachments, now)    // attachments rows: is_inline = contentId ∈ sanitized.referencedContentIDs
                    MessageRepository.applyServerLabels(id, msg.labelIds)                          // free freshness
                    recomputeEffective([id]); recomputeAggregates([thread])
        inFlight −= ids
```

Bodies are never fetched by the BG task or by list scrolling. Sanitizer failures (SwiftSoup throw) fall back to `Sanitizer.plainTextToHTML(text ?? "")` and log `render.sanitize.failed` with the message id — never leave a message unreadable.

### 4.6 Labels, unread counts, badge

- `LabelSync` after every delta: `labels.list` (1 unit) to pick up new/renamed labels; then batched `labels.get` for **displayed** labels (system `INBOX` plus every `user` label with `labelListVisibility != labelHide`, cap 60 ids, 1 unit each) to refresh `threads_unread` etc. `[gmail-api §11]`.
- Displayed counts: the **Inbox** row and the app badge use the local count `SELECT COUNT(*) FROM thread WHERE in_inbox=1 AND is_unread=1` (exactly what the list shows, includes optimistic state). Other labels show the server `threads_unread` (their content is not fully cached). Documented in the Labels screen footer ("Counts from Gmail").
- Badge: only if `settings.showBadge` and authorization was granted; `UNUserNotificationCenter.current().setBadgeCount(n)` after every sync run and outbox ack (foreground and background) `[ios-platform §6]`; `0` on sign-out.

### 4.7 Conflict rules: optimistic local state vs server

Definitions: `S` = `server_label_ids`, `P` = ordered pending deltas for the message (from outbox rows: message ops targeting it, and thread ops whose `affected_message_ids` contain it), `E` = `label_ids` = `effective(S, P)`. The UI only ever reads `E`.

| Event | Effect on `S` | Effect on `P` | `E` |
|---|---|---|---|
| User action (archive/read/unread) | unchanged | enqueue/coalesce delta `d` | recomputed → instant UI |
| History record for the message (delta sync) | `S := labels` (if full set present) or `S := d_hist(S)` | unchanged | recomputed; pending intent still on top |
| Outbox op acked (2xx) | `S := d(S)` for each affected message; if the response carries `labelIds` per message, `S := labelIds` | op removed | recomputed; converges to server |
| Outbox op 404 (target gone) | unchanged | op removed | recomputed; delta sync deletes the message soon |
| Outbox op 400 (invalid label) | unchanged | op removed + toast "Couldn't apply change" | reverts to server state |
| Full resync | `S :=` fresh; rows not re-listed deleted unless referenced by `P` | unchanged | recomputed |
| Message arrives later in a thread that has a pending thread op | `S` = fetched | thread op's `affected_message_ids` does not contain it → not affected | reflects server; correct because `threads.modify` applied server-side to the messages that existed when Gmail processed it |

Ordering property: because `E` is a function of `(S, P)` and both updates are commutative set operations, the interleaving of ack, history and user actions cannot lose an update. The only "conflict" left is semantic: another client changes a label after the user's local action but before the op is transmitted — the user's op is applied last and wins. That matches user expectation ("I archived it") and is documented as intended.

Thread-level ops and message-level snapshot: `threads.modify` applies to **all** messages of the thread server-side `[gmail-api §9]`, while locally we apply the delta to the messages we know. If the thread was incomplete, unknown messages get the right labels when they are fetched (their `S` comes from the server after the op was applied, or the history record shows the change). Consistent either way.

### 4.8 Outbox design

**Operations**
- `modify` — `target ∈ {thread(id), message(id)}`, `add`, `remove` (sorted), `affected_message_ids`. Stage-1 UI only creates thread-level ops: archive (`remove INBOX`), mark read (`remove UNREAD`), mark unread (`add UNREAD`), move to inbox (`add INBOX`, used by "Undo archive" toast). Message-level ops are supported by the same code path for future use.
- `send` — `draft_json` (`ComposeDraft`), `rfc822_message_id`, `transmit_state`.

**Enqueue (same transaction as the optimistic update)**
```
enqueueModify(target, delta, affected, now):
    if let existing = pending (state='pending') op with same target:
        merged = OutboxCoalescer.merge(existing.delta, delta)
        if merged.isEmpty: delete existing; recomputeEffective(affected)   // e.g. read then unread → nothing to send
        else: update existing (delta = merged, affected = existing.affected ∪ affected, updated_at = now)
    else: insert (seq = max(seq)+1, state = pending, next_attempt_at = 0)
    recomputeEffective(affected)  → recomputeAggregates
    // an op that is 'in_flight' is never merged into; a new row is created and applied after it (seq order)
```
Coalescing keeps at most one pending op per target, so 20 rapid swipes produce ≤ 20 rows and toggling produces 0 or 1.

**Drain (`OutboxWorker`)**
```
drain():
    guard !running else return; running = true; defer running = false
    loop:
        if network.isOffline: status.isOffline = true; return          // NetworkMonitor will kick() when back
        mods = db.write { OutboxRepository.claimBatch(kind: .modify, limit: 50, now) }    // pending & due → in_flight
        if !mods.isEmpty:
            calls = mods.map { ModifyCall(opId: $0.id, target: $0.target, add: $0.add, remove: $0.remove) }
            results = api.modify(calls)                                  // one HTTP batch; per-part results by Content-ID
            db.write:
                for (opId, r) in results:
                    switch r:
                      .success(labelsByMessage): ack(opId, labelsByMessage)
                      .failure(.notFound):       ack(opId, nil)  → then discard semantics: op removed, S unchanged (target gone)
                      .failure(.badRequest):     fail(opId) → toast; discard (reverts E)
                      .failure(.unauthenticated): retryLater(opId) (GmailAPI already tried one refresh; AuthStore flips to needsReauth)
                      .failure(transient):       retryLater(opId, backoff: .outbox)
                      .failure(other 403):       fail(opId) permanently; toast with reason
        sends = db.write { claimBatch(kind: .send, limit: 1, now) }      // one send at a time
        if let s = sends.first: await SendOperation.run(s)                 // §7.7
        if mods.isEmpty && sends.isEmpty: break
    status.pendingOps = count(pending); status.failedSends = count(failed sends)
    if any op was acked: badge update; if a send was acked: engine.run(.afterOutbox)
```

`claimBatch` only returns rows with `next_attempt_at <= now`; rows with a future `next_attempt_at` are re-checked on the next kick; `OutboxWorker` also schedules a `Task.sleep` until the earliest `next_attempt_at` while the app is foregrounded (this is a one-shot continuation of a user action, not a polling timer).

**Retry/backoff**: `attempts += 1` only when `error.countsAsAttempt`; `next_attempt_at = now + Backoff.outbox.delay(attempt)` (2 s, 4 s, 8 s … cap 300 s, ±25 % jitter, `Retry-After` honoured). After **8** transient attempts a modify op becomes `failed` but is re-armed (state → pending, attempts → 0) on the next foreground/pull-to-refresh so it is never lost silently. A `send` becomes `failed` after 5 transient attempts or immediately on a permanent 4xx.

**At launch**: `OutboxRepository.releaseInFlight()` (`in_flight → pending`) because a kill during a request leaves the state unknown; for sends `transmit_state = maybe_sent` triggers the `rfc822msgid:` check before any retry (§7.7).

**Failure UX**
- Transient/offline: nav-bar subtitle "Offline — changes will sync" (SF `wifi.slash`); nothing else; the UI already shows the optimistic state.
- Failed send: an inline banner row at the top of the inbox list: "Not sent: <subject>" with actions **Retry**, **Edit** (reopens Compose with the draft), **Discard** (confirmation). Also a red `exclamationmark.triangle` badge on the Settings gear when the inbox is filtered away.
- Reverted label op (400/403 permanent): toast "Couldn't archive — Gmail rejected the change" for 4 s; the row reappears because `E` reverted.

### 4.9 Cache bounds (`Pruner`, runs after a successful delta, at most once per 6 h)

1. `message_body`: keep total `byte_size` ≤ 120 MB; evict by `last_opened_at` ascending, never rows of threads currently open.
2. `attachment` file cache: ≤ 200 MB LRU by file access date.
3. Messages: delete threads (cascade) that are `in_inbox = 0 AND is_unread = 0 AND last_date < now − 30 d` and whose messages carry no cached-view label and no pending outbox op. Hidden (TRASH/SPAM) messages older than 7 days are deleted.
4. Never prune while a full sync is in progress.

### 4.10 Reconciler (daily safety net)

Because history deltas are applied blindly to `S`, a missed record (e.g. a `tooManyRecords` abort followed by resync covers it; but a decoding glitch would not) could leave `S` drifting. Once per 24 h, after a delta: `ids = visible messages (in_inbox=1 or is_unread=1)` (≤ 500), `api.getMessages(ids, format: .minimal)` in batches of 50, `applyServerLabels` for each, `recomputeEffective`, `recomputeAggregates`; 404 → delete. Cost ≤ 500 × 20 = 10,000 units spread by the limiter over ~2 minutes; runs only on Wi-Fi/expensive-path-false per `NWPath.isExpensive`, foreground only. Logs the number of messages whose `S` differed (`sync.reconcile.drift`) — the Diagnostics screen shows it; a non-zero value on consecutive days means the delta path has a bug to fix.

### 4.11 Background refresh

```
.backgroundTask(.appRefresh("de.newtelco.minimail.refresh"))   // identifier must match BGTaskSchedulerPermittedIdentifiers exactly
BackgroundRefresh.run():
    scheduleNext()                          // request is consumed; re-arm first [ios-platform §3.3]
    guard auth.state is signedIn else return
    await engine.run(.background)           // delta + label counts only; no bodies; checks Task.isCancelled between calls
    await outbox.drainNow()                 // pending modifies + sends (wrapped in beginBackgroundTask by the worker when foreground-initiated; here the BG task itself is the budget)
    await badge.update()
```
DB protection: if `DatabasePool` throws `SQLITE_AUTH`/`SQLITE_IOERR` because the device is locked before first unlock, the handler logs and returns (`[ios-platform §2.2]`).

---

## 5. Auth

### 5.1 Flow

1. **Config**: `GoogleClientID` read from `Bundle.main.infoDictionary` (injected from `Config/Google.xcconfig`); redirect URI = `com.googleusercontent.apps.<id>:/oauth2redirect` (single slash) `[gmail-api "OAuth 2.0 for iOS"]`; endpoints hard-coded (`https://accounts.google.com/o/oauth2/v2/auth`, `https://oauth2.googleapis.com/token`, `https://oauth2.googleapis.com/revoke`) — no discovery round-trip at launch `[gmail-api OIDC-verified]`.
2. **Scopes**: exactly `["https://www.googleapis.com/auth/gmail.modify"]`. Decision: no `openid`/`email` scope — the account email comes from `getProfile` (1 unit), which avoids a second consent line and any id-token handling.
3. **Sign-in** (`AuthStore.signIn(from:)`, main actor): `OIDAuthorizationRequest(configuration:clientId:scopes:redirectURL:responseType: OIDResponseTypeCode, additionalParameters: ["login_hint": lastEmail?, "hd": "newtelco.de"])`; `OIDExternalUserAgentIOS(presentingViewController:prefersEphemeralSession: false)` (shared Safari session, fastest for a single work account `[ios-platform §1.3]`); `OIDAuthState.authState(byPresenting:externalUserAgent:callback:)`; callback hops to the main actor via `withCheckedThrowingContinuation`. The returned `OIDAuthState` is handed to `AppAuthTokenProvider.adopt(_:)` which persists it (NSKeyedArchiver, secure coding) into the Keychain under service `de.newtelco.minimail`, account `oauth.authState`, accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` `[ios-platform §1.5, §5.5]`.
4. **Account check**: immediately `api.getProfile()`. If `sync_state.accountEmail` exists and differs → `Database.wipe` + reset (single-account app; a different account never sees the old cache). Store `accountEmail`. State → `.signedIn(email)`.
5. **`onOpenURL`** fallback: `auth.resume(url:)` calls `currentFlow?.resumeExternalUserAgentFlow(url)` `[ios-platform §1.4]`.
6. **Missing refresh token** (`state.refreshToken == nil` after sign-in): retry the flow once with `additionalParameters["prompt"] = "consent"`; if still missing, surface "Google did not issue a refresh token" and stay signed out (`[gmail-api "PKCE"]` UNVERIFIED that native clients always get one).

### 5.2 Token provider (actor, single-flight refresh)

```
actor AppAuthTokenProvider {
    private var state: OIDAuthState?        // owned here; not Sendable → never escapes the actor
    private var refreshTask: Task<String, Error>?
    func accessToken() async throws -> String {
        guard let state else { throw AuthError.signedOut }
        if let refreshTask { return try await refreshTask.value }       // coalesce concurrent callers
        let task = Task { try await withCheckedThrowingContinuation { cont in
            state.performAction(freshTokens: { token, _, error in           // refreshes if expired [ios-platform §1.6]
                if let token { cont.resume(returning: token) } else { cont.resume(throwing: Self.map(error)) } }) } }
        refreshTask = task; defer { refreshTask = nil }
        return try await task.value
    }
    func invalidateAccessToken() { state?.setNeedsTokenRefresh() }
    // OIDAuthStateChangeDelegate.didChange → persist() (archive to Keychain) on every token response
    // OIDAuthStateErrorDelegate.authState(_:didEncounterAuthorizationError:) with OAuth "invalid_grant" → onNeedsReauth()
}
```
Errors: `OIDOAuthTokenErrorDomain` code `invalid_grant` → `AuthError.needsReauth`; network errors during refresh → `GmailError.offline/.network` (retryable, do not sign out); any other → `AuthError.flowFailed`.

### 5.3 401 handling (in `GmailAPI`)

```
perform(request):
    token = try await tokens.accessToken()
    (data, resp) = transport.send(request + Bearer token)
    if resp.status == 401:
        await tokens.invalidateAccessToken()
        token2 = try await tokens.accessToken()           // forces refresh
        (data, resp) = transport.send(request + Bearer token2)
        if resp.status == 401: throw GmailError.unauthenticated   // caller: AuthStore.markNeedsReauth(); ops stay pending
```
A `401` inside an HTTP batch part is treated the same way once for the whole batch (refresh, re-send the batch). Two consecutive 401s or an `invalid_grant` flip `AuthStore.state` to `.needsReauth(email)`: the UI shows a non-dismissable sheet "Sign in again to continue syncing"; the cache and outbox stay intact; sync and drain pause. Re-auth with the same email resumes everything; with a different email → wipe (5.1 step 4).

### 5.4 Sign-out

`AuthStore.signOut()`: cancel running sync/drain → `tokens.revokeAndClear()` (`POST /revoke token=<refresh>`, best effort, 3 s timeout) → Keychain delete → `Database.wipe` (delete the whole `minimail-db` directory incl. `-wal/-shm`) → attachment cache + `WKWebsiteDataStore` reset → `setBadgeCount(0)` → state `.signedOut`. Decision: `Settings` (incl. the signature) are kept — they are the owner's preferences, not account data.

### 5.5 Single-account assumptions

- Exactly one Keychain item, one DB, one `accountEmail`. Every screen assumes `AuthStore.state == .signedIn`.
- `selfAddresses` = profile email ∪ verified `sendAs` aliases (`verificationStatus == accepted` or `isPrimary`), refreshed by every full sync and daily by `LabelSync` (1 unit).
- `From:` header = `sendAs.first(isDefault)?.displayName` + profile email. Gmail rewrites a mismatching From to the primary anyway `[gmail-api §14]`.

---

## 6. Networking

### 6.1 Client shape

- `URLSession.minimail`: `URLSessionConfiguration.ephemeral`, `timeoutIntervalForRequest = 30`, `timeoutIntervalForResource = 120`, `waitsForConnectivity = false` (we want fast failure + our own offline gate), `httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "minimail/<version> iOS"]`, `allowsExpensiveNetworkAccess = true`, `allowsConstrainedNetworkAccess = true` (Low Data Mode still syncs; bodies are user-initiated anyway), `urlCache = nil`.
- `RequestBuilder`: base `https://gmail.googleapis.com/gmail/v1/users/me/`; repeated keys for `labelIds`, `metadataHeaders`, `historyTypes` `[gmail-api "Common facts"]`; `prettyPrint=false` always; `fields=` per method (§4.4, §4.5); JSON bodies `Content-Type: application/json`.
- Batch endpoint `https://www.googleapis.com/batch/gmail/v1`, `multipart/mixed; boundary=…`, inner request lines host-relative `/gmail/v1/users/me/...`, ≤ **50** parts per batch (documented max 100; 50 keeps per-user rate errors rare `[gmail-api §12]`).
- Upload endpoint for large sends: `POST https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart` with a related-multipart body: part 1 `application/json` `{"threadId": …}`, part 2 `message/rfc822` raw bytes `[mime-rfc §1.1]`. (If `multipart` upload is rejected on the real account, fall back to `uploadType=media` without `threadId` — accepted loss of threading for > 5 MB forwards.)

### 6.2 Error taxonomy and mapping

```
map(status, body):
    env = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body)
    reason = env?.primaryReason
    switch status:
      400: .badRequest(reason, env.message)
      401: .unauthenticated
      403: reason ∈ {rateLimitExceeded, userRateLimitExceeded, dailyLimitExceeded, quotaExceeded, concurrentLimitExceeded}
             ? .rateLimited(retryAfter: header, reason) : .forbidden(reason)
      404: .notFound
      409, 412: .conflict
      413: .payloadTooLarge
      429: .rateLimited(retryAfter: Retry-After header (seconds or HTTP-date), reason)
      500…599: .server(status)
      other 4xx: .badRequest(reason, message)
map(URLError):
      .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff → .offline
      .cancelled → .cancelled
      else → .network(code)
```

Per-call retry policy (inside `GmailAPI.perform`, before the caller sees an error):

| Error | Retries | Backoff |
|---|---|---|
| `.rateLimited` | 4 | `Retry-After` if present, else `Backoff.transient` (1, 2, 4, 8 s ±25 %) |
| `.server(5xx)` | 3 | `Backoff.transient` |
| `.network` (timeout, reset) | 2 | `Backoff.transient` |
| `.offline` | 0 | fail fast; `NetworkMonitor` re-triggers |
| `.unauthenticated` | 1 (after refresh) | none |
| `.batchMalformed` | 1 | 1 s |
| everything else | 0 | — |

Non-idempotent exception: `messages.send` is retried **only** on `.rateLimited`/`.server` when the response is unambiguous (the request was rejected). On a network error after the body was transmitted the API layer does not retry; `SendOperation` handles it with the `rfc822msgid:` check (§7.7). The transport reports whether the request body was fully sent (`URLSessionTaskMetrics` / error code heuristics: `.timedOut` after upload → maybe sent; `.cannotConnectToHost` → not sent).

### 6.3 Batching strategy

`BatchClient.run(calls: [BatchCall]) -> [id: Result<BatchPart, GmailError>]`:
1. Chunk to ≤ 50; for each chunk `limiter.acquire(units: Σ QuotaTable.units)`; POST; parse with `BatchResponseParser`.
2. For each part: status 2xx → success; else map via §6.2. Parts with `.rateLimited`/`.server` are collected and re-sent as a smaller batch after `Backoff.transient` (max 3 rounds). Parts with `.unauthenticated` → refresh once and re-send the whole chunk (max 1). Others are final.
3. Outer HTTP failure (non-200 or unparsable multipart) → `.batchMalformed` once (retry whole chunk after 1 s), then propagate as the result for every part.
4. Results are matched by `Content-ID` (`<response-ID>`), never by order `[gmail-api §12]`. A part id missing from the response is reported as `.batchMalformed` for that id.

Batch usage table:

| Purpose | Calls per part | Parts/batch | Units/batch (pessimistic) |
|---|---|---|---|
| Metadata hydration | `messages.get?format=metadata` | 25 | 500 |
| Body load | `messages.get?format=full` | 10 | 200 |
| Label counts | `labels.get` | 50 | 50 |
| Outbox modifies | `threads.modify` / `messages.modify` | 50 | ≤ 500 |
| Reconcile | `messages.get?format=minimal` | 50 | 1000 |

### 6.4 Rate limiting and concurrency

`RateLimiter` actor: token bucket refilled at 80 units/s (80 % of 6,000/min), burst 400; `acquire(units:)` awaits both tokens and one of 3 concurrency slots `[gmail-api gotcha 24]`. Every `GmailAPI` call declares its `GmailMethod`; batches declare the sum. A `429` additionally halves the refill rate for 60 s (adaptive), then restores. The limiter never blocks the main actor (callers are actors/tasks).

### 6.5 Logging

- `os.Logger(subsystem: "de.newtelco.minimail", category:)` categories: `auth`, `net`, `sync`, `outbox`, `db`, `render`, `ui`, `bg`.
- Privacy: message ids/thread ids `%{public}`; addresses, subjects, snippets `%{private}`; **never** log tokens, `Authorization` headers, bodies, `raw`, or attachment bytes. Error envelopes are logged with `message` redacted to 120 chars.
- Each `GmailAPI` call logs one line at `.info`: method, status, elapsed ms, units, retry count, batch part count. Signposts (`OSSignposter`): `coldStart`, `fullSync`, `deltaSync`, `hydrateBatch`, `threadOpen`, `bodyLoad`, `send`.
- `DiagnosticsScreen` (Settings) shows: account, `historyId`, generation, last full/delta/reconcile times, drift count, outbox rows (state, attempts, last error), limiter state, and a "Copy diagnostics" button (plain text, no secrets). It also has "Force full resync".

---

## 7. Compose pipeline (reply-all / forward)

### 7.1 Reply-all recipients (`ReplyAll.recipients`, pure) `[mime-rfc §2.1, §8.1]`

```
recipients(input):
    self = input.selfAddresses (lowercased)
    isSelfReply = input.from != nil && self.contains(input.from.key)
    toCandidates = isSelfReply ? input.to : ((input.replyTo.isEmpty ? [input.from].compactMap{$0} : input.replyTo) + input.to)
    ccCandidates = input.cc
    seen = Set<String>()
    to = toCandidates.filter { !$0.key.isEmpty && !self.contains($0.key) && seen.insert($0.key).inserted }
    cc = ccCandidates.filter { !$0.key.isEmpty && !self.contains($0.key) && seen.insert($0.key).inserted }
    if to.isEmpty && !cc.isEmpty { to = cc; cc = [] }
    if to.isEmpty, let from = input.from { to = [from] }        // note-to-self: never empty To
    return Recipients(to, cc)
```
All 16 vectors of `[mime-rfc §8.1]` are test cases. Display names: first-seen wins; RFC 2047 decoded on ingest, re-encoded by the builder.

### 7.2 Subject

`SubjectPrefix.reply` / `.forward` as in `[mime-rfc §1.4–1.5, §8.2]`; empty original → `"Re: "` / `"Fwd: "` (trailing space kept, matching Gmail web; UNVERIFIED but harmless).

### 7.3 Threading headers

| | `threadId` | `In-Reply-To` | `References` |
|---|---|---|---|
| Reply-all | original `threadId` | original `Message-ID` | original `References` (or single `In-Reply-To` if no References) + original `Message-ID`, deduped in order |
| Forward | original `threadId` **(Decision: keep in thread, Gmail-web behaviour)** | original `Message-ID` | same chain as reply |

Rationale: mirrors what Gmail web and Google's own CLI emit `[mime-rfc §1.5]`; the owner's thread view keeps the forward with its source. If the owner wants "forward = fresh conversation", flip `settings.forwardKeepsThread = false`, which omits **all three** together (setting only `threadId` does nothing `[gmail-api §14]`). If the original lacks a `Message-ID` (rare), `In-Reply-To`/`References` are omitted and the send still carries `threadId` (Gmail may start a new thread — accepted).

### 7.4 Quoting and body assembly

```
buildOutgoing(draft: ComposeDraft, settings, identity: (displayName, email, domain), now) -> OutgoingMessage:
    style      = settings.composeStyle
    sigHTML    = settings.signatureEnabled && draft.includeSignature ? settings.signatureHTML (already sanitized on save) : nil
    sigText    = sigHTML.map { Quoting.textFromHTML($0) }
    quoteHTML  = draft.kind == .replyAll ? Quoting.replyHTML(draft.quoteSource, tz) : Quoting.forwardHTML(draft.quoteSource, tz)
    quoteText  = draft.kind == .replyAll ? Quoting.replyText(…) : Quoting.forwardText(…)
    htmlFrag   = OutgoingHTML.body(text: draft.bodyText, style: style, signatureHTML: sigHTML, quoteHTML: quoteHTML)
    html       = OutgoingHTML.document(bodyFragment: htmlFrag)
    text       = OutgoingHTML.plain(text: draft.bodyText, signatureText: sigText, quoteText: quoteText)
    return OutgoingMessage(from: Mailbox(displayName, email), to: draft.to, cc: draft.cc, subject: draft.subject,
                           date: draft.createdAt, timeZone: .current, messageID: draft.rfc822MessageId,
                           inReplyTo: …, references: …, textBody: text, htmlBody: html, attachments: fetched)
```
HTML layout (exact): `<div class="minimail_default" style="font-family:…;font-size:14px;color:#…">` + one `<div>` per typed line (`<div><br></div>` for empty) + `</div>`, then `<div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature" style="…same inline css…">SIG</div>` when a signature exists, then `<br>` + the Gmail quote block (reply: `gmail_quote gmail_quote_container` + `gmail_attr` + `<blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">`; forward: banner block with `<strong class="gmail_sendername" dir="auto">`, body not blockquoted) `[mime-rfc §3.4–§4.2, html-rendering §5.5]`. The quote is **outside** the styled wrapper. No `color-scheme` meta in outgoing mail `[html-rendering §5.5]`.

Plain text layout: typed text, blank line, `-- ` + signature text (if any), blank line, attribution line + `> ` quoted lines (reply) or the forward banner block `[mime-rfc §4.1–4.2, §7.1]`.

`QuoteSource` is captured when the Compose screen opens (from `message_body` + headers): `html = QuoteExtractor.quotable(body_html)` (remote `data-src` restored to `src`, placeholder GIFs removed, `minimail-cid://` → `cid:`), `text = body_text ?? Quoting.textFromHTML(html)`. Inline `cid:` images referenced by the quote are **not** re-attached in stage 1 (they render as broken images for the recipient, same as Gmail's plain forward without related parts — documented limitation; PLAN's "attachments passthrough" covers real attachments).

### 7.5 MIME builder (`MIMEBuilder.build`) `[mime-rfc §1.3, §3]`

- Header order fixed; each header line folded at 78 (address lists after commas, `References` one id per continuation); non-ASCII display names and Subject via `RFC2047.encodeHeaderText` (B, UTF-8, ≤ 75 per word).
- `Date:` `RFC5322Date.format(date, tz)`; `Message-ID:` from the draft; `MIME-Version: 1.0`.
- Structure A: `multipart/alternative; boundary="=_minimail_alt_<16hex>"` → `text/plain; charset="UTF-8"` (QP) then `text/html; charset="UTF-8"` (QP). Structure B when attachments exist: `multipart/mixed; boundary="=_minimail_mixed_<16hex>"` ⊃ [A, attachments…]. Each attachment: `Content-Type: <mime>; name="<file>"`, `Content-Disposition: attachment; filename="<file>"; size=<n>` (RFC 2231 `filename*=` added for non-ASCII names), `Content-Transfer-Encoding: base64` (76-col, CRLF, standard alphabet).
- Text bodies: `\n` → CRLF normalisation, then `QuotedPrintable.encode`.
- Byte-exact tests pin the two examples in `[mime-rfc §7]` (`sha256 b9f8078c…` for the reply; the forward example is regenerated with `In-Reply-To` present per §7.3 and its hash recorded in the fixture on first run — the research hash `2127dc54…` applies to the no-In-Reply-To variant and is kept as a second test with that header omitted).

### 7.6 Forward with attachments

At **drain time** (not at compose time, so compose works offline and attachments are never prefetched): for each `ForwardAttachmentRef` in the draft (user may have removed some in the compose UI):
1. `attachment_id` from the `attachment` row; if `NULL` or `attachments.get` returns 404 → `messages.get?format=full&fields=payload` for the source message, re-map by `partId`, update the row, retry once `[gmail-api §6]`.
2. `Base64URL.decode(data)`; verify `bytes.count == size` (log mismatch, continue).
3. Sum check before building: if `Σ size × 1.37 + 64 KB > 25 MB` → permanent failure `payloadTooLarge` with a user-facing reason before any network call `[mime-rfc §6]`. If `Σ size > 5 MB` use the upload path (§6.1), else JSON `raw`.

### 7.7 Send via outbox (`SendOperation.run`)

```
run(op):
    draft = decode(op.draft_json)
    if op.transmit_state == .maybe_sent:
        found = api.listMessages(labelIds: [], q: "rfc822msgid:\(draft.rfc822MessageId)", maxResults: 1)   // 5 units [gmail-api §14]
        if let m = found.messages.first: return ackSend(op, gmailId: m.id)      // it went through; do not send twice
    attachments = fetchAttachments(draft)                                         // §7.6; permanent failure → fail(op)
    message = buildOutgoing(draft, …)                                              // §7.4
    bytes   = MIMEBuilder.build(message)
    db.write { op.transmit_state = .maybe_sent }                                  // BEFORE the request leaves
    do {
        sent = Σ attachments > 5 MB ? api.sendUpload(rfc822: bytes, threadId: tid) : api.send(raw: Base64URL.encode(bytes), threadId: tid)
        db.write { op.transmit_state = .sent; op.sent_gmail_id = sent.id; delete op }
        Haptics.success; status.toast("Sent")
        engine.run(.afterOutbox)                                                   // SENT copy appears via history
    } catch let e as GmailError {
        switch e:
          .offline, .network, .server, .rateLimited: retryLater(op, e)             // next attempt starts with the rfc822msgid check
          .unauthenticated: retryLater(op, e)                                      // paused until re-auth
          .payloadTooLarge, .badRequest, .forbidden: fail(op, e)                   // user banner: Retry / Edit / Discard
          default: fail(op, e)
    }
```
`tid` = `draft.threadId` if `settings.forwardKeepsThread || draft.kind == .replyAll` else `nil`. `beginBackgroundTask` wraps a foreground-initiated send so a swipe-away does not kill it mid-request `[ios-platform §3.5]`.

### 7.8 Compose-time rules

- Reply-all default recipients from §7.1; the user may remove any recipient and add addresses (validated with `AddressParser.parseFirst` + a minimal `x@y.z` check); To may not be empty at send.
- Forward: To empty by default (user must add ≥ 1); all non-inline attachments pre-selected; inline images excluded (§7.4).
- Draft autosave: `ComposeModel` writes the `ComposeDraft` JSON to `Application Support/minimail-db/compose-autosave.json` on every change (debounced 1 s) and deletes it on send/discard; on next launch with a file present, the inbox shows a "Resume draft" banner. Never lose typed text on a crash.
- Send tap: `db.write { OutboxRepository.enqueueSend(draft) }` → dismiss → `outbox.kick()`. The Compose screen never awaits the network.

---

## 8. UI

### 8.1 Screens and navigation graph

```
RootView
 ├─ AuthStore.state == .loading      → ProgressView (splash, ≤ 100 ms; DB open + keychain read)
 ├─ .signedOut                       → SignInScreen
 └─ .signedIn / .needsReauth         → NavigationStack(path: $router.path)
        InboxScreen(filter)                                    root; filter ∈ {inbox, today, unread, label(id)}
          ├─ push  ThreadScreen(threadId)
          │         ├─ fullScreenCover ComposeScreen(draft)     (reply-all / forward)
          │         ├─ quickLookPreview($attachmentURL)
          │         └─ sheet SafariView(url)
          ├─ push  InboxScreen(filter: .label(id))              from LabelsScreen tap
          ├─ sheet LabelsScreen                                 (own NavigationStack; tapping a label dismisses + pushes filtered inbox)
          ├─ sheet SettingsScreen → SignatureScreen | ComposeStyleScreen | ThemeScreen | DiagnosticsScreen
          └─ fullScreenCover ComposeScreen(draft)               from the failed-send banner "Edit" / "Resume draft"
        .needsReauth → .sheet(isPresented: true, interactiveDismissDisabled) ReauthSheet
```

`Router` (`@Observable`): `path: [Route]` with `enum Route: Hashable { case thread(String), label(String) }`; sheets as optional state on the model. Deep links: none in stage 1.

### 8.2 Screen contracts

| Screen | State | Actions | Empty / loading / error |
|---|---|---|---|
| **SignInScreen** | `isSigningIn`, `error` | "Sign in with Google" → `auth.signIn`; shows the account domain hint | Error text under button (admin_policy_enforced → "Ask your Workspace admin to trust minimail" `[gmail-api "Workspace"]`) |
| **InboxScreen** | `filter`, `unreadOnly`, `rows: [ThreadRowDTO]` (ValueObservation), `SyncStatus`, `failedSends`, `autosavedDraft`, `undo: (opId, title)?` | pull-to-refresh → `engine.run(.pullToRefresh)`; tap row → push thread; swipe leading (archive, full swipe) → `actions.archive(thread)`; swipe trailing (read/unread) → `actions.toggleUnread`; view menu; unread chip; settings gear; "Load older" footer (inbox only) → `engine.run(.loadOlderInbox)`; failed-send banner Retry/Edit/Discard; undo toast "Archived · Undo" 5 s | `ContentUnavailableView("No Mail", systemImage: "tray")` for inbox; `"Nothing today", "sun.max"`; `"All caught up", "checkmark.circle"` (unread); `"No messages", "tag"` (label); first-ever sync: `ProgressView` with progress from `SyncStatus`; offline: nav subtitle; error: banner with Retry (never blocks the list) |
| **ThreadScreen** | `detail: ThreadDetailDTO` (ValueObservation on thread + messages + bodies + attachments), `expanded: Set<String>` (default: last message + all unread), `imagesAllowed: Set<String>` (per message), `loadingBodies: Set<String>`, `attachmentURL: URL?`, `safariURL` | on appear → `engine.ensureThreadComplete`, mark read (`settings.markReadOnOpen`, thread op `remove UNREAD`) ; bottom bar: Reply all, Forward, Archive, Read/Unread toggle; header tap → expand/collapse; "Load images" (per message) → `imagesAllowed.insert(id)` → document rebuilt; attachment tap → download → QuickLook; link tap → Safari sheet; `mailto:` tap → no-op in stage 1 (compose-new is out of scope) — shows copy address action sheet | body loading: skeleton block inside the HTML for that message; body fetch error: inline "Couldn't load message · Retry" block; thread deleted server-side → pop with toast |
| **ComposeScreen** | `draft: ComposeDraft`, `canSend`, `showRecipientsEditor`, `attachmentsSelection` | Send → enqueue + dismiss; Cancel → discard confirmation if text typed; edit recipients; toggle signature; toggle attachments (forward) | Attachments over 25 MB → Send disabled with footnote; recipients invalid → red chip |
| **LabelsScreen** | `labels: [LabelRowDTO]` (system first: Inbox, Sent, Starred, Important, Drafts, Spam, Trash → Decision: show only Inbox, Starred, Important, Sent + all user labels; hide Spam/Trash/Drafts/Chat/categories), local inbox unread count, server counts | tap → filtered inbox; pull-to-refresh → `LabelSync` | `ContentUnavailableView("No labels")` before first sync |
| **SettingsScreen** | `Settings` via `@Bindable SettingsStore` | Theme picker, Compose style, Signature, Remote images default, Badge toggle (requests notification permission in context), Mark read on open, Swipe actions, Forward keeps thread, Account (email, Sign out), Diagnostics | — |
| **SignatureScreen** | raw HTML `TextEditor` (monospaced); live preview uses the single pooled web view via `MailWebView` in preview mode (Settings and Thread are never on screen at the same time, so the pool's one instance suffices); "Import from Gmail" (reads `sendAs.signature`) | Save → `SignatureSanitizer.sanitize` → settings | Sanitizer error → alert |
| **ComposeStyleScreen** | family (Picker), size (Stepper 12–18), colour (`ColorPicker` without opacity → hex) , preview rendered via SwiftUI `Text` with the chosen font mapped to system equivalents | | |
| **DiagnosticsScreen** | see §6.5 | Force full resync, Copy diagnostics, Retry all failed | |

### 8.3 List row (`ThreadRow`)

```
HStack(alignment: .top, spacing: 10) {
  Circle 8pt accent (unread) or clear                          // leading gutter, fixed width 12
  VStack(alignment: .leading, spacing: 2) {
    HStack { Text(participantsLine).font(.headline).fontWeight(unread ? .semibold : .regular).lineLimit(1)
             Spacer(); if hasAttachments { Image(systemName: "paperclip").foregroundStyle(.secondary) }
             Text(timeLabel).font(.subheadline).foregroundStyle(unread ? .primary : .secondary) }
    Text(subject).font(.subheadline).lineLimit(1)
    HStack(alignment: .top) { Text(snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
             Spacer(minLength: 8); LabelChips(userLabels, max: 2) }
  }
}
.listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16))
```
`ThreadRowDTO { id, subject, snippet, participantsLine (computed from participants JSON: "Alice, Bob" / "Alice (3)"), lastDate, isUnread, hasAttachments, messageCount, userLabelIds: [String], labelChips: [(name, textColor, bgColor)] }`. `timeLabel`: today → `HH:mm` (locale), yesterday → "Yesterday", within 6 days → weekday, same year → `d MMM`, else `dd.MM.yy` (`Date.FormatStyle`, locale-aware). `LabelChip`: capsule, `caption2`, colours from Gmail palette (`[gmail-api §11]`), fallback secondary fill.

Swipe actions (Apple's own mail example `[ios-platform §5.2]`): leading `Button { archive } label: { Label("Archive", systemImage: "archivebox") }.tint(.green)` with `allowsFullSwipe: true`; trailing `Button { toggleUnread } label: { Label(isUnread ? "Read" : "Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") }.tint(.blue)`. Both configurable in Settings (`SwipeAction` enum) but default as PLAN.md.

Haptics: `.sensoryFeedback(.impact(weight: .light), trigger: lastActionId)` on swipe completion; `.success` when a send is enqueued; `.error` on a failed op toast (respects `settings.hapticsEnabled`).

SF Symbols used: `tray` (Inbox), `sun.max` (Today), `envelope.badge` (Unread), `tag` (Labels), `gearshape` (Settings), `archivebox`, `envelope.open`, `envelope.badge`, `arrowshape.turn.up.left.2` (Reply all), `arrowshape.turn.up.right` (Forward), `paperclip`, `photo` (Load images), `wifi.slash`, `exclamationmark.triangle`, `arrow.clockwise`, `paperplane` (Send), `xmark` (Cancel), `chevron.down`/`chevron.up` (expand), `checkmark.circle`, `person.crop.circle`, `doc` (attachment generic), `tray.and.arrow.down` (Move to inbox / Undo).

Fonts: system text styles only (`.largeTitle` nav, `.headline`, `.subheadline`, `.body`, `.footnote`, `.caption2`); Dynamic Type respected; `.monospaced` only in the signature editor and diagnostics.

### 8.4 Thread screen composition

Single pooled `WKWebView` is the scroller `[html-rendering §4]`: `NavigationStack` title = `SubjectPrefix.stripForDisplay(thread.subject)`; the web view fills the content; a native `.toolbar(.bottomBar)` holds the four actions. Message headers, collapsed previews, attachment lists, "Load images" buttons and body skeletons are all rendered inside the HTML document (`ThreadDocumentBuilder`) with system font and theme CSS variables; taps come back through `window.webkit.messageHandlers.mm.postMessage({type, id, …})` (app JS keeps working with content JS disabled `[html-rendering §2.1]`). The document is rebuilt (cheap string concat, `loadHTMLString`) whenever the observed `ThreadDetailDTO`, `expanded` or `imagesAllowed` change; scroll position is restored via `scrollTo(0, y)` after `didFinish` when the change was not user-initiated expansion.

Compose quote preview: rendered read-only below the editor **as SwiftUI `Text`** built from `body_text`/`Quoting.textFromHTML` (no second WKWebView, no height measuring). The HTML quote is only assembled at send time.

### 8.5 Filters as SQL (`ThreadListQuery.request`)

Common projection (`:limit` default 300, list paginates by "Load older" for inbox only):

```sql
SELECT t.id, t.subject, t.snippet, t.last_date, t.is_unread, t.has_attachments, t.message_count, t.participants,
       (SELECT json_group_array(DISTINCT ml.label_id) FROM message m2 JOIN message_label ml ON ml.message_id = m2.id
          WHERE m2.thread_id = t.id AND m2.is_hidden = 0 AND ml.label_id LIKE 'Label_%') AS user_label_ids
FROM thread t
WHERE <FILTER> AND (:unreadOnly = 0 OR t.is_unread = 1)
ORDER BY t.last_date DESC
LIMIT :limit
```

| Filter | `<FILTER>` |
|---|---|
| Inbox | `t.in_inbox = 1` |
| Today | `t.last_date >= :startOfTodayMs` — plus, to catch older threads with a new message today, the same predicate is exact because `last_date` is the newest visible message |
| Unread | `t.is_unread = 1` (chip forced on, hidden) |
| Label(id) | `EXISTS (SELECT 1 FROM message m JOIN message_label ml ON ml.message_id = m.id WHERE m.thread_id = t.id AND m.is_hidden = 0 AND ml.label_id = :labelId)` |

`startOfTodayMs = TodayRange.startOfTodayMillis(now, .current, .autoupdatingCurrent)`; recomputed on `.active`, on `NSCalendarDayChanged` and on `NSSystemTimeZoneDidChange` (no timers). Threads whose every message is hidden are never in `thread` (aggregator deletes them), so no `is_hidden` predicate is needed at thread level.

`ValueObservation.trackingConstantRegion { db in try ThreadListQuery.request(...).fetchAll(db) }.start(in: pool, scheduling: .immediate)` `[ios-platform §2.6]` — first paint synchronously from cache.

### 8.6 Actions (`ThreadActions`, main-actor façade over the DB)

```
archive(threadId):     write { ids = ThreadRepository.messageIds; enqueueModify(.thread(id), LabelDelta(remove:[INBOX]), ids) }; outbox.kick(); undo = (opId?, "Archived")
undoArchive(threadId): write { enqueueModify(.thread(id), LabelDelta(add:[INBOX]), ids) }   // coalesces to nothing if the original op is still pending
markRead/Unread:       write { enqueueModify(.thread(id), LabelDelta(remove/add:[UNREAD]), ids) }
```
Every action is one synchronous-feeling call: the transaction commits, the observation fires, the row animates — before any network.

---

## 9. HTML rendering

### 9.1 Sanitizer (`MinimailHTML.Sanitizer`, runs in `BodyLoader`, off main) `[html-rendering §1]`

Pipeline, once per body fetch, result cached in `message_body`:
1. `SwiftSoup.parseBodyFragment(raw, "")`.
2. Images: `cid:X` → `minimail-cid://<messageId>/<percent-encoded X>` (record X in `referencedContentIDs`); `data:image/*` kept; `http(s)` → `data-src` + 1×1 GIF placeholder + class `mm-remote`, `hasRemoteImages = true`; anything else → `src` removed; `srcset/sizes/loading` removed; `[background]` attributes dropped.
3. Tracking pixel heuristic (remote only: ≤ 2 px or hidden, no alt) → element removed.
4. `DarkStrategy.classify(doc)` → `native` if the sender declares `prefers-color-scheme`/`color-scheme`/`supported-color-schemes`; `card` if any background colour/`bgcolor`/`background` or (≥ 3 images and ≥ 2 tables); else `plain`.
5. `SwiftSoup.clean(bodyHTML, "", whitelist)` with the exact whitelist from `[html-rendering §1.3]` (relaxed + `center font hr s del ins abbr address style wbr`; `style class dir lang align valign width height bgcolor border cellpadding cellspacing` on all; `img[data-src]`; `font[face size color]`; `a[href title]`; protocols `a: http https mailto tel`, `img: data minimail-cid`; CSS property allowlist; `preserveRelativeLinks(true)`; enforced `a[target=_self]`).
6. `StyleScrubber.scrub` on the cleaned fragment (`@import`, `@font-face`, non-`data:` `url()`, `expression(`, `behavior:`, `-moz-binding`, `javascript:`, `position:fixed|absolute`).
7. Output `SanitizedBody(html, hasRemoteImages, darkStrategy, referencedContentIDs)`; `sanitizer_version = 1`. On any SwiftSoup throw → fallback `plainTextToHTML(text)`; if no text either → `"<p><i>This message could not be displayed.</i></p>"` and log.

Plain-text-only mails: `plainTextToHTML` = HTML-escape, linkify `https?://` and `www.` tokens into `<a>`, `\n` → `<div>` per line, wrapped in `<div class="mm-plaintext">` (CSS `white-space: pre-wrap`).

### 9.2 WKWebView setup (`WebViewConfigurationFactory`, `WebViewPool`) `[html-rendering §2.4]`

```
config.defaultWebpagePreferences.allowsContentJavaScript = false
config.defaultWebpagePreferences.preferredContentMode = .mobile
config.websiteDataStore = .nonPersistent()
config.dataDetectorTypes = []                       // decision: no data detectors; links come from the mail; phone numbers are not auto-linked
config.setURLSchemeHandler(CIDSchemeHandler(store: inlineImageStore), forURLScheme: "minimail-cid")
config.userContentController.add(RuleLists.blockAll)
config.userContentController.add(bridge, name: "mm")
config.suppressesIncrementalRendering = true
webView.allowsLinkPreview = false; isOpaque = false; backgroundColor = theme.background; underPageBackgroundColor = theme.background
webView.navigationDelegate = LinkPolicy.shared; scrollView.contentInsetAdjustmentBehavior = .automatic
#if DEBUG webView.isInspectable = true #endif
```
`WebViewPool.prepare()` runs after the first inbox paint: compiles/looks up the two rule lists (`minimail.block-all.v1`, `minimail.images-only.v1`) and creates the single instance, warming it with the empty template. `dequeue()` hands it to `MailWebView`; `recycle()` loads the empty template and drops the bridge callbacks. Memory warning → recycle if not on screen.

Rule lists: exactly the JSON of `[html-rendering §2.2]` (`block-all`: block `^https?://`, `^wss?://`, `^ftp://`, `^file://`; `images-only`: same plus `ignore-previous-rules` for `^https://` `resource-type: ["image"]`). If `resource-type` values are rejected at compile time (UNVERIFIED subset), fall back to a list that blocks everything and rely on the CSP variant for the images-on document.

`LinkPolicy`: `.linkActivated` → `http(s)` → `SafariView` sheet (via bridge callback), `mailto:` → copy-address action sheet, `tel:` → `UIApplication.open`; return `.cancel`. `.other` allowed only for `about:blank`. Everything else cancelled `[html-rendering §2.5]`.

### 9.3 Image blocking and "Load images"

Default: images blocked (`settings.loadRemoteImagesByDefault == false`). Each message section with `has_remote_images` shows an HTML button "Load images" (`photo` glyph as inline SVG data URI, themed). Tap → bridge `loadImages(id)` → `ThreadModel.imagesAllowed.insert(id)` → document rebuilt with: (a) for that message's fragment `data-src` copied back to `src`, (b) the document-level CSP meta switched to the images-on variant (`img-src https: data: minimail-cid:`), (c) `userContentController` rule lists swapped to `images-only` **for the whole document** (rule lists are per web view; the CSP is per document; since the other messages' images still carry the placeholder `src`, nothing loads for them). Reload is a local string load — tens of ms `[html-rendering §1.3]`. "Load images" is per open, not persisted (stage 1; a per-sender allowlist is a stage-2 setting).

Inline `cid:` images load automatically (they are attachments, not trackers) through `minimail-cid://` → `InlineImageStore.bytes` → `attachments.get` (5 units) → in-memory + `AttachmentFileCache`. When offline the scheme handler fails the task → broken image glyph; no retry storm (the store caches failures for 60 s).

### 9.4 Dark mode strategy `[html-rendering §3]`

Never invert. Template declares `<meta name="color-scheme" content="light dark">` and `:root{color-scheme:light dark}`; the body class per message section is `mm-plain` / `mm-card` / `mm-native` from `dark_strategy`:
- `plain`: dark overrides (`color: var(--mm-text)`, links `var(--mm-link)`, `[style*="color"]{color:inherit!important}`, `font[color]{color:inherit!important}`).
- `card`: the fragment is wrapped in a white 12 px-radius card with `color-scheme: light`, untouched author colours.
- `native`: no overrides; the sender's own `prefers-color-scheme` CSS runs.
`webView.overrideUserInterfaceStyle` follows `ThemeStore.resolvedScheme` so a forced Light/Dark theme wins inside the web view (UNVERIFIED propagation → Fallback: the template also receives `data-theme="dark|light"` on `<html>` and the CSS uses `html[data-theme=dark]` selectors in addition to the media query; both paths are written from the start, so the fallback is free).

### 9.5 Document template and sizing

Template (`ThreadTemplate.swift`, CSS from `Resources/Web/thread.css`): CSP meta first (`default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`), charset, viewport `width=device-width, initial-scale=1, viewport-fit=cover` (pinch-zoom allowed), color-scheme meta, `<style>` with theme variables (`--mm-bg --mm-text --mm-secondary --mm-accent --mm-separator --mm-link --mm-card`), base rules (`img,table{max-width:100%!important;height:auto}`, `pre{white-space:pre-wrap}`, `-webkit-text-size-adjust:100%`, `font: -apple-system-body` for chrome), then one `<section class="mm-msg" data-id>` per message: header (`from`, date, expand caret, attachment count), collapsed snippet or expanded body (`div.mm-body.mm-plain|card|native`), attachment list (`button.mm-att[data-part]`), "Load images" button. Since the web view is the scroller, there is **no height measurement**; `scrollView` bounces normally; Dynamic Type change → rebuild document on `UIContentSizeCategory.didChangeNotification`.

Performance guards: the document builder caps a single body at 1.5 MB of HTML (beyond that it shows the first 1.5 MB + "Message truncated"), and the whole document at 6 MB (older messages collapsed become previews only until expanded).

---

## 10. Theming

```swift
struct ThemeColors: Sendable, Equatable { var background, surface, text, secondaryText, accent, unread, separator, link, cardBackground: Color }
struct ThemeFonts: Sendable, Equatable { var listTitle: Font = .headline; var listSubtitle: Font = .subheadline; var listSnippet: Font = .footnote; var body: Font = .body }
struct ThemeTokens: Sendable, Equatable {
    var colors: ThemeColors; var fonts: ThemeFonts
    var cssVariables: String   // ":root{--mm-bg:#…;--mm-text:#…;…}" for the web template (hex via UIColor resolution in the given scheme)
}
protocol Theme: Sendable {
    var id: String { get }                      // "light", "dark" (stable, persisted)
    var name: String { get }                    // display
    var baseScheme: ColorScheme { get }         // which scheme this theme is designed for
    var tokens: ThemeTokens { get }
}
struct LightTheme: Theme { … system colours: .systemBackground, .label, .secondaryLabel, .tint, unread = accent, .separator, .link }
struct DarkTheme: Theme  { … same tokens resolved for dark }
enum ThemeRegistry { static let all: [any Theme] = [LightTheme(), DarkTheme()]; static func theme(id: String) -> (any Theme)? }
enum ThemeMode: String, Codable, Sendable { case system, light, dark }

@Observable @MainActor final class ThemeStore {
    init(settings: SettingsStore, systemScheme: ColorScheme)
    var mode: ThemeMode                          // bound to settings.themeMode
    private(set) var current: any Theme          // resolved: system → LightTheme/DarkTheme by systemScheme; light/dark → settings.lightThemeID/darkThemeID
    var tokens: ThemeTokens { current.tokens }
    var preferredColorScheme: ColorScheme?       // nil for system, else the theme's baseScheme → applied with .preferredColorScheme at RootView
    func systemSchemeChanged(_ s: ColorScheme)   // RootView observes @Environment(\.colorScheme) and forwards
}
```
Rules: views read `@Environment(ThemeStore.self)` and use tokens only (`theme.tokens.colors.accent`), never `Color.blue`. The stock themes map to system semantic colours, so the app looks exactly like a system app and adapts to accessibility settings. `RootView` applies `.preferredColorScheme(theme.preferredColorScheme)` and `.tint(theme.tokens.colors.accent)`. Web content receives `tokens.cssVariables` and `overrideUserInterfaceStyle`.

Extensibility: a new theme = one struct + one registry entry; `Settings.lightThemeID/darkThemeID` select it per scheme (so a future "Sepia" can be the light variant while Dark stays). JSON-defined themes later = a `JSONTheme: Theme` struct decoding the token set. Persistence: `Settings.themeMode`, `lightThemeID`, `darkThemeID` (§11); unknown ids fall back to the stock theme.

---

## 11. Settings model

```swift
enum SwipeAction: String, Codable, Sendable, CaseIterable { case archive, toggleUnread, none }

struct Settings: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    // Appearance
    var themeMode: ThemeMode = .system
    var lightThemeID: String = "light"
    var darkThemeID: String = "dark"
    // Compose
    var composeStyle: ComposeStyle = ComposeStyle()          // helvetica / 14 px / #000000
    var signatureHTML: String = ""                           // sanitized on save
    var signatureEnabled: Bool = true
    var forwardKeepsThread: Bool = true                      // §7.3
    // Reading
    var loadRemoteImagesByDefault: Bool = false
    var markReadOnOpen: Bool = true
    var leadingSwipe: SwipeAction = .archive
    var trailingSwipe: SwipeAction = .toggleUnread
    // System
    var showBadge: Bool = false                              // opt-in; triggers UNUserNotificationCenter .badge prompt
    var hapticsEnabled: Bool = true
    var inboxPageSize: Int = 100                             // 50…200
    // Non-user (persisted app state)
    var lastSignedInEmail: String? = nil                     // login_hint
}

@Observable @MainActor final class SettingsStore {
    static let key = "de.newtelco.minimail.settings"
    private(set) var settings: Settings                       // mutate via update { }
    init(defaults: UserDefaults = .standard)                  // JSON decode; on decode failure → defaults + log; migrates by schemaVersion
    func update(_ change: (inout Settings) -> Void)           // encodes with .sortedKeys and writes synchronously
}
```
Persisted as one JSON blob under one key `[PLAN.md]`; `PrivacyInfo.xcprivacy` declares `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` `[ios-platform §7]`.

---

## 12. Performance & battery budget

| Metric | Target | How measured | Tactics |
|---|---|---|---|
| Cold start → first list paint | **< 400 ms** on iPhone 13-class | `coldStart` signpost from `main` to first `ThreadRow.onAppear`; XCTest `measure` on `AppContainer.boot()` | DB open + migrate only (no network) on the main path; Keychain read async; `ValueObservation … scheduling: .immediate`; no WebView creation before first paint; no font/asset loading |
| Delta sync with no changes | **< 600 ms**, 1 request | `deltaSync` signpost | single `history.list` (2 units); label counts skipped if last fetched < 5 min ago |
| Delta sync with 20 new messages | **< 2 s** | signpost | one batch of 20 metadata gets; one transaction |
| Thread open (cached bodies) | **< 150 ms** to `didFinish` | `threadOpen` signpost | pooled warm WebView; document ≤ 6 MB cap; no height measurement |
| Thread open (bodies to fetch) | skeleton in < 150 ms; bodies ≤ 1.5 s on LTE | | batch of ≤ 10 full gets; sanitize off main |
| List scroll | 60 fps, no hitching at 500 rows | Instruments Animation Hitches | `List` with stable `id`, prefetched DTO (no per-row queries), label chips precomputed in SQL |
| Memory (app process) | **< 80 MB** typical, < 150 MB peak | Instruments Allocations | one WKWebView (out-of-process); bodies not held in memory beyond the open thread; GRDB automatic memory management |
| Network when idle (foreground) | **0 requests** | Proxyman/Charles session | no timers; ValueObservation only |
| Background | ≤ 1 `history.list` + ≤ 2 batches per BG refresh; **0** body fetches | `bg` log category | `.background` reason path excludes bodies, label counts if fresh, reconcile |
| Quota | ≤ 2,100 units per full sync; ≤ 60 units per idle delta | `net` log units counter | pessimistic table; batches ≤ 25 for gets |
| DB | list query < 10 ms at 5k messages | XCTest `measure` with seeded DB | covering indexes (§3.2); `message_label` join instead of JSON scans |
| Battery | Energy impact "Low" in Xcode gauge over a 10-min session | manual | no location/BLE/audio; WebView has no JS timers; images off by default; no polling |

Additional tactics: `URLSession` HTTP/2 connection reuse (one session); `fields=` + `prettyPrint=false` cut metadata payloads ~50 %; bodies fetched newest-first so the visible message renders first; `Pruner` keeps the DB < ~150 MB; attachments never prefetched; `AttachmentFileCache` in `Caches` (purgeable).

---

## 13. Testing strategy

### 13.1 Unit tests — `MinimailCore` package (Linux `swift test`, seconds)

| File | What it pins |
|---|---|
| `Base64URLTests` | vectors `[mime-rfc §8.3]`; padded/unpadded; both alphabets; rejects invalid chars |
| `QuotedPrintableTests` | encode vectors (`Grüße`, `a=b`, trailing space, tab, 80×x soft break, `-- ` → `--=20`); decode tolerant cases; round-trip random UTF-8 |
| `RFC2047Tests` | decode table `[mime-rfc §8.3]` incl. folded adjacent words, missing pad, unknown charset unchanged; encode ≤ 75 per word, ASCII passthrough, split never inside a UTF-8 sequence |
| `RFC2231Tests` | filename table incl. continuations, `*lang`, extended-wins, illegal encoded-word tolerance; encoder output for `Ängebot.pdf` |
| `AddressParserTests` | table `[mime-rfc §8.4]` + groups, obs-route, empty list members, folded input, comment-as-name |
| `MailboxSerializationTests` | quoting specials, RFC 2047 name, bare addr |
| `RFC5322DateTests` | parse obsolete forms, zone names, comments; format `Fri, 11 Sep 2026 10:00:00 +0200` |
| `ContentTypeParamsTests` | charset/boundary/name extraction; quoted values; case |
| `MessageIDsTests` | References splitting with folds and junk tokens; generate format |
| `MIMEBuilderTests` | **byte-exact** reply (`sha256 b9f8078c…`, raw string from `[mime-rfc §7.1]`), forward variants (with/without In-Reply-To), header folding at 78, CRLF everywhere, 998-octet max line, boundary uniqueness, base64 76-col wrapping, RFC 2231 attachment name |
| `ReplyAllTests` | 16 vectors `[mime-rfc §8.1]` |
| `SubjectPrefixTests` | table `[mime-rfc §8.2]` + `stripForDisplay` |
| `QuotingTests` | attribution string with U+202F; reply HTML skeleton equality; plain `> ` rules incl. empty lines; forward banner 10/9 dashes, header order, Cc omitted when empty; `textFromHTML` |
| `OutgoingHTMLTests` | wrapper/inline CSS, `<div><br></div>` empty lines, escaping, signature block markup, quote outside wrapper, no color-scheme meta |
| `ComposeStyleTests` | clamping, hex validation, css strings |
| `DTODecodingTests` | every fixture JSON decodes; `StringUInt64` from string and number; unknown fields ignored; `format=metadata` payload without parts |
| `PayloadParserTests` | shapes (a)–(h) `[mime-rfc §5.2]`: bare text, alternative, mixed+pdf, related+cid, Outlook nested, signed, report, attachmentId-only html; charset handling (ISO-8859-1, windows-1252, missing); inline detection by Content-ID vs disposition; deferred text parts |
| `BatchEncoderTests` | exact wire bytes for the 2-call sample `[gmail-api §12]` (CRLF, Content-ID, inner request line, inner JSON body) |
| `BatchParserTests` | parses the observed response sample; mixed 200/401/429 parts; matches by Content-ID out of order; missing part; garbage → ParseError |
| `LabelAlgebraTests` | effective() over sequences; flags; sortedJSON stability |
| `HistoryReducerTests` | add→delete cancels; delete→add re-adds; label ops chronological; finalLabels last-wins; multi-page; empty history keeps `historyId`; touchedThreads |
| `OutboxCoalescerTests` | read→unread cancels; archive+read merges; add∩remove cleanup; idempotent merge |
| `BackoffTests` | deterministic delays with injected random; cap; Retry-After precedence |
| `HydrationPolicyTests` | rule matrix (unknown labels, known thread, cached label, spam/trash/draft) |
| `TodayRangeTests` | table-driven over TZs (Europe/Berlin DST edges, Pacific/Auckland, UTC-11), 23:59:59 vs 00:00:00 boundaries |
| `ThreadAggregatorTests` | subject from earliest, snippet from newest, counts, participants dedupe/self flag, empty → nil |
| `MinimailHTMLTests/SanitizerTests` | script/iframe/form/meta removal; `on*` attrs; `javascript:` hrefs; remote img → data-src+placeholder; cid rewrite + referenced set; data: image kept; tracking pixel removed; `<style>` scrub cases; DarkStrategy classification matrix; whitelist keeps tables/fonts/inline styles; malformed HTML (unclosed tags, `<!--[if mso]>`) does not throw; 2 MB newsletter under 300 ms |
| `MinimailHTMLTests/QuoteExtractorTests`, `SignatureSanitizerTests` | data-src restore; cid back-mapping; signature keeps https img, drops script |

### 13.2 Fixtures (`Packages/MinimailCore/Tests/Fixtures/`)

- `gmail/profile.json`, `labels.list.json`, `labels.get.inbox.json`, `labels.get.user.json`
- `gmail/messages.list.inbox.json` (100 ids, 2 pages), `messages.get.metadata.*.json` (plain, multipart, non-ASCII headers, folded References, no Message-ID), `messages.get.full.{a..h}.json` (the eight shapes), `messages.get.full.large-text-attachmentid.json`, `attachments.get.png.json`, `attachments.get.pdf.json`
- `gmail/history.{empty,added,deleted,labels,mixed,added-then-deleted,paged-1,paged-2,own-modify-echo}.json`, `history.404.json`, `error.{401,403-rate,403-admin,429,500,400-invalid-history}.json`
- `gmail/threads.get.metadata.json`, `threads.modify.response.json`, `messages.modify.response.json`, `send.response.json`
- `gmail/batch.request.sample.txt` (exact bytes), `batch.response.sample.txt`, `batch.response.mixed.txt`
- `mime/reply-all.eml` + `.sha256` + `.raw.txt`, `mime/forward-pdf.eml` (both variants), `mime/gmail-web-reply-fixture.eml`, `mime/gmail-web-forward-fixture.eml`, `mime/stub.pdf`
- `html/newsletter.html`, `html/plain-mail.html`, `html/dark-native.html`, `html/tracking-pixels.html`, `html/malformed.html`, `html/inline-cid.html`, `html/signature.html`
- `vectors/*.json` — the tables (QP, RFC 2047, base64, RFC 2231, addresses, reply-all, subject, today) as data so tests are table-driven

### 13.3 App-target tests (`minimailTests`, simulator)

- `MigrationsTests`: fresh DB matches the DDL (compare `sqlite_master` SQL), foreign keys on, invariants hold on empty DB.
- `MessageRepositoryTests`, `OutboxRepositoryTests`: enqueue/coalesce/ack/discard flows; `label_ids` invariant after each step; `message_label` mirror; thread aggregates.
- `ThreadListQueryTests`: seeded 5k messages; each filter returns the expected ids; unread chip; Today boundary; `measure` < 10 ms.
- `FullSyncTests` (FakeTransport scripted from fixtures): baseline historyId ordering; generation deletion keeps outbox-referenced rows; progress reporting; 404 on a metadata part is skipped.
- `DeltaSyncTests`: each history fixture produces the expected DB; own-modify echo is idempotent; unknown-message fetch policy; paging; `historyId` never decreases; `tooManyRecords` → resync.
- `HistoryExpiryTests`: 404 → full resync → delta from new baseline; 400 invalid → same.
- `ConflictTests` (the heart of this candidate): interleavings — (1) archive locally, history says another client marked unread, ack arrives → final `E` = server ∖ INBOX with UNREAD; (2) ack before history echo; (3) history echo before ack; (4) full resync while op pending → message kept, op applied after resync; (5) op 404 → row removed by next delta; (6) two rapid toggles → zero network calls; (7) thread op with a message arriving later → later message untouched locally, server truth wins.
- `OutboxWorkerTests`: batch of 50 with mixed part results; backoff scheduling; offline gate; in_flight release at launch; failed re-arm on foreground.
- `SendOperationTests`: maybe_sent + rfc822msgid found → no second send; not found → resend; attachment re-resolution on 404; > 25 MB refused; upload path chosen > 5 MB; permanent 400 → failed + banner state.
- `GmailAPITests`: status→error mapping table; 401→refresh→retry→401→unauthenticated; retry counts per error; `Retry-After` honoured; batch part retry rounds; limiter blocks and releases; request URL shape (repeated params, fields).
- `ThreadDocumentBuilderTests`: document contains CSP variant per images state; sections per message; expanded/collapsed; caps; theme variables; escaping of header fields.
- `ThreadRowSnapshotTests`: 3 snapshots (unread light, read dark with chips, long participants) on `iPhone 17` iOS 26.5.
- `AppContainer` under `MINIMAIL_TESTING=1`: uses `FakeTransport` + `FakeTokenProvider` + in-memory DB seeded from fixtures — shared by the UI smoke test.

### 13.4 UI test (exactly one)

`SmokeTests.testInboxShowsSeededMailAndUnreadFilter`: launch with `MINIMAIL_TESTING=1`; assert the seeded subject cell exists; tap the "Unread" chip; assert only unread rows remain; open the first thread; assert the navigation title. Runs on `main` pushes only `[tooling §7.3]`.

### 13.5 Device checklist (manual, M2/M4; recorded in `docs/plan/device-checklist.md` by the agent)

Content rule lists compile with `resource-type`; no network egress from the web view with a proxy attached; `evaluateJavaScript` works with content JS off; CSP `img-src minimail-cid:` accepted; BG refresh fires (LLDB `_simulateLaunchForTaskWithIdentifier:`) and survives a locked device; `[.badge]` prompt and `setBadgeCount`; AppAuth under Swift 6; real `history.list` after 8+ days idle returns 404 and recovery works; `after:` epoch query not needed (Today is local).

---

## 14. Risks and open questions — with resolutions

| # | Risk / open question | Resolution in this design |
|---|---|---|
| 1 | Quota-unit table and per-user limit UNVERIFIED (`messages.get` 5 vs 20; 6,000 vs 15,000/min) `[gmail-api "Quotas"]` | Pessimistic constants in `QuotaTable`; limiter at 80 units/s; batches ≤ 25 for gets. Verify on the real quota page at M1 and only ever relax. |
| 2 | Whether history change records carry the message's current `labelIds` (SNIPPET) | Reducer uses them when present (`finalLabels`), else applies deltas; both paths tested. Daily `Reconciler` bounds any drift. |
| 3 | `historyId` expiry (404, sometimes within hours) | Explicit `historyExpired` path → cheap full resync (≈2k units) with generation-based cleanup; tested. |
| 4 | Non-idempotent `messages.send`; duplicate sends after timeouts | `transmit_state` persisted before the request + `rfc822msgid:` check before any retry; own `Message-ID` always set. |
| 5 | `threads.modify` / `messages.modify` response shape UNVERIFIED | Ack applies the delta to `server_label_ids` regardless; response `labelIds` (if present) override. |
| 6 | `batchModify` has no per-id results and unknown failure semantics | Not used. HTTP batch of individual `threads.modify` calls with per-part results (≤ 50/batch). |
| 7 | `attachmentId` instability | Transient column; re-resolve via fresh `messages.get` on 404 (§7.6). |
| 8 | Large text bodies delivered by `attachmentId` only | `deferredTextParts` path in `BodyLoader`. |
| 9 | `format=metadata` gives no attachment info | `Content-Type` in `metadataHeaders` + `payload.mimeType` → `attachment_hint`; exact after body fetch. |
| 10 | Thread only partially known after `messages.list` hydration | `is_complete` flag + `threads.get?format=metadata` on open (40 units, once). |
| 11 | Optimistic op vs concurrent change from another client | `S`/`P`/`E` model (§4.7); user's op wins by being applied last; documented. |
| 12 | App killed mid-request | Outbox `in_flight` released at launch; sends go through the `maybe_sent` check; every DB write is one transaction; `historyId` advanced only after commit. |
| 13 | Offline for a week; BG refresh with locked device | Outbox survives; 404 → resync; `completeUntilFirstUserAuthentication` on the DB dir; BG handler tolerates `SQLITE_AUTH`. |
| 14 | Workspace admin blocks the client (`admin_policy_enforced`) | Sign-in screen shows the exact remedy text; README checklist item precedes first login. |
| 15 | Refresh token revoked (password change, 6-month idle, 50-token cap) | `invalid_grant` → `.needsReauth` sheet; cache and outbox preserved; no retry loop. |
| 16 | Forward threading semantics (In-Reply-To on forwards) | Mirror Gmail web (all three set); `forwardKeepsThread=false` omits all three together. |
| 17 | `data:` images in signatures are not rendered by Gmail | Signature editor warns on `data:` `img src` and recommends an https URL `[mime-rfc §3.4]`; no cid signature parts in stage 1. |
| 18 | SwiftSoup `<style>` copied verbatim; possible layout escapes | `StyleScrubber` + CSP + rule list + no content JS = four independent layers. |
| 19 | Content-rule-list `resource-type` vocabulary UNVERIFIED | Fallback list without `resource-type`; CSP variant carries the images-on policy. |
| 20 | `overrideUserInterfaceStyle` → `prefers-color-scheme` propagation UNVERIFIED | Template also uses `html[data-theme]` selectors from day one. |
| 21 | Swift 6 + `MainActor` default vs GRDB/AppAuth closures | Engine/store code is explicit `actor`/`nonisolated`; escape hatch `nonisolated` default documented `[tooling §3.3]`; the package is nonisolated so most code never sees the issue. |
| 22 | Linux Foundation differences for the core package | Core avoids `NSRegularExpression`/CoreFoundation; charset table is pure Swift; CI runs both Linux and macOS. |
| 23 | "Today" across time zones / midnight rollover | Local computation from `internal_date`; `NSCalendarDayChanged` + TZ-change notifications; TZ table tests. No server `after:` query. |
| 24 | Today view semantics (inbox-only or all?) | Decision: any visible thread with a message received today, archived or not — predictable and cheap; documented in the view menu subtitle "Received today". |
| 25 | Unread counts for labels we don't fully cache | Inbox count local (matches the list); other labels show server `threadsUnread`; footer says so. |
| 26 | Very large threads / bodies | Document caps (1.5 MB per body, 6 MB per document); collapsed messages are previews. |
| 27 | Cache growth | `Pruner` bounds bodies (120 MB), attachments (200 MB), stale threads (30 d). |
| 28 | Typed text lost on crash | Compose autosave file + "Resume draft" banner. |
| 29 | Badge requires notification permission | Opt-in toggle; prompt in context; if `[.badge]` is denied the toggle shows "Off in Settings". |
| 30 | Second account / account switch | Single-account by design; email mismatch at sign-in wipes the DB; documented in Settings → Account. |
| 31 | Xcode 27 / iOS 27 arriving 2026-09-14 | Pin 26.6 now; bump when the runner has 27 GA; deployment target unchanged. |
| 32 | XcodeGen target-level `configFiles` acceptance | Fallback: `#include` in `Signing.xcconfig`. |
| 33 | Upload path (`uploadType=multipart` with `threadId`) UNVERIFIED | Fallback to `uploadType=media` without `threadId` for > 5 MB forwards. |
| 34 | `rfc822msgid:` search latency after a send (index delay) | The check runs only on retry after a `maybe_sent` failure, typically ≥ 2 s later; if not found and the resend then 400s as duplicate-free but a duplicate appears, it is the one known residual risk — logged with `outbox.send.duplicate-risk`. |

### 14.1 Milestone mapping (unchanged from PLAN.md, with robustness gates)

- **M1**: project.yml, package skeleton with `Base64URL`, DTOs, `BatchRequest/Response`, `LabelAlgebra`, `HistoryReducer` + tests green on Linux; app: DB v1, AppAuth sign-in, full sync → inbox list; dark mode via ThemeStore. Gate: `ConflictTests` (1)–(3) pass.
- **M2**: delta sync + expiry recovery, thread completion, body loader + sanitizer, thread screen, Today/Unread/Label views, thread-level outbox modifies with coalescing, reconcile. Gate: invariant tests + `DeltaSyncTests` all green; device checklist items 1–4.
- **M3**: MIME builder byte-exact, reply-all, forward + attachments, send op with idempotency, compose UI with autosave, signature + compose style. Gate: `MIMEBuilderTests` sha256 pins; `SendOperationTests`.
- **M4**: settings screens, diagnostics, BG refresh, badge, pruner, snapshot + UI smoke test, TestFlight upload from CI.
