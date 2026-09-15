# Spec 01 — project-setup: project, tooling, CI, app skeleton

Module id: `01-project-setup`. Depends on: nothing. Consumed by: every other module (02–14).
Source of truth: `docs/plan/design/architecture.md` §0, §1, §2.1, §2.4 (Theme/Settings/AppEnvironment pointers), §5.2 (routing table, informative only here), §6.5, §10, §11, §12.2, §13, §14, Appendix A; `docs/plan/design/modules.md` §01; research `[tooling]`, `[ios-platform]`, `[html-rendering §5.3–5.4]`.

Conventions in this document: paths are relative to the repo root `/home/user/minimail`. "Verbatim" code blocks are copied from architecture.md and must be reproduced byte-for-byte except for whitespace inside Swift files, which `make format` normalises. `DEVIATION:` marks a departure from architecture.md with its reason.

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. A buildable, testable repository skeleton that every later module extends without restructuring:
   - `project.yml` (XcodeGen 2.46.0 spec, complete), `Makefile`, `.gitignore`, `.swift-format`, `ExportOptions.plist`, `Config/Signing.xcconfig`, `Config/Google.xcconfig`, `.github/workflows/ci.yml`.
   - Local SwiftPM package `Packages/MailCore` with the two libraries `MailCore` (Foundation only) and `MailHTML` (SwiftSoup 2.13.9) and their two test targets, each with a `Fixtures/` resource directory. The targets compile with placeholder sources so `swift test` passes on Linux and macOS from day one.
   - App target `minimail` (iOS 17.0, Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) with resources (`AppIcon`, `AccentColor`, `LaunchBackground`, `PrivacyInfo.xcprivacy`), `@main` entry, composition root `AppEnvironment` (strict launch order of §12.2 with `testing:` mode), placeholder `RootView`, `Log`, `Formatters`, the theme system (`Theme`, `ThemeTokens`, `LightTheme`, `DarkTheme`, `ThemeChoice`, `ThemeStore`, `ThemeTokensReader`) and the settings model (`Settings`, `SettingsStore`).
   - Test target `minimailTests` with tests for everything above (run with `xcodebuild test` via `make test-app`).
2. Two small pure types placed in `MailCore` because the app-side types above need them to compile before modules 02 and 08 exist: `ComposeStyle` (needed by `Settings.composeStyle`) and `ThemeCSSTokens` (needed by `Theme.cssTokens(for:)`). See §10 deviations D1 and D2.

### 1.2 Explicitly out of scope

- Any screen other than the placeholder `RootView` (sign-in = 04, inbox = 09, thread = 10, compose = 11, labels = 12, settings screens = 13).
- Network code (`URLSession.minimail`, `GmailClient` = 05), auth (`OAuthConfig`, `Keychain`, `AuthStore`, `AppAuthTokenProvider` = 04), storage (`Database`, schema, records, repositories = 06), sync/outbox/BG refresh/maintenance (07), web view (08).
- `.onOpenURL` wiring in `MinimailApp` (04), scene-phase triggers and `.backgroundTask` (07).
- `Makefile` archive/upload targets, the TestFlight runbook, `docs/plan/device-checklist.md`, `StubURLProtocol`, `TestDatabase`, `InvariantChecks`, `FixtureLoader`, `SmokeTests` (14). This module ships only the `ExportOptions.plist` file.
- Fixture catalog of §13.2 (14) — this module ships one smoke fixture per package test target to prove resource bundling.

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 02–03, 06, 07, 08 (MailCore files) | the package layout, `Package.swift` targets, `Fixtures/` directories, `ComposeStyle`, `ThemeCSSTokens` |
| 04 | `AppEnvironment` (adds `auth`, `tokens`; fills `startDeferredWork`), `RootView` (replaces the placeholder body with the `AuthStore.State` switch), `MinimailApp` (adds `.onOpenURL`), `Settings.lastSignedInEmail`, `Log.auth` |
| 05 | `Log.net`, `Formatters` (none), `Settings` snapshot |
| 06 | `AppEnvironment` (adds `db`, `Database.open` in launch step 1), `Log.db`, `Formatters.bytes` |
| 07 | `AppEnvironment` (adds `sync`, `outbox`, `mailActions`, `status`; launch step 3 hooks), `MinimailApp` (adds `.backgroundTask`, scene-phase), `Settings`/`SettingsStore.snapshot`, `Log.sync`/`.outbox`/`.bg`, signpost intervals |
| 08 | `ThemeStore.forcedDocumentTheme`, `Theme.cssTokens(for:)`, `ThemeCSSTokens`, `ThemeStore.interfaceStyle`, `Log.web`, `Settings.loadRemoteImages` |
| 09–12 | `ThemeTokensReader`/`ThemeTokens` (all colours), `Log.ui`, `Settings.markReadOnOpen`, `Settings.inboxPageSize`, `AppEnvironment` |
| 13 | `Settings`, `SettingsStore.update`, `ThemeStore.choice`, `ThemeChoice.allCases`, `ComposeStyle.Family.allCases`, `ComposeStyle.sizeChoices` |
| 14 | `AppEnvironment(testing: true)`, the scheme environment variable `MINIMAIL_TESTING=1`, the fixture folder copy in `project.yml` |

---

## 2. Files

Every file this module creates. Kind `new` = created by this module; `generated` = produced by a tool, never hand-edited, git-ignored.

| Path | Kind | Purpose |
|---|---|---|
| `project.yml` | new | XcodeGen spec, verbatim architecture §1.4 |
| `Makefile` | new | headless workflow targets, verbatim architecture §1.6 |
| `.gitignore` | new | ignores generated project, build output, result bundles |
| `.swift-format` | new | swift-format configuration (tooling §5.1, one rule changed — §10 D5) |
| `ExportOptions.plist` | new | TestFlight export options (tooling §6.2), used by module 14's archive target |
| `Config/Signing.xcconfig` | new | `DEVELOPMENT_TEAM` placeholder; includes `Google.xcconfig` |
| `Config/Google.xcconfig` | new | `GOOGLE_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID` placeholders |
| `.github/workflows/ci.yml` | new | jobs `core` (ubuntu, `swift test`) and `ios` (macos-26, `xcodebuild test`) |
| `Packages/MailCore/Package.swift` | new | verbatim architecture §1.5 |
| `Packages/MailCore/Sources/MailCore/Compose/ComposeStyle.swift` | new | `ComposeStyle` (§2.2 signature) — D1 |
| `Packages/MailCore/Sources/MailCore/Render/ThemeCSSTokens.swift` | new | `ThemeCSSTokens` (§2.2 signature) — D2 |
| `Packages/MailCore/Sources/MailHTML/MailHTMLPackage.swift` | new | placeholder proving `MailHTML` links `MailCore` + `SwiftSoup`; module 08 may delete it |
| `Packages/MailCore/Tests/MailCoreTests/ComposeStyleTests.swift` | new | clamp / hex / CSS / Codable tests |
| `Packages/MailCore/Tests/MailCoreTests/PackageSmokeTests.swift` | new | `ThemeCSSTokens` equality + `Bundle.module` fixture load |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/smoke.json` | new | smoke fixture `{"ok":true}` |
| `Packages/MailCore/Tests/MailHTMLTests/PackageSmokeTests.swift` | new | SwiftSoup parse + fixture load |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/smoke.html` | new | smoke fixture |
| `minimail/App/MinimailApp.swift` | new | `@main`, one `WindowGroup`, environment injection |
| `minimail/App/AppEnvironment.swift` | new | composition root, launch order, `testing:` mode |
| `minimail/App/RootView.swift` | new | placeholder root; applies theme modifiers; starts deferred work |
| `minimail/Support/Log.swift` | new | `os.Logger` categories + `OSSignposter` intervals |
| `minimail/Support/Formatters.swift` | new | byte-count formatting |
| `minimail/Theme/Theme.swift` | new | `ThemeTokens`, `Theme`, `LightTheme`, `DarkTheme`, `ThemeChoice`, `SystemPalette`, `ThemeTokensReader` |
| `minimail/Theme/ThemeStore.swift` | new | `ThemeStore` |
| `minimail/Features/Settings/Settings.swift` | new | `Settings` Codable struct |
| `minimail/Features/Settings/SettingsStore.swift` | new | `SettingsStore` |
| `minimail/Resources/Assets.xcassets/Contents.json` | new | catalog root |
| `minimail/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` | new | single 1024×1024 icon entry |
| `minimail/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | new | 1024×1024 RGB PNG generated by the command in §5.9 |
| `minimail/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` | new | light `#007aff`, dark `#0a84ff` |
| `minimail/Resources/Assets.xcassets/LaunchBackground.colorset/Contents.json` | new | light `#ffffff`, dark `#000000` |
| `minimail/Resources/PrivacyInfo.xcprivacy` | new | `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` |
| `minimailTests/App/AppEnvironmentTests.swift` | new | init, testing mode, root view hosting |
| `minimailTests/App/BundleConfigTests.swift` | new | Info.plist keys, assets, privacy manifest present in the built app |
| `minimailTests/App/LogAndFormattersTests.swift` | new | logger categories, signpost intervals, byte formatting |
| `minimailTests/Theme/ThemeStoreTests.swift` | new | resolution, persistence, CSS hex tokens |
| `minimailTests/Settings/SettingsStoreTests.swift` | new | defaults, round trip, tolerant decode, clamps, sorted keys |
| `minimail.xcodeproj/` | generated | `xcodegen generate`; git-ignored |
| `minimail/Info.plist` | generated | from `project.yml` `info.properties`; git-ignored |
| `minimail/minimail.entitlements` | generated | empty; git-ignored |
| `Packages/MailCore/Package.resolved` | generated | written by `swift test`; committed (exact pin, deterministic) |

Directories that must exist and be non-empty in git (git does not track empty directories): `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/` (holds `smoke.json`), `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/` (holds `smoke.html`).

Files listed in architecture §1.3 that this module does NOT create (owned elsewhere): everything under `minimail/Auth`, `minimail/Gmail`, `minimail/Store`, `minimail/Sync`, `minimail/Web`, `minimail/Features/{SignIn,Inbox,Thread,Compose,Labels}`, `minimail/Features/Settings/{SettingsScreen,SignatureEditorScreen}.swift`, `minimail/App/{BackgroundRefresh,Maintenance}.swift`, `minimailTests/Support/*`, and the package sources of modules 02, 03, 06, 07, 08.

---

## 3. Public interface

All app-target declarations are `internal` (single module; no `public`). Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` every unannotated app declaration is `@MainActor`; declarations that actors or package code must reach are marked `nonisolated` explicitly. Package declarations are `public` and nonisolated (package default).

### 3.1 `MailCore` — `Compose/ComposeStyle.swift` (DEVIATION D1: file moved from module 02 to 01)

Signature verbatim from architecture §2.2, plus two additive constants (`sizeRange`, `sizeChoices`) used by module 13's picker.

```swift
import Foundation

/// Default font family, size and colour applied to outgoing mail (§7.5). Stored inside `Settings.composeStyle`.
/// Invariants (enforced on every mutation and on decode): `sizePx ∈ sizeRange`; `colorHex` matches `^#[0-9a-f]{6}$`.
public struct ComposeStyle: Codable, Equatable, Sendable {
    /// Web-safe font stacks [html-rendering §5.3]; `-apple-system`/`system-ui` deliberately excluded.
    public enum Family: String, Codable, CaseIterable, Sendable {
        case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        /// CSS `font-family` value, e.g. "Helvetica, Arial, sans-serif".
        public var css: String { get }
        /// Human name for pickers, e.g. "Helvetica".
        public var displayName: String { get }
    }
    /// Inclusive size bounds in CSS px.
    public static let sizeRange: ClosedRange<Int> = 12...18
    /// Sizes offered by the Settings picker [html-rendering §5.3].
    public static let sizeChoices: [Int] = [12, 13, 14, 15, 16, 18]

    public var family: Family = .helvetica
    /// Clamped into `sizeRange` by a property observer; decoding also clamps.
    public var sizePx: Int = 14 { didSet }
    /// Lowercased on set; a value not matching `^#[0-9a-f]{6}$` is replaced by "#000000".
    public var colorHex: String = "#000000" { didSet }
    /// "font-family:{family.css};font-size:{sizePx}px;color:{colorHex}" — no trailing semicolon, no spaces.
    public var inlineCSS: String { get }
    /// True iff `s` is 7 characters, starts with "#", and the remaining 6 are in [0-9a-f] (lowercase only).
    public static func isValidHex(_ s: String) -> Bool
    public init()
    /// Tolerant decoding: every key optional (`decodeIfPresent`), unknown `family` raw value → `.helvetica`, then clamp/validate.
    public init(from decoder: any Decoder) throws
    // encode(to:) is synthesized: keys "family", "sizePx", "colorHex".
}
```

### 3.2 `MailCore` — `Render/ThemeCSSTokens.swift` (DEVIATION D2: struct split out of `Render/ThreadDocument.swift`)

Verbatim field list from architecture §2.2 (`ThemeCSSTokens`), with the memberwise initializer made public.

```swift
import Foundation

/// Hex colour strings ("#rrggbb", lowercase) resolved by the app per colour scheme; consumed by `ThreadDocument.render` (module 08).
public struct ThemeCSSTokens: Sendable, Equatable {
    public var background, surface, text, secondaryText, accent, separator, link, cardBackground: String
    public init(background: String, surface: String, text: String, secondaryText: String,
                accent: String, separator: String, link: String, cardBackground: String)
}
```

### 3.3 `MailHTML` — `MailHTMLPackage.swift` (placeholder; module 08 may delete it once `Sanitizer.swift` exists)

```swift
import Foundation
import MailCore
import SwiftSoup

/// Proves the `MailHTML` target links `MailCore` and `SwiftSoup`. Not used by the app.
public enum MailHTMLPackage {
    public static let name = "MailHTML"
    /// `SwiftSoup.parse(html).text()`; rethrows SwiftSoup errors.
    public static func textContent(ofHTML html: String) throws -> String
}
```

### 3.4 App — `Support/Log.swift`

Architecture §6.5 verbatim categories and interval names.

```swift
import Foundation
import os

/// Logger categories and signpost intervals. `nonisolated` so actors (04, 05, 07) and reader closures (06) can log.
nonisolated enum Log {
    static let subsystem = "com.minimail"
    static let auth   = Logger(subsystem: subsystem, category: "auth")
    static let net    = Logger(subsystem: subsystem, category: "net")
    static let sync   = Logger(subsystem: subsystem, category: "sync")
    static let outbox = Logger(subsystem: subsystem, category: "outbox")
    static let db     = Logger(subsystem: subsystem, category: "db")
    static let web    = Logger(subsystem: subsystem, category: "web")
    static let ui     = Logger(subsystem: subsystem, category: "ui")
    static let bg     = Logger(subsystem: subsystem, category: "bg")
    /// Signposter for the intervals below; category `.pointsOfInterest` so Instruments shows them without configuration.
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// The eight intervals of architecture §6.5. `name` is the `StaticString` passed to `beginInterval`.
    enum Interval: String, CaseIterable, Sendable {
        case coldStartToList, fullSync, deltaSync, hydrateBatch, threadOpen, bodyLoad, documentLoad, outboxDrain
        var name: StaticString { get }      // switch → literal with the same spelling as the case
    }
    /// Begins an interval with a fresh `OSSignpostID` (intervals of the same name may overlap).
    static func begin(_ interval: Interval) -> OSSignpostIntervalState
    /// Ends `state` for `interval`. Ending twice is a programmer error (OSSignposter asserts in Debug).
    static func end(_ interval: Interval, _ state: OSSignpostIntervalState)
    /// begin → body → end (also on throw).
    static func measure<T>(_ interval: Interval, _ body: () throws -> T) rethrows -> T
    /// Async variant; the interval spans suspensions.
    static func measure<T>(_ interval: Interval, _ body: () async throws -> T) async rethrows -> T
}
```

Logging rules for every module (copied from §6.5 so implementers of later modules read them here): method + path + status + ms at `.debug`; retries/recoveries at `.notice`; failures at `.error` with the `GmailError` description; ids `%{public}`, addresses/subjects/snippets `%{private}`; never tokens, headers, bodies.

### 3.5 App — `Support/Formatters.swift`

```swift
import Foundation

/// Locale-aware formatting helpers that must work off the main actor (called from `Queries` on GRDB reader threads).
nonisolated enum Formatters {
    /// `ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)` — e.g. "1.5 MB", "Zero KB" for 0.
    /// Negative counts are treated as 0.
    static func bytes(_ count: Int) -> String
}
```

### 3.6 App — `Theme/Theme.swift`

`ThemeTokens`, `Theme`, `LightTheme`, `DarkTheme`, `ThemeTokens.system`, `ThemeChoice` verbatim from architecture §10; `SystemPalette` and `ThemeTokensReader` are this spec's implementation of "hex via `UIColor.resolvedColor`" and the "`themeTokens` view helper".

```swift
import MailCore
import SwiftUI
import UIKit

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
// Both `cssTokens(for:)` implementations return `SystemPalette.cssTokens(for: scheme)` (stock themes = system colours).

extension ThemeTokens {   // stock themes = system semantic colours (adapt to Increase Contrast and Smart Invert automatically)
    static let system = ThemeTokens(background: Color(.systemBackground), groupedBackground: Color(.systemGroupedBackground), surface: Color(.secondarySystemBackground),
        text: Color(.label), secondaryText: Color(.secondaryLabel), accent: Color(.tintColor), unread: Color(.systemBlue), separator: Color(.separator),
        link: Color(.link), chipBackground: Color(.tertiarySystemFill), swipeArchive: Color(.systemIndigo), swipeRead: Color(.systemBlue))
}

/// Persisted user choice. `nonisolated` because it is a field of the `Sendable` `Settings` struct read by actors.
nonisolated enum ThemeChoice: String, Codable, CaseIterable, Sendable { case system, light, dark }

/// Resolves UIKit semantic colours to CSS hex per scheme (§10 "hex only for the web template's CSS variables").
enum SystemPalette {
    /// "#rrggbb" (lowercase) of `color` resolved for `scheme`; colours with alpha < 1 are composited over `background` (same scheme). Components clamped to 0…1, rounded to the nearest byte.
    static func hex(_ color: UIColor, scheme: ColorScheme, over background: UIColor = .systemBackground) -> String
    /// Mapping (see §4.6): background←systemBackground, surface←secondarySystemBackground, text←label, secondaryText←secondaryLabel,
    /// accent←UIColor(named:"AccentColor") ?? .systemBlue, separator←separator, link←link, cardBackground←systemBackground resolved for `.light` regardless of `scheme`.
    static func cssTokens(for scheme: ColorScheme) -> ThemeCSSTokens
}

/// The "themeTokens view helper" of §10: `@ThemeTokensReader private var themeTokens` inside a `View` yields the tokens of
/// `ThemeStore.resolved(for: colorScheme)`. Views never use raw colours (`make lint`).
@propertyWrapper
struct ThemeTokensReader: DynamicProperty {
    @Environment(ThemeStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    var wrappedValue: ThemeTokens { store.resolved(for: colorScheme).tokens }
    init()
}
```

### 3.7 App — `Theme/ThemeStore.swift`

Verbatim from architecture §10 with the initializer and the static theme instances made explicit.

```swift
import SwiftUI
import UIKit

@Observable final class ThemeStore {
    static let light: any Theme = LightTheme()
    static let dark: any Theme = DarkTheme()
    static let registry: [String: any Theme] = ["light": light, "dark": dark]   // add a theme = one struct + one entry

    /// Persisted through `SettingsStore` on every change (`didSet` → `settings.update { $0.themeChoice = choice }`).
    var choice: ThemeChoice { didSet }
    /// Reads the initial `choice` from `settings.settings.themeChoice`; keeps a strong reference to `settings`.
    init(settings: SettingsStore)
    /// `.system` → `registry["light"|"dark"]` by `systemScheme`; `.light` → `light`; `.dark` → `dark` (ignores `systemScheme`).
    func resolved(for systemScheme: ColorScheme) -> any Theme
    var preferredColorScheme: ColorScheme? { choice == .system ? nil : resolved(for: .light).colorScheme }
    var forcedDocumentTheme: String? { preferredColorScheme.map { $0 == .dark ? "dark" : "light" } }   // html[data-theme]
    /// `.unspecified` for `.system`, `.light` / `.dark` otherwise — for `overrideUserInterfaceStyle` and UIWindow chrome.
    var interfaceStyle: UIUserInterfaceStyle { get }
}
```

### 3.8 App — `Features/Settings/Settings.swift`

Verbatim from architecture §11 (fields, defaults) plus tolerant decoding and normalisation.

```swift
import Foundation
import MailCore

/// One Codable struct in UserDefaults (decision 14). `nonisolated` + `Sendable`: actors receive copies via `SettingsStore.snapshot`.
nonisolated struct Settings: Codable, Equatable, Sendable {
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

    static let inboxPageSizeRange: ClosedRange<Int> = 50...200

    init()
    /// Tolerant: every key `decodeIfPresent`; an unknown `themeChoice` raw value → `.system`; a failing nested `composeStyle` → `ComposeStyle()`; then `normalized()`.
    init(from decoder: any Decoder) throws
    /// `schemaVersion = 1`; `inboxPageSize` clamped into `inboxPageSizeRange`; `composeStyle` re-assigned to itself so its observers run; `lastSignedInEmail` trimmed of whitespace and set to nil if empty.
    func normalized() -> Settings
    // encode(to:) synthesized; CodingKeys = property names; nil `lastSignedInEmail` is omitted.
}
```

### 3.9 App — `Features/Settings/SettingsStore.swift`

Verbatim from architecture §11.

```swift
import Foundation
import MailCore

@Observable final class SettingsStore {
    static let key = "com.minimail.settings"
    private(set) var settings: Settings
    /// One `UserDefaults.data(forKey:)` + JSON decode. Missing key → `Settings()`. Decode failure → `Settings()` + `Log.ui.error` (data length logged, never content).
    init(defaults: UserDefaults = .standard)
    /// Applies `change` to a copy, normalises it, assigns `settings` (one observation change) and writes synchronously:
    /// `JSONEncoder` with `.sortedKeys` → `defaults.set(data, forKey: Self.key)`. Encoding failure → `Log.ui.error`, in-memory value still updated.
    func update(_ change: (inout Settings) -> Void)
    /// Sendable copy for actors.
    var snapshot: Settings { settings }
    /// The defaults instance this store writes to (tests read it back).
    let defaults: UserDefaults
}
```

### 3.10 App — `App/AppEnvironment.swift`

Composition root (decision 10, §12.2). In this module it owns `settings` and `theme`; modules 04, 06, 07, 08 add their objects at the marked insertion points **in the order given** (the launch order is a contract).

```swift
import Foundation
import SwiftUI

/// Composition root. `@MainActor` (implicit). Exactly one instance per process, created in `MinimailApp.init`.
@Observable final class AppEnvironment {
    /// `true` when `MINIMAIL_TESTING=1` is in the process environment (scheme sets it for every `xcodebuild test` host launch) or when passed explicitly.
    let isTesting: Bool
    /// `.standard`, or the suite "com.minimail.testing" wiped at init when `isTesting`.
    let defaults: UserDefaults
    let settings: SettingsStore
    let theme: ThemeStore
    /// Signpost state of `Log.Interval.coldStartToList`, begun in `init`; ended once by `markFirstListPaint()`.
    private var coldStart: OSSignpostIntervalState?
    /// Set by `startDeferredWork()`; guarantees the deferred work runs once per process.
    private(set) var deferredWorkStarted = false

    static var isTestingProcess: Bool { ProcessInfo.processInfo.environment["MINIMAIL_TESTING"] == "1" }

    /// Launch step 1 of §12.2 — synchronous, budget < 15 ms:
    ///   1. `SettingsStore(defaults:)`  (one UserDefaults JSON decode)
    ///   2. [06 inserts here] `Database.open(directory:)` (or `openInMemory()` when `isTesting`)
    ///   3. [04 inserts here] `Keychain.exists("oauth.authState")`, `syncState.accountEmail` read, `AuthStore(...)`
    ///   4. `ThemeStore(settings:)`
    ///   5. [05/07/08 insert their actors/hosts here — construction only, no I/O]
    /// Forbidden in `init`: AppAuth, network, `WKWebView`, `UNUserNotificationCenter`, `BGTaskScheduler`, NotificationCenter observers.
    init(testing: Bool = AppEnvironment.isTestingProcess)

    /// Launch step 3 of §12.2, called from `RootView.task`. Idempotent. Yields to the run loop twice (`await Task.yield()` ×2) so the
    /// first frame is on screen, then runs the hooks in this order (each a marked insertion point):
    ///   a. [04] `await tokens.load()`
    ///   b. [07] `OutboxRepository.releaseInFlight` (via a write) → `await sync.run(.launch)`
    ///   c. +1 s (`try? await Task.sleep(for: .seconds(1))`): [08] `await webHost.prepare()`
    ///   d. +2 s: [07] `BackgroundRefresh.schedule()`, `await Maintenance.cleanup(db, now:)`, `await sync.updateBadge()`
    /// In this module the body performs the two yields and the two sleeps only; when `isTesting` it returns right after the yields (no sleeps).
    func startDeferredWork() async

    /// Ends the `coldStartToList` interval the first time it is called; later calls are no-ops. Module 09 calls it when the first rows are laid out.
    func markFirstListPaint()
}
```

### 3.11 App — `App/RootView.swift`

```swift
import SwiftUI

/// Root of the window. Applies the theme modifiers of §10 and starts the deferred launch work. Module 04 replaces the placeholder body
/// with `switch env.auth.state { case .signedOut: SignInScreen(); case .signedIn, .needsReauth: NavigationStack { InboxScreen(scope:) } }` (09 supplies `InboxScreen`).
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View   // RootPlaceholderView() .preferredColorScheme(env.theme.preferredColorScheme) .tint(themeTokens.accent) .task { await env.startDeferredWork() }
}

/// Stage-1 placeholder shown until module 04 lands. Uses theme tokens only.
struct RootPlaceholderView: View {
    @ThemeTokensReader private var themeTokens
    var body: some View   // see §6
}
```

### 3.12 App — `App/MinimailApp.swift`

```swift
import SwiftUI

@main
struct MinimailApp: App {
    /// Created synchronously in `App.init` (launch step 1).
    @State private var env = AppEnvironment()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.theme)
                .environment(env.settings)
        }
        // Module 04 adds `.onOpenURL { env.auth.resume(url: $0) }` inside the WindowGroup content.
        // Module 07 adds `.backgroundTask(.appRefresh(BackgroundRefresh.taskID)) { await BackgroundRefresh.run(env) }` and `.onChange(of: scenePhase)`.
    }
}
```

---

## 4. Behaviour

### 4.1 `ComposeStyle`

`Family.css` table (exact strings, `[html-rendering §5.3]`):

| case | `css` | `displayName` |
|---|---|---|
| helvetica | `Helvetica, Arial, sans-serif` | `Helvetica` |
| arial | `Arial, Helvetica, sans-serif` | `Arial` |
| verdana | `Verdana, Geneva, sans-serif` | `Verdana` |
| tahoma | `Tahoma, Geneva, sans-serif` | `Tahoma` |
| trebuchet | `'Trebuchet MS', Helvetica, sans-serif` | `Trebuchet MS` |
| georgia | `Georgia, 'Times New Roman', serif` | `Georgia` |
| times | `'Times New Roman', Times, serif` | `Times New Roman` |
| courier | `'Courier New', Courier, monospace` | `Courier New` |

Property observers:

```swift
public var sizePx: Int = 14 {
    didSet { if !Self.sizeRange.contains(sizePx) { sizePx = min(max(sizePx, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) } }
}
public var colorHex: String = "#000000" {
    didSet { let l = colorHex.lowercased(); colorHex = Self.isValidHex(l) ? l : "#000000" }
}
```
Re-assignment inside `didSet` does not re-trigger the observer (Swift semantics), so the guard `if` is only an optimisation.

`isValidHex(_ s:)`: `s.utf8.count == 7`, `s.first == "#"`, every remaining scalar in `"0123456789abcdef"`. Uppercase input is invalid for `isValidHex` (the setter lowercases first).

`init(from:)`:
1. `let c = try decoder.container(keyedBy: CodingKeys.self)`.
2. `self.init()`.
3. `if let raw = try c.decodeIfPresent(String.self, forKey: .family), let f = Family(rawValue: raw) { family = f }`.
4. `if let n = try c.decodeIfPresent(Int.self, forKey: .sizePx) { sizePx = n }` (observer clamps).
5. `if let h = try c.decodeIfPresent(String.self, forKey: .colorHex) { colorHex = h }` (observer validates).
6. A type mismatch (e.g. `"sizePx": "big"`) throws `DecodingError` — callers (`Settings.init(from:)`) catch and substitute `ComposeStyle()`.

`inlineCSS` example for defaults: `font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000`.

### 4.2 `ThemeCSSTokens`, `MailHTMLPackage`

Pure data / trivial wrapper; no behaviour beyond the signatures. `MailHTMLPackage.textContent(ofHTML: "<p>Hi <b>there</b></p>")` returns `"Hi there"`.

### 4.3 `Log`

- `Interval.name`: `switch self { case .coldStartToList: return "coldStartToList" … }` — each literal a `StaticString` spelled exactly like the case.
- `begin`: `signposter.beginInterval(interval.name, id: signposter.makeSignpostID())`.
- `end`: `signposter.endInterval(interval.name, state)`.
- `measure` (sync): `let s = begin(i); defer { end(i, s) }; return try body()`.
- `measure` (async): same with `try await body()`.
- If `OSSignposter.isEnabled` is false (no Instruments/log stream attached) the calls are cheap no-ops per Apple's implementation; no guard needed.
- Concurrency: `Logger` and `OSSignposter` are `Sendable`; the statics are `nonisolated`. If the compiler rejects a static as "not concurrency-safe", annotate that static `nonisolated(unsafe)` (both types are documented thread-safe).

### 4.4 `Formatters.bytes`

`ByteCountFormatter.string(fromByteCount: Int64(max(count, 0)), countStyle: .file)`. Class method, thread-safe, locale-aware (`"1.5 MB"` in en_US, `"1,5 MB"` in de_DE).

### 4.5 `ThemeStore`

| Operation | Behaviour |
|---|---|
| `init(settings:)` | `self.settings = settings; choice = settings.settings.themeChoice` (observer does not fire during init). |
| `choice` set | `didSet { settings.update { $0.themeChoice = choice } }` — also fires when the same value is assigned (harmless extra write). |
| `resolved(for: s)` | `.system` → `s == .dark ? Self.dark : Self.light`; `.light` → `Self.light`; `.dark` → `Self.dark`. |
| `preferredColorScheme` | `nil` / `.light` / `.dark`. |
| `forcedDocumentTheme` | `nil` / `"light"` / `"dark"`. |
| `interfaceStyle` | `.unspecified` / `.light` / `.dark`. |

Adding a theme later: one `struct X: Theme` + one `registry` entry; `ThemeChoice` gains `.custom(id)` later; nothing in the views changes (§10).

### 4.6 `SystemPalette`

`hex(color, scheme:, over:)`:
1. `let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)`.
2. `let fg = color.resolvedColor(with: traits)`, `let bg = background.resolvedColor(with: traits)`.
3. Read `(r, g, b, a)` from `fg` with `getRed(_:green:blue:alpha:)`; if it returns `false`, read `getWhite(_:alpha:)` and set `r = g = b = white`. Same for `bg` (ignore its alpha).
4. If `a < 1`: `r = a*r + (1-a)*bg.r` (same for g, b).
5. `byte(v) = Int((min(max(v, 0), 1) * 255).rounded())`; return `String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))`.

`cssTokens(for: scheme)`:

| field | UIColor | note |
|---|---|---|
| background | `.systemBackground` | light `#ffffff`, dark `#000000` |
| surface | `.secondarySystemBackground` | |
| text | `.label` | light `#000000`, dark `#ffffff` |
| secondaryText | `.secondaryLabel` | alpha 0.6 → composited over background |
| accent | `UIColor(named: "AccentColor", in: .main, compatibleWith: nil) ?? .systemBlue` | light `#007aff`, dark `#0a84ff` from the asset in §5.10 |
| separator | `.separator` | alpha → composited |
| link | `.link` | |
| cardBackground | `.systemBackground` resolved with `.light` **always** | the `mm-card` strategy renders a white card in dark mode (§9.5) → `#ffffff` for both schemes |

### 4.7 `ThemeTokensReader`

A `DynamicProperty` whose nested `@Environment` wrappers SwiftUI updates automatically. Requires `ThemeStore` in the environment (`MinimailApp` injects it); a view rendered without it crashes with SwiftUI's standard "No Observable object of type ThemeStore found" — tests must inject it (`.environment(env.theme)`).

### 4.8 `Settings`

`init(from:)`:
1. `self.init()`; `let c = try decoder.container(keyedBy: CodingKeys.self)`.
2. For each field: `if let v = try c.decodeIfPresent(T.self, forKey: .x) { x = v }` — `schemaVersion`, `signatureHTML`, `signatureEnabled`, `loadRemoteImages`, `markReadOnOpen`, `showBadge`, `inboxPageSize`, `lastSignedInEmail`.
3. `themeChoice`: `if let raw = try c.decodeIfPresent(String.self, forKey: .themeChoice), let t = ThemeChoice(rawValue: raw) { themeChoice = t }`.
4. `composeStyle`: `if let cs = try? c.decodeIfPresent(ComposeStyle.self, forKey: .composeStyle) { composeStyle = cs }` (a malformed nested object falls back to the default instead of failing the whole decode).
5. A type mismatch on a scalar field (e.g. `"markReadOnOpen": "yes"`) throws → `SettingsStore` falls back to `Settings()` and logs.
6. `self = normalized()`.

`normalized()`: copy; `schemaVersion = 1`; `inboxPageSize = min(max(inboxPageSize, 50), 200)`; `composeStyle.sizePx = composeStyle.sizePx; composeStyle.colorHex = composeStyle.colorHex` (runs the observers for values that arrived via memberwise mutation paths); `lastSignedInEmail = lastSignedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)`, then `nil` if empty; return copy.

### 4.9 `SettingsStore`

`init(defaults:)`:
```
self.defaults = defaults
if let data = defaults.data(forKey: Self.key) {
    do { settings = try JSONDecoder().decode(Settings.self, from: data) }        // Settings.init(from:) already normalises
    catch { Log.ui.error("settings decode failed (\(data.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)"); settings = Settings() }
} else { settings = Settings() }
```
`update(_:)`:
```
var copy = settings; change(&copy); copy = copy.normalized()
settings = copy                                                     // one Observation mutation, even if equal
let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
do { defaults.set(try enc.encode(copy), forKey: Self.key) } catch { Log.ui.error("settings encode failed: \(String(describing: error), privacy: .public)") }
```
No `synchronize()` call (deprecated; `UserDefaults` writes through). Concurrency: `@MainActor`; `snapshot` is the only way actors get a `Settings` (via a `@Sendable () async -> Settings` closure that hops to main, wired by 07).

### 4.10 `AppEnvironment`

`init(testing:)` steps (this module's content; insertion points for later modules are comments in the file):
1. `isTesting = testing`.
2. `coldStart = Log.begin(.coldStartToList)`.
3. `defaults`: if `isTesting`, `let d = UserDefaults(suiteName: "com.minimail.testing")!` — `suiteName` init returns nil only for the global domain, so the force unwrap is safe; then `d.removePersistentDomain(forName: "com.minimail.testing")`; else `.standard`.
4. `settings = SettingsStore(defaults: defaults)`.
5. `// [06] db = try! Database.open(...)  /  openInMemory() when isTesting` — comment only in this module.
6. `// [04] keychain existence, accountEmail, AuthStore` — comment only.
7. `theme = ThemeStore(settings: settings)`.
8. `// [05][07][08] GmailClient / SyncStatus / SyncEngine / Outbox / MailActions / WebViewHost` — comment only.
9. `Log.ui.debug("AppEnvironment ready testing=\(testing, privacy: .public)")`.

`startDeferredWork()`:
```
guard !deferredWorkStarted else { return }; deferredWorkStarted = true
await Task.yield(); await Task.yield()
// [04] await tokens.load()
// [07] release in-flight outbox rows; await sync.run(.launch)
if isTesting { return }
try? await Task.sleep(for: .seconds(1))
// [08] await webHost.prepare()
try? await Task.sleep(for: .seconds(1))
// [07] BackgroundRefresh.schedule(); await Maintenance.cleanup(db, now: Date()); await sync.updateBadge()
```
`markFirstListPaint()`: `if let s = coldStart { Log.end(.coldStartToList, s); coldStart = nil }`.

Performance constraint: step 1 total < 15 ms on device (§12.2). In this module the only I/O is one `UserDefaults` read (< 1 ms).

### 4.11 `RootView` / `RootPlaceholderView` / `MinimailApp`

- `RootView.body` = `RootPlaceholderView()` with modifiers in this order: `.preferredColorScheme(env.theme.preferredColorScheme)`, `.tint(themeTokens.accent)`, `.task { await env.startDeferredWork() }`. The `.environment(themeStore)` injection of §10 happens in `MinimailApp` (one level up) so `ThemeTokensReader` inside `RootView` itself can read it.
- `MinimailApp`: `@State private var env = AppEnvironment()` evaluates in `App.init` — this **is** launch step 1. No other work in `MinimailApp`.
- Testing: the scheme's `MINIMAIL_TESTING=1` reaches the host app during `xcodebuild test`, so the app process under test uses the testing defaults suite and never touches `.standard`.

---

## 5. Data

### 5.1 `project.yml` (verbatim architecture §1.4)

```yaml
name: minimail
options:
  minimumXcodeGenVersion: 2.46.0
  bundleIdPrefix: com
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
        UILaunchScreen: { UIColorName: LaunchBackground }   # theme-matched colour asset → no white flash
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false }
        ITSAppUsesNonExemptEncryption: false
        BGTaskSchedulerPermittedIdentifiers: [com.minimail.refresh]
        UIBackgroundModes: [fetch]
        GoogleClientID: $(GOOGLE_CLIENT_ID)                  # read by OAuthConfig.fromInfoPlist()
        CFBundleURLTypes:
          - CFBundleTypeRole: Editor
            CFBundleURLName: com.minimail.oauth
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
        PRODUCT_BUNDLE_IDENTIFIER: com.minimailTests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/minimail.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/minimail
        BUNDLE_LOADER: $(TEST_HOST)
```

Facts: `CFBundleURLSchemes` = reversed client id, single-slash redirect path `[gmail-api gotcha 19]`; `UIBackgroundModes: fetch` + `BGTaskSchedulerPermittedIdentifiers` for `BGAppRefreshTask` `[ios-platform §3.1]`; `GoogleClientID` is a plain custom Info.plist key. Xcode substitutes `$(VAR)` in Info.plist values from build settings, so the xcconfig values in §5.5 land in the built plist. If XcodeGen rejects the `type: folder` fixture entry (UNVERIFIED, architecture §14 #24), replace it with:

```yaml
      - path: Packages/MailCore/Tests/MailCoreTests/Fixtures
        buildPhase: resources
        excludes: ["**/*.swift"]
```

Resulting Info.plist keys the tests check (§7): `BGTaskSchedulerPermittedIdentifiers = ["com.minimail.refresh"]`, `UIBackgroundModes = ["fetch"]`, `UILaunchScreen = {UIColorName: "LaunchBackground"}`, `GoogleClientID = "REPLACE.apps.googleusercontent.com"` (until the owner edits `Google.xcconfig`), `CFBundleURLTypes[0].CFBundleURLSchemes[0] = "com.googleusercontent.apps.REPLACE"`, `ITSAppUsesNonExemptEncryption = false`, `CFBundleDisplayName = "minimail"`.

### 5.2 `Packages/MailCore/Package.swift` (verbatim architecture §1.5)

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

Rules (§1.5): `MailCore` imports only `Foundation`; `MailHTML` adds `SwiftSoup`; fixtures live inside each test target directory. `Context.environment` availability in a manifest is UNVERIFIED (architecture §14 #17); if `swift build` rejects it, replace the `if includeHTML` block by an unconditional include and document that `core-test-nohtml` is unavailable.

### 5.3 `Makefile` (verbatim architecture §1.6)

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

Recipe lines start with a TAB character (make requirement). Until module 08 creates `minimail/Web`, the last `lint` grep prints "No such file or directory" for that path to stderr and exits non-zero, which the leading `!` turns into success — expected, not an error. `make lint` runs `swift format` from the Swift 6 toolchain on both Linux and macOS.

### 5.4 `.gitignore`

```
# XcodeGen output — regenerate with `xcodegen generate`
minimail.xcodeproj/
minimail/Info.plist
minimail/minimail.entitlements
# build artefacts
.build/
DerivedData/
*.xcresult
.swiftpm/
.DS_Store
```

`.build/` without a leading slash also matches `Packages/MailCore/.build/`. `Packages/MailCore/Package.resolved` is committed.

### 5.5 `Config/Signing.xcconfig` and `Config/Google.xcconfig`

`Config/Signing.xcconfig`:
```
// Owner-specific. Team ID from https://developer.apple.com/account (Membership details). Not a secret.
#include "Google.xcconfig"
DEVELOPMENT_TEAM = REPLACE_WITH_TEAM_ID
```

`Config/Google.xcconfig`:
```
// OAuth client (type iOS) created in the example.com Google Cloud project (PLAN.md "Google Cloud setup").
// GOOGLE_REVERSED_CLIENT_ID is GOOGLE_CLIENT_ID with its two dot-separated halves swapped.
GOOGLE_CLIENT_ID = REPLACE.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.REPLACE
```

Simulator builds never need `DEVELOPMENT_TEAM` (the `NOSIGN` triple); the placeholders compile. `xcconfig` `#include` paths are relative to the including file.

### 5.6 `.swift-format`

Tooling §5.1 configuration with `NeverForceUnwrap` set to `false` (D5).

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
    "NeverForceUnwrap": false,
    "OrderedImports": true,
    "UseEarlyExits": false
  }
}
```

### 5.7 `ExportOptions.plist` (tooling §6.2; keys UNVERIFIED individually — module 14 verifies with `xcodebuild -help | grep -A 60 exportOptionsPlist`)

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

### 5.8 `.github/workflows/ci.yml` (architecture §1.7, tooling §4.4)

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
  core:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7
      - uses: swift-actions/setup-swift@v2          # action version UNVERIFIED; fallback: container image swift:6.1
        with:
          swift-version: "6.1"
      - run: swift --version
      - name: Package tests (MailCore + MailHTML)
        id: core
        run: make core-test
        continue-on-error: true
      - name: Package tests without MailHTML (SwiftSoup-on-Linux fallback, architecture §14 #1)
        if: steps.core.outcome == 'failure'
        run: make core-test-nohtml

  ios:
    runs-on: macos-26
    timeout-minutes: 45
    env:
      SIM_DEST: platform=iOS Simulator,name=iPhone 17
    steps:
      - uses: actions/checkout@v7
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '26.6'
      - name: Install tools
        run: brew install xcodegen                 # xcbeautify 3.2.1 is preinstalled on macos-26
      - name: Cache Swift packages
        uses: actions/cache@v6
        with:
          path: .build/SourcePackages
          key: spm-${{ runner.os }}-xcode26.6-${{ hashFiles('project.yml', 'Packages/MailCore/Package.swift') }}
          restore-keys: |
            spm-${{ runner.os }}-xcode26.6-
      - name: Lint
        run: make lint
      - name: Package tests on macOS (safety net for the Linux job)
        run: make core-test
      - name: App tests
        run: make test-app
      - name: Upload results
        if: failure()
        uses: actions/upload-artifact@v4          # version UNVERIFIED [tooling §4.4]
        with:
          name: xcresult
          path: .build/results
```

Semantics: the `core` job passes when either `make core-test` passes or, after it fails, `make core-test-nohtml` passes (documented fallback; `MailHTMLTests` then run on macOS only). The `ios` job always runs the package tests too (§13.4). No launch-metric gate, no UI-test job (decision 15).

### 5.9 `AppIcon.appiconset`

`Contents.json`:
```json
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`AppIcon.png`: 1024×1024, 8-bit RGB (no alpha — App Store rejects alpha), solid `#0a84ff`. Generate on Linux with the standard library only (no PIL) and commit the result:

```sh
python3 - <<'EOF'
import struct, zlib
w = h = 1024
raw = b''.join(b'\x00' + bytes([0x0a, 0x84, 0xff]) * w for _ in range(h))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
open('minimail/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png', 'wb').write(png)
EOF
```

### 5.10 `AccentColor.colorset/Contents.json` (system blue values: light 0/122/255, dark 10/132/255)

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "1.000", "green" : "0.478", "red" : "0.000" }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "1.000", "green" : "0.518", "red" : "0.039" }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

### 5.11 `LaunchBackground.colorset/Contents.json` (light `systemBackground` white, dark `systemBackground` black — §10)

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "1.000", "green" : "1.000", "red" : "1.000" }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "0.000", "green" : "0.000", "red" : "0.000" }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

`Assets.xcassets/Contents.json`:
```json
{
  "info" : { "author" : "xcode", "version" : 1 }
}
```

### 5.12 `minimail/Resources/PrivacyInfo.xcprivacy` (`[ios-platform §7]`; reason code CA92.1 = "access user defaults to read and write information only accessible to the app itself")

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyTrackingDomains</key>
  <array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array>
        <string>CA92.1</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
```

XcodeGen adds `.xcprivacy` files under `sources` to the Copy Bundle Resources phase; the file lands at the app bundle root (`Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")` is non-nil).

### 5.13 Settings JSON on disk (`UserDefaults` key `com.minimail.settings`, `.sortedKeys`)

Default value after one `update { _ in }` (nil `lastSignedInEmail` omitted; keys sorted lexicographically):

```json
{"composeStyle":{"colorHex":"#000000","family":"helvetica","sizePx":14},"inboxPageSize":100,"loadRemoteImages":false,"markReadOnOpen":true,"schemaVersion":1,"showBadge":false,"signatureEnabled":true,"signatureHTML":"","themeChoice":"system"}
```

Tolerated inputs and their decode results:

| stored JSON | result |
|---|---|
| `{"themeChoice":"dark"}` | defaults with `themeChoice = .dark` |
| `{"themeChoice":"sepia"}` | defaults (`.system`) |
| `{"inboxPageSize":999}` | `inboxPageSize = 200` |
| `{"inboxPageSize":1}` | `inboxPageSize = 50` |
| `{"composeStyle":{"sizePx":40,"colorHex":"#ABCDEF"}}` | `sizePx = 18`, `colorHex = "#abcdef"`, `family = .helvetica` |
| `{"composeStyle":{"sizePx":"big"}}` | `composeStyle = ComposeStyle()` (nested failure isolated) |
| `{"composeStyle":{"colorHex":"red"}}` | `colorHex = "#000000"` |
| `{"lastSignedInEmail":"  "}` | `lastSignedInEmail = nil` |
| `{"unknownKey":1}` | defaults |
| `not json` / `{"markReadOnOpen":"yes"}` | `Settings()` + `Log.ui.error` |

### 5.14 Fixture files

`Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/smoke.json`:
```json
{"ok":true}
```
`Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/smoke.html`:
```html
<!doctype html><html><body><p>smoke <b>fixture</b></p></body></html>
```

---

## 6. UI

The only view content of this module is the placeholder root. No navigation, no sheets, no haptics.

### 6.1 `RootPlaceholderView`

```
ZStack
 ├─ themeTokens.background            (.ignoresSafeArea())
 └─ VStack(spacing: 12)
      ├─ Image(systemName: "envelope")  .font(.system(size: 44, weight: .regular)) .foregroundStyle(themeTokens.accent)
      ├─ Text("minimail")               .font(.largeTitle.bold()) .foregroundStyle(themeTokens.text)
      └─ Text("Inbox coming soon")      .font(.subheadline) .foregroundStyle(themeTokens.secondaryText)
```
- Accessibility: the `VStack` gets `.accessibilityElement(children: .combine)` and `.accessibilityLabel("minimail, inbox coming soon")`; the image is `.accessibilityHidden(true)`.
- States: exactly one (static). Theme choice `.light`/`.dark` from `Settings` forces the scheme via `RootView`'s `.preferredColorScheme`; `.system` follows the device.
- No user actions.

### 6.2 Theme application (contract for all later screens)

- `RootView` applies `.preferredColorScheme(env.theme.preferredColorScheme)` and `.tint(themeTokens.accent)`; `MinimailApp` injects `AppEnvironment`, `ThemeStore` and `SettingsStore` into the environment.
- Every later view reads colours through `@ThemeTokensReader private var themeTokens` and uses `themeTokens.<token>`; `make lint` rejects `Color(.blue)`-style raw colours under `minimail/Features` and `minimail/Web`.
- System fonts only (`.font(.body)`, `.headline`, …); Dynamic Type follows automatically.

---

## 7. Tests

Package tests run with `make core-test` (`swift test` on Linux and macOS). App tests run with `make test-app` (`xcodebuild test`, simulator `iPhone 17`). All app test classes are `final class … : XCTestCase` and `@MainActor` (the default isolation makes them so).

### 7.1 Package tests (`swift test`)

| Test file | Function | Setup | Assertions |
|---|---|---|---|
| `Packages/MailCore/Tests/MailCoreTests/ComposeStyleTests.swift` | `testDefaults` | `ComposeStyle()` | `family == .helvetica`, `sizePx == 14`, `colorHex == "#000000"`, `inlineCSS == "font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000"` |
| | `testFamilyCSSTable` | loop over `Family.allCases` | each `css` equals the §4.1 table entry; `displayName` equals the table; `allCases.count == 8` |
| | `testSizeClampOnSet` | `var s = ComposeStyle(); s.sizePx = 40; s.sizePx = 3; s.sizePx = 16` | after each: `18`, `12`, `16` |
| | `testColorHexNormalisation` | set `"#ABCDEF"`, `"red"`, `"#12345"`, `"#123456"` | `"#abcdef"`, `"#000000"`, `"#000000"`, `"#123456"` |
| | `testIsValidHex` | table | `isValidHex("#000000") == true`, `("#ABCDEF") == false`, `("000000") == false`, `("#00000") == false`, `("#0000000") == false`, `("#00000g") == false` |
| | `testDecodeTolerant` | decode `{"family":"comic","sizePx":40,"colorHex":"#ABCDEF"}` | `family == .helvetica`, `sizePx == 18`, `colorHex == "#abcdef"` |
| | `testDecodeEmptyObject` | decode `{}` | equals `ComposeStyle()` |
| | `testDecodeTypeMismatchThrows` | decode `{"sizePx":"big"}` | `XCTAssertThrowsError` |
| | `testEncodeSortedKeys` | `JSONEncoder` with `.sortedKeys` on defaults | string == `{"colorHex":"#000000","family":"helvetica","sizePx":14}` |
| | `testRoundTrip` | every family × sizes `[12, 18]` × hex `"#0a84ff"` | decode(encode(x)) == x |
| `Packages/MailCore/Tests/MailCoreTests/PackageSmokeTests.swift` | `testThemeCSSTokensEquatable` | two identical inits, one differing in `link` | `==` true, `!=` for the variant |
| | `testFixtureBundleLoads` | `Bundle.module.url(forResource: "smoke", withExtension: "json", subdirectory: "Fixtures/vectors")` | non-nil; JSON decodes to `["ok": true]` |
| `Packages/MailCore/Tests/MailHTMLTests/PackageSmokeTests.swift` | `testSwiftSoupLinked` | `MailHTMLPackage.textContent(ofHTML: "<p>Hi <b>there</b></p>")` | `== "Hi there"` |
| | `testFixtureBundleLoads` | `Bundle.module.url(forResource: "smoke", withExtension: "html", subdirectory: "Fixtures/html")` | non-nil; contents contain `"smoke"` |
| | `testMailCoreReachable` | `ComposeStyle().sizePx` | `== 14` (proves `MailHTML` depends on `MailCore`) |

### 7.2 App tests (`xcodebuild test`)

Shared helper (private in each file, no support module — 14 owns `minimailTests/Support`): `func freshDefaults(_ name: String = #function) -> UserDefaults` creates `UserDefaults(suiteName: "minimailTests.\(name)")!` and calls `removePersistentDomain(forName:)` first.

| Test file | Function | Setup | Assertions |
|---|---|---|---|
| `minimailTests/Settings/SettingsStoreTests.swift` | `testMissingKeyGivesDefaults` | fresh suite | `store.settings == Settings()`; `defaults.data(forKey: SettingsStore.key) == nil` (init never writes) |
| | `testUpdateWritesSynchronouslyAndSortedKeys` | `store.update { $0.themeChoice = .dark }` | `String(data: defaults.data(forKey: key)!, encoding: .utf8)` == the §5.13 string with `"themeChoice":"dark"`; a **second** `SettingsStore(defaults:)` reads `themeChoice == .dark` |
| | `testCorruptDataFallsBack` | `defaults.set(Data("not json".utf8), forKey: key)` | `store.settings == Settings()` |
| | `testPartialJSON` | store `{"themeChoice":"dark"}` | `themeChoice == .dark`, `inboxPageSize == 100`, `composeStyle == ComposeStyle()` |
| | `testUnknownThemeChoice` | `{"themeChoice":"sepia"}` | `themeChoice == .system` |
| | `testUnknownKeysIgnored` | `{"unknownKey":1,"markReadOnOpen":false}` | `markReadOnOpen == false` |
| | `testClampInboxPageSize` | `{"inboxPageSize":999}` then `{"inboxPageSize":1}` | `200`, `50`; and `update { $0.inboxPageSize = 0 }` → `50` |
| | `testNestedComposeStyleFailureIsolated` | `{"composeStyle":{"sizePx":"big"},"showBadge":true}` | `composeStyle == ComposeStyle()`, `showBadge == true` |
| | `testComposeStyleNormalisedThroughUpdate` | `update { $0.composeStyle.sizePx = 99; $0.composeStyle.colorHex = "#ABCDEF" }` | `18`, `"#abcdef"` |
| | `testScalarTypeMismatchFallsBack` | `{"markReadOnOpen":"yes"}` | `store.settings == Settings()` |
| | `testLastSignedInEmailTrimmed` | `update { $0.lastSignedInEmail = "  " }` then `" a@b.de "` | `nil`, then `"a@b.de"`; encoded JSON omits the key when nil |
| | `testSnapshotIsCopy` | `let snap = store.snapshot; store.update { $0.showBadge = true }` | `snap.showBadge == false` |
| `minimailTests/Theme/ThemeStoreTests.swift` | `testInitialChoiceFromSettings` | settings stored `{"themeChoice":"light"}` | `ThemeStore(settings:).choice == .light` |
| | `testChoicePersists` | `theme.choice = .dark` | `settings.settings.themeChoice == .dark`; a new `SettingsStore` on the same defaults reads `.dark` |
| | `testResolvedSystem` | `choice = .system` | `resolved(for: .light).id == "light"`, `resolved(for: .dark).id == "dark"` |
| | `testResolvedForced` | `choice = .light` / `.dark` | `resolved(for: .dark).id == "light"` / `resolved(for: .light).id == "dark"` |
| | `testPreferredColorSchemeAndDocumentTheme` | three choices | `(nil, nil)`, `(.light, "light")`, `(.dark, "dark")` |
| | `testInterfaceStyle` | three choices | `.unspecified`, `.light`, `.dark` |
| | `testRegistry` | — | `ThemeStore.registry.keys.sorted() == ["dark", "light"]`; `registry["light"]?.colorScheme == .light`; `registry["dark"]?.name == "Dark"` |
| | `testCSSTokensHexFormat` | `LightTheme().cssTokens(for: .light)` and `(for: .dark)`, same for `DarkTheme` | all 8 fields match `^#[0-9a-f]{6}$` (checked with `ComposeStyle.isValidHex`) |
| | `testCSSTokensKnownValues` | `SystemPalette.cssTokens(for: .light)` / `.dark` | light: `background == "#ffffff"`, `text == "#000000"`, `accent == "#007aff"`, `cardBackground == "#ffffff"`; dark: `background == "#000000"`, `text == "#ffffff"`, `accent == "#0a84ff"`, `cardBackground == "#ffffff"` |
| | `testHexCompositesAlpha` | `SystemPalette.hex(UIColor(white: 0, alpha: 0.5), scheme: .light, over: .white)` | `== "#808080"` (0.5·0 + 0.5·255 = 127.5 → 128) |
| | `testHexGrayscaleColor` | `SystemPalette.hex(.white, scheme: .light)`, `(.black, …)` | `"#ffffff"`, `"#000000"` |
| `minimailTests/App/AppEnvironmentTests.swift` | `testTestingModeUsesIsolatedDefaults` | `AppEnvironment(testing: true)` | `isTesting == true`; `env.defaults !== UserDefaults.standard`; `env.settings.defaults === env.defaults`; `env.settings.settings == Settings()`; `env.theme.choice == .system` |
| | `testTestingModeWipesSuite` | write `{"themeChoice":"dark"}` into suite `com.minimail.testing`, then `AppEnvironment(testing: true)` | `env.theme.choice == .system` |
| | `testProcessFlagDetected` | — | `AppEnvironment.isTestingProcess == true` (the scheme sets `MINIMAIL_TESTING=1`) |
| | `testDeferredWorkIdempotent` | `await env.startDeferredWork()` twice | `deferredWorkStarted == true`; second call returns immediately (elapsed < 100 ms) |
| | `testMarkFirstListPaintTwiceIsSafe` | call twice | no crash (`XCTAssertNoThrow` around the calls) |
| | `testRootViewHosts` | `UIHostingController(rootView: RootView().environment(env).environment(env.theme).environment(env.settings))`; `view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)`; `view.layoutIfNeeded()` | `view.subviews.isEmpty == false`; no crash |
| | `testInitTiming` | `measure { _ = AppEnvironment(testing: true) }` | records only (no gate — decision 15) |
| `minimailTests/App/BundleConfigTests.swift` | `testBackgroundKeys` | `Bundle.main.infoDictionary!` | `["BGTaskSchedulerPermittedIdentifiers"] as? [String] == ["com.minimail.refresh"]`; `["UIBackgroundModes"] as? [String] == ["fetch"]` |
| | `testLaunchScreenColor` | | `(["UILaunchScreen"] as? [String: Any])?["UIColorName"] as? String == "LaunchBackground"`; `UIColor(named: "LaunchBackground") != nil` |
| | `testOAuthKeys` | | `(["GoogleClientID"] as? String)?.hasSuffix(".apps.googleusercontent.com") == true`; first `CFBundleURLSchemes` entry `hasPrefix("com.googleusercontent.apps.")` |
| | `testDisplayAndCategory` | | `CFBundleDisplayName == "minimail"`, `LSApplicationCategoryType == "public.app-category.productivity"`, `ITSAppUsesNonExemptEncryption as? Bool == false`, `CFBundleShortVersionString == "0.1.0"` |
| | `testPrivacyManifestBundled` | | `Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil`; plist decodes; `NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPIType == "NSPrivacyAccessedAPICategoryUserDefaults"`; reasons contain `"CA92.1"` |
| | `testAccentColorAsset` | | `UIColor(named: "AccentColor") != nil` |
| | `testFixtureFolderCopied` | `Bundle(for: Self.self).url(forResource: "smoke", withExtension: "json", subdirectory: "Fixtures/vectors")` | non-nil (proves the `type: folder` copy in `project.yml`) |
| `minimailTests/App/LogAndFormattersTests.swift` | `testLoggerCategoriesExist` | touch `Log.auth … Log.bg` | `Log.subsystem == "com.minimail"`; each `Logger` value is constructible (compile + no crash); `Log.Interval.allCases.count == 8` |
| | `testIntervalNamesMatchCases` | loop | `"\(interval.name)" == interval.rawValue` for every case |
| | `testMeasureReturnsValueAndEndsOnThrow` | `Log.measure(.threadOpen) { 42 }`; `XCTAssertThrowsError(try Log.measure(.bodyLoad) { throw E() })` | `== 42`; throws propagate |
| | `testMeasureAsync` | `await Log.measure(.deltaSync) { await Task.yield(); return "x" }` | `== "x"` |
| | `testBytes` | `Formatters.bytes(0)`, `(1_500_000)`, `(-5)` | non-empty; `bytes(1_500_000).hasSuffix("MB")`; `bytes(-5) == bytes(0)` |

---

## 8. Tasks

Ordered; each is one sitting. "Verify" commands run on Linux unless marked (macOS).

- [ ] **T01.1 Repository scaffolding** — files: `.gitignore`, `.swift-format`, `Config/Signing.xcconfig`, `Config/Google.xcconfig`, `ExportOptions.plist`, `Makefile`. Done when all six exist with the byte-exact contents of §5.3–§5.7 and `Makefile` recipes start with TAB. Verify: `grep -c $'^\t' Makefile` prints `19` or more; `python3 -c "import json;json.load(open('.swift-format'))"`; `plutil -lint ExportOptions.plist` (macOS) or `python3 -c "import plistlib;plistlib.load(open('ExportOptions.plist','rb'))"`.
- [ ] **T01.2 MailCore package skeleton** — files: `Packages/MailCore/Package.swift`, `Sources/MailCore/Render/ThemeCSSTokens.swift`, `Sources/MailHTML/MailHTMLPackage.swift`, `Tests/MailCoreTests/PackageSmokeTests.swift`, `Tests/MailCoreTests/Fixtures/vectors/smoke.json`, `Tests/MailHTMLTests/PackageSmokeTests.swift`, `Tests/MailHTMLTests/Fixtures/html/smoke.html`. Done when `make core-test` passes (5 tests) or, if SwiftSoup fails to compile on Linux, `make core-test-nohtml` passes (2 tests) and the failure is recorded in §10 of this spec's implementation notes. Verify: `make core-test`.
- [ ] **T01.3 ComposeStyle** — files: `Sources/MailCore/Compose/ComposeStyle.swift`, `Tests/MailCoreTests/ComposeStyleTests.swift`. Done when the 10 tests of §7.1 pass. Verify: `cd Packages/MailCore && swift test --filter ComposeStyleTests`.
- [ ] **T01.4 project.yml + resources** — files: `project.yml`, `minimail/Resources/Assets.xcassets/**` (4 JSON files + `AppIcon.png` via the §5.9 command), `minimail/Resources/PrivacyInfo.xcprivacy`. Done when `xcodegen generate` succeeds without warnings about missing paths (requires T01.5 sources to exist for a compilable app; generation itself only needs the directories). Verify (macOS): `make gen && ls minimail.xcodeproj && plutil -lint minimail/Info.plist && grep -c LaunchBackground minimail/Info.plist`.
- [ ] **T01.5 Support + Settings + Theme + App skeleton** — files: `minimail/Support/Log.swift`, `minimail/Support/Formatters.swift`, `minimail/Features/Settings/Settings.swift`, `minimail/Features/Settings/SettingsStore.swift`, `minimail/Theme/Theme.swift`, `minimail/Theme/ThemeStore.swift`, `minimail/App/AppEnvironment.swift`, `minimail/App/RootView.swift`, `minimail/App/MinimailApp.swift`. Done when `make build` succeeds with zero errors under Swift 6 / MainActor default (warnings allowed). Verify (macOS): `make build`.
- [ ] **T01.6 App tests** — files: `minimailTests/Settings/SettingsStoreTests.swift`, `minimailTests/Theme/ThemeStoreTests.swift`, `minimailTests/App/AppEnvironmentTests.swift`, `minimailTests/App/BundleConfigTests.swift`, `minimailTests/App/LogAndFormattersTests.swift`. Done when all 42 app tests of §7.2 pass. Verify (macOS): `make test-app` and `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact` shows `failedTests: 0`.
- [ ] **T01.7 Lint clean** — files: any of the above (formatting only). Done when `make format` produces no diff on a second run and `make lint` exits 0. Verify (macOS or Linux with a Swift 6 toolchain): `make format && git diff --stat && make lint`.
- [ ] **T01.8 CI workflow** — files: `.github/workflows/ci.yml`. Done when the YAML parses and both jobs are green on a pull request (or, without GitHub access, `python3 -c "import yaml,sys;yaml.safe_load(open('.github/workflows/ci.yml'))"` passes and the job steps match §5.8 exactly). Verify: the YAML parse command; on GitHub: both checks `ci / core` and `ci / ios` pass.
- [ ] **T01.9 Simulator smoke** (macOS, optional if no simulator available) — no files. Done when the app launches and shows the placeholder in light and dark appearance. Verify: `UDID=$(xcrun simctl list devices available --json | jq -r '[.devices[][] | select(.name=="iPhone 17")][0].udid'); xcrun simctl boot "$UDID" || true; xcrun simctl install "$UDID" .build/DerivedData/Build/Products/Debug-iphonesimulator/minimail.app; xcrun simctl launch "$UDID" com.minimail; xcrun simctl io "$UDID" screenshot .build/shot-light.png; xcrun simctl ui "$UDID" appearance dark; xcrun simctl io "$UDID" screenshot .build/shot-dark.png` (simctl flags UNVERIFIED `[tooling §2.2]`; consult `xcrun simctl help`).

---

## 9. Acceptance criteria

1. `make core-test` passes on Linux (Swift 6.1+) and on macOS with Xcode 26.6; if SwiftSoup does not build on Linux, `make core-test-nohtml` passes on Linux and `make core-test` passes on macOS, and the fact is recorded as UNVERIFIED-resolved in the CI log. Verify: the commands above.
2. `make gen` produces `minimail.xcodeproj` with targets `minimail` and `minimailTests`, scheme `minimail` with `MINIMAIL_TESTING=1`, and `minimail/Info.plist` containing every key of §5.1. Verify (macOS): `make gen && plutil -p minimail/Info.plist | grep -E "BGTaskSchedulerPermittedIdentifiers|UIBackgroundModes|LaunchBackground|GoogleClientID|CFBundleURLSchemes"`.
3. `make build` compiles the app with `SWIFT_VERSION=6`, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, resolving AppAuth 3.0.0, GRDB 7.11.1 and SwiftSoup 2.13.9 exactly. Verify: `make build` exit 0 and `grep -E '"version" ?: ?"(3\.0\.0|7\.11\.1|2\.13\.9)"' minimail.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved | wc -l` prints `3`.
4. `make test-app` passes every test in §7.2 (42 tests) with `failedTests: 0` in the xcresult summary.
5. `make lint` exits 0: swift-format strict, no forbidden imports in `Packages/MailCore/Sources`, no `import SwiftSoup` in `Sources/MailCore`, no raw colours under `minimail/Features`.
6. The launched app shows the §6.1 placeholder; with `Settings.themeChoice = .dark` written to `UserDefaults` (or via a later Settings screen) the window renders dark, and the launch screen background is black in dark mode and white in light mode (no white flash). Manual device/simulator step (T01.9).
7. `AppEnvironment.init` performs no network, Keychain, AppAuth, WebKit, notification or background-task API call — verify by `grep -rE "import (AppAuth|WebKit|BackgroundTasks|UserNotifications|Security|GRDB)" minimail/App minimail/Theme minimail/Features/Settings minimail/Support` printing nothing.
8. `git status` after `make gen && make build && make test-app` shows no untracked generated files (`.gitignore` covers `minimail.xcodeproj/`, `minimail/Info.plist`, `minimail/minimail.entitlements`, `.build/`, `*.xcresult`). Verify: `git status --porcelain | grep -vE "Package.resolved" | wc -l` prints `0`.
9. CI: both jobs of `.github/workflows/ci.yml` pass on a pull request; the `core` job finishes in under 20 minutes, the `ios` job in under 45.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | `ComposeStyle` lives in module 02 per modules.md, but `Settings.composeStyle` (this module) needs it and 01 has no dependencies. | DEVIATION | This module creates `Sources/MailCore/Compose/ComposeStyle.swift` with the exact §2.2 signature (+ `sizeRange`, `sizeChoices`, `isValidHex`) and `ComposeStyleTests`. Module 02 must not recreate them; 02's `OutgoingBodies` consumes `ComposeStyle.inlineCSS` unchanged. |
| D2 | `ThemeCSSTokens` is declared inside `Render/ThreadDocument.swift` (module 08), but `Theme.cssTokens(for:)` (this module) returns it. | DEVIATION | This module creates `Sources/MailCore/Render/ThemeCSSTokens.swift` holding only that struct (public memberwise init added). Module 08 writes `ThreadDocument.swift` without redefining it. |
| D3 | Architecture §1.3 lists no test files for Theme/Settings/App skeleton. | DEVIATION (additive) | Five test files under `minimailTests/{App,Theme,Settings}/` and two package smoke tests are added; `SmokeTests.swift` (14) is unchanged. |
| D4 | `.gitignore` in §1.3 names four patterns. | DEVIATION (additive) | Added `minimail/Info.plist`, `minimail/minimail.entitlements` (both generated by XcodeGen), `.swiftpm/`, `.DS_Store`. |
| D5 | Tooling §5.1 suggests `"NeverForceUnwrap": true`. | DEVIATION | Set to `false`: architecture §2.4 uses `URL(string: "…")!` in `OAuthConfig` and `UserDefaults(suiteName:)!` is used here; a strict lint would fail on verbatim architecture code. |
| D6 | `ThemeStore.registry` in §10 has no explicit `light`/`dark` statics. | additive | `static let light`/`dark` avoid force-unwrapping the dictionary in `resolved(for:)`. |
| A1 | `Context.environment` in `Package.swift` | UNVERIFIED (arch §14 #17) | Assumed available (PackageDescription ≥ 5.6). Fallback in §5.2. |
| A2 | SwiftSoup 2.13.9 compiles on Linux | UNVERIFIED (arch §14 #1) | CI `core` job falls back to `make core-test-nohtml`; `MailHTMLTests` then run only in the `ios` job. |
| A3 | XcodeGen `type: folder` source entry with `buildPhase: resources` | UNVERIFIED (arch §14 #24) | Fallback YAML in §5.1. |
| A4 | `swift-actions/setup-swift@v2` accepts `swift-version: "6.1"`; `swift:6.1` Docker tag | UNVERIFIED `[tooling §7.4]` | If the action fails, switch the `core` job to `container: swift:6.1` (or the newest `swift:6.x` tag listed on hub.docker.com/_/swift). |
| A5 | `actions/upload-artifact@v4`, `actions/checkout@v7`, `actions/cache@v6` | partially verified `[tooling §4.4]` | Pinned as written; bump majors if the runner reports deprecation. |
| A6 | `ExportOptions.plist` key names | partially verified `[tooling §6.2]` | Committed as written; module 14 validates against `xcodebuild -help` before the first archive. |
| A7 | `nonisolated` on type declarations (`nonisolated enum Log`, `nonisolated struct Settings`) requires Swift 6.2+ (SE-0449) | assumed OK (Xcode 26.6 ships Swift 6.3) | Fallback: mark every member `nonisolated` individually and keep the type unannotated. |
| A8 | `Logger` / `OSSignposter` / `OSSignpostIntervalState` are `Sendable` | assumed (Apple documents both as thread-safe) | Fallback: `nonisolated(unsafe) static let` on the statics; wrap the interval state if it is not `Sendable` across `await` in `measure`. |
| A9 | `@Observable` supports `didSet` on stored properties (`ThemeStore.choice`) | assumed (macro-generated accessors call observers) | Fallback: replace with an explicit `func setChoice(_:)` and a private stored property; module 13 then binds through a computed `Binding`. |
| A10 | `Color(.systemBackground)` unlabeled initializer from `UIColor` (used verbatim in §10) | assumed (`Color.init(_ color: UIColor)` exists since iOS 13) | Fallback: `Color(uiColor:)` (iOS 15). |
| A11 | `UIColor(named: "AccentColor")` round-trips the asset components exactly enough that `#007aff` / `#0a84ff` result after rounding | assumed | If the simulator yields ±1 in a channel, relax `testCSSTokensKnownValues` to compare `accent` against `SystemPalette.hex(UIColor(named:"AccentColor")!, …)` and keep the exact checks for background/text/cardBackground. |
| A12 | App Store / TestFlight accept a flat single-colour 1024 px icon | assumed (icons are only validated for size, alpha and format) | Owner may replace `AppIcon.png` later; the catalog entry stays. |
| A13 | `PrivacyInfo.xcprivacy` reason codes beyond `CA92.1` | open | Module 06 decides whether `FileManager` timestamp access (`C617.1`) is needed for `Database.open`'s attribute write; if so it edits this file (modify) and notes it. |
| A14 | Scheme `environmentVariables` apply to the test action's host app | assumed (Xcode's test action inherits the run action's environment by default; XcodeGen writes both) | `testProcessFlagDetected` fails loudly if not; fallback: add `MINIMAIL_TESTING` under `scheme.testVariants`/`testTargets` env in `project.yml` per ProjectSpec.md. |
| A15 | Cold-start budget < 15 ms for step 1 | not gated (decision 15) | `testInitTiming` records `measure` results only; real numbers come from `log stream --predicate 'subsystem == "com.minimail"'` on device (§12.1). |
