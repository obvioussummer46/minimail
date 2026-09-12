# 09-inbox-list — Inbox screen/model, rows, filters, swipe actions, banners, paging

Module id: `09-inbox-list`.

Depends on:
- `01-project-setup` — `AppEnvironment`, `ThemeTokens`, `ThemeTokensReader`, `ThemeStore`, `SettingsStore`, `Log.ui`, `RootView`, `MinimailApp`, `Formatters`.
- `06-storage` — `ThreadQuery`, `ThreadRow`, `ThreadChip`, `ThreadDetail` (not used here), `Queries.{threads,labelsById,failedSends,inboxUnreadThreadCount,todayThreadCount}`, `LabelRecord`, `OutboxRecord`, `SendJob`, `SyncStateRepository`, `DayBoundary`, `TestDatabase`, `InvariantChecks`, `AppDatabase`.
- `07-sync-outbox` — `SyncEngine.run(_:)`, `SyncReason`, `SyncStatus`, `MailActions`, `Outbox.retrySend(id:)`, `Outbox.discardSend(id:)`.

Transitively used: `04-auth` (`AuthStore.State`, `AuthStore.state/lastError/isSigningIn/signIn()/signOut()`), `05-gmail-client` (only through the test host's default `OfflineURLProtocol`), `02-mailcore-mime` (`Mailbox`, `ComposeMode`, `QuoteSource` inside `SendJob`).

Consumed by: `10-thread-view` (`ThreadRoute`, `ComposeInput`, `InboxScope`; replaces the `ThreadScreen` placeholder), `11-compose` (`ComposeInput`; replaces the `ComposeScreen` placeholder), `12-labels` (`InboxScope`, `LabelChip`, the `LabelsScreen(onSelect:)` contract), `13-settings-theme-signature` (replaces the `SettingsScreen` placeholder and deletes `InboxPlaceholders.swift`), `14-qa` (`SmokeTests` hosts `InboxScreen`, uses the accessibility identifiers of §5.4).

Source of truth: `docs/plan/design/architecture.md` §2.1 (isolation + layering rules), §2.4 (Store / Sync / Auth interfaces), §3.2 (columns the rows come from), §3.5 (invariants asserted in tests), §4.1 (sync triggers), §4.6 (local counts), §4.8 (outbox failure UX), §5.2/D22 (reauth routing), §8.1 (navigation graph), §8.2 (screen contract), §8.3 (row layout, swipes, toolbar, haptics), §8.6 (filters as SQL + `ValueObservation`), §10 (theme tokens), §12.1–§12.3 (performance), §13.1/§13.3 (test layers), §14 #19/#26, §15 D15/D16/D21/D22, §16 (non-goals); `docs/plan/design/modules.md` §09; research `[ios-platform §2.6]` (ValueObservation → SwiftUI), `[ios-platform §5.1]` (`@Observable`), `[ios-platform §5.2]` (NavigationStack, swipe actions, refreshable, ContentUnavailableView), `[ios-platform §5.6]` (Swift 6 default MainActor isolation).

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. **`InboxScreen(scope:)`** — the root screen of the signed-in app: a `NavigationStack` whose content is a `List(.plain)` of `ThreadRowView`s, with `.toolbarTitleMenu` scope switching (Inbox / Today / Labels…), an unread-only toggle, a Settings button, pull-to-refresh, leading/trailing swipe actions with theme tints and haptics, empty states, the initial-sync footer, status banner rows (offline / error / reauth), the "Outbox" section for failed sends (Retry / Delete / tap → Compose), "load older" paging, `ThreadRoute` push navigation and the single `ActiveSheet` slot (architecture §8.1–§8.3).
2. **`InboxModel`** — the `@Observable` main-actor model that owns two GRDB `ValueObservation`s started with `.immediate` scheduling: the thread rows produced by `Queries.threads` (60 rows per page, `+60` per "load older") and one auxiliary projection (label table, local Inbox/Today counts, failed sends, inbox page token). It turns UI intents into `MailActions` / `Outbox` / `SyncEngine.run` calls and recomputes its `DayBoundary` on day change, time-zone change and scene activation (architecture §8.6, §14 #19).
3. **`ThreadRowView`** (+ `LabelChip`) — the iOS-Mail-style row of architecture §8.3, rendered from the fully precomputed `ThreadRow` (no formatting, no `Task`, no date math in `body`).
4. **`StatusBanner`** (+ `FailedSendRow`) — the non-blocking status rows of architecture §4.8 / §8.2 ("never a blocking alert").
5. Value types shared with later modules: `InboxScope`, `ThreadRoute`, `ActiveSheet`, `ComposeInput`, `InboxBanner`, `InboxEmptyState`.
6. A modification of `minimail/App/RootView.swift`: the signed-in / needs-reauth branch renders `InboxScreen(scope: .inbox)`; 04's `SignedInPlaceholderView` and 01's `RootPlaceholderView` are deleted.
7. Interim placeholder screens (`ThreadScreen`, `ComposeScreen`, `LabelsScreen`, `SettingsScreen`) carrying the exact signatures modules 10–13 will implement, so this module compiles, runs and is testable before them (same precedent as 04's `SignedInPlaceholderView`).
8. App tests `minimailTests/Inbox/InboxModelTests.swift` and `minimailTests/Inbox/InboxViewsTests.swift` (XCTest, simulator, `make test-app`).

### 1.2 Explicitly out of scope (owned elsewhere)

- The thread screen and everything it does — `ensureThreadLoaded`, mark-read-on-open, body rendering, attachments, QuickLook (10).
- Compose UI, draft prefill, `SendJob` construction, resending a failed job (11). This module only *opens* a compose sheet with a `ComposeInput`.
- The labels sheet content, `sync.run(.labelOpened(id))`, `refreshLabelCounts` (12). This module only presents `LabelsScreen(onSelect:)` and consumes the selected `InboxScope`.
- The settings screen, theme picker, signature editor, sign-out row (13). The `SettingsScreen` placeholder keeps one Sign-out button so 04's device checklist stays executable until 13 lands.
- Any SQL text (all reads go through `Queries` / repositories — architecture §2.1 rule 3), any `GmailClient` or `URLSession` call (rule 2), any sync decision (throttling, page tokens, re-arming failed ops all live in 07).
- Programmatic manipulation of the navigation path by other modules (10 pops itself with `@Environment(\.dismiss)`).
- Non-goals of architecture §16 that touch this screen: undo toast, configurable swipe actions, star/trash/spam/move swipes, per-message read state, search bar, section headers by date, iPad/landscape layouts, localisation.

### 1.3 Consumers and the exact symbols they take

| Consumer | Symbols consumed from this module |
|---|---|
| 10 thread view | `ThreadRoute` (the pushed value; 10 supplies the real `.navigationDestination` content by replacing the `ThreadScreen` placeholder), `ComposeInput.fromMessage(mode:threadId:messageId:)` for its Reply-all / Forward sheet |
| 11 compose | `ComposeInput` (both cases) and the `ComposeScreen(input:)` signature |
| 12 labels | `InboxScope` (the `onSelect` payload), the `LabelsScreen(onSelect:)` signature, `LabelChip` (view + `LabelChip.color(hex:)`) |
| 13 settings | the `SettingsScreen()` signature; deletes `InboxPlaceholders.swift` |
| 14 qa | `InboxScreen(scope:)` hosted in `SmokeTests`, `InboxModel` state assertions, the accessibility identifiers of §5.4 |

---

## 2. Files

| Path (relative to repo root) | Kind | Purpose |
|---|---|---|
| `minimail/Features/Inbox/InboxModel.swift` | new | `InboxScope`, `ThreadRoute`, `ComposeInput`, `ActiveSheet`, `InboxBanner`, `InboxEmptyState`, `InboxAux`, `InboxModel` (observations, paging, filters, actions, day change, banners) |
| `minimail/Features/Inbox/InboxScreen.swift` | new | `InboxScreen` (NavigationStack, model lifecycle, notification wiring, toolbar, sheets, navigation destination), private `InboxListView`, private `InboxEmptyView` |
| `minimail/Features/Inbox/ThreadRowView.swift` | new | `ThreadRowView` (architecture §8.3 row) and `LabelChip` (Gmail-coloured capsule + hex→`Color` mapping) |
| `minimail/Features/Inbox/StatusBanner.swift` | new | `StatusBanner` (offline / error / reauth row) and `FailedSendRow` (Outbox section row) + their pure string helpers |
| `minimail/Features/Inbox/InboxPlaceholders.swift` | new (temporary) | interim `ThreadScreen`, `ComposeScreen`, `LabelsScreen`, `SettingsScreen` with the final signatures; 10/11/12 delete their own struct, 13 deletes the file |
| `minimail/App/RootView.swift` | modify | signed-in / needs-reauth branch → `InboxScreen(scope: .inbox)`; delete `SignedInPlaceholderView` (04) and `RootPlaceholderView` (01) |
| `minimailTests/Inbox/InboxModelTests.swift` | new | model behaviour against `AppEnvironment(testing: true)` + a seeded temporary pool (§7.1) |
| `minimailTests/Inbox/InboxViewsTests.swift` | new | pure view helpers (strings, colours, ids) + hosting smoke tests (§7.2) |

No `Packages/MailCore` file is added or edited (this module ships no pure algorithm). No `project.yml` change: the app target globs `minimail/` and the test target globs `minimailTests/` (01 §1.4). No `Info.plist` key, no entitlement, no asset.

---

## 3. Public interface

Conventions (01 §3, 06 §3): the app target builds with `SWIFT_VERSION = 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` `[ios-platform §5.6]`, so every declaration below is `@MainActor` **implicitly** unless it carries an explicit `nonisolated`. App declarations are `internal` (no `public`). Types that cross into GRDB `@Sendable` fetch closures, into actors (`SyncEngine`, `Outbox`) or into `Hashable` navigation values are marked `nonisolated` and are `Sendable` value types.

Signatures marked `// verbatim` are copied from architecture §2.4 / §8.1 / modules.md. Every deviation is listed in §10.

### 3.1 `minimail/Features/Inbox/InboxModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import Observation

/// Which mailbox the list shows.
///
/// Deliberately carries no `DayBoundary` (unlike `ThreadQuery.Scope.today(DayBoundary)`): the boundary is owned by
/// `InboxModel.day` and recomputed on day / time-zone change, so `InboxScope` stays a plain comparable value that the
/// title menu compares and that `LabelsScreen(onSelect:)` (module 12) can hand back. See DEVIATION D1 (§10).
nonisolated enum InboxScope: Hashable, Sendable {
    case inbox
    case today
    /// A Gmail label id, e.g. `"Label_12"`. Never `"INBOX"` (that is `.inbox`).
    case label(id: String)
}

/// Navigation value pushed by a thread row (architecture §8.1: `ThreadRoute(threadId)` +
/// `.navigationDestination(for: ThreadRoute.self)`).
nonisolated struct ThreadRoute: Hashable, Sendable {                                    // verbatim (name + payload)
    let threadId: String
    init(threadId: String)
}

/// Input of `ComposeScreen(input:)` (module 11).
///
/// `.fromMessage` is produced by module 10 (Reply all / Forward on a cached message); `.failedSend` is produced here by the
/// Outbox section (architecture §4.8: "tap → Compose prefilled from the job"). `Equatable` but not `Hashable`, because
/// `SendJob.quoteSource: QuoteSource` is declared `Codable, Sendable, Equatable` only (architecture §2.2).
/// `Identifiable` is what `.sheet(item:)` requires.
nonisolated enum ComposeInput: Equatable, Sendable, Identifiable {
    case fromMessage(mode: ComposeMode, threadId: String, messageId: String)
    case failedSend(outboxId: Int64, job: SendJob)
    /// `"message:<mode.rawValue>:<messageId>"` or `"failedSend:<outboxId>"` (§5.1).
    var id: String { get }
}

/// The single sheet slot of the inbox (architecture §8.1: `enum ActiveSheet { labels, settings, compose(ComposeInput) }`).
enum ActiveSheet: Identifiable, Equatable {                                              // verbatim (cases)
    case labels
    case settings
    case compose(ComposeInput)
    /// `"labels"`, `"settings"`, `"compose:" + input.id` (§5.1).
    var id: String { get }
}

/// The status row shown above the threads. At most one is visible; the priority order is fixed in `InboxModel.banner` (§4.6).
enum InboxBanner: Equatable {
    /// `auth.state == .needsReauth(_)` and the user has not dismissed it this session.
    case reauth
    /// `SyncStatus.isOffline` — the last network attempt failed with `GmailError.offline`.
    case offline
    /// `SyncStatus.lastError`, or `"Database unavailable"` when a `ValueObservation` failed.
    case error(String)
}

/// What the list shows when it has no thread rows (§4.7; architecture §8.2 column "Empty / loading / error").
enum InboxEmptyState: Equatable {
    case initialSync      // SyncStatus.phase == .initialSync  → ProgressView("Loading your inbox…")
    case allCaughtUp      // unreadOnly == true                → "All caught up"  (checkmark.circle)
    case noMail           // scope == .inbox                   → "No Mail"        (tray)
    case nothingToday     // scope == .today                   → "Nothing today"  (sun.max)
    case noMessages       // scope == .label(_)                → "No messages"    (tag)
}

/// Main-actor model of the inbox list (architecture §8.2 row "InboxScreen / InboxModel").
///
/// Exactly one instance exists per `InboxScreen`; the screen is the navigation root, so the instance lives as long as the
/// signed-in session. Creating it performs two synchronous cache reads (`.immediate` observations) and no network, no
/// `Task` and no `DatabasePool.write` (architecture §12.2 step 2).
@Observable final class InboxModel {

    // ---- constants ----
    /// 60 — one page (`ThreadQuery.pageSize`, 06 §3.9). `limit` grows by this amount per "load older".
    static let pageSize: Int = ThreadQuery.pageSize
    /// 3 — consecutive automatic `sync.run(.loadOlder…)` calls that produced no new row before the model stops and waits
    /// for the next scroll to the end (§4.5).
    static let maxAutoOlderLoads = 3

    /// Composition root. `db`, `syncStatus`, `sync`, `outbox`, `actions` and `auth` are read from it at call time
    /// (07 D6: `AppEnvironment.actions` is rebuilt after an account wipe, so it is never cached here).
    let env: AppEnvironment

    // ---- observed state (mutated only by this class) ----
    private(set) var scope: InboxScope
    private(set) var unreadOnly: Bool = false
    private(set) var limit: Int = InboxModel.pageSize
    /// Today's window in `timeZone` at the last (re)computation (`DayBoundary.today(now:timeZone:)`).
    private(set) var day: DayBoundary
    /// Rows of `Queries.threads(query, …)`, newest first, at most `limit` entries.
    private(set) var rows: [ThreadRow] = []
    /// `Queries.labelsById` — chip names/colours, the label-scope title and the label page token.
    private(set) var labels: [String: LabelRecord] = [:]
    /// `Queries.inboxUnreadThreadCount` — local, matches the list including optimistic state (architecture §4.6).
    private(set) var inboxUnreadCount: Int = 0
    /// `Queries.todayThreadCount(day)`.
    private(set) var todayCount: Int = 0
    /// `Queries.failedSends` — rows of the "Outbox" section, ordered by `outbox.id`.
    private(set) var failedSends: [OutboxRecord] = []
    /// A server page token exists for the current scope, so "load older" can fetch more (§4.5).
    private(set) var hasOlder: Bool = false
    /// A `sync.run(.loadOlder…)` started by `rowAppeared` is in flight (drives the footer spinner).
    private(set) var isLoadingOlder: Bool = false
    /// Text of the last `ValueObservation` failure; `nil` after a successful restart (`refresh()`).
    private(set) var observationError: String?
    /// Bound by the screen through `.sheet(item:)`; the only externally settable property.
    var activeSheet: ActiveSheet?
    /// Monotonic counter feeding `.sensoryFeedback(.impact(weight: .light), trigger:)` (architecture §8.3).
    private(set) var lastActionId: Int = 0
    /// Monotonic counter feeding `.sensoryFeedback(.selection, trigger:)` (scope / unread-toggle changes).
    private(set) var filterChangeId: Int = 0
    /// The user dismissed the reauth banner; reset when `auth.state` returns to `.signedIn`.
    private(set) var reauthBannerDismissed: Bool = false

    // ---- derived (computed; no storage, no side effects) ----
    /// `ThreadQuery(scope: scope mapped through `day`, unreadOnly: unreadOnly, limit: limit)`.
    /// `.inbox → .inbox`, `.today → .today(day)`, `.label(id) → .label(id: id)`.
    var query: ThreadQuery { get }
    /// `"Inbox"` / `"Today"` / `labels[id]?.name ?? id` (the full Gmail name, e.g. `"Customers/ACME"`).
    var title: String { get }
    /// Priority: `.reauth` → `.offline` → `.error(syncStatus.lastError)` → `.error("Database unavailable")` → `nil` (§4.6).
    var banner: InboxBanner? { get }
    /// `nil` when `rows` is non-empty; otherwise `.initialSync` / `.allCaughtUp` / `.noMail` / `.nothingToday` / `.noMessages` (§4.7).
    var emptyState: InboxEmptyState? { get }
    /// `.loadOlderInbox` for `.inbox` and `.today`; `.loadOlderLabel(id)` for `.label(id)`.
    var olderReason: SyncReason { get }

    /// Starts both observations synchronously with `.immediate` scheduling, so that when `init` returns `labels`,
    /// `inboxUnreadCount`, `todayCount`, `failedSends`, `hasOlder` and `rows` already hold the current cache contents
    /// (architecture §12.2 step 2 — first frame from SQLite).
    ///
    /// - Parameters:
    ///   - env: composition root (`env.db` must be open; it always is after launch step 1).
    ///   - scope: initial scope (`.inbox` from `RootView`).
    ///   - clock: `now` for `DayBoundary.today` and for the row date labels; injected in tests.
    ///   - timeZone: device time zone by default; `DayBoundary` and the date labels use it.
    ///   - locale: date-label locale (`RowDateLabeler`).
    ///
    /// Performs no network call, no `sync.run`, no `Task`. Never throws: an observation that fails at start reports through
    /// `onError` → `observationError` (§4.12).
    init(env: AppEnvironment,
         scope: InboxScope,
         clock: @escaping () -> Date = Date.init,
         timeZone: TimeZone = .current,
         locale: Locale = .current)

    /// Title-menu or Labels-sheet selection. A selection equal to the current scope is a no-op (no haptic, no restart).
    /// Otherwise: `scope = new`, `limit = pageSize`, `autoOlderLoads = 0`, `filterChangeId += 1`, `hasOlder` recomputed,
    /// and the threads observation is restarted **in place** (architecture §8.1: "filter changes replace the observation in place").
    func setScope(_ scope: InboxScope)

    /// Flips `unreadOnly`, resets `limit` to `pageSize`, `filterChangeId += 1`, restarts the threads observation.
    /// The flag survives scope changes (PLAN.md: "Filter chip: unread toggle on any view").
    func toggleUnreadOnly()

    /// Called from every row's `.onAppear`; only the last row has an effect (§4.5).
    /// `rows.count >= limit` → `limit += pageSize` + restart (the cache holds more); otherwise, when `hasOlder` and no
    /// load is in flight → `sync.run(olderReason)` in a `Task`.
    func rowAppeared(_ threadId: String)

    /// Pull-to-refresh. Restarts failed observations first (when `observationError != nil`), then awaits
    /// `env.sync.run(.pullToRefresh)` (07 re-arms failed modify ops and forces label counts). Never throws.
    func refresh() async

    /// `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange` and `scenePhase == .active` (architecture §14 #19).
    /// Recomputes `DayBoundary.today(now:timeZone:)`; when the boundary or the time-zone identifier changed it stores both
    /// and restarts **both** observations (the Today window, `todayCount` and every row's `dateLabel` depend on them).
    func dayChanged(now: Date = Date(), timeZone: TimeZone = .current)

    /// Leading full swipe. `lastActionId += 1`, then `Task { await env.actions.archive(threadId:) }`.
    /// The row leaves Inbox/Today on the next observation tick; in a label scope it stays (its label is unchanged).
    func archive(threadId: String)

    /// Trailing full swipe. `lastActionId += 1`, then `markRead` when `isUnread`, else `markUnread` (whole thread, architecture D19).
    func toggleRead(threadId: String, isUnread: Bool)

    /// Outbox row swipe "Retry": `Task { await env.outbox.retrySend(id:) }` (07: failed → pending, attempts 0, then drain).
    func retrySend(_ outboxId: Int64)

    /// Outbox row swipe "Delete": `lastActionId += 1`, then `Task { await env.outbox.discardSend(id:) }` (row deleted).
    func discardSend(_ outboxId: Int64)

    /// Outbox row tap. For a `kind == .send` record with a `sendJob`, sets
    /// `activeSheet = .compose(.failedSend(outboxId: record.id, job: job))`; anything else logs `Log.ui.error` and does nothing.
    func openFailedSend(_ record: OutboxRecord)

    /// Reauth banner "×".
    func dismissReauthBanner()

    /// Wired to `.onChange(of: env.auth.state)`. `.signedIn` clears `reauthBannerDismissed` so the banner returns if the
    /// session degrades again. Other states are ignored.
    func authStateChanged(_ state: AuthStore.State)

    /// Cancels both observations (used by tests and by `deinit` through the cancellables).
    func stop()

    #if DEBUG
    /// Test hook (§10 A12): feeds `observationFailed` with a synthetic error so `testObservationErrorRecovery` can exercise
    /// the error banner without corrupting the database. Never called by production code.
    func _simulateObservationError(_ text: String)
    #endif
}
```

Private members of `InboxModel` (named here so tests, reviewers and modules 10–13 can reason about them; they are not API):

```swift
/// One fetch of everything the screen needs besides the rows (§4.3). `Equatable` so `removeDuplicates()` suppresses
/// no-op ticks caused by writes to unrelated tables.
nonisolated private struct InboxAux: Equatable, Sendable {
    var labels: [String: LabelRecord]
    var inboxUnread: Int
    var today: Int
    var failedSends: [OutboxRecord]
    var inboxNextPageToken: String?
}

private var threadsCancellable: AnyDatabaseCancellable?   // name UNVERIFIED `[ios-platform §2.6]`; see §10 A2
private var auxCancellable: AnyDatabaseCancellable?
private var chipFingerprint: [String: ThreadChip] = [:]   // label rows projected to chip fields
private var lastInboxToken: String?                       // last observed syncState.inboxNextPageToken
private var lastAppearedId: String?                       // argument of the most recent rowAppeared
private var autoOlderLoads: Int = 0
private let clock: () -> Date
private var timeZone: TimeZone
private let locale: Locale

private func startThreads()
private func startAux()
private func apply(_ aux: InboxAux)
private func recomputeHasOlder(inboxToken: String?)
private func loadOlder()
private func observationFailed(_ error: any Error)
```

### 3.2 `minimail/Features/Inbox/InboxScreen.swift`

```swift
import GRDB
import MailCore
import SwiftUI

/// Root screen of the signed-in app (architecture §8.1). Owns the `NavigationStack` path, the `InboxModel` instance and the
/// day-change wiring; every piece of list content lives in the private `InboxListView`.
struct InboxScreen: View {                                                               // verbatim: InboxScreen(scope:)
    /// Scope of the FIRST model creation. Later scope changes go through the title menu or the Labels sheet, never through
    /// a new `InboxScreen`.
    init(scope: InboxScope)
    var body: some View

    /// Yields once per `NSCalendarDayChanged` or `NSSystemTimeZoneDidChange` notification (§4.9). Observers are added on
    /// first iteration and removed when the stream terminates (view disappears / task cancelled).
    /// `nonisolated static` so it can be created from `.task` without capturing the view.
    nonisolated static func dayChangeStream() -> AsyncStream<Void>
}

/// Everything that needs `@Bindable var model` — the `List`, its sections, toolbar, sheets, swipe actions and haptics.
/// Private; documented because the hosting tests walk the rendered hierarchy.
private struct InboxListView: View {
    @Bindable var model: InboxModel
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View
}

/// One list row rendering an `InboxEmptyState` (`ContentUnavailableView` or `ProgressView`), so that pull-to-refresh keeps
/// working while the list is empty.
private struct InboxEmptyView: View {
    let state: InboxEmptyState
    var body: some View
}
```

### 3.3 `minimail/Features/Inbox/ThreadRowView.swift`

```swift
import CoreGraphics
import MailCore
import SwiftUI

/// One thread row (architecture §8.3). `body` maps precomputed strings to `Text`; it performs no formatting, starts no
/// `Task`, and reads nothing from the environment except the theme tokens.
struct ThreadRowView: View {
    let row: ThreadRow
    init(row: ThreadRow)
    var body: some View

    /// VoiceOver label (§6.3), pure and unit-tested:
    /// `["Unread" when isUnread, participants, subject or "No subject", dateLabel,
    ///   "<n> messages" when messageCount > 1, "Has attachment" when hasAttachments, "Label <name>" per chip]`
    /// joined with `", "`.
    nonisolated static func accessibilityLabel(for row: ThreadRow) -> String
}

/// Gmail-coloured capsule for one user label. Created in this module because 09 precedes 12 and the rows need chips;
/// module 12 reuses the very same type (DEVIATION D4, §10).
struct LabelChip: View {
    let chip: ThreadChip
    init(chip: ThreadChip)
    var body: some View

    /// `"#rrggbb"` (exactly 7 characters, case-insensitive hex) → `Color`; anything else (wrong length, non-hex, `nil`)
    /// → `nil`, and the caller falls back to `themeTokens.chipBackground` / `themeTokens.text`.
    ///
    /// Implemented as `Color(cgColor: CGColor(srgbRed:green:blue:alpha: 1))` — **not** `Color(red:green:blue:)` and not
    /// `UIColor(red:…)`, because `make lint` greps for the regex `Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)`
    /// over `minimail/Features`, and the substring `Color(red` occurs inside `UIColor(red:` (01 §1.6). See §10 D9.
    nonisolated static func color(hex: String?) -> Color?
}
```

### 3.4 `minimail/Features/Inbox/StatusBanner.swift`

```swift
import MailCore
import SwiftUI

/// Non-blocking status row (architecture §8.2: "StatusBanner rows (offline / 'Couldn't refresh · Retry' / 'Sign in again')
/// — never a blocking alert").
struct StatusBanner: View {
    let kind: InboxBanner
    /// Disables the action button (`.reauth` while `AuthStore.isSigningIn`); ignored by the other kinds.
    let isBusy: Bool
    /// `.reauth` → start sign-in; `.error` → retry (pull-to-refresh path); `.offline` → never invoked (no button).
    let action: () -> Void
    /// `.reauth` only: the "×" button. `nil` hides it.
    let dismiss: (() -> Void)?
    /// `.reauth` only: second line under the title (`AuthStore.lastError`). `nil` hides it.
    let detailOverride: String?

    init(kind: InboxBanner,
         isBusy: Bool = false,
         detailOverride: String? = nil,
         action: @escaping () -> Void,
         dismiss: (() -> Void)? = nil)
    var body: some View

    // Pure string/symbol helpers (§5.2, §5.3); unit-tested.
    nonisolated static func title(for kind: InboxBanner) -> String
    nonisolated static func detail(for kind: InboxBanner) -> String?
    nonisolated static func symbol(for kind: InboxBanner) -> String
    nonisolated static func actionTitle(for kind: InboxBanner) -> String?
}

/// One row of the "Outbox" section (architecture §4.8 failure UX: subject, "Not sent — <short error>",
/// swipe Retry / Delete, tap → Compose prefilled from the job).
struct FailedSendRow: View {
    let record: OutboxRecord
    init(record: OutboxRecord)
    var body: some View

    /// `record.sendJob?.subject` trimmed of whitespace; empty or `nil` → `"(No subject)"`.
    nonisolated static func subject(for record: OutboxRecord) -> String
    /// `"To: " + (job.to + job.cc).map(\.displayName).joined(separator: ", ")`; no job or no recipients → `"To: —"`.
    nonisolated static func recipients(for record: OutboxRecord) -> String
    /// `"Not sent — " + (record.lastError ?? "Unknown error")`, rendered with `lineLimit(1)`.
    nonisolated static func errorLine(for record: OutboxRecord) -> String
}
```

### 3.5 `minimail/Features/Inbox/InboxPlaceholders.swift` (temporary)

```swift
import MailCore
import SwiftUI

// Each struct carries the FINAL signature of the screen it stands in for, so replacing it is a file move, not an API change.
// Module 10 deletes `ThreadScreen`, 11 deletes `ComposeScreen`, 12 deletes `LabelsScreen`, 13 deletes `SettingsScreen`
// and then the whole file. Bodies are minimal (§6.7) and use theme tokens only.

/// Replaced by module 10 (`minimail/Features/Thread/ThreadScreen.swift`).
struct ThreadScreen: View { init(threadId: String); var body: some View }

/// Replaced by module 11 (`minimail/Features/Compose/ComposeScreen.swift`).
struct ComposeScreen: View { init(input: ComposeInput); var body: some View }

/// Replaced by module 12 (`minimail/Features/Labels/LabelsScreen.swift`).
/// Contract for 12: call `onSelect(scope)` exactly once per selection and do NOT dismiss the sheet — the inbox sets
/// `activeSheet = nil` in its `onSelect` closure (§4.8).
struct LabelsScreen: View { init(onSelect: @escaping (InboxScope) -> Void); var body: some View }

/// Replaced by module 13 (`minimail/Features/Settings/SettingsScreen.swift`).
struct SettingsScreen: View { init(); var body: some View }
```

### 3.6 `minimail/App/RootView.swift` (modify)

```swift
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View
    // Group {
    //     switch env.auth.state {
    //     case .signedOut:                 SignInScreen()
    //     case .signedIn, .needsReauth:    InboxScreen(scope: .inbox)
    //     }
    // }
    // .preferredColorScheme(env.theme.preferredColorScheme)
    // .tint(themeTokens.accent)
    // .task { await env.startDeferredWork() }
}
// DELETED by this module: `SignedInPlaceholderView` (04 §3.8) and `RootPlaceholderView` (01 §3.11).
```

The `NavigationStack` lives **inside** `InboxScreen` (it owns the `path` binding) — 04's comment sketched `NavigationStack { InboxScreen(scope: .inbox) }`; see DEVIATION D2 (§10). The three modifiers keep 01's order so `startDeferredWork()` still runs exactly once (the `Group`'s identity does not change when the switch flips between `.signedIn` and `.needsReauth`).

### 3.7 Symbols consumed from dependencies (exact list)

| Module | Symbols |
|---|---|
| 01 | `AppEnvironment` (`db`, `isTesting`, `theme`, `settings`, `markFirstListPaint()`, `deferredWorkStarted`), `ThemeTokens`, `ThemeTokensReader`, `ThemeStore`, `SettingsStore`, `Log.ui` |
| 04 | `AuthStore.State` (`.signedOut` / `.signedIn(email:)` / `.needsReauth(email:)`, `.email`), `AuthStore.state`, `.lastError`, `.isSigningIn`, `.signIn()`, `.signOut()` (placeholder Settings only) |
| 06 | `ThreadQuery`, `ThreadQuery.Scope`, `ThreadQuery.pageSize`, `ThreadRow`, `ThreadChip`, `Queries.threads(_:now:timeZone:locale:labels:)`, `Queries.labelsById(_:)`, `Queries.failedSends(_:)`, `Queries.inboxUnreadThreadCount(_:)`, `Queries.todayThreadCount(_:_:)`, `LabelRecord`, `OutboxRecord` (+ `kind`, `state`, `lastError`, `sendJob`), `OutboxKind`, `SendJob`, `SyncStateRepository.get(_:_:)`, `SyncKey.inboxNextPageToken`, `DayBoundary`, `AppDatabase` (tests only), `TestDatabase` (tests), `InvariantChecks` (tests), `OutboxRepository` (tests only) |
| 07 | `SyncEngine.run(_:)`, `SyncReason.pullToRefresh/.loadOlderInbox/.loadOlderLabel(_:)`, `SyncStatus` (`phase`, `isOffline`, `lastError`), `SyncStatus.Phase.initialSync`, `MailActions.archive(threadId:)`, `.markRead(threadId:)`, `.markUnread(threadId:)`, `Outbox.retrySend(id:)`, `Outbox.discardSend(id:)` |
| 02 (through 06) | `Mailbox` (`displayName`), `ComposeMode` (`.replyAll`, `.forward`), `QuoteSource` (inside `SendJob`) |

---

## 4. Behaviour

### 4.1 Model creation and the first frame (architecture §12.2 step 2)

```
InboxScreen.body, first evaluation (model == nil):
    NavigationStack(path: $path) {
        themeTokens.background.ignoresSafeArea()        // identical to the LaunchBackground asset
    }
    .onAppear { if model == nil { model = InboxModel(env: env, scope: initialScope) } }

InboxModel.init(env:scope:clock:timeZone:locale:):
 1. store env, scope, clock, timeZone, locale
 2. day = DayBoundary.today(now: clock(), timeZone: timeZone)
 3. startAux()        // synchronous first value: labels, counts, failedSends, page token → hasOlder
 4. startThreads()    // synchronous first value: ≤ limit ThreadRows

InboxScreen.body, second evaluation (model != nil):
    NavigationStack(path: $path) { InboxListView(model: model) … }

InboxListView.onAppear → env.markFirstListPaint()        // ends the `coldStartToList` signpost (01 §3.10)
```

Order matters: `startAux()` runs **before** `startThreads()` so the first row fetch already sees `labels` and renders chips immediately; otherwise the first tick would show chip-less rows and the label fingerprint change (§4.3) would restart the observation one tick later.

Timing: `init` performs two reads on the main thread through `.immediate` scheduling. The row query is served by one partial index and returns at most 60 rows (06 §7.2 `testInboxQueryUnder5msWith5000Messages`: < 5 ms on 5,000 messages); the aux fetch is `labelsById` (~100 rows), two `COUNT(*)` on partial indexes, `failedSends` (indexed by `outbox_due`, normally zero rows) and one `syncState` primary-key lookup — together < 1 ms. All later values are fetched on GRDB's reader queue and delivered on the main queue `[ios-platform §2.6]`.

The state write inside `.onAppear` is applied in the same run-loop turn as the first layout, so the rows are normally part of the first committed frame; if a frame without the list is ever drawn it paints `themeTokens.background`, which is the same colour as `LaunchBackground` and therefore invisible (§10 A3).

### 4.2 Threads observation

```
startThreads():
 1. threadsCancellable?.cancel()
 2. let fetch = Queries.threads(query, now: clock(), timeZone: timeZone, locale: locale, labels: labels)
        // -> @Sendable (Database) throws -> [ThreadRow]
 3. threadsCancellable = ValueObservation
        .trackingConstantRegion(fetch)
        .removeDuplicates()
        .start(in: env.db,
               scheduling: .immediate,
               onError:  { [weak self] error in MainActor.assumeIsolated { self?.observationFailed(error) } },
               onChange: { [weak self] rows  in MainActor.assumeIsolated { self?.rows = rows } })
```

- `trackingConstantRegion` is valid because the SQL text and the touched tables depend only on the captured `ThreadQuery` (06 §4.12 `threadsSQL`), which is fixed for the lifetime of one observation.
- `.immediate` delivers the first value synchronously on the calling (main) thread and later values on the main dispatch queue `[ios-platform §2.6]` — hence `MainActor.assumeIsolated` inside the `@Sendable` callbacks (fallback in §10 A5).
- `.removeDuplicates()` suppresses re-renders when an aggregate rewrite produces identical rows (`ThreadRow: Equatable`, 06 D4).
- The observation is cancelled and restarted by: `setScope`, `toggleUnreadOnly`, `rowAppeared` (limit bump), `dayChanged` (boundary or zone changed), `apply(aux)` when the chip fingerprint changed, `refresh()` after an observation error. Each restart re-fetches synchronously, so the list never shows a stale scope for a frame.
- `observationFailed(error)`: `Log.ui.error("inbox observation failed: \(String(describing: error), privacy: .public)")`; `observationError = String(describing: error)`; the banner becomes `.error("Database unavailable")`; paging is disabled until `refresh()` restarts the observations.

### 4.3 Auxiliary observation

```
startAux():
 1. auxCancellable?.cancel()
 2. let day = self.day                                  // captured by value
 3. auxCancellable = ValueObservation
        .trackingConstantRegion { db in
            InboxAux(labels: try Queries.labelsById(db),
                     inboxUnread: try Queries.inboxUnreadThreadCount(db),
                     today: try Queries.todayThreadCount(db, day),
                     failedSends: try Queries.failedSends(db),
                     inboxNextPageToken: try SyncStateRepository.get(db, .inboxNextPageToken))
        }
        .removeDuplicates()
        .start(in: env.db, scheduling: .immediate,
               onError:  { [weak self] e   in MainActor.assumeIsolated { self?.observationFailed(e) } },
               onChange: { [weak self] aux in MainActor.assumeIsolated { self?.apply(aux) } })

apply(aux):
 1. labels = aux.labels; inboxUnreadCount = aux.inboxUnread; todayCount = aux.today; failedSends = aux.failedSends
 2. recomputeHasOlder(inboxToken: aux.inboxNextPageToken)
 3. let fp = aux.labels.mapValues { ThreadChip(id: $0.id, name: $0.name, textColor: $0.textColor, backgroundColor: $0.backgroundColor) }
    if fp != chipFingerprint {
        chipFingerprint = fp
        if threadsCancellable != nil { startThreads() }   // not during init: threads not started yet
    }

recomputeHasOlder(inboxToken):
 1. lastInboxToken = inboxToken
 2. switch scope {
    case .inbox, .today:  hasOlder = (inboxToken != nil)
    case .label(let id):  hasOlder = (labels[id]?.viewNextPageToken != nil)
    }
```

The fingerprint exists because 07 refreshes label counts every 5 minutes: those writes change `threadsUnread`/`countsFetchedAt` and tick this observation, but they must **not** restart the (more expensive) threads observation, since chips only depend on id, name and the two colours.

### 4.4 Filters, scope and title

| Operation | Steps |
|---|---|
| `setScope(s)` | `guard s != scope else { return }` → `scope = s` → `limit = pageSize` → `autoOlderLoads = 0` → `filterChangeId += 1` → `recomputeHasOlder(inboxToken: lastInboxToken)` → `startThreads()` |
| `toggleUnreadOnly()` | `unreadOnly.toggle()` → `limit = pageSize` → `autoOlderLoads = 0` → `filterChangeId += 1` → `startThreads()` |
| `query` | `ThreadQuery(scope: .inbox` / `.today(day)` / `.label(id: id)`, `unreadOnly: unreadOnly, limit: limit)` |
| `title` | `.inbox` → `"Inbox"`; `.today` → `"Today"`; `.label(id)` → `labels[id]?.name ?? id` |

The title menu emits only `.inbox` and `.today`; `.label(_)` can only come from the Labels sheet's `onSelect` (module 12). `unreadOnly` is intentionally preserved across scope changes.

### 4.5 Paging and "load older"

Architecture §8.2: "last row appears → `limit += 60`, then `sync.run(.loadOlderInbox/.loadOlderLabel)` when a page token exists".

```
rowAppeared(id):
 1. lastAppearedId = id
 2. guard observationError == nil else { return }          // paging disabled while the cache view is broken
 3. guard id == rows.last?.id else { return }              // only the last row triggers
 4. if rows.count >= limit { limit += pageSize; autoOlderLoads = 0; startThreads(); return }
 5. guard hasOlder, !isLoadingOlder else { return }        // cache exhausted; the server may have more
 6. loadOlder()

loadOlder():
 1. isLoadingOlder = true
 2. let before = rows.count
 3. Task { [weak self] in
        guard let self else { return }
        await env.sync.run(olderReason)                    // 07 §4.4: next messages.list page + metadata batch, no delta
        await Task.yield()                                 // let the observation tick land
        isLoadingOlder = false
        if rows.count > before { autoOlderLoads = 0; return }
        if hasOlder, autoOlderLoads < Self.maxAutoOlderLoads, rows.last?.id == lastAppearedId {
            autoOlderLoads += 1
            loadOlder()
        }
    }
```

Edge cases:
- A fetched page whose messages all belong to already-cached threads adds no row. The bounded retry (3) covers that and the single-flight behaviour of `SyncEngine.run` (a second caller returns immediately and the reason is re-run at the end of the active run, 07 §4.4.1). After 3 fruitless attempts the model waits for the next scroll to the end.
- `hasOlder` flips to `false` through the aux observation when 07 clears `syncState.inboxNextPageToken` or `label.viewNextPageToken` — no polling.
- `.today` deliberately pages through the **inbox** token: the newest 100 inbox messages can all be from today, and an older inbox page may still contain today's mail. There is never a server-side `after:` query (architecture D16, `[gmail-api gotcha 20]`).
- While `isLoadingOlder` is true the list shows a footer `ProgressView` row (§6.4). No spinner is shown for the limit bump (it is synchronous).
- Signed out / paused: `SyncEngine.run` returns immediately (`SyncError.paused`, 07), so `isLoadingOlder` flips back within one turn.

### 4.6 Banners (architecture §4.8 failure UX, §5.2 / D22)

```
banner:
    if case .needsReauth = env.auth.state, !reauthBannerDismissed   → .reauth
    else if env.syncStatus.isOffline                                → .offline
    else if let e = env.syncStatus.lastError                        → .error(e)
    else if observationError != nil                                 → .error("Database unavailable")
    else                                                            → nil
```

- `.reauth` — title "Sign in again to keep syncing", detail `env.auth.lastError` (passed as `detailOverride`), button "Sign in" → `Task { try? await env.auth.signIn() }` (the store publishes errors itself), "×" → `dismissReauthBanner()`. `authStateChanged(.signedIn)` clears the dismissal. The cached list stays fully usable while reauth is pending (architecture D22).
- `.offline` — title "Offline — changes will sync", symbol `wifi.slash`, no button. Optimistic changes stay on screen; 07 retries on the next trigger. Architecture §4.8 phrases this as a "nav-bar subtitle"; it is rendered as a banner row here (DEVIATION D3, §10).
- `.error(text)` — title "Couldn't refresh", detail = `text` (a `GmailError.userMessage` from 05, or "Database unavailable"), button "Retry" → `Task { await model.refresh() }`.
- Never an alert, never a modal, never a blocking overlay (architecture §8.2).

### 4.7 Empty states

`emptyState` is `nil` whenever `rows` is non-empty. Otherwise, in this order:

1. `env.syncStatus.phase == .initialSync` → `.initialSync`
2. `unreadOnly` → `.allCaughtUp`
3. `scope == .inbox` → `.noMail`; `scope == .today` → `.nothingToday`; `scope == .label(_)` → `.noMessages`

| State | Rendering |
|---|---|
| `.initialSync` | `ProgressView("Loading your inbox…")`, `.progressViewStyle(.circular)`, centred |
| `.noMail` | `ContentUnavailableView("No Mail", systemImage: "tray", description: Text("New mail you receive will appear here."))` |
| `.nothingToday` | `ContentUnavailableView("Nothing today", systemImage: "sun.max", description: Text("No mail received today."))` |
| `.allCaughtUp` | `ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("No unread mail here."))` |
| `.noMessages` | `ContentUnavailableView("No messages", systemImage: "tag", description: Text("No cached mail with this label."))` |

During the first sync the list fills progressively (07 commits one transaction per 25-message metadata batch), so `.initialSync` is replaced by rows as soon as the first batch lands.

### 4.8 Sheets and navigation

- `@State private var path: [ThreadRoute]` lives in `InboxScreen`. Rows push through a hidden `NavigationLink(value: ThreadRoute(threadId:))` (§6.3); `.navigationDestination(for: ThreadRoute.self) { ThreadScreen(threadId: $0.threadId) }` is attached to the stack content.
- `.sheet(item: $model.activeSheet)`:
  - `.labels` → `LabelsScreen(onSelect: { scope in model.setScope(scope); model.activeSheet = nil })`
  - `.settings` → `SettingsScreen()`
  - `.compose(input)` → `ComposeScreen(input: input)`
  Sheets inherit `AppEnvironment`, `ThemeStore` and `SettingsStore` from the window's environment.
- Scope switching never pushes or pops; dismissing the Labels sheet is the only navigation side effect of `onSelect`.
- Module 12's `LabelsScreen` is responsible for `sync.run(.labelOpened(id))` (modules.md §12); this module does not call it (§10 A15 documents the one-line fallback).
- Opening a thread does not change the path when it is already open (SwiftUI value-based links are idempotent per tap).

### 4.9 Day and time-zone changes (architecture §14 #19)

```
InboxScreen:
    .task { for await _ in InboxScreen.dayChangeStream() { model?.dayChanged() } }
    .onChange(of: scenePhase) { _, phase in if phase == .active { model?.dayChanged() } }

dayChangeStream():
    AsyncStream<Void> { continuation in
        let names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemTimeZoneDidChange]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield(()) }
        }
        continuation.onTermination = { _ in tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }

dayChanged(now:timeZone:):
 1. let d = DayBoundary.today(now: now, timeZone: timeZone)
 2. guard d != day || timeZone.identifier != self.timeZone.identifier else { return }
 3. day = d; self.timeZone = timeZone
 4. startAux(); startThreads()          // Today window, todayCount and every dateLabel depend on both
```

`addObserver(forName:object:queue:using:)` is used instead of `NotificationCenter.notifications(named:)` because `Notification` is not `Sendable` and the `for await` form does not compile cleanly in a main-actor context under Swift 6 strict checking (§10 A6). Observers are registered from `.task`, i.e. after the first frame — `AppEnvironment.init` must stay free of NotificationCenter observers (architecture §12.2 step 1). A day change that happens while the app is backgrounded is caught by the `scenePhase == .active` call.

### 4.10 Actions

Every action is fire-and-forget on the main actor; the result appears through the observation tick (architecture §12.1: "swipe archive → row gone: next frame").

| Operation | Effect |
|---|---|
| `archive(threadId:)` | `lastActionId += 1`; `Task { await env.actions.archive(threadId: threadId) }` → 07 writes `enqueueModify(remove: ["INBOX"], affected: messageIds)` + optimistic `E` + aggregates in one transaction, then `outbox.kick()`. In Inbox/Today the row disappears on the next tick; in a label scope it stays (the label is unchanged), which is correct Gmail behaviour. |
| `toggleRead(threadId:isUnread:)` | `lastActionId += 1`; `Task { isUnread ? await env.actions.markRead(threadId:) : await env.actions.markUnread(threadId:) }`. With `unreadOnly` on, a just-read row disappears. |
| `retrySend(_:)` | `Task { await env.outbox.retrySend(id: id) }` → row leaves the Outbox section (state `pending`), 07 drains. |
| `discardSend(_:)` | `lastActionId += 1`; `Task { await env.outbox.discardSend(id: id) }` → row deleted. |
| `openFailedSend(_:)` | `guard record.kind == .send, let job = record.sendJob else { Log.ui.error(…); return }`; `activeSheet = .compose(.failedSend(outboxId: record.id, job: job))`. Module 11 deletes the old job when the user sends the reopened draft. |
| `refresh()` | `if observationError != nil { observationError = nil; startAux(); startThreads() }`; `await env.sync.run(.pullToRefresh)` (07: always runs, re-arms failed modify ops, forces label counts). |

Two rapid toggles (read → unread) inside the 300 ms outbox debounce coalesce to zero outbox rows and zero requests (07 §4.6 / architecture §4.8); the row visibly flips twice.

### 4.11 Concurrency and isolation

- `InboxModel`, every `View`, `ActiveSheet`, `InboxBanner`, `InboxEmptyState`: main actor (implicit, `[ios-platform §5.6]`).
- `InboxScope`, `ThreadRoute`, `ComposeInput`, `InboxAux`: `nonisolated` + `Sendable` — they cross into `@Sendable` GRDB closures, actor calls and `Hashable` navigation storage.
- GRDB observation callbacks are `@Sendable` and (with `.immediate`) delivered on the main queue, so their bodies use `MainActor.assumeIsolated` (§10 A5).
- Actor calls (`env.sync`, `env.outbox`, `env.actions`) are always `await`ed inside an unstructured `Task { }` created on the main actor. The model does not retain these tasks: every call is an idempotent enqueue/drain and cancelling it would only lose a UI refresh, never user intent (intent is already committed to the `outbox` table by `MailActions` before the task suspends).
- `env.actions` is read at call time (07 D6: rebuilt after an account wipe).
- The model and the views never call `DatabasePool.read`/`write` directly; the only database access is through `ValueObservation` (architecture §12.3: "UI only observes"). Consequence for `make lint`: `minimail/Features/Inbox` contains no SQL keyword.

### 4.12 Error handling

| Source | Error | Handling |
|---|---|---|
| threads or aux `ValueObservation` | any `Error` (GRDB) | `Log.ui.error`; `observationError` set; banner `.error("Database unavailable")`; paging disabled; `refresh()` restarts both observations |
| `env.sync.run(_:)` | never throws (07) | outcome surfaces through `SyncStatus.isOffline` / `.lastError` → banner |
| `env.actions.*` | never throws (07 logs internally) | nothing to display; the optimistic state stays |
| `env.outbox.retrySend/discardSend` | never throws | — |
| `env.auth.signIn()` | throws `AuthError` | `try?`; `env.auth.lastError` is rendered as the reauth banner's detail line |
| `openFailedSend` on a non-send record | programmer error | `Log.ui.error("openFailedSend: outbox row \(record.id) is not a failed send")`; no sheet |

### 4.13 Performance constraints (architecture §12.1)

| Constraint | How it is met here |
|---|---|
| Cold start → first list paint < 400 ms | `init` = two `.immediate` reads (≤ 60 rows + one aux fetch); no `Task`, no network, no formatter construction in `body` |
| Scroll: 0 hitches at 120 Hz | `ThreadRow` is fully precomputed on the reader thread (06 §4.12); `body` does `String → Text` only; `List(.plain)` with stable `Identifiable` ids and `Equatable` rows; no image loading in rows |
| Swipe archive → row gone next frame | one transaction in `MailActions` → one observation tick |
| No timers, no polling | day changes come from notifications, paging from `onAppear`, sync from 07's triggers; `grep -rn "Timer\|DispatchSourceTimer" minimail/Features/Inbox` is empty |
| Observation churn | `.removeDuplicates()` on both observations; the threads observation restarts only on filter/limit/day/chip-fingerprint changes |

### 4.14 Lifecycle, sign-out and account wipe

- The model is created once per signed-in session. `RootView`'s switch keeps `InboxScreen`'s identity stable across `.signedIn ↔ .needsReauth` (one `case` clause covers both), so observations survive a reauth.
- Sign-out moves `auth.state` to `.signedOut`: `RootView` swaps in `SignInScreen`, `InboxScreen` and its `@State` model are destroyed and both observations are cancelled by their cancellables' `deinit`.
- 06 wipes the database **in place** (`AppDatabase.reset(pool)`), so an observation that survives a wipe simply reports empty results. If 07/06 ever replace the pool object (07 §10 O1), the model must be recreated — which the sign-out → sign-in round trip already does.

---

## 5. Data

This module defines no table, no migration, no `Info.plist` key, no `UserDefaults` key and reads no `Settings` field. It is a pure projection of module 06's tables.

### 5.1 Identifiers and value formats

| Value | Format / example |
|---|---|
| `ComposeInput.id` | `"message:replyAll:18c2f1a9b3d4e5f6"`, `"message:forward:18c2f1a9b3d4e5f6"`, `"failedSend:42"` |
| `ActiveSheet.id` | `"labels"`, `"settings"`, `"compose:failedSend:42"`, `"compose:message:forward:18c2f1a9b3d4e5f6"` |
| `ThreadRoute` | `ThreadRoute(threadId: "18c2f1a9b3d4e5f6")` (Gmail thread id, hex string) |
| `InboxScope.label` | `InboxScope.label(id: "Label_12")` |
| `InboxModel.pageSize` | `60` (= `ThreadQuery.pageSize`) |
| `InboxModel.maxAutoOlderLoads` | `3` |
| `ThreadQuery` produced, inbox | `ThreadQuery(scope: .inbox, unreadOnly: false, limit: 60)`; after one "load older": `limit: 120` |
| `ThreadQuery` produced, today | `ThreadQuery(scope: .today(DayBoundary(startMs: 1_757_541_600_000, endMs: 1_757_628_000_000)), unreadOnly: false, limit: 60)` — Europe/Berlin, 2025-09-11 |
| Page-token sources | inbox and today: `syncState.inboxNextPageToken`; label: `label.viewNextPageToken` of the scoped label row |
| `OutboxRecord` fields read | `id`, `kind` (must be `.send`), `state` (always `.failed` from `Queries.failedSends`), `lastError`, `sendJob` (`subject`, `to`, `cc`) |

### 5.2 Strings (English literals; `SWIFT_EMIT_LOC_STRINGS = YES` collects them, 01 §1.4)

| Where | Text |
|---|---|
| navigation title | `Inbox` · `Today` · `<label name>` |
| title menu items | `Inbox` · `Today` · `Labels…` (U+2026) |
| unread toggle a11y | label `Unread only`, value `On` / `Off`; in `.inbox` scope value `On, 12 unread` / `Off, 12 unread` |
| settings button a11y | `Settings` |
| swipe buttons | `Archive` · `Read` · `Unread` · `Retry` · `Delete` |
| banner `.reauth` | title `Sign in again to keep syncing`; detail = `AuthStore.lastError` (may be `nil`); action `Sign in`; dismiss a11y label `Dismiss` |
| banner `.offline` | title `Offline — changes will sync` (U+2014 em dash); no detail; no action |
| banner `.error` | title `Couldn't refresh` (U+2019 apostrophe); detail = the error text; action `Retry` |
| Outbox section header | `Outbox` |
| Outbox row | subject or `(No subject)`; `To: Alice, bob@example.com` or `To: —` (U+2014); `Not sent — <lastError>` or `Not sent — Unknown error` |
| initial-sync footer | `Loading your inbox…` (U+2026) |
| older-page footer | no visible text; a11y label `Loading older mail` |
| empty states | `No Mail` / `New mail you receive will appear here.` · `Nothing today` / `No mail received today.` · `All caught up` / `No unread mail here.` · `No messages` / `No cached mail with this label.` |
| row | `(No subject)`; a11y fragments `Unread`, `No subject`, `<n> messages`, `Has attachment`, `Label <name>` |
| placeholders | `Thread <id> (module 10)` · `Compose (module 11)` · `Cancel` · `Labels` · `Mailboxes` · `Settings (module 13)` · `Account` · `Sign out` |

### 5.3 SF Symbols (architecture §8.3)

| Use | Symbol |
|---|---|
| title menu: Inbox / Today / Labels… | `tray` / `sun.max` / `tag` |
| unread-only toggle: off / on | `line.3.horizontal.decrease.circle` / `line.3.horizontal.decrease.circle.fill` |
| settings button | `gearshape` |
| row attachment indicator | `paperclip` |
| swipe Archive | `archivebox` |
| swipe Read (row is unread) / Unread (row is read) | `envelope.open` / `envelope.badge` |
| Outbox row leading icon | `paperplane` |
| Outbox swipe Retry / Delete | `arrow.clockwise` / `trash` |
| banner reauth / offline / error | `person.crop.circle.badge.exclamationmark` / `wifi.slash` / `exclamationmark.triangle` |
| banner dismiss | `xmark` |
| empty states | `tray` / `sun.max` / `checkmark.circle` / `tag` |

### 5.4 Accessibility identifiers (used by §7 hosting tests and by 14's device checklist)

`inbox.list`, `inbox.unreadToggle`, `inbox.settings`, `inbox.banner`, `inbox.banner.action`, `inbox.banner.dismiss`, `inbox.row.<threadId>`, `inbox.outbox.row.<outboxId>`, `inbox.empty`, `inbox.loadingOlder`, `placeholder.signout`.

### 5.5 Theme tokens used (01 §3.6; no raw colours — enforced by `make lint`)

| Token | Where |
|---|---|
| `background` | list background, pre-model placeholder |
| `surface` | banner row background (`listRowBackground`) |
| `text` | participants, subject, banner title, Outbox subject, chip text fallback |
| `secondaryText` | date label, message count, snippet, attachment icon, banner symbol/detail, Outbox recipients/error |
| `unread` | the 10 pt unread dot |
| `chipBackground` | chip capsule fill when the label has no Gmail colour |
| `swipeArchive` | `.tint` of the leading swipe button |
| `swipeRead` | `.tint` of the trailing swipe button |
| `accent` | `.tint` of the Retry swipe button; inherited button tint from `RootView` |

Gmail label colours come from `ThreadChip.textColor` / `.backgroundColor` (`"#rrggbb"` strings written by 06 from `GmailLabelColor`) and are converted by `LabelChip.color(hex:)`; they are used unchanged in dark mode (§10 A9).

### 5.6 Codable / persisted shapes

None. `InboxScope`, `ActiveSheet`, `ComposeInput`, `ThreadRoute`, `InboxBanner` and `InboxEmptyState` are in-memory only; nothing in this module writes `UserDefaults`, files or the database.

---

## 6. UI

### 6.1 View hierarchy

```
InboxScreen                                     @State model: InboxModel?, @State path: [ThreadRoute]
                                                @Environment(AppEnvironment.self) env, @Environment(\.scenePhase) scenePhase
└─ NavigationStack(path: $path)
   └─ Group {
        if let model { InboxListView(model: model) }
        else         { themeTokens.background.ignoresSafeArea() }
      }
      .navigationDestination(for: ThreadRoute.self) { ThreadScreen(threadId: $0.threadId) }
   .onAppear      { if model == nil { model = InboxModel(env: env, scope: initialScope) } }
   .onChange(of: scenePhase) { _, phase in if phase == .active { model?.dayChanged() } }
   .onChange(of: env.auth.state) { _, state in model?.authStateChanged(state) }
   .task          { for await _ in InboxScreen.dayChangeStream() { model?.dayChanged() } }

InboxListView (@Bindable model)
└─ List {
     if let banner = model.banner   → Section { StatusBanner(…) }                                   (§6.5)
     if !model.failedSends.isEmpty  → Section("Outbox") { ForEach(model.failedSends) { FailedSendRow } }  (§6.6)
     if let empty = model.emptyState → Section { InboxEmptyView(state: empty) }                      (§6.4)
     else                            → Section { ForEach(model.rows) { row in threadRow(row) }
                                                 if model.isLoadingOlder { loadingOlderFooter } }   (§6.3/§6.4)
   }
   .listStyle(.plain)
   .accessibilityIdentifier("inbox.list")
   .refreshable { await model.refresh() }
   .navigationTitle(model.title)
   .navigationBarTitleDisplayMode(.large)
   .toolbarTitleMenu { … }                                                                          (§6.2)
   .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { unreadToggle; settingsButton } }        (§6.2)
   .sheet(item: $model.activeSheet) { … }                                                           (§4.8)
   .sensoryFeedback(.impact(weight: .light), trigger: model.lastActionId)
   .sensoryFeedback(.selection, trigger: model.filterChangeId)
   .background(themeTokens.background)
   .onAppear { env.markFirstListPaint() }
```

### 6.2 Toolbar

```swift
.toolbarTitleMenu {
    Button { model.setScope(.inbox) } label: { Label("Inbox", systemImage: "tray") }
    Button { model.setScope(.today) } label: { Label("Today", systemImage: "sun.max") }
    Divider()
    Button { model.activeSheet = .labels } label: { Label("Labels…", systemImage: "tag") }
}
.toolbar {
    ToolbarItemGroup(placement: .topBarTrailing) {
        Button { model.toggleUnreadOnly() } label: {
            Image(systemName: model.unreadOnly ? "line.3.horizontal.decrease.circle.fill"
                                               : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Unread only")
        .accessibilityValue(unreadToggleValue)          // §5.2
        .accessibilityIdentifier("inbox.unreadToggle")

        Button { model.activeSheet = .settings } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("inbox.settings")
    }
}
```

`unreadToggleValue` = `model.unreadOnly ? "On" : "Off"`, with `", \(model.inboxUnreadCount) unread"` appended when `model.scope == .inbox`. Title display mode is `.large` (iOS Mail mailbox style); the title menu is the chevron next to the large title (architecture D15 — no segmented control).

### 6.3 Thread row

```swift
// inside InboxListView
@ViewBuilder private func threadRow(_ row: ThreadRow) -> some View {
    ZStack {
        NavigationLink(value: ThreadRoute(threadId: row.id)) { EmptyView() }
            .opacity(0)
            .accessibilityHidden(true)                  // hides the disclosure chevron (iOS Mail has none)
        ThreadRowView(row: row)
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16))      // architecture §8.3
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
        Button { model.archive(threadId: row.id) } label: { Label("Archive", systemImage: "archivebox") }
            .tint(themeTokens.swipeArchive)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button { model.toggleRead(threadId: row.id, isUnread: row.isUnread) } label: {
            Label(row.isUnread ? "Read" : "Unread",
                  systemImage: row.isUnread ? "envelope.open" : "envelope.badge")
        }
        .tint(themeTokens.swipeRead)
    }
    .onAppear { model.rowAppeared(row.id) }
    .accessibilityIdentifier("inbox.row.\(row.id)")
}
```

```swift
// ThreadRowView.body — architecture §8.3 layout, verbatim structure
HStack(alignment: .top, spacing: 10) {
    Circle()
        .fill(row.isUnread ? themeTokens.unread : Color.clear)      // space is always reserved
        .frame(width: 10, height: 10)
        .padding(.top, 5)
    VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
            Text(row.participants)
                .font(.headline).fontWeight(row.isUnread ? .semibold : .regular)
                .lineLimit(1).foregroundStyle(themeTokens.text)
            if row.messageCount > 1 {
                Text("\(row.messageCount)").font(.caption).foregroundStyle(themeTokens.secondaryText)
            }
            Spacer(minLength: 4)
            if row.hasAttachments {
                Image(systemName: "paperclip").font(.caption).foregroundStyle(themeTokens.secondaryText)
            }
            Text(row.dateLabel).font(.subheadline).foregroundStyle(themeTokens.secondaryText).lineLimit(1)
        }
        Text(row.subject.isEmpty ? "(No subject)" : row.subject)
            .font(.subheadline).lineLimit(1).foregroundStyle(themeTokens.text)
        HStack(alignment: .top, spacing: 8) {
            Text(row.snippet).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(2)
            Spacer(minLength: 8)
            if !row.chips.isEmpty {
                HStack(spacing: 4) { ForEach(row.chips) { LabelChip(chip: $0) } }
            }
        }
    }
}
.contentShape(Rectangle())
.accessibilityElement(children: .ignore)
.accessibilityLabel(ThreadRowView.accessibilityLabel(for: row))
.accessibilityAddTraits(.isButton)
```

```swift
// LabelChip.body
Text(chip.name)
    .font(.caption2).lineLimit(1)
    .padding(.horizontal, 6).padding(.vertical, 2)
    .foregroundStyle(LabelChip.color(hex: chip.textColor) ?? themeTokens.text)
    .background(Capsule().fill(LabelChip.color(hex: chip.backgroundColor) ?? themeTokens.chipBackground))
    .accessibilityHidden(true)                     // the row's a11y label already names the labels
```

Dynamic Type: system text styles only, so the row grows with the content size; the `lineLimit`s keep the row bounded. Chips keep Gmail's colours in both appearances (§10 A9).

### 6.4 Empty and loading rows

- `InboxEmptyView`: the `ContentUnavailableView` / `ProgressView` of §4.7 with `.frame(maxWidth: .infinity, minHeight: 320)`, `.listRowSeparator(.hidden)`, `.listRowBackground(Color.clear)`, `.accessibilityIdentifier("inbox.empty")`. Rendering it as a list row (instead of replacing the `List`) keeps pull-to-refresh available.
- `loadingOlderFooter`: `ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).listRowSeparator(.hidden).accessibilityIdentifier("inbox.loadingOlder").accessibilityLabel("Loading older mail")`.
- Foreground delta syncs show no indicator at all (architecture §4.3: they are silent); only pull-to-refresh shows the system refresh control.

### 6.5 Status banner row

```swift
// StatusBanner.body
HStack(alignment: .center, spacing: 10) {
    Image(systemName: StatusBanner.symbol(for: kind))
        .foregroundStyle(themeTokens.secondaryText).accessibilityHidden(true)
    VStack(alignment: .leading, spacing: 2) {
        Text(StatusBanner.title(for: kind)).font(.subheadline).foregroundStyle(themeTokens.text)
        if let d = detailOverride ?? StatusBanner.detail(for: kind) {
            Text(d).font(.caption).foregroundStyle(themeTokens.secondaryText).lineLimit(2)
        }
    }
    Spacer(minLength: 8)
    if let t = StatusBanner.actionTitle(for: kind) {
        Button(t, action: action)
            .buttonStyle(.bordered).controlSize(.small).disabled(isBusy)
            .accessibilityIdentifier("inbox.banner.action")
    }
    if let dismiss {
        Button(action: dismiss) { Image(systemName: "xmark") }
            .buttonStyle(.plain).foregroundStyle(themeTokens.secondaryText)
            .accessibilityLabel("Dismiss").accessibilityIdentifier("inbox.banner.dismiss")
    }
}
.listRowBackground(themeTokens.surface)
.accessibilityElement(children: .contain)
.accessibilityIdentifier("inbox.banner")
```

Wiring in `InboxListView`:

| Kind | Construction |
|---|---|
| `.reauth` | `StatusBanner(kind: .reauth, isBusy: env.auth.isSigningIn, detailOverride: env.auth.lastError, action: { Task { try? await env.auth.signIn() } }, dismiss: { model.dismissReauthBanner() })` |
| `.offline` | `StatusBanner(kind: .offline, action: {})` |
| `.error(let text)` | `StatusBanner(kind: .error(text), action: { Task { await model.refresh() } })` |

`StatusBanner.detail(for:)` returns `nil` for `.reauth` and `.offline`, and the message for `.error(text)`; `detailOverride` exists so the reauth banner can show `AuthStore.lastError` without the pure helper reaching into the environment.

### 6.6 Outbox section

```swift
Section("Outbox") {
    ForEach(model.failedSends) { rec in
        Button { model.openFailedSend(rec) } label: { FailedSendRow(record: rec) }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { model.discardSend(rec.id) } label: { Label("Delete", systemImage: "trash") }
                Button { model.retrySend(rec.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .tint(themeTokens.accent)
            }
            .accessibilityIdentifier("inbox.outbox.row.\(rec.id)")
    }
}
```

```swift
// FailedSendRow.body
HStack(alignment: .top, spacing: 10) {
    Image(systemName: "paperplane").foregroundStyle(themeTokens.secondaryText)
        .padding(.top, 2).accessibilityHidden(true)
    VStack(alignment: .leading, spacing: 2) {
        Text(FailedSendRow.subject(for: record)).font(.subheadline).fontWeight(.semibold)
            .lineLimit(1).foregroundStyle(themeTokens.text)
        Text(FailedSendRow.recipients(for: record)).font(.footnote)
            .lineLimit(1).foregroundStyle(themeTokens.secondaryText)
        Text(FailedSendRow.errorLine(for: record)).font(.footnote)
            .lineLimit(1).foregroundStyle(themeTokens.secondaryText)
    }
}
.contentShape(Rectangle())
.accessibilityElement(children: .combine)
```

`Button(role: .destructive)` renders red through the system `[ios-platform §5.2]`, so no raw colour is needed. `allowsFullSwipe: false` prevents a full swipe from deleting an unsent mail by accident.

### 6.7 Placeholder screens

| Struct | Body |
|---|---|
| `ThreadScreen(threadId:)` | `Text("Thread \(threadId) (module 10)").foregroundStyle(themeTokens.secondaryText).navigationTitle("Thread").navigationBarTitleDisplayMode(.inline)` |
| `ComposeScreen(input:)` | `NavigationStack { Text("Compose (module 11)").navigationTitle("Compose").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } }` |
| `LabelsScreen(onSelect:)` | `NavigationStack { List { Section("Mailboxes") { Button { onSelect(.inbox) } label: { Label("Inbox", systemImage: "tray") }; Button { onSelect(.today) } label: { Label("Today", systemImage: "sun.max") } } }.navigationTitle("Labels") }` |
| `SettingsScreen()` | `NavigationStack { List { Section("Account") { Text(env.auth.state.email ?? "—"); Button("Sign out", role: .destructive) { Task { await env.auth.signOut() } }.accessibilityIdentifier("placeholder.signout") } }.navigationTitle("Settings") }` |

The `LabelsScreen` placeholder deliberately offers Inbox/Today only: it exercises the `onSelect` contract without pretending to list labels (module 12 owns that).

### 6.8 State → rendering matrix

| Condition | List content, top → bottom |
|---|---|
| signed in, empty cache, first sync running | `ProgressView("Loading your inbox…")` row |
| signed in, rows present, idle | thread rows |
| offline, rows present | offline banner, thread rows |
| `needsReauth` (not dismissed) | reauth banner, [Outbox section], thread rows |
| `needsReauth` (dismissed) + offline | offline banner, thread rows |
| failed sends present | [banner], "Outbox" section, thread rows or empty state |
| `unreadOnly` on, nothing unread | [banner], [Outbox], "All caught up" |
| `.today`, nothing received today | [banner], [Outbox], "Nothing today" |
| `.label(id)`, nothing cached for it | [banner], [Outbox], "No messages" |
| loading an older page | thread rows, footer spinner |
| observation failed | "Couldn't refresh · Database unavailable" banner, last known rows, paging disabled until Retry |

### 6.9 User action → effect

| Action | Effect |
|---|---|
| tap a row | push `ThreadRoute(threadId:)` onto `path` |
| leading full swipe | `model.archive(threadId:)`, light impact haptic, row leaves Inbox/Today |
| trailing full swipe | `model.toggleRead(threadId:isUnread:)`, light impact haptic |
| pull down | `model.refresh()` → `sync.run(.pullToRefresh)` |
| title menu → Inbox / Today | `model.setScope(_)`, selection haptic |
| title menu → Labels… | `activeSheet = .labels` |
| unread toggle | `model.toggleUnreadOnly()`, selection haptic |
| gear | `activeSheet = .settings` |
| scroll to the last row | limit bump or `sync.run(.loadOlder…)` (§4.5) |
| Outbox row tap | `activeSheet = .compose(.failedSend(…))` |
| Outbox swipe Retry / Delete | `model.retrySend(_:)` / `model.discardSend(_:)` (light impact on delete) |
| banner "Sign in" | `env.auth.signIn()` |
| banner "Retry" | `model.refresh()` |
| banner "×" | `model.dismissReauthBanner()` |

### 6.10 Appearance, Dynamic Type, haptics

- Colours only via `ThemeTokensReader` (§5.5); `RootView` applies `.preferredColorScheme(env.theme.preferredColorScheme)` and `.tint`, so Light/Dark/System all work without any per-view branch (architecture §10).
- Fonts: system text styles only (`.headline`, `.subheadline`, `.footnote`, `.caption`, `.caption2`); no fixed point sizes; Dynamic Type reflows the rows. Nothing in this module reacts to `UIContentSizeCategory.didChangeNotification` (that is 10's web view concern, architecture §14 #26).
- Haptics: `.sensoryFeedback(.impact(weight: .light), trigger: model.lastActionId)` for archive / read toggle / delete-send; `.sensoryFeedback(.selection, trigger: model.filterChangeId)` for scope and unread-toggle changes. `.success` on send belongs to module 11 (architecture §8.3).

---

## 7. Tests

Every test in this module is an **app test** run on the simulator with `xcodebuild` (`make test-app`, or one class with `make test-one T=minimailTests/InboxModelTests`). There are no `MailCore` package tests here (no package file is added), so `swift test` on Linux is unaffected. Classes are `final class …: XCTestCase` and run on the main actor (01 §7, `[ios-platform §5.6]`).

**Fixtures:** none on disk. All data is produced in code by module 06's test support (`minimailTests/Support/TestDatabase.swift`):

| Helper | Use here |
|---|---|
| `TestDatabase.parsed(id:threadId:internalDate:labels:from:to:cc:subject:snippet:…)` | single seeded messages (`t1`, `t2`, `t3`) |
| `TestDatabase.seed(_:_:selfAddresses:generation:now:)` | writes them through `upsertMetadata` + `recomputeAggregates` |
| `TestDatabase.seedMany(_:count:base:)` | 200 messages over 100 threads, every 5th unread, every 7th `Label_12`, every 11th TRASH-hidden, `internalDate = 1_757_000_000_000 + i × 60_000` (2025-09-04, never "today") |
| `TestDatabase.seedLabels(_:_:)` + `TestDatabase.sampleLabels` | label table incl. `Label_12` "Customers/ACME" (with colour), `Label_13` "Hidden", `Label_14` "IfUnread" |
| `InvariantChecks.assertAll(_:)` | architecture §3.5 invariants after every test that enqueues an outbox op |

**Shared setup** in both files:

```swift
var env: AppEnvironment!          // AppEnvironment(testing: true): temporary DatabasePool (06), OfflineURLProtocol (05 D8),
                                  // auth .signedOut, isolated UserDefaults suite
var model: InboxModel!
let seedNow: Int64 = 1_757_500_000_000          // 2025-09-10 10:26:40 UTC
let berlin = TimeZone(identifier: "Europe/Berlin")!

override func setUp() async throws { env = AppEnvironment(testing: true) }
override func tearDown() async throws { model?.stop(); model = nil; env = nil }

/// Polls every 20 ms until `cond()` or `timeout`; XCTFail on timeout.
func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async
```

Because the test host answers every request with `GmailError.offline` and `auth.state == .signedOut`, `SyncEngine.run` returns immediately (`SyncError.paused`) and `Outbox.drain` performs at most one offline round — the tests exercise this module, not 07.

### 7.1 `minimailTests/Inbox/InboxModelTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testImmediateRowsOnInit` | seed `t1`(date +3 min), `t2`(+2), `t3`(+1), all `["INBOX"]` | synchronously after `init`: `model.rows.map(\.id) == ["t1","t2","t3"]`; `model.title == "Inbox"`; `model.emptyState == nil`; `model.banner == nil`; `model.hasOlder == false`; `model.query == ThreadQuery(scope: .inbox, unreadOnly: false, limit: 60)` |
| `testEmptyStatesPerScope` | no seed; model `.inbox` | `emptyState == .noMail`; after `setScope(.today)` → `.nothingToday`; after `setScope(.label(id: "Label_12"))` → `.noMessages`; after `toggleUnreadOnly()` → `.allCaughtUp`; with `env.syncStatus.phase = .initialSync` → `.initialSync`; back to `.idle` → `.allCaughtUp` |
| `testQueryMirrorsState` | model with `clock: { fixed }` (`Date(timeIntervalSince1970: 1_757_580_000)`), `timeZone: berlin` | `setScope(.today)` → `query.scope == .today(DayBoundary.today(now: fixed, timeZone: berlin))` with `startMs == 1_757_541_600_000`, `endMs == 1_757_628_000_000`; `setScope(.label(id: "L"))` → `query.scope == .label(id: "L")`; `toggleUnreadOnly()` → `query.unreadOnly == true` |
| `testSetScopeSameIsNoop` | model `.inbox` | `setScope(.inbox)` → `filterChangeId == 0`; `setScope(.today)` → `1`; `setScope(.today)` again → `1` |
| `testUnreadToggleFilters` | `seedMany(count: 200)` | after `toggleUnreadOnly()`: every row has `isUnread == true`; `rows.map(\.id)` equals the result of `Queries.threads(ThreadQuery(scope: .inbox, unreadOnly: true, limit: 60), …)` evaluated directly through `env.db.read`; `filterChangeId == 1` |
| `testPagingIncreasesLimit` | `seedMany(count: 200)` (≥ 90 visible inbox threads) | `rows.count == 60`; `rowAppeared(rows[10].id)` → `limit == 60` and `rows.count == 60`; `rowAppeared(rows.last!.id)` → `limit == 120` and synchronously `rows.count > 60` |
| `testToggleResetsLimit` | as above, after one page (`limit == 120`) | `toggleUnreadOnly()` → `limit == 60`; `setScope(.today)` → `limit == 60`; `setScope(.inbox)` → `limit == 60` |
| `testHasOlderFromInboxToken` | seed `t1`; model | `hasOlder == false`; `try await env.db.write { try SyncStateRepository.set($0, .inboxNextPageToken, "p2") }` → `await waitUntil { model.hasOlder }`; `olderReason == .loadOlderInbox`; `setScope(.today)` → `hasOlder == true`, `olderReason == .loadOlderInbox`; set the key to `nil` → `await waitUntil { !model.hasOlder }` |
| `testHasOlderFromLabelToken` | `seedLabels(sampleLabels)`; `try await env.db.write { try LabelRepository.markViewFetched($0, labelId: "Label_12", nextPageToken: "lp", now: seedNow) }`; model; `setScope(.label(id: "Label_12"))` | `await waitUntil { model.hasOlder }`; `olderReason == .loadOlderLabel("Label_12")`; after `markViewFetched(…, nextPageToken: nil, …)` → `await waitUntil { !model.hasOlder }` |
| `testLoadOlderRunsAndStops` | write `inboxNextPageToken = "p2"` **before** creating the model; seed `t1`; model | `rowAppeared("t1")` → `isLoadingOlder == true`; `await waitUntil { !model.isLoadingOlder }`; `limit == 60`; `rows.count == 1`; the model made at most `maxAutoOlderLoads + 1 == 4` `run` calls (counted through `env.syncStatus.lastRunReason` staying `nil` in the signed-out host — assert instead that the call returns within 2 s and `isLoadingOlder == false`) |
| `testRowAppearedNotLastIsNoop` | seed `t1`, `t2`; token `"p2"` | `rowAppeared("t1")` (not the last row) → `isLoadingOlder == false`, `limit == 60` |
| `testRowAppearedBlockedByObservationError` | seed `t1`; token `"p2"`; model; `model._simulateObservationError("boom")` | `rowAppeared("t1")` → `isLoadingOlder == false` |
| `testTitleForLabelScope` | `seedLabels(sampleLabels)`; model | `setScope(.label(id: "Label_12"))` → `title == "Customers/ACME"`; `setScope(.label(id: "Label_999"))` → `title == "Label_999"`; `setScope(.today)` → `title == "Today"`; `setScope(.inbox)` → `"Inbox"` |
| `testChipsFromLabelTable` | `seedLabels(sampleLabels)`; seed `t1` with labels `["INBOX","Label_12","Label_13"]` | `rows[0].chips.map(\.id) == ["Label_12","Label_13"]` (sorted by id, ≤ 2); `rows[0].chips[0].name == "Customers/ACME"`; chip colours equal the values in `try env.db.read { try Queries.labelsById($0) }["Label_12"]` |
| `testLabelRenameRestartsThreads` | as above | `try await env.db.write { var l = try LabelRecord.fetchOne($0, key: "Label_12")!; l.name = "Renamed"; try l.update($0) }` → `await waitUntil { model.rows[0].chips.first?.name == "Renamed" }` |
| `testLabelCountChangeDoesNotRestartThreads` | as above | `try await env.db.write { var l = try LabelRecord.fetchOne($0, key: "Label_12")!; l.threadsUnread = 7; try l.update($0) }` → `await waitUntil { model.labels["Label_12"]?.threadsUnread == 7 }`; `model.rows` is unchanged (same array value) |
| `testCountsObserved` | `seedMany(count: 200)`; model | `inboxUnreadCount == (try env.db.read { try Queries.inboxUnreadThreadCount($0) })`; `todayCount == 0`; seed one extra INBOX message with `internalDate = Int64(Date().timeIntervalSince1970 * 1000)` → `await waitUntil { model.todayCount == 1 }` |
| `testArchiveRemovesRowAndEnqueues` | seed `t1`, `t2` `["INBOX","UNREAD"]`; model | `archive(threadId: "t1")` → `lastActionId == 1`; `await waitUntil { model.rows.map(\.id) == ["t2"] }`; `try env.db.read { try OutboxRepository.activeModifies($0) }.count == 1` with `removeLabelIds == ["INBOX"]` and `threadId == "t1"`; `try InvariantChecks.assertAll(env.db)` |
| `testArchiveInLabelScopeKeepsRow` | `seedLabels`; seed `t1` `["INBOX","Label_12"]`; model; `setScope(.label(id: "Label_12"))` | `archive(threadId: "t1")`; after `await waitUntil { (try? env.db.read { try ThreadRecord.fetchOne($0, key: "t1")?.inInbox }) == false }`: `model.rows.map(\.id) == ["t1"]`; `try InvariantChecks.assertAll(env.db)` |
| `testToggleReadFlipsAndCoalesces` | seed `t1` `["INBOX","UNREAD"]`; model | `toggleRead(threadId: "t1", isUnread: true)` → `await waitUntil { model.rows[0].isUnread == false }`; immediately `toggleRead(threadId: "t1", isUnread: false)` → `await waitUntil { model.rows[0].isUnread == true }`; `lastActionId == 2`; `try env.db.read { try OutboxRepository.activeModifies($0) }.isEmpty` (inverse deltas cancel, 06 `testEnqueueInverseCancelsToZeroRows`); `try InvariantChecks.assertAll(env.db)` |
| `testUnreadOnlyHidesRowAfterMarkRead` | seed `t1` unread, `t2` read; model; `toggleUnreadOnly()` | `rows.map(\.id) == ["t1"]`; `toggleRead(threadId: "t1", isUnread: true)` → `await waitUntil { model.rows.isEmpty }`; `emptyState == .allCaughtUp` |
| `testFailedSendsSectionAndOpen` | build `job = SendJob(mode: .replyAll, originalMessageId: "m1", threadId: "t1", messageID: "<x@example.com>", to: [Mailbox(name: "Bob", addr: "bob@example.com")], cc: [], subject: "Hi", typedText: "t", inReplyTo: nil, references: [], quoteSource: QuoteSource(author: nil, date: Date(timeIntervalSince1970: 1_757_500_000), subject: "Hi", to: [], cc: [], html: nil, text: nil), attachments: [], includeSignature: true)`; `let id = try await env.db.write { db -> Int64 in let id = try OutboxRepository.enqueueSend(db, job: job, now: seedNow); try OutboxRepository.fail(db, opId: id, error: "Daily quota exceeded"); return id }`; model | `await waitUntil { model.failedSends.count == 1 }`; `failedSends[0].id == id`; `failedSends[0].kind == .send`; `openFailedSend(failedSends[0])` → `model.activeSheet == .compose(.failedSend(outboxId: id, job: job))` and `model.activeSheet?.id == "compose:failedSend:\(id)"` |
| `testOpenFailedSendIgnoresModifyRow` | seed `t1`; `archive("t1")`; `await waitUntil { !(try! env.db.read { try OutboxRepository.activeModifies($0) }).isEmpty }`; take that record | `openFailedSend(record)` → `model.activeSheet == nil` |
| `testDiscardSendRemovesRow` | as `testFailedSendsSectionAndOpen` | `discardSend(id)` → `await waitUntil { model.failedSends.isEmpty }`; `try env.db.read { try OutboxRecord.fetchOne($0, key: id) } == nil`; `lastActionId == 1` |
| `testRetrySendLeavesFailedSection` | as above | `retrySend(id)` → `await waitUntil { model.failedSends.isEmpty }`; `await waitUntil { (try? env.db.read { try OutboxRecord.fetchOne($0, key: id)?.state }) != .failed }` (offline drain leaves it `pending` or `inFlight`, never `failed`) |
| `testBannerPriority` | model | `env.syncStatus.isOffline = true; env.syncStatus.lastError = "x"` → `banner == .offline`; `isOffline = false` → `banner == .error("x")`; `lastError = nil` → `banner == nil`; `model._simulateObservationError("boom")` → `banner == .error("Database unavailable")` |
| `testReauthBannerAndDismiss` | `env1 = AppEnvironment(testing: true)`; `try await env1.db.write { try SyncStateRepository.set($0, .accountEmail, "a@example.com") }`; `env2 = AppEnvironment(testing: true, databaseDirectory: env1.databaseDirectory)` (06 §3.16 overload; precondition: no `oauth.authState` Keychain item — otherwise `XCTSkip`, §10 A13); model on `env2` | `env2.auth.state == .needsReauth(email: "a@example.com")`; `banner == .reauth`; setting `env2.syncStatus.isOffline = true` keeps `banner == .reauth`; `dismissReauthBanner()` → `banner == .offline`; `authStateChanged(.signedIn(email: "a@example.com"))` → `reauthBannerDismissed == false` and `banner == .reauth` |
| `testDayChangeRestartsOnlyWhenBoundaryDiffers` | `fixed = Date(timeIntervalSince1970: 1_757_580_000)` (2025-09-11 10:40 CEST); seed `t1` with `internalDate = 1_757_580_000_000`, `["INBOX"]`; model `.today`, `clock: { fixed }`, `timeZone: berlin` | `rows.count == 1`; `dayChanged(now: fixed, timeZone: berlin)` → `day.startMs == 1_757_541_600_000` (unchanged), `rows.count == 1`; `dayChanged(now: fixed.addingTimeInterval(86_400), timeZone: berlin)` → `day.startMs == 1_757_628_000_000`, `rows.isEmpty`, `emptyState == .nothingToday`; `dayChanged(now: fixed.addingTimeInterval(86_400), timeZone: TimeZone(identifier: "Pacific/Auckland")!)` → `day == DayBoundary.today(now: fixed.addingTimeInterval(86_400), timeZone: auckland)` |
| `testRefreshWhenSignedOutReturnsFast` | model | `let t = Date(); await model.refresh()`; `XCTAssertLessThan(Date().timeIntervalSince(t), 1)`; `env.syncStatus.phase == .idle` |
| `testObservationErrorRecovery` | seed `t1`; model; `model._simulateObservationError("boom")` | `observationError != nil`; `banner == .error("Database unavailable")`; `await model.refresh()` → `observationError == nil`, `banner == nil`, `rows.map(\.id) == ["t1"]` |
| `testStopCancelsObservations` | seed `t1`; model; `model.stop()`; seed `t2` | after 300 ms `model.rows.map(\.id) == ["t1"]` (no tick after `stop`) |

30 tests.

### 7.2 `minimailTests/Inbox/InboxViewsTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testThreadRowAccessibilityLabel` | `ThreadRow(id: "t", participants: "Alice, Me", subject: "", snippet: "s", dateLabel: "14:32", isUnread: true, messageCount: 3, hasAttachments: true, chips: [ThreadChip(id: "L", name: "ACME", textColor: nil, backgroundColor: nil)])` | `== "Unread, Alice, Me, No subject, 14:32, 3 messages, Has attachment, Label ACME"`; a read row (`isUnread: false`, subject `"Hi"`, `messageCount: 1`, no attachment, no chips) → `"Alice, Me, Hi, 14:32"` |
| `testLabelChipColorParsing` | — | `LabelChip.color(hex: "#ff0000") != nil`; `"#FF0000"` non-nil; `"#ff000"` → `nil`; `"ff0000"` → `nil`; `"#gg0000"` → `nil`; `nil` → `nil`; the blue component of `UIColor(LabelChip.color(hex: "#0000ff")!)` is `1 ± 0.01` |
| `testStatusBannerStrings` | all three kinds | `.offline` → title `"Offline — changes will sync"`, symbol `"wifi.slash"`, `actionTitle == nil`, `detail == nil`; `.reauth` → `"Sign in again to keep syncing"`, `"person.crop.circle.badge.exclamationmark"`, `"Sign in"`, `detail == nil`; `.error("x")` → `"Couldn't refresh"`, `"exclamationmark.triangle"`, `"Retry"`, `detail == "x"` |
| `testFailedSendRowStrings` | `OutboxRecord` with `sendJob.subject == "  "`, `to == [Mailbox(name: "Alice", addr: "a@x.de")]`, `cc == [Mailbox(name: nil, addr: "b@x.de")]`, `lastError == nil` | `subject == "(No subject)"`; `recipients == "To: Alice, b@x.de"`; `errorLine == "Not sent — Unknown error"`; with `lastError == "Daily quota exceeded"` → `"Not sent — Daily quota exceeded"`; with `sendJob == nil` → `recipients == "To: —"` and `subject == "(No subject)"` |
| `testComposeInputAndSheetIds` | — | `ComposeInput.fromMessage(mode: .forward, threadId: "t", messageId: "m").id == "message:forward:m"`; `.failedSend(outboxId: 7, job: job).id == "failedSend:7"`; `ActiveSheet.labels.id == "labels"`; `.settings.id == "settings"`; `.compose(.failedSend(outboxId: 7, job: job)).id == "compose:failedSend:7"`; `ActiveSheet.compose(a) == .compose(a)`; `ActiveSheet.labels != .settings` |
| `testInboxScreenHostsSeededRows` | `env = AppEnvironment(testing: true)`; seed `t1`, `t2`; `let vc = UIHostingController(rootView: InboxScreen(scope: .inbox).environment(env).environment(env.theme).environment(env.settings))`; `vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)`; `vc.view.layoutIfNeeded()`; `RunLoop.main.run(until: Date() + 0.3)` | no crash; `vc.view.subviews.isEmpty == false`; a `UICollectionView`/`UITableView` descendant exists (walk `subviews` recursively — SwiftUI `List` backing); `env.deferredWorkStarted == false` (hosting the screen alone never starts sync) |
| `testRootViewSignedInShowsInbox` | the `.needsReauth` environment of `testReauthBannerAndDismiss`; host `RootView()` with the three `.environment` modifiers, same frame and layout | no crash; `vc.view.subviews.isEmpty == false`; `grep`-level guarantee that `SignedInPlaceholderView` no longer exists is covered by §9 item 1 |
| `testPlaceholderSignatures` | — | `_ = ThreadScreen(threadId: "t")`, `_ = ComposeScreen(input: .fromMessage(mode: .replyAll, threadId: "t", messageId: "m"))`, `_ = LabelsScreen(onSelect: { _ in })`, `_ = SettingsScreen()` compile and each hosts in a `UIHostingController` without crashing (modules 10–13 must keep this test compiling when they replace the placeholders) |
| `testLabelsPlaceholderCallsOnSelect` | `var picked: InboxScope?`; host `LabelsScreen(onSelect: { picked = $0 })` | hosting does not crash and the closure type is `(InboxScope) -> Void` (compile-time contract for module 12) |
| `testDayChangeStreamYieldsOnNotification` | `let stream = InboxScreen.dayChangeStream()`; a `Task` that awaits the first element and fulfils an expectation; `NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)` | expectation fulfilled within 1 s; after cancelling the task a second post does not crash (observers removed through `onTermination`) |

10 tests. Total for this module: 40.

### 7.3 Running them

```
make test-app                                   # whole app suite (this module + 01/04/05/06/07/08)
make test-one T=minimailTests/InboxModelTests    # this module's model tests
make test-one T=minimailTests/InboxViewsTests    # this module's view tests
```

---

## 8. Tasks

Ordered. Every verification command runs on the macOS runner unless marked otherwise. Sizes are the rough implementation budget.

- [ ] **T09.1 Shared value types + model skeleton** — files: `minimail/Features/Inbox/InboxModel.swift` (`InboxScope`, `ThreadRoute`, `ComposeInput`, `ActiveSheet`, `InboxBanner`, `InboxEmptyState`, `InboxAux`, and `InboxModel` with `init`, `startThreads`, `startAux`, `apply`, `recomputeHasOlder`, `query`, `title`, `banner`, `emptyState`, `olderReason`, `observationFailed`, `stop`). Done when `make build` succeeds under Swift 6 / MainActor default and an `InboxModel` created against a seeded pool exposes rows synchronously. Verify: `make build`. (~230 lines)
- [ ] **T09.2 Model behaviour + first test batch** — files: `minimail/Features/Inbox/InboxModel.swift` (`setScope`, `toggleUnreadOnly`, `rowAppeared`, `loadOlder`, `refresh`, `dayChanged`, `archive`, `toggleRead`, `retrySend`, `discardSend`, `openFailedSend`, `dismissReauthBanner`, `authStateChanged`, the `#if DEBUG _simulateObservationError` hook), `minimailTests/Inbox/InboxModelTests.swift` (setup helpers + the first 17 tests, `testImmediateRowsOnInit` … `testCountsObserved`). Done when those 17 pass. Verify: `make test-one T=minimailTests/InboxModelTests`. (~260 lines)
- [ ] **T09.3 Row and chip views** — files: `minimail/Features/Inbox/ThreadRowView.swift` (`ThreadRowView`, `ThreadRowView.accessibilityLabel(for:)`, `LabelChip`, `LabelChip.color(hex:)`), `minimailTests/Inbox/InboxViewsTests.swift` (`testThreadRowAccessibilityLabel`, `testLabelChipColorParsing`). Done when both pass and `make lint` finds no raw colour under `minimail/Features`. Verify: `make test-one T=minimailTests/InboxViewsTests && make lint`. (~130 lines)
- [ ] **T09.4 Banner and Outbox rows** — files: `minimail/Features/Inbox/StatusBanner.swift` (`StatusBanner` + 4 static helpers, `FailedSendRow` + 3 static helpers), `minimailTests/Inbox/InboxViewsTests.swift` (`testStatusBannerStrings`, `testFailedSendRowStrings`, `testComposeInputAndSheetIds`). Done when they pass. Verify: `make test-one T=minimailTests/InboxViewsTests`. (~140 lines)
- [ ] **T09.5 Screen, toolbar, sheets, navigation, placeholders, RootView** — files: `minimail/Features/Inbox/InboxScreen.swift` (`InboxScreen`, `dayChangeStream`, `InboxListView`, `InboxEmptyView`, toolbar, title menu, swipe actions, haptics, sheet routing, `markFirstListPaint`), `minimail/Features/Inbox/InboxPlaceholders.swift`, `minimail/App/RootView.swift` (branch + deletion of both placeholder views). Done when `make build` passes, 01's and 04's `AppEnvironmentTests` still pass, and `grep -rn "SignedInPlaceholderView\|RootPlaceholderView" minimail minimailTests` prints nothing. Verify: `make build && make test-one T=minimailTests/AppEnvironmentTests`. (~300 lines)
- [ ] **T09.6 Hosting and stream tests** — file: `minimailTests/Inbox/InboxViewsTests.swift` (`testInboxScreenHostsSeededRows`, `testRootViewSignedInShowsInbox`, `testPlaceholderSignatures`, `testLabelsPlaceholderCallsOnSelect`, `testDayChangeStreamYieldsOnNotification`). Done when all 10 view tests pass. Verify: `make test-one T=minimailTests/InboxViewsTests`. (~150 lines)
- [ ] **T09.7 Remaining model tests (actions, outbox, banners, day change)** — file: `minimailTests/Inbox/InboxModelTests.swift` (`testArchiveRemovesRowAndEnqueues` … `testStopCancelsObservations`). Done when all 30 model tests pass and every action test ends with `InvariantChecks.assertAll`. Verify: `make test-one T=minimailTests/InboxModelTests`. (~220 lines)
- [ ] **T09.8 Full suite, format, lint** — no new files. Done when `make format` produces no diff on a second run, `make lint` exits 0, and `make test-app` reports `failedTests: 0`. Verify: `make format && git diff --stat && make lint && make test-app`.
- [ ] **T09.9 Device / simulator pass** (manual, after 04's sign-in on the owner's iPhone) — no files. Boot `iPhone 17` (`xcrun simctl boot "iPhone 17"`), install the Debug build, and walk §9 item 10: rows, title menu, unread toggle, both swipes and their tints, Outbox section (force one failure by enabling airplane mode before a send), offline banner, dark mode. Save `xcrun simctl io booted screenshot .build/shot-inbox-light.png` and `…-dark.png`.

---

## 9. Acceptance criteria

1. `make build` succeeds with the five new `minimail/Features/Inbox/*.swift` files present, and both interim root placeholders are gone: `grep -rn "SignedInPlaceholderView\|RootPlaceholderView" minimail minimailTests | wc -l` prints `0`.
2. `make test-app` passes the 40 tests of §7 plus every earlier module's tests: `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact` shows `failedTests: 0`.
3. `make lint` exits 0. In particular no raw colour under `minimail/Features/Inbox` (`grep -rnE "Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)|\.tint\(\.(blue|indigo|green|red)\)" minimail/Features/Inbox` prints nothing — note that `UIColor(red:…)` would match, hence the `CGColor(srgbRed:…)` implementation of `LabelChip.color(hex:)`), and no SQL in the feature layer (`grep -rn "SELECT\|INSERT\|UPDATE\|DELETE" minimail/Features/Inbox | wc -l` prints `0`).
4. `InboxModel(env:scope:)` returns with `rows` already populated from a seeded pool (`testImmediateRowsOnInit`), i.e. the first frame of `InboxScreen` comes from SQLite without awaiting anything (architecture §12.2).
5. A leading swipe removes the row from Inbox on the next observation tick and leaves exactly one active `modify` op with `removeLabelIds == ["INBOX"]` (`testArchiveRemovesRowAndEnqueues`); read→unread inside the debounce window leaves zero ops (`testToggleReadFlipsAndCoalesces`); architecture §3.5 invariants hold after both (`InvariantChecks.assertAll`).
6. Scope switching, the unread toggle and paging change only `ThreadQuery` fields and restart the observation in place (`testQueryMirrorsState`, `testPagingIncreasesLimit`, `testToggleResetsLimit`, `testSetScopeSameIsNoop`); `hasOlder` follows the two page-token sources (`testHasOlderFromInboxToken`, `testHasOlderFromLabelToken`); automatic "load older" is bounded (`testLoadOlderRunsAndStops`).
7. Banner priority is reauth > offline > sync error > observation error, and the reauth banner is dismissable and re-armed on `.signedIn` (`testBannerPriority`, `testReauthBannerAndDismiss`). No alert is ever presented: `grep -rn "\.alert(" minimail/Features/Inbox | wc -l` prints `0`.
8. Failed sends appear in an "Outbox" section, open a `.compose(.failedSend)` sheet on tap, and Retry / Delete change the row state (`testFailedSendsSectionAndOpen`, `testRetrySendLeavesFailedSection`, `testDiscardSendRemovesRow`); a non-send outbox row never opens a sheet (`testOpenFailedSendIgnoresModifyRow`).
9. The day boundary is recomputed only when it actually changed, and the module contains no timer (`testDayChangeRestartsOnlyWhenBoundaryDiffers`; `grep -rn "Timer\|DispatchSourceTimer\|Task.sleep" minimail/Features/Inbox | wc -l` prints `0`).
10. Manual device step (owner's iPhone, after the module 04 sign-in): the inbox lists cached threads with unread dots, participant names, date labels and coloured chips; the large-title menu switches Inbox ↔ Today and opens the Labels sheet; the funnel toggles unread-only with a selection haptic; a leading full swipe archives with the indigo tint and a light impact; a trailing full swipe toggles read with the blue tint; airplane mode + pull-to-refresh shows "Offline — changes will sync", which disappears after the first successful request; scrolling to the end of more than 60 cached threads extends the list without a visible hitch; Light/Dark/System all render through system semantic colours with no white flash at launch.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | Architecture writes `InboxScreen(scope:)` without naming the scope type; `ThreadQuery.Scope.today` carries a `DayBoundary`. | DEVIATION (additive) | A new `InboxScope { inbox, today, label(id:) }` without a boundary is the screen/sheet-level scope; `InboxModel.query` maps it onto `ThreadQuery.Scope` using its own `day`. `LabelsScreen(onSelect: (InboxScope) -> Void)` is the contract for module 12. |
| D2 | Spec 04 §3.8 sketches `NavigationStack { InboxScreen(scope: .inbox) }` in `RootView`. | DEVIATION | The `NavigationStack(path:)` lives inside `InboxScreen`, which owns `path`; `RootView` renders `InboxScreen(scope: .inbox)` directly. modules.md §09 lists "`NavigationStack` root" in this module's scope. |
| D3 | Architecture §4.8 describes the offline state as "a nav-bar subtitle 'Offline — changes will sync' (`wifi.slash`)"; §8.2 and modules.md say `StatusBanner` rows. | DEVIATION (choice) | Rendered as a `StatusBanner` list row: iOS 17 SwiftUI has no navigation-subtitle API, and a custom `.principal` toolbar item conflicts with `.toolbarTitleMenu`. Same text, same symbol. |
| D4 | modules.md assigns `LabelChip` to module 12, but module 09 needs chips in the rows and ships first. | DEVIATION | `LabelChip` is defined in `minimail/Features/Inbox/ThreadRowView.swift`. Module 12 reuses it as-is (it may move the struct to `Features/Labels/` unchanged; the row keeps referring to `LabelChip`). |
| D5 | `minimail/Features/Inbox/InboxPlaceholders.swift` is not in the architecture §1.3 file tree. | DEVIATION (temporary) | Required so this module compiles and runs before 10–13 (precedent: 04's `SignedInPlaceholderView`). Each later module deletes its struct; 13 deletes the file; `testPlaceholderSignatures` keeps compiling against the real screens. |
| D6 | Architecture §8.2 lists the model's state as `query`, `rows`, `day`, counts, `failedSends`, `hasOlder`, `syncStatus`, `activeSheet`. | additive | `query` is computed from `scope`/`unreadOnly`/`limit`; `syncStatus` is read through `env.syncStatus` (one instance, 07). Added: `labels`, `isLoadingOlder`, `observationError`, `lastActionId`, `filterChangeId`, `reauthBannerDismissed`, plus `InboxBanner`, `InboxEmptyState`, `olderReason`. |
| D7 | `ComposeInput` is `Equatable` + `Identifiable`, not `Hashable`. | constraint | `SendJob.quoteSource: QuoteSource` is `Codable, Sendable, Equatable` only (architecture §2.2), and `.sheet(item:)` needs `Identifiable` only. `ThreadRoute` (the navigation value) is `Hashable`, as `NavigationPath` requires. |
| D8 | The aux observation calls `SyncStateRepository.get(db, .inboxNextPageToken)` from a feature-layer closure; architecture §2.1 rule 3 says UI `SELECT`s live in `Queries`. | assumption | A repository accessor is not a SQL string in `Features/` — the rule's intent (no SQL outside `Store/`) holds, and `make lint`'s grep passes. If 06 later adds `Queries.inboxNextPageToken`, switch to it (one line). |
| D9 | `make lint`'s raw-colour regex `Color\((red|…)` also matches the substring inside `UIColor(red:` and `Color(red:green:blue:)`. | resolved | `LabelChip.color(hex:)` builds `Color(cgColor: CGColor(srgbRed: r, green: g, blue: b, alpha: 1))`, which the regex does not match, and which needs no `UIKit` import. |
| D10 | Test files `minimailTests/Inbox/*.swift` are not in the architecture §1.3 tree (which lists `SmokeTests` for screen hosting). | DEVIATION (additive) | Same precedent as 01/04/05/06/07/08: module-owned test files. Module 14's `SmokeTests` still hosts `InboxScreen` against a seeded DB. |
| A1 | `.toolbarTitleMenu(content:)` and `.sensoryFeedback(_:trigger:)` are not covered by the research files (`[ios-platform §5.2]` lists the other list APIs). | assumed (Apple docs: `toolbarTitleMenu` iOS 16.0, `sensoryFeedback` iOS 17.0) | If either does not compile against the iOS 17.0 floor: title menu → a `Menu` in `ToolbarItem(placement: .principal)` showing the title with a chevron; haptics → `UIImpactFeedbackGenerator(style: .light).impactOccurred()` / `UISelectionFeedbackGenerator().selectionChanged()` invoked from the model's action methods. |
| A2 | `AnyDatabaseCancellable` is the return type of `ValueObservation.start(in:scheduling:onError:onChange:)`. | UNVERIFIED `[ios-platform §2.6]` | Store whatever type GRDB 7.11.1 returns; the name appears only in the two private properties, so a different spelling is a one-line fix. |
| A3 | Creating the model in `.onAppear` still yields rows in the first committed frame. | assumption | The state write happens in the same run-loop turn as the first layout. If a blank frame is ever drawn it paints `themeTokens.background`, identical to the `LaunchBackground` asset, so it is invisible; the `coldStartToList` signpost ends in `InboxListView.onAppear`, so the device measurement stays honest either way. |
| A4 | `ValueObservation.removeDuplicates()` is available for `Equatable` values on a `trackingConstantRegion` observation. | GRDB 7 documented API | If unavailable, drop both calls: `ThreadRow`/`InboxAux` equality still limits SwiftUI's diffing work, and `apply(aux)` already compares the chip fingerprint before restarting the threads observation. |
| A5 | With `.immediate` scheduling every later notification is delivered on the main dispatch queue, so `MainActor.assumeIsolated` in the `@Sendable` callbacks is sound. | `[ios-platform §2.6]` | If GRDB 7.11.1 offers a main-actor-typed `onChange` (or `scheduling: .mainActor`), prefer it and delete the `assumeIsolated` wrappers. |
| A6 | `NotificationCenter.notifications(named:)` does not compile cleanly in a main-actor `for await` under Swift 6 (non-`Sendable` `Notification`). | assumption | `dayChangeStream()` wraps `addObserver(forName:object:queue:using:)`. If the async-sequence form does compile, either is acceptable — the helper stays because it is the unit-testable seam. |
| A7 | `NSCalendarDayChanged` / `NSSystemTimeZoneDidChange` reach a foreground app; a backgrounded app learns about the change on the next activation. | Apple docs | The `scenePhase == .active` call covers the background case; architecture §14 #19 names all three triggers. |
| A8 | Pull-to-refresh during an active run returns immediately (single-flight `SyncEngine.run`), so the refresh control stops early. | 07 §4.4.1 | Accepted: the queued `.pullToRefresh` still executes at the end of the active run, and the observation delivers its result whenever it lands. |
| A9 | Gmail label colours are shown unchanged in dark mode. | choice | Gmail's own clients do the same; labels without colours fall back to `chipBackground`/`text`, which adapt. Revisit only if a colour proves unreadable on device (§9 item 10). |
| A10 | A hidden `NavigationLink(value:)` with `opacity(0)` inside a `ZStack` removes the disclosure chevron while keeping cell highlighting and value-based navigation. | common SwiftUI pattern | Fallback: use the visible `NavigationLink` and accept the chevron — no behavioural change. |
| A11 | `OutboxRecord.lastError` of a failed send holds a short user-facing string (`GmailError.userMessage`, or 07's synthetic "Attachments too large to forward (25.0 MB)" / "Attachment <name> no longer available" / "Original message no longer available"). | 07 §10 A2 (assumption directed at 06) | Displayed verbatim after "Not sent — " with `lineLimit(1)`. If 06 ever stores `String(describing:)` the row still renders; only the wording degrades. |
| A12 | Provoking a `ValueObservation` failure needs a DEBUG-only hook. | test design | `#if DEBUG func _simulateObservationError(_ text: String) { observationFailed(NSError(domain: "minimail.test", code: 1, userInfo: [NSLocalizedDescriptionKey: text])) } #endif`. Production code never calls it; `make lint` allows the underscore name. |
| A13 | The simulator Keychain holds no `oauth.authState` item while `testReauthBannerAndDismiss` runs. | shared precondition with 06's `testCachedEmailReadFromSyncState` and 04's tests | If a stale item exists the test calls `XCTSkip("Keychain item present")`; 04's tests delete their own accounts in `tearDown`. |
| A14 | `AppEnvironment(testing: true)` opens a `DatabasePool` (06 `openTemporary`), so `trackingConstantRegion` behaves as in production. | 06 §3.16 | If 06 ever switches the testing environment to a `DatabaseQueue`, the observations still work (GRDB supports both writers); `.immediate` semantics are identical. |
| A15 | `sync.run(.labelOpened(id))` is triggered by module 12's `LabelsScreen`, not by `setScope(.label(id:))`. | modules.md §12 | If 12 prefers the model to do it, add one line to `setScope`: `if case .label(let id) = scope { Task { await env.sync.run(.labelOpened(id)) } }`; `SyncEngine`'s single-flight makes a double trigger harmless. |
| A16 | "Today" pages through the inbox page token, so a very busy day can require several "load older" rounds. | choice | Uniform paging rule with the 3-round bound; never a server-side `after:` query (architecture D16, `[gmail-api gotcha 20]`). |
| A17 | `AppEnvironment.actions` is `private(set) var` and may be rebuilt after an account wipe (07 D6). | 07 §3.10 | The model never caches it; every action reads `env.actions` at call time. |
| A18 | Hosting `InboxScreen` in a test never starts sync or network activity. | design | `InboxModel.init` performs no `Task`; `startDeferredWork()` is only called from `RootView.task`, and the test host's default `OfflineURLProtocol` blocks the network anyway (05 D8). Asserted by `testInboxScreenHostsSeededRows`. |
