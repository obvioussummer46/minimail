# 09-inbox-list — Inbox screen/model, rows, filters, swipe actions, banners, paging

Module id: `09-inbox-list`. Depends on: `01-project-setup` (`AppEnvironment`, `ThemeTokensReader`/`ThemeTokens`, `Log.ui`, `RootView`), `06-storage` (`ThreadQuery`, `ThreadRow`, `ThreadChip`, `Queries`, `LabelRecord`, `OutboxRecord`, `SendJob`, `DayBoundary`, `SyncStateRepository`), `07-sync-outbox` (`SyncEngine.run`, `SyncReason`, `SyncStatus`, `MailActions`, `Outbox.retrySend/discardSend`). Transitively uses `04-auth` (`AuthStore.state/isSigningIn/signIn`) and `05-gmail-client` (test-host `OfflineURLProtocol` default). Consumed by: `10-thread-view` (`ThreadRoute`, `ComposeInput.fromMessage`, `InboxScope`), `11-compose` (`ComposeInput`), `12-labels` (`InboxScope`, `LabelChip`, the `LabelsScreen(onSelect:)` contract), `13-settings-theme-signature` (the `SettingsScreen()` slot), `14-qa` (`SmokeTests` hosts `InboxScreen`).

Source of truth: `docs/plan/design/architecture.md` §2.4 (Store/Sync interfaces), §4.1 (triggers), §4.8 (failure UX), §5.2 (reauth routing), §8.1–§8.3, §8.6, §10, §12.1–§12.3, §13.3, §14 #19, §15 D15/D16/D21/D22; `docs/plan/design/modules.md` (09 scope); `docs/plan/research/ios-platform.md` §2.6 (ValueObservation), §5.1–§5.2 (Observable, lists, swipe, refreshable, ContentUnavailableView), §5.6 (Swift 6 isolation).

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. `InboxScreen(scope:)` — the root of the signed-in app: `NavigationStack`, `List(.plain)` of `ThreadRowView`s, `.toolbarTitleMenu` scope switching (Inbox / Today / Labels…), unread-only toggle, Settings button, pull-to-refresh, leading/trailing swipe actions with theme tints and haptics, empty states, initial-sync footer, status banner rows (offline / error / reauth), the "Outbox" section for failed sends (Retry / Delete / tap → compose), "load older" paging, `ThreadRoute` navigation and the single `ActiveSheet` slot (architecture §8.1–§8.3).
2. `InboxModel` — `@Observable` main-actor model owning two GRDB `ValueObservation`s (`.immediate`): the thread rows of `Queries.threads` (limit paging 60/+60) and an auxiliary projection (label table, local counts, failed sends, inbox page token). It converts UI intents into `MailActions` / `Outbox` / `SyncEngine.run` calls and recomputes the `DayBoundary` on day/time-zone change and scene activation (architecture §8.6, §14 #19).
3. `ThreadRowView` + `LabelChip` — the iOS-Mail-style row of architecture §8.3 rendered from the precomputed `ThreadRow` (no formatting in `body`).
4. `StatusBanner` + `FailedSendRow` — the non-blocking status rows of architecture §4.8 / §8.2.
5. Value types shared with later modules: `InboxScope`, `ThreadRoute`, `ActiveSheet`, `ComposeInput`, `InboxBanner`, `InboxEmptyState`.
6. `RootView` modification: `SignedInPlaceholderView` (04) and `RootPlaceholderView` (01) are deleted; the signed-in/needs-reauth branch shows `InboxScreen(scope: .inbox)`.
7. Interim placeholders `ThreadScreen(threadId:)`, `ComposeScreen(input:)`, `LabelsScreen(onSelect:)`, `SettingsScreen()` with the exact signatures modules 10–13 will implement, so this module compiles and runs before them (same precedent as 04's `SignedInPlaceholderView`).
8. App tests `minimailTests/Inbox/InboxModelTests.swift`, `minimailTests/Inbox/InboxViewsTests.swift`.

### 1.2 Explicitly out of scope (owned elsewhere)

- Thread screen, `ensureThreadLoaded`, mark-read-on-open, attachments (10). Compose prefill, `SendJob` construction, resend of a failed job (11). Labels sheet content, `sync.run(.labelOpened(id))`, label counts refresh (12). Settings screen, theme picker, sign-out row (13 — this module's `SettingsScreen` placeholder keeps a Sign out button only so 04's device check stays possible).
- Any SQL text (`Queries` / repositories only), any `GmailClient` or `URLSession` call, any sync decision (`SyncEngine` decides throttling, page tokens, re-arming).
- The `NavigationStack` path being driven programmatically by other modules (10 pops itself with `dismiss`).
- Undo toast, configurable swipes, per-message read state, search (architecture §16).

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 10 thread view | `ThreadRoute` (pushed value; 10 implements the destination `ThreadScreen(threadId:)` and deletes the placeholder), `ComposeInput.fromMessage(mode:threadId:messageId:)` for its Reply all / Forward sheet |
| 11 compose | `ComposeInput` (both cases), `ComposeScreen(input:)` signature (replaces the placeholder) |
| 12 labels | `InboxScope` (the `onSelect` payload), `LabelsScreen(onSelect:)` signature (replaces the placeholder), `LabelChip` (moved or reused, see §10 D4) |
| 13 settings | `SettingsScreen()` signature (replaces the placeholder) |
| 14 qa | `InboxScreen(scope:)` hosted in `SmokeTests`, `InboxModel` state assertions, accessibility identifiers of §5.4 |

---

## 2. Files

| Path (repo root) | Kind | Purpose |
|---|---|---|
| `minimail/Features/Inbox/InboxModel.swift` | new | `InboxScope`, `ThreadRoute`, `ComposeInput`, `ActiveSheet`, `InboxBanner`, `InboxEmptyState`, `InboxModel` (observations, paging, actions, day change) |
| `minimail/Features/Inbox/InboxScreen.swift` | new | `InboxScreen` (NavigationStack, model lifecycle, notifications), private `InboxListView`, `InboxEmptyView`, toolbar, sheet routing |
| `minimail/Features/Inbox/ThreadRowView.swift` | new | `ThreadRowView` (architecture §8.3 row), `LabelChip` (Gmail-colour capsule) |
| `minimail/Features/Inbox/StatusBanner.swift` | new | `StatusBanner` (offline / error / reauth rows), `FailedSendRow` (Outbox section row) |
| `minimail/Features/Inbox/InboxPlaceholders.swift` | new (temporary) | interim `ThreadScreen`, `ComposeScreen`, `LabelsScreen`, `SettingsScreen` with the final signatures; each of modules 10–13 deletes its own struct, 13 deletes the file |
| `minimail/App/RootView.swift` | modify | signed-in branch → `InboxScreen(scope: .inbox)`; delete `SignedInPlaceholderView` and `RootPlaceholderView` |
| `minimailTests/Inbox/InboxModelTests.swift` | new | model behaviour against `AppEnvironment(testing: true)` + seeded pool (§7) |
| `minimailTests/Inbox/InboxViewsTests.swift` | new | pure view helpers (strings, colours, ids), hosting smoke (§7) |

No package (`MailCore`/`MailHTML`) files. No `project.yml` change (the app target globs `minimail/`, the test target globs `minimailTests/`).

---

## 3. Public interface

All app-target types are `@MainActor` by default (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); the value types shared with actors/tests are marked `nonisolated`. Signatures marked `// verbatim` come from architecture §2.4 / §8.1 / modules.md.

### 3.1 `minimail/Features/Inbox/InboxModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import Observation

/// Which mailbox the list shows. `.today` carries no `DayBoundary`: the boundary is owned by `InboxModel.day` and recomputed on day change,
/// so the scope is a plain value that `LabelsScreen(onSelect:)` (12) can hand back and the title menu can compare.
nonisolated enum InboxScope: Hashable, Sendable {
    case inbox
    case today
    case label(id: String)          // Gmail label id, e.g. "Label_12" (never "INBOX")
}

/// Navigation value pushed by a row (architecture §8.1: `ThreadRoute(threadId)`; `.navigationDestination(for: ThreadRoute.self)`).
nonisolated struct ThreadRoute: Hashable, Sendable {                                                          // verbatim (name, field)
    let threadId: String
    init(threadId: String)
}

/// Input of `ComposeScreen(input:)` (11). `.fromMessage` is emitted by 10 (Reply all / Forward on a cached message);
/// `.failedSend` by the Outbox section here (architecture §4.8: "tap → Compose prefilled from the job").
/// `Equatable` only (`SendJob.quoteSource` is not `Hashable`); `Identifiable` for `.sheet(item:)`.
nonisolated enum ComposeInput: Equatable, Sendable, Identifiable {
    case fromMessage(mode: ComposeMode, threadId: String, messageId: String)
    case failedSend(outboxId: Int64, job: SendJob)
    /// `"message:\(mode.rawValue):\(messageId)"` / `"failedSend:\(outboxId)"`.
    var id: String { get }
}

/// The single sheet slot of the inbox (architecture §8.1: `enum ActiveSheet { labels, settings, compose(ComposeInput) }`).
enum ActiveSheet: Identifiable, Equatable {                                                                    // verbatim cases
    case labels
    case settings
    case compose(ComposeInput)
    /// `"labels"` / `"settings"` / `"compose:" + input.id`.
    var id: String { get }
}

/// The status row shown above the threads — at most one, chosen in this priority order (§4.6).
enum InboxBanner: Equatable {
    case reauth                     // auth.state == .needsReauth and not dismissed → "Sign in again"
    case offline                    // syncStatus.isOffline → "Offline — changes will sync"
    case error(String)              // syncStatus.lastError, or "Database unavailable" when an observation failed → "Couldn't refresh · Retry"
}

/// What the list shows when `rows` is empty (§4.7; architecture §8.2 InboxScreen column "Empty / loading / error").
enum InboxEmptyState: Equatable {
    case initialSync                // syncStatus.phase == .initialSync → ProgressView("Loading your inbox…")
    case allCaughtUp                // unreadOnly == true → "All caught up" (checkmark.circle)
    case noMail                     // scope .inbox → "No Mail" (tray)
    case nothingToday               // scope .today → "Nothing today" (sun.max)
    case noMessages                 // scope .label → "No messages" (tag)
}

/// Main-actor model of the inbox list (architecture §8.2 row "InboxScreen / InboxModel"). One instance per `InboxScreen`, created in
/// `InboxScreen.onAppear`, alive for the process (the inbox is the navigation root).
@Observable final class InboxModel {
    /// 60 (`ThreadQuery.pageSize`); `limit` grows by this amount per page (architecture §2.4 "limit 60, +60 per page").
    static let pageSize: Int = ThreadQuery.pageSize
    /// Consecutive automatic `sync.run(.loadOlder…)` calls without a row-count change before the model waits for the next scroll (§4.5).
    static let maxAutoOlderLoads = 3

    /// Composition root; read for `db`, `syncStatus`, `sync`, `actions` (re-read on every call — 07 rebuilds it after a wipe), `outbox`, `auth`.
    let env: AppEnvironment

    // ---- observed state (private(set): only the model mutates) ----
    private(set) var scope: InboxScope
    private(set) var unreadOnly: Bool = false
    private(set) var limit: Int = InboxModel.pageSize
    private(set) var day: DayBoundary                                   // today in `timeZone` at the last (re)computation
    private(set) var rows: [ThreadRow] = []                             // ValueObservation(.immediate) of Queries.threads(query)
    private(set) var labels: [String: LabelRecord] = [:]                // Queries.labelsById — chips, label-scope title, label page token
    private(set) var inboxUnreadCount: Int = 0                          // Queries.inboxUnreadThreadCount (local; matches the list)
    private(set) var todayCount: Int = 0                                // Queries.todayThreadCount(day)
    private(set) var failedSends: [OutboxRecord] = []                   // Queries.failedSends — the "Outbox" section
    private(set) var hasOlder: Bool = false                             // a page token exists for the current scope (§4.5)
    private(set) var isLoadingOlder: Bool = false                       // a sync.run(.loadOlder…) started by `rowAppeared` is in flight
    private(set) var observationError: String?                          // GRDB error text of a failed observation; nil after `refresh()` restarts it
    var activeSheet: ActiveSheet?                                       // bound by the screen (`.sheet(item:)`)
    private(set) var lastActionId: Int = 0                              // `.sensoryFeedback(.impact(weight: .light), trigger:)`
    private(set) var filterChangeId: Int = 0                            // `.sensoryFeedback(.selection, trigger:)`
    private(set) var reauthBannerDismissed: Bool = false

    // ---- derived (computed, no storage) ----
    /// `ThreadQuery(scope: scope→ThreadQuery.Scope (`.today` → `.today(day)`), unreadOnly: unreadOnly, limit: limit)`.
    var query: ThreadQuery { get }
    /// `"Inbox"` / `"Today"` / `labels[id]?.name ?? id`.
    var title: String { get }
    /// Priority: `.reauth` (auth.state is `.needsReauth` and `!reauthBannerDismissed`) → `.offline` (`env.syncStatus.isOffline`)
    /// → `.error(env.syncStatus.lastError)` → `.error("Database unavailable")` when `observationError != nil` → nil.
    var banner: InboxBanner? { get }
    /// nil when `rows` is non-empty; else `.initialSync` when `env.syncStatus.phase == .initialSync`; else `.allCaughtUp` when `unreadOnly`;
    /// else by scope: `.noMail` / `.nothingToday` / `.noMessages`.
    var emptyState: InboxEmptyState? { get }
    /// `.loadOlderInbox` for `.inbox` and `.today`; `.loadOlderLabel(id)` for `.label(id)`.
    var olderReason: SyncReason { get }

    /// Starts both observations synchronously (`.immediate`): after `init` returns, `labels`, counts, `failedSends`, `hasOlder` and `rows`
    /// hold the current cache contents (architecture §12.2 step 2). `clock` feeds `RowDateLabeler.now` and `DayBoundary.today`;
    /// `timeZone`/`locale` feed `Queries.threads`. No network, no sync call, no `Task`.
    init(env: AppEnvironment, scope: InboxScope,
         clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current, locale: Locale = .current)

    /// Title-menu / Labels-sheet selection. Same scope → no-op. Else: `scope = new`, `limit = pageSize`, `filterChangeId += 1`,
    /// recompute `hasOlder`, restart the threads observation in place (architecture §8.1 "filter changes replace the observation in place").
    func setScope(_ scope: InboxScope)
    /// Flips `unreadOnly`, `limit = pageSize`, `filterChangeId += 1`, restarts the threads observation.
    func toggleUnreadOnly()
    /// Called from every row's `.onAppear`. Only the LAST row matters (§4.5): `rows.count >= limit` → `limit += pageSize` + restart;
    /// else `hasOlder && !isLoadingOlder` → `sync.run(olderReason)` in a `Task` with `isLoadingOlder` bracketing it.
    func rowAppeared(_ threadId: String)
    /// Pull-to-refresh: restarts failed observations (if `observationError != nil`), then `await env.sync.run(.pullToRefresh)`.
    func refresh() async
    /// `NSCalendarDayChanged` / `NSSystemTimeZoneDidChange` / scene active: recompute `DayBoundary.today(now:timeZone:)`; when it differs
    /// from `day` (or the time zone identifier changed) → store, restart BOTH observations (dateLabels and the Today window depend on them).
    func dayChanged(now: Date = Date(), timeZone: TimeZone = .current)
    /// Leading swipe: `lastActionId += 1`; `Task { await env.actions.archive(threadId:) }` (optimistic; the row leaves the inbox on the next tick).
    func archive(threadId: String)
    /// Trailing swipe: `lastActionId += 1`; `isUnread ? markRead : markUnread` via `env.actions` in a `Task`.
    func toggleRead(threadId: String, isUnread: Bool)
    /// Outbox row swipe "Retry": `Task { await env.outbox.retrySend(id:) }`.
    func retrySend(_ outboxId: Int64)
    /// Outbox row swipe "Delete": `lastActionId += 1`; `Task { await env.outbox.discardSend(id:) }`.
    func discardSend(_ outboxId: Int64)
    /// Outbox row tap: `record.kind == .send && record.sendJob != nil` → `activeSheet = .compose(.failedSend(outboxId: record.id, job:))`; else no-op + `Log.ui.error`.
    func openFailedSend(_ record: OutboxRecord)
    /// Reauth banner "×": `reauthBannerDismissed = true`.
    func dismissReauthBanner()
    /// From `.onChange(of: env.auth.state)`: `.signedIn` → `reauthBannerDismissed = false` (the banner returns on the next `.needsReauth`).
    func authStateChanged(_ state: AuthStore.State)
    /// Cancels both observations (tests; `deinit` also cancels through the cancellables' own deinit).
    func stop()
}
```

Private members of `InboxModel` (named so tests and later modules can reason about them):

```swift
/// One fetch of everything the list needs besides rows (§4.3). `Equatable` so `removeDuplicates()` suppresses no-op ticks.
nonisolated private struct InboxAux: Equatable, Sendable {
    var labels: [String: LabelRecord]
    var inboxUnread: Int
    var today: Int
    var failedSends: [OutboxRecord]
    var inboxNextPageToken: String?
}
private var threadsCancellable: AnyDatabaseCancellable?        // name UNVERIFIED [ios-platform §2.6]; use whatever `ValueObservation.start` returns
private var auxCancellable: AnyDatabaseCancellable?
private var chipFingerprint: [String: ThreadChip] = [:]        // labels projected to chip fields; threads restart only when this changes
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

/// Root screen of the signed-in app (architecture §8.1). `NavigationStack` + `InboxModel` lifecycle + day-change wiring.
struct InboxScreen: View {                                                                                    // verbatim: InboxScreen(scope:)
    /// Scope of the FIRST model creation; later scope changes go through the title menu / Labels sheet.
    init(scope: InboxScope)
    var body: some View
    /// `AsyncStream<Void>` that yields once per `NSCalendarDayChanged` or `NSSystemTimeZoneDidChange` notification (§4.9);
    /// observers are removed on stream termination. `nonisolated` static so `.task` can start it from any context.
    nonisolated static func dayChangeStream() -> AsyncStream<Void>
}

/// The list itself — everything that needs `@Bindable var model` (private; documented for tests reading the hierarchy).
private struct InboxListView: View { @Bindable var model: InboxModel; var body: some View }

/// `ContentUnavailableView` / `ProgressView` row for `InboxEmptyState` (private).
private struct InboxEmptyView: View { let state: InboxEmptyState; var body: some View }
```

### 3.3 `minimail/Features/Inbox/ThreadRowView.swift`

```swift
import MailCore
import SwiftUI
import UIKit

/// One list row (architecture §8.3). `body` maps precomputed strings to `Text`; no formatting, no `Task`, no environment reads other than theme.
struct ThreadRowView: View {
    let row: ThreadRow
    init(row: ThreadRow)
    var body: some View
    /// VoiceOver label (§6.3): "Unread, " (if unread) + participants + ", " + subject-or-"No subject" + ", " + dateLabel
    /// + ", N messages" (messageCount > 1) + ", Has attachment" (hasAttachments) + ", Label <name>" per chip. Pure; tested.
    nonisolated static func accessibilityLabel(for row: ThreadRow) -> String
}

/// Gmail-coloured capsule for a user label (chip). Created here because 09 precedes 12; modules.md assigns the type to 12 (§10 D4).
struct LabelChip: View {
    let chip: ThreadChip
    init(chip: ThreadChip)
    var body: some View
    /// `"#rrggbb"` (case-insensitive, exactly 7 chars) → `Color(uiColor: UIColor(red:green:blue:alpha: 1))`; anything else → nil
    /// (the caller falls back to `themeTokens.chipBackground` / `themeTokens.text`). Built through `UIColor` so `make lint`'s
    /// raw-colour grep (`Color\((red|…)`) does not match.
    nonisolated static func color(hex: String?) -> Color?
}
```

### 3.4 `minimail/Features/Inbox/StatusBanner.swift`

```swift
import MailCore
import SwiftUI

/// Non-blocking status row (architecture §8.2: "StatusBanner rows (offline / Couldn't refresh · Retry / Sign in again) — never a blocking alert").
struct StatusBanner: View {
    let kind: InboxBanner
    /// `.reauth`: `env.auth.isSigningIn` → disables the button; ignored for other kinds.
    let isBusy: Bool
    /// `.reauth` → sign in; `.error` → retry; `.offline` → never called (no button).
    let action: () -> Void
    /// `.reauth` only: the "×" button; nil hides it.
    let dismiss: (() -> Void)?
    init(kind: InboxBanner, isBusy: Bool = false, action: @escaping () -> Void, dismiss: (() -> Void)? = nil)
    var body: some View
    /// Strings/symbols of §5.2 (pure, tested).
    nonisolated static func title(for kind: InboxBanner) -> String
    nonisolated static func detail(for kind: InboxBanner) -> String?
    nonisolated static func symbol(for kind: InboxBanner) -> String
    nonisolated static func actionTitle(for kind: InboxBanner) -> String?
}

/// Row of the "Outbox" section (architecture §4.8 failure UX: subject, "Not sent — <short error>", swipe Retry / Delete, tap → compose).
struct FailedSendRow: View {
    let record: OutboxRecord
    init(record: OutboxRecord)
    var body: some View
    /// `record.sendJob?.subject` trimmed; empty/nil → "(No subject)".
    nonisolated static func subject(for record: OutboxRecord) -> String
    /// `"To: " + (job.to + job.cc).map(\.displayName).joined(", ")`; no recipients → "To: —".
    nonisolated static func recipients(for record: OutboxRecord) -> String
    /// `"Not sent — " + (record.lastError ?? "Unknown error")` (the row applies `lineLimit(1)`).
    nonisolated static func errorLine(for record: OutboxRecord) -> String
}
```

### 3.5 `minimail/Features/Inbox/InboxPlaceholders.swift` (temporary)

```swift
import SwiftUI

// Every struct below carries the FINAL signature of the screen it stands in for. Module 10 deletes `ThreadScreen`, 11 `ComposeScreen`,
// 12 `LabelsScreen`, 13 `SettingsScreen` and the file. Bodies are minimal (§6.7) and use theme tokens only.

/// Replaced by module 10 (`Features/Thread/ThreadScreen.swift`).
struct ThreadScreen: View { init(threadId: String); var body: some View }
/// Replaced by module 11 (`Features/Compose/ComposeScreen.swift`).
struct ComposeScreen: View { init(input: ComposeInput); var body: some View }
/// Replaced by module 12 (`Features/Labels/LabelsScreen.swift`). Contract: 12 calls `onSelect(scope)` exactly once per selection and
/// does NOT dismiss itself — the inbox sets `activeSheet = nil` (§4.8).
struct LabelsScreen: View { init(onSelect: @escaping (InboxScope) -> Void); var body: some View }
/// Replaced by module 13 (`Features/Settings/SettingsScreen.swift`).
struct SettingsScreen: View { init(); var body: some View }
```

### 3.6 `minimail/App/RootView.swift` (modify)

```swift
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens
    var body: some View
    // Group { switch env.auth.state { case .signedOut: SignInScreen(); case .signedIn, .needsReauth: InboxScreen(scope: .inbox) } }
    //   .preferredColorScheme(env.theme.preferredColorScheme).tint(themeTokens.accent).task { await env.startDeferredWork() }
}
// `SignedInPlaceholderView` (04 §3.8) and `RootPlaceholderView` (01 §3.11) are DELETED from this file.
```

The `NavigationStack` lives inside `InboxScreen` (it owns the path binding) — 04's comment wrote `NavigationStack { InboxScreen(scope: .inbox) }`; see §10 D2.

---

## 4. Behaviour

### 4.1 Model creation and first frame (architecture §12.2 step 2)

```
InboxScreen.body (first evaluation, model == nil):
    NavigationStack(path: $path) { themeTokens.background.ignoresSafeArea() }      // same colour as LaunchBackground → invisible if it lasts a frame
    .onAppear { if model == nil { model = InboxModel(env: env, scope: initialScope) } }
InboxModel.init:
    self.env = env; self.scope = scope; self.clock = clock; self.timeZone = timeZone; self.locale = locale
    day = DayBoundary.today(now: clock(), timeZone: timeZone)
    startAux()          // synchronous first value: labels, counts, failedSends, page token → hasOlder
    startThreads()      // synchronous first value: ≤ limit ThreadRows from the covering index
InboxListView.onAppear → env.markFirstListPaint()      // ends the coldStartToList signpost (01 §3.10)
```
Order matters: `startAux()` before `startThreads()` so the first row fetch already has `labels` for chips (otherwise the first tick would show rows without chips and the label fingerprint change would restart the observation one tick later).

Performance: `init` performs two reads on the main thread through GRDB's `.immediate` scheduling — the row query is served by one partial index (≤ 60 rows, < 5 ms on a 5,000-message DB, 06 §7.2 `testInboxQueryUnder5msWith5000Messages`); the aux fetch is `labelsById` (≤ ~100 rows), two `COUNT(*)` on partial indexes, `failedSends` (indexed `outbox_due` scan of `failed` rows) and one `syncState` PK lookup — < 1 ms together. Later changes are fetched on GRDB's reader queue and delivered on the main queue (`[ios-platform §2.6]`: "fresh values are then never fetched from the main thread").

### 4.2 Threads observation

```
startThreads():
    threadsCancellable?.cancel()
    let fetch = Queries.threads(query, now: clock(), timeZone: timeZone, locale: locale, labels: labels)   // @Sendable (Database) throws -> [ThreadRow]
    threadsCancellable = ValueObservation
        .trackingConstantRegion(fetch)
        .removeDuplicates()                                              // [ThreadRow] is Equatable; aggregate rewrites with equal rows do not re-render
        .start(in: env.db, scheduling: .immediate,
               onError:  { [weak self] error in MainActor.assumeIsolated { self?.observationFailed(error) } },
               onChange: { [weak self] rows  in MainActor.assumeIsolated { self?.rows = rows } })
```
- The closure's region is constant for a given `query` (SQL text and tables depend only on the captured `q`, 06 §4.12), so `trackingConstantRegion` is valid.
- `.immediate` delivers the first value synchronously on the caller (main) and later values "on the main dispatch queue" (`[ios-platform §2.6]`), which is why `MainActor.assumeIsolated` is correct inside the `@Sendable` callbacks (§10 A5 gives the fallback).
- Restarted (cancel + start) by: `setScope`, `toggleUnreadOnly`, `rowAppeared` (limit bump), `dayChanged` (boundary or zone changed), `apply(aux)` when the chip fingerprint changed, `refresh()` after an observation error. A restart re-fetches synchronously (`.immediate`) so the list never shows a stale scope for a frame.
- `observationFailed(error)`: `Log.ui.error("inbox observation failed: \(String(describing: error), privacy: .public)")`, `observationError = String(describing: error)`; the banner shows `.error("Database unavailable")`; `refresh()` restarts.

### 4.3 Auxiliary observation

```
startAux():
    auxCancellable?.cancel()
    let day = self.day
    auxCancellable = ValueObservation
        .trackingConstantRegion { db in
            InboxAux(labels: try Queries.labelsById(db),
                     inboxUnread: try Queries.inboxUnreadThreadCount(db),
                     today: try Queries.todayThreadCount(db, day),
                     failedSends: try Queries.failedSends(db),
                     inboxNextPageToken: try SyncStateRepository.get(db, .inboxNextPageToken)) }
        .removeDuplicates()
        .start(in: env.db, scheduling: .immediate,
               onError:  { [weak self] e in MainActor.assumeIsolated { self?.observationFailed(e) } },
               onChange: { [weak self] aux in MainActor.assumeIsolated { self?.apply(aux) } })

apply(aux):
    labels = aux.labels; inboxUnreadCount = aux.inboxUnread; todayCount = aux.today; failedSends = aux.failedSends
    recomputeHasOlder(inboxToken: aux.inboxNextPageToken)
    let fp = aux.labels.mapValues { ThreadChip(id: $0.id, name: $0.name, textColor: $0.textColor, backgroundColor: $0.backgroundColor) }
    if fp != chipFingerprint { chipFingerprint = fp; if threadsCancellable != nil { startThreads() } }   // not during init (threads not started yet)

recomputeHasOlder(inboxToken):
    lastInboxToken = inboxToken                                            // private stored copy for setScope
    switch scope {
    case .inbox, .today: hasOlder = inboxToken != nil
    case .label(let id): hasOlder = labels[id]?.viewNextPageToken != nil }
```
`day` is captured by value; `dayChanged` restarts this observation so `todayCount` follows the new window. Label count refreshes (every 5 min, 07) change `countsFetchedAt`/`threadsUnread` and tick this observation, but the chip fingerprint (id, name, colours) is unchanged → the threads observation is NOT restarted.

### 4.4 Filters and title

| Operation | Steps |
|---|---|
| `setScope(s)` | `guard s != scope else return`; `scope = s`; `limit = pageSize`; `autoOlderLoads = 0`; `filterChangeId += 1`; `recomputeHasOlder(inboxToken: lastInboxToken)`; `startThreads()` |
| `toggleUnreadOnly()` | `unreadOnly.toggle()`; `limit = pageSize`; `autoOlderLoads = 0`; `filterChangeId += 1`; `startThreads()` |
| `query` | `ThreadQuery(scope: .inbox / .today(day) / .label(id: id), unreadOnly: unreadOnly, limit: limit)` |
| `title` | `.inbox` → `"Inbox"`; `.today` → `"Today"`; `.label(id)` → `labels[id]?.name ?? id` (full Gmail name, e.g. "Customers/ACME") |

`unreadOnly` survives scope changes (PLAN.md "Filter chip: unread toggle on any view"). The title menu never emits `.label(_)`; only the Labels sheet does (`onSelect`).

### 4.5 Paging and "load older" (architecture §8.2: "last row appears → `limit += 60`, then `sync.run(.loadOlderInbox/.loadOlderLabel)` when a page token exists")

```
rowAppeared(id):
    guard id == rows.last?.id else return                      // only the last row triggers
    if rows.count >= limit:
        limit += pageSize; autoOlderLoads = 0; startThreads(); return      // cache probably has more rows
    guard hasOlder, !isLoadingOlder else return                // cache exhausted for this scope; server may have more
    loadOlder()

loadOlder():
    isLoadingOlder = true
    let before = rows.count
    Task { [weak self] in
        guard let self else { return }
        await env.sync.run(olderReason)                        // 07: guard token; messages.list?pageToken → metadata batch → token replaced/cleared
        await Task.yield()                                     // let the observation tick land
        isLoadingOlder = false
        if rows.count > before { autoOlderLoads = 0; return }
        if hasOlder, autoOlderLoads < Self.maxAutoOlderLoads, rows.last?.id == lastAppearedId { autoOlderLoads += 1; loadOlder() }
    }
```
- `lastAppearedId` (private) is the id passed to the most recent `rowAppeared`. The bounded retry covers pages whose messages all belong to already cached threads (no new rows) and single-flight coalescing in `SyncEngine.run` (a second caller returns at once; the queued reason runs at the end of the active run — `autoOlderLoads` stops the model after 3 immediate returns; the next scroll to the end tries again).
- `hasOlder` turns false when 07 clears the token (`inboxNextPageToken` deleted / `label.viewNextPageToken` nil) — observed, no polling.
- `.today` uses the inbox token: the newest 100 inbox messages may all be from today; loading an older inbox page can add today rows. Bounded by the same retry rule.
- While `isLoadingOlder` the list shows a footer `ProgressView` row (§6.4).
- No load-older while the aux/threads observation has failed (`observationError != nil`): `rowAppeared` returns early.

### 4.6 Banners (architecture §4.8 failure UX, §5.2 D22)

```
banner:
    if case .needsReauth = env.auth.state, !reauthBannerDismissed → .reauth
    else if env.syncStatus.isOffline → .offline
    else if let e = env.syncStatus.lastError → .error(e)
    else if observationError != nil → .error("Database unavailable")
    else → nil
```
- `.reauth`: button "Sign in" → `Task { try? await env.auth.signIn() }` (errors surface through `env.auth.lastError`, shown as the banner detail line while `.needsReauth` persists); "×" → `dismissReauthBanner()`; `authStateChanged(.signedIn)` resets the dismissal. The cached list stays fully usable (architecture D22).
- `.offline`: no button. Optimistic changes stay visible; the outbox retries on the next trigger (07). The architecture's §4.8 phrase "nav-bar subtitle" is implemented as this list row (§10 D3).
- `.error(text)`: title "Couldn't refresh", detail `text` (a `GmailError.userMessage` from 05, "Rate limited — try again later", "Database unavailable"), button "Retry" → `Task { await model.refresh() }`.
- Never an alert. The banner section has no header, `listRowBackground(themeTokens.surface)`.

### 4.7 Empty states

`emptyState` (§3.1) is rendered as one list row (`InboxEmptyView`) so pull-to-refresh keeps working:

| State | View |
|---|---|
| `.initialSync` | `ProgressView("Loading your inbox…")` centred, `.progressViewStyle(.circular)` |
| `.noMail` | `ContentUnavailableView("No Mail", systemImage: "tray", description: Text("New mail you receive will appear here."))` |
| `.nothingToday` | `ContentUnavailableView("Nothing today", systemImage: "sun.max", description: Text("No mail received today."))` |
| `.allCaughtUp` | `ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("No unread mail here."))` |
| `.noMessages` | `ContentUnavailableView("No messages", systemImage: "tag", description: Text("No cached mail with this label."))` |

Precedence: `.initialSync` beats every other state (the first sync fills the list progressively, 07 §4.4: one commit per 25-message batch — rows appear while the footer is still visible only if `rows` is non-empty, in which case `emptyState == nil`).

### 4.8 Sheets and navigation

- `path: [ThreadRoute]` is `@State` in `InboxScreen`; rows push `ThreadRoute(threadId:)` through a hidden `NavigationLink(value:)` (§6.3). `.navigationDestination(for: ThreadRoute.self) { ThreadScreen(threadId: $0.threadId) }` is applied to the stack's root content.
- `.sheet(item: $model.activeSheet)`: `.labels` → `LabelsScreen(onSelect: { scope in model.setScope(scope); model.activeSheet = nil })`; `.settings` → `SettingsScreen()`; `.compose(input)` → `ComposeScreen(input: input)`. Sheets inherit the environment (`AppEnvironment`, `ThemeStore`, `SettingsStore`) automatically.
- Scope switching never pushes or pops; the sheet dismissal is the only navigation side effect of `onSelect`.
- Module 12's `LabelsScreen` triggers `sync.run(.labelOpened(id))` itself (modules.md 12); this module does not.

### 4.9 Day and time-zone changes (architecture §14 #19)

```
InboxScreen:
    .task { for await _ in InboxScreen.dayChangeStream() { model?.dayChanged() } }
    .onChange(of: scenePhase) { _, phase in if phase == .active { model?.dayChanged() } }
dayChangeStream():
    AsyncStream<Void> { continuation in
        let names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemTimeZoneDidChange]
        let tokens = names.map { NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in continuation.yield(()) } }
        continuation.onTermination = { _ in tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
dayChanged(now, timeZone):
    let d = DayBoundary.today(now: now, timeZone: timeZone)
    guard d != day || timeZone.identifier != self.timeZone.identifier else { return }
    day = d; self.timeZone = timeZone
    startAux(); startThreads()
```
`addObserver` is chosen over `NotificationCenter.notifications(named:)` because `Notification` is not `Sendable` and the `for await` form does not compile in a main-actor context under Swift 6 strict checking without workarounds (§10 A6). The observers are registered after the first frame (`.task`), honouring the launch rule "no NotificationCenter observers beyond scene phase" in `AppEnvironment.init`.

### 4.10 Actions

| Operation | Effect (all fire-and-forget; the observation tick renders the result on the next frame, architecture §12.1 "swipe archive → row gone: next frame") |
|---|---|
| `archive(threadId:)` | `lastActionId += 1`; `Task { await env.actions.archive(threadId:) }` → 07: `enqueueModify(remove INBOX, affected = messageIds)` + `kick()`; `thread.inInbox = 0` in the same transaction → the row disappears in Inbox/Today; in a label scope it stays (label unchanged) |
| `toggleRead(threadId:isUnread:)` | `lastActionId += 1`; `Task { isUnread ? await env.actions.markRead(threadId:) : await env.actions.markUnread(threadId:) }`; with `unreadOnly` a just-read row disappears |
| `retrySend(id)` | `Task { await env.outbox.retrySend(id:) }` → row leaves the Outbox section (state pending) |
| `discardSend(id)` | `lastActionId += 1`; `Task { await env.outbox.discardSend(id:) }` |
| `openFailedSend(record)` | see §3.1; 11's `ComposeScreen` deletes the old job on Send |
| `refresh()` | `if observationError != nil { observationError = nil; startAux(); startThreads() }`; `await env.sync.run(.pullToRefresh)` (07 re-arms failed modify ops, forces label counts; single-flight: returns immediately if a run is active — the refresh control then stops early; acceptable, §10 A8) |

Two rapid toggles (read → unread) coalesce to zero outbox rows and zero requests (07 §4.6) — the row flips twice in the UI.

### 4.11 Concurrency and isolation

- `InboxModel`, all views, `ActiveSheet`, `InboxBanner`, `InboxEmptyState`: main actor (implicit). `InboxScope`, `ThreadRoute`, `ComposeInput`, `InboxAux`: `nonisolated` + `Sendable` (crossed into `@Sendable` GRDB closures and actor calls).
- GRDB callbacks: `@Sendable`, run on the main queue (`.immediate` scheduler) → `MainActor.assumeIsolated`.
- Every `env.actions` / `env.outbox` / `env.sync` call is `await`ed inside a detached-free `Task { }` on the main actor (structured child of nothing; the model does not track them — they are idempotent enqueue/drain calls).
- `env.actions` is read at call time (07 D6: rebuilt after an account wipe).
- No `DatabasePool.read/write` calls from the model or views except through `ValueObservation` (architecture §12.3 "UI only observes").

### 4.12 Error handling summary

| Source | Error | Handling |
|---|---|---|
| ValueObservation (threads or aux) | any `Error` | `Log.ui.error`; `observationError` set; banner `.error("Database unavailable")`; `refresh()` restarts; paging disabled meanwhile |
| `env.sync.run` | never throws | `SyncStatus.lastError/isOffline` → banner |
| `env.actions.*` | never throws (07 logs) | nothing to show; optimistic state stays |
| `env.outbox.retrySend/discardSend` | never throws | — |
| `env.auth.signIn()` | throws `AuthError` | `try?`; `env.auth.lastError` rendered as the reauth banner's detail line |
| `openFailedSend` on a non-send record | programmer error | `Log.ui.error("openFailedSend: record \(id) is not a failed send")`, no sheet |

---

## 5. Data

### 5.1 Identifiers and formats

| Value | Format / example |
|---|---|
| `ComposeInput.id` | `"message:replyAll:18c2f1a9b3d4e5f6"`, `"message:forward:18c2…"`, `"failedSend:42"` |
| `ActiveSheet.id` | `"labels"`, `"settings"`, `"compose:failedSend:42"`, `"compose:message:forward:18c2…"` |
| `InboxModel.pageSize` | `60` (`ThreadQuery.pageSize`, 06 §3.9) |
| `InboxModel.maxAutoOlderLoads` | `3` |
| `ThreadQuery` produced | `ThreadQuery(scope: .inbox, unreadOnly: false, limit: 60)` → after one page: `limit: 120`; today: `.today(DayBoundary(startMs: 1757541600000, endMs: 1757628000000))` (Europe/Berlin, 2026-09-11, 06 §5.6) |
| Page-token sources | inbox/today: `syncState.inboxNextPageToken` (06 §5.3, nil when exhausted); label: `label.viewNextPageToken` |
| `OutboxRecord` fields read | `id`, `kind`, `state` (always `.failed` from `Queries.failedSends`), `lastError`, `sendJob` (`subject`, `to`, `cc`) |

### 5.2 Strings (English literals; `SWIFT_EMIT_LOC_STRINGS = YES` collects them)

| Key (where) | Text |
|---|---|
| nav title | `Inbox` · `Today` · `<label name>` |
| title menu | `Inbox` · `Today` · `Labels…` |
| toolbar accessibility | `Unread only` (value `On`/`Off`, `\(inboxUnreadCount) unread` appended in Inbox scope) · `Settings` |
| swipe | `Archive` · `Read` · `Unread` · `Retry` · `Delete` |
| banner.reauth | title `Sign in again to keep syncing`, detail `env.auth.lastError` (nil → none), action `Sign in`, dismiss accessibility `Dismiss` |
| banner.offline | title `Offline — changes will sync` (U+2014 em dash), no detail, no action |
| banner.error | title `Couldn't refresh`, detail `<text>`, action `Retry` |
| outbox section header | `Outbox` |
| outbox row | `<subject>` / `(No subject)`; `To: <names>` / `To: —`; `Not sent — <lastError>` / `Not sent — Unknown error` |
| loading footer | `Loading your inbox…` (U+2026); older-page footer has no text |
| empty states | `No Mail` / `New mail you receive will appear here.` · `Nothing today` / `No mail received today.` · `All caught up` / `No unread mail here.` · `No messages` / `No cached mail with this label.` |
| row | `(No subject)`; accessibility fragments `Unread`, `No subject`, `\(n) messages`, `Has attachment`, `Label \(name)` |
| placeholders | `Thread <id> (module 10)` · `Compose (module 11)` · `Cancel` · `Mailboxes` · `Settings (module 13)` · `Sign out` |

### 5.3 SF Symbols

| Use | Symbol |
|---|---|
| title menu Inbox / Today / Labels… | `tray` / `sun.max` / `tag` |
| unread toggle off / on | `line.3.horizontal.decrease.circle` / `line.3.horizontal.decrease.circle.fill` |
| settings | `gearshape` |
| row attachment | `paperclip` |
| swipe Archive | `archivebox` |
| swipe Read (row unread) / Unread (row read) | `envelope.open` / `envelope.badge` |
| outbox row leading icon | `paperplane` |
| outbox swipe Retry / Delete | `arrow.clockwise` / `trash` |
| banner reauth / offline / error | `person.crop.circle.badge.exclamationmark` / `wifi.slash` / `exclamationmark.triangle` |
| banner dismiss | `xmark` |
| empty states | `tray` / `sun.max` / `checkmark.circle` / `tag` |

### 5.4 Accessibility identifiers (for 14's device checklist and hosting tests)

`inbox.list`, `inbox.unreadToggle`, `inbox.settings`, `inbox.banner`, `inbox.banner.action`, `inbox.banner.dismiss`, `inbox.row.<threadId>`, `inbox.outbox.row.<outboxId>`, `inbox.empty`, `inbox.loadingOlder`, `placeholder.signout` (kept from 04 on the Settings placeholder's Sign out button).

### 5.5 Theme tokens used (01 §3.6; no raw colours — `make lint`)

`background` (list/background), `surface` (banner row background), `text` (primary text), `secondaryText` (date, snippet, counts, icons), `unread` (dot), `chipBackground`/`text` (chip fallback), `swipeArchive` (Archive tint), `swipeRead` (Read/Unread tint), `accent` (Retry tint, banner buttons via `.tint` inherited from `RootView`). Gmail chip colours are built from the label's hex via `UIColor` (§3.3).

---

## 6. UI

### 6.1 View hierarchy

```
InboxScreen                                  @State model: InboxModel?, @State path: [ThreadRoute]
└─ NavigationStack(path: $path)
   └─ Group { if let model { InboxListView(model) } else { themeTokens.background.ignoresSafeArea() } }
        .navigationDestination(for: ThreadRoute.self) { ThreadScreen(threadId: $0.threadId) }
   .onAppear { create model }  .onChange(of: scenePhase)  .onChange(of: env.auth.state) { model?.authStateChanged($1) }  .task { day changes }

InboxListView (@Bindable model)
└─ List {                                                                    .listStyle(.plain) .accessibilityIdentifier("inbox.list")
     if let banner = model.banner        → Section { StatusBanner(...) }                              (§6.5)
     if !model.failedSends.isEmpty       → Section("Outbox") { ForEach(model.failedSends) { FailedSendRow } }   (§6.6)
     if let empty = model.emptyState     → Section { InboxEmptyView(state: empty) }                   (§6.4)
     else                                → Section { ForEach(model.rows) { row in threadRow(row) }
                                                     if model.isLoadingOlder { ProgressView() … } }
   }
   .refreshable { await model.refresh() }
   .navigationTitle(model.title)  .navigationBarTitleDisplayMode(.large)
   .toolbarTitleMenu { Inbox · Today · Labels… }                                                     (§6.2)
   .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { unreadToggle; settingsButton } }
   .sheet(item: $model.activeSheet) { … }                                                             (§4.8)
   .sensoryFeedback(.impact(weight: .light), trigger: model.lastActionId)
   .sensoryFeedback(.selection, trigger: model.filterChangeId)
   .background(themeTokens.background)
   .onAppear { env.markFirstListPaint() }
```

### 6.2 Toolbar

- Title: `model.title`, large display mode (iOS Mail mailbox style). `.toolbarTitleMenu { Button { model.setScope(.inbox) } label: { Label("Inbox", systemImage: "tray") }; Button { model.setScope(.today) } label: { Label("Today", systemImage: "sun.max") }; Divider(); Button { model.activeSheet = .labels } label: { Label("Labels…", systemImage: "tag") } }`.
- Trailing group: `Button { model.toggleUnreadOnly() } label: { Image(systemName: model.unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }.accessibilityLabel("Unread only").accessibilityValue(model.unreadOnly ? "On" : "Off").accessibilityIdentifier("inbox.unreadToggle")`; `Button { model.activeSheet = .settings } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings").accessibilityIdentifier("inbox.settings")`.
- In `.inbox` scope the unread toggle's accessibility value is `"\(model.unreadOnly ? "On" : "Off"), \(model.inboxUnreadCount) unread"`.

### 6.3 Thread row (`threadRow(row)` in `InboxListView`, content = `ThreadRowView`)

```
ZStack {                                                                            // hides the disclosure chevron (iOS Mail has none)
  NavigationLink(value: ThreadRoute(threadId: row.id)) { EmptyView() }.opacity(0).accessibilityHidden(true)
  ThreadRowView(row: row)
}
.listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16))            // architecture §8.3
.swipeActions(edge: .leading, allowsFullSwipe: true) {
  Button { model.archive(threadId: row.id) } label: { Label("Archive", systemImage: "archivebox") }.tint(themeTokens.swipeArchive) }
.swipeActions(edge: .trailing, allowsFullSwipe: true) {
  Button { model.toggleRead(threadId: row.id, isUnread: row.isUnread) }
    label: { Label(row.isUnread ? "Read" : "Unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge") }.tint(themeTokens.swipeRead) }
.onAppear { model.rowAppeared(row.id) }
.accessibilityIdentifier("inbox.row.\(row.id)")

ThreadRowView.body (architecture §8.3 verbatim layout):
HStack(alignment: .top, spacing: 10)
  Circle().fill(row.isUnread ? themeTokens.unread : Color.clear).frame(width: 10, height: 10).padding(.top, 5)   // space always reserved
  VStack(alignment: .leading, spacing: 2)
    HStack(spacing: 4)
      Text(row.participants).font(.headline).fontWeight(row.isUnread ? .semibold : .regular).lineLimit(1).foregroundStyle(themeTokens.text)
      if row.messageCount > 1 { Text("\(row.messageCount)").font(.caption).foregroundStyle(themeTokens.secondaryText) }
      Spacer(minLength: 4)
      if row.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(themeTokens.secondaryText) }
      Text(row.dateLabel).font(.subheadline).foregroundStyle(themeTokens.secondaryText).lineLimit(1)
    Text(row.subject.isEmpty ? "(No subject)" : row.subject).font(.subheadline).lineLimit(1).foregroundStyle(themeTokens.text)
    HStack(alignment: .top, spacing: 8)
      Text(row.snippet).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(2)
      Spacer(minLength: 8)
      if !row.chips.isEmpty { HStack(spacing: 4) { ForEach(row.chips) { LabelChip(chip: $0) } } }
.contentShape(Rectangle())
.accessibilityElement(children: .ignore)
.accessibilityLabel(ThreadRowView.accessibilityLabel(for: row))
.accessibilityAddTraits(.isButton)

LabelChip.body:
Text(chip.name).font(.caption2).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
  .foregroundStyle(LabelChip.color(hex: chip.textColor) ?? themeTokens.text)
  .background(Capsule().fill(LabelChip.color(hex: chip.backgroundColor) ?? themeTokens.chipBackground))
  .accessibilityHidden(true)                                                       // the row label already lists the chips
```
Dynamic Type: system text styles only; the row grows; `lineLimit`s cap it. Chips keep Gmail's colours in dark mode (Gmail's own apps do the same; §10 A9).

### 6.4 Empty and loading rows

- `InboxEmptyView`: the `ContentUnavailableView`/`ProgressView` of §4.7 with `.frame(maxWidth: .infinity, minHeight: 320)`, `.listRowSeparator(.hidden)`, `.listRowBackground(Color.clear)`, `.accessibilityIdentifier("inbox.empty")`.
- Older-page footer: `ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).listRowSeparator(.hidden).accessibilityIdentifier("inbox.loadingOlder").accessibilityLabel("Loading older mail")`.
- Pull-to-refresh: the system refresh control on the `List`; no custom indicator for `phase == .syncing` (foreground syncs are silent; architecture §4.3).

### 6.5 Status banner row

```
StatusBanner.body:
HStack(alignment: .center, spacing: 10)
  Image(systemName: symbol(for: kind)).foregroundStyle(themeTokens.secondaryText).accessibilityHidden(true)
  VStack(alignment: .leading, spacing: 2)
    Text(title(for: kind)).font(.subheadline).foregroundStyle(themeTokens.text)
    if let d = detail(for: kind) { Text(d).font(.caption).foregroundStyle(themeTokens.secondaryText).lineLimit(2) }
  Spacer(minLength: 8)
  if let t = actionTitle(for: kind) { Button(t, action: action).buttonStyle(.bordered).controlSize(.small).disabled(isBusy).accessibilityIdentifier("inbox.banner.action") }
  if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(themeTokens.secondaryText).accessibilityLabel("Dismiss").accessibilityIdentifier("inbox.banner.dismiss") }
.listRowBackground(themeTokens.surface)
.accessibilityElement(children: .contain)
.accessibilityIdentifier("inbox.banner")
```
Wiring in `InboxListView`: `.reauth` → `StatusBanner(kind:, isBusy: env.auth.isSigningIn, action: { Task { try? await env.auth.signIn() } }, dismiss: { model.dismissReauthBanner() })`; `.offline` → `StatusBanner(kind: .offline, action: {})`; `.error` → `StatusBanner(kind:, action: { Task { await model.refresh() } })`. The reauth detail line is `env.auth.lastError` (passed by building `.reauth` rows with `detail(for:)` = nil and the view appending `env.auth.lastError` — implement as: `StatusBanner.detail(for: .reauth)` returns nil; `InboxListView` wraps the banner in a `VStack` adding `Text(env.auth.lastError)` when non-nil).

### 6.6 Outbox section

```
Section("Outbox") {
  ForEach(model.failedSends) { rec in
    Button { model.openFailedSend(rec) } label: { FailedSendRow(record: rec) }.buttonStyle(.plain)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button(role: .destructive) { model.discardSend(rec.id) } label: { Label("Delete", systemImage: "trash") }
        Button { model.retrySend(rec.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(themeTokens.accent) }
      .accessibilityIdentifier("inbox.outbox.row.\(rec.id)")
  }
}
FailedSendRow.body:
HStack(alignment: .top, spacing: 10)
  Image(systemName: "paperplane").foregroundStyle(themeTokens.secondaryText).padding(.top, 2).accessibilityHidden(true)
  VStack(alignment: .leading, spacing: 2)
    Text(subject(for: record)).font(.subheadline).fontWeight(.semibold).lineLimit(1).foregroundStyle(themeTokens.text)
    Text(recipients(for: record)).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(1)
    Text(errorLine(for: record)).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(1)
.contentShape(Rectangle())
.accessibilityElement(children: .combine)
```
`Button(role: .destructive)` renders red by the system (`[ios-platform §5.2]`) — no raw colour. `allowsFullSwipe: false` so a full swipe never deletes a failed send by accident.

### 6.7 Placeholders (`InboxPlaceholders.swift`)

| Struct | Body |
|---|---|
| `ThreadScreen(threadId:)` | `Text("Thread \(threadId) (module 10)").font(.body).foregroundStyle(themeTokens.secondaryText).navigationTitle("Thread").navigationBarTitleDisplayMode(.inline)` |
| `ComposeScreen(input:)` | `NavigationStack { Text("Compose (module 11)").navigationTitle("Compose").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } }` |
| `LabelsScreen(onSelect:)` | `NavigationStack { List { Section("Mailboxes") { Button { onSelect(.inbox) } label: { Label("Inbox", systemImage: "tray") }; Button { onSelect(.today) } label: { Label("Today", systemImage: "sun.max") } } }.navigationTitle("Labels") }` |
| `SettingsScreen()` | `NavigationStack { List { Section("Account") { Text(env.auth.state.email ?? "—"); Button("Sign out", role: .destructive) { Task { await env.auth.signOut() } }.accessibilityIdentifier("placeholder.signout") } }.navigationTitle("Settings") }` |

All use `@ThemeTokensReader` for colours where a colour is set; none imports anything beyond SwiftUI (+ `MailCore` for `ComposeInput`'s `ComposeMode`).

### 6.8 States → rendering matrix

| Condition | List content (top → bottom) |
|---|---|
| signed in, cache empty, first sync running | `ProgressView("Loading your inbox…")` row |
| signed in, rows present, idle | rows |
| offline, rows present | offline banner, rows |
| `needsReauth` | reauth banner (until dismissed), Outbox section if any, rows |
| failed sends present | (banner), "Outbox" section, rows or empty state |
| `unreadOnly`, no unread | (banner), (Outbox), "All caught up" |
| label scope, nothing cached | "No messages" (12 hydrates the view; rows appear via observation) |
| loading older page | rows, footer spinner |
| observation failed | error banner "Couldn't refresh · Database unavailable", rows frozen until Retry |

### 6.9 Haptics and navigation summary

- `.impact(weight: .light)` on archive / read toggle / delete-send (trigger `lastActionId`); `.selection` on scope or unread-toggle change (`filterChangeId`). `.success` on send belongs to 11.
- Tap row → push `ThreadRoute`; swipe → action; title menu → scope or Labels sheet; gear → Settings sheet; Outbox row → Compose sheet; banner buttons → sign in / retry.

---

## 7. Tests

All tests in this module are app tests (`xcodebuild test`, `make test-app`; single file `make test-one T=minimailTests/InboxModelTests`). Classes are `final class … : XCTestCase`, main-actor by default. No package tests (no `MailCore` files).

Shared setup (private to each file; 14 owns `minimailTests/Support`): `env = AppEnvironment(testing: true)` (temporary `DatabasePool`, `OfflineURLProtocol` → every request answers `.offline`, auth `.signedOut`); `db = env.db`; seeding through 06's `TestDatabase.seed(db, [ParsedMessage])`, `TestDatabase.seedMany(db, count:)`, `TestDatabase.seedLabels(db, TestDatabase.sampleLabels)`, `TestDatabase.parsed(id:…)`. Helper `func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async` polls every 20 ms with `try? await Task.sleep(for: .milliseconds(20))` and `XCTFail`s on timeout. `now` for seeds = `1_757_500_000_000` (2026-09-10 12:26:40 UTC). `tearDown`: `model.stop()`; `try? env.db.close()`.

### 7.1 `minimailTests/Inbox/InboxModelTests.swift`

| Test | Setup | Assertions |
|---|---|---|
| `testImmediateRowsOnInit` | seed t1 (date 3), t2 (date 2), t3 (date 1) all `["INBOX"]`; `InboxModel(env:scope:.inbox)` | synchronously after init: `rows.map(\.id) == ["t1","t2","t3"]`; `title == "Inbox"`; `emptyState == nil`; `hasOlder == false`; `banner == nil`; `query == ThreadQuery(scope: .inbox, unreadOnly: false, limit: 60)` |
| `testEmptyStatesPerScope` | no seed; model `.inbox` | `emptyState == .noMail`; `setScope(.today)` → `.nothingToday`; `setScope(.label(id: "Label_12"))` → `.noMessages`; `toggleUnreadOnly()` → `.allCaughtUp`; `env.syncStatus.phase = .initialSync` → `.initialSync`; `phase = .idle` → `.allCaughtUp` |
| `testQueryMirrorsState` | model with `clock: { fixed }`, `timeZone: Europe/Berlin` | `setScope(.today)` → `query.scope == .today(DayBoundary.today(now: fixed, timeZone: berlin))`; `setScope(.label(id: "L"))` → `.label(id: "L")`; `toggleUnreadOnly()` → `query.unreadOnly == true` |
| `testSetScopeSameIsNoop` | model `.inbox` | `setScope(.inbox)` → `filterChangeId == 0`; `setScope(.today)` → `1`; `setScope(.today)` → `1` |
| `testUnreadToggleFilters` | `seedMany(count: 200)` (every 5th unread) | `toggleUnreadOnly()` → every row `isUnread`; `rows.map(\.id)` equals `Queries.threads(ThreadQuery(scope: .inbox, unreadOnly: true))` evaluated directly on `db`; `filterChangeId == 1` |
| `testPagingIncreasesLimit` | `seedMany(count: 200)` (≥ 90 inbox threads) | `rows.count == 60`; `rowAppeared(rows[10].id)` → `limit == 60`; `rowAppeared(rows.last!.id)` → `limit == 120` and synchronously `rows.count > 60` |
| `testToggleResetsLimit` | as above after one page (`limit == 120`) | `toggleUnreadOnly()` → `limit == 60`; `setScope(.today)` → `limit == 60` |
| `testHasOlderFromInboxToken` | seed t1; model | `hasOlder == false`; `try await db.write { try SyncStateRepository.set($0, .inboxNextPageToken, "p2") }` → `waitUntil { model.hasOlder }`; `olderReason == .loadOlderInbox`; `setScope(.today)` → `hasOlder == true`; set token nil → `waitUntil { !model.hasOlder }` |
| `testHasOlderFromLabelToken` | `seedLabels`; `try await db.write { try LabelRepository.markViewFetched($0, labelId: "Label_12", nextPageToken: "lp", now: now) }`; model; `setScope(.label(id: "Label_12"))` | `waitUntil { model.hasOlder }`; `olderReason == .loadOlderLabel("Label_12")`; `markViewFetched(…, nil, …)` → `waitUntil { !model.hasOlder }` |
| `testLoadOlderRunsAndStops` | seed t1 with `inboxNextPageToken = "p2"` (written before the model); model | `rowAppeared("t1")` → `isLoadingOlder == true`; `waitUntil { !model.isLoadingOlder }` (auth `.signedOut` → `run` skipped, returns immediately; at most 3 automatic retries); `limit == 60`; `rows.count == 1` |
| `testRowAppearedNotLastIsNoop` | seed t1, t2 with token `"p2"` | `rowAppeared("t1")` → `isLoadingOlder == false`, `limit == 60` |
| `testTitleForLabelScope` | `seedLabels`; model | `setScope(.label(id: "Label_12"))` → `title == "Customers/ACME"`; `setScope(.label(id: "Label_999"))` → `title == "Label_999"`; `setScope(.today)` → `"Today"` |
| `testChipsFromLabelTable` | `seedLabels`; seed t1 labels `["INBOX","Label_12","Label_13"]` | `rows[0].chips.map(\.id) == ["Label_12","Label_13"]`; `rows[0].chips[0].name == "Customers/ACME"`; chip colours equal the `LabelRecord` values from `Queries.labelsById(db)["Label_12"]` |
| `testLabelRenameRestartsThreads` | as above | `try await db.write { var l = try LabelRecord.fetchOne($0, key: "Label_12")!; l.name = "Renamed"; try l.update($0) }` → `waitUntil { model.rows[0].chips[0].name == "Renamed" }` |
| `testCountsObserved` | `seedMany(count: 200)`; model | `inboxUnreadCount == try db.read { try Queries.inboxUnreadThreadCount($0) }`; `todayCount == 0` (seeds dated 2025-09); seed one more message dated `Date()` in INBOX → `waitUntil { model.todayCount == 1 }` |
| `testArchiveRemovesRowAndEnqueues` | seed t1, t2 `["INBOX","UNREAD"]`; model | `archive(threadId: "t1")` → `lastActionId == 1`; `waitUntil { model.rows.map(\.id) == ["t2"] }`; after `try? await Task.sleep(for: .milliseconds(600))` (debounce + offline drain): `try db.read { try OutboxRepository.pendingModifies($0) }.count == 1` with `removeLabelIds == ["INBOX"]`; `try InvariantChecks.assertAll(db)` |
| `testArchiveInLabelScopeKeepsRow` | `seedLabels`; seed t1 `["INBOX","Label_12"]`; model; `setScope(.label(id: "Label_12"))` | `archive(threadId: "t1")` → after 300 ms `rows.map(\.id) == ["t1"]` (still labelled); `try db.read { try ThreadRecord.fetchOne($0, key: "t1")!.inInbox } == false` |
| `testToggleReadFlipsAndCoalesces` | seed t1 `["INBOX","UNREAD"]`; model | `toggleRead(threadId: "t1", isUnread: true)` → `waitUntil { model.rows[0].isUnread == false }`; immediately `toggleRead(threadId: "t1", isUnread: false)` → `waitUntil { model.rows[0].isUnread == true }`; `lastActionId == 2`; after 600 ms `pendingModifies($0).isEmpty` (inverse cancelled, 06 `testEnqueueInverseCancelsToZeroRows`); invariants hold |
| `testUnreadOnlyHidesRowAfterMarkRead` | seed t1 unread, t2 read; model; `toggleUnreadOnly()` | `rows.map(\.id) == ["t1"]`; `toggleRead(threadId: "t1", isUnread: true)` → `waitUntil { model.rows.isEmpty }`; `emptyState == .allCaughtUp` |
| `testFailedSendsSectionAndOpen` | `let job = SendJob(mode: .replyAll, originalMessageId: "m1", threadId: "t1", messageID: "<x@newtelco.de>", to: [Mailbox(name: "Bob", addr: "bob@x")], cc: [], subject: "Hi", typedText: "t", inReplyTo: nil, references: [], quoteSource: QuoteSource(author: nil, date: Date(), subject: "Hi", to: [], cc: [], html: nil, text: nil), attachments: [], includeSignature: true)`; `id = try await db.write { let id = try OutboxRepository.enqueueSend($0, job: job, now: now); try OutboxRepository.fail($0, opId: id, error: .badRequest(reason: nil, message: "boom")); return id }`; model | `waitUntil { model.failedSends.count == 1 }`; `failedSends[0].id == id`; `openFailedSend(failedSends[0])` → `activeSheet == .compose(.failedSend(outboxId: id, job: job))`; `activeSheet?.id == "compose:failedSend:\(id)"` |
| `testOpenFailedSendIgnoresModify` | seed t1; `archive("t1")`; wait 600 ms; `rec = pendingModifies()[0]` | `openFailedSend(rec)` → `activeSheet == nil` |
| `testDiscardSendRemovesRow` | as `testFailedSendsSectionAndOpen` | `discardSend(id)` → `waitUntil { model.failedSends.isEmpty }`; `try db.read { try OutboxRecord.fetchOne($0, key: id) } == nil`; `lastActionId == 1` |
| `testRetrySendLeavesFailedSection` | as above | `retrySend(id)` → `waitUntil { model.failedSends.isEmpty }`; `waitUntil { (try? db.read { try OutboxRecord.fetchOne($0, key: id)?.state }) == .pending }` (offline drain → `retryLater` uncounted → pending) |
| `testBannerFromSyncStatus` | model | `env.syncStatus.isOffline = true; env.syncStatus.lastError = "x"` → `banner == .offline`; `isOffline = false` → `.error("x")`; `lastError = nil` → `nil` |
| `testReauthBannerAndDismiss` | `env1 = AppEnvironment(testing: true)`; `try await env1.db.write { try SyncStateRepository.set($0, .accountEmail, "a@newtelco.de") }`; `try env1.db.close()`; `env2 = AppEnvironment(testing: true, databaseDirectory: env1.databaseDirectory)` (06 §3.16 overload; requires no `oauth.authState` Keychain item on the simulator — 06's `testCachedEmailReadFromSyncState` has the same precondition); model on `env2` | `env2.auth.state == .needsReauth(email: "a@newtelco.de")`; `banner == .reauth`; `env2.syncStatus.isOffline = true` → still `.reauth`; `dismissReauthBanner()` → `.offline`; `authStateChanged(.signedIn(email: "a@newtelco.de"))` → `reauthBannerDismissed == false` and `banner == .reauth` (state unchanged in env2) |
| `testDayChangeRestartsOnlyWhenBoundaryDiffers` | `fixed = Date(timeIntervalSince1970: 1_757_580_000)` (2026-09-11 08:40 UTC); seed t1 with `internalDate = 1_757_580_000_000` `["INBOX"]`; model `.today`, `clock: { fixed }`, `timeZone: berlin` | `rows.count == 1`; `dayChanged(now: fixed, timeZone: berlin)` → `day` unchanged (same instance value), `rows.count == 1`; `dayChanged(now: fixed + 86_400, timeZone: berlin)` → `day.startMs == 1_757_628_000_000`; `rows.isEmpty`; `emptyState == .nothingToday`; `dayChanged(now: fixed + 86_400, timeZone: TimeZone(identifier: "Pacific/Auckland")!)` → `day` recomputed for Auckland |
| `testRefreshWhenSignedOutReturnsFast` | model | `let t = Date(); await model.refresh(); XCTAssertLessThan(Date().timeIntervalSince(t), 1)`; `env.syncStatus.phase == .idle` |
| `testObservationErrorRecovery` | model; `try env.db.close()` then `try await env.db.write { … }` is impossible after close — instead simulate: call the private path via a `#if DEBUG` test hook `model._simulateObservationError("boom")` (§10 A12) | `banner == .error("Database unavailable")`; `rowAppeared(rows.last?.id ?? "")` does nothing; `await refresh()` → `observationError == nil`, `banner == nil` |
| `testStopCancelsObservations` | seed t1; model; `stop()`; seed t2 | after 300 ms `rows.map(\.id) == ["t1"]` (no tick after stop) |

Invariants: every test that enqueues an outbox op ends with `try InvariantChecks.assertAll(db)`.

### 7.2 `minimailTests/Inbox/InboxViewsTests.swift`

| Test | Setup | Assertions |
|---|---|---|
| `testThreadRowAccessibilityLabel` | `ThreadRow(id: "t", participants: "Alice, Me", subject: "", snippet: "s", dateLabel: "14:32", isUnread: true, messageCount: 3, hasAttachments: true, chips: [ThreadChip(id: "L", name: "ACME", textColor: nil, backgroundColor: nil)])` | `ThreadRowView.accessibilityLabel(for:) == "Unread, Alice, Me, No subject, 14:32, 3 messages, Has attachment, Label ACME"`; read row with subject "Hi", 1 message, no attachment, no chips → `"Alice, Me, Hi, 14:32"` |
| `testLabelChipColorParsing` | — | `LabelChip.color(hex: "#ff0000") != nil`; `"#FF0000"` non-nil; `"#ff000"` nil; `"ff0000"` nil; `"#gg0000"` nil; `nil` nil; resolved `UIColor(LabelChip.color(hex: "#0000ff")!)` blue component == 1 (±0.01) |
| `testStatusBannerStrings` | three kinds | `title(for: .offline) == "Offline — changes will sync"`, `symbol == "wifi.slash"`, `actionTitle == nil`, `detail == nil`; `.reauth` → `"Sign in again to keep syncing"`, `"person.crop.circle.badge.exclamationmark"`, `"Sign in"`; `.error("x")` → `"Couldn't refresh"`, `"exclamationmark.triangle"`, `"Retry"`, `detail == "x"` |
| `testFailedSendRowStrings` | `OutboxRecord` with `sendJob.subject = "  "`, `to = [Mailbox(name: "Alice", addr: "a@x")]`, `cc = [Mailbox(name: nil, addr: "b@x")]`, `lastError = nil` | `subject == "(No subject)"`; `recipients == "To: Alice, b@x"`; `errorLine == "Not sent — Unknown error"`; with `lastError = "Daily quota exceeded"` → `"Not sent — Daily quota exceeded"`; `sendJob = nil` → `recipients == "To: —"` |
| `testComposeInputAndSheetIds` | — | `ComposeInput.fromMessage(mode: .forward, threadId: "t", messageId: "m").id == "message:forward:m"`; `.failedSend(outboxId: 7, job:).id == "failedSend:7"`; `ActiveSheet.labels.id == "labels"`, `.settings.id == "settings"`, `.compose(.failedSend(outboxId: 7, job:)).id == "compose:failedSend:7"`; `ActiveSheet.compose(a) == .compose(a)` |
| `testInboxScreenHostsSeededRows` | `env = AppEnvironment(testing: true)`; seed t1, t2; `UIHostingController(rootView: InboxScreen(scope: .inbox).environment(env).environment(env.theme).environment(env.settings))`; `view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)`; `view.layoutIfNeeded()`; `RunLoop.main.run(until: Date() + 0.3)` | no crash; `view.subviews.isEmpty == false`; a `UITableView`/`UICollectionView` descendant exists (SwiftUI `List` backing) — found by walking `view` recursively; `env.deferredWorkStarted == false` (hosting the screen never starts sync) |
| `testRootViewSignedInShowsInbox` | env as above; make auth `.signedIn` impossible without Keychain → host `RootView` with the `.needsReauth` env of `testReauthBannerAndDismiss` (same construction) | no crash; `view.subviews.isEmpty == false` |
| `testPlaceholderSignatures` | — | `_ = ThreadScreen(threadId: "t"); _ = ComposeScreen(input: .fromMessage(mode: .replyAll, threadId: "t", messageId: "m")); _ = LabelsScreen(onSelect: { _ in }); _ = SettingsScreen()` compile and host in `UIHostingController` without crash (modules 10–13 keep this test compiling when they replace the placeholders) |
| `testDayChangeStreamYieldsOnNotification` | `let stream = InboxScreen.dayChangeStream()`; `Task { var it = stream.makeAsyncIterator(); await it.next(); exp.fulfill() }`; post `NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)` | expectation fulfilled within 1 s; cancelling the task removes observers (a second post after cancellation does not crash) |

Test count: 26 (InboxModelTests) + 9 (InboxViewsTests) = 35.

---

## 8. Tasks

Ordered; each one sitting; verification on the macOS runner unless noted.

- [ ] **T09.1 Shared types + model skeleton** — files: `minimail/Features/Inbox/InboxModel.swift` (`InboxScope`, `ThreadRoute`, `ComposeInput`, `ActiveSheet`, `InboxBanner`, `InboxEmptyState`, `InboxModel` with `init`, `startThreads`, `startAux`, `apply`, `recomputeHasOlder`, `query`, `title`, `banner`, `emptyState`, `olderReason`, `stop`). Done when `make build` passes and `InboxModel(env:scope:)` yields rows synchronously (temporary `print` allowed, removed in T09.2). Verify: `make build`. (~220 lines)
- [ ] **T09.2 Model behaviour** — file: `InboxModel.swift` (`setScope`, `toggleUnreadOnly`, `rowAppeared`, `loadOlder`, `refresh`, `dayChanged`, `archive`, `toggleRead`, `retrySend`, `discardSend`, `openFailedSend`, `dismissReauthBanner`, `authStateChanged`, `observationFailed`, DEBUG hook `_simulateObservationError`); test file `minimailTests/Inbox/InboxModelTests.swift` with the first 15 tests of §7.1 (`testImmediateRowsOnInit` … `testCountsObserved`). Done when those 15 pass. Verify: `make test-one T=minimailTests/InboxModelTests`. (~250 lines)
- [ ] **T09.3 Row and chip views** — file: `minimail/Features/Inbox/ThreadRowView.swift` (`ThreadRowView`, `LabelChip`, `accessibilityLabel(for:)`, `color(hex:)`); tests `testThreadRowAccessibilityLabel`, `testLabelChipColorParsing` in `minimailTests/Inbox/InboxViewsTests.swift`. Done when both pass and `make lint` reports no raw colour under `minimail/Features`. Verify: `make test-one T=minimailTests/InboxViewsTests && make lint`. (~120 lines)
- [ ] **T09.4 Banners and outbox rows** — file: `minimail/Features/Inbox/StatusBanner.swift` (`StatusBanner`, `FailedSendRow` + static string helpers); tests `testStatusBannerStrings`, `testFailedSendRowStrings`, `testComposeInputAndSheetIds`. Done when they pass. Verify: `make test-one T=minimailTests/InboxViewsTests`. (~130 lines)
- [ ] **T09.5 Screen, toolbar, sheets, placeholders, RootView** — files: `minimail/Features/Inbox/InboxScreen.swift` (`InboxScreen`, `InboxListView`, `InboxEmptyView`, `dayChangeStream`, toolbar, title menu, sheet routing, swipe actions, haptics, `markFirstListPaint`), `minimail/Features/Inbox/InboxPlaceholders.swift`, `minimail/App/RootView.swift` (branch + deletion of both placeholders); tests `testInboxScreenHostsSeededRows`, `testRootViewSignedInShowsInbox`, `testPlaceholderSignatures`, `testDayChangeStreamYieldsOnNotification`. Done when `make build` passes, 01's `AppEnvironmentTests.testRootViewHosts` still passes and the four tests pass. Verify: `make test-one T=minimailTests/InboxViewsTests && make test-one T=minimailTests/AppEnvironmentTests`. (~300 lines)
- [ ] **T09.6 Remaining model tests** — file: `minimailTests/Inbox/InboxModelTests.swift` (the 11 tests from `testArchiveRemovesRowAndEnqueues` to `testStopCancelsObservations`). Done when all 26 pass with invariants. Verify: `make test-one T=minimailTests/InboxModelTests`. (~200 lines)
- [ ] **T09.7 Full suite + lint** — no new files. Done when `make test-app` shows `failedTests: 0` and `make format` produces no diff on a second run and `make lint` exits 0. Verify: `make format && git diff --stat && make lint && make test-app`.
- [ ] **T09.8 Simulator check** (macOS, optional if no simulator) — no files. Boot `iPhone 17`, install the Debug build, launch; with a signed-out env the sign-in screen shows; to see the list without OAuth, run the app with `MINIMAIL_TESTING=1` and a seeded temporary DB is not available — instead verify on the owner's device after 04's sign-in (T04.8): rows, title menu, unread toggle, swipe tints, dark mode. Commands as in 01 T01.9 (`xcrun simctl … screenshot`). Screenshots to `.build/shot-inbox-{light,dark}.png`.

---

## 9. Acceptance criteria

1. `make build` succeeds under Swift 6 / MainActor default with `minimail/Features/Inbox/{InboxModel,InboxScreen,ThreadRowView,StatusBanner,InboxPlaceholders}.swift` present and `SignedInPlaceholderView` / `RootPlaceholderView` absent: `grep -rn "SignedInPlaceholderView\|RootPlaceholderView" minimail minimailTests | wc -l` prints `0`.
2. `make test-app` passes all 35 tests of §7 plus every earlier module's tests (`failedTests: 0` in `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact`).
3. `make lint` exits 0 — in particular no raw colour in `minimail/Features/Inbox` (`grep -rnE "Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)|\.tint\(\.(blue|indigo|green|red)\)" minimail/Features/Inbox` prints nothing) and no `import GRDB`-driven SQL strings: `grep -rn "SELECT\|INSERT\|UPDATE\|DELETE" minimail/Features/Inbox | wc -l` prints `0`.
4. `InboxModel(env:scope:)` returns with `rows` populated synchronously from a seeded pool (`testImmediateRowsOnInit`), i.e. the first frame of `InboxScreen` is rendered from SQLite without awaiting anything (architecture §12.2).
5. Swipe archive removes an inbox row on the next observation tick and leaves exactly one pending `modify` op (`testArchiveRemovesRowAndEnqueues`); read → unread within the debounce window leaves zero ops (`testToggleReadFlipsAndCoalesces`); invariants §3.5 hold after each.
6. Scope switching, unread toggle and paging change only `ThreadQuery` fields and restart the observation in place (`testQueryMirrorsState`, `testPagingIncreasesLimit`, `testToggleResetsLimit`); `hasOlder` follows the page tokens (`testHasOlderFromInboxToken`, `testHasOlderFromLabelToken`) and load-older stops after bounded retries (`testLoadOlderRunsAndStops`).
7. Banner priority reauth > offline > error and reauth dismissal behave per §4.6 (`testBannerFromSyncStatus`, `testReauthBannerAndDismiss`); no alert is ever presented (no `.alert` modifier in `minimail/Features/Inbox`: `grep -rn "\.alert(" minimail/Features/Inbox | wc -l` prints `0`).
8. Failed sends appear in the "Outbox" section, open a `.compose(.failedSend)` sheet on tap, and Retry / Delete change the row state (`testFailedSendsSectionAndOpen`, `testRetrySendLeavesFailedSection`, `testDiscardSendRemovesRow`).
9. Day change restarts the observations only when the boundary or zone differs (`testDayChangeRestartsOnlyWhenBoundaryDiffers`); no timer exists in the module (`grep -rn "Timer\|DispatchSourceTimer" minimail/Features/Inbox | wc -l` prints `0`).
10. Manual device step (after T04.8 sign-in on the owner's iPhone, TestFlight or direct install): the inbox lists cached threads with unread dots, participant names, date labels and chips; the title menu switches Inbox/Today; the funnel toggles unread-only with a selection haptic; leading swipe archives (indigo tint) with a light impact; trailing swipe toggles read (blue tint); airplane mode → "Offline — changes will sync" row appears after the next pull-to-refresh and disappears on the first successful request; scrolling to the end after > 60 cached threads loads more rows without a hitch; dark mode renders through `.systemBackground`/`.label` (no white flash on launch).

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | Architecture/modules.md write `InboxScreen(scope:)` without naming the type; `ThreadQuery.Scope.today` carries a `DayBoundary`. | DEVIATION (additive) | New `InboxScope { inbox, today, label(id:) }` (no boundary) is the screen/sheet-level scope; `InboxModel.query` converts with its own `day`. `LabelsScreen(onSelect: (InboxScope) -> Void)` is the contract for 12. |
| D2 | Spec 04 §3.8 comments that 09 replaces the placeholder with `NavigationStack { InboxScreen(scope: .inbox) }`. | DEVIATION | The `NavigationStack(path:)` lives inside `InboxScreen` (it owns `path`); `RootView` shows `InboxScreen(scope: .inbox)` directly. modules.md 09 lists "`NavigationStack` root" in this module's scope. |
| D3 | Architecture §4.8 says offline shows "a nav-bar subtitle 'Offline — changes will sync' (wifi.slash)"; §8.2 and modules.md say `StatusBanner` rows. | DEVIATION (choice) | Rendered as a `StatusBanner` list row (iOS 17 SwiftUI has no navigation-subtitle API and a custom principal toolbar item conflicts with `.toolbarTitleMenu`). Same text and symbol. |
| D4 | modules.md assigns `LabelChip` to module 12, but 09 (chips in rows) precedes 12. | DEVIATION | `LabelChip` is created in `Features/Inbox/ThreadRowView.swift` with the colour mapping of §3.3. Module 12 reuses it (may move the struct into `Features/Labels/` unchanged; the row keeps referencing `LabelChip`). |
| D5 | `Features/Inbox/InboxPlaceholders.swift` is not in the architecture §1.3 tree. | DEVIATION (temporary) | Needed so 09 compiles before 10–13 (same precedent as 04's `SignedInPlaceholderView`). Each later module deletes its struct; 13 deletes the file; `testPlaceholderSignatures` keeps compiling against the real screens. |
| D6 | Architecture lists `InboxModel` state as `query`, `rows`, `day`, `counts`, `failedSends`, `hasOlder`, `syncStatus`, `activeSheet`. | additive | `query` is computed from `scope`/`unreadOnly`/`limit`; `syncStatus` is read through `env.syncStatus` (one instance, 07); added `labels`, `isLoadingOlder`, `observationError`, `lastActionId`, `filterChangeId`, `reauthBannerDismissed`, `InboxBanner`, `InboxEmptyState`, `olderReason`. |
| D7 | `ComposeInput` is `Equatable`/`Identifiable`, not `Hashable`. | constraint | `SendJob.quoteSource: QuoteSource` is declared `Codable, Sendable, Equatable` only (architecture §2.2). `.sheet(item:)` needs `Identifiable` only. |
| D8 | The aux observation calls `SyncStateRepository.get(db, .inboxNextPageToken)` from UI code; architecture §2.1 rule 3 says UI `SELECT`s live in `Queries`. | assumption | A repository accessor is not a SQL string in `Features/`; the rule's intent (no SQL outside `Store/`) holds. If 06 later adds `Queries.inboxNextPageToken`, switch to it. |
| D9 | Test files `minimailTests/Inbox/*.swift` are not in the §1.3 tree (which lists `SmokeTests` for screen hosting). | DEVIATION (additive) | Same as 01/06/07: module-owned tests; 14's `SmokeTests` still hosts `InboxScreen` against a seeded DB. |
| A1 | `.toolbarTitleMenu` and `.sensoryFeedback` are not cited in the research files (`[ios-platform §0]` lists the other stage-1 APIs). | assumed (Apple docs: `toolbarTitleMenu(content:)` iOS 16.0; `sensoryFeedback(_:trigger:)` iOS 17.0) | If either fails to compile on iOS 17.0, fallback: a `Menu` inside `ToolbarItem(placement: .principal)` showing the title with a chevron; haptics via `UIImpactFeedbackGenerator(style: .light).impactOccurred()` / `UISelectionFeedbackGenerator().selectionChanged()` called in the model methods. |
| A2 | `AnyDatabaseCancellable` as the return type of `ValueObservation.start`. | UNVERIFIED `[ios-platform §2.6]` | Store whatever type `start(in:scheduling:onError:onChange:)` returns (GRDB 7.11.1 source); the code never names the type except in the two private properties. |
| A3 | Model creation in `.onAppear` renders the rows in the first presented frame (no blank frame). | assumption | The placeholder branch paints `themeTokens.background` (= `LaunchBackground`), so an extra frame is invisible. The `coldStartToList` signpost ends in `InboxListView.onAppear`, i.e. only when rows are laid out — the device measurement of §12.1 stays honest either way. |
| A4 | `ValueObservation.removeDuplicates()` exists on the observation returned by `trackingConstantRegion` for `Equatable` values. | GRDB 7 documented API | If unavailable, drop it: SwiftUI's `ForEach` diffing on `Equatable` rows keeps the visible cost low; `apply(aux)` already compares fingerprints. |
| A5 | `.immediate` scheduling delivers every notification on the main dispatch queue, so `MainActor.assumeIsolated` inside the `@Sendable` callbacks is safe. | `[ios-platform §2.6]` ("default scheduling: notifies on the main actor, asynchronously; `.immediate` delivers the first value synchronously") | If GRDB 7.11.1 offers `scheduling: .mainActor` or an `@MainActor`-typed `onChange`, prefer it and delete the `assumeIsolated` wrappers. |
| A6 | `NotificationCenter.notifications(named:)` yields non-`Sendable` `Notification`s and does not compile in a main-actor `for await` under strict concurrency. | assumption (Swift 6.2 diagnostics) | `dayChangeStream()` wraps `addObserver(forName:object:queue:using:)`; if the async sequence compiles cleanly, either form is acceptable — the stream helper stays for testability. |
| A7 | `NSCalendarDayChanged` / `NSSystemTimeZoneDidChange` are delivered to a foreground app; a backgrounded app receives them on next activation. | Apple docs | The scene-active `dayChanged()` call covers the background case (architecture §14 #19 lists all three triggers). |
| A8 | Pull-to-refresh while a run is active returns immediately (`SyncEngine.run` single-flight) and the refresh control stops early. | 07 §4.4.1 | Accepted; the queued `.pullToRefresh` still executes at the end of the active run. |
| A9 | Gmail label colours (`textColor`/`backgroundColor`) are shown unchanged in dark mode. | choice | Gmail's apps do the same; labels without colours use `chipBackground`/`text` tokens which adapt. |
| A10 | Hidden `NavigationLink` + `opacity(0)` in a `ZStack` removes the disclosure chevron while keeping cell highlight and value-based navigation. | widely used SwiftUI pattern | Fallback: keep the visible `NavigationLink` (chevron shown) — no behaviour change. |
| A11 | `OutboxRecord.lastError` for failed sends holds a short user string (`GmailError.userMessage` or the synthetic messages of 07 §6). | 07 A2 (assumption for 06) | Displayed verbatim after "Not sent — " with `lineLimit(1)`; if 06 stores `String(describing:)` the row still works. |
| A12 | Simulating an observation failure needs a DEBUG-only hook. | test design | `#if DEBUG func _simulateObservationError(_ text: String) { observationFailed(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text])) } #endif` on `InboxModel`; production code never calls it. |
| A13 | The simulator Keychain has no `oauth.authState` item when `testReauthBannerAndDismiss` runs. | shared precondition with 06's `testCachedEmailReadFromSyncState` and 04's tests | If a stale item exists, the test `XCTSkip`s with the reason "Keychain item present" (04's tests delete their own accounts in tearDown). |
| A14 | `AppEnvironment(testing: true)` opens a `DatabasePool` (06 `openTemporary`) so `trackingConstantRegion` behaves as in production; `close()` in tearDown releases the file. | 06 §3.16 | If 06 switches tests to `DatabaseQueue`, the observations still work (GRDB supports both readers); `.immediate` semantics are identical. |
| A15 | `.labelOpened(id)` is triggered by 12's `LabelsScreen`, not by `setScope(.label)`. | modules.md 12 | If 12 prefers the model to trigger it, add one line to `setScope`: `if case .label(let id) = scope { Task { await env.sync.run(.labelOpened(id)) } }` — single-flight makes a double trigger harmless. |
| A16 | "Today" + load-older: older inbox pages may still contain today's mail on very busy days. | choice | Uniform paging rule with the 3-retry bound; no server `after:` query (architecture D16, `[gmail-api gotcha 20]`). |
| A17 | `env.actions` is `private(set) var` on `AppEnvironment` (07 D6) and may be rebuilt after a wipe. | 07 §3.10 | The model never caches it; every call reads `env.actions` at call time. |
