# Module 04 — `auth`: AppAuth token actor, AuthStore, Keychain, sign-in screen

Source of truth: `docs/plan/design/architecture.md` §0 (decisions 2, 10, 11, 14), §1.2–§1.4, §2.1, §2.4 (Auth section), §4.2 (account-mismatch line), §4.10 (signed-in guard), §5 (whole section), §6.1 (401 handling contract), §8.1–§8.2 (SignInScreen row), §11 (`lastSignedInEmail`), §12.2 (launch order), §13.3 (`KeychainTests`), §14 (#2, #10, #12, #15, #16), §15 (D22), Appendix A; `docs/plan/design/modules.md` ("04-auth" paragraph); research `docs/plan/research/ios-platform.md` (cited `[ios-platform §n]`), `docs/plan/research/gmail-api.md` (cited `[gmail-api §n]` / `[gmail-api gotcha n]`), `docs/plan/research/tooling.md` (cited `[tooling §n]`). Depends on module `01-project-setup` (spec `docs/plan/spec/01-project-setup.md`, cited `[01 §n]`). Every fact the research marks UNVERIFIED stays UNVERIFIED here (§10).

Conventions: "main" = the main actor (the app target's default isolation, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` `[tooling §3.3]`); "the item" = the Keychain generic-password item `service = "com.minimail"`, `account = "oauth.authState"`; "the provider" = `AppAuthTokenProvider`; "the store" = `AuthStore`. Line references `architecture.md §5.3` refer to the design document as committed.

---

## 1. Purpose & scope

### 1.1 What this module delivers

| Area | Files | What it delivers |
|---|---|---|
| OAuth configuration | `minimail/Auth/OAuthConfig.swift` | client id from `Info.plist` key `GoogleClientID`, reversed-client-id redirect URL with a single-slash path, hard-coded Google endpoints (no discovery round trip), the single scope `gmail.modify` |
| Token provider | `minimail/Auth/TokenProvider.swift`, `minimail/Auth/AppAuthTokenProvider.swift` | the `TokenProvider` protocol consumed by `GmailClient` (05); the actor that owns the `OIDAuthState`, unarchives it from the Keychain after the first frame, refreshes access tokens with a single in-flight refresh, maps `invalid_grant` to `AuthError.needsReauth` and signals the store, re-archives on every AppAuth state change, revokes and clears on sign-out |
| Auth state machine | `minimail/Auth/AuthStore.swift` | `@Observable` state (`signedOut` / `signedIn` / `needsReauth`), the synchronous launch-routing truth table of architecture §5.2, the interactive AppAuth sign-in flow (`login_hint`, `hd`, one `prompt=consent` retry, one retry without optional parameters), the `.onOpenURL` fallback, account-mismatch wipe hook, sign-out orchestration of architecture §5.4 |
| Keychain | `minimail/Auth/Keychain.swift` | four static functions over `kSecClassGenericPassword` (`exists` / `set` / `get` / `delete`) with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Sign-in screen | `minimail/Features/SignIn/SignInScreen.swift` | the only screen shown while `auth.state == .signedOut`; one button, error text, the Workspace-admin remedy for `admin_policy_enforced`, the "client id not configured" hint |
| App wiring | `minimail/App/AppEnvironment.swift`, `minimail/App/RootView.swift`, `minimail/App/MinimailApp.swift` (all `modify`) | launch step 3 of architecture §12.2 (Keychain existence check + `AuthStore.init`), deferred `tokens.load()`, the `RootView` switch on `AuthStore.State`, `.onOpenURL` → `auth.resume(url:)` |
| Tests | `minimailTests/Auth/{KeychainTests,OAuthConfigTests,AppAuthTokenProviderTests,AuthStoreTests}.swift`, additions to `minimailTests/App/AppEnvironmentTests.swift` | simulator round trips, config parsing, single-flight refresh and error mapping against a stubbed token endpoint, routing table, sign-out ordering |

### 1.2 Explicitly out of scope (owned elsewhere)

- `GmailClient`, `URLSession.minimail`, `GmailError` and the HTTP 401 → `invalidateAccessToken()` → retry-once → `unauthorized` logic (module 05). `getProfile` after sign-in is reached only through the injected closure `AuthStore.hooks.fetchProfileEmail` (modules.md: "invoked through an injected closure").
- `Database.destroy`, closing/reopening the pool, `SyncStateRepository.get(.accountEmail)` (module 06). This module reads `cachedEmail` through an `AppEnvironment` local that 06 fills; it wipes through `AuthStore.hooks.wipeAccountData`.
- Cancelling a running sync/drain, `sync.run(.launch)` after sign-in, the "sync and drain pause while `needsReauth`" rule, the `BackgroundRefresh.run` signed-in guard (module 07; wired through `hooks.prepareSignOut` / `hooks.didSignIn`, and by 07 reading `auth.state`).
- `WebViewHost.recycle()` and the purge of `Caches/attachments`, `Caches/cid`, `tmp/attachments` (module 08 inside `hooks.wipeAccountData`).
- The reauth banner on the list ("Sign in again", module 09 `StatusBanner`), the Settings "Sign out" row (module 13), `InboxScreen` (09). This module ships a throw-away `SignedInPlaceholderView` inside `RootView.swift` that 09 deletes.
- The badge toggle and `[.badge]` authorization request (13). This module only calls `setBadgeCount(0)` on sign-out.
- `minimailTests/Support/StubURLProtocol.swift` (module 14). This module's token-endpoint stub is private to `AppAuthTokenProviderTests.swift`.

### 1.3 Consumers and what they take from this module

| Module | Symbols consumed |
|---|---|
| 05-gmail-client | `TokenProvider` (`accessToken()`, `invalidateAccessToken()`), `AuthError` (only to recognise `.needsReauth` / `.signedOut` thrown by `accessToken()`), `AuthStore.markNeedsReauth()` (after the second 401), `AuthStore.hooks.fetchProfileEmail` (05 assigns `{ try await gmail.getProfile().emailAddress }` in `AppEnvironment.init`) |
| 06-storage | `AppEnvironment` insertion point `cachedEmail` (replaces `nil` with the `syncState.accountEmail` read), `AuthStore.hooks.wipeAccountData` (destroy + reopen) |
| 07-sync-outbox | `AuthStore.state` (pause rule, BG guard), `AuthStore.handleAccountMismatch(expected:got:)` (from `fullSync`), `AuthError.accountMismatch`, `AuthStore.hooks.prepareSignOut` / `hooks.didSignIn`, `AppEnvironment.tokens` / `.auth` |
| 08-html-rendering | `AuthStore.hooks.wipeAccountData` (adds `webHost.recycle()` + cache purge) |
| 09-inbox-list | `AuthStore.state` (`.needsReauth` banner), `AuthStore.signIn()` (banner action), `AuthStore.lastError`, replaces `SignedInPlaceholderView` in `RootView` |
| 13-settings-theme-signature | `AuthStore.signOut()`, `AuthStore.state.email` |
| 14-qa | `SignInScreen` (smoke host), the testing Keychain account `"oauth.authState.testing"` |

### 1.4 Non-negotiable rules for this module

1. `AppEnvironment.init` performs exactly one Keychain call (`Keychain.exists`, attributes only, no data decrypt) and no AppAuth call, no network, no `NSKeyedUnarchiver` (architecture §12.2 step 1). The `OIDAuthState` unarchive happens in `tokens.load()` after the first frame.
2. Tokens never leave the provider: `accessToken()` returns the bearer string to the caller; nothing logs it, stores it in `UserDefaults`, or shows it on screen. Log lines under `Log.auth` carry no token, no header, no body (architecture §6.5).
3. `invalid_grant` is terminal for the current `OIDAuthState`: the provider latches `needsReauth`, signals the store once, and never loops on the token endpoint `[gmail-api gotcha 18]`.
4. Transport failures during refresh are retryable and never sign the user out: they surface as `URLError` and module 05 maps them with `GmailError.map(_ urlError:)`.
5. Exactly one scope, `https://www.googleapis.com/auth/gmail.modify` `[gmail-api gotcha 1]`.
6. Every file that imports AppAuth does so as `@preconcurrency import AppAuth` (architecture §14 #2).
7. Views use theme tokens only (`@ThemeTokensReader`), system fonts only, SF Symbols only (`[01 §6.2]`).

---

## 2. Files

All paths relative to the repo root. `new` = created by this module; `modify` = a file owned by module 01 that this module edits at the insertion points 01 marked.

| Path | Kind | Purpose |
|---|---|---|
| `minimail/Auth/OAuthConfig.swift` | new | `struct OAuthConfig` — client id, redirect URL, endpoints, scope, `fromInfoPlist()`, `isPlaceholder`, `serviceConfiguration` |
| `minimail/Auth/TokenProvider.swift` | new | `protocol TokenProvider` |
| `minimail/Auth/AppAuthTokenProvider.swift` | new | `actor AppAuthTokenProvider` + private `StateDelegate` + `mapTokenError` |
| `minimail/Auth/AuthStore.swift` | new | `AuthError`, `AuthStore` (+ `State`, `Hooks`), `NeedsReauthRelay`, flow-error classification |
| `minimail/Auth/Keychain.swift` | new | `enum Keychain` — `exists` / `set` / `get` / `delete` |
| `minimail/Features/SignIn/SignInScreen.swift` | new | `SignInScreen` view + `SignInMessage` (pure message selection) |
| `minimail/App/AppEnvironment.swift` | modify | adds `oauthConfig`, `tokens`, `auth`; fills launch step 3 and deferred step a; wires the 01-owned hooks |
| `minimail/App/RootView.swift` | modify | replaces `RootPlaceholderView()` with the `switch env.auth.state`; adds `SignedInPlaceholderView` (deleted by 09) |
| `minimail/App/MinimailApp.swift` | modify | adds `.onOpenURL { _ = env.auth.resume(url: $0) }` |
| `minimailTests/Auth/KeychainTests.swift` | new | simulator round trip, `exists`, overwrite, delete-missing |
| `minimailTests/Auth/OAuthConfigTests.swift` | new | client id → redirect URL, endpoints, scope, placeholder detection, `Info.plist` read |
| `minimailTests/Auth/AppAuthTokenProviderTests.swift` | new | load/adopt/persist round trip, fresh-token fast path, single-flight refresh, `invalid_grant` latch + callback, transport error → `URLError`, revoke request bytes, delegate re-archive; private `TokenEndpointStub: URLProtocol` |
| `minimailTests/Auth/AuthStoreTests.swift` | new | routing truth table, `markNeedsReauth`, `handleTokenLoad`, `resume(url:)`, `signOut` ordering, `handleAccountMismatch`, placeholder-config `signIn` failure, flow-error classification, retry predicates, `SignInMessage` selection |
| `minimailTests/App/AppEnvironmentTests.swift` | modify | adds `testAuthRoutingInTestingMode`, `testTestingModeWithKeychainItemRoutesSignedIn`, `testDeferredWorkLoadsTokens`, `testHooksWiredToSettings`, `testRootViewHostsSignedOut`, `testRootViewHostsSignedInPlaceholder` |

Files this module does NOT touch: `project.yml` (the `GoogleClientID` key and `CFBundleURLTypes` already exist `[01 §5.1]`), `Config/Google.xcconfig`, `Features/Settings/*`, `Theme/*`, `Support/*`, anything under `Packages/`.

---

## 3. Public interface

Signatures marked "verbatim" are copied from architecture §2.4 / §5.3. Everything else is additive and marked as such; deviations carry a `DEVIATION:` note.

### 3.1 `minimail/Auth/OAuthConfig.swift`

```swift
@preconcurrency import AppAuth
import Foundation

/// OAuth client facts (architecture §2.4, §5.1 step 1). Value type; safe to hand to actors.
struct OAuthConfig: Sendable {
    let clientID: String                                        // "<prefix>.apps.googleusercontent.com" from Info.plist GoogleClientID
    let redirectURL: URL                                        // com.googleusercontent.apps.<prefix>:/oauth2redirect
    let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    let scopes = ["https://www.googleapis.com/auth/gmail.modify"]
    static func fromInfoPlist() -> OAuthConfig                  // verbatim

    // ---- additive ----
    /// Sent as the optional `hd` authorization parameter (architecture §5.1; UNVERIFIED for the native flow, §10 A3).
    let hostedDomain: String? = "example.com"
    /// Info.plist key read by `fromInfoPlist()` (`[01 §5.1]`: `GoogleClientID: $(GOOGLE_CLIENT_ID)`).
    static let infoPlistKey = "GoogleClientID"
    /// Keychain account of the archived `OIDAuthState` (architecture §5.2). Tests and `AppEnvironment(testing: true)` use `testingKeychainAccount`.
    static let keychainAccount = "oauth.authState"
    static let testingKeychainAccount = "oauth.authState.testing"
    /// Builds the redirect URL from the client id: `com.googleusercontent.apps.<prefix>:/oauth2redirect` where `<prefix>` is
    /// `clientID` with the suffix `.apps.googleusercontent.com` removed (single slash `[gmail-api gotcha 19]`).
    /// Precondition: none — a client id without the suffix yields `com.googleusercontent.apps.<clientID>:/oauth2redirect`.
    init(clientID: String)
    /// `fromInfoPlist()` with an explicit bundle (tests). Missing or non-string key → `init(clientID: "REPLACE.apps.googleusercontent.com")` + `Log.auth.error`.
    static func fromInfoPlist(bundle: Bundle) -> OAuthConfig
    /// `true` when the client id still carries the `Config/Google.xcconfig` placeholder (`hasPrefix("REPLACE")`) or is empty. `SignInScreen` disables the button.
    var isPlaceholder: Bool { get }
    /// `OIDServiceConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint)` — built per call (the ObjC object is not Sendable).
    var serviceConfiguration: OIDServiceConfiguration { get }
}
```

### 3.2 `minimail/Auth/TokenProvider.swift`

```swift
import Foundation

/// Verbatim architecture §2.4. Implemented by `AppAuthTokenProvider`; consumed by `GmailClient` (05).
protocol TokenProvider: Sendable {
    /// A bearer access token that is valid now. Refreshes through the refresh token when expired (single-flight: N concurrent
    /// callers share one refresh). Throws `AuthError.signedOut` (no state loaded), `AuthError.needsReauth` (`invalid_grant`,
    /// latched until the next `adopt`), `URLError` (transport failure — retryable, caller maps it), `AuthError.flowFailed(String)` (anything else).
    func accessToken() async throws -> String
    /// After an HTTP 401: forces the next `accessToken()` to refresh (`OIDAuthState.setNeedsTokenRefresh()`). Never throws, never networks.
    func invalidateAccessToken() async
}
```

### 3.3 `minimail/Auth/AppAuthTokenProvider.swift`

```swift
@preconcurrency import AppAuth
import Foundation

/// Owns the `OIDAuthState` (architecture §2.4, §5.3). One instance per process, created in `AppEnvironment.init` (construction only — no I/O).
actor AppAuthTokenProvider: TokenProvider {
    /// DEVIATION (additive parameters): architecture declares `init(keychainAccount: String = "oauth.authState")` and a
    /// `nonisolated let onNeedsReauth`. A `let` must be initialised in `init`, so the closure is an init parameter; the revocation
    /// endpoint and the URLSession are parameters so tests can stub the `/revoke` POST. All three have defaults, so the verbatim call
    /// `AppAuthTokenProvider()` still compiles.
    init(keychainAccount: String = OAuthConfig.keychainAccount,
         revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
         session: URLSession = URLSession(configuration: .ephemeral),
         onNeedsReauth: @escaping @Sendable () -> Void = {})

    /// Unarchives the `OIDAuthState` from the Keychain (runs on the actor, i.e. off main). `true` iff an item existed, unarchived,
    /// and `state.isAuthorized`. Never throws; a corrupt archive is deleted and logged (§4.3).
    func load() async -> Bool                                        // verbatim
    /// Installs `state` after an interactive sign-in: sets delegates, clears the reauth latch, archives to the Keychain.
    /// Throws `AuthError.keychain(status)` when the Keychain write fails (the state is then NOT kept).
    func adopt(_ state: sending OIDAuthState) async throws           // verbatim
    func accessToken() async throws -> String                        // verbatim; §4.4
    func invalidateAccessToken() async                               // verbatim; §4.5
    /// `POST revocationEndpoint` with `token=<refresh token>` (best effort, 3 s timeout, result only logged) → drop state → `Keychain.delete`.
    func revokeAndClear() async                                      // verbatim; §4.6
    var refreshToken: String? { get async }                          // verbatim: `state?.refreshToken`
    nonisolated let onNeedsReauth: @Sendable () -> Void              // verbatim: invalid_grant → AuthStore.markNeedsReauth on main

    // ---- additive ----
    let keychainAccount: String
    /// `state != nil` (tests, `AppEnvironmentTests`).
    var isLoaded: Bool { get }
    /// `true` after an `invalid_grant` until the next `adopt` (§4.4 step 2).
    var needsReauthLatched: Bool { get }
    /// Re-archives the current state to the Keychain; called by the AppAuth change delegate (§4.7). Failures are logged, never thrown.
    func persistCurrentState()
    /// Pure mapping of the error handed to `performAction(freshTokens:)`'s callback (§4.4 step 6). Exposed for tests.
    nonisolated static func mapTokenError(_ error: (any Error)?) -> any Error
}
```

Private helper in the same file:

```swift
/// AppAuth calls its delegates on arbitrary threads; this object hops to the actor. `nonisolated` so the ObjC callbacks carry no MainActor assumption.
nonisolated private final class StateDelegate: NSObject, OIDAuthStateChangeDelegate, OIDAuthStateErrorDelegate, Sendable {
    private weak var owner: AppAuthTokenProvider?      // actors are Sendable; weak to avoid a cycle (OIDAuthState delegates are weak too)
    init(owner: AppAuthTokenProvider)
    func didChange(_ state: OIDAuthState)                                                   // Task { await owner?.persistCurrentState() }
    func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: any Error)  // Log.auth.error only (the `accessToken()` path does the mapping)
}
```

### 3.4 `minimail/Auth/AuthStore.swift`

```swift
@preconcurrency import AppAuth
import Foundation
import Observation
import UIKit
import UserNotifications

/// Verbatim architecture §2.4. `nonisolated` so actors (provider, 05, 07) can throw and compare it.
nonisolated enum AuthError: Error, Sendable, Equatable {
    case signedOut, needsReauth, userCancelled, flowFailed(String), missingRefreshToken,
         accountMismatch(expected: String, got: String), keychain(Int32)
}
extension AuthError: LocalizedError {
    /// User-facing text (§5.6 strings table). `flowFailed(text)` → "Sign-in failed: <text>".
    var errorDescription: String? { get }
    /// `flowFailed(text)` whose `text` contains `admin_policy_enforced` (architecture §5.1 step 5, `[gmail-api gotcha 2]`).
    var isAdminPolicyEnforced: Bool { get }
}

/// Auth state machine + interactive sign-in. `@MainActor` (implicit). One instance, owned by `AppEnvironment`.
@Observable final class AuthStore {
    enum State: Equatable { case signedOut, signedIn(email: String?), needsReauth(email: String?) }   // verbatim
    private(set) var state: State                                                                    // verbatim
    private(set) var lastError: String?                                                              // verbatim: errorDescription of the last failure, nil after success
    var currentFlow: OIDExternalUserAgentSession?                                                    // verbatim: retained while the browser sheet is up
    /// Synchronous routing decision (architecture §5.2 truth table, §4.9 here). No I/O.
    init(tokens: AppAuthTokenProvider, config: OAuthConfig, hasKeychainItem: Bool, cachedEmail: String?)   // verbatim
    /// AppAuth flow → adopt → profile → mismatch wipe → `.signedIn` (§4.10). Throws `AuthError`; `lastError` is set before rethrowing.
    /// Re-entrancy: returns immediately (no throw) while `isSigningIn`.
    func signIn() async throws                                                                       // verbatim
    /// Architecture §5.4 (§4.11). Idempotent: no-op when already `.signedOut`.
    func signOut() async                                                                             // verbatim
    /// `.onOpenURL` fallback: hands `url` to `currentFlow` when its scheme matches `config.redirectURL.scheme` (§4.12).
    func resume(url: URL) -> Bool                                                                    // verbatim
    /// `.signedIn(e)` → `.needsReauth(e)`; other states unchanged (§4.13). Called by the provider (via `NeedsReauthRelay`) and by `GmailClient` after 401×2.
    func markNeedsReauth()                                                                           // verbatim

    // ---- additive ----
    let config: OAuthConfig
    let tokens: AppAuthTokenProvider
    /// `true` from `signIn()` entry to exit. `SignInScreen` shows a spinner and disables the button.
    private(set) var isSigningIn: Bool
    /// Typed twin of `lastError` (tests, `SignInScreen.message`).
    private(set) var lastAuthError: AuthError?
    /// The e-mail the local cache belongs to (`syncState.accountEmail` at launch; the profile e-mail after sign-in; nil after a wipe).
    private(set) var cachedEmail: String?
    /// Cross-module callbacks (§3.4.1). `AppEnvironment.init` assigns them; defaults are no-ops so this module runs standalone.
    var hooks: Hooks
    /// Deferred launch step a (architecture §12.2 step 3): `succeeded == false` while `state` is `.signedIn(e)` → `.needsReauth(e)`; otherwise no-op (§4.14).
    func handleTokenLoad(succeeded: Bool)
    /// Called by `SyncEngine.fullSync` (07) when `getProfile().emailAddress != syncState.accountEmail` (architecture §4.2):
    /// sets `lastError` to `AuthError.accountMismatch(expected:got:).errorDescription`, then `await signOut()` (which wipes) (§4.15).
    func handleAccountMismatch(expected: String, got: String) async
    /// Pure: AppAuth flow callback error → `AuthError` (§4.10 step 4). Exposed for tests.
    nonisolated static func classifyFlowError(_ error: (any Error)?) -> AuthError
    /// Pure: whether a first-attempt failure warrants one retry without the optional `hd` parameter (§4.10 step 5).
    nonisolated static func shouldRetryWithoutOptionalParameters(_ error: AuthError) -> Bool
}

extension AuthStore.State {
    /// `nil` for `.signedOut`, the associated value otherwise.
    var email: String? { get }
    var isSignedOut: Bool { get }
}
```

#### 3.4.1 `AuthStore.Hooks`

```swift
extension AuthStore {
    /// Injection points for modules 01, 05, 06, 07, 08 (modules.md: "getProfile after sign-in is invoked through an injected closure;
    /// DB wipe implementation (06, called via AppEnvironment)"). All closures run on main; async ones are awaited.
    struct Hooks {
        /// `login_hint` for the authorization request. 01 wires `{ settings.settings.lastSignedInEmail }`. Default `{ nil }`.
        var loginHint: @MainActor () -> String? = { nil }
        /// Called with the authenticated address before `state` flips to `.signedIn`. 01 wires `settings.update { $0.lastSignedInEmail = email }`. Default no-op.
        var rememberEmail: @MainActor (String) -> Void = { _ in }
        /// Returns the account e-mail using the freshly adopted tokens (`GmailProfile.emailAddress`). 05 wires
        /// `{ [gmail] in try await gmail.getProfile().emailAddress }`. `nil` (default) skips the profile step (§4.10 step 8).
        var fetchProfileEmail: (@Sendable () async throws -> String)? = nil
        /// Stops everything that may write to the DB: cancel the running sync and outbox drain and await them (07). Default no-op.
        var prepareSignOut: @MainActor () async -> Void = {}
        /// Erases every per-account artefact except tokens and Settings, and leaves the app usable for a fresh sync: close the pool,
        /// `Database.destroy(directory)`, reopen an empty DB (06); purge `Caches/attachments`, `Caches/cid`, `tmp/attachments`,
        /// `webHost.recycle()` (08). Default no-op.
        var wipeAccountData: @MainActor () async -> Void = {}
        /// Called after `state` became `.signedIn`. 07 wires `{ Task { await sync.run(.launch) } }` (must not block). Default no-op.
        var didSignIn: @MainActor () -> Void = {}
        init()
    }
}
```

#### 3.4.2 `NeedsReauthRelay`

```swift
/// Breaks the construction cycle provider → store → provider: the provider's `onNeedsReauth` closure captures the relay,
/// `AppEnvironment` points the relay at the store once it exists. `@MainActor` (implicit) ⇒ `Sendable`.
final class NeedsReauthRelay {
    weak var auth: AuthStore?
    init()
    /// Safe from any thread: `Task { @MainActor in self.auth?.markNeedsReauth() }`.
    nonisolated func fire()
}
```

### 3.5 `minimail/Auth/Keychain.swift`

```swift
import Foundation
import Security

/// Verbatim architecture §2.4 (`[ios-platform §5.5]`). Generic-password items, primary key `service` + `account`.
/// All functions are synchronous and block the calling thread (Security framework); only `exists` may run on main (< 5 ms, attributes only).
nonisolated enum Keychain {
    static let service = "com.minimail"
    /// `SecItemCopyMatching` with `kSecReturnAttributes: true`, `kSecMatchLimit: kSecMatchLimitOne` (no data decrypt).
    /// `errSecSuccess` → true; `errSecItemNotFound` → false; `errSecInteractionNotAllowed` → true (item present, device not yet unlocked; logged); any other status → false + `Log.auth.error`.
    static func exists(account: String) -> Bool
    /// `SecItemUpdate` (`kSecValueData`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), falling back to
    /// `SecItemAdd` on `errSecItemNotFound`. Throws `AuthError.keychain(status)` for any other status.
    static func set(_ data: Data, account: String) throws
    /// `SecItemCopyMatching` with `kSecReturnData: true`. `nil` on `errSecItemNotFound`; throws `AuthError.keychain(status)` otherwise.
    static func get(account: String) throws -> Data?
    /// `SecItemDelete`. `errSecSuccess` and `errSecItemNotFound` both succeed; anything else throws `AuthError.keychain(status)`.
    static func delete(account: String) throws
}
```

### 3.6 `minimail/Features/SignIn/SignInScreen.swift`

```swift
import SwiftUI

/// The screen for `auth.state == .signedOut` (architecture §8.1–§8.2). Owns no state beyond what `AuthStore` publishes.
struct SignInScreen: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View            // §6.1
}

/// What the text block under the button shows. Pure so it is testable without hosting the view.
enum SignInMessage: Equatable {
    case none
    case configMissing                     // config.isPlaceholder
    case adminPolicy(clientID: String)     // lastAuthError?.isAdminPolicyEnforced
    case error(String)                     // any other lastError
    /// Precedence: `configMissing` > `adminPolicy` > `error` > `none`. `userCancelled` → `.none` (the user knows).
    static func select(config: OAuthConfig, lastAuthError: AuthError?, lastError: String?) -> SignInMessage
    /// The exact strings of §5.6.
    var text: String? { get }
}
```

### 3.7 `minimail/App/AppEnvironment.swift` (modify)

Additions to the `[01 §3.10]` declaration; everything else unchanged.

```swift
@Observable final class AppEnvironment {
    // … 01 properties …
    /// Read once from `Info.plist` in `init` (a dictionary lookup; no I/O beyond the already-loaded bundle plist).
    let oauthConfig: OAuthConfig
    /// Constructed in `init` (no I/O). `load()` runs in `startDeferredWork()`.
    let tokens: AppAuthTokenProvider
    /// Routing state computed in `init` from `Keychain.exists` + `cachedEmail`.
    let auth: AuthStore
    /// `OAuthConfig.testingKeychainAccount` when `isTesting`, else `OAuthConfig.keychainAccount` — so the test host never sees a developer's real item.
    var keychainAccount: String { get }
}
```

### 3.8 `minimail/App/RootView.swift` (modify)

```swift
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View
    // Group { switch env.auth.state { case .signedOut: SignInScreen(); case .signedIn, .needsReauth: SignedInPlaceholderView() } }
    //   .preferredColorScheme(env.theme.preferredColorScheme).tint(themeTokens.accent).task { await env.startDeferredWork() }
    // [09] replaces `SignedInPlaceholderView()` with `NavigationStack { InboxScreen(scope: .inbox) }` and deletes the placeholder.
}

/// Interim signed-in surface so the auth flows can be exercised on a device before module 09 exists. Deleted by 09.
struct SignedInPlaceholderView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View            // §6.2
}
```

`RootPlaceholderView` from 01 stays in the file unused until 09 deletes both placeholders (keeping it avoids touching 01's tests, which host `RootView`, not the placeholder).

### 3.9 `minimail/App/MinimailApp.swift` (modify)

```swift
WindowGroup {
    RootView()
        .environment(env)
        .environment(env.theme)
        .environment(env.settings)
        .onOpenURL { url in _ = env.auth.resume(url: url) }      // architecture §5.1 step 4, [ios-platform §1.4]
}
```

---

## 4. Behaviour

### 4.1 `OAuthConfig`

`init(clientID:)`:
```
self.clientID = clientID
let suffix = ".apps.googleusercontent.com"
let prefix = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
self.redirectURL = URL(string: "com.googleusercontent.apps.\(prefix):/oauth2redirect")!      // scheme chars [A-Za-z0-9.-] only; never nil for a Google client id
```
If `URL(string:)` returns nil (a client id containing characters illegal in a URL scheme), fall back to `URL(string: "com.googleusercontent.apps.invalid:/oauth2redirect")!` and `Log.auth.error("client id is not a valid URL scheme")` — the flow will fail with `flowFailed` and the screen shows it; the app never crashes on a bad xcconfig.

`fromInfoPlist(bundle:)`:
```
guard let id = bundle.object(forInfoDictionaryKey: Self.infoPlistKey) as? String, !id.isEmpty
else { Log.auth.error("Info.plist \(Self.infoPlistKey, privacy: .public) missing"); return OAuthConfig(clientID: "REPLACE.apps.googleusercontent.com") }
return OAuthConfig(clientID: id.trimmingCharacters(in: .whitespacesAndNewlines))
```
`fromInfoPlist()` = `fromInfoPlist(bundle: .main)`. `isPlaceholder` = `clientID.isEmpty || clientID.hasPrefix("REPLACE")`.

Endpoints are the OIDC-verified values `[gmail-api "OAuth 2.0 for iOS"]`; no discovery request is ever made (architecture §5.1 step 1).

### 4.2 `Keychain`

Query dictionaries (byte-exact keys; `[CFString: Any]` cast to `CFDictionary`):

| Function | Query | Extra |
|---|---|---|
| `exists` | `kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne` | `SecItemCopyMatching(query, &item)`; result mapping as in §3.5 |
| `set` | `kSecClass, kSecAttrService, kSecAttrAccount` | attrs `kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; `SecItemUpdate(query, attrs)`; on `errSecItemNotFound` → `SecItemAdd(query.merging(attrs) { $1 }, nil)` |
| `get` | `kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne` | `item as? Data` |
| `delete` | `kSecClass, kSecAttrService, kSecAttrAccount` | `SecItemDelete(query)` |

Rules: no access group, no `kSecAttrSynchronizable` (item must not sync via iCloud), no entitlement needed `[ios-platform §5.5]`. `AfterFirstUnlockThisDeviceOnly` keeps BG refresh working after the first unlock and prevents migration to another device (architecture §14 #12). Every non-success status is logged as `Log.auth.error("keychain <fn> status=\(status, privacy: .public)")`. Thread-safety: the Security calls are thread-safe; callers are the actor (`set`/`get`/`delete`) and `AppEnvironment.init` on main (`exists` only).

### 4.3 `AppAuthTokenProvider.load()`

```
1. data = try Keychain.get(account: keychainAccount)
     catch AuthError.keychain(status): Log.auth.error("load keychain status=\(status)"); return false      // item kept (e.g. errSecInteractionNotAllowed)
2. guard let data else { Log.auth.debug("load: no item"); return false }
3. state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
     catch or nil: Log.auth.error("load: unarchive failed; deleting item"); try? Keychain.delete(account: keychainAccount); return false
4. install(state): self.state = state; delegate = StateDelegate(owner: self); state.stateChangeDelegate = delegate; state.errorDelegate = delegate; needsReauthLatched = false; refreshTask = nil
5. Log.auth.notice("load: authorized=\(state.isAuthorized)"); return state.isAuthorized
```
`isAuthorized == false` (AppAuth recorded an `authorizationError` in a previous session, or no refresh token and an expired access token) keeps the state installed (a later `accessToken()` throws `needsReauth` via `mapTokenError`, or refreshes if it can) — the store already went to `.needsReauth` through `handleTokenLoad(succeeded: false)`. Precondition: none; idempotent (a second call re-reads the Keychain). Performance: one Keychain read + one unarchive, ≈ 2–10 ms on the actor, never on main.

### 4.4 `AppAuthTokenProvider.accessToken()` (architecture §5.3 verbatim + latch)

```swift
func accessToken() async throws -> String {
    guard let state else { throw AuthError.signedOut }                          // 1
    if needsReauthLatched { throw AuthError.needsReauth }                        // 2: never loop on invalid_grant
    if let refreshTask { return try await refreshTask.value }                    // 3: single flight — N concurrent callers share one refresh
    let task = Task { [state] in                                                 // 4: inherits actor isolation
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            state.performAction(freshTokens: { token, _, error in               // refreshes iff expired (60 s tolerance) or setNeedsTokenRefresh [ios-platform §1.6]
                if let token { cont.resume(returning: token) } else { cont.resume(throwing: Self.mapTokenError(error)) }
            })
        }
    }
    refreshTask = task
    defer { refreshTask = nil }                                                  // 5: only the creator clears it
    do { return try await task.value }
    catch let e as AuthError where e == .needsReauth {                           // 6
        needsReauthLatched = true; Log.auth.error("refresh: invalid_grant → needsReauth"); onNeedsReauth(); throw e
    }
}
```
Notes:
- Step 3 relies on actor re-entrancy: callers B…N arriving while A awaits see `refreshTask != nil` and await the same value; the callback fires exactly once per `performAction`.
- `performAction(freshTokens:)` returns the cached access token without network when it is fresh (expiry more than 60 s away, AppAuth `kExpiryTimeTolerance`, `[ios-platform §1.6]`); the fast path costs one actor hop.
- Sharers (step 3) rethrow whatever the creator's task threw; only the creator sets the latch and fires `onNeedsReauth()` once.
- `mapTokenError` (step 6 mapping), pure, `nonisolated`:

```
guard let error else { return AuthError.flowFailed("token refresh returned neither token nor error") }
let ns = error as NSError
if ns.domain == OIDOAuthTokenErrorDomain {
    let response = ns.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any]
    let field = response?[OIDOAuthErrorFieldError] as? String
    if ns.code == OIDErrorCodeOAuth.invalidGrant.rawValue || field == "invalid_grant" { return AuthError.needsReauth }
    return AuthError.flowFailed("token: \(field ?? "") \(response?[OIDOAuthErrorFieldErrorDescription] as? String ?? ns.localizedDescription)".trimmingCharacters(in: .whitespaces))
}
if let u = error as? URLError { return u }                                                                  // transport, direct
if ns.domain == OIDGeneralErrorDomain, ns.code == OIDErrorCode.networkError.rawValue {
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? URLError { return u }                                   // transport, wrapped by AppAuth
    if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSURLErrorDomain { return URLError(URLError.Code(rawValue: under.code)) }
    return URLError(.unknown)
}
if ns.domain == OIDGeneralErrorDomain, ns.code == OIDErrorCode.tokenRefreshError.rawValue { return AuthError.needsReauth }   // "Unable to refresh expired token without a refresh token"
return AuthError.flowFailed("\(ns.domain)#\(ns.code): \(ns.localizedDescription)")
```
Constant spellings (`OIDOAuthTokenErrorDomain`, `OIDGeneralErrorDomain`, `OIDOAuthErrorResponseErrorKey`, `OIDOAuthErrorFieldError`, `OIDOAuthErrorFieldErrorDescription`, `OIDErrorCodeOAuth.invalidGrant`, `OIDErrorCode.networkError`, `OIDErrorCode.tokenRefreshError`) are the Swift imports of `Sources/AppAuthCore/OIDError.h`; the implementing agent verifies them on the macOS runner with
`grep -nE "OIDErrorCodeOAuthInvalidGrant|OIDErrorCodeNetworkError|OIDErrorCodeTokenRefreshError|OIDOAuthErrorResponseErrorKey|OIDOAuthErrorFieldError" .build/SourcePackages/checkouts/AppAuth-iOS/Sources/AppAuthCore/OIDError.h` (§10 A1).

Errors thrown, summarised: `AuthError.signedOut`, `AuthError.needsReauth`, `URLError`, `AuthError.flowFailed`. Never `GmailError` (05 is a consumer, not a dependency — §10 D3).

### 4.5 `invalidateAccessToken()`

`state?.setNeedsTokenRefresh()`; `Log.auth.debug("access token invalidated")`. No network, never throws. The next `accessToken()` refreshes (or, if latched, throws `needsReauth` immediately).

### 4.6 `revokeAndClear()` (architecture §5.4)

```
1. let token = state?.refreshToken ?? state?.lastTokenResponse?.accessToken
2. if let token {
       var req = URLRequest(url: revocationEndpoint); req.httpMethod = "POST"; req.timeoutInterval = 3
       req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
       req.httpBody = Data("token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)".utf8)
       do { let (_, r) = try await session.data(for: req); Log.auth.notice("revoke status=\((r as? HTTPURLResponse)?.statusCode ?? -1)") }
       catch { Log.auth.notice("revoke failed: \(String(describing: error), privacy: .public)") }     // best effort: 400 (already invalid) and offline are both fine
   }
3. state?.stateChangeDelegate = nil; state?.errorDelegate = nil; state = nil; delegate = nil; refreshTask = nil; needsReauthLatched = false
4. do { try Keychain.delete(account: keychainAccount) } catch { Log.auth.error("keychain delete failed") }
```
Revoking the refresh token also revokes its access tokens `[gmail-api "Revocation"]`. Idempotent: with no state, steps 3–4 still run (deletes a stray item). Never throws. Total worst case 3 s (timeout) + Keychain.

### 4.7 Persistence (`adopt`, `persistCurrentState`, delegate)

`adopt(_ state:)`:
```
1. install(state)                                     // same as §4.3 step 4
2. data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)   // [ios-platform §1.5]
     catch: self.state = nil; delegate = nil; throw AuthError.flowFailed("archive: \(error.localizedDescription)")
3. try Keychain.set(data, account: keychainAccount)   // throws AuthError.keychain(status) → self.state = nil; delegate = nil; rethrow
4. Log.auth.notice("adopt: persisted \(data.count, privacy: .public) bytes")
```
`persistCurrentState()`: `guard let state else { return }`; steps 2–3 with errors logged (`Log.auth.error`) instead of thrown.

`StateDelegate.didChange(_:)`: `Task { await owner?.persistCurrentState() }` — AppAuth fires it after every token response (access-token rotation, refresh-token rotation, recorded authorization error) `[ios-platform §1.5]`; the archive always reflects the latest state. `authState(_:didEncounterAuthorizationError:)`: `Log.auth.error("authState error: \(String(describing: error), privacy: .public)")` — nothing else; the `accessToken()` path already mapped the same error for its caller. Thread-safety of archiving the `OIDAuthState` on the actor while AppAuth may touch it on its own queue is UNVERIFIED (§10 A5); the archive is a snapshot of immutable response objects, so the worst case is a stale archive that the next `didChange` corrects.

### 4.8 `refreshToken`, `isLoaded`, `needsReauthLatched`

Plain reads of actor state; `refreshToken` exists for the sign-in flow's `missingRefreshToken` check and for tests (never logged).

### 4.9 `AuthStore.init` — routing truth table (architecture §5.2, D22)

```
self.tokens = tokens; self.config = config; self.cachedEmail = cachedEmail; hooks = Hooks(); isSigningIn = false; lastError = nil; lastAuthError = nil
switch (hasKeychainItem, cachedEmail) {
case (true, let email):        state = .signedIn(email: email)        // yes/yes normal; yes/no reinstall → list empty + "Loading your inbox…" (09), run(.launch) does the initial sync (07)
case (false, .some(let email)): state = .needsReauth(email: email)     // no/yes → cached list readable, "Sign in again" banner (09)
case (false, nil):              state = .signedOut                      // no/no → SignInScreen
}
Log.auth.notice("routing: keychain=\(hasKeychainItem) cachedEmail=\(cachedEmail != nil) → \(String(describing: state), privacy: .public)")
```
Budget: microseconds; no I/O (the Keychain call happened in `AppEnvironment.init`, §4.16).

### 4.10 `AuthStore.signIn()` (architecture §5.1 step 2)

```
 1. guard !isSigningIn else { return }
 2. guard !config.isPlaceholder else { fail(.flowFailed("GoogleClientID is not configured")) }        // fail(e): lastAuthError = e; lastError = e.errorDescription; throw e
 3. isSigningIn = true; lastError = nil; lastAuthError = nil; defer { isSigningIn = false; currentFlow = nil }
 4. var params: [String: String] = [:]
    if let hint = hooks.loginHint(), !hint.isEmpty { params["login_hint"] = hint }
    if let hd = config.hostedDomain { params["hd"] = hd }
    var strippedOptional = false, requestedConsent = false
    var authState: OIDAuthState
 5. loop:
      do { authState = try await presentFlow(additionalParameters: params) }
      catch let e as AuthError {
          if !strippedOptional, params["hd"] != nil, Self.shouldRetryWithoutOptionalParameters(e) {   // architecture §5.1: "a failure that mentions them is retried once without them"
              params["hd"] = nil; strippedOptional = true; Log.auth.notice("sign-in: retrying without hd"); continue loop }
          fail(e) }
 6.   if authState.refreshToken == nil, !requestedConsent {                                           // architecture §14 #16
          params["prompt"] = "consent"; requestedConsent = true; Log.auth.notice("sign-in: no refresh token, retrying with prompt=consent"); continue loop }
      guard authState.refreshToken != nil else { fail(.missingRefreshToken) }
      break loop
 7. do { try await tokens.adopt(authState) } catch let e as AuthError { fail(e) }
 8. var email: String? = state.email ?? cachedEmail
    if let fetch = hooks.fetchProfileEmail {
        do { email = try await fetch() }
        catch { await tokens.revokeAndClear(); fail(.flowFailed("profile: \(error.localizedDescription)")) }   // no half state: tokens gone, user taps again
        if let cached = cachedEmail, cached.caseInsensitiveCompare(email!) != .orderedSame {
            Log.auth.notice("sign-in: account changed \(cached, privacy: .private) → \(email!, privacy: .private); wiping")
            await hooks.prepareSignOut(); await hooks.wipeAccountData(); cachedEmail = nil }             // architecture §5.1: "different email wipes"
    }
 9. if let email { hooks.rememberEmail(email); cachedEmail = email }                                  // settings.lastSignedInEmail = login_hint for next time
10. state = .signedIn(email: email); Log.auth.notice("signed in")
11. hooks.didSignIn()                                                                                   // 07: Task { await sync.run(.launch) }
```
`presentFlow(additionalParameters:)` (private, main):
```
guard let vc = Self.presentingViewController() else { throw AuthError.flowFailed("no key window to present sign-in") }
let request = OIDAuthorizationRequest(configuration: config.serviceConfiguration, clientId: config.clientID, clientSecret: nil,
                                      scopes: config.scopes, redirectURL: config.redirectURL, responseType: OIDResponseTypeCode,
                                      additionalParameters: params.isEmpty ? nil : params)
guard let agent = OIDExternalUserAgentIOS(presentingViewController: vc, prefersEphemeralSession: false) else { throw AuthError.flowFailed("cannot create external user agent") }
return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OIDAuthState, any Error>) in
    currentFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
        Task { @MainActor in                                                    // AppAuth callbacks are not MainActor-isolated [ios-platform §1.4]
            self.currentFlow = nil
            if let state { cont.resume(returning: state) } else { cont.resume(throwing: Self.classifyFlowError(error)) }
        }
    }
}
```
`presentingViewController()`: `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController` `[ios-platform §1.4]`. `prefersEphemeralSession: false` (shared Safari cookies → one-tap account chooser, `[ios-platform §1.3]`); iOS still shows the "wants to use google.com to sign in" consent sheet.

`classifyFlowError(_:)` (pure):
```
guard let error else { return .flowFailed("authorization returned neither state nor error") }
let ns = error as NSError
if ns.domain == OIDGeneralErrorDomain, ns.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue || ns.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue { return .userCancelled }
let response = ns.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any]
var parts: [String] = []
if let f = response?[OIDOAuthErrorFieldError] as? String { parts.append(f) }                           // e.g. "admin_policy_enforced", "access_denied"
if let d = response?[OIDOAuthErrorFieldErrorDescription] as? String { parts.append(d) }
if !parts.contains(ns.localizedDescription) { parts.append(ns.localizedDescription) }
return .flowFailed("\(ns.domain)#\(ns.code): " + parts.joined(separator: " — "))
```
`shouldRetryWithoutOptionalParameters(_ e:)`: `guard case .flowFailed(let text) = e else { return false }`; `let t = text.lowercased()`; return `!t.contains("admin_policy_enforced") && !t.contains("access_denied") && !t.contains("invalid_client") && !t.contains("redirect_uri_mismatch")` — those four are real configuration/policy failures that a second browser sheet cannot fix; everything else (including Google rejecting `hd` for the native flow, UNVERIFIED §10 A3) earns exactly one retry without `hd`. Upper bound: three browser presentations (hd → no hd → prompt=consent).

Edge cases:
- User cancels the sheet: `userCancelled` → `lastError = nil` special case: `fail(.userCancelled)` sets `lastAuthError = .userCancelled` but `lastError = nil` (no text under the button; `SignInMessage.select` returns `.none`). Still thrown so callers (banner, placeholder) can ignore it with `try?`.
- `signIn()` from `.needsReauth(e)` with the same e-mail: step 8 finds `cachedEmail == email` → no wipe; state `.signedIn(e)`; `didSignIn` → 07 resumes sync and drain with the intact cache and outbox (architecture §5.3 last sentence).
- `signIn()` from `.needsReauth(e)` with a different e-mail: wipe (step 8) → `.signedIn(new)`; the outbox rows of the old account are gone with the DB.
- App backgrounded during the sheet: AppAuth's `ASWebAuthenticationSession` completes or cancels on its own; nothing to do.
- `hooks.fetchProfileEmail == nil` (before 05 exists): `email` stays `state.email ?? cachedEmail` (nil on a fresh install) → `.signedIn(email: nil)`; 07's first full sync stores `accountEmail`.

Concurrency: whole function on main; awaits hop to the provider actor and back. Nothing blocks main for longer than a dictionary build; the browser sheet runs out of process.

### 4.11 `AuthStore.signOut()` (architecture §5.4)

```
1. guard state != .signedOut else { return }
2. currentFlow?.cancel(); currentFlow = nil                       // a sheet that is still up is dismissed
3. await hooks.prepareSignOut()                                   // 07: cancel running sync/drain and await them
4. await tokens.revokeAndClear()                                  // POST /revoke (3 s, best effort) + Keychain delete  (§4.6)
5. await hooks.wipeAccountData()                                  // 06: close pool → Database.destroy → reopen empty; 08: purge Caches/attachments, Caches/cid, tmp/attachments, webHost.recycle()
6. try? await UNUserNotificationCenter.current().setBadgeCount(0) // [ios-platform §6]; throws when notifications were never authorised → ignored
7. cachedEmail = nil; lastError = nil; lastAuthError = nil; state = .signedOut; Log.auth.notice("signed out")
```
Kept: `Settings` (theme, compose style, signature, `lastSignedInEmail` as the next `login_hint`) — architecture §5.4. Order matters: tokens are revoked before the DB is destroyed so a crash between 4 and 5 leaves "no item + cached e-mail" = `.needsReauth` on next launch, which is recoverable; the reverse order would leave live tokens with no cache (`.signedIn(nil)`, also recoverable) — either is acceptable, the architecture's order is kept.

### 4.12 `AuthStore.resume(url:)`

```
guard let flow = currentFlow else { return false }
guard url.scheme?.lowercased() == config.redirectURL.scheme?.lowercased() else { return false }
do { try flow.resumeExternalUserAgentFlow(url); currentFlow = nil; Log.auth.debug("resumed flow via onOpenURL"); return true }
catch { Log.auth.notice("resume rejected: \(String(describing: error), privacy: .public)"); return false }
```
With `ASWebAuthenticationSession` the redirect normally arrives through AppAuth's completion handler and `.onOpenURL` never fires; this is the documented fallback `[ios-platform §1.4]`. Swift spelling `resumeExternalUserAgentFlow(_:)` per the 3.0.0 CHANGELOG `[ios-platform §1.1]`; whether it imports as `throws` or `-> Bool` is UNVERIFIED (§10 A2) — if it returns `Bool`, `return flow.resumeExternalUserAgentFlow(url)` with the same `currentFlow = nil` on `true`.

### 4.13 `markNeedsReauth()`

```
switch state {
case .signedIn(let email): state = .needsReauth(email: email); lastAuthError = .needsReauth; lastError = AuthError.needsReauth.errorDescription; Log.auth.notice("needsReauth")
case .needsReauth, .signedOut: break                                // idempotent; a late signal after sign-out is ignored
}
```
Callers: `NeedsReauthRelay.fire()` (provider, `invalid_grant`), `GmailClient` after the second 401 (05), 07 when it catches `AuthError.needsReauth` from a request. Effects owned by others: 09 shows the dismissable banner; 07 pauses sync and drain while `state` is `.needsReauth`; cache and outbox stay intact.

### 4.14 `handleTokenLoad(succeeded:)`

```
if !succeeded, case .signedIn = state { Log.auth.notice("token load failed → needsReauth"); markNeedsReauth() }
```
Covers: the item exists but is corrupt (deleted by `load()`), unreadable (Keychain status), or `isAuthorized == false`. `.signedIn(nil)` becomes `.needsReauth(nil)` (banner without e-mail).

### 4.15 `handleAccountMismatch(expected:got:)`

```
let e = AuthError.accountMismatch(expected: expected, got: got)
Log.auth.error("account mismatch")                                  // addresses are private; not logged
await signOut()                                                     // wipes DB + caches, revokes, → .signedOut
lastAuthError = e; lastError = e.errorDescription                   // set AFTER signOut (which clears them) so SignInScreen explains why
```
07 calls it from `fullSync` when `profile.emailAddress != syncState.accountEmail` (architecture §4.2 "AuthStore: wipe + sign out"), then aborts the run.

### 4.16 `AppEnvironment` changes (architecture §12.2)

`init(testing:)` step 3 (the `// [04]` insertion point of `[01 §4.10]`) becomes:
```
let keychainAccount = testing ? OAuthConfig.testingKeychainAccount : OAuthConfig.keychainAccount
let hasItem = Keychain.exists(account: keychainAccount)                     // one SecItemCopyMatching, attributes only, < 5 ms
let cachedEmail: String? = nil                                              // [06] replaces with: try? db.read { try SyncStateRepository.get($0, .accountEmail) }
let relay = NeedsReauthRelay()
let tokens = AppAuthTokenProvider(keychainAccount: keychainAccount, onNeedsReauth: { relay.fire() })
let oauthConfig = OAuthConfig.fromInfoPlist()
let auth = AuthStore(tokens: tokens, config: oauthConfig, hasKeychainItem: hasItem, cachedEmail: cachedEmail)
relay.auth = auth
self.tokens = tokens; self.oauthConfig = oauthConfig; self.auth = auth
```
New step 9 (after `theme`, after the 05/07/08 construction comments, before the final log line) — hooks owned by 01's objects:
```
auth.hooks.loginHint = { [settings] in settings.settings.lastSignedInEmail }
auth.hooks.rememberEmail = { [settings] email in settings.update { $0.lastSignedInEmail = email } }
// [05] auth.hooks.fetchProfileEmail = { [gmail] in try await gmail.getProfile().emailAddress }
// [06][08] auth.hooks.wipeAccountData = { … close pool, Database.destroy, reopen, purge caches, webHost.recycle() … }
// [07] auth.hooks.prepareSignOut = { … cancel + await sync/drain … } ; auth.hooks.didSignIn = { Task { await sync.run(.launch) } }
```
`startDeferredWork()` step a (the `// [04]` comment) becomes:
```
let loaded = await tokens.load()
auth.handleTokenLoad(succeeded: loaded)
```
`keychainAccount` is exposed as a computed property (`tokens.keychainAccount`) for tests. The 01 acceptance criterion 7 grep (`import Security` under `minimail/App`) still passes: `AppEnvironment.swift` calls `Keychain.exists` without importing Security.

Budget: `Keychain.exists` ≈ 1–5 ms on device; the rest is allocation. Still inside the 15 ms step-1 budget.

### 4.17 `RootView` / `MinimailApp`

`RootView.body`: `Group { switch env.auth.state { case .signedOut: SignInScreen(); case .signedIn, .needsReauth: SignedInPlaceholderView() } }` with 01's three modifiers in the same order (`.preferredColorScheme`, `.tint`, `.task`). The `.task` sits on the `Group`, whose identity does not change when the switch flips, so `startDeferredWork()` runs exactly once per window (it is also idempotent).

`MinimailApp`: adds `.onOpenURL { url in _ = env.auth.resume(url: url) }` on `RootView()` after the three `.environment` modifiers.

---

## 5. Data

### 5.1 Keychain item

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `com.minimail` |
| `kSecAttrAccount` | `oauth.authState` (app) / `oauth.authState.testing` (test host, `AppEnvironment(testing: true)`) / `test.<function>` (unit tests, deleted in `tearDown`) |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `kSecValueData` | `NSKeyedArchiver.archivedData(withRootObject: OIDAuthState, requiringSecureCoding: true)` — binary plist, opaque, typically 2–6 KB (contains the refresh token, the last access token, expiry, scope, the authorization request incl. PKCE verifier) |
| Access group / synchronizable | none / absent |

### 5.2 Authorization request (built by `OIDAuthorizationRequest`; shown for verification with `RequestLog` is impossible — the browser sends it)

```
https://accounts.google.com/o/oauth2/v2/auth?
  client_id=<prefix>.apps.googleusercontent.com
  &redirect_uri=com.googleusercontent.apps.<prefix>:/oauth2redirect
  &response_type=code
  &scope=https://www.googleapis.com/auth/gmail.modify
  &code_challenge=<base64url(SHA256(code_verifier))>&code_challenge_method=S256
  &state=<random>
  &login_hint=<Settings.lastSignedInEmail>          (attempt 1+, only when non-nil)
  &hd=example.com                                    (attempt 1 only; dropped by the optional-parameter retry)
  &prompt=consent                                    (only on the missing-refresh-token retry)
```
`[gmail-api "OAuth 2.0 for iOS"]`. PKCE is generated by AppAuth; the client has no secret.

### 5.3 Token endpoint traffic (AppAuth-owned; shapes the test stub reproduces)

Refresh request: `POST https://oauth2.googleapis.com/token`, `Content-Type: application/x-www-form-urlencoded`, body `client_id=<id>&grant_type=refresh_token&refresh_token=<rt>` (parameter order is AppAuth's).
Success: `200 {"access_token":"ya29.…","expires_in":3599,"scope":"https://www.googleapis.com/auth/gmail.modify","token_type":"Bearer"}`.
Terminal failure: `400 {"error":"invalid_grant","error_description":"Bad Request"}` → `AuthError.needsReauth` `[gmail-api gotcha 18]`.

Revocation: `POST https://oauth2.googleapis.com/revoke`, `Content-Type: application/x-www-form-urlencoded`, body `token=<refresh token, percent-encoded to alphanumerics>`; `200` success, `400` already invalid — both ignored.

### 5.4 `Info.plist` keys consumed (owned by 01, `[01 §5.1]`)

| Key | Value | Used by |
|---|---|---|
| `GoogleClientID` | `$(GOOGLE_CLIENT_ID)` from `Config/Google.xcconfig` | `OAuthConfig.fromInfoPlist()` |
| `CFBundleURLTypes[0].CFBundleURLSchemes[0]` | `$(GOOGLE_REVERSED_CLIENT_ID)` = `com.googleusercontent.apps.<prefix>` | iOS delivers the redirect; must equal `redirectURL.scheme` (`OAuthConfigTests.testSchemeMatchesBundleURLScheme`) |

### 5.5 State machine

| From | Event | To | Side effects |
|---|---|---|---|
| (init) | Keychain item ∧ any e-mail | `signedIn(email?)` | — |
| (init) | no item ∧ e-mail | `needsReauth(email)` | — |
| (init) | no item ∧ no e-mail | `signedOut` | — |
| `signedIn(e)` | `handleTokenLoad(false)` | `needsReauth(e)` | `lastError` set |
| `signedIn(e)` | `markNeedsReauth()` | `needsReauth(e)` | `lastError` set |
| `signedOut` / `needsReauth(e)` | `signIn()` success, same or first e-mail | `signedIn(email)` | tokens persisted; `rememberEmail`; `didSignIn` |
| `needsReauth(e)` | `signIn()` success, different e-mail | `signedIn(new)` | `prepareSignOut` + `wipeAccountData` first |
| `signedOut` / `needsReauth` | `signIn()` failure | unchanged | `lastError` (nil for cancel); tokens revoked if adopted before the failure |
| any but `signedOut` | `signOut()` | `signedOut` | revoke, wipe, badge 0 |
| any | `handleAccountMismatch` | `signedOut` | as `signOut()` + `lastError` = mismatch text |
| `signedOut` / `needsReauth` | `markNeedsReauth()` | unchanged | — |

### 5.6 Strings (exact; English only, `SWIFT_EMIT_LOC_STRINGS` picks them up)

| Id | Text |
|---|---|
| title | `minimail` |
| subtitle | `Gmail for example.com` |
| button | `Sign in with Google` |
| button.busy | `Signing in…` |
| `AuthError.signedOut` | `Not signed in.` |
| `AuthError.needsReauth` | `Your Google session has expired. Sign in again.` |
| `AuthError.userCancelled` | `Sign-in was cancelled.` |
| `AuthError.flowFailed(t)` | `Sign-in failed: <t>` |
| `AuthError.missingRefreshToken` | `Google did not return a refresh token. Sign in again and approve access.` |
| `AuthError.accountMismatch(e, g)` | `Google signed in <g>, but the mail on this device belongs to <e>. The local copy was cleared — sign in again.` |
| `AuthError.keychain(s)` | `Keychain error <s>.` |
| `SignInMessage.configMissing` | `Google client ID is not configured. Set GOOGLE_CLIENT_ID in Config/Google.xcconfig and rebuild.` |
| `SignInMessage.adminPolicy(id)` | `Your Google Workspace administrator has not allowed minimail yet. In the Admin console open Security → Access and data control → API controls → Manage Third-Party App Access and mark this client ID as Trusted, or enable "Trust internal, domain-owned apps".` + `\n` + `<id>` |
| `SignInMessage.error(t)` | `<t>` |
| placeholder.signedIn | `Signed in as <email>` / `Loading your inbox…` when e-mail is nil |
| placeholder.needsReauth | `Sign in again to keep syncing.` |
| placeholder.signInAgain | `Sign in again` |
| placeholder.signOut | `Sign out` |

### 5.7 Settings touched (owned by 01)

`Settings.lastSignedInEmail: String?` — written by `hooks.rememberEmail` after every successful sign-in; read by `hooks.loginHint`; kept on sign-out (architecture §5.4, §11). Never used as identity (`syncState.accountEmail` is).

---

## 6. UI

### 6.1 `SignInScreen`

```
VStack(spacing: 16)                                        .padding(.horizontal, 32) .frame(maxWidth: .infinity, maxHeight: .infinity) .background(themeTokens.background.ignoresSafeArea())
 ├─ Spacer()
 ├─ Image(systemName: "envelope")                          .font(.system(size: 56, weight: .regular)) .foregroundStyle(themeTokens.accent) .accessibilityHidden(true)
 ├─ Text("minimail")                                       .font(.largeTitle.bold()) .foregroundStyle(themeTokens.text)
 ├─ Text("Gmail for example.com")                          .font(.subheadline) .foregroundStyle(themeTokens.secondaryText)
 ├─ Spacer()
 ├─ Button { Task { try? await env.auth.signIn() } } label: {
 │     HStack(spacing: 8) { if env.auth.isSigningIn { ProgressView().controlSize(.small) }
 │                          Text(env.auth.isSigningIn ? "Signing in…" : "Sign in with Google") }
 │     .frame(maxWidth: .infinity) }
 │   .buttonStyle(.borderedProminent) .controlSize(.large)
 │   .disabled(env.auth.isSigningIn || env.oauthConfig.isPlaceholder)
 │   .accessibilityLabel("Sign in with Google") .accessibilityHint("Opens Google in a browser sheet") .accessibilityIdentifier("signin.button")
 ├─ if let text = message.text {
 │     Label { Text(text).font(.footnote).foregroundStyle(themeTokens.secondaryText).multilineTextAlignment(.leading).textSelection(.enabled) }
 │           icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(themeTokens.accent) }
 │       .accessibilityIdentifier("signin.message") }
 └─ Spacer().frame(height: 24)
```
where `message = SignInMessage.select(config: env.oauthConfig, lastAuthError: env.auth.lastAuthError, lastError: env.auth.lastError)`.

States:
| State | Rendering |
|---|---|
| idle, configured | button enabled, no message |
| `isSigningIn` | spinner + "Signing in…", button disabled (the browser sheet is on top) |
| `config.isPlaceholder` | button disabled, `configMissing` text |
| `lastAuthError.isAdminPolicyEnforced` | button enabled, remedy text with the client id (`textSelection(.enabled)` so the owner can copy it) |
| other error | button enabled, `lastError` text |
| cancelled | button enabled, no message |

Actions: tap → `signIn()`. Errors are thrown and swallowed (`try?`) because the store already published them. No haptics (nothing succeeds on this screen — success replaces it). No navigation; `RootView` swaps it out when `state` leaves `.signedOut`. Colours: `themeTokens.background/text/secondaryText/accent` only (there is no error token; the triangle icon carries the meaning). Fonts: system. Dark mode: inherited from `RootView`. Rotation: portrait only (project setting).

### 6.2 `SignedInPlaceholderView` (interim, deleted by 09)

```
VStack(spacing: 12) .padding(32) .frame(maxWidth: .infinity, maxHeight: .infinity) .background(themeTokens.background.ignoresSafeArea())
 ├─ Image(systemName: "tray")                      .font(.system(size: 44)) .foregroundStyle(themeTokens.accent) .accessibilityHidden(true)
 ├─ Text(env.auth.state.email.map { "Signed in as \($0)" } ?? "Loading your inbox…")   .font(.headline) .foregroundStyle(themeTokens.text)
 ├─ if case .needsReauth = env.auth.state {
 │     Text("Sign in again to keep syncing.")      .font(.subheadline) .foregroundStyle(themeTokens.secondaryText)
 │     Button("Sign in again") { Task { try? await env.auth.signIn() } } .buttonStyle(.borderedProminent) .disabled(env.auth.isSigningIn) }
 ├─ if let text = env.auth.lastError { Text(text).font(.footnote).foregroundStyle(themeTokens.secondaryText) }
 └─ Button("Sign out", role: .destructive) { Task { await env.auth.signOut() } } .buttonStyle(.bordered) .accessibilityIdentifier("placeholder.signout")
```
Exists so T04.8 (device check) can exercise sign-in → sign-out → sign-in again and the reauth path before 09 lands.

---

## 7. Tests

All tests in this module are app tests (`minimailTests`, `xcodebuild test` via `make test-app`; simulator `iPhone 17`). Nothing here runs under `swift test` (no package code). Test classes are `final class … : XCTestCase`, main-actor by default. Every test that touches the Keychain uses `account = "test.\(name)"` and deletes it in `setUp` and `tearDown`.

### 7.1 Fixtures and helpers (private to each test file — 14 owns `minimailTests/Support`)

`AppAuthTokenProviderTests.swift` contains:

```swift
/// Builds an in-memory OIDAuthState without any network: authorization response + token response for the test client.
private func makeAuthState(accessToken: String = "at-1", expiresIn: TimeInterval = 3600, refreshToken: String? = "rt-1") -> OIDAuthState
//   cfg = OIDServiceConfiguration(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth", tokenEndpoint: "https://oauth2.googleapis.com/token")
//   req = OIDAuthorizationRequest(configuration: cfg, clientId: "test.apps.googleusercontent.com", clientSecret: nil, scopes: ["https://www.googleapis.com/auth/gmail.modify"],
//                                 redirectURL: "com.googleusercontent.apps.test:/oauth2redirect", responseType: OIDResponseTypeCode, additionalParameters: nil)
//   authResp = OIDAuthorizationResponse(request: req, parameters: ["code": "c" as NSString, "state": req.state! as NSString])
//   tokenReq = OIDTokenRequest(configuration: cfg, grantType: OIDGrantTypeAuthorizationCode, authorizationCode: "c", redirectURL: req.redirectURL, clientID: req.clientID,
//                              clientSecret: nil, scope: nil, refreshToken: nil, codeVerifier: req.codeVerifier, additionalParameters: nil)
//   params: [String: NSCopying & NSObjectProtocol] = ["access_token": accessToken, "token_type": "Bearer", "expires_in": NSNumber(value: expiresIn)] + refresh_token when non-nil
//   return OIDAuthState(authorizationResponse: authResp, tokenResponse: OIDTokenResponse(request: tokenReq, parameters: params))

/// URLProtocol that answers https://oauth2.googleapis.com/token and /revoke. Installed with
/// `OIDURLSessionProvider.setSession(URLSession(configuration: cfg))` where `cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TokenEndpointStub.self]`
/// (AppAuth routes token requests through `OIDURLSessionProvider.session`, default `URLSession.shared`; UNVERIFIED §10 A4 — fallback `URLProtocol.registerClass`).
/// `tearDown` restores `OIDURLSessionProvider.setSession(URLSession.shared)`.
private final class TokenEndpointStub: URLProtocol {
    struct Reply { var status: Int; var json: String; var delay: TimeInterval = 0; var fail: URLError.Code? = nil }
    nonisolated(unsafe) static var reply = Reply(status: 200, json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#)
    nonisolated(unsafe) static var requests: [(url: URL, body: String)] = []     // body read from httpBodyStream (httpBody is nil inside URLProtocol)
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool   // host == "oauth2.googleapis.com"
    override func startLoading()                                     // record; sleep(delay); if fail → client.urlProtocol(self, didFailWithError: URLError(fail)); else 200/400 + JSON
}
```
`AuthStoreTests.swift` contains `private final class RevokeStub: URLProtocol` (always 200, records requests) and `private func makeStore(hasKeychainItem: Bool, cachedEmail: String?, account: String) -> (AuthStore, AppAuthTokenProvider, HookLog)` where `HookLog` is a `@MainActor final class` with `var calls: [String]` appended by every hook.

### 7.2 Test table

| Test file | Function | Setup | Assertions |
|---|---|---|---|
| `minimailTests/Auth/KeychainTests.swift` | `testServiceConstant` | — | `Keychain.service == "com.minimail"` |
| | `testGetMissingIsNil` | fresh account | `try Keychain.get(account:) == nil`; `Keychain.exists(account:) == false` |
| | `testSetGetRoundTrip` | `set(Data("hello".utf8))` | `get == Data("hello".utf8)`; `exists == true` |
| | `testOverwriteReplaces` | `set("a")`, `set("bb")` | `get == Data("bb".utf8)` (update path, not a duplicate-item error) |
| | `testDeleteRemoves` | set, delete | `get == nil`, `exists == false` |
| | `testDeleteMissingDoesNotThrow` | fresh account | `XCTAssertNoThrow(try Keychain.delete(account:))` |
| | `testLargePayload` | `set(Data(repeating: 0xAB, count: 65_536))` | round trip equal, `count == 65_536` |
| | `testAccountsAreIsolated` | set "x" on account A, set "y" on account B | `get(A) == "x"`, `get(B) == "y"`; delete A leaves B |
| | `testExistsIsFast` | set once; `measure { _ = Keychain.exists(account:) }` | recorded only (target < 5 ms; no gate — decision 15) |
| `minimailTests/Auth/OAuthConfigTests.swift` | `testRedirectFromClientID` | `OAuthConfig(clientID: "123-abc.apps.googleusercontent.com")` | `redirectURL.absoluteString == "com.googleusercontent.apps.123-abc:/oauth2redirect"`; `redirectURL.scheme == "com.googleusercontent.apps.123-abc"` |
| | `testRedirectWithoutSuffix` | `OAuthConfig(clientID: "raw")` | `redirectURL.absoluteString == "com.googleusercontent.apps.raw:/oauth2redirect"` |
| | `testEndpointsAndScope` | any config | `authorizationEndpoint == "https://accounts.google.com/o/oauth2/v2/auth"`, `tokenEndpoint == "https://oauth2.googleapis.com/token"`, `revocationEndpoint == "https://oauth2.googleapis.com/revoke"`, `scopes == ["https://www.googleapis.com/auth/gmail.modify"]`, `hostedDomain == "example.com"` |
| | `testPlaceholderDetection` | `"REPLACE.apps.googleusercontent.com"`, `""`, `"123.apps.googleusercontent.com"` | `isPlaceholder` `true`, `true`, `false` |
| | `testFromInfoPlistReadsBundle` | `OAuthConfig.fromInfoPlist(bundle: .main)` | `clientID == Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String` |
| | `testFromInfoPlistMissingKeyFallsBack` | `Bundle(for: Self.self)` (test bundle has no key) | `isPlaceholder == true` |
| | `testSchemeMatchesBundleURLScheme` | `fromInfoPlist()`; first `CFBundleURLTypes[0].CFBundleURLSchemes[0]` from `Bundle.main.infoDictionary` | equal strings (proves `GOOGLE_CLIENT_ID` / `GOOGLE_REVERSED_CLIENT_ID` agree) |
| | `testServiceConfiguration` | | `serviceConfiguration.authorizationEndpoint == authorizationEndpoint`, `.tokenEndpoint == tokenEndpoint` |
| | `testKeychainAccountConstants` | | `OAuthConfig.keychainAccount == "oauth.authState"`, `testingKeychainAccount == "oauth.authState.testing"` |
| `minimailTests/Auth/AppAuthTokenProviderTests.swift` | `testLoadWithoutItemIsFalse` | provider on a fresh account | `await load() == false`; `isLoaded == false`; `accessToken()` throws `AuthError.signedOut` |
| | `testAdoptPersistsAndLoadsAgain` | `adopt(makeAuthState())` | `Keychain.exists(account) == true`; a **second** provider on the same account: `load() == true`, `refreshToken == "rt-1"`, `accessToken() == "at-1"` (no network — stub records 0 requests) |
| | `testFreshTokenNeedsNoNetwork` | adopt `expiresIn: 3600` | `accessToken() == "at-1"`; `TokenEndpointStub.requests.isEmpty` |
| | `testExpiredTokenRefreshes` | adopt `expiresIn: 30` (inside AppAuth's 60 s tolerance); stub 200 `at-2` | `accessToken() == "at-2"`; exactly 1 request to `/token`; body contains `grant_type=refresh_token` and `refresh_token=rt-1` |
| | `testInvalidateForcesRefresh` | adopt fresh; `invalidateAccessToken()`; stub 200 `at-2` | `accessToken() == "at-2"`; 1 request |
| | `testSingleFlightRefresh` | adopt `expiresIn: 30`; stub `delay: 0.3`; `async let` ×5 `accessToken()` | all five `== "at-2"`; `TokenEndpointStub.requests.count == 1` |
| | `testInvalidGrantLatchesAndSignals` | adopt `expiresIn: 30`; stub 400 `{"error":"invalid_grant"}`; `onNeedsReauth` increments a counter | first `accessToken()` throws `AuthError.needsReauth`; `needsReauthLatched == true`; second call throws `needsReauth` with **no** new request; counter `== 1` after both |
| | `testAdoptClearsLatch` | after the previous scenario, `adopt(makeAuthState())` | `needsReauthLatched == false`; `accessToken() == "at-1"` |
| | `testTransportErrorIsURLError` | adopt `expiresIn: 30`; stub `fail: .notConnectedToInternet` | `accessToken()` throws; `(error as? URLError)?.code == .notConnectedToInternet`; `needsReauthLatched == false`; counter `== 0` |
| | `testRefreshResultIsReArchived` | adopt `expiresIn: 30`; `let before = Keychain.get`; refresh → `at-2`; wait ≤ 1 s for the delegate hop | `Keychain.get != before`; a new provider's `load()` then `accessToken() == "at-2"` without a request |
| | `testRevokeAndClearPostsAndDeletes` | adopt; provider built with `session` = stub session, `revocationEndpoint` = `https://oauth2.googleapis.com/revoke` | one request with `url.path == "/revoke"`, method `POST`, header `Content-Type == "application/x-www-form-urlencoded"`, body `== "token=rt-1"`; afterwards `Keychain.exists == false`, `isLoaded == false`, `refreshToken == nil`, `accessToken()` throws `signedOut` |
| | `testRevokeWithoutStateStillDeletesItem` | `Keychain.set(junk)`; provider never loaded | `revokeAndClear()` → `exists == false`; 0 requests |
| | `testRevokeSurvivesNetworkFailure` | adopt; stub `fail: .timedOut` for `/revoke` | returns (no throw); item deleted |
| | `testLoadDeletesCorruptItem` | `Keychain.set(Data("garbage".utf8))` | `load() == false`; `Keychain.exists == false` |
| | `testMapTokenErrorTable` | construct `NSError`s: (`OIDOAuthTokenErrorDomain`, code `invalidGrant`), (`OIDOAuthTokenErrorDomain`, code -1, userInfo response `["error": "invalid_grant"]`), (`OIDOAuthTokenErrorDomain`, response `["error": "invalid_client"]`), `URLError(.timedOut)`, (`OIDGeneralErrorDomain`, `networkError`, underlying `URLError(.networkConnectionLost)`), (`OIDGeneralErrorDomain`, `tokenRefreshError`), (`"Other"`, 7), `nil` | `.needsReauth`, `.needsReauth`, `.flowFailed` containing `"invalid_client"`, `URLError .timedOut`, `URLError .networkConnectionLost`, `.needsReauth`, `.flowFailed` containing `"Other#7"`, `.flowFailed` |
| `minimailTests/Auth/AuthStoreTests.swift` | `testRoutingTable` | four `makeStore` combinations | `(true, "a@x") → .signedIn("a@x")`; `(true, nil) → .signedIn(nil)`; `(false, "a@x") → .needsReauth("a@x")`; `(false, nil) → .signedOut`; `lastError == nil` in all |
| | `testStateEmailHelper` | | `State.signedOut.email == nil`, `.signedIn(email: "a").email == "a"`, `.needsReauth(email: "b").email == "b"`, `isSignedOut` true only for `.signedOut` |
| | `testMarkNeedsReauth` | `(true, "a@x")` | after: `state == .needsReauth(email: "a@x")`, `lastAuthError == .needsReauth`, `lastError == AuthError.needsReauth.errorDescription`; calling again → unchanged; from `.signedOut` → stays `.signedOut`, `lastError == nil` |
| | `testHandleTokenLoad` | `(true, nil)` | `handleTokenLoad(succeeded: true)` → `.signedIn(nil)`; `handleTokenLoad(succeeded: false)` → `.needsReauth(nil)`; on `.signedOut` store → unchanged |
| | `testResumeWithoutFlowIsFalse` | any | `resume(url: URL(string: "com.googleusercontent.apps.test:/oauth2redirect?code=x")!) == false` |
| | `testResumeWrongSchemeIsFalse` | `currentFlow` = a dummy `OIDExternalUserAgentSession` implementation that records calls | `resume(url: "https://example.com/") == false`; dummy not called; `currentFlow` still set |
| | `testResumeMatchingSchemeForwards` | same dummy, `resumeExternalUserAgentFlow` succeeds | `resume(url: config.redirectURL.appending(queryItems: [.init(name: "code", value: "x")])) == true`; dummy called once; `currentFlow == nil` |
| | `testSignInWithPlaceholderConfigFails` | store with `OAuthConfig(clientID: "REPLACE.apps.googleusercontent.com")` | `await XCTAssertThrowsError(try await signIn())` with `AuthError.flowFailed`; `lastError?.contains("GoogleClientID") == true`; `isSigningIn == false`; `state` unchanged |
| | `testSignOutOrderAndEffects` | `(true, "a@x")`; `adopt(makeAuthState())` beforehand; `RevokeStub` session; `settings.lastSignedInEmail = "a@x"`; hooks log | after `signOut()`: `state == .signedOut`, `cachedEmail == nil`, `lastError == nil`, `Keychain.exists == false`, `HookLog.calls == ["prepareSignOut", "wipeAccountData"]`, `RevokeStub` saw 1 POST, `settings.settings.lastSignedInEmail == "a@x"` (kept) |
| | `testSignOutIsIdempotent` | `(false, nil)` | `signOut()` → no hook calls, no revoke request, `state == .signedOut` |
| | `testHandleAccountMismatch` | `(true, "a@x")` + adopted state | after `handleAccountMismatch(expected: "a@x", got: "b@x")`: `state == .signedOut`; `lastAuthError == .accountMismatch(expected: "a@x", got: "b@x")`; `lastError` contains `"a@x"` and `"b@x"`; `HookLog.calls == ["prepareSignOut", "wipeAccountData"]`; `Keychain.exists == false` |
| | `testClassifyFlowErrorTable` | `nil`; (`OIDGeneralErrorDomain`, `userCanceledAuthorizationFlow`); (`OIDGeneralErrorDomain`, `programCanceledAuthorizationFlow`); (`OIDOAuthAuthorizationErrorDomain`, code -1, response `["error": "admin_policy_enforced", "error_description": "blocked"]`); (`"X"`, 3, no userInfo) | `.flowFailed`; `.userCancelled`; `.userCancelled`; `.flowFailed(t)` with `t.contains("admin_policy_enforced")` and `t.contains("blocked")` and `isAdminPolicyEnforced == true`; `.flowFailed(t)` with `t.hasPrefix("X#3: ")` |
| | `testShouldRetryWithoutOptionalParameters` | `.flowFailed("… admin_policy_enforced")`, `.flowFailed("access_denied")`, `.flowFailed("invalid_client")`, `.flowFailed("redirect_uri_mismatch")`, `.flowFailed("invalid_request: hd")`, `.userCancelled`, `.missingRefreshToken` | `false, false, false, false, true, false, false` |
| | `testAuthErrorDescriptions` | every case | equals the §5.6 strings (`accountMismatch("a","b")` contains both; `keychain(-25300)` == `"Keychain error -25300."`) |
| | `testSignInMessageSelection` | placeholder config + admin error; real config + admin error; real config + `.flowFailed("x")`; real config + `.userCancelled` with `lastError == nil`; real config + nil | `.configMissing`; `.adminPolicy(clientID: "123.apps.googleusercontent.com")` and `text!.contains("Trust internal, domain-owned apps")` and `text!.hasSuffix("123.apps.googleusercontent.com")`; `.error("Sign-in failed: x")`; `.none`; `.none` |
| | `testNeedsReauthRelay` | relay with `auth` = `(true, "a@x")` store; call `fire()` from `DispatchQueue.global()`; wait ≤ 1 s | `state == .needsReauth(email: "a@x")`; relay with `auth == nil` → `fire()` does not crash |
| | `testProviderSignalsStore` | store `(true, "a@x")` whose provider was built with `onNeedsReauth: { relay.fire() }`; adopt `expiresIn: 30`; stub 400 invalid_grant | `accessToken()` throws; within 1 s `state == .needsReauth(email: "a@x")` |
| `minimailTests/App/AppEnvironmentTests.swift` (additions) | `testAuthRoutingInTestingMode` | delete `OAuthConfig.testingKeychainAccount`; `AppEnvironment(testing: true)` | `env.tokens.keychainAccount == "oauth.authState.testing"`; `env.auth.state == .signedOut`; `env.oauthConfig.clientID == Bundle.main GoogleClientID` |
| | `testTestingModeWithKeychainItemRoutesSignedIn` | `Keychain.set(junk, account: testing)`; `AppEnvironment(testing: true)` | `env.auth.state == .signedIn(email: nil)`; `await env.startDeferredWork()` → `load()` deleted the corrupt item → `env.auth.state == .needsReauth(email: nil)`; `Keychain.exists(testing) == false` |
| | `testDeferredWorkLoadsTokens` | fresh testing account | after `startDeferredWork()`: `await env.tokens.isLoaded == false`; `env.auth.state == .signedOut`; `deferredWorkStarted == true` |
| | `testHooksWiredToSettings` | `env.settings.update { $0.lastSignedInEmail = "h@x" }` | `env.auth.hooks.loginHint() == "h@x"`; `env.auth.hooks.rememberEmail("n@x")` → `env.settings.settings.lastSignedInEmail == "n@x"`; `env.auth.hooks.fetchProfileEmail == nil` |
| | `testRootViewHostsSignedOut` | `UIHostingController(rootView: RootView().environment(env).environment(env.theme).environment(env.settings))`, 390×844, `layoutIfNeeded()` | no crash; `env.auth.state == .signedOut`; the hierarchy contains a `UIButton`/control whose accessibility identifier is `signin.button` (walk `view` recursively over `subviews`, match `accessibilityIdentifier`) — if SwiftUI does not expose the identifier through UIKit accessibility on this SDK, the assertion degrades to "hierarchy non-empty" (§10 A7) |
| | `testRootViewHostsSignedInPlaceholder` | `Keychain.set(junk, testing)` then `AppEnvironment(testing: true)`; host as above | no crash; `env.auth.state == .signedIn(email: nil)` |

Total: 9 + 9 + 15 + 17 + 6 = 56 new tests; the 42 tests of module 01 must keep passing (01's `testRootViewHosts` now hosts `SignInScreen`).

---

## 8. Tasks

Ordered; each is one sitting. "Verify" commands run on the macOS runner (app code) unless marked (any).

- [ ] **T04.1 Keychain** — files: `minimail/Auth/Keychain.swift`, `minimail/Auth/AuthStore.swift` (only the `AuthError` enum + `LocalizedError` extension at this point, so `Keychain` can throw it), `minimailTests/Auth/KeychainTests.swift`. Done when the 9 Keychain tests pass and `exists` never touches `kSecReturnData`. Verify: `make test-one T=minimailTests/KeychainTests`.
- [ ] **T04.2 OAuthConfig** — files: `minimail/Auth/OAuthConfig.swift`, `minimailTests/Auth/OAuthConfigTests.swift`. Done when the 9 config tests pass, including `testSchemeMatchesBundleURLScheme` with the placeholder xcconfig values (`REPLACE` ↔ `com.googleusercontent.apps.REPLACE`). Verify: `make test-one T=minimailTests/OAuthConfigTests`.
- [ ] **T04.3 TokenProvider + AppAuthTokenProvider** — files: `minimail/Auth/TokenProvider.swift`, `minimail/Auth/AppAuthTokenProvider.swift`. Done when `make build` succeeds under Swift 6 / MainActor default with `@preconcurrency import AppAuth` and the AppAuth constant names of §4.4 resolved (run the `grep … OIDError.h` command of §4.4 first and fix spellings). Verify: `make build` and `grep -c "@preconcurrency import AppAuth" minimail/Auth/AppAuthTokenProvider.swift` prints `1`.
- [ ] **T04.4 AppAuthTokenProvider tests** — files: `minimailTests/Auth/AppAuthTokenProviderTests.swift` (incl. `makeAuthState`, `TokenEndpointStub`). Done when the 15 provider tests pass; if `OIDURLSessionProvider.setSession` does not intercept (§10 A4), switch to `URLProtocol.registerClass(TokenEndpointStub.self)` and record the outcome in §10. Verify: `make test-one T=minimailTests/AppAuthTokenProviderTests`.
- [ ] **T04.5 AuthStore, Hooks, NeedsReauthRelay** — files: `minimail/Auth/AuthStore.swift` (complete). Done when `make build` succeeds and `signIn()` / `signOut()` / `resume(url:)` / `markNeedsReauth()` / `handleTokenLoad` / `handleAccountMismatch` / `classifyFlowError` / `shouldRetryWithoutOptionalParameters` exist with the §3.4 signatures. Verify: `make build`; `grep -nE "func (signIn|signOut|resume|markNeedsReauth|handleTokenLoad|handleAccountMismatch|classifyFlowError|shouldRetryWithoutOptionalParameters)\(" minimail/Auth/AuthStore.swift | wc -l` prints `8`.
- [ ] **T04.6 App wiring + screens** — files: `minimail/Features/SignIn/SignInScreen.swift`, `minimail/App/AppEnvironment.swift`, `minimail/App/RootView.swift`, `minimail/App/MinimailApp.swift`. Done when the app builds, launches in the simulator to `SignInScreen` (placeholder client id → disabled button + config message), and 01's 42 tests still pass. Verify: `make build && make test-app`; `grep -c "onOpenURL" minimail/App/MinimailApp.swift` prints `1`; `grep -rE "import (AppAuth|Security)" minimail/App` prints nothing.
- [ ] **T04.7 AuthStore + AppEnvironment tests** — files: `minimailTests/Auth/AuthStoreTests.swift`, `minimailTests/App/AppEnvironmentTests.swift` (6 added functions). Done when all 56 new tests and 01's 42 pass: `failedTests: 0`. Verify: `make test-app && xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact`.
- [ ] **T04.8 Lint + device check** — files: none new (formatting only). Done when `make format` yields no diff on a second run, `make lint` exits 0, and the manual device steps of §9 items 9–11 pass with a real `GOOGLE_CLIENT_ID` (owner-provided, never committed). Verify: `make format && git diff --stat && make lint`; device steps as listed.

---

## 9. Acceptance criteria

1. `make build` compiles the app with the five `Auth/` files, the sign-in screen and the three modified `App/` files under `SWIFT_VERSION=6`, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`; AppAuth is imported only via `@preconcurrency import AppAuth` and only under `minimail/Auth` and `minimailTests/Auth`. Verify: `make build`; `grep -rlE "^(@preconcurrency )?import AppAuth" minimail minimailTests | grep -vE "^minimail/Auth/|^minimailTests/Auth/" | wc -l` prints `0`.
2. `make test-app` passes every test of §7.2 plus module 01's tests (`failedTests: 0`, 98 tests). Verify: the T04.7 command.
3. `AppEnvironment.init` performs exactly one Keychain call (`Keychain.exists`) and no AppAuth, network or unarchive call. Verify: `grep -n "Keychain\." minimail/App/AppEnvironment.swift` prints one line containing `Keychain.exists`; `grep -nE "NSKeyedUnarchiver|OIDAuthState|URLSession" minimail/App/AppEnvironment.swift` prints nothing. (Supersedes 01's acceptance criterion 7 for the Keychain clause; the import grep of criterion 7 still holds.)
4. The routing truth table holds on the simulator: (a) fresh install → `SignInScreen`; (b) after a Keychain item is written for the testing account (via `testTestingModeWithKeychainItemRoutesSignedIn`) → `.signedIn(nil)` then `.needsReauth(nil)` after `load()` fails. Verify: `make test-one T=minimailTests/AppEnvironmentTests`.
5. A refresh with `invalid_grant` produces exactly one token request, `AuthError.needsReauth` for every caller, one `onNeedsReauth` signal, and `AuthStore.state == .needsReauth(email)`; a later `adopt` clears the latch. Verify: `make test-one T=minimailTests/AppAuthTokenProviderTests/testInvalidGrantLatchesAndSignals` and `…/AuthStoreTests/testProviderSignalsStore`.
6. Five concurrent `accessToken()` calls on an expired state produce one token request. Verify: `make test-one T=minimailTests/AppAuthTokenProviderTests/testSingleFlightRefresh`.
7. Sign-out deletes the Keychain item, POSTs `token=<refresh>` to `/revoke` once, calls `prepareSignOut` before `wipeAccountData`, keeps `Settings.lastSignedInEmail`, ends in `.signedOut`. Verify: `make test-one T=minimailTests/AuthStoreTests/testSignOutOrderAndEffects`.
8. `make lint` exits 0 (no raw colours under `minimail/Features/SignIn`; swift-format strict). Verify: `make lint`.
9. Manual device step (real OAuth client, owner's phone, `Config/Google.xcconfig` filled locally): tap "Sign in with Google" → Google sheet with the account chooser (shared session) → consent → the app shows `SignedInPlaceholderView` with "Signed in as <owner e-mail>" only after module 05 wires `fetchProfileEmail`; before that, "Loading your inbox…". Kill and relaunch → still signed in without a sheet (Keychain + `load()`); `log stream --predicate 'subsystem == "com.minimail" AND category == "auth"'` shows `routing: keychain=true`, `load: authorized=true`.
10. Manual device step: Settings → Google account → third-party access → remove minimail (or change the Google password, `[gmail-api gotcha 18]`); reopen the app; after the first API call fails with `invalid_grant` the state flips to `.needsReauth` (placeholder shows "Sign in again"); tapping it and choosing the same account resumes without a wipe (`Keychain.exists` true again; DB untouched — verified by 07/09 once they exist, here by the absence of `wiping` in the log).
11. Manual device step: with the Workspace admin setting "Trust internal, domain-owned apps" OFF and the client not marked Trusted, sign-in shows the `adminPolicy` remedy text containing the client id `[gmail-api gotcha 2]`; after the admin marks it Trusted, sign-in succeeds without reinstalling.
12. Manual device step: tap "Sign out" on the placeholder → back to `SignInScreen` within 4 s (3 s revoke timeout worst case) even in airplane mode; a subsequent sign-in shows the previous address pre-selected (`login_hint`).

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | `AppAuthTokenProvider.init` gains `revocationEndpoint:`, `session:`, `onNeedsReauth:` parameters (architecture: `init(keychainAccount:)` + `nonisolated let onNeedsReauth`). | DEVIATION (additive, defaulted) | A `nonisolated let` needs an init argument; the session/endpoint parameters make the revoke POST stub-able. `AppAuthTokenProvider()` still compiles. |
| D2 | `AuthStore` gains `hooks: Hooks`, `isSigningIn`, `lastAuthError`, `cachedEmail`, `config`, `tokens`, `handleTokenLoad`, `handleAccountMismatch`, the two pure classifiers; `NeedsReauthRelay` added. | DEVIATION (additive) | modules.md requires `getProfile` and the DB wipe to be injected closures; the verbatim `init` has no closure parameters, so they are a settable struct. The relay breaks the provider ↔ store construction cycle without an unsafe global. |
| D3 | Architecture §5.3 says transport errors during refresh map to `GmailError.offline/.network`. | DEVIATION | `GmailError` lives in module 05, which depends on 04; the provider rethrows `URLError` (unwrapped from AppAuth's `OIDErrorCodeNetworkError`) and 05 applies `GmailError.map(_ urlError:)` — same outcome, correct dependency direction. 05's spec must catch `URLError` around `tokens.accessToken()`. |
| D4 | `AuthError` is declared `nonisolated`; `Keychain` is `nonisolated`; `StateDelegate` is `nonisolated`. | additive | Needed so the actor and ObjC callbacks can use them without a main-actor hop (SE-0449 spelling assumed available in Xcode 26.6 — same assumption as `[01 §10 A7]`; fallback: annotate members individually). |
| D5 | `OAuthConfig` gains `hostedDomain`, `infoPlistKey`, `keychainAccount`, `testingKeychainAccount`, `init(clientID:)`, `fromInfoPlist(bundle:)`, `isPlaceholder`, `serviceConfiguration`. | additive | The verbatim members are unchanged; the testing account keeps a developer's real item out of the test host. |
| D6 | `SignedInPlaceholderView` inside `RootView.swift`. | additive, temporary | Lets sign-in / reauth / sign-out be exercised on a device before 09; 09 deletes it together with `RootPlaceholderView`. |
| D7 | `AuthStore.lastError` stays `nil` on `userCancelled` although the error is thrown. | interpretation | Architecture §8.2 wants "error text under the button"; a cancelled sheet is not an error the user needs explained. `lastAuthError` still records it. |
| D8 | Profile fetch failure after `adopt` → `revokeAndClear()` + `flowFailed`. | interpretation | Architecture §5.1 has `profile = try await gmail.getProfile()` inside the throwing flow; revoking keeps "no half state" (a persisted token with `.signedOut` would route to `.signedIn(nil)` on the next launch). |
| D9 | Badge reset (`setBadgeCount(0)`) is done by `AuthStore.signOut()` directly with `UserNotifications`. | interpretation | Architecture §5.4 lists it in the sign-out sequence; `UNUserNotificationCenter` is only forbidden in `AppEnvironment.init`. |
| A1 | Swift spellings of AppAuth error constants (`OIDErrorCodeOAuth.invalidGrant`, `OIDErrorCode.networkError`, `OIDErrorCode.tokenRefreshError`, `OIDErrorCode.userCanceledAuthorizationFlow`, `OIDErrorCode.programCanceledAuthorizationFlow`, `OIDOAuthErrorResponseErrorKey`, `OIDOAuthErrorFieldError`, `OIDOAuthErrorFieldErrorDescription`, `OIDOAuthTokenErrorDomain`, `OIDOAuthAuthorizationErrorDomain`, `OIDGeneralErrorDomain`). | UNVERIFIED (names from `OIDError.h`, `[ios-platform §1.2]` lists only some) | Fixed on first build with the `grep … OIDError.h` command of §4.4; numeric fallbacks: `userCanceled = -3`, `programCanceled = -4`, `networkError = -5`, `tokenRefreshError = -11`, `OAuthInvalidGrant = -10`. |
| A2 | `resumeExternalUserAgentFlow(_:)` imports as `throws` (ObjC `BOOL … error:`). | UNVERIFIED (`[ios-platform §1.1]` gives the name only) | §4.12 gives both variants. |
| A3 | `hd` and `prompt=consent` accepted by the native flow; a refresh token is always issued to iOS clients. | UNVERIFIED (architecture §14 #15, #16; `[gmail-api "OAuth 2.0 for iOS"]`) | One retry without `hd`, one retry with `prompt=consent`, then `missingRefreshToken`; sign-in never blocks on them. |
| A4 | `OIDURLSessionProvider.setSession(_:)` routes AppAuth's token requests through a session whose `protocolClasses` contains the stub. | UNVERIFIED (class exists in `AppAuthCore`; behaviour with custom protocol classes untested) | Fallback `URLProtocol.registerClass(TokenEndpointStub.self)` (affects `URLSession.shared`, AppAuth's default). |
| A5 | Archiving `OIDAuthState` on the actor while AppAuth may mutate it on its own queue. | UNVERIFIED (AppAuth is not annotated for concurrency) | The delegate hops to the actor; the worst case is a stale archive corrected by the next `didChange`. |
| A6 | `@preconcurrency import AppAuth` is enough for `OIDAuthState` to cross the continuation and the `sending` parameter without errors (warnings allowed). | UNVERIFIED (architecture §14 #2, `[ios-platform §8 item 5]`) | Fallback: `private struct UncheckedBox<T>: @unchecked Sendable { let value: T }` around the state in `presentFlow` and an `adopt(boxed:)` overload; escape hatch order of architecture §14 #2 after that. |
| A7 | SwiftUI `.accessibilityIdentifier` is visible to UIKit's `accessibilityIdentifier` on hosted views. | assumed | `testRootViewHostsSignedOut` degrades to a non-empty-hierarchy check if not. |
| A8 | `OIDAuthorizationResponse(request:parameters:)`, `OIDTokenRequest(configuration:grantType:…)`, `OIDTokenResponse(request:parameters:)` and `OIDAuthState(authorizationResponse:tokenResponse:)` are public initialisers usable from tests. | assumed (all are public in the AppAuthCore headers) | If `OIDTokenRequest`'s long initialiser differs, use the shorter `init(configuration:grantType:authorizationCode:redirectURL:clientID:clientSecret:scope:refreshToken:codeVerifier:additionalParameters:)` variant that compiles; the test only needs a token response with `access_token`, `expires_in`, `refresh_token`. |
| A9 | AppAuth's expiry tolerance is 60 s (`kExpiryTimeTolerance`), so `expires_in: 30` triggers a refresh and `3600` does not. | assumed (`[ios-platform §1.6]` says "refreshes if expired") | If a 30 s token is not refreshed, use `expiresIn: -10` in the expired fixtures. |
| A10 | Keychain works in the simulator without entitlements; `errSecInteractionNotAllowed` never occurs in tests. | verified `[ios-platform §5.5]` | — |
| A11 | Google returns `error=admin_policy_enforced` on the redirect (authorization error), so it surfaces via `classifyFlowError`, not via the token endpoint. | UNVERIFIED (`[gmail-api "OAuth scopes and Workspace policy"]` quotes "Error 400: admin_policy_enforced" from a snippet) | `isAdminPolicyEnforced` is a substring check on `flowFailed`, so either path (authorization or token error text) triggers the remedy. |
| A12 | `UNUserNotificationCenter.setBadgeCount(_:)` throws when notifications are unauthorised. | assumed | Wrapped in `try?`; nothing depends on it. |
