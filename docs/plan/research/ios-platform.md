# iOS platform research — minimail (as of 2026-09-11)

Scope: the iOS-side building blocks for a SwiftUI Gmail client (AppAuth-iOS, GRDB, BackgroundTasks, WKWebView, SwiftUI iOS 17 APIs, Keychain, QuickLook, Swift 6 concurrency, badge). Everything below was checked against the sources listed at the end on 2026-09-11. Items I could not confirm from an official source are tagged **UNVERIFIED**. Exact API names are given in Apple's Swift spelling.

Legend: `[A]` Apple developer documentation · `[GH]` GitHub source/README/CHANGELOG · `[SE]` Swift Evolution · `[3P]` third-party (lower trust).

---

## 0. Toolchain and deployment floor (decision input)

| Fact | Value | Source |
|---|---|---|
| Latest stable Xcode | **Xcode 26.6** (SDK iOS 26.5; min deployment iOS 15; runs on macOS Tahoe 26.2+) | `[A]` https://developer.apple.com/support/xcode/ |
| Xcode 27 | **RC** as of 2026-09-11; Swift **6.4**; iOS 27 SDK; requires macOS Tahoe 26.6+; min deployment iOS 15; on-device debugging **iOS 17+** | `[A]` https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes , https://developer.apple.com/support/xcode/ |
| Xcode 26.0 | Swift 6.2, iOS 26 SDK, requires macOS Sequoia 15.6+ | `[A]` https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes |
| App Store SDK rule | Since **2026-04-28** iOS apps must be built with the **iOS 26 SDK or later** | `[A]` https://developer.apple.com/news/upcoming-requirements/ |
| iOS 27 public release | 2026-09-14 (`[3P]` MacRumors https://www.macrumors.com/2026/09/09/apple-announces-ios-27-release-date/ — **UNVERIFIED** against Apple) | |
| Apple versioning | iOS 18 → iOS 26 (2025) → iOS 27 (2026). There is no "iOS 19–25". | `[3P]` Wikipedia; consistent with Apple release notes above |

**Recommendation on the floor: keep `IPHONEOS_DEPLOYMENT_TARGET = 17.0`; build with the iOS 26 SDK (Xcode 26.6 today, Xcode 27 when final).**
Evidence:
- Every Stage-1 API is iOS ≤ 17.0: `@Observable` (17.0), `ContentUnavailableView` (17.0), `.environment(_:)` for Observable objects (17.0), `@Bindable` (17.0), `NavigationStack` (16.0), `.swipeActions` (15.0), `.refreshable` (15.0), `.searchable` (16.0), `.backgroundTask(.appRefresh)` (16.0), `setBadgeCount` (16.0), `WKWebpagePreferences.allowsContentJavaScript` (14.0), `WKContentRuleListStore` (11.0), `.quickLookPreview` (14.0). All `[A]` (see per-section citations).
- The only things that would justify an **iOS 26** floor: the SwiftUI-native `WebView`/`WebPage` (iOS 26.0, `[A]` https://developer.apple.com/documentation/webkit/webview-swift.struct) which would replace the `UIViewRepresentable` wrapper, and `TextEditor` attributed-text editing (`[A]` TextEditor page says attributed text is supported "when initialized with AttributedString" — version not stated on the page; **UNVERIFIED** that this is 26.0). Neither is needed; the WKWebView wrapper is ~80 lines. Not strong evidence → keep iOS 17.
- Hand-rolled auth caveat: `ASWebAuthenticationSession.init(url:callback:completionHandler:)` is **17.4+**; the older `init(url:callbackURLScheme:completionHandler:)` is deprecated but still available for 17.0–17.3 (`[A]` topic list on https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession). AppAuth handles this internally.
- Xcode 27 can only debug on iOS 17+ devices, which is consistent with a 17.0 floor.

Headless build note (for the executing agent): iOS apps cannot be built on Linux; a macOS runner with Xcode and `xcodebuild` is required. Generate the `.xcodeproj` from a YAML spec with **XcodeGen 2.46.0** (tag dated 2026-07-16, `[GH]` https://github.com/yonaskolb/XcodeGen — tag list via `git ls-remote`) so the project is fully reproducible from files: `xcodegen generate && xcodebuild -scheme minimail -destination 'generic/platform=iOS' build`. Swift packages are declared in `project.yml` under `packages:`.

---

## 1. AppAuth-iOS

### 1.1 Version / SPM
- Latest tag: **3.0.0**, commit dated **2026-08-24** (`git clone --branch 3.0.0` → `git log`). Previous: 2.1.0, 2.0.0. `[GH]` https://github.com/openid/AppAuth-iOS/blob/master/CHANGELOG.md
- 3.0.0 CHANGELOG (verbatim points): "BREAKING: Updates made to support Xcode 27"; "Raised minimum deployment targets to iOS 15.0, macOS 12.0, tvOS 15.0 and watchOS 9.0"; "`swift-tools-version` bump from 5.3 to 5.7"; "`resumeExternalUserAgentFlowWithURL:error:` is now required in `OIDExternalUserAgentSession`"; "Swift callers now spell the method `resumeExternalUserAgentFlow(_:)`". 2.1.0: "Removed external browser (Safari) fallback from `OIDExternalUserAgentIOS`" and added a SwiftUI + SPM sample under `Examples/Example-iOS_Swift-SPM`.
- `Package.swift` (`[GH]` https://github.com/openid/AppAuth-iOS/blob/master/Package.swift): `swift-tools-version:5.7`, `platforms: [.iOS(.v15), ...]`, products **`AppAuthCore`**, **`AppAuth`** (iOS/macOS, this is the one to link), `AppAuthTV`. Ships `PrivacyInfo.xcprivacy` resources.
- The library is **Objective-C** (headers under `Sources/AppAuthCore/*.h`). No Swift concurrency annotations: callbacks arrive on arbitrary threads/queues → hop to `MainActor` yourself.

```swift
// Package dependency (project.yml `packages:` or Package.swift)
.package(url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMajor(from: "3.0.0"))
// target dependency
.product(name: "AppAuth", package: "AppAuth-iOS")
```
(README still shows `from: "1.3.0"`; use 3.0.0 — `[GH]` README "Swift Package Manager" section.)

### 1.2 Core API names (from headers, `[GH]` `Sources/AppAuthCore/*.h`, `Sources/AppAuth/iOS/*.h`)
- `OIDServiceConfiguration(authorizationEndpoint:tokenEndpoint:)` (ObjC `initWithAuthorizationEndpoint:tokenEndpoint:`); or discovery `OIDAuthorizationService.discoverConfiguration(forIssuer:completion:)` (ObjC `discoverServiceConfigurationForIssuer:completion:`).
- `OIDAuthorizationRequest(configuration:clientId:scopes:redirectURL:responseType:additionalParameters:)` (also a variant with `clientSecret:` and one with `nonce:`). Constants `OIDResponseTypeCode`, `OIDScopeOpenID`, `OIDScopeProfile`. PKCE (`codeVerifier`/`codeChallenge`/`codeChallengeMethod`) is generated automatically by this initializer (the full designated init exposes them; `+generateCodeVerifier` exists).
- `OIDExternalUserAgentIOS(presentingViewController:)` and **`OIDExternalUserAgentIOS(presentingViewController:prefersEphemeralSession:)`** (`API_AVAILABLE(ios(13))`; header comment: "See `ASWebAuthenticationSession.prefersEphemeralWebBrowserSession`").
- `OIDAuthState.authState(byPresenting:presenting:callback:)` (ObjC `authStateByPresentingAuthorizationRequest:presentingViewController:callback:`) and `OIDAuthState.authState(byPresenting:externalUserAgent:callback:)` — returns `OIDExternalUserAgentSession` which you must retain.
- `OIDExternalUserAgentSession.resumeExternalUserAgentFlow(_:)` (throws), `.cancel()`, `.failExternalUserAgentFlow(with:)`.
- `OIDAuthState`: `isAuthorized`, `refreshToken`, `lastTokenResponse`, `lastAuthorizationResponse`, `stateChangeDelegate` (`OIDAuthStateChangeDelegate`), `errorDelegate` (`OIDAuthStateErrorDelegate`), **`performAction(freshTokens:)`** (ObjC `performActionWithFreshTokens:`; block type `OIDAuthStateAction = (accessToken: String?, idToken: String?, error: Error?) -> Void`), `setNeedsTokenRefresh()`, `update(with:error:)`. Conforms to **`NSSecureCoding`** (`@interface OIDAuthState : NSObject <NSSecureCoding>`).
- Error codes added in 2.1.0: `OIDErrorCodeURLMismatch`, `OIDErrorCodeInvalidAuthorizationFlow`.

### 1.3 Ephemeral vs shared browser session
`ASWebAuthenticationSession.prefersEphemeralWebBrowserSession: Bool` (iOS 13+): "Set … to `true` to request that the browser doesn't share cookies or other browsing data between the authentication session and the user's normal browser session. Safari always respects the request. … The value of this property is `false` by default. Set this property before you call `start()`." `[A]` https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/prefersephemeralwebbrowsersession

Trade-off for minimail:
- `prefersEphemeralSession: false` (default): reuses Safari's Google cookies → if the owner is already signed in to Google in Safari, login is one tap (account chooser). iOS shows the "wants to use google.com to sign in" consent sheet in both modes.
- `prefersEphemeralSession: true`: always a fresh login (password + 2FA/passkey), nothing written to Safari cookies. Cleaner sign-out semantics.
- Recommendation: **`false`** (shared) for a single-account work app — fastest login; token lifetime is governed by the refresh token, not cookies. Sign-out = delete Keychain item; Google session in Safari is untouched either way.

### 1.4 Flow in a SwiftUI `App` (verified against `[GH]` `Examples/Example-iOS_Swift-SPM/Example/{ExampleApp,AppDelegate,AuthManager}.swift`)

The official SwiftUI sample keeps an `AppDelegate` (via `@UIApplicationDelegateAdaptor`) holding `currentAuthorizationFlow` and resumes it from `application(_:open:options:)`. Since `OIDExternalUserAgentIOS` uses `ASWebAuthenticationSession`, whose redirect is delivered "through a completion handler" (`[A]` ASWebAuthenticationSession overview), the `open:` / `onOpenURL` path is a fallback; keep it anyway (the README documents it, cost is 6 lines). Pure-SwiftUI equivalent:

```swift
import AppAuth
import SwiftUI

@main
struct MinimailApp: App {
    @State private var auth = AuthStore()          // @Observable, @MainActor
    var body: some Scene {
        WindowGroup {
            RootView().environment(auth)
                .onOpenURL { url in                 // [A] onOpenURL(perform:) iOS 14+
                    _ = try? auth.currentFlow?.resumeExternalUserAgentFlow(url)
                    auth.currentFlow = nil
                }
        }
    }
}

@MainActor @Observable
final class AuthStore {
    var authState: OIDAuthState?
    var currentFlow: OIDExternalUserAgentSession?

    func signIn() {
        let config = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)   // endpoints: see gmail-api research doc
        let request = OIDAuthorizationRequest(
            configuration: config,
            clientId: clientID,                                   // com.googleusercontent.apps.<id> reversed → see gmail doc
            scopes: ["https://www.googleapis.com/auth/gmail.modify", OIDScopeEmail],
            redirectURL: URL(string: "com.googleusercontent.apps.<id>:/oauth2redirect")!,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil)
        guard let vc = presentingViewController() else { return }
        let agent = OIDExternalUserAgentIOS(presentingViewController: vc, prefersEphemeralSession: false)!
        currentFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { [weak self] state, error in
            Task { @MainActor in                                   // AppAuth callbacks are not MainActor-isolated
                self?.currentFlow = nil
                self?.authState = state
                self?.persist()
            }
        }
    }

    private func presentingViewController() -> UIViewController? {   // same as AppAuth sample
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow)?.rootViewController
    }
}
```

Info.plist (`[A]` CFBundleURLTypes; `[GH]` sample Info.plist uses exactly this shape):
```xml
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>CFBundleURLSchemes</key>
  <array><string>com.googleusercontent.apps.&lt;client-id-prefix&gt;</string></array>
</dict></array>
```

### 1.5 Persisting `OIDAuthState` (Keychain, not UserDefaults)
The sample stores it in `UserDefaults` — **do not copy that**; refresh tokens are secrets. Serialize exactly as the sample does and put the `Data` in the Keychain (§5.6):
```swift
let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
```
Persist on every `OIDAuthStateChangeDelegate.didChange(_:)` (token responses replace the access token; Google may rotate refresh tokens). Set `authState.stateChangeDelegate = self` after load and after login (sample `setAuthState`).

### 1.6 Token refresh
```swift
func accessToken() async throws -> String {
    guard let state = authState else { throw AuthError.signedOut }
    return try await withCheckedThrowingContinuation { cont in
        state.performAction { accessToken, _, error in    // performAction(freshTokens:) — refreshes if expired
            if let token = accessToken { cont.resume(returning: token) }
            else { cont.resume(throwing: error ?? AuthError.unknown) }
        }
    }
}
```
README: use `performActionWithFreshTokens:` "to perform their API calls to avoid" expired tokens; it refreshes automatically when needed and reports refresh failures to `errorDelegate` (`[GH]` README "Making API Calls", `OIDAuthState.h` comments). Call `setNeedsTokenRefresh()` after a 401 to force a refresh on the next action. AppAuth serializes concurrent `performAction` calls internally (**UNVERIFIED** — not stated in docs; wrap your `accessToken()` in an `actor` with a single in-flight refresh `Task` to be safe).

### 1.7 Alternative: hand-rolled PKCE with `ASWebAuthenticationSession` (no dependency)
Verified Apple pieces (`[A]` https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession and children):
- `ASWebAuthenticationSession(url:callback:completionHandler:)` (17.4+) with `callback: .customScheme("com.googleusercontent.apps.<id>")`; deprecated `init(url:callbackURLScheme:completionHandler:)` for 17.0–17.3.
- `prefersEphemeralWebBrowserSession`, `presentationContextProvider: ASWebAuthenticationPresentationContextProviding` (`@MainActor` protocol; return the key `UIWindow` from `presentationAnchor(for:)`), `start() -> Bool` ("Only call this method once"; the session retains itself after `start()` on iOS 13+ deployment targets), `cancel()`, `canStart`.
- PKCE: 32 random bytes via `SecRandomCopyBytes` → base64url `code_verifier`; `code_challenge = base64url(SHA256(verifier))` via `CryptoKit.SHA256`; `code_challenge_method=S256`; `state` nonce; token exchange and refresh = two `URLSession` POSTs with `application/x-www-form-urlencoded` (exact Google params: gmail-api research doc).

Honest weighing for a solo, single-provider, single-scope app:

| | AppAuth-iOS 3.0.0 | Hand-rolled |
|---|---|---|
| Code you own | ~60 lines glue | ~200–250 lines (PKCE, URL building, token store, refresh with single-flight, error mapping) |
| Swift 6 fit | ObjC, callback-based, not `Sendable`-annotated; needs continuations + `@MainActor` hops; `OIDAuthState` is a mutable class | Native `async/await`, `actor TokenStore`, `Codable` struct tokens in Keychain |
| Correctness risk | Low: spec-compliant PKCE, well-tested refresh/expiry logic, error taxonomy | Medium: you must get base64url, expiry skew, `invalid_grant` → sign-out, refresh-token rotation right |
| Maintenance | Active (3.0.0 shipped for Xcode 27, 2026-08); Apache-2; privacy manifest included | Zero external churn |
| Binary/complexity | Adds dynamic registration, end-session, discovery, TV code you never use | Minimal |

Verdict: **Keep AppAuth (accepted baseline)** — the refresh/expiry edge cases are where solo projects lose days, and 3.0.0 is freshly maintained. But isolate it behind a tiny protocol so it can be swapped for a hand-rolled implementation in an afternoon if Swift 6 friction becomes annoying:
```swift
protocol TokenProvider: Sendable { func accessToken() async throws -> String; func signOut() async }
```

---

## 2. GRDB.swift

### 2.1 Version / SPM / requirements
- Latest tag **v7.11.1**, commit dated **2026-06-18** (`git log` of the tag). Recent: 7.11.0, 7.10.0, 7.9.0. `[GH]` https://github.com/groue/GRDB.swift/blob/master/CHANGELOG.md
- README header: "**Requirements**: iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 7.0+ • SQLite 3.20.0+ • **Swift 6.1+ / Xcode 16.3+**". `[GH]` https://github.com/groue/GRDB.swift/blob/master/README.md
- `Package.swift`: `swift-tools-version:6.1`; products **`GRDB`** (use this), `GRDB-dynamic`, `GRDBSQLite`; `swiftSettings` define **`SQLITE_ENABLE_FTS5`** and `SQLITE_ENABLE_SNAPSHOT` by default → the FTS5 API is compiled in for SPM users. (The older `Documentation/FullTextSearch.md` sentence "you'll need a custom SQLite build" predates this; the system SQLite on iOS includes FTS5 — **UNVERIFIED** from Apple docs, but GRDB's own SPM manifest enabling it for `.iOS` is strong evidence.)
```swift
.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1"))
.product(name: "GRDB", package: "GRDB.swift")
```

### 2.2 DatabaseQueue vs DatabasePool (`[GH]` DocC `DatabaseConnections.md`, `Concurrency.md`, `DatabasePool.md`)
- `DatabaseQueue`: one connection, all reads/writes serialized; supports in-memory DBs (`DatabaseQueue()` — use in unit tests/previews).
- `DatabasePool`: one writer connection + a pool of readers; **"Unless `Configuration/readonly`, the database is set to the WAL mode"**; "reads can run in parallel, and can even run during write operations"; writes still serialized. `Configuration.maximumReaderCount` caps readers.
- GRDB's own advice: "If you are not sure, choose `DatabaseQueue`."
- **For minimail choose `DatabasePool`**: the sync engine writes batches while the list view observes/reads; WAL lets the UI read during a sync write, and `ValueObservation.trackingConstantRegion` can then fetch off the main thread (§2.6). Rule 1 of Concurrency: open exactly **one** `DatabasePool` per file for the app's lifetime.
- Location (DocC "Opening a Connection"): Application Support, inside a dedicated directory:
```swift
let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
let dir = appSupport.appendingPathComponent("minimail-db", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let dbPool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
```
  Data-protection caveat (same doc): on a locked device, a data-protected DB throws `DatabaseError` `SQLITE_IOERR` (10) or `SQLITE_AUTH` (23). BG refresh (§3) can run while locked → either catch and end the task, or set the directory's `FileProtectionType` to `.completeUntilFirstUserAuthentication` (**UNVERIFIED** that this is not already the default for app files; it is the documented default class for the data-protection entitlement per `[3P]` common knowledge — verify with `FileManager.attributesOfItem`).
- Memory: "Database queues and pools automatically free non-essential memory when the application receives a memory warning, and when the application enters background" (`Configuration.automaticMemoryManagement`, default on). `[GH]` README "Memory Management on iOS".

### 2.3 Migrations (`[GH]` DocC `Migrations.md`)
```swift
var migrator = DatabaseMigrator()
#if DEBUG
migrator.eraseDatabaseOnSchemaChange = true   // dev convenience; UNVERIFIED name here — it is in the DatabaseMigrator API reference, not in Migrations.md
#endif
migrator.registerMigration("v1") { db in
    try db.create(table: "label") { t in
        t.primaryKey("id", .text)
        t.column("name", .text).notNull()
        t.column("type", .text).notNull()
        t.column("color", .text)
        t.column("unreadCount", .integer).notNull().defaults(to: 0)
        t.column("sortOrder", .integer).notNull().defaults(to: 0)
    }
    try db.create(table: "message") { t in
        t.primaryKey("id", .text)
        t.column("threadId", .text).notNull().indexed()
        t.column("date", .datetime).notNull().indexed()
        t.column("isUnread", .boolean).notNull().defaults(to: false)
        t.column("labelIds", .jsonText).notNull()      // JSON column; .jsonText exists in GRDB 7 (UNVERIFIED here; fall back to .text)
        t.column("bodyHtml", .text)
        // ...
    }
}
try migrator.migrate(dbPool)
```
Verified facts: `DatabaseMigrator()`, `registerMigration(_:foreignKeyChecks:_:)` (`.immediate` when renaming FKs), `migrate(_:)`, `migrate(_:upTo:)`, `hasCompletedMigrations(_:)`, `hasBeenSuperseded(_:)`; "Each migration runs in a separate transaction"; "Migrations run with deferred foreign key checks"; applied-migration memory is stored "in the database itself (in a reserved table)". Schema builders shown in the doc: `t.autoIncrementedPrimaryKey("id")`, `t.column("name", .text).notNull()`, `t.belongsTo("author")`, `db.alter(table:) { t.add(column:_:) ; t.rename(column:to:) }`, `db.rename(table:to:)`, `db.drop(table:)`.

### 2.4 Record protocols (`[GH]` README "Record Protocols Overview", "Codable Records", "JSON Columns")
- `FetchableRecord` (decode rows; derives from `Decodable`), `TableRecord` (generates SQL; `static let databaseTableName`), `PersistableRecord` (insert/update/delete/upsert; derives from `Encodable`). Combine: `struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable`.
- Fetch/persist API: `Message.fetchAll(db)`, `Message.fetchOne(db, id:)`, `Message.fetchCount(db)`, `Message.filter(...)`, `Message.order(\.date.desc)` (closure/key-path syntax since 7.5), `message.insert(db)`, `.update(db)`, `.save(db)`, `.upsert(db)`, `Message.deleteOne(db, id:)`.
- **JSON columns**: "When a Codable record contains a property that is not a simple value (Bool, Int, String, Date, Swift enums, etc.), that value is encoded and decoded as a **JSON string**." So `var labelIds: [String]` and `var rawHeaders: [String: String]` become JSON `TEXT` columns with zero code. Uses Foundation `JSONEncoder`/`JSONDecoder`; customize via `static func databaseJSONEncoder(for column: String) -> JSONEncoder` / `databaseJSONDecoder(for:)`. **Tip from README: set `.sortedKeys`** so JSON output is stable (needed for record comparison and accurate `ValueObservation` change detection).
- Column names default to coding keys; use `enum CodingKeys: String, CodingKey, ColumnExpression` (README "Tip: Derive Columns from Coding Keys") to get typed columns for requests.

### 2.5 Reads/writes off the main thread (`[GH]` DocC `Concurrency.md`, `SwiftConcurrency.md`)
```swift
let unread = try await dbPool.read { db in try Message.filter(Column("isUnread") == true).fetchCount(db) }
try await dbPool.write { db in for m in messages { try m.save(db) } }   // one transaction; rolled back on throw
```
- Sync forms `dbPool.read {}` / `dbPool.write {}` block the calling thread → never call them from the main actor for anything non-trivial; use the `async` forms from the sync engine actor.
- `write` "wraps your database statements in a transaction that commits if and only if no error occurs".
- Swift 6: closures passed to `read`/`write`/`ValueObservation.tracking` are `@Sendable`; **record types must be `Sendable`** → use structs ("Since classes are difficult to make Sendable, the easiest way is to replace classes with structs"). The `Record` base class "is not Sendable, and its use is actively discouraged since GRDB 7". Optional: enable upcoming feature `InferSendableFromCaptures` to silence the `writer.read(Player.fetchCount)` warning.

### 2.6 ValueObservation → SwiftUI (`[GH]` DocC `ValueObservation.md`)
- Create: `ValueObservation.tracking { db in try Message.filter(...).order(...).fetchAll(db) }`; optimized constant-region form `ValueObservation.trackingConstantRegion { ... }` (with `DatabasePool`, fresh values are then "never fetched from the main thread").
- Consume: `start(in:scheduling:onError:onChange:)` (default scheduling: notifies **on the main actor, asynchronously**; `.immediate` delivers the first value synchronously on start — "only use the immediate scheduling for very fast database requests"), `values(in:)` async sequence (uses the `.task` scheduler, cooperative pool), `publisher(in:)` Combine. `shared(in:scheduling:extent:)` for multi-subscriber observations.
- Driving an `@Observable` store (no GRDBQuery dependency needed):
```swift
@MainActor @Observable
final class InboxModel {
    private(set) var rows: [MessageRow] = []
    private var cancellable: AnyDatabaseCancellable?
    init(db: DatabasePool, filter: InboxFilter) {
        cancellable = ValueObservation
            .trackingConstantRegion { db in try MessageRow.query(filter).fetchAll(db) }
            .start(in: db, scheduling: .immediate,            // first paint from cache, no flash
                   onError: { error in /* log */ },
                   onChange: { [weak self] rows in self?.rows = rows })
    }
}
```
  `AnyDatabaseCancellable` is the return type of `start` (**UNVERIFIED** exact name from this session's fetch; it is the documented cancellable type in GRDB 6/7 API — check `ValueObservation.start` signature in the tagged source). Alternative pure-async form inside `.task { for try await rows in observation.values(in: db) { self.rows = rows } }` — cancels with the view.
- Performance note (doc): each `start` is an independent observation; share when several views want the same value; the doc recommends companion library GRDBQuery for SwiftUI but it is optional.

### 2.7 FTS5 (`[GH]` `Documentation/FullTextSearch.md`)
- Create: `try db.create(virtualTable: "message_ft", using: FTS5()) { t in t.column("subject"); t.column("body") }` (→ `CREATE VIRTUAL TABLE … USING fts5(...)`); tokenizer e.g. `t.tokenizer = .unicode61()` (case/diacritic-insensitive), `.porter()` for English stemming.
- External-content table synchronized by triggers: `t.synchronize(withTable: "message")` — "every insert, update or delete that happens in the regular table is automatically applied to the full-text index".
- Query: `FTS5Pattern(matchingAllTokensIn: userText)` (or `matchingAnyTokenIn:`/`matchingPhrase:`), `Message.matching(pattern)`; relevance via `FTS5` `rank` (doc section "FTS5 Sorting by Relevance"). Search is out of scope for stage 1; the schema decision (external content FTS5 over `message`) can be a later migration with zero data migration cost.

### 2.8 WAL checklist
- `DatabasePool` sets WAL automatically; no `PRAGMA` needed. `DatabaseQueue` does **not**.
- Back up / export: never copy `db.sqlite` alone while WAL is active (`-wal`/`-shm` siblings) — keep the whole directory (DocC tip: "wrap the database file inside a dedicated directory").

---

## 3. Background refresh

### 3.1 Info.plist keys (`[A]`)
```xml
<key>UIBackgroundModes</key>
<array><string>fetch</string></array>                       <!-- BGAppRefreshTask "requires setting the fetch UIBackgroundModes capability" -->
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array><string>de.newtelco.minimail.refresh</string></array> <!-- array of strings; register(...) returns false for unlisted ids -->
```
Sources: https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask ; https://developer.apple.com/documentation/bundleresources/information-property-list/bgtaskschedulerpermittedidentifiers ; https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes (valid values include `fetch`, `processing`, `remote-notification`, …). In XcodeGen this is `info.properties` + the `com.apple.BackgroundModes` capability is just these plist keys (no entitlement).

### 3.2 Handler registration — SwiftUI scene modifier (iOS 16+) `[A]` https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:)
```swift
WindowGroup { RootView() }
    .backgroundTask(.appRefresh("de.newtelco.minimail.refresh")) {   // BackgroundTask.appRefresh(_:) -> BackgroundTask<Void, Void>
        await BackgroundRefresh.run()       // "The system considers the task completed when the action closure … returns."
    }
```
Doc: "If the action closure has not returned when the task runs out of time to complete, the system cancels the task" → check `Task.isCancelled` between steps; keep the closure short. This replaces `BGTaskScheduler.shared.register(forTaskWithIdentifier:using:launchHandler:)` (UIKit form: returns `Bool`; "Registration of all launch handlers must be complete before the end of `applicationDidFinishLaunching`"; "The system kills the app on the second registration of the same task identifier").

### 3.3 Scheduling (`[A]` BGTaskRequest/BGTaskScheduler pages)
```swift
func scheduleRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: "de.newtelco.minimail.refresh")   // init(identifier:)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // "the system doesn't guarantee launching the task at the specified date, but only that it won't begin sooner"; nil = no delay
    Task.detached {                                                    // iOS 27 doc: "Do not call this method from the main thread"
        if #available(iOS 27, *) {
            try? await BGTaskScheduler.shared.submitTaskRequest(request)   // async throws; replaces submit(_:)
        } else {
            try? BGTaskScheduler.shared.submit(request)                     // deprecated in iOS 27.0
        }
    }
}
```
- `submit(_:)` is **deprecated in iOS 27.0**; replacement `submitTaskRequest(_:completionHandler:)` / `submitTaskRequest(_:) async throws` (iOS 27+). Both: "Submitting a task request for an unexecuted task that's already in the queue replaces the previous task request. There can be a total of **1 refresh task** and 10 processing tasks scheduled at any time."
- Call `scheduleRefresh()` when `scenePhase == .background` and again at the start of the background handler (the request is consumed when it runs).
- Other API: `BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:)`, `cancelAllTaskRequests()`, `getPendingTaskRequests(completionHandler:)`. UIKit-style tasks need `task.expirationHandler` and `task.setTaskCompleted(success:)` ("Not calling … before the time for the task expires may result in the system killing your app") — not needed with the SwiftUI modifier.
- Debug trigger from LLDB while paused on device (from Apple's "Refreshing and Maintaining Your App Using Background Tasks" sample project; exact selector **UNVERIFIED** this session): `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"de.newtelco.minimail.refresh"]`.

### 3.4 Battery-neutral rules
- App refresh is opportunistic: the system decides when, based on usage patterns and conditions; `earliestBeginDate` only delays. Don't fight it (no timers, no location, no VoIP, no silent-push hacks).
- In the handler do exactly: `history.list` delta → write to DB → update badge (§6) → reschedule. Skip when no refresh token or when `SQLITE_AUTH`/`SQLITE_IOERR` (device locked & DB protected).
- Respect `Task.isCancelled`; expect a budget of a few tens of seconds (**UNVERIFIED** number; Apple only says the task is cancelled when time runs out).
- Do not open WKWebViews or render in the background.

### 3.5 `URLSession` background sessions — **not needed**
`URLSessionConfiguration.background(withIdentifier:)` "hands control of the transfers over to the system, which handles the transfers in a separate process … transfers continue even when the app itself is suspended or terminated" (`[A]` https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)). It is delegate-only (no `async` body APIs), needs `.backgroundTask(.urlSession(...))`, and pays a per-transfer system overhead. minimail's requests are small JSON (`history.list`, batched `messages.get`, `messages.send`); use the default `URLSession` inside the BG refresh task. For "user taps Send then swipes away" use `UIApplication.shared.beginBackgroundTask(expirationHandler:)` / `endBackgroundTask(_:)` around the send (`[A]` "Choosing Background Strategies": "If your app performs critical work that must continue while it runs in the background, use `beginBackgroundTask` … call `endBackgroundTask` before the time limit expires"). Revisit only if attachments > a few MB must download while backgrounded (not stage 1).

---

## 4. WKWebView in SwiftUI

### 4.1 Verified API (`[A]`)
- `WKWebView.loadHTMLString(_:baseURL:) -> WKNavigation?` — "sets the source of this load request for app activity data to `NSURLRequest.Attribution.developer`". With `baseURL: nil` the document has an opaque origin: relative URLs cannot resolve, and `cid:` images cannot be fetched → inline `cid:` parts as `data:` URIs during sanitization (or register a `WKURLSchemeHandler` for `cid` via `WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)` — **UNVERIFIED** here, iOS 11 API).
- `WKWebpagePreferences.allowsContentJavaScript: Bool` (iOS 14+): "If you change the value to `false`, the web view doesn't execute JavaScript code referenced by the web content. That includes JavaScript code found in inline `<script>` elements, `javascript:` URLs, and all other referenced JavaScript content." Set on `WKWebViewConfiguration.defaultWebpagePreferences` (iOS 13+; "When the web view navigates to a new page, it passes the default preferences to its navigation delegate"). The wording scopes this to *content* JavaScript; app-initiated `evaluateJavaScript`/`WKUserScript` are expected to still run (**UNVERIFIED** by an explicit doc sentence — test on device; fallback for sizing is KVO on `scrollView.contentSize`).
- `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContentRuleList:) async throws -> WKContentRuleList?` (iOS 11+), then `configuration.userContentController.add(_ contentRuleList:)` — "apply a set of content filtering rules to your web view's configuration". Rule JSON format is the Safari content-blocker format (`[A]` https://developer.apple.com/documentation/safariservices/creating-a-content-blocker): triggers `url-filter` (regex, required), `url-filter-is-case-sensitive`, `if-domain`/`unless-domain`, `resource-type` ∈ {`document`, `top-document`, `child-document`, `image`, `style-sheet`, `script`, `font`, `raw`, `svg-document`, `media`, `popup`, `ping`, `fetch`, `websocket`, `csp-report`, `other`}, `load-type` ∈ {`first-party`, `third-party`}, `if-top-url`/`unless-top-url`, `if-frame-url`/`unless-frame-url`, `load-context` ∈ {`top-frame`, `child-frame`}; actions `block`, `block-cookies`, `css-display-none` (+`selector`), `ignore-previous-rules`, `make-https`.
- `WKWebsiteDataStore.nonPersistent()` — "stores data only in memory, and doesn't write that data to disk"; assign to `configuration.websiteDataStore`.
- `WKUserScript(source:injectionTime:forMainFrameOnly:inContentWorld:)` (iOS 14+) for injecting the theme CSS/JS at `.atDocumentStart`.
- `WKWebView.evaluateJavaScript(_:in:in:completionHandler:)` (`@MainActor`; completion "always runs on the app's main thread"); the simpler `evaluateJavaScript(_:completionHandler:)` also exists.
- `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` (async variant: `webView(_:decidePolicyFor:) async -> WKNavigationActionPolicy`) — "The web view calls this method after the interaction occurs but before it attempts to load any content."
- `WKWebView.underPageBackgroundColor` (iOS 15+), `isInspectable` (iOS 16.4+; enable in DEBUG for Safari Web Inspector), `WKPreferences.isFraudulentWebsiteWarningEnabled` (iOS 13+).
- `SFSafariViewController` (`[A]` https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller): present modally; user gets Reader, content blockers, Done button; the app cannot observe browsing.

### 4.2 Content rule lists (exact JSON)
Block every network subresource; `data:` URIs are unaffected because the regex is anchored to network schemes:
```json
[
  { "trigger": { "url-filter": "^(https?|ftp|wss?)://" }, "action": { "type": "block" } }
]
```
"Load images" variant (still blocks scripts, fonts, CSS, iframes, fetch, media, pings):
```json
[
  { "trigger": { "url-filter": "^(https?|ftp|wss?)://",
                 "resource-type": ["document","child-document","style-sheet","script","font","raw","svg-document","media","popup","ping","fetch","websocket","csp-report","other"] },
    "action": { "type": "block" } },
  { "trigger": { "url-filter": "^http://", "resource-type": ["image"] }, "action": { "type": "make-https" } }
]
```
Compile both once at launch with identifiers `"block-all"` and `"block-all-but-images"` (`WKContentRuleListStore` caches compiled lists on disk under the identifier; `lookUpContentRuleList(forIdentifier:)` returns the cached one — **UNVERIFIED** method name this session, it is part of the same class). Toggling "Load images" = `userContentController.removeAllContentRuleLists()` + `add(_:)` + reload.

Belt-and-braces CSP in the generated document (WebKit enforces `<meta http-equiv>` CSP; **UNVERIFIED** from Apple docs — standard HTML behavior):
```html
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
<!-- with remote images allowed: img-src data: cid: https: -->
```

### 4.3 Representable wrapper with content sizing and link interception
```swift
import SwiftUI
import WebKit

struct MessageBodyView: UIViewRepresentable {
    let html: String            // sanitized, self-contained document
    let allowRemoteImages: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WebViewPool.shared.dequeue()          // §4.4
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false          // outer SwiftUI ScrollView/List scrolls
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html || context.coordinator.remoteImages != allowRemoteImages else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.remoteImages = allowRemoteImages
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        ucc.add(allowRemoteImages ? RuleLists.blockAllButImages : RuleLists.blockAll)
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        WebViewPool.shared.recycle(webView)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MessageBodyView
        var loadedHTML: String?
        var remoteImages = false
        init(_ parent: MessageBodyView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                LinkOpener.shared.open(url)                 // SFSafariViewController sheet, or mailto: → compose
                return .cancel
            }
            return action.navigationType == .other ? .allow : .cancel   // .other == our loadHTMLString
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                if let h = result as? CGFloat, h > 0 { self.parent.height = h }
            }
        }
    }
}
// usage inside the thread screen:
// MessageBodyView(html: msg.html, allowRemoteImages: showImages, height: $bodyHeight).frame(height: bodyHeight)
```
Configuration factory (shared by the pool):
```swift
let config = WKWebViewConfiguration()
config.defaultWebpagePreferences.allowsContentJavaScript = false
config.websiteDataStore = .nonPersistent()
config.preferences.isFraudulentWebsiteWarningEnabled = false     // no network anyway
config.suppressesIncrementalRendering = true                     // avoid flash before CSS applies (UNVERIFIED effect on loadHTMLString)
config.userContentController.addUserScript(WKUserScript(source: themeCSSInjector, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
```
HTML wrapper generated once at fetch time (cached in `message.bodyHtml`):
```html
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="color-scheme" content="light dark">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'">
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 12px; font: -apple-system-body; -webkit-text-size-adjust: 100%; overflow-wrap: anywhere; }
  img, table { max-width: 100% !important; height: auto; }
  pre { white-space: pre-wrap; }
  @media (prefers-color-scheme: dark) { body { background: transparent; color: #fff; } a { color: #6ea8fe; } }
</style></head><body>…sanitized message HTML…</body></html>
```
Sizing caveats: sizing inside a `List` row is fragile (row height caching); put the body in a `ScrollView { LazyVStack }` thread screen instead, and re-measure on `didFinish` and on width change (`GeometryReader` width → trigger `evaluateJavaScript` again). Do not read `scrollView.contentSize` synchronously in `didFinish` — it lags layout.

### 4.4 Pooling / reuse (no official guidance; practice)
Apple documents no pooling API. Practical rules (**UNVERIFIED** by docs, standard practice): creating a `WKWebView` costs a web-content process spin-up (~100+ ms) — keep one `@MainActor` singleton `WebViewPool` holding 1–2 instances created at app start with the shared configuration; `dequeue()` returns an idle instance, `recycle()` loads `about:blank` (`loadHTMLString("", baseURL: nil)`) and clears the delegate. A `UIView` can have only one superview, so never hand the same instance to two visible representables. For a thread with N messages, either render all messages into **one** HTML document in one web view (fastest, simplest sizing) or lazily create views only for expanded messages. `WKWebView` instances sharing one `WKWebViewConfiguration`/process pool share the content process (`WKProcessPool` is deprecated-ish in recent SDKs; sharing the configuration is enough — **UNVERIFIED**).

### 4.5 Dark mode for email HTML
- Opt-in mechanism: `<meta name="color-scheme" content="light dark">` and CSS `color-scheme: light dark` tell WebKit the document supports both schemes so UA defaults (canvas background, default text, form controls, selection) switch; author colors are styled with `@media (prefers-color-scheme: dark)`. Source: WebKit blog "Dark Mode Support in WebKit" https://webkit.org/blog/8840/ — **UNVERIFIED by direct fetch (egress-blocked); syntax confirmed via search snippets and MDN/W3C titles**.
- The web view follows the app's trait collection; when the owner picks Light/Dark in Settings, set `webView.overrideUserInterfaceStyle = .dark/.light` (UIView API) in `updateUIView`.
- Email HTML usually hard-codes `color:#000` / `bgcolor="#ffffff"`. Options, in order of fidelity vs. effort: (1) leave author colors, only make the canvas transparent → white cards on dark background (what Apple Mail does for many mails); (2) sanitizer pass: strip `bgcolor`, `background`, `background-color` from `body`/outer tables and drop `color` on `body` so the UA defaults win; (3) forced CSS `body, td, p, span, div { color: #fff !important; background: transparent !important }` behind a "Force dark" setting; (4) `filter: invert(1) hue-rotate(180deg)` on `html` + re-invert `img` — brittle, avoid. Recommend (1)+(2) for stage 1.
- Set `webView.isOpaque = false`, `backgroundColor = .clear`, and `underPageBackgroundColor = .clear` so the SwiftUI theme background shows through.

### 4.6 Links → `SFSafariViewController`
```swift
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
// .sheet(item: $linkToOpen) { SafariView(url: $0.url).ignoresSafeArea() }
```
`SFSafariViewController` only accepts `http`/`https` URLs (**UNVERIFIED** here; documented precondition in the class reference). Route `mailto:` to the compose screen and anything else to `openURL` (`@Environment(\.openURL)`).

### 4.7 iOS 26 alternative (if the floor ever moves): `WebView(page)` + `WebPage` (`[A]` https://developer.apple.com/documentation/webkit/webpage): `WebPage.Configuration` has `defaultNavigationPreferences.allowsContentJavaScript`, `loadsSubresources = false` (single switch that blocks all subresource loads — simpler than rule lists), `websiteDataStore = .nonPersistent()`, `userContentController`; `page.load(html:baseURL:)` returns an `AsyncSequence<NavigationEvent>`; `callJavaScript(_:arguments:in:contentWorld:)`.

---

## 5. SwiftUI (iOS 17) and system frameworks

### 5.1 `@Observable` (`[A]` https://developer.apple.com/documentation/observation/observable() — iOS 17.0)
```swift
@Observable final class ThemeStore { var theme: Theme = .system }
// injection (iOS 17): [A] environment(_:) "Use this modifier to place an object that you declare with the Observable() macro into a view's environment"
RootView().environment(themeStore)
struct Row: View { @Environment(ThemeStore.self) private var theme }
// two-way bindings to observable properties: [A] @Bindable (iOS 17)
@Bindable var prefs = prefs; TextField("Signature", text: $prefs.signatureHTML)
```
Views re-render only for properties actually read in `body` (Observation tracking), which is what keeps large lists cheap. Use `@State` to own an `@Observable` model in a view; `@Environment(Type.self)` to read it.

### 5.2 Navigation / lists (`[A]`)
- `NavigationStack { List { NavigationLink(value: thread) } .navigationDestination(for: Thread.self) { ThreadView($0) } }`; `NavigationStack(path: $path)` for programmatic navigation (iOS 16).
- `.swipeActions(edge: .leading, allowsFullSwipe: true) { Button { archive() } label: { Label("Archive", systemImage: "archivebox") }.tint(.green) }` and `.swipeActions(edge: .trailing) { Button { toggleUnread() } label: { Label(isUnread ? "Read" : "Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") } }` — Apple's own doc example is a mail list; "By default, the user can perform the first action for a given swipe direction with a full swipe"; `Button(role: .destructive)` renders red.
- `.refreshable { await sync.refresh() }` — enables pull-to-refresh on `List`; the closure is `@Sendable () async -> Void`.
- `.searchable(text: $query, placement: .automatic, prompt: "Search")` (iOS 16 signature) — out of scope for stage 1 but free to add later with FTS5.
- `ContentUnavailableView { Label("No Mail", systemImage: "tray.fill") } description: { Text("New mails you receive will appear here.") }` — this exact example is in Apple's doc; `ContentUnavailableView.search` for empty search results.

### 5.3 Compose editor: `UITextView` vs `TextEditor`
- `TextEditor(text:)` (iOS 14) is plain `String` editing on iOS 17; attributed editing only "when initialized with AttributedString" (newer OS; **UNVERIFIED** version). Styling via `.font`, `.foregroundColor`, `.lineSpacing`; keyboard toolbar via `.toolbar { ToolbarItemGroup(placement: .keyboard) { … } }`.
- `UITextView` (`@MainActor class`) gives `attributedText`, `inputAccessoryView`, selection/cursor control, `textContainerInset`, and reliable auto-growing via `sizeThatFits`.
- Recommendation: the compose body is plain text with the font/color applied at MIME-build time (PLAN), so **`TextEditor` is sufficient and ~40 lines cheaper**; keep the PLAN's `UITextView` only if you need the caret placed *above* the quoted text on open with custom insets or an accessory bar with attachments. Either way the quoted original is not edited inline in stage 1 — show it read-only below the editor (WKWebView) and append it at send time.

### 5.4 Attachments: QuickLook
- Simplest: `.quickLookPreview($previewURL)` (iOS 14, `[A]` https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:)): "The Quick Look preview appears when you set the binding to a non-nil item. … Upon dismissal by the user, Quick Look automatically sets the item binding to nil." Multi-item: `.quickLookPreview($selection, in: urls)`.
- Flow: tap → download `attachments.get` → write to `FileManager.default.temporaryDirectory/<messageId>/<filename>` (file must have the right extension for type detection) → set binding. Supported types: iWork, Office, RTF, PDF, images, text, CSV, USDZ (`[A]` QLPreviewController overview).
- Only wrap `QLPreviewController` (+ `QLPreviewControllerDataSource.numberOfPreviewItems(in:)` / `previewController(_:previewItemAt:)`) in a `UIViewControllerRepresentable` if you need custom titles or a navigation push.

### 5.5 Keychain (Security framework) — token store
`[A]` `SecItemAdd(_:_:)`, `SecItemCopyMatching(_:_:)`, `SecItemUpdate(_:_:)`, `SecItemDelete(_:)` (all iOS 2+; doc warning: they "block the calling thread … call from a background dispatch queue or `async` function"). `kSecClassGenericPassword` primary key = `kSecAttrService` + `kSecAttrAccount` (+ access group). `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: "After the first unlock, the data remains accessible until the next restart. This is recommended for items that need to be accessed by background applications. Items with this attribute do not migrate to a new device." — exactly right for BG refresh + no iCloud/backup migration of the refresh token.
```swift
import Security

enum Keychain {
    static let service = "de.newtelco.minimail"

    static func set(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let attrs: [CFString: Any] = [kSecValueData: data,
                                      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get(account: String) throws -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return item as? Data
    }

    static func delete(account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
```
No entitlement is needed for the app's own items (Xcode adds `application-identifier`; `keychain-access-groups` only for sharing). Store the archived `OIDAuthState` under account `"oauth.authState"`. Simulator note: Keychain works without extra setup.

### 5.6 Swift 6 strict concurrency — what it means for this codebase
Verified language facts:
- Xcode 26 ships Swift 6.2; Xcode 27 RC ships Swift 6.4 (`[A]` release notes).
- **SE-0466 "Control default actor isolation inference"** (Implemented, Swift 6.2): compiler flag `-default-isolation MainActor` (or `nonisolated`); SwiftPM `SwiftSetting.defaultIsolation(MainActor.self)` (PackageDescription 6.2). "rather than being non-isolated … the code would instead be implicitly isolated to `@MainActor`"; opt out per declaration with `nonisolated`. `[SE]` https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
- **SE-0461** (Implemented, Swift 6.2): upcoming feature `NonisolatedNonsendingByDefault` — `nonisolated async` functions run on the caller's actor; `@concurrent` requests the cooperative pool. `[SE]` https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
- Xcode build settings that map to these (`[3P]` Donny Wals / SwiftLee / useyourloaf — names **UNVERIFIED** against an Apple page, but consistent across sources and used by Xcode 26 new-project templates): `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, plus `SWIFT_VERSION = 6.0` (language mode 6) and `SWIFT_STRICT_CONCURRENCY = complete`.

Recommended settings (xcconfig, reproducible from files):
```
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
SWIFT_APPROACHABLE_CONCURRENCY = YES
IPHONEOS_DEPLOYMENT_TARGET = 17.0
```
Consequences and patterns:
- With MainActor-by-default, all views, `@Observable` stores, `UIViewRepresentable` (already `@MainActor`), `WKNavigationDelegate` (`@MainActor` protocol) and `QLPreviewControllerDataSource` (`@MainActor`) "just work".
- Put the network + sync + DB-write pipeline in explicit actors: `actor SyncEngine`, `actor GmailClient`, `actor TokenStore`. Mark CPU-heavy pure functions (MIME parse, HTML sanitize, base64url) `nonisolated` and call them with `@concurrent` where they must leave the main actor.
- GRDB: records must be `Sendable` structs (§2.5); `ValueObservation` default scheduling delivers on the main actor, which matches `@Observable` stores.
- AppAuth (ObjC): `OIDAuthState` is a non-Sendable class; keep it owned by the `@MainActor AuthStore` and bridge with `withCheckedThrowingContinuation` + `Task { @MainActor in }` inside callbacks. Expect a handful of `@preconcurrency import AppAuth` / `nonisolated(unsafe)` annotations.
- `WKWebView` calls are main-actor only; never touch it from the sync actor.
- Unit tests: XCTest (or Swift Testing) run on the main actor by default under these settings; DB tests use `DatabaseQueue()` in-memory.

---

## 6. Unread badge without notifications UI

- API: `UNUserNotificationCenter.current().setBadgeCount(_:)` (`async throws`, iOS 16+; `[A]` https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/setbadgecount(_:withcompletionhandler:)). `UIApplication.applicationIconBadgeNumber` is **deprecated in iOS 17.0** (`[A]`).
- **Authorization is required for badging.** Apple: "Local and remote notifications get a person's attention by displaying an alert, playing sounds, or badging your app's icon. … you must obtain permission to use them." and `requestAuthorization`: "If your app's local or remote notifications involve user interactions, you must request authorization … Interactions include displaying an alert, playing a sound, or badging the app's icon." `[A]` https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications , https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)
- Request only the badge: `try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])` — the system prompt still appears once ("The first time your app calls the method, the system prompts the person"). `UNAuthorizationOptions` members: `badge`, `sound`, `alert`, `carPlay`, `criticalAlert`, `providesAppNotificationSettings`, `provisional`. Whether `[.badge, .provisional]` grants badge without a prompt is **UNVERIFIED** (Apple describes provisional as quiet delivery to Notification Center; badge behavior is not stated) — test it; if it works it is the least intrusive path.
- Plan: make the badge an opt-in Settings toggle ("Show unread count on icon") that triggers the prompt in context (Apple's guidance), then call `setBadgeCount(unreadInboxCount)` after every sync (foreground and BG refresh) and `setBadgeCount(0)` on sign-out. No `UNNotificationRequest` is ever scheduled; no APNs.

---

## 7. Consolidated Info.plist for minimail (XcodeGen `info.properties`)

```yaml
CFBundleURLTypes:
  - CFBundleTypeRole: Editor
    CFBundleURLSchemes: [com.googleusercontent.apps.<client-id-prefix>]
UIBackgroundModes: [fetch]
BGTaskSchedulerPermittedIdentifiers: [de.newtelco.minimail.refresh]
UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false }
UILaunchScreen: {}
ITSAppUsesNonExemptEncryption: false        # UNVERIFIED as required; common for TestFlight (HTTPS-only apps)
```
Also ship `PrivacyInfo.xcprivacy` (required-reason APIs: `UserDefaults` → `CA92.1`, file timestamps if used) — required for App Store/TestFlight uploads since 2024 (**UNVERIFIED** exact reason codes here; AppAuth and GRDB ship their own manifests — AppAuth verified in `Package.swift` resources).

---

## 8. Open items / things to test on a real device early
1. `allowsContentJavaScript = false` + `evaluateJavaScript` height measurement (fallback: KVO `scrollView.contentSize`).
2. Content rule list correctness with `data:` images and `cid:` inlining; verify no network egress with Charles/Proxyman.
3. BG refresh while locked: DB data-protection errors (`SQLITE_AUTH`/`SQLITE_IOERR`).
4. `[.badge, .provisional]` behaviour.
5. AppAuth 3.0.0 under Swift 6 language mode + MainActor default isolation (expected: a few `@preconcurrency` imports).
6. Xcode 27 final vs 26.6 — both satisfy the iOS 26 SDK rule; pick whichever the macOS runner has.

---

## Sources (fetched 2026-09-11)
Apple (`developer.apple.com/documentation/...` via the DocC JSON endpoints):
- backgroundtasks/bgapprefreshtask · backgroundtasks/bgapprefreshtaskrequest/init(identifier:) · backgroundtasks/bgtaskrequest/earliestbegindate · backgroundtasks/bgtaskscheduler · backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:) · backgroundtasks/bgtaskscheduler/submit(_:) · backgroundtasks/bgtaskscheduler/submittaskrequest(_:completionhandler:) · backgroundtasks/bgtask/settaskcompleted(success:) · backgroundtasks/bgtask/expirationhandler · backgroundtasks/choosing-background-strategies-for-your-app
- bundleresources/information-property-list/{bgtaskschedulerpermittedidentifiers, uibackgroundmodes, cfbundleurltypes}
- swiftui/scene/backgroundtask(_:action:) · swiftui/backgroundtask · swiftui/backgroundtask/apprefresh(_:) · swiftui/contentunavailableview · swiftui/navigationstack · swiftui/view/{onopenurl(perform:), swipeactions(edge:allowsfullswipe:content:), refreshable(action:), searchable(text:placement:prompt:), environment(_:), quicklookpreview(_:), quicklookpreview(_:in:)} · swiftui/bindable · swiftui/environment · swiftui/uiviewrepresentable · swiftui/texteditor · observation/observable()
- webkit/wkwebpagepreferences/allowscontentjavascript · webkit/wkwebviewconfiguration/{defaultwebpagepreferences, websitedatastore} · webkit/wkwebsitedatastore/nonpersistent() · webkit/wkcontentruleliststore/compilecontentrulelist(foridentifier:encodedcontentrulelist:completionhandler:) · webkit/wkusercontentcontroller/add(_:) · webkit/wkuserscript/init(source:injectiontime:formainframeonly:incontentworld:) · webkit/wkwebview/{loadhtmlstring(_:baseurl:), evaluatejavascript(_:in:in:completionhandler:), isinspectable, underpagebackgroundcolor} · webkit/wkpreferences/isfraudulentwebsitewarningenabled · webkit/wknavigationdelegate · webkit/wknavigationdelegate/webview(_:decidepolicyfor:decisionhandler:) · webkit/webkit-for-swiftui · webkit/webview-swift.struct · webkit/webpage · webkit/webpage/configuration · webkit/webpage/load(html:baseurl:)
- safariservices/creating-a-content-blocker · safariservices/sfsafariviewcontroller
- authenticationservices/aswebauthenticationsession · …/prefersephemeralwebbrowsersession · …/init(url:callback:completionhandler:) · …/callback · …/callback/customscheme(_:) · …/start() · authenticationservices/aswebauthenticationpresentationcontextproviding
- usernotifications/unusernotificationcenter/setbadgecount(_:withcompletionhandler:) · …/requestauthorization(options:completionhandler:) · usernotifications/unauthorizationoptions · usernotifications/asking-permission-to-use-notifications · uikit/uiapplication/applicationiconbadgenumber
- security/{ksecclassgenericpassword, ksecattraccessible, ksecattraccessibleafterfirstunlockthisdeviceonly, secitemadd(_:_:), secitemcopymatching(_:_:), secitemupdate(_:_:), secitemdelete(_:)}
- quicklook/qlpreviewcontroller · quicklook/qlpreviewcontrollerdatasource · uikit/uitextview · foundation/urlsessionconfiguration/background(withidentifier:)
- xcode-release-notes/xcode-26-release-notes · xcode-release-notes/xcode-27-release-notes · https://developer.apple.com/support/xcode/ · https://developer.apple.com/news/upcoming-requirements/
GitHub:
- https://github.com/openid/AppAuth-iOS (README, CHANGELOG.md, Package.swift, Sources/AppAuthCore/{OIDAuthState,OIDAuthorizationRequest,OIDServiceConfiguration,OIDAuthorizationService,OIDExternalUserAgentSession}.h, Sources/AppAuth/iOS/{OIDExternalUserAgentIOS,OIDAuthState+IOS}.h, Examples/Example-iOS_Swift-SPM/Example/{ExampleApp,AppDelegate,AuthManager}.swift + Info.plist); tag dates via `git clone --branch`.
- https://github.com/groue/GRDB.swift (README.md, CHANGELOG.md, Package.swift, GRDB/Documentation.docc/{Concurrency,Migrations,DatabaseConnections,JSON,SwiftConcurrency,Extension/ValueObservation,Extension/DatabaseQueue,Extension/DatabasePool}.md, Documentation/FullTextSearch.md)
- https://github.com/yonaskolb/XcodeGen (tags)
- https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md · …/0461-async-function-isolation.md
Third-party (context only): MacRumors iOS 27 release date; Donny Wals / SwiftLee / useyourloaf on Xcode 26 concurrency build settings; WebKit blog 8840 (title/snippets only — site egress-blocked).
