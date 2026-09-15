# 13-settings-theme-signature — Settings screen, theme picker, signature editor, compose style, badge, Advanced

Module id: `13-settings-theme-signature` (Appendix A). Depends on: **01-project-setup** (`Settings`, `SettingsStore`, `ThemeStore`, `ThemeChoice`, `Theme`, `ThemeTokens`, `ThemeTokensReader`, `SystemPalette`, `AppEnvironment`, `Log`, `Formatters`, `ComposeStyle`, `ThemeCSSTokens`), **06-storage** (`SyncStateRepository`, `SyncKey`, `Queries.outboxCounts`, `AppDatabase`, `TestDatabase`, `InvariantChecks`), **07-sync-outbox** (`SyncStatus`, `SyncEngine.requestFullResync/updateBadge`), **08-html-rendering** (`SignatureSanitizer`, `WebViewHost.makeThrowawayWebView`, `ThreadDocument.css`), and transitively **04-auth** (`AuthStore.signOut`, `AuthStore.State.email`), **05-gmail-client** (`RequestLog.snapshot`), **09-inbox-list** (the `SettingsScreen()` call site and the placeholder it replaces).

Sources of truth, in order: `architecture.md` §11 (settings model + the Form section list), §10 (theming), §7.5 (default font/colour + signature rules), §8.1/§8.2 (navigation graph and the two screen contracts), §4.6 (badge), §4.9/§12.2 (what this screen may trigger), §5.4 (sign-out), §6.5 (request log), §9.1/§9.2 (the CSS the preview reuses), §14 #11 (badge authorization UNVERIFIED), §15 D9/D12/D14/D26, §16 (non-goals); `modules.md` §13; research `[ios-platform §5.1, §5.2, §5.6, §6, §7]`, `[html-rendering §5.1–§5.4, §7]`, `[mime-rfc §3.4]`, `[gmail-api §15]`.

Conventions (same as 09/10/11): the app target builds with `SWIFT_VERSION = 6` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` `[ios-platform §5.6]`, so every declaration below is `@MainActor` **implicitly** unless it carries an explicit `nonisolated`. App declarations are `internal` (never `public`). Types that cross into GRDB `@Sendable` fetch closures or into actors are `nonisolated` + `Sendable` value types. Signatures marked `// verbatim` are copied from `architecture.md` / `modules.md` / spec 09 unchanged; every other addition is listed in §10.

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. **`SettingsScreen`** — the sheet presented from the inbox toolbar (`gearshape`, 09 §6): a `NavigationStack` around a `Form` with the six sections of architecture §11 — Account (email, name, Sign Out), Appearance (Theme: System / Light / Dark bound to `ThemeStore.choice`), Compose (font family, size, text colour through a `ColorPicker`, Signature link, Use-signature toggle), Reading (load remote images, mark read on open), Notifications (badge toggle that requests `[.badge]` in context and turns itself off when denied), Advanced (sync status line, "Full resync now", DEBUG "Recent requests", version).
2. **`SignatureEditorScreen`** — pushed from the Compose section: a monospaced `TextEditor` over the raw HTML, a live preview in a **throwaway** `WKWebView` (`WebViewHost.makeThrowawayWebView()`, D12/D26), `SignatureSanitizer.sanitize` on save, the `data:`-image warning of `[mime-rfc §3.4]`, and "Import from Gmail" reading `syncState.sendAsSignature` `[gmail-api §15]`.
3. **`RequestLogScreen`** (DEBUG only) — the last 100 entries of `RequestLog.snapshot()`, newest first.
4. Two observable models with no view dependencies so every rule is unit-testable: `SettingsModel` (advanced info load, badge authorization, sign-out, full resync, status strings) and `SignatureEditorModel` (preview pipeline, warning, import, save).
5. Pure helpers: `HexColor` (`Color` ⇄ `#rrggbb` for the `ColorPicker`), `SignaturePreviewDocument` (the preview HTML), `SignatureSummary` (the one-line value shown next to "Signature"), `ThemeChoice.displayName`, `SettingsStore.binding(_:)`.
6. Deletion of the interim `struct SettingsScreen` from `minimail/Features/Inbox/InboxPlaceholders.swift` (09 §2) and, once it is empty, of the file itself.
7. Tests: `SettingsModelTests`, `SignatureEditorModelTests`, `SettingsViewsTests` (all app tests, `xcodebuild test`), plus the one-line update of 09's `testPlaceholderSignatures`.

### 1.2 Explicitly out of scope

- **Definitions** of `Settings`, `SettingsStore`, `ThemeStore`, `Theme`, `ThemeTokens`, `ThemeChoice`, `SystemPalette`, `ThemeTokensReader`, `ComposeStyle` — all created by module 01 (`modules.md` §13: "Must NOT contain"). This module only reads and mutates them through `SettingsStore.update` and `ThemeStore.choice`.
- The pooled `WKWebView`, its configuration, rule lists, `CIDSchemeHandler`, `InlineImageStore`, `LinkPolicy`, `MailWebView` — module 08. This module calls exactly one factory method (`makeThrowawayWebView()`) and one pure helper (`ThreadDocument.css`).
- The sanitizer allowlist and `SignatureSanitizer`'s implementation — module 08.
- Sign-out mechanics (token revoke, Keychain delete, DB destroy, cache purge, badge 0) — `AuthStore.signOut()` + its hooks (04/06/07/08). This module calls it and dismisses.
- Full-resync mechanics (`historyId := nil`, generation bump, relisting) — `SyncEngine.requestFullResync()` (07). This module calls it behind a confirmation.
- Badge *computation* and the `setBadgeCount` call after every sync — `SyncEngine.updateBadge()` (07 §3.5, architecture §4.6). This module owns only the authorization request, the persisted `Settings.showBadge` flag, and clearing the badge to `0` when the toggle is switched off.
- `Settings.inboxPageSize` and `Settings.lastSignedInEmail` — no control is exposed (architecture §11 lists neither in the screen); see §10 A1.
- Any SQL string, any network call, any `GmailClient` method other than the DEBUG read of `RequestLog.snapshot()`, any migration, any `project.yml`/`Info.plist`/entitlement change.
- Per-scheme theme ids, JSON themes, a Diagnostics screen with copy/export, a haptics toggle, configurable swipe actions — non-goals (architecture §16, D9).

### 1.3 Consumers and the exact symbols they take

| Consumer | Symbols used |
|---|---|
| 09 `InboxScreen` | `SettingsScreen()` (presented for `ActiveSheet.settings`, 09 §4.8) |
| 14 QA | `SettingsModelTests` / `SignatureEditorModelTests` / `SettingsViewsTests` conventions; the device-checklist items of §9 (theme switch, badge prompt, signature round trip, full resync) |
| everything else | nothing — no other module imports a type defined here |

What this module reads from others (complete list, no other symbol is touched):

| From | Symbols |
|---|---|
| 01 | `Settings` (all fields), `SettingsStore.{settings,update,snapshot}`, `ThemeStore.{choice,resolved(for:),preferredColorScheme,forcedDocumentTheme,interfaceStyle}`, `ThemeChoice.allCases`, `Theme.cssTokens(for:)`, `ThemeTokensReader`, `ThemeTokens.{text,secondaryText,surface,groupedBackground,accent,separator}`, `AppEnvironment.{settings,theme,db,auth,sync,syncStatus,requestLog,webHost,isTesting}`, `Log.ui`, `ComposeStyle.{Family,sizeChoices,sizeRange,isValidHex,inlineCSS}`, `ThemeCSSTokens` |
| 04 | `AuthStore.signOut()`, `AuthStore.State.email` |
| 05 | `RequestLog.snapshot()` (DEBUG) |
| 06 | `SyncStateRepository.{all,get}`, `SyncKey.{accountEmail,displayName,historyId,lastFullSyncAt,lastDeltaSyncAt,sendAsSignature}`, `Queries.outboxCounts` |
| 07 | `SyncStatus.{phase,isOffline,lastError,lastSyncAt,pendingOps,failedSends}`, `SyncEngine.requestFullResync()`, `SyncEngine.updateBadge()` |
| 08 | `SignatureSanitizer.sanitize(_:)`, `SignatureSanitizer.hasDataImages(_:)`, `SanitizerError`, `WebViewHost.makeThrowawayWebView()`, `ThreadDocument.css(light:dark:)` |
| 02 (MailCore) | `Quoting.textFromHTML(_:)` (signature summary line) |

---

## 2. Files

| Path (relative to repo root) | Kind | Purpose |
|---|---|---|
| `minimail/Features/Settings/SettingsScreen.swift` | new | `SettingsScreen` (NavigationStack + Form + toolbar + confirmation dialogs), private section views `SettingsAccountSection`, `SettingsAppearanceSection`, `SettingsComposeSection`, `SettingsReadingSection`, `SettingsNotificationsSection`, `SettingsAdvancedSection`, `RequestLogScreen` (DEBUG), `extension SettingsStore { binding(_:) }`, `extension ThemeChoice { displayName }` |
| `minimail/Features/Settings/SettingsModel.swift` | new | `SettingsAdvancedInfo`, `BadgeAuthorizing`, `SystemBadgeAuthorizer`, `SettingsModel`, `HexColor`, `SettingsStrings` (D1) |
| `minimail/Features/Settings/SignatureEditorScreen.swift` | new | `SignatureEditorScreen`, private `SignaturePreviewView` (`UIViewRepresentable` over a throwaway `WKWebView`) |
| `minimail/Features/Settings/SignatureEditorModel.swift` | new | `SignatureEditorModel`, `SignatureImportState`, `SignaturePreviewDocument`, `SignatureSummary` (D1) |
| `minimail/Features/Inbox/InboxPlaceholders.swift` | delete | 09 §2: "13 deletes the file". Deleting `struct SettingsScreen` leaves it empty because 10/11/12 already removed `ThreadScreen`, `ComposeScreen` and `LabelsScreen`. If any of those is still present (out-of-order execution), delete only `struct SettingsScreen` and keep the file. |
| `minimailTests/Settings/SettingsModelTests.swift` | new | advanced load, badge authorization matrix, status/version strings, full resync, sign-out (§7.1) |
| `minimailTests/Settings/SignatureEditorModelTests.swift` | new | preview pipeline, warning, error, size guard, import, save, dirty rules (§7.2) |
| `minimailTests/Settings/SettingsViewsTests.swift` | new | `HexColor`, `SignaturePreviewDocument`, `SignatureSummary`, `ThemeChoice.displayName`, `SettingsStore.binding`, hosting smoke tests, placeholder removal (§7.3) |
| `minimailTests/Inbox/InboxViewsTests.swift` | modify | one line of `testPlaceholderSignatures`: host `SettingsScreen()` with the three environment values injected (§7.4) |

No `Packages/MailCore` file is added or edited: this module ships no pure package algorithm (`SignatureSanitizer` is 08's, `ComposeStyle` is 01's). No `project.yml` change (the app target globs `minimail/`, the test target globs `minimailTests/` — 01 §5.1). No `Info.plist` key: `UNUserNotificationCenter.requestAuthorization(options: [.badge])` needs none (`UIBackgroundModes` already contains only `fetch`, 01 §5.1) `[ios-platform §6, §7]`. No new asset, no new `UserDefaults` key (the module writes into 01's `com.minimail.settings` blob), no migration.

`make lint` constraints for the four new source files:

| File | Allowed imports |
|---|---|
| `SettingsScreen.swift` | `SwiftUI`, `UIKit`, `MailCore` |
| `SettingsModel.swift` | `Foundation`, `GRDB`, `MailCore`, `Observation`, `SwiftUI`, `UIKit`, `UserNotifications`, `os` |
| `SignatureEditorScreen.swift` | `SwiftUI`, `UIKit`, `WebKit`, `MailCore` |
| `SignatureEditorModel.swift` | `Foundation`, `GRDB`, `MailCore`, `MailHTML`, `Observation`, `os` |

Never `AppAuth`, never `SwiftSoup` (only `MailHTML`'s facade), never a raw colour literal (every colour through `ThemeTokensReader` or `HexColor`), never `SELECT`/`INSERT`/`UPDATE`/`DELETE FROM` in any string.

---

## 3. Public interface

### 3.1 `minimail/Features/Settings/SettingsModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import Observation
import SwiftUI
import UIKit
import UserNotifications
import os

/// One `db.read` snapshot for the Advanced section (architecture §11 "Sync status line"). Value type so the read closure is `@Sendable`.
nonisolated struct SettingsAdvancedInfo: Sendable, Equatable {
    var accountEmail: String?          // syncState.accountEmail
    var displayName: String?           // syncState.displayName
    var historyId: String?             // syncState.historyId, decimal string, verbatim
    var lastFullSyncAtMs: Int64?       // syncState.lastFullSyncAt
    var lastDeltaSyncAtMs: Int64?      // syncState.lastDeltaSyncAt
    var hasGmailSignature: Bool        // syncState.sendAsSignature present and non-empty
    var pendingOps: Int                // Queries.outboxCounts().pending
    var failedSends: Int               // Queries.outboxCounts().failed
    /// All fields nil / false / 0 — the value used before the first load and when the read throws.
    static let empty: SettingsAdvancedInfo
    init(accountEmail: String? = nil, displayName: String? = nil, historyId: String? = nil,
         lastFullSyncAtMs: Int64? = nil, lastDeltaSyncAtMs: Int64? = nil,
         hasGmailSignature: Bool = false, pendingOps: Int = 0, failedSends: Int = 0)
}

/// Everything this module needs from `UNUserNotificationCenter`, behind a protocol so the badge rules are testable
/// without a system prompt (`[ios-platform §6]`, architecture §14 #11). ADDITION (D2).
protocol BadgeAuthorizing: Sendable {
    /// `requestAuthorization(options: [.badge])`. Returns `false` on `throw` and on denial. The system prompt appears
    /// at most once per install; a previously denied app gets `false` without a prompt.
    func requestBadgeAuthorization() async -> Bool
    /// `notificationSettings().badgeSetting == .enabled` — detects an authorization revoked in iOS Settings after the fact.
    func isBadgeEnabled() async -> Bool
    /// `try? setBadgeCount(count)`; never throws out.
    func setBadgeCount(_ count: Int) async
}

/// Production implementation. `[.badge]` only — never `.alert`, `.sound` or `.provisional` (architecture §14 #11, 07 §10 A15).
nonisolated struct SystemBadgeAuthorizer: BadgeAuthorizing {
    init()
    func requestBadgeAuthorization() async -> Bool
    func isBadgeEnabled() async -> Bool
    func setBadgeCount(_ count: Int) async
}

/// State and side effects of `SettingsScreen` that are not a plain `Settings` field (architecture §8.2 lists the screen's own state
/// as "`@Bindable SettingsStore`, sync status line"; this model owns the rest). ADDITION (D1): a separate observable object so the
/// badge matrix, the advanced read and the strings are unit-testable without hosting a view.
@Observable final class SettingsModel {
    enum BadgeState: Equatable { case idle, requesting, denied }

    private(set) var info: SettingsAdvancedInfo
    /// `.requesting` disables the toggle; `.denied` renders the help footer + "Open Settings" button.
    private(set) var badgeState: BadgeState
    private(set) var isSigningOut: Bool
    private(set) var isResyncing: Bool
    /// Bound to the two `confirmationDialog`s of §6.
    var showsSignOutConfirmation: Bool
    var showsResyncConfirmation: Bool

    /// Keeps a strong reference to `env` (it outlives the sheet). `badge` defaults to the system implementation.
    init(env: AppEnvironment, badge: any BadgeAuthorizing = SystemBadgeAuthorizer())

    /// One `db.read` → `info` (§4.2). Never throws: a failing read logs `Log.ui.error` and leaves `info` unchanged
    /// (`.empty` on the first call).
    func load() async
    /// The `Settings.showBadge` write path (§4.4). `on == true` requests `[.badge]` first and only persists on success.
    func setBadgeEnabled(_ on: Bool) async
    /// Called from `.task`: reconciles a persisted `showBadge == true` with an authorization revoked in iOS Settings (§4.4.3).
    func verifyBadgeAuthorization() async
    /// `await env.auth.signOut()` (architecture §5.4). Idempotent while `isSigningOut`.
    func signOut() async
    /// `await env.sync.requestFullResync()` then `load()` (§4.5). Idempotent while `isResyncing`.
    func fullResync() async

    // ---- derived strings (pure given the model's inputs; covered by tests) ----
    /// "Offline" · "Syncing…" · "First sync…" · `SyncStatus.lastError` · "Idle" (§4.6).
    var statusLine: String { get }
    /// `SyncStatus.lastSyncAt`, else `max(lastDeltaSyncAtMs, lastFullSyncAtMs)`, formatted
    /// `.formatted(date: .abbreviated, time: .shortened)`; "Never" when all three are nil.
    var lastSyncLine: String { get }
    /// "<CFBundleShortVersionString> (<CFBundleVersion>)", e.g. "0.1.0 (1)"; missing keys → "—".
    var versionLine: String { get }
    /// `info.accountEmail` ?? `env.auth.state.email` ?? "—".
    var accountEmailLine: String { get }
}

/// `Color` ⇄ `"#rrggbb"` for the compose `ColorPicker` (architecture §11 "ColorPicker bound through hex"). ADDITION (D3).
nonisolated enum HexColor {
    /// `"#rrggbb"` (lowercase, `ComposeStyle.isValidHex`) → `Color(.sRGB, red:green:blue:, opacity: 1)`.
    /// Any other input (wrong length, uppercase, missing "#", non-hex digit) → opaque black.
    static func color(_ hex: String) -> Color
    /// sRGB components of `color`, clamped to 0…1, rounded to the nearest byte, formatted `"#%02x%02x%02x"` (lowercase).
    /// Alpha is ignored. Dynamic colours are resolved for `.light` first. Unconvertible colours → `"#000000"`.
    static func hex(_ color: Color) -> String
    /// Same conversion from `UIColor` (used by `hex(_:)` and directly by tests).
    static func hex(_ color: UIColor) -> String
}

/// Every user-visible string of this module in one place (so tests assert against the same constant the view renders). ADDITION (D4).
nonisolated enum SettingsStrings {
    static let signOutTitle = "Sign Out"
    static let signOutConfirmTitle = "Sign out of minimail?"
    static let signOutConfirmDetail = "This deletes the local mail cache on this iPhone. Your mail stays in Gmail."
    static let accountFooter = "Signing out deletes the local mail cache on this iPhone. Your mail stays in Gmail."
    static let composeFooter = "Your default font, size and color are applied to the text you type. The quoted original keeps its own styling."
    static let readingFooter = "Remote images can tell the sender that you opened the message."
    static let badgeDeniedFooter = "Badges are turned off for minimail. Allow them in iOS Settings → Notifications → minimail."
    static let badgeOpenSettings = "Open Settings"
    static let resyncTitle = "Full Resync Now"
    static let resyncConfirmTitle = "Re-download the inbox?"
    static let resyncConfirmDetail = "minimail fetches the inbox list from Gmail again. Cached messages that are still in the inbox are kept."
    static let advancedFooter = "A full resync is only needed when the local cache and Gmail disagree."
    static let signatureNotSet = "Not set"
    static let previewFooter = "Remote images aren't loaded in this preview."
    static let dataImageWarning = "Gmail does not render data: images. Use a hosted https: image instead."
    static let signatureTooLarge = "The signature is too large. The limit is 64 KB."
    static let signatureCleanFailed = "This HTML couldn't be cleaned. Check for unbalanced tags."
    static let signatureUnknownError = "Couldn't process this HTML."
    static let importUnavailable = "No Gmail signature found for this account."
    static let importDone = "Imported from Gmail."
    static let importOverwriteTitle = "Replace the current signature?"
    static let importOverwriteDetail = "The text in the editor is replaced by the signature stored in Gmail."
}
```

### 3.2 `minimail/Features/Settings/SettingsScreen.swift`

```swift
import MailCore
import SwiftUI
import UIKit

/// The Settings sheet (architecture §8.1: "sheet SettingsScreen → push SignatureEditorScreen"; §11 for the section list).
/// Presented by 09 for `ActiveSheet.settings`; inherits `AppEnvironment`, `ThemeStore` and `SettingsStore` from the window.
struct SettingsScreen: View {          // verbatim (09 §3.5 placeholder signature)
    init()                             // verbatim
    var body: some View
}

/// DEBUG-only list of the last `RequestLog.capacity` requests (architecture §11 "DEBUG: Recent requests"; §6.5).
#if DEBUG
struct RequestLogScreen: View {
    init()
    var body: some View
}
#endif

extension SettingsStore {
    /// Two-way binding to one field of `Settings`, writing through `update` (which normalises and persists synchronously).
    /// Main actor; the getter participates in `@Observable` tracking. ADDITION (D5).
    func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value>
}

extension ThemeChoice {
    /// "System" / "Light" / "Dark" — the picker labels of architecture §11. ADDITION (D6).
    var displayName: String { get }
}

// Private to the file (listed so the implementer creates exactly these, and no more):
private struct SettingsAccountSection: View        { let model: SettingsModel }
private struct SettingsAppearanceSection: View     { }                      // reads ThemeStore from the environment
private struct SettingsComposeSection: View        { }                      // reads SettingsStore from the environment
private struct SettingsReadingSection: View        { }
private struct SettingsNotificationsSection: View  { let model: SettingsModel }
private struct SettingsAdvancedSection: View       { let model: SettingsModel }
```

### 3.3 `minimail/Features/Settings/SignatureEditorModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import MailHTML
import Observation
import os

/// Result of the last "Import from Gmail" tap (`[gmail-api §15]`).
nonisolated enum SignatureImportState: Equatable, Sendable {
    case idle
    case loading
    case unavailable        // syncState.sendAsSignature missing or blank → SettingsStrings.importUnavailable
    case imported           // → SettingsStrings.importDone
}

/// State machine of `SignatureEditorScreen` (architecture §8.2 row "SignatureEditorScreen"; §7.5 for the rules).
@Observable final class SignatureEditorModel {
    /// Editor hard cap. Larger input is neither previewed nor saved (`Sanitizer.maxInputBytes` is 2 MiB — far above
    /// anything an e-mail signature needs, and SwiftSoup on a 2 MiB string would stall the editor).
    nonisolated static let maxBytes = 65_536
    /// Debounce between the last keystroke and the preview rebuild, in milliseconds (§4.9).
    nonisolated static let previewDebounceMs = 400

    /// The raw HTML in the `TextEditor` (bindable).
    var html: String
    /// The document handed to the preview web view; `SignaturePreviewDocument.render` output. Never empty.
    private(set) var previewDocument: String
    /// The last successful `SignatureSanitizer.sanitize(html)` result; `nil` until the first successful pass.
    private(set) var sanitized: String?
    /// `SettingsStrings.dataImageWarning` when the sanitized HTML contains a `data:` `<img>`; else nil (`[mime-rfc §3.4]`).
    private(set) var warning: String?
    /// Sanitizer / size error text; blocks Save while non-nil.
    private(set) var error: String?
    private(set) var importState: SignatureImportState
    private(set) var isSaving: Bool
    /// Bound to the import confirmation dialog (§6.12).
    var showsImportConfirmation: Bool

    /// - env: for `SettingsStore` and the `syncState` read.
    /// - light/dark/forcedScheme: the CSS tokens and `html[data-theme]` value captured once from `ThemeStore` (architecture §10).
    init(env: AppEnvironment, light: ThemeCSSTokens, dark: ThemeCSSTokens, forcedScheme: String?)

    /// Copies `Settings.signatureHTML` into `html`, resets the derived state and renders the empty preview. Idempotent;
    /// called once from `.onAppear`.
    func load()
    /// Sanitises `html` off the main actor and refreshes `sanitized`, `warning`, `error`, `previewDocument` (§4.9).
    /// Cancellation-safe: if the surrounding `Task` was cancelled while sanitising, nothing is assigned.
    func refreshPreview() async
    /// Reads `syncState.sendAsSignature` and replaces `html` with it (§4.11). Sets `importState`.
    func importFromGmail() async
    /// Sanitises (if needed) and writes the result into `Settings.signatureHTML`; `true` when the write happened (§4.10).
    func save() async -> Bool
    /// `html` differs from the persisted `Settings.signatureHTML`.
    var isDirty: Bool { get }
    /// `isDirty && error == nil && !isSaving && html.utf8.count <= maxBytes`.
    var canSave: Bool { get }
}

/// The preview document (08 §10 A9, adapted — see D7). Pure string building; never throws.
nonisolated enum SignaturePreviewDocument {
    /// CSP without `https:` (see D7) so nothing can reach the network even if the block-all rule list is not compiled yet.
    static let csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    /// `<!doctype html><html[ data-theme=…]><head>…<style>ThreadDocument.css(light:dark:)</style></head>`
    /// `<body class="mm-plain"><div class="mm-body">{signatureHTML|placeholder}</div></body></html>` — byte layout in §5.3.
    /// `signatureHTML` is inserted **unescaped** (it is already sanitized); an empty/blank value renders the
    /// `<span class="mm-skeleton">Nothing to preview</span>` placeholder.
    static func render(signatureHTML: String, light: ThemeCSSTokens, dark: ThemeCSSTokens, forcedScheme: String?) -> String
}

/// The value shown next to "Signature" in the Compose section.
nonisolated enum SignatureSummary {
    static let limit = 40
    /// Blank HTML → `SettingsStrings.signatureNotSet`. Otherwise `Quoting.textFromHTML(html)` (MailCore, 02) with every
    /// whitespace run collapsed to one space, trimmed, truncated to `limit` characters with a trailing "…".
    /// A signature that is only markup (e.g. `<img src="…">`) yields `"HTML signature"`.
    static func line(_ html: String) -> String
}
```

### 3.4 `minimail/Features/Settings/SignatureEditorScreen.swift`

```swift
import MailCore
import SwiftUI
import UIKit
import WebKit

/// Raw-HTML signature editor with a live preview (architecture §8.2, §7.5, D12/D26). Pushed from `SettingsScreen`.
struct SignatureEditorScreen: View {
    init()
    var body: some View
}

/// Hosts one throwaway `WKWebView` created by `WebViewHost.makeThrowawayWebView()` (08 §4.10: no cid handler,
/// no message handler, no user script, block-all rule list). The instance lives exactly as long as this representable.
private struct SignaturePreviewView: UIViewRepresentable {
    let host: WebViewHost
    let document: String
    let interfaceStyle: UIUserInterfaceStyle     // ThemeStore.interfaceStyle
    let backgroundColor: UIColor                 // UIColor(themeTokens.surface)
    func makeUIView(context: Context) -> WKWebView
    func updateUIView(_ webView: WKWebView, context: Context)
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator)
    func makeCoordinator() -> Coordinator
    final class Coordinator { var appliedDocument: String = ""; var appliedStyle: UIUserInterfaceStyle = .unspecified }
}
```

---

## 4. Behaviour

### 4.1 Lifecycle of `SettingsScreen`

```
SettingsScreen
  @Environment(AppEnvironment.self) env
  @Environment(ThemeStore.self)     theme
  @Environment(SettingsStore.self)  settings
  @Environment(\.dismiss)           dismiss
  @ThemeTokensReader                themeTokens
  @State private var model: SettingsModel?

.onAppear  { if model == nil { model = SettingsModel(env: env) } }
.task      { await model?.verifyBadgeAuthorization(); await model?.load() }
```

- One `SettingsModel` per presentation; it dies with the sheet. No observation is started and nothing is cancelled on disappear (the model holds no `ValueObservation`, no `Task`).
- `.task` runs after the first frame; the Advanced rows render `"—"` / `0` until `load()` returns (typically one indexed read, < 2 ms).
- `SyncStatus` is `@Observable` and read directly (`env.syncStatus.phase` etc.), so the status line updates live while a sync runs; the numbers from `info` (historyId, pending, failed) refresh only on `load()` and after a full resync — good enough for a diagnostic panel (architecture D9: "Settings → Advanced keeps a sync-status line").
- The screen performs **no** write besides `SettingsStore.update`, `ThemeStore.choice` and the two actor calls (`requestFullResync`, `updateBadge`) triggered by user taps.

### 4.2 `SettingsModel.load()`

```
load():
 1. let snapshot: SettingsAdvancedInfo? = try? await env.db.read { db in
        let all    = try SyncStateRepository.all(db)                       // 06 §3.15 ADDITION, one SELECT
        let counts = try Queries.outboxCounts(db)                          // 06 §3.9
        let sig    = all[.sendAsSignature]
        return SettingsAdvancedInfo(
            accountEmail:     all[.accountEmail],
            displayName:      all[.displayName],
            historyId:        all[.historyId],
            lastFullSyncAtMs: all[.lastFullSyncAt].flatMap(Int64.init),
            lastDeltaSyncAtMs:all[.lastDeltaSyncAt].flatMap(Int64.init),
            hasGmailSignature:(sig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            pendingOps:       counts.pending,
            failedSends:      counts.failed)
    }
 2. guard let snapshot else { Log.ui.error("settings.load failed"); return }     // keeps the previous value
 3. info = snapshot
```

Isolation: the closure is `@Sendable` and runs on a GRDB reader thread; `SettingsAdvancedInfo` is `nonisolated Sendable`. No SQL string is written here (rule 3 of architecture §2.1).

### 4.3 Editing a `Settings` field

Every toggle/picker writes through `SettingsStore.binding(_:)`:

```
binding(keyPath):
    Binding(get:  { self.settings[keyPath: keyPath] },
            set:  { v in self.update { $0[keyPath: keyPath] = v } })
```

`SettingsStore.update` (01 §3.9) applies the change to a copy, calls `Settings.normalized()` (clamps `inboxPageSize`, re-assigns `composeStyle` so `ComposeStyle`'s `didSet` clamps `sizePx` and validates `colorHex`), assigns `settings` (one observation change) and writes the JSON synchronously with `.sortedKeys`. Consequences relied on here:

| Field | Written by | Read by |
|---|---|---|
| `themeChoice` | `ThemeStore.choice`'s `didSet` (01 §3.7) — **not** by this module directly | `RootView` (`preferredColorScheme`), 10 (`forcedDocumentTheme`), this module (preview scheme) |
| `composeStyle.family` / `.sizePx` / `.colorHex` | `SettingsComposeSection` | 07 `OutboxIdentitySource.current()` → `OutgoingBodies.html` |
| `signatureHTML` | `SignatureEditorModel.save()` (sanitized) | 07 `OutboxIdentitySource.current()` |
| `signatureEnabled` | `SettingsComposeSection` toggle | 07 identity closure, 11 `ComposeModel.includeSignature` |
| `loadRemoteImages` | `SettingsReadingSection` toggle | 10 `ThreadModel` |
| `markReadOnOpen` | `SettingsReadingSection` toggle | 10 `ThreadModel` |
| `showBadge` | `SettingsModel.setBadgeEnabled` / `verifyBadgeAuthorization` only | 07 `SyncEngine.updateBadge` |

A theme change takes effect immediately: `ThemeStore` is `@Observable`, `RootView` applies `.preferredColorScheme` and `.tint`, and the sheet re-renders with the new `ThemeTokensReader` values in the same update. The open signature preview does **not** re-theme (its tokens were captured at `init`) — see §10 A6.

### 4.4 Badge toggle (architecture §4.6, §11, §14 #11; `[ios-platform §6]`)

#### 4.4.1 Turning it on

```
setBadgeEnabled(true):
 1. guard badgeState != .requesting else { return }
 2. badgeState = .requesting
 3. let granted = await badge.requestBadgeAuthorization()          // UNUserNotificationCenter, [.badge] only
 4. if granted {
        badgeState = .idle
        env.settings.update { $0.showBadge = true }
        await env.sync.updateBadge()                               // 07: setBadgeCount(inboxUnreadThreadCount)
    } else {
        badgeState = .denied
        env.settings.update { $0.showBadge = false }                // the toggle snaps back on the next render
        Log.ui.notice("badge authorization denied")
    }
```

#### 4.4.2 Turning it off

```
setBadgeEnabled(false):
 1. env.settings.update { $0.showBadge = false }
 2. badgeState = .idle
 3. await badge.setBadgeCount(0)                                    // clears a stale badge; SyncEngine.updateBadge() is a no-op now
```

#### 4.4.3 Reconciliation on appear

```
verifyBadgeAuthorization():
 1. guard env.settings.snapshot.showBadge else { badgeState = .idle; return }
 2. if await badge.isBadgeEnabled() { badgeState = .idle; return }
 3. env.settings.update { $0.showBadge = false }; badgeState = .denied; await badge.setBadgeCount(0)
    Log.ui.notice("badge authorization revoked, toggle switched off")
```

Edge cases: a `requestAuthorization` throw is mapped to `false` by `SystemBadgeAuthorizer` (denial and failure are indistinguishable to the user, and both mean "no badge"); a second tap while `.requesting` is ignored; the system prompt appears at most once per install, so a user who denied it once only ever sees the `.denied` footer with the "Open Settings" button (`UIApplication.openSettingsURLString` through `@Environment(\.openURL)`).

### 4.5 Full resync

```
fullResync():
 1. guard !isResyncing else { return }
 2. isResyncing = true
 3. await env.sync.requestFullResync()        // 07 §3.5: clears syncState.historyId, then run(.pullToRefresh) → full-sync path
 4. isResyncing = false
 5. await load()                              // historyId + counts are now current
```

The button is behind a `confirmationDialog` (`SettingsStrings.resyncConfirm*`) because it costs one `messages.list` + four metadata batches (architecture §12.1) and drops "Load older" pages (§14 #22). While `isResyncing`, the row shows a `ProgressView` and is disabled. The call never throws (`requestFullResync` is non-throwing) and the observable result is visible in the inbox (`SyncStatus.phase == .syncing`, then rows refresh).

### 4.6 Derived strings

```
statusLine:
    if env.syncStatus.isOffline                 → "Offline"
    switch env.syncStatus.phase {
      case .syncing:      → "Syncing…"
      case .initialSync:  → "First sync…"
      case .idle:         → env.syncStatus.lastError ?? "Idle"
    }

lastSyncLine:
    let d = env.syncStatus.lastSyncAt
            ?? [info.lastDeltaSyncAtMs, info.lastFullSyncAtMs].compactMap { $0 }.max()
                 .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    return d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"

versionLine:
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) { case let (s?, b?): "\(s) (\(b))"; case let (s?, nil): s; default: "—" }

accountEmailLine:
    info.accountEmail ?? env.auth.state.email ?? "—"
```

`lastSyncLine` is the only formatter use; `Date.FormatStyle` is locale-aware and needs no cached `DateFormatter` (this screen is not on a scroll path, architecture §8.3's precomputation rule does not apply).

### 4.7 Sign-out

```
Sign Out row tapped  → model.showsSignOutConfirmation = true
confirmation "Sign Out" (destructive) →
    dismiss()                                    // close the sheet first: RootView is about to swap in SignInScreen
    Task { await model.signOut() }               // unstructured; the closure keeps the model (and env) alive

signOut():
    guard !isSigningOut else { return }
    isSigningOut = true
    await env.auth.signOut()                     // 04 §4.11 / architecture §5.4: cancel sync+drain, revoke, Keychain, wipe DB,
                                                 // purge caches, recycle web view, setBadgeCount(0), state = .signedOut
    isSigningOut = false
```

This module does **not** clear `Settings`: architecture §5.4 keeps theme, compose style and signature across sign-out, and `lastSignedInEmail` stays as the `login_hint`.

### 4.8 `HexColor`

```
color(hex):
 1. guard ComposeStyle.isValidHex(hex) else { return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1) }
 2. let v = UInt32(hex.dropFirst(), radix: 16)!         // 6 lowercase hex digits, validated in step 1
 3. Color(.sRGB, red: Double((v >> 16) & 0xff)/255, green: Double((v >> 8) & 0xff)/255, blue: Double(v & 0xff)/255, opacity: 1)

hex(uiColor):
 1. let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
 2. var r/g/b/a: CGFloat = 0; guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
 3. func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
 4. String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))

hex(color) = hex(UIColor(color))
```

Notes: `getRed` on a Display-P3 colour returns extended-sRGB components that may fall outside 0…1; step 3 clamps them, which is the standard "closest sRGB" behaviour and keeps `ComposeStyle.isValidHex` satisfied (see §10 A3 for the exact-conversion fallback). `String(format:)` with `%02x` produces lowercase digits, which `ComposeStyle.colorHex`'s `didSet` requires (uppercase would be rejected and reset to `#000000`).

### 4.9 Signature preview pipeline

```
SignatureEditorScreen:
    .onAppear      { if model == nil { model = SignatureEditorModel(env:, light:, dark:, forcedScheme:) ; model!.load() } }
    .task(id: model?.html)                                  // re-created on every keystroke → previous sleep is cancelled
        { try? await Task.sleep(for: .milliseconds(SignatureEditorModel.previewDebounceMs))
          await model?.refreshPreview() }

load():
    html = env.settings.snapshot.signatureHTML
    savedHTML = html ; sanitized = nil ; warning = nil ; error = nil ; importState = .idle
    previewDocument = SignaturePreviewDocument.render(signatureHTML: "", light:, dark:, forcedScheme:)

refreshPreview():
 1. let source = html
 2. guard source.utf8.count <= Self.maxBytes else {
        error = SettingsStrings.signatureTooLarge ; warning = nil ; sanitized = nil ; return }
 3. let outcome: Result<String, any Error> = await Task.detached(priority: .userInitiated) {
        do { return .success(try SignatureSanitizer.sanitize(source)) } catch { return .failure(error) } }.value
 4. guard !Task.isCancelled, html == source else { return }          // a newer keystroke already won
 5. switch outcome {
      case .success(let clean):
          sanitized = clean ; error = nil
          warning = SignatureSanitizer.hasDataImages(clean) ? SettingsStrings.dataImageWarning : nil
          previewDocument = SignaturePreviewDocument.render(signatureHTML: clean, light:, dark:, forcedScheme:)
      case .failure(let e):
          sanitized = nil ; warning = nil ; error = Self.message(for: e)
          Log.ui.notice("signature sanitize failed: \(e)")
    }

message(for:)   SanitizerError.tooLarge    → SettingsStrings.signatureTooLarge
                SanitizerError.cleanFailed → SettingsStrings.signatureCleanFailed
                anything else              → SettingsStrings.signatureUnknownError
```

- The sanitizer runs on a detached task because SwiftSoup parsing is CPU work and must not block typing (architecture §2.1 rule 4's spirit: no heavy work on the writer/main). `String` is `Sendable`; `SignatureSanitizer` is `nonisolated`.
- `.task(id:)` gives a free debounce: SwiftUI cancels the previous task when `html` changes, so `Task.sleep` throws and no sanitize starts. At most one sanitize per 400 ms idle period.
- An empty editor renders the placeholder document, not an error.
- The preview never loads remote resources: CSP `img-src data:` **and** the block-all content rule list on the throwaway instance (§4.12).

### 4.10 Save

```
save():
 1. guard !isSaving else { return false }
 2. isSaving = true ; defer { isSaving = false }
 3. if sanitized == nil && error == nil { await refreshPreview() }     // user hit Save inside the debounce window
 4. guard error == nil, let clean = sanitized else { return false }
 5. env.settings.update { $0.signatureHTML = clean }                   // architecture §7.5: sanitized once on save
 6. html = clean ; savedHTML = clean                                   // the editor now shows what was stored
 7. return true

SignatureEditorScreen toolbar: Button("Save") { Task { if await model.save() { dismiss() } } }.disabled(!model.canSave)
```

`dismiss()` inside a pushed `NavigationLink` destination pops back to `SettingsScreen` (SwiftUI `DismissAction` semantics for a pushed view). The Compose section's "Signature" value updates on the next render because `SettingsStore.settings` changed.

Saving replaces the editor text with the sanitized HTML on purpose: the owner sees exactly what will be sent, and `isDirty` becomes false so a second Save is disabled.

### 4.11 Import from Gmail (`[gmail-api §15]`, architecture §7.5)

```
Import row tapped:
    if model.isDirty || !model.html.isEmpty { model.showsImportConfirmation = true }
    else { Task { await model.importFromGmail() } }

importFromGmail():
 1. importState = .loading
 2. let raw = try? await env.db.read { try SyncStateRepository.get($0, .sendAsSignature) }
 3. let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
 4. guard !value.isEmpty else { importState = .unavailable ; return }
 5. html = value                      // triggers .task(id:) → debounce → refreshPreview()
 6. importState = .imported
```

`syncState.sendAsSignature` is written by every full sync from the default/primary `sendAs` alias (07 §5.1); it is the **raw** Gmail HTML and is sanitized only when the user saves. It may reference `https://ci3.googleusercontent.com/…` proxied images — kept as remote images by `SignatureSanitizer` (08 §4.5) and therefore not rendered in the preview (§4.12). The import never performs a network request; if a signed-in account has never completed a full sync, the value is absent and the user sees `SettingsStrings.importUnavailable`.

### 4.12 Throwaway preview web view

```
makeUIView:
    let wv = host.makeThrowawayWebView()          // 08 §4.10: no cid handler, no "mm" handler, no user script, block-all rule list,
                                                  // allowsContentJavaScript = false, nonPersistent data store, LinkPolicy that opens nothing
    wv.isOpaque = false
    wv.scrollView.isScrollEnabled = true
    wv.scrollView.bounces = false
    return wv

updateUIView(wv, context):
    if context.coordinator.appliedStyle != interfaceStyle { wv.overrideUserInterfaceStyle = interfaceStyle; coordinator.appliedStyle = interfaceStyle }
    wv.backgroundColor = backgroundColor ; wv.underPageBackgroundColor = backgroundColor
    guard context.coordinator.appliedDocument != document else { return }
    wv.loadHTMLString(document, baseURL: nil)
    context.coordinator.appliedDocument = document

dismantleUIView(wv, _):
    wv.stopLoading()
    wv.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)   // drop the DOM before release
```

The instance is created when the editor appears and released when it disappears (D12: "the signature editor uses a throwaway second instance only while visible"). The pooled `WebViewHost.webView` is never touched here, so a thread that is open behind the sheet keeps its document and scroll position.

### 4.13 Concurrency and isolation

| Element | Isolation | Notes |
|---|---|---|
| `SettingsScreen`, `SignatureEditorScreen`, `RequestLogScreen`, every private section view, `SettingsModel`, `SignatureEditorModel` | `@MainActor` (implicit) | pure UI state |
| `SettingsAdvancedInfo`, `SignatureImportState`, `SignaturePreviewDocument`, `SignatureSummary`, `HexColor`, `SettingsStrings`, `BadgeAuthorizing`, `SystemBadgeAuthorizer` | `nonisolated`, `Sendable` | crossing into `@Sendable` GRDB closures and detached tasks |
| `env.db.read { … }` | GRDB reader pool, off main | two one-shot reads in the whole module (`load`, `importFromGmail`); no `ValueObservation` |
| `Task.detached { try SignatureSanitizer.sanitize(source) }` | cooperative pool | only `String` crosses the boundary |
| `env.sync.requestFullResync()`, `env.sync.updateBadge()`, `env.auth.signOut()` | actor / main-actor hops from an unstructured `Task` | fire-and-forget; results appear through `SyncStatus` and `AuthStore.state` |
| `UNUserNotificationCenter` calls | inside `SystemBadgeAuthorizer` (`nonisolated`) | never called from a view body |

No `@Sendable` closure captures `self`. No timer, no polling, no `NotificationCenter` observer (`grep -rn "Timer\|DispatchSourceTimer\|NotificationCenter" minimail/Features/Settings` prints nothing).

### 4.14 Performance

| Constraint | How it is met |
|---|---|
| Opening the sheet must not stutter | `init` allocates one model; `body` reads `Settings` fields and `SyncStatus` — no I/O, no formatter construction per row |
| Advanced read | one `db.read` with one `syncState` scan and two `COUNT(*)` over `outbox` (a table that holds single-digit row counts in practice) |
| Typing in the editor | sanitize is debounced 400 ms and runs detached; the `TextEditor` binding never sanitises |
| Preview reload | only when `previewDocument` actually changes (`Coordinator.appliedDocument` guard) |
| Battery | no background work is started here; the only network this screen can cause is the user-initiated full resync |
| Memory | one extra `WKWebView` exists only while the editor is on screen |

### 4.15 Error handling — exact cases

| Source | Failure | Handling |
|---|---|---|
| `env.db.read` in `load()` | any `Error` | `Log.ui.error("settings.load failed")`; `info` keeps its previous value; rows show `"—"` / previous numbers; no alert |
| `env.db.read` in `importFromGmail()` | any `Error` | treated as "absent" → `importState = .unavailable` |
| `SignatureSanitizer.sanitize` | `SanitizerError.tooLarge` | `error = SettingsStrings.signatureTooLarge`; Save disabled |
| | `SanitizerError.cleanFailed` | `error = SettingsStrings.signatureCleanFailed`; Save disabled |
| | any SwiftSoup error | `error = SettingsStrings.signatureUnknownError`; Save disabled |
| editor over 64 KB | — | `error = SettingsStrings.signatureTooLarge` before any parsing |
| `requestBadgeAuthorization` | throws or `false` | `badgeState = .denied`; `showBadge` forced false; footer + "Open Settings" |
| `env.auth.signOut()` | never throws (04) | sheet already dismissed; `RootView` swaps to `SignInScreen` |
| `env.sync.requestFullResync()` | never throws (07) | failures surface in `SyncStatus.lastError` → `statusLine` |
| `SettingsStore.update` encoding | logged inside 01's store | in-memory value still updated; nothing to show here |

No alert, no modal, no blocking overlay anywhere in this module (architecture §8.2's rule for the whole app).

---

## 5. Data

### 5.1 `Settings` fields this module writes

No new `UserDefaults` key. The single key is 01's `com.minimail.settings`; a blob after the owner has set a Verdana 15 px dark-blue style, a signature and the badge looks exactly like this (`.sortedKeys`, one line on disk — wrapped here for reading):

```json
{"composeStyle":{"colorHex":"#0b5394","family":"verdana","sizePx":15},
 "inboxPageSize":100,"lastSignedInEmail":"max.mustermann@example.com","loadRemoteImages":false,
 "markReadOnOpen":true,"schemaVersion":1,
 "signatureEnabled":true,
 "signatureHTML":"<div dir=\"ltr\">Max Mustermann<br>Example GmbH<br><a href=\"https://www.example.com\">example.com</a></div>",
 "showBadge":true,"themeChoice":"dark"}
```

| Field | Control | Allowed values |
|---|---|---|
| `themeChoice` | Appearance picker (through `ThemeStore.choice`) | `system` / `light` / `dark` |
| `composeStyle.family` | Compose font picker | the 8 `ComposeStyle.Family` cases |
| `composeStyle.sizePx` | Compose size picker | `ComposeStyle.sizeChoices` = `[12, 13, 14, 15, 16, 18]` (clamped to `12...18`) |
| `composeStyle.colorHex` | `ColorPicker` through `HexColor` | `^#[0-9a-f]{6}$` |
| `signatureHTML` | editor Save (sanitized) | ≤ 65 536 UTF-8 bytes |
| `signatureEnabled` | Compose toggle | bool |
| `loadRemoteImages` | Reading toggle | bool |
| `markReadOnOpen` | Reading toggle | bool |
| `showBadge` | Notifications toggle (only after `[.badge]` was granted) | bool |

### 5.2 `syncState` keys read (never written)

| `SyncKey` | Used for | Format (07 §5.1) |
|---|---|---|
| `accountEmail` | Account row | verbatim address |
| `displayName` | Account row (hidden when absent) | plain string |
| `historyId` | Advanced row | decimal `UInt64` string |
| `lastFullSyncAt`, `lastDeltaSyncAt` | `lastSyncLine` fallback | epoch-ms decimal string |
| `sendAsSignature` | Import from Gmail | raw HTML |

### 5.3 Preview document (byte layout)

`SignaturePreviewDocument.render(signatureHTML: "<div dir=\"ltr\">Max</div>", light: L, dark: D, forcedScheme: "dark")`:

```html
<!doctype html><html data-theme="dark"><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark"><style>{ThreadDocument.css(light: L, dark: D)}</style></head><body class="mm-plain"><div class="mm-body"><div dir="ltr">Max</div></div></body></html>
```

Rules:
- `forcedScheme == "dark"` → ` data-theme="dark"`; `"light"` → ` data-theme="light"`; `nil` or any other value → no attribute (identical to `ThreadDocument.render`, 08 §4.6 step 1).
- The `<style>` content is `ThreadDocument.css(light:dark:)` verbatim (08 §3 ADDITION) — the same variables, `@media (prefers-color-scheme: dark)` block and `html[data-theme]` blocks the thread view uses, so the preview matches what the theme does elsewhere (architecture §9.5).
- `body` has class `mm-plain` and the content sits in `.mm-body`, so the dark-mode readability overrides of §9.2 apply exactly as they do to a plain message.
- Blank input → `<div class="mm-body"><span class="mm-skeleton">Nothing to preview</span></div>`.
- The document is never escaped; `signatureHTML` is either `SignatureSanitizer` output or the empty placeholder.

### 5.4 Accessibility identifiers (used by the hosting tests and by module 14's checklist)

```
settings.done                 settings.account.email        settings.account.name
settings.signOut              settings.theme                settings.font
settings.fontSize             settings.color                settings.signature
settings.signatureEnabled     settings.loadImages           settings.markRead
settings.badge                settings.badgeHelp            settings.advanced.status
settings.advanced.lastSync    settings.advanced.historyId   settings.advanced.pending
settings.advanced.failed      settings.resync               settings.requestLog
settings.version
signature.editor              signature.preview             signature.save
signature.import              signature.warning             signature.error
signature.importState         requestLog.list               requestLog.refresh
```

### 5.5 SF Symbols

| Where | Symbol |
|---|---|
| signature `data:` warning row | `exclamationmark.triangle` |
| signature sanitizer error row | `xmark.octagon` |
| import row | `arrow.down.doc` |
| full resync row | `arrow.clockwise` |
| request log row (DEBUG) | `list.bullet.rectangle` |

No other image is used; every other row is text only (system `Form` styling).

---

## 6. UI

### 6.1 `SettingsScreen` hierarchy

```
SettingsScreen
└─ NavigationStack
   └─ Form {
        SettingsAccountSection(model: model)                 (§6.3)
        SettingsAppearanceSection()                          (§6.4)
        SettingsComposeSection()                             (§6.5)
        SettingsReadingSection()                             (§6.6)
        SettingsNotificationsSection(model: model)           (§6.7)
        SettingsAdvancedSection(model: model)                (§6.8)
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.accessibilityIdentifier("settings.done") } }
      .navigationDestination(for: SettingsRoute.self) { _ in SignatureEditorScreen() }
   .onAppear { if model == nil { model = SettingsModel(env: env) } }
   .task { await model?.verifyBadgeAuthorization(); await model?.load() }
```

`SettingsRoute` is a private `enum SettingsRoute: Hashable { case signature }`; the Compose section pushes it with `NavigationLink(value: SettingsRoute.signature)`. (A value-based link keeps the destination out of the row's body, so the editor's `WKWebView` is created only when the row is tapped.)

The whole screen is one system `Form` — no custom background, no custom row insets, no scroll view of its own. Dynamic Type, Increase Contrast and Smart Invert are honoured because every colour is a theme token resolving to a system semantic colour (architecture D14).

### 6.2 States of the screen

| State | Rendering |
|---|---|
| fresh (before `load()`) | Account "—", Advanced History ID "—", Pending 0, Failed 0, Last Sync from `SyncStatus.lastSyncAt` or "Never"; every editable row is already live (they read `Settings`, not the database) |
| loaded | `info` values substituted |
| `phase == .syncing` / `.initialSync` | Status row shows "Syncing…" / "First sync…"; nothing is disabled |
| `isOffline` | Status row "Offline" |
| `lastError != nil` and idle | Status row shows the error text (a `GmailError.userMessage` from 05 or "Database unavailable") |
| `badgeState == .requesting` | badge toggle disabled |
| `badgeState == .denied` | badge toggle off + help footer + "Open Settings" button |
| `isResyncing` | resync row shows a trailing `ProgressView`, row disabled |
| `isSigningOut` | Sign Out row disabled (visible only for the instant before dismissal) |
| DEBUG build | "Recent Requests" row present; absent in Release |

There is no loading spinner for the sheet as a whole and no error state: every row has a defined rendering with missing data.

### 6.3 Account section

```swift
Section("Account") {
    LabeledContent("Email", value: model.accountEmailLine)
        .accessibilityIdentifier("settings.account.email")
        .accessibilityLabel("Account email, \(model.accountEmailLine)")
    if let name = model.info.displayName, !name.isEmpty {
        LabeledContent("Name", value: name).accessibilityIdentifier("settings.account.name")
    }
    Button(SettingsStrings.signOutTitle, role: .destructive) { model.showsSignOutConfirmation = true }
        .disabled(model.isSigningOut)
        .accessibilityIdentifier("settings.signOut")
} footer: {
    Text(SettingsStrings.accountFooter)
}
.confirmationDialog(SettingsStrings.signOutConfirmTitle,
                    isPresented: $model.showsSignOutConfirmation, titleVisibility: .visible) {
    Button(SettingsStrings.signOutTitle, role: .destructive) { dismiss(); Task { await model.signOut() } }
    Button("Cancel", role: .cancel) { }
} message: { Text(SettingsStrings.signOutConfirmDetail) }
```

### 6.4 Appearance section

```swift
Section("Appearance") {
    @Bindable var theme = theme
    Picker("Theme", selection: $theme.choice) {
        ForEach(ThemeChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("settings.theme")
}
```

Selecting a value writes `ThemeStore.choice`, whose `didSet` persists `Settings.themeChoice` (01 §3.7). The change is visible immediately across the app: `RootView`'s `.preferredColorScheme` and `.tint` re-apply, and the sheet itself re-renders with the new tokens. Adding a future theme is one `ThemeStore.registry` entry plus one `ThemeChoice` case — this picker needs no edit (architecture §10 "Extensibility").

### 6.5 Compose section

```swift
Section("Compose") {
    Picker("Font", selection: settings.binding(\.composeStyle.family)) {
        ForEach(ComposeStyle.Family.allCases, id: \.self) { Text($0.displayName).tag($0) }
    }
    .pickerStyle(.menu).accessibilityIdentifier("settings.font")

    Picker("Size", selection: settings.binding(\.composeStyle.sizePx)) {
        ForEach(ComposeStyle.sizeChoices, id: \.self) { Text("\($0) px").tag($0) }
    }
    .pickerStyle(.menu).accessibilityIdentifier("settings.fontSize")

    ColorPicker("Text Color", selection: composeColorBinding, supportsOpacity: false)
        .accessibilityIdentifier("settings.color")

    NavigationLink(value: SettingsRoute.signature) {
        LabeledContent("Signature", value: SignatureSummary.line(settings.settings.signatureHTML))
    }
    .accessibilityIdentifier("settings.signature")

    Toggle("Use Signature", isOn: settings.binding(\.signatureEnabled))
        .accessibilityIdentifier("settings.signatureEnabled")
} footer: {
    Text(SettingsStrings.composeFooter)
}

private var composeColorBinding: Binding<Color> {
    Binding(get: { HexColor.color(settings.settings.composeStyle.colorHex) },
            set: { newColor in settings.update { $0.composeStyle.colorHex = HexColor.hex(newColor) } })
}
```

`ComposeStyle.Family` is `CaseIterable` (01 §3.1) and the eight `displayName`s are the exact strings of `[html-rendering §5.3]`. `supportsOpacity: false` keeps the picker from producing a colour whose alpha would be silently dropped. `Use Signature` off keeps the stored HTML (architecture §7.5: "toggles inclusion without deleting").

### 6.6 Reading section

```swift
Section("Reading") {
    Toggle("Load Remote Images Automatically", isOn: settings.binding(\.loadRemoteImages))
        .accessibilityIdentifier("settings.loadImages")
    Toggle("Mark as Read When Opened", isOn: settings.binding(\.markReadOnOpen))
        .accessibilityIdentifier("settings.markRead")
} footer: {
    Text(SettingsStrings.readingFooter)
}
```

### 6.7 Notifications section

```swift
Section("Notifications") {
    Toggle("Show Unread Count on Icon", isOn: badgeBinding)
        .disabled(model.badgeState == .requesting)
        .accessibilityIdentifier("settings.badge")
    if model.badgeState == .denied {
        Button(SettingsStrings.badgeOpenSettings) {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .accessibilityIdentifier("settings.badgeHelp")
    }
} footer: {
    if model.badgeState == .denied { Text(SettingsStrings.badgeDeniedFooter) }
}

private var badgeBinding: Binding<Bool> {
    Binding(get: { settings.settings.showBadge },
            set: { on in Task { await model.setBadgeEnabled(on) } })
}
```

The toggle is the **only** place the app asks for notification authorization, and it asks in context, as Apple requires `[ios-platform §6]`. The badge value itself is written by `SyncEngine.updateBadge()` after every run and every outbox ack (architecture §4.6).

### 6.8 Advanced section

```swift
Section("Advanced") {
    LabeledContent("Status", value: model.statusLine).accessibilityIdentifier("settings.advanced.status")
    LabeledContent("Last Sync", value: model.lastSyncLine).accessibilityIdentifier("settings.advanced.lastSync")
    LabeledContent("History ID", value: model.info.historyId ?? "—").accessibilityIdentifier("settings.advanced.historyId")
    LabeledContent("Pending Operations", value: "\(model.info.pendingOps)").accessibilityIdentifier("settings.advanced.pending")
    LabeledContent("Failed Sends", value: "\(model.info.failedSends)").accessibilityIdentifier("settings.advanced.failed")

    Button { model.showsResyncConfirmation = true } label: {
        HStack { Label(SettingsStrings.resyncTitle, systemImage: "arrow.clockwise")
                 Spacer()
                 if model.isResyncing { ProgressView().controlSize(.small) } }
    }
    .disabled(model.isResyncing)
    .accessibilityIdentifier("settings.resync")

    #if DEBUG
    NavigationLink { RequestLogScreen() } label: { Label("Recent Requests", systemImage: "list.bullet.rectangle") }
        .accessibilityIdentifier("settings.requestLog")
    #endif

    LabeledContent("Version", value: model.versionLine).accessibilityIdentifier("settings.version")
} footer: {
    Text(SettingsStrings.advancedFooter)
}
.confirmationDialog(SettingsStrings.resyncConfirmTitle,
                    isPresented: $model.showsResyncConfirmation, titleVisibility: .visible) {
    Button(SettingsStrings.resyncTitle) { Task { await model.fullResync() } }
    Button("Cancel", role: .cancel) { }
} message: { Text(SettingsStrings.resyncConfirmDetail) }
```

### 6.9 `RequestLogScreen` (DEBUG)

```swift
struct RequestLogScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var lines: [String] = []
    var body: some View {
        List {
            if lines.isEmpty { ContentUnavailableView("No requests yet", systemImage: "list.bullet.rectangle") }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("requestLog.list")
        .navigationTitle("Recent Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button("Refresh") { reload() }.accessibilityIdentifier("requestLog.refresh") } }
        .onAppear { reload() }
    }
    private func reload() { lines = (env.requestLog?.snapshot() ?? []).reversed() }
}
```

Entries are rendered newest first. `RequestLog.snapshot()` already formats each line as `"HH:mm:ss.SSS METHOD path status msms"` (05 §3.3) and never contains tokens, headers or bodies (architecture §6.5).

### 6.10 `SignatureEditorScreen` hierarchy

```
SignatureEditorScreen                       @State model: SignatureEditorModel?
                                            @Environment(AppEnvironment.self) env
                                            @Environment(ThemeStore.self) theme
                                            @Environment(\.dismiss) dismiss
                                            @ThemeTokensReader themeTokens
└─ Form {
     Section("HTML") {
       TextEditor(text: $model.html)
         .font(.system(.footnote, design: .monospaced))
         .frame(minHeight: 160)
         .autocorrectionDisabled()
         .textInputAutocapitalization(.never)
         .accessibilityIdentifier("signature.editor")
         .accessibilityLabel("Signature HTML")
     } footer: { statusFooter }                                      (§6.11)

     Section("Preview") {
       SignaturePreviewView(host: env.webHost, document: model.previewDocument,
                            interfaceStyle: theme.interfaceStyle,
                            backgroundColor: UIColor(themeTokens.surface))
         .frame(height: 180)
         .accessibilityIdentifier("signature.preview")
         .accessibilityLabel("Signature preview")
     } footer: { Text(SettingsStrings.previewFooter) }

     Section {
       Button { importTapped() } label: { Label("Import from Gmail", systemImage: "arrow.down.doc") }
         .disabled(model.importState == .loading)
         .accessibilityIdentifier("signature.import")
     } footer: { importFooter }                                      (§6.11)
   }
   .navigationTitle("Signature")
   .navigationBarTitleDisplayMode(.inline)
   .toolbar { ToolbarItem(placement: .confirmationAction) {
       Button("Save") { Task { if await model.save() { dismiss() } } }
         .disabled(!(model?.canSave ?? false))
         .accessibilityIdentifier("signature.save") } }
   .onAppear { if model == nil { let t = theme.resolved(for: theme.preferredColorScheme ?? .light)
                                model = SignatureEditorModel(env: env, light: t.cssTokens(for: .light),
                                                             dark: t.cssTokens(for: .dark),
                                                             forcedScheme: theme.forcedDocumentTheme)
                                model?.load() } }
   .task(id: model?.html) { try? await Task.sleep(for: .milliseconds(SignatureEditorModel.previewDebounceMs))
                            await model?.refreshPreview() }
   .confirmationDialog(SettingsStrings.importOverwriteTitle, isPresented: $model.showsImportConfirmation,
                       titleVisibility: .visible) {
       Button("Replace") { Task { await model.importFromGmail() } }
       Button("Cancel", role: .cancel) { }
   } message: { Text(SettingsStrings.importOverwriteDetail) }
```

The editor never uses a second `Form` inside a `NavigationStack` of its own: it is pushed into `SettingsScreen`'s stack (architecture §8.1).

### 6.11 Footers of the editor

```swift
@ViewBuilder private var statusFooter: some View {
    if let e = model.error {
        Label(e, systemImage: "xmark.octagon").font(.footnote)
            .foregroundStyle(themeTokens.text).accessibilityIdentifier("signature.error")
    } else if let w = model.warning {
        Label(w, systemImage: "exclamationmark.triangle").font(.footnote)
            .foregroundStyle(themeTokens.secondaryText).accessibilityIdentifier("signature.warning")
    }
}

@ViewBuilder private var importFooter: some View {
    switch model.importState {
    case .idle:        EmptyView()
    case .loading:     Text("Loading…").font(.footnote).accessibilityIdentifier("signature.importState")
    case .unavailable: Text(SettingsStrings.importUnavailable).font(.footnote).accessibilityIdentifier("signature.importState")
    case .imported:    Text(SettingsStrings.importDone).font(.footnote).accessibilityIdentifier("signature.importState")
    }
}
```

`ThemeTokens` has no error colour (architecture §10); the error row is distinguished by its symbol and by Save staying disabled (same decision as 11 §10 A8).

### 6.12 User action → effect (complete table)

| Action | Effect |
|---|---|
| Tap `gearshape` in the inbox (09) | `ActiveSheet.settings` → this screen |
| "Done" | `dismiss()` |
| Theme picker | `ThemeStore.choice` → `Settings.themeChoice`; whole app re-themes instantly |
| Font / Size picker | `Settings.composeStyle` → next outgoing mail (07 `OutgoingBodies`) |
| `ColorPicker` | `Settings.composeStyle.colorHex` via `HexColor.hex` |
| Tap "Signature" | push `SignatureEditorScreen` |
| "Use Signature" | `Settings.signatureEnabled` → 07 identity closure / 11 `includeSignature` |
| "Load Remote Images Automatically" | `Settings.loadRemoteImages` → 10 |
| "Mark as Read When Opened" | `Settings.markReadOnOpen` → 10 |
| Badge toggle on | `[.badge]` prompt → on grant persist + `SyncEngine.updateBadge()`; on denial self-off + footer |
| Badge toggle off | persist false + `setBadgeCount(0)` |
| "Open Settings" | `openURL(UIApplication.openSettingsURLString)` |
| "Full Resync Now" → "Full Resync Now" in the dialog | `SyncEngine.requestFullResync()` then `load()` |
| "Recent Requests" (DEBUG) | push `RequestLogScreen` |
| "Sign Out" → "Sign Out" in the dialog | `dismiss()` then `AuthStore.signOut()` |
| Type in the editor | debounce 400 ms → sanitize → preview / warning / error |
| "Import from Gmail" | (confirm if the editor is non-empty) → `syncState.sendAsSignature` into the editor |
| "Save" | sanitize → `Settings.signatureHTML` → pop |

### 6.13 Haptics, Dynamic Type, accessibility

- **Haptics**: none. Architecture §8.3 assigns `.sensoryFeedback` to the list (impact), filter changes (selection) and send (success) only; a settings form uses the system's own control feedback. `grep -rn "sensoryFeedback\|UIImpactFeedbackGenerator" minimail/Features/Settings` prints nothing.
- **Dynamic Type**: every label uses a system text style (`Form` defaults, `.footnote` for footers, `.caption` monospaced for the request log). The preview web view carries `font:-apple-system-body` from `ThreadDocument.css` and therefore follows the content size category the same way the thread view does (architecture §9.6).
- **Accessibility**: `LabeledContent` exposes label + value automatically; the two rows that need more context carry explicit `accessibilityLabel`s (§6.3, §6.10). Every interactive row has an identifier from §5.4. The colour picker is the system control (fully accessible). No custom gesture, no drag, no swipe.
- **Colours**: only through `ThemeTokensReader` / system control defaults / `HexColor` (which renders a user-chosen value, not a UI colour). `make lint`'s raw-colour grep passes.

---

## 7. Tests

All four files are **app tests** (XCTest on the simulator, `make test-app` / `make test-one`). No `swift test` package test is added: `SignatureSanitizer` and `ThreadDocument.css` are covered by 08's `MailHTMLTests` / `MailCoreTests`, `ComposeStyle` by 01's `MailCoreTests`, and everything this module adds touches `AppEnvironment`, `UIKit` or `SwiftUI`.

**Shared setup** (all three new files, following 09 §7 / 11 §7):

```swift
var env: AppEnvironment!               // AppEnvironment(testing: true): temporary pool (06), offline stub (05 D8),
                                       // auth .signedOut, isolated UserDefaults suite "com.minimail.testing"
let seedNow: Int64 = 1_757_500_000_000                  // 2025-09-10 10:26:40 UTC

override func setUp() async throws {
    env = AppEnvironment(testing: true)
}
override func tearDown() async throws { env = nil }

/// Polls every 20 ms until `cond()` or `timeout`; `XCTFail` on timeout (09 §7 helper, reused verbatim).
func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async

/// Seeds the syncState rows the Advanced section reads.
func seedSyncState(email: String? = "max.mustermann@example.com", name: String? = "Max Mustermann",
                   historyId: String? = "1234530", deltaAtMs: Int64? = seedNow,
                   signature: String? = "<div dir=\"ltr\">Max Mustermann<br>Example</div>") async throws
```

**Stub** (in `SettingsModelTests.swift`, used by both model files):

```swift
/// Records every call and returns scripted answers (`[ios-platform §6]` cannot be exercised in a test host).
final class StubBadgeAuthorizer: BadgeAuthorizing, @unchecked Sendable {
    var grantResult = true
    var enabledResult = true
    private(set) var requests = 0
    private(set) var enabledChecks = 0
    private(set) var badgeCounts: [Int] = []
    func requestBadgeAuthorization() async -> Bool
    func isBadgeEnabled() async -> Bool
    func setBadgeCount(_ count: Int) async
}
```

No fixture file is added. The HTML samples are inline string literals listed in the tables below.

### 7.1 `minimailTests/Settings/SettingsModelTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testLoadReadsSyncStateAndOutboxCounts` | `seedSyncState()`; one failed send + one pending modify written through `OutboxRepository.enqueueSend`/`fail` and `enqueueModify` on a seeded thread; `model = SettingsModel(env: env, badge: stub)` | after `await model.load()`: `info.accountEmail == "max.mustermann@example.com"`, `info.displayName == "Max Mustermann"`, `info.historyId == "1234530"`, `info.lastDeltaSyncAtMs == seedNow`, `info.hasGmailSignature == true`, `info.pendingOps == 1`, `info.failedSends == 1`; `try InvariantChecks.assertAll(env.db)` |
| `testLoadWithEmptyDatabase` | no seed | `info == .empty`; `accountEmailLine == "—"`; `lastSyncLine == "Never"`; `info.hasGmailSignature == false` |
| `testLoadIgnoresBlankSignature` | `seedSyncState(signature: "   ")` | `info.hasGmailSignature == false` |
| `testBadgeToggleOnGranted` | `stub.grantResult = true` | `await model.setBadgeEnabled(true)`; `stub.requests == 1`; `env.settings.snapshot.showBadge == true`; `model.badgeState == .idle` |
| `testBadgeToggleOnDenied` | `stub.grantResult = false` | `await model.setBadgeEnabled(true)`; `env.settings.snapshot.showBadge == false`; `model.badgeState == .denied`; no `setBadgeCount` call recorded |
| `testBadgeToggleOff` | `env.settings.update { $0.showBadge = true }` | `await model.setBadgeEnabled(false)`; `showBadge == false`; `stub.badgeCounts == [0]`; `badgeState == .idle`; `stub.requests == 0` |
| `testVerifyBadgeKeepsEnabled` | `showBadge = true`; `stub.enabledResult = true` | `await model.verifyBadgeAuthorization()`; `showBadge == true`; `badgeState == .idle`; `stub.enabledChecks == 1` |
| `testVerifyBadgeSelfOffWhenRevoked` | `showBadge = true`; `stub.enabledResult = false` | `await model.verifyBadgeAuthorization()`; `showBadge == false`; `badgeState == .denied`; `stub.badgeCounts == [0]` |
| `testVerifyBadgeSkippedWhenOff` | `showBadge == false` (default) | `stub.enabledChecks == 0`; `badgeState == .idle` |
| `testStatusLineMatrix` | mutate `env.syncStatus` | `isOffline = true` → `"Offline"`; then `isOffline = false, phase = .syncing` → `"Syncing…"`; `phase = .initialSync` → `"First sync…"`; `phase = .idle, lastError = "Couldn't reach Gmail"` → that string; `lastError = nil` → `"Idle"` |
| `testLastSyncLinePrefersSyncStatus` | `info` loaded with `lastDeltaSyncAtMs = seedNow`; `env.syncStatus.lastSyncAt = Date(timeIntervalSince1970: 1_757_600_000)` | `lastSyncLine == Date(timeIntervalSince1970: 1_757_600_000).formatted(date: .abbreviated, time: .shortened)` |
| `testLastSyncLineFallsBackToSyncState` | `seedSyncState(deltaAtMs: seedNow)`; `lastSyncAt` nil | equals `Date(timeIntervalSince1970: Double(seedNow)/1000).formatted(date: .abbreviated, time: .shortened)` |
| `testVersionLine` | — | `model.versionLine == "0.1.0 (1)"` (matches 01 §5.1 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`) |
| `testFullResyncClearsHistoryIdAndReloads` | `seedSyncState(historyId: "1234530")`; `await model.load()` | `await model.fullResync()`; `try env.db.read { try SyncStateRepository.get($0, .historyId) } == nil`; `model.info.historyId == nil`; `model.isResyncing == false` |
| `testFullResyncIsSingleFlight` | — | two concurrent `async let` calls to `fullResync()` → the second returns without a second `requestFullResync` (asserted through `env.syncStatus.lastRunReason` being set exactly once after a reset, and `isResyncing == false` at the end) |
| `testSignOutIsIdempotent` | — | `await model.signOut()` twice; `env.auth.state == .signedOut`; `model.isSigningOut == false`; no crash (04's `signOut` is a no-op when already signed out) |

16 tests.

### 7.2 `minimailTests/Settings/SignatureEditorModelTests.swift`

Shared helper:

```swift
func makeModel() -> SignatureEditorModel {
    let t = env.theme.resolved(for: .light)
    return SignatureEditorModel(env: env, light: t.cssTokens(for: .light), dark: t.cssTokens(for: .dark), forcedScheme: nil)
}
```

| Test function | Setup | Assertions |
|---|---|---|
| `testLoadCopiesSettings` | `env.settings.update { $0.signatureHTML = "<div>Max</div>" }` | after `load()`: `html == "<div>Max</div>"`; `isDirty == false`; `canSave == false`; `previewDocument.contains("Nothing to preview")` |
| `testPreviewSanitizes` | `html = "<div>Max<script>alert(1)</script></div>"` | after `await refreshPreview()`: `sanitized!.contains("<script") == false`; `sanitized!.contains("Max")`; `error == nil`; `previewDocument.contains(sanitized!)` |
| `testPreviewKeepsHTTPSImage` | `html = "<img src=\"https://www.example.com/logo.png\" alt=\"Example\">"` | `sanitized!.contains("https://www.example.com/logo.png")` (08 §4.5 keeps `https:` in signatures); `warning == nil` |
| `testDataImageWarning` | `html = "<img src=\"data:image/png;base64,iVBORw0KGgo=\">"` | `warning == SettingsStrings.dataImageWarning`; `error == nil`; `canSave == true` (the warning does not block) |
| `testWarningClearsWhenImageRemoved` | as above, then `html = "<div>Max</div>"`; `await refreshPreview()` | `warning == nil` |
| `testOversizeBlocksSave` | `html = String(repeating: "a", count: SignatureEditorModel.maxBytes + 1)` | after `refreshPreview()`: `error == SettingsStrings.signatureTooLarge`; `sanitized == nil`; `canSave == false`; no sanitize attempt (asserted by the call returning in < 50 ms) |
| `testCIDImageLosesSource` | `html = "<img src=\"cid:logo@x\">"` | `sanitized!.contains("cid:") == false` (08 §4.5 step 3) |
| `testSaveWritesSanitizedHTML` | `load()`; `html = "<div>Max<script>x</script></div>"`; `await refreshPreview()` | `await save() == true`; `env.settings.snapshot.signatureHTML == model.sanitized`; `model.html == model.sanitized`; `isDirty == false`; `canSave == false` |
| `testSaveInsideDebounceSanitizesFirst` | `load()`; `html = "<b>Max</b>"` **without** calling `refreshPreview()` | `await save() == true`; `env.settings.snapshot.signatureHTML.contains("Max")`; `sanitized != nil` |
| `testSaveBlockedByError` | `html` over `maxBytes`; `await refreshPreview()` | `await save() == false`; `env.settings.snapshot.signatureHTML == ""` |
| `testIsDirtyRules` | `load()` with stored `"<div>A</div>"` | `isDirty == false`; `html = "<div>B</div>"` → `true`; `html = "<div>A</div>"` → `false` |
| `testImportFromGmail` | `seedSyncState(signature: "<div dir=\"ltr\">Gmail Sig</div>")`; `load()` | `await importFromGmail()`; `html == "<div dir=\"ltr\">Gmail Sig</div>"`; `importState == .imported`; `isDirty == true` |
| `testImportUnavailable` | `seedSyncState(signature: nil)` | `await importFromGmail()`; `importState == .unavailable`; `html` unchanged |
| `testImportBlankIsUnavailable` | `seedSyncState(signature: "\n  \n")` | `importState == .unavailable` |
| `testRefreshPreviewIgnoresStaleResult` | `html = "<div>one</div>"`; start `refreshPreview()` with `async let`, immediately set `html = "<div>two</div>"`, then `await` both | final `sanitized` contains `"two"` and not `"one"` (step 4's `html == source` guard) |

15 tests.

### 7.3 `minimailTests/Settings/SettingsViewsTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testHexRoundTrip` | — | for each of `["#000000", "#ffffff", "#1d1d1f", "#0b5394", "#ff0000", "#123456"]`: `HexColor.hex(HexColor.color(h)) == h` |
| `testHexRejectsInvalid` | — | `HexColor.color("") == HexColor.color("#000000")`; `HexColor.color("#FFF") == HexColor.color("#000000")`; `HexColor.color("#GGGGGG") == HexColor.color("#000000")`; `HexColor.color("#FFFFFF") == HexColor.color("#000000")` (uppercase is invalid per `ComposeStyle.isValidHex`) |
| `testHexIsLowercaseAndAcceptedByComposeStyle` | — | for a `UIColor(red: 1, green: 0.5, blue: 0, alpha: 1)`: `ComposeStyle.isValidHex(HexColor.hex(c))`; the string has no uppercase character |
| `testHexClampsOutOfRangeComponents` | `UIColor(red: 1.4, green: -0.2, blue: 0.5, alpha: 1)` (extended sRGB) | `HexColor.hex(c) == "#ff0080"` |
| `testHexIgnoresAlpha` | `UIColor(red: 0, green: 0, blue: 1, alpha: 0.3)` | `"#0000ff"` |
| `testSignaturePreviewDocumentShape` | `render(signatureHTML: "<div>Max</div>", light: L, dark: D, forcedScheme: "dark")` | starts with `"<!doctype html><html data-theme=\"dark\">"`; contains `SignaturePreviewDocument.csp`; contains `"<body class=\"mm-plain\"><div class=\"mm-body\"><div>Max</div></div></body>"`; contains `ThreadDocument.css(light: L, dark: D)`; does **not** contain `"https:"` inside the CSP meta |
| `testSignaturePreviewDocumentNoForcedScheme` | `forcedScheme: nil` | starts with `"<!doctype html><html><head>"` |
| `testSignaturePreviewDocumentEmpty` | `signatureHTML: "   "` | contains `"Nothing to preview"` |
| `testSignatureSummary` | — | `SignatureSummary.line("") == "Not set"`; `line("<div>Max Mustermann<br>Example GmbH</div>")` == `"Max Mustermann Example GmbH"`; a 60-character text is cut to 40 characters + `"…"`; `line("<img src=\"https://x/y.png\">") == "HTML signature"` |
| `testThemeChoiceDisplayNames` | — | `ThemeChoice.system.displayName == "System"`, `.light == "Light"`, `.dark == "Dark"`; `ThemeChoice.allCases.count == 3` |
| `testSettingsStoreBindingWritesThrough` | `let b = env.settings.binding(\.markReadOnOpen)` | `b.wrappedValue == true`; `b.wrappedValue = false`; `env.settings.snapshot.markReadOnOpen == false`; the value survives a fresh `SettingsStore(defaults: env.defaults)` |
| `testComposeStyleBindingNormalises` | `env.settings.binding(\.composeStyle.sizePx).wrappedValue = 99` | `env.settings.snapshot.composeStyle.sizePx == 18` (clamped by `ComposeStyle`'s `didSet` through `normalized()`) |
| `testSettingsScreenHosts` | `let vc = UIHostingController(rootView: SettingsScreen().environment(env).environment(env.theme).environment(env.settings))`; `vc.loadViewIfNeeded()` | no crash; `vc.view.bounds.size != .zero` after `vc.view.layoutIfNeeded()` |
| `testSignatureEditorScreenHosts` | same pattern with `NavigationStack { SignatureEditorScreen() }` | no crash; the throwaway web view is created and released when the controller is deallocated (asserted with a `weak var` to `env.webHost` staying non-nil and no `XCTAssert` on the pooled instance's `url`) |
| `testRequestLogScreenHosts` (DEBUG only) | `env.requestLog?.record(method: "GET", path: "profile", status: 200, ms: 12)`; host `NavigationStack { RequestLogScreen() }` | no crash; `env.requestLog?.snapshot().count == 1` |
| `testPlaceholderStructRemoved` | — | `FileManager.default.fileExists(atPath: …/InboxPlaceholders.swift) == false` is **not** asserted (the file is outside the test bundle); instead: `String(describing: SettingsScreen.self) == "SettingsScreen"` and a compile-time reference `let _: SettingsScreen = SettingsScreen()` in the module that owns it — the real check is the grep in §9 item 5 |

16 tests (15 in Release, where `testRequestLogScreenHosts` is compiled out).

### 7.4 `minimailTests/Inbox/InboxViewsTests.swift` (modify)

`testPlaceholderSignatures` (09 §7.2) currently hosts the four placeholders. Replace the `SettingsScreen` line with:

```swift
let settings = UIHostingController(
    rootView: SettingsScreen().environment(env).environment(env.theme).environment(env.settings))
settings.loadViewIfNeeded()
```

(the placeholder needed no environment; the real screen reads `AppEnvironment`, `ThemeStore` and `SettingsStore` in its body). The three other lines stay as modules 10–12 left them.

### 7.5 Running them

```
make test-one T=minimailTests/SettingsModelTests
make test-one T=minimailTests/SignatureEditorModelTests
make test-one T=minimailTests/SettingsViewsTests
make test-app                       # whole suite, then the xcresult summary
make core-test                      # unchanged: this module adds no package test
```

---

## 8. Tasks

- [ ] **T13.1 `SettingsModel` value types and pure helpers** — files: `minimail/Features/Settings/SettingsModel.swift` (`SettingsAdvancedInfo`, `BadgeAuthorizing`, `SystemBadgeAuthorizer`, `HexColor`, `SettingsStrings`), `minimailTests/Settings/SettingsViewsTests.swift` (`testHexRoundTrip`, `testHexRejectsInvalid`, `testHexIsLowercaseAndAcceptedByComposeStyle`, `testHexClampsOutOfRangeComponents`, `testHexIgnoresAlpha`). Done when the five tests pass and every produced hex satisfies `ComposeStyle.isValidHex`. Verify: `make test-one T=minimailTests/SettingsViewsTests`. (~140 lines)

- [ ] **T13.2 `SettingsModel` behaviour** — files: `minimail/Features/Settings/SettingsModel.swift` (`SettingsModel`: `init`, `load`, `setBadgeEnabled`, `verifyBadgeAuthorization`, `signOut`, `fullResync`, the four derived strings), `minimailTests/Settings/SettingsModelTests.swift` (`StubBadgeAuthorizer`, `seedSyncState`, all 16 tests of §7.1). Done when all 16 pass and `InvariantChecks.assertAll` holds after the seeded-outbox test. Verify: `make test-one T=minimailTests/SettingsModelTests`. (~230 lines)

- [ ] **T13.3 `SettingsScreen` — Account, Appearance, Compose** — files: `minimail/Features/Settings/SettingsScreen.swift` (`SettingsScreen` skeleton, `SettingsRoute`, `SettingsStore.binding(_:)`, `ThemeChoice.displayName`, `SettingsAccountSection`, `SettingsAppearanceSection`, `SettingsComposeSection`, `composeColorBinding`), `minimailTests/Settings/SettingsViewsTests.swift` (+`testThemeChoiceDisplayNames`, `testSettingsStoreBindingWritesThrough`, `testComposeStyleBindingNormalises`). Done when `make build` succeeds and the three tests pass. Verify: `make build && make test-one T=minimailTests/SettingsViewsTests`. (~200 lines)

- [ ] **T13.4 `SettingsScreen` — Reading, Notifications, Advanced, request log** — files: `minimail/Features/Settings/SettingsScreen.swift` (`SettingsReadingSection`, `SettingsNotificationsSection`, `SettingsAdvancedSection`, both `confirmationDialog`s, `RequestLogScreen` under `#if DEBUG`), `minimailTests/Settings/SettingsViewsTests.swift` (+`testSettingsScreenHosts`, `testRequestLogScreenHosts`). Done when both tests pass and a Release build compiles the `#else` path (`xcodebuild build … -configuration Release`). Verify: `make build && make test-one T=minimailTests/SettingsViewsTests`. (~210 lines)

- [ ] **T13.5 `SignatureEditorModel` + preview document** — files: `minimail/Features/Settings/SignatureEditorModel.swift` (`SignatureImportState`, `SignaturePreviewDocument`, `SignatureSummary`, `SignatureEditorModel` with `load`, `refreshPreview`, `save`, `importFromGmail`, `isDirty`, `canSave`, `message(for:)`), `minimailTests/Settings/SignatureEditorModelTests.swift` (all 15 tests of §7.2), `minimailTests/Settings/SettingsViewsTests.swift` (+`testSignaturePreviewDocumentShape`, `testSignaturePreviewDocumentNoForcedScheme`, `testSignaturePreviewDocumentEmpty`, `testSignatureSummary`). Done when all 19 pass and the sanitize call runs off the main actor (asserted implicitly: the tests `await` it). Verify: `make test-one T=minimailTests/SignatureEditorModelTests && make test-one T=minimailTests/SettingsViewsTests`. (~260 lines)

- [ ] **T13.6 `SignatureEditorScreen` + throwaway preview** — files: `minimail/Features/Settings/SignatureEditorScreen.swift` (`SignatureEditorScreen`, `SignaturePreviewView`, the two footers, the import dialog, the debounced `.task(id:)`), `minimailTests/Settings/SettingsViewsTests.swift` (+`testSignatureEditorScreenHosts`). Done when the test passes, the editor pushes and pops inside `SettingsScreen`'s stack, and `grep -rn "WebViewHost.webView\|MailWebView" minimail/Features/Settings` prints nothing (only `makeThrowawayWebView` is used). Verify: `make build && make test-one T=minimailTests/SettingsViewsTests`. (~180 lines)

- [ ] **T13.7 Placeholder removal** — files: `minimail/Features/Inbox/InboxPlaceholders.swift` (delete `struct SettingsScreen`; delete the file when it holds no other declaration), `minimailTests/Inbox/InboxViewsTests.swift` (the `testPlaceholderSignatures` line of §7.4). Done when `grep -rn "struct SettingsScreen" minimail | grep -v "minimail/Features/Settings/SettingsScreen.swift"` prints nothing and 09's view tests still pass. Verify: `make build && make test-one T=minimailTests/InboxViewsTests`. (~30 lines)

- [ ] **T13.8 Lint, full suite, device checklist entries** — files: none (or whitespace fixes from `make format`); append the four manual items of §9 to `docs/plan/device-checklist.md` if module 14 has already created it, otherwise hand them to 14. Done when `make lint` is clean, `make test-app` reports `failedTests: 0`, and `make core-test` is unchanged. Verify: `make lint && make test-app && make core-test`. (~20 lines)

---

## 9. Acceptance criteria

1. `make build` succeeds with `SWIFT_VERSION = 6` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, in Debug **and** Release (the Release build proves the `#if DEBUG` request-log branch compiles both ways). Verify: `make build && xcodebuild build -project minimail.xcodeproj -scheme minimail -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO`.
2. All 47 tests of §7 pass and the whole app suite stays green. Verify: `make test-app`, then `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact` shows `failedTests: 0`.
3. Every section of architecture §11 exists with the documented control: Account (email + Sign Out), Appearance (Theme), Compose (Font, Size, Text Color, Signature, Use Signature), Reading (2 toggles), Notifications (badge), Advanced (status, last sync, history id, pending, failed, Full Resync Now, DEBUG Recent Requests, Version). Verify: `grep -c "accessibilityIdentifier(\"settings\." minimail/Features/Settings/SettingsScreen.swift` ≥ 19, and `testSettingsScreenHosts`.
4. A colour chosen in the `ColorPicker` round-trips into `Settings.composeStyle.colorHex` in the exact form `MIMEBuilder` will emit (`^#[0-9a-f]{6}$`). Verify: `testHexRoundTrip`, `testHexIsLowercaseAndAcceptedByComposeStyle`.
5. The interim placeholder is gone and nothing else declares the screen. Verify: `grep -rn "struct SettingsScreen" minimail | grep -v "minimail/Features/Settings/SettingsScreen.swift"` prints nothing.
6. The signature is sanitized exactly once, on save, and the stored value is what the preview showed. Verify: `testSaveWritesSanitizedHTML`, `testSaveInsideDebounceSanitizesFirst`.
7. The preview cannot reach the network: the document's CSP has no `https:` in `img-src`, and the instance is `WebViewHost.makeThrowawayWebView()` (block-all rule list, no cid handler). Verify: `testSignaturePreviewDocumentShape`, plus `grep -n "img-src" minimail/Features/Settings/SignatureEditorModel.swift` showing only `img-src data:`.
8. The badge toggle never persists `true` without a granted `[.badge]` authorization, and switches itself off when authorization is revoked. Verify: `testBadgeToggleOnDenied`, `testVerifyBadgeSelfOffWhenRevoked`.
9. No SQL text, no forbidden import, no raw colour, no timer in this module. Verify: `make lint` and `grep -rnE "SELECT|INSERT|UPDATE |DELETE FROM|Timer\(|import SwiftSoup|import AppAuth" minimail/Features/Settings` prints nothing.
10. Only one `WKWebView` is created by this module, and only while the editor is visible. Verify: `grep -rn "WKWebView\|makeThrowawayWebView" minimail/Features/Settings` shows `makeThrowawayWebView()` exactly once and no `WKWebView(` constructor.
11. **Manual device step** (added to `docs/plan/device-checklist.md` by module 14): on the owner's iPhone with the system in Light mode, open Settings → Appearance → Dark: the whole app including an open thread turns dark within one frame, and the thread document's background matches the list background (this exercises both the `overrideUserInterfaceStyle` path and the `html[data-theme]` fallback of architecture §14 #5).
12. **Manual device step**: Settings → Compose → Signature → "Import from Gmail" pulls the Workspace signature, the preview renders it (hosted images appear as broken/alt text — expected, §5.3), Save → send a reply → the mail that arrives in Gmail carries that signature under a `-- ` prefix and the typed text in the chosen font/size/colour.
13. **Manual device step**: turn the badge toggle on → the iOS prompt appears once → the app icon shows the inbox unread count after the next sync; deny it on a second device (or revoke it in iOS Settings) → reopening Settings shows the toggle off with the explanation footer (architecture §14 #11, UNVERIFIED `[.badge, .provisional]` is not used).
14. **Manual device step**: Advanced → "Full Resync Now" → confirm: the inbox reloads, History ID changes, pending/failed counters stay at 0, and no message the user had cached and still has in the inbox disappears (architecture §4.2 generation resync).

---

## 10. Open questions & assumptions

| # | Item | Status / assumption chosen | Fallback |
|---|---|---|---|
| A1 | `Settings.inboxPageSize` (50…200) and `Settings.lastSignedInEmail` get no control. | decision: architecture §11's screen list names neither; D9 lists "configurable everything" as scope creep | Add one `Picker("Inbox page size", …)` with `[50, 100, 150, 200]` to Advanced — one row, `settings.binding(\.inboxPageSize)`, no other change (07 reads it per run, 07 §10 A19) |
| A2 | `[.badge]`-only authorization grants badging without alerts or sounds; `[.badge, .provisional]` is **UNVERIFIED** (`[ios-platform §6]`, architecture §14 #11) and deliberately not used. | carried forward as UNVERIFIED; the module asks for `[.badge]` only | If `[.badge]` alone turns out not to enable `setBadgeCount`, the toggle stays off and the footer explains it; the device checklist item (§9 #13) is where this is decided |
| A3 | `UIColor.getRed(_:green:blue:alpha:)` on a Display-P3 colour returned by `ColorPicker` yields extended-sRGB components that clamping maps to the visually closest sRGB value. | assumption (clamping is the standard behaviour) | Convert explicitly: `color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil)` and read its components — `HexColor.hex` changes, nothing else does |
| A4 | `.task(id: model?.html)` is a correct debounce: SwiftUI cancels and restarts the task on every `html` change. | assumed (documented `task(id:)` semantics, iOS 15+) | Replace with an explicit `@State private var debounceTask: Task<Void, Never>?` cancelled and recreated in `onChange(of: model.html)` — same 400 ms, five extra lines |
| A5 | `dismiss()` inside a view pushed with `NavigationLink(value:)` pops that view (rather than dismissing the Settings sheet). | assumed (`DismissAction` documentation: "dismisses the current presentation", which for a pushed view is a pop) | Give `SettingsScreen` a `@State private var path: [SettingsRoute]` and have the editor call a `onSaved: () -> Void` closure that does `path.removeLast()` |
| A6 | The signature preview captures `light`/`dark`/`forcedScheme` once at `init`; changing the theme while the editor is open does not re-render the preview document (the web view's `overrideUserInterfaceStyle` still follows). | accepted: the theme picker is one screen back, so the sequence needs deliberate effort | Make the three values `let`s of `SignaturePreviewView` instead and pass `theme.…` on every update, bumping a `revision` — `SignatureEditorModel` then needs a `setTokens(light:dark:forcedScheme:)` |
| A7 | `SignatureSanitizer.sanitize` on a ≤ 64 KB signature completes in well under the 400 ms debounce on an iPhone 12. | assumption (08 §10 A12 measures 500 KB in < 150 ms in Release) | Raise `previewDebounceMs`, or show the previous preview while a new sanitize runs (the model already keeps `sanitized`) |
| A8 | `syncState.sendAsSignature` is present for the owner's account (Workspace signatures are configured in the Gmail web UI, `[gmail-api §15]`). | assumption | `importState = .unavailable` covers the empty case; the owner can paste the HTML by hand |
| A9 | The preview CSP omits `https:` (08 §10 A9 proposes `img-src https: data:`). | **DEVIATION from 08 A9**, chosen for safety: with `https:` in the CSP the only thing stopping a network fetch would be the block-all rule list, which is compiled asynchronously by `WebViewHost.prepare()` and may be absent in a test host or on a first launch. Remote signature images do not render either way (08 A9 says so explicitly) | If the owner wants hosted logos in the preview, add `https:` back **and** `await env.webHost.prepare()` before creating the view, or add a "Load images in preview" toggle (both out of stage-1 scope) |
| A10 | `Quoting.textFromHTML` (02) is a crude tag strip; `SignatureSummary.line` therefore shows plain text without entities for normal signatures and `"HTML signature"` for markup-only ones. | accepted (a summary line, not a rendering) | Use `MailHTMLPackage.textContent(ofHTML:)` (01 §3.3, SwiftSoup) if the crude strip produces visible artefacts — costs a `MailHTML` import in `SignatureEditorModel.swift`, which it already has |
| A11 | `SyncStateRepository.all(_:)` exists (06 §3.15 ADDITION "Settings → Advanced"). | verified in spec 06 | Otherwise six `SyncStateRepository.get` calls inside the same `db.read` — identical result, one extra line each |
| A12 | `AppEnvironment(testing: true)` constructs `webHost` without I/O (08 §4.11), so `SettingsViewsTests` can host the editor. | verified in spec 08 | If the host is created lazily, `testSignatureEditorScreenHosts` calls `await env.webHost.prepare()` in `setUp` |
| A13 | `env.requestLog` is `RequestLog?` and is `nil` in Release (05 §4). The Advanced row is compiled out with `#if DEBUG`, so the optional is only read in Debug. | verified in spec 05 | — |
| A14 | The Account section shows `syncState.accountEmail`, falling back to `AuthStore.State.email`. Right after sign-in and before the first full sync only the latter exists. | design choice | — |
| A15 | Architecture §14 #5 (`overrideUserInterfaceStyle` → `prefers-color-scheme` propagation) stays **UNVERIFIED**; the preview inherits both paths from `ThreadDocument.css` plus the `data-theme` attribute, exactly as the thread view does. | carried forward unchanged | Covered by 08's fallback; no change here |

### Deviations from `architecture.md` / `modules.md`

| # | Deviation | Reason |
|---|---|---|
| D1 | Two extra source files, `Features/Settings/SettingsModel.swift` and `Features/Settings/SignatureEditorModel.swift`; `modules.md` §13 names only `{SettingsScreen,SignatureEditorScreen}.swift`. | Same precedent as 09 (`InboxModel.swift`) and 11 (`ComposeModel.swift`): the badge matrix, the advanced read, the preview pipeline and the strings are unit-testable only outside a `View`, and `SettingsScreen.swift` would otherwise exceed 600 lines. No type moves out of this module's scope. |
| D2 | `BadgeAuthorizing` / `SystemBadgeAuthorizer` wrap `UNUserNotificationCenter`. | Architecture §11 says "`requestAuthorization([.badge])` in context; denied → toggle turns itself off". A test host cannot answer a system prompt, so the three calls are injected. Production behaviour is byte-identical. |
| D3 | `HexColor` (architecture §11 only says "`ColorPicker` bound through hex"). | The conversion needs a defined rounding/clamping rule to keep `ComposeStyle.colorHex`'s `^#[0-9a-f]{6}$` invariant; making it a named pure enum makes it testable. |
| D4 | `SettingsStrings`. | Tests assert the exact user-visible strings; a single constant table prevents drift between the view and the test. |
| D5 | `SettingsStore.binding(_:)` extension (01's store exposes only `settings` (get-only) and `update`). | `Form` controls need `Binding`s. Declaring the extension in 13 keeps `SettingsStore.swift` free of `import SwiftUI` (01 §3.9 imports Foundation + MailCore only). |
| D6 | `ThemeChoice.displayName` extension. | 01's `ThemeChoice` (architecture §10) has no label; the picker needs one and the label is UI text, which belongs to the screen module. |
| D7 | The preview CSP is `img-src data:` instead of 08 §10 A9's `img-src https: data:`. | Defence in depth: the rule list is the only other barrier and it is compiled asynchronously. The observable behaviour (no remote images in the preview) is the one 08 A9 already documents. |
| D8 | `SettingsModel.load()` reads `Queries.outboxCounts` in addition to `SyncStatus.pendingOps` / `.failedSends`. | `SyncStatus`'s counters are maintained by 07 during runs; a sheet opened before the first run of a launch would show zeros. The database is the authority for a diagnostic panel. |
| D9 | A "Done" toolbar button and two `confirmationDialog`s (sign-out, full resync) that architecture §11 does not name. | A sheet needs a dismissal affordance; both confirmed actions are destructive or expensive (account wipe / full re-download). Neither adds state that other modules can observe. |
| D10 | Turning the badge toggle off calls `setBadgeCount(0)` from this module. | Architecture §4.6 clears the badge on sign-out only; `SyncEngine.updateBadge()` is a no-op once `showBadge == false`, so without this call a stale number would stay on the icon forever. |
| D11 | `RequestLogScreen` is a named screen; architecture §11 says only "DEBUG: Recent requests". | A pushed list is the smallest way to show 100 lines; it is compiled out of Release entirely. |
