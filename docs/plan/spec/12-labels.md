# Module 12 — labels (`Features/Labels`)

Status: detailed spec. Sources of truth: `docs/plan/design/architecture.md` (§2.4 app interfaces, §3.2 DDL `label` table, §4.1 `.labelOpened` / `.loadOlderLabel`, §4.6 labels/unread counts/badge, §8.1 navigation graph, §8.2 screen contract "LabelsScreen / LabelsModel", §8.6 label filter SQL, §10 theming, §12.1/§12.3 performance, §13.3 app tests, §15 D15/D21, §16 non-goals, Appendix A), `docs/plan/design/modules.md` (scope of 12 and of 06/07/09), `PLAN.md` ("Label list (system + user labels, Gmail colors, unread counts)", "Tap label → filtered list"), research `[gmail-api §10, §11]`, `[ios-platform §2.6, §5.1, §5.2]`.

Dependencies: **07-sync-outbox** (`SyncEngine.run(.labelOpened:)`, `SyncEngine.refreshLabelCounts(force:)`, `SyncEngine.labelCountsStaleness`, `SyncStatus`), **09-inbox-list** (`InboxScope`, the `LabelsScreen(onSelect:)` contract, `LabelChip`, `ThreadChip`). Transitively: 01 (`AppEnvironment`, `ThemeStore`, `ThemeTokensReader`, `ThemeTokens`, `Log.ui`), 06 (`Queries.labelsForSheet`, `Queries.inboxUnreadThreadCount`, `Queries.todayThreadCount`, `LabelRecord`, `SyncStateRepository`, `SyncKey.lastLabelCountsAt`, `DayBoundary`, `TestDatabase`), 03 (`GmailLabel` in tests only).

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. **`LabelsScreen(onSelect:)`** — the sheet presented from the inbox title menu ("Labels…", 09 §6.2). Two sections: **Mailboxes** (Inbox with the local unread thread count, Today with the local today count) and **Labels** (the rows of `Queries.labelsForSheet` with Gmail colours and the server `threadsUnread`, footer "Counts from Gmail"). Pull-to-refresh forces a label-count refresh.
2. **`LabelsModel`** — the main-actor model: one `ValueObservation(.immediate)` over the `label` table, the two local counts and `syncState.lastLabelCountsAt`; the precomputed `LabelRow` projection; the sheet-open staleness check (5 min) that calls `SyncEngine.refreshLabelCounts(force: true)`; selection handling that fires `SyncEngine.run(.labelOpened(id))` and hands an `InboxScope` back to the presenter.
3. **`LabelChip` ownership** — the Gmail-coloured capsule created in 09 (`Features/Inbox/ThreadRowView.swift`) moves unchanged to `minimail/Features/Labels/LabelChip.swift` (modules.md assigns it to this module; 09 D4 sanctions the move), joined by `LabelColorDot`, the small colour dot used by the labels sheet rows.
4. **Deletion of the interim `LabelsScreen` placeholder** that module 09 created in `minimail/Features/Inbox/InboxPlaceholders.swift`, plus the two hosting tests in `minimailTests/Inbox/InboxViewsTests.swift` that hosted it without an environment.
5. **Contract tests for 07's label behaviour** (`SyncEngine.refreshLabelCounts(force:)` throttle/force, `hydrateLabelViewIfStale` once-per-24 h, `loadOlderLabel` page token) — modules.md assigns the *verification* of those behaviours to this module; the implementation stays in 07.

### 1.2 Explicitly out of scope (owned elsewhere)

| Not here | Owner |
|---|---|
| The inbox list itself, `InboxModel`, `InboxScope` definition, `ThreadRow`/`ThreadChip`, `ThreadRowView`, swipe actions, banners, the `.sheet(item:)` presentation and the `activeSheet = nil` dismissal | 09 |
| `SyncEngine.refreshLabelCounts` / `hydrateLabelViewIfStale` / `loadOlderLabel` / `loadOlderInbox` **implementations**, `SyncStatus`, `Outbox`, badge | 07 |
| `LabelRepository.{replaceAll,updateCounts,markViewFetched,cachedViewLabelIds,displayedLabelIds}`, `Queries.labelsForSheet` SQL, the `label` DDL | 06 |
| `GmailClient.listLabels` / `getLabels`, the batch codec, `GmailLabel` DTO | 05, 03 |
| Settings screen, theme picker, signature editor | 13 |
| Creating / renaming / deleting labels, applying a label to a thread, star/trash/spam actions, label counts for hidden labels, nested-label tree UI, search | architecture §16 (non-goals) |
| Any SQL string (every read goes through `Queries` / `SyncStateRepository`) | 06 |

### 1.3 Consumers and the exact symbols they take

| Consumer | Symbols |
|---|---|
| 09 `InboxScreen` | `LabelsScreen(onSelect:)` — presented for `ActiveSheet.labels` (09 §4.8); `LabelChip` (moved here, API unchanged) used by `ThreadRowView` |
| 13 `SettingsScreen` | nothing directly (`LabelChip` is available but unused there) |
| 14 QA | `LabelsModel`, `LabelsScreen` for `SmokeTests`; the accessibility identifiers of §5.4 for the device checklist |

---

## 2. Files

| Path (relative to repo root) | Kind | Purpose |
|---|---|---|
| `minimail/Features/Labels/LabelsModel.swift` | new | `LabelRow`, `LabelsEmptyState`, `LabelsModel` (observation, row projection, staleness check, refresh, selection), private `LabelsAux` |
| `minimail/Features/Labels/LabelsScreen.swift` | new | `LabelsScreen(onSelect:)`, private `LabelsListView`, private `LabelRowView`, private `LabelsEmptyView` |
| `minimail/Features/Labels/LabelChip.swift` | new | `LabelChip` (moved verbatim from 09's `ThreadRowView.swift`) + `LabelChip.color(hex:)`, and `LabelColorDot` |
| `minimail/Features/Inbox/ThreadRowView.swift` | modify | delete `struct LabelChip` (now in `Features/Labels/LabelChip.swift`); `ThreadRowView` keeps referring to `LabelChip` unchanged |
| `minimail/Features/Inbox/InboxPlaceholders.swift` | modify | delete the interim `struct LabelsScreen` (file keeps `ComposeScreen` and `SettingsScreen` until 11 and 13) |
| `minimailTests/Labels/LabelsModelTests.swift` | new | model behaviour against `AppEnvironment(testing: true)` + a seeded pool (§7.1) |
| `minimailTests/Labels/LabelsViewsTests.swift` | new | pure row/footer helpers, colour parsing, hosting smoke tests (§7.2) |
| `minimailTests/Labels/LabelSyncContractTests.swift` | new | 07 contract verification with `SyncHarness` + `BatchStub` (§7.3) |
| `minimailTests/Inbox/InboxViewsTests.swift` | modify | `testPlaceholderSignatures` and `testLabelsPlaceholderCallsOnSelect` host the **real** `LabelsScreen`, which needs the three `.environment` modifiers (§7.4) |

No `Packages/MailCore` or `Packages/MailHTML` file is added or edited — this module ships no pure algorithm, so `swift test` on Linux is unaffected. No `project.yml` change (the app target globs `minimail/`, the test target globs `minimailTests/`, 01 §1.4). No `Info.plist` key, no entitlement, no asset, no migration.

---

## 3. Public interface

Conventions (01 §3, 06 §3, 09 §3): the app target builds with `SWIFT_VERSION = 6` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` `[ios-platform §5.6]`, so every declaration below is `@MainActor` **implicitly** unless it carries an explicit `nonisolated`. App declarations are `internal` (no `public`). Types that cross into GRDB `@Sendable` fetch closures or into actors are `nonisolated` and `Sendable` value types.

Signatures marked `// verbatim` are copied from architecture §2.4 / §8.2 / modules.md / 09 §3.5. Every deviation is listed in §10.

### 3.1 `minimail/Features/Labels/LabelsModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import Observation

/// One fully precomputed row of the labels sheet — a mailbox row (Inbox / Today) or a label row.
///
/// Everything the view needs is a `String`: `body` performs no formatting, no number formatting and no colour parsing
/// beyond `LabelChip.color(hex:)` (09 §3.3), which is a pure static function.
nonisolated struct LabelRow: Identifiable, Equatable, Sendable {
    /// `"mailbox.inbox"`, `"mailbox.today"`, or a Gmail label id (`"STARRED"`, `"Label_12"`). Drives `ForEach` identity
    /// and the accessibility identifier `"labels.row.<id>"` (§5.4).
    let id: String
    /// Display title: `"Inbox"`, `"Today"`, the friendly name of a system label (§4.4 table), or `LabelRecord.name`
    /// verbatim for a user label (full Gmail name including `/` separators, e.g. `"Customers/ACME"`).
    let title: String
    /// Trailing count, already formatted (`"3"`, `"999+"`), or `nil` when there is nothing to show (§4.5).
    let countText: String?
    /// SF Symbol of the leading icon, or `nil` when the row shows a `LabelColorDot` instead (user label with a colour).
    let symbol: String?
    /// `label.backgroundColor` (`"#rrggbb"`) of a user label; `nil` for mailbox rows, system labels and uncoloured user labels.
    let colorHex: String?
    /// What `onSelect` receives when the row is tapped.
    let scope: InboxScope
    /// VoiceOver label (§6.4): the title, unchanged.
    let accessibilityLabel: String
    /// VoiceOver value: `"12 unread"` (Inbox and label rows), `"5 today"` (Today row), or `nil` when `countText == nil`.
    let accessibilityValue: String?
}

/// What the Labels section shows when it has no label rows (§4.6).
nonisolated enum LabelsEmptyState: Equatable, Sendable {
    /// `SyncStatus.phase == .initialSync` — the first sync has not delivered `labels.list` yet.
    case initialSync
    /// The `label` table is empty (or holds only hidden labels) and no sync is running.
    case noLabels
    /// The `ValueObservation` failed; the cached rows (if any) are still shown, this state only appears when there are none.
    case unavailable
}

/// Main-actor model of the labels sheet (architecture §8.2 row "LabelsScreen / LabelsModel").
///
/// One instance per sheet presentation: `LabelsScreen` creates it on appear and drops it when the sheet goes away, so the
/// once-per-presentation staleness check (§4.7) needs no extra bookkeeping. Creating it performs exactly one synchronous
/// cache read (`.immediate` observation) and no network, no `Task` and no `DatabasePool.write`.
@Observable final class LabelsModel {

    // ---- constants ----
    /// 300 s — `SyncEngine.labelCountsStaleness` (07 §3.2, architecture §4.6). Counts older than this are refreshed when the
    /// sheet opens.
    static let countsStaleness: TimeInterval = SyncEngine.labelCountsStaleness
    /// Label ids removed from the Labels section because the Mailboxes section already shows them with a **local** count
    /// (architecture §4.6). DEVIATION D1 (§10).
    static let hiddenLabelIds: Set<String> = ["INBOX"]
    /// Friendly names for the system labels the sheet can show (§4.4).
    static let systemDisplayNames: [String: String] = [
        "INBOX": "Inbox", "STARRED": "Starred", "IMPORTANT": "Important", "SENT": "Sent",
        "DRAFT": "Drafts", "SPAM": "Spam", "TRASH": "Trash",
    ]
    /// Leading SF Symbols for system labels (§5.3).
    static let systemSymbols: [String: String] = [
        "INBOX": "tray", "STARRED": "star", "IMPORTANT": "bookmark", "SENT": "paperplane",
        "DRAFT": "doc", "SPAM": "xmark.bin", "TRASH": "trash",
    ]
    /// Counts above this render as `"999+"` so a four-digit number cannot squeeze the title (§4.5).
    static let maxDisplayedCount = 999

    /// Composition root. `db`, `sync` and `syncStatus` are read from it at call time (07 D6: `AppEnvironment.db` is
    /// reassigned after an account wipe, so no sub-object is cached here).
    let env: AppEnvironment

    // ---- observed state (mutated only by this class) ----
    /// `[Inbox, Today]`, in that order, rebuilt on every observation tick.
    private(set) var mailboxRows: [LabelRow] = []
    /// `Queries.labelsForSheet` order, minus `hiddenLabelIds` (§4.3).
    private(set) var labelRows: [LabelRow] = []
    /// `Queries.inboxUnreadThreadCount` — local, matches the list including optimistic state (architecture §4.6).
    private(set) var inboxUnreadCount: Int = 0
    /// `Queries.todayThreadCount(day)` — local.
    private(set) var todayCount: Int = 0
    /// `syncState.lastLabelCountsAt` as a `Date`; `nil` until the first successful `refreshLabelCounts`.
    private(set) var countsFetchedAt: Date?
    /// True while `refreshLabelCounts(force: true)` is awaited (drives the footer text; the system supplies the
    /// pull-to-refresh spinner).
    private(set) var isRefreshing: Bool = false
    /// Number of `SyncEngine.refreshLabelCounts(force: true)` calls this model made (staleness check + pull-to-refresh).
    /// Observable so §7.1 can assert the throttle decisions without a network stub.
    private(set) var countsRefreshes: Int = 0
    /// Label ids handed to `SyncEngine.run(.labelOpened(id))`, in call order (§4.8).
    private(set) var openedLabelIds: [String] = []
    /// The scope of the most recent `select(_:)`.
    private(set) var lastSelected: InboxScope?
    /// `true` once `appeared()` has performed the staleness check for this presentation.
    private(set) var didCheckStaleness: Bool = false
    /// Text of the last `ValueObservation` failure; `nil` after a successful restart (`refresh()`).
    private(set) var observationError: String?

    // ---- derived (computed; no storage, no side effects) ----
    /// `nil` when `labelRows` is non-empty; otherwise `.unavailable` → `.initialSync` → `.noLabels` (§4.6).
    var emptyState: LabelsEmptyState? { get }
    /// Footer of the Labels section, e.g. `"Counts from Gmail · updated 3 min ago"` (§4.9).
    var footerText: String { get }

    /// Starts the single observation synchronously with `.immediate` scheduling, so that when `init` returns
    /// `mailboxRows`, `labelRows`, `inboxUnreadCount`, `todayCount` and `countsFetchedAt` already hold the cache contents
    /// (the sheet's first frame is drawn from SQLite, never from a spinner).
    ///
    /// - Parameters:
    ///   - env: composition root (`env.db` must be open; it always is after launch step 1).
    ///   - clock: `now` for `DayBoundary.today` and for the footer's relative time; injected in tests.
    ///   - timeZone: device time zone by default; only `DayBoundary.today` uses it.
    ///
    /// Performs no network call, no `sync.run`, no `Task`. Never throws: an observation that fails at start reports through
    /// `onError` → `observationError` (§4.11).
    init(env: AppEnvironment,
         clock: @escaping () -> Date = Date.init,
         timeZone: TimeZone = .current)

    /// Called once from `LabelsScreen.task` (§6.2). Performs the sheet-open staleness check of architecture §4.6:
    /// when `countsFetchedAt` is `nil` or older than `countsStaleness`, awaits `refreshCounts()`; otherwise returns
    /// immediately. Idempotent — the second call is a no-op (`didCheckStaleness`).
    func appeared() async

    /// Pull-to-refresh (`.refreshable`). Restarts a failed observation first, then always awaits
    /// `env.sync.refreshLabelCounts(force: true)` — the 5-minute throttle is deliberately bypassed (architecture §4.6).
    /// Never throws; errors surface through `SyncStatus.lastError` and the footer.
    func refresh() async

    /// Row tap. Records `lastSelected`; for `.label(id)` also starts `Task { await env.sync.run(.labelOpened(id)) }`
    /// (fire-and-forget: `SyncEngine.run` is single-flight and never throws) and appends `id` to `openedLabelIds`.
    /// Does **not** dismiss the sheet and does **not** call `onSelect` — `LabelsScreen` calls this immediately before
    /// invoking `onSelect(scope)` (09 §4.8 contract).
    func select(_ scope: InboxScope)

    /// Cancels the observation (used by `LabelsScreen.onDisappear` and by tests).
    func stop()

    // ---- pure helpers (unit-tested in §7.2) ----

    /// `systemDisplayNames[label.id]` for `type == "system"`, else `label.name` verbatim.
    nonisolated static func displayName(for label: LabelRecord) -> String
    /// `nil` for a user label that carries a `backgroundColor` (it renders a `LabelColorDot`);
    /// `systemSymbols[label.id]` for a known system label; `"tag"` for everything else.
    nonisolated static func symbol(for label: LabelRecord) -> String?
    /// `nil` when `count` is `nil` or `<= 0`; `"999+"` above `maxDisplayedCount`; else the decimal digits.
    nonisolated static func countText(_ count: Int?) -> String?
    /// The complete row projection for one label (`scope = .label(id: label.id)`).
    nonisolated static func row(for label: LabelRecord) -> LabelRow
    /// The two mailbox rows for the given local counts.
    nonisolated static func mailboxRows(inboxUnread: Int, today: Int) -> [LabelRow]
    /// Footer text (§4.9). Priority: refreshing → offline → never fetched → relative age.
    nonisolated static func footer(countsFetchedAt: Date?, now: Date, isOffline: Bool, isRefreshing: Bool) -> String

    #if DEBUG
    /// Test hook (09 §10 A12 precedent): feeds `observationFailed` with a synthetic error so the `.unavailable` state and
    /// the recovery path can be exercised without corrupting the database. Never called by production code.
    func _simulateObservationError(_ text: String)
    #endif
}
```

Private members of `LabelsModel` (named so tests and reviewers can reason about them; not API):

```swift
/// One fetch of everything the sheet shows. `Equatable` so `removeDuplicates()` suppresses ticks caused by writes to
/// unrelated tables (message/thread writes that do not change a count).
nonisolated private struct LabelsAux: Equatable, Sendable {
    var labels: [LabelRecord]
    var inboxUnread: Int
    var today: Int
    var lastLabelCountsAt: Int64?
}

private var cancellable: AnyDatabaseCancellable?     // name UNVERIFIED `[ios-platform §2.6]`; 09 §10 A2 fallback applies
private let clock: () -> Date
private let timeZone: TimeZone
private let day: DayBoundary                          // computed once in init (§4.10)

private func start()
private func apply(_ aux: LabelsAux)
private func refreshCounts() async
private func observationFailed(_ error: any Error)
```

### 3.2 `minimail/Features/Labels/LabelsScreen.swift`

```swift
import SwiftUI

/// The labels sheet (architecture §8.1: `InboxScreen ├─ sheet LabelsScreen`).
///
/// Contract with module 09 (`InboxPlaceholders.swift` doc comment, 09 §4.8): call `onSelect(scope)` **exactly once** per
/// selection and do **not** dismiss the sheet — the presenter sets `activeSheet = nil` inside its `onSelect` closure.
/// The explicit "Done" button is the only place this screen dismisses itself.
struct LabelsScreen: View {                                                            // verbatim: LabelsScreen(onSelect:)
    /// Receives `.inbox`, `.today` or `.label(id:)`. Invoked on the main actor, synchronously, from the row's button action.
    init(onSelect: @escaping (InboxScope) -> Void)
    var body: some View
}

/// Everything that needs the model — the `List`, its two sections, the footer, pull-to-refresh.
/// Private; documented because the hosting tests walk the rendered hierarchy.
private struct LabelsListView: View {
    let model: LabelsModel
    let onSelect: (InboxScope) -> Void
    @ThemeTokensReader private var themeTokens
    var body: some View
}

/// One row: leading icon or colour dot, title, trailing count. No `Task`, no formatting, no environment access beyond the
/// theme tokens.
private struct LabelRowView: View {
    let row: LabelRow
    @ThemeTokensReader private var themeTokens
    var body: some View
}

/// `ContentUnavailableView` / `ProgressView` for the three empty states (§6.5).
private struct LabelsEmptyView: View {
    let state: LabelsEmptyState
    var body: some View
}
```

### 3.3 `minimail/Features/Labels/LabelChip.swift`

```swift
import CoreGraphics
import MailCore
import SwiftUI

/// Gmail-coloured capsule for one user label. Created by module 09 in `Features/Inbox/ThreadRowView.swift`; moved here
/// unchanged because modules.md assigns the chip to this module and 09 DEVIATION D4 permits the move ("it may move the
/// struct to `Features/Labels/` unchanged; the row keeps referring to `LabelChip`"). The API is byte-identical to 09 §3.3.
struct LabelChip: View {                                                               // verbatim (09 §3.3)
    let chip: ThreadChip
    init(chip: ThreadChip)
    var body: some View

    /// `"#rrggbb"` (exactly 7 characters, case-insensitive hex) → `Color`; anything else (wrong length, non-hex, `nil`)
    /// → `nil`, and the caller falls back to `themeTokens.chipBackground` / `themeTokens.text`.
    ///
    /// Implemented as `Color(cgColor: CGColor(srgbRed:green:blue:alpha: 1))` — **not** `Color(red:green:blue:)` and not
    /// `UIColor(red:…)`, because `make lint` greps for `Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)` over
    /// `minimail/Features` and the substring `Color(red` occurs inside `UIColor(red:` (01 §1.6, 09 §10 D9).
    nonisolated static func color(hex: String?) -> Color?
}

/// 10 pt circle in a label's Gmail background colour, used as the leading icon of a coloured user label in the sheet.
/// Falls back to `themeTokens.chipBackground` when the hex is missing or malformed.
struct LabelColorDot: View {
    let colorHex: String?
    /// 10 — same diameter as the unread dot of the list row (architecture §8.3).
    static let diameter: CGFloat = 10
    init(colorHex: String?)
    var body: some View
}
```

### 3.4 `minimail/Features/Inbox/ThreadRowView.swift` (modify)

```swift
// DELETED by this module (moved verbatim to minimail/Features/Labels/LabelChip.swift):
//     struct LabelChip: View { let chip: ThreadChip; … ; nonisolated static func color(hex:) -> Color? }
// `ThreadRowView.body` keeps its `ForEach(row.chips) { LabelChip(chip: $0) }` line unchanged — same target, same type name.
// The file's `import CoreGraphics` is removed together with the struct (nothing else in it uses `CGColor`).
```

### 3.5 `minimail/Features/Inbox/InboxPlaceholders.swift` (modify)

```swift
// DELETED by this module:
//     /// Replaced by module 12 (`minimail/Features/Labels/LabelsScreen.swift`).
//     struct LabelsScreen: View { init(onSelect: @escaping (InboxScope) -> Void); var body: some View }
// The file keeps `ComposeScreen` (until 11) and `SettingsScreen` (until 13, which deletes the file).
```

### 3.6 Symbols consumed from dependencies (exact list)

| Module | Symbols |
|---|---|
| 01 | `AppEnvironment` (`db`, `syncStatus`, `sync`, `isTesting`, `theme`, `settings`), `ThemeTokens` (`text`, `secondaryText`, `background`, `chipBackground`, `accent`), `ThemeTokensReader`, `ThemeStore`, `SettingsStore`, `Log.ui` |
| 06 | `LabelRecord` (`id`, `name`, `type`, `isUser`, `labelListVisibility`, `textColor`, `backgroundColor`, `threadsUnread`, `threadsTotal`, `countsFetchedAt`, `sortOrder`, `viewFetchedAt`, `viewNextPageToken`), `Queries.labelsForSheet(_:)`, `Queries.inboxUnreadThreadCount(_:)`, `Queries.todayThreadCount(_:_:)`, `SyncStateRepository.get(_:_:)`, `SyncKey.lastLabelCountsAt`, `DayBoundary.today(now:timeZone:)`, `LabelRepository.{replaceAll,updateCounts,markViewFetched}` (tests only), `TestDatabase.{seedLabels,sampleLabels,seed,seedMany,parsed}` (tests only), `InvariantChecks` (tests only) |
| 07 | `SyncEngine.run(_:)`, `SyncReason.labelOpened(_:)`, `SyncReason.loadOlderLabel(_:)` (contract tests), `SyncEngine.refreshLabelCounts(force:)`, `SyncEngine.labelCountsStaleness`, `SyncEngine.labelViewMaxAge` (contract tests), `SyncStatus` (`phase`, `isOffline`), `SyncStatus.Phase.initialSync`, `SyncHarness`/`BatchStub`/`JSONFixtures`/`FixedTokenProvider` (tests only, `minimailTests/Sync/SyncTestSupport.swift`) |
| 09 | `InboxScope` (`.inbox`, `.today`, `.label(id:)`), `ThreadChip`, the `LabelsScreen(onSelect:)` signature, `InboxModel` (contract test only: `olderReason`, `setScope`, `hasOlder`) |
| 05 | `StubURLProtocol` (tests only) |
| 03 | `GmailLabel`, `GmailLabelColor` (tests only, through `TestDatabase.sampleLabels` and inline JSON) |

---

## 4. Behaviour

### 4.1 Model creation and the first frame

```
LabelsScreen.body, first evaluation (model == nil):
    NavigationStack { themeTokens.background.ignoresSafeArea() }
    .onAppear { if model == nil { model = LabelsModel(env: env) } }

LabelsModel.init(env:clock:timeZone:):
 1. store env, clock, timeZone
 2. day = DayBoundary.today(now: clock(), timeZone: timeZone)          // fixed for this presentation (§4.10)
 3. start()                                                            // synchronous first value

LabelsScreen.body, second evaluation (model != nil):
    NavigationStack { LabelsListView(model: model, onSelect: onSelect) … }
```

Timing budget: one `.immediate` read on the main thread — `labelsForSheet` (≤ ~100 rows, one indexed scan of a table that holds one row per Gmail label), two `COUNT(*)` over partial indexes (`thread_inbox_unread`, `thread_inbox_today`) and one `syncState` primary-key lookup: together well under 1 ms on the 5,000-message seed of 06 §7.2. The sheet therefore renders its final content in its presentation animation's first frame; no spinner, no placeholder rows.

### 4.2 Observation

```
start():
 1. cancellable?.cancel()
 2. let day = self.day                                   // captured by value
 3. cancellable = ValueObservation
        .trackingConstantRegion { db in
            LabelsAux(labels: try Queries.labelsForSheet(db),
                      inboxUnread: try Queries.inboxUnreadThreadCount(db),
                      today: try Queries.todayThreadCount(db, day),
                      lastLabelCountsAt: try SyncStateRepository.get(db, .lastLabelCountsAt).flatMap(Int64.init))
        }
        .removeDuplicates()
        .start(in: env.db,
               scheduling: .immediate,
               onError:  { [weak self] e   in MainActor.assumeIsolated { self?.observationFailed(e) } },
               onChange: { [weak self] aux in MainActor.assumeIsolated { self?.apply(aux) } })
```

- `trackingConstantRegion` is valid: the four statements are fixed strings over `label`, `thread` and `syncState` for the lifetime of the observation (the `day` arguments are values, not new SQL) `[ios-platform §2.6]`.
- `.immediate` delivers the first value synchronously on the calling (main) thread and later values on the main dispatch queue — hence `MainActor.assumeIsolated` inside the `@Sendable` callbacks (identical to 09 §4.2; the same fallback of 09 §10 A5 applies if `assumeIsolated` is rejected: hop with `Task { @MainActor in … }` and accept one extra frame).
- `.removeDuplicates()` matters here: 07's outbox acks and delta syncs write `message`/`thread` rows constantly; only writes that change a count, a label row or `lastLabelCountsAt` may re-render the sheet.
- The observation is cancelled and restarted only by `refresh()` after an observation error, and cancelled by `stop()`.

```
apply(aux):
 1. inboxUnreadCount = aux.inboxUnread; todayCount = aux.today
 2. mailboxRows = LabelsModel.mailboxRows(inboxUnread: aux.inboxUnread, today: aux.today)
 3. labelRows   = aux.labels.filter { !LabelsModel.hiddenLabelIds.contains($0.id) }.map(LabelsModel.row(for:))
 4. countsFetchedAt = aux.lastLabelCountsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
 5. observationError = nil
```

### 4.3 Which labels are listed

`Queries.labelsForSheet` (06 §4.9) already implements the visibility rules of `[gmail-api §11]`:

```sql
SELECT * FROM label
WHERE id IN ('INBOX','STARRED','IMPORTANT','SENT')
   OR (type = 'user' AND (labelListVisibility IS NULL
                          OR labelListVisibility = 'labelShow'
                          OR (labelListVisibility = 'labelShowIfUnread' AND (threadsUnread IS NULL OR threadsUnread > 0))))
ORDER BY sortOrder, name COLLATE NOCASE
```

This module applies exactly one further rule: rows whose id is in `LabelsModel.hiddenLabelIds` (`{"INBOX"}`) are dropped, because the Mailboxes section already shows Inbox with the **local** unread count and the Labels section's footer says its counts come from Gmail (architecture §4.6; DEVIATION D1, §10). The resulting order for the standard Workspace account is:

```
STARRED · IMPORTANT · SENT · <user labels by name, case-insensitive>
```

`sortOrder` values are written by `LabelRepository.replaceAll` (06 §5.4): INBOX 0, STARRED 10, IMPORTANT 20, SENT 30, other system 500, user 1000. Other system labels (`UNREAD`, `TRASH`, `SPAM`, `CHAT`, `CATEGORY_*`, `DRAFT`) never reach the sheet — the SQL excludes them.

### 4.4 Row titles and icons

| Row | `id` | `title` | `symbol` | `colorHex` | `scope` |
|---|---|---|---|---|---|
| Inbox | `mailbox.inbox` | `Inbox` | `tray` | — | `.inbox` |
| Today | `mailbox.today` | `Today` | `sun.max` | — | `.today` |
| System label `STARRED` | `STARRED` | `Starred` | `star` | — | `.label(id: "STARRED")` |
| System label `IMPORTANT` | `IMPORTANT` | `Important` | `bookmark` | — | `.label(id: "IMPORTANT")` |
| System label `SENT` | `SENT` | `Sent` | `paperplane` | — | `.label(id: "SENT")` |
| Other system label | its id | `systemDisplayNames[id] ?? name` | `systemSymbols[id] ?? "tag"` | — | `.label(id:)` |
| User label with `backgroundColor` | its id | `name` verbatim (`Customers/ACME`) | `nil` → `LabelColorDot` | `backgroundColor` | `.label(id:)` |
| User label without colour | its id | `name` verbatim | `tag` | — | `.label(id:)` |

`displayName(for:)` uses `systemDisplayNames` only when `label.type == "system"`; a user label that happens to be called `"SENT"` keeps its own name. Nested Gmail labels keep their full `parent/child` name, matching the navigation title module 09 shows for a label scope (`labels[id]?.name ?? id`, 09 §4.4) — see §10 A3 for the one cosmetic inconsistency this leaves.

### 4.5 Counts

| Row | Source | Rule |
|---|---|---|
| Inbox | `Queries.inboxUnreadThreadCount` (local SQL over `thread`) | `countText = countText(inboxUnread)`, accessibility value `"<n> unread"` |
| Today | `Queries.todayThreadCount(day)` (local SQL) | `countText = countText(today)`, accessibility value `"<n> today"` |
| Every label | `LabelRecord.threadsUnread` (server, written by `LabelRepository.updateCounts` from `labels.get` `[gmail-api §11]`) | `countText = countText(threadsUnread)`, accessibility value `"<n> unread"` |

`countText(_:)`: `nil` for `nil` and for values `<= 0`; `"999+"` for values `> 999`; otherwise `String(count)`. Local counts reflect optimistic outbox state instantly (architecture §4.6, D21); server counts change only when `refreshLabelCounts` runs, which is why the footer names their origin and age.

### 4.6 Empty / loading / error states

```
emptyState:
    guard labelRows.isEmpty else { return nil }
    if observationError != nil                       → .unavailable
    else if env.syncStatus.phase == .initialSync     → .initialSync
    else                                             → .noLabels
```

| State | Rendering (§6.5) |
|---|---|
| `.initialSync` | `ProgressView("Loading labels…")`, `.progressViewStyle(.circular)`, centred |
| `.noLabels` | `ContentUnavailableView("No labels", systemImage: "tag", description: Text("Labels appear after the first sync."))` (architecture §8.2: "'No labels' before the first sync") |
| `.unavailable` | `ContentUnavailableView("Labels unavailable", systemImage: "exclamationmark.triangle", description: Text("Pull down to try again."))` |

The Mailboxes section is always rendered (its two rows never depend on the `label` table), so the sheet is never fully blank and pull-to-refresh always has a target. A failing observation with rows already loaded keeps the stale rows visible and only changes the footer (§4.9) — never an alert, never a blocking overlay (architecture §8.2).

### 4.7 Sheet-open staleness check (architecture §4.6)

```
appeared():
 1. guard !didCheckStaleness else { return }
 2. didCheckStaleness = true
 3. let at = countsFetchedAt                                    // from the .immediate first value, so never a race
 4. if at == nil || clock().timeIntervalSince(at!) >= Self.countsStaleness { await refreshCounts() }

refreshCounts():
 1. isRefreshing = true
 2. countsRefreshes += 1
 3. await env.sync.refreshLabelCounts(force: true)              // never throws (07 §3.2)
 4. isRefreshing = false
```

- `force: true` is correct even though the model already decided the counts are stale: 07's own throttle uses the same `lastLabelCountsAt` value, and between the model's read and the engine's read another run may have refreshed it — the user-visible promise ("the sheet I just opened shows current counts") wins. Architecture §4.6: "Also called with `force: true` when the Labels sheet opens and counts are older than 5 min."
- Fresh counts (< 5 min) cost **zero** requests, which is the point of the throttle (D21).
- Signed-out / `needsReauth`: `refreshLabelCounts` returns immediately (07 §4.4.7 guards on `auth.state`), so `isRefreshing` flips back within one turn and the cached counts stay on screen.
- The check runs once per presentation because the model is created per presentation; re-opening the sheet six minutes later checks again.

### 4.8 Selection

```
select(scope):
 1. lastSelected = scope
 2. if case .label(let id) = scope:
        openedLabelIds.append(id)
        Log.ui.debug("labels.select \(id, privacy: .public)")
        Task { await env.sync.run(.labelOpened(id)) }           // fire and forget; single-flight, never throws
```

`LabelsScreen`'s row button runs `model.select(row.scope)` and then `onSelect(row.scope)` in the same main-actor turn. The presenter (09 §4.8) does `model.setScope(scope); model.activeSheet = nil`, which switches the inbox scope in place and dismisses the sheet. This screen never calls `dismiss()` on selection (09's placeholder contract); the "Done" button is the only self-dismissal.

What `.labelOpened(id)` does in 07 (§4.4.5), reproduced here because this module's tests assert it:

```
run(.labelOpened(id)) → hydrateLabelViewIfStale(id) → syncCore(force: false)

hydrateLabelViewIfStale(id):
    label = LabelRecord.fetchOne(id)                                    // unknown id → return
    if let at = label.viewFetchedAt, (now − at) < labelViewMaxAge (24 h) { return }
    p = gmail.listMessages(labelIds: [id], q: nil, maxResults: 50, pageToken: nil)
    hydrateMetadata(p.messages.ids, generation)                          // 25-part batches
    LabelRepository.markViewFetched(id, p.nextPageToken, now)
```

Consequences the sheet relies on: the first tap on a label fills `thread_label` for that label so `Queries.threads(.label(id:))` (architecture §8.6) has rows; the second tap within 24 h issues no request; `label.viewNextPageToken` becomes the paging token module 09 uses for "load older" (§4.12). Selecting `.inbox` or `.today` issues no request at all (the inbox view is hydrated by the normal sync path).

`SENT`, `STARRED` and `IMPORTANT` behave exactly like user labels here: before the first selection only messages that happened to be cached for another reason carry them, afterwards the newest 50 messages of the label are cached (architecture §4.3 `HydrationPolicy`, §4.4).

### 4.9 Footer (architecture §8.2 "footer 'Counts from Gmail'")

```
footer(countsFetchedAt:now:isOffline:isRefreshing:):
    if isRefreshing                      → "Updating counts from Gmail…"
    if isOffline                         → "Counts from Gmail · offline"
    guard let at = countsFetchedAt else  → "Counts from Gmail · not loaded yet"
    let s = max(0, now.timeIntervalSince(at))
    if s <  60                           → "Counts from Gmail · updated just now"
    if s <  3600                         → "Counts from Gmail · updated \(Int(s / 60)) min ago"
    if s <  86_400                       → "Counts from Gmail · updated \(Int(s / 3600)) h ago"
    else                                 → "Counts from Gmail · updated \(Int(s / 86_400)) d ago"
```

`footerText` is `footer(countsFetchedAt: countsFetchedAt, now: clock(), isOffline: env.syncStatus.isOffline, isRefreshing: isRefreshing)`. Reading `env.syncStatus.isOffline` inside a computed property makes the footer re-render when 07 flips the flag (`SyncStatus` is `@Observable`). The footer is attached to the **Labels** section only; the Mailboxes section has none, which is the visual cue that its counts are local (architecture §4.6, D21).

### 4.10 Day boundary

`day` is computed once in `init` from `clock()` and `timeZone`. The sheet is a short-lived modal; there is no `NSCalendarDayChanged` / `NSSystemTimeZoneDidChange` wiring here (09 owns that for the list, §4.9 of 09). A sheet left open across midnight shows a Today count for the day it was opened on; re-opening it recomputes. Assumption A2 (§10).

### 4.11 Error handling

| Failure | Handling |
|---|---|
| `ValueObservation` start or tick throws (`DatabaseError`, e.g. `SQLITE_AUTH` before first unlock) | `observationFailed(e)`: `Log.ui.error("labels observation failed: \(String(describing: e), privacy: .public)")`, `observationError = String(describing: e)`; rows keep their last values; `emptyState == .unavailable` when there were none |
| `refresh()` while the observation is broken | restarts it first (`start()`), then refreshes counts; a successful restart clears `observationError` through `apply` |
| `refreshLabelCounts` network failure | never thrown to this module (07 catches `GmailError` and writes `SyncStatus.lastError` / `isOffline`); the footer shows "· offline" when `isOffline`, otherwise the stale age |
| `sync.run(.labelOpened(id))` failure | never thrown (`run` is `async` and non-throwing); a failed hydration leaves `viewFetchedAt == nil`, so the next selection retries |
| Selecting a label whose row vanished between render and tap (label deleted server-side) | `run(.labelOpened(id))` finds no row and returns; the inbox shows `.noMessages` for that scope; the next `refreshLabelCounts` removes the row through `LabelRepository.replaceAll` |

No error state in this module is blocking, modal, or throwing. `LabelsModel` has no `throws` API.

### 4.12 Paging hook for the label scope

This module owns the *wiring*, not the paging code (09 §4.5 owns the latter). The chain, end to end:

1. `select(.label(id:))` → 09's `InboxModel.setScope(.label(id:))` → `query.scope == .label(id: id)` and `olderReason == .loadOlderLabel(id)`.
2. `recomputeHasOlder` sets `hasOlder = labels[id]?.viewNextPageToken != nil` (09 §4.3), where `labels` is `Queries.labelsById`.
3. `.labelOpened(id)` (fired in `select`) writes that token through `LabelRepository.markViewFetched` (07 §4.4.5), so `hasOlder` becomes `true` one observation tick later without any polling.
4. Scrolling to the last row calls `rowAppeared` → `sync.run(.loadOlderLabel(id))` → next 50 messages of the label + a new token (or `nil`, which hides "load older").

§7.3 verifies steps 3 and 4 against the real `SyncEngine`; §7.1 verifies step 1's payload.

### 4.13 Concurrency and isolation

- `LabelsModel`, `LabelRow` construction, every view: main actor (project default). `LabelRow`, `LabelsEmptyState` and `LabelsAux` are `nonisolated Sendable` value types because they cross into the GRDB `@Sendable` fetch closure.
- The only `Task`s this module creates are (a) the fire-and-forget `sync.run(.labelOpened:)` in `select`, and (b) the implicit tasks of `.task`/`.refreshable`. No detached tasks, no timers, no `DispatchQueue`.
- No `DatabasePool.write` anywhere in this module — it never writes the database.
- `stop()` is idempotent and safe to call from `onDisappear` and again from a test's `tearDown`.

### 4.14 Performance constraints (architecture §12.1, §12.3)

| Constraint | How it is met |
|---|---|
| Sheet open → content painted in the presentation animation | one `.immediate` observation, no network before the first frame, all strings precomputed in `apply` |
| No work per frame | `LabelRowView.body` maps `String`s to `Text`; colour parsing happens once per row build (`LabelChip.color(hex:)` on ≤ ~100 rows) |
| No speculative network | counts are refreshed only when stale (5 min) or on an explicit pull; `.labelOpened` hydrates at most once per 24 h per label |
| Quota | sheet open ≤ 1 + 60 units (`labels.list` + one batched `labels.get` round, cap 60 labels, 07 §4.4.7); label selection ≤ 5 + 20 × n units for at most 50 new messages |
| Battery | no timers, no observers besides the one `ValueObservation`; the model dies with the sheet |

---

## 5. Data

This module defines no table, no migration, no `Info.plist` key, no `UserDefaults` key and writes nothing. It is a pure projection of module 06's `label`, `thread` and `syncState` tables.

### 5.1 Values read

| Value | Source | Format / example |
|---|---|---|
| label rows | `Queries.labelsForSheet` | `LabelRecord(id: "Label_12", name: "Customers/ACME", type: "user", labelListVisibility: "labelShow", messageListVisibility: "show", textColor: "#ffffff", backgroundColor: "#4a86e8", messagesUnread: 3, threadsUnread: 2, threadsTotal: 44, countsFetchedAt: 1_757_500_000_000, sortOrder: 1000, viewFetchedAt: nil, viewNextPageToken: nil)` |
| inbox unread | `Queries.inboxUnreadThreadCount` | `Int`, e.g. `12` |
| today count | `Queries.todayThreadCount(day)` | `Int`, e.g. `5` |
| counts timestamp | `SyncStateRepository.get(db, .lastLabelCountsAt)` | decimal epoch-ms string, e.g. `"1757500000000"` → `Date(timeIntervalSince1970: 1_757_500_000)` |
| offline flag | `env.syncStatus.isOffline` | `Bool` |
| sync phase | `env.syncStatus.phase` | `.idle` / `.syncing` / `.initialSync` |

### 5.2 Constants

| Name | Value |
|---|---|
| `LabelsModel.countsStaleness` | `300` s (= `SyncEngine.labelCountsStaleness`) |
| `LabelsModel.hiddenLabelIds` | `["INBOX"]` |
| `LabelsModel.maxDisplayedCount` | `999` |
| `LabelColorDot.diameter` | `10` pt |
| `LabelsModel.systemDisplayNames` | `["INBOX": "Inbox", "STARRED": "Starred", "IMPORTANT": "Important", "SENT": "Sent", "DRAFT": "Drafts", "SPAM": "Spam", "TRASH": "Trash"]` |
| `LabelsModel.systemSymbols` | `["INBOX": "tray", "STARRED": "star", "IMPORTANT": "bookmark", "SENT": "paperplane", "DRAFT": "doc", "SPAM": "xmark.bin", "TRASH": "trash"]` |

### 5.3 Strings (English literals; `SWIFT_EMIT_LOC_STRINGS = YES` collects them, 01 §1.4)

| Where | Text |
|---|---|
| navigation title | `Labels` |
| toolbar | `Done` |
| section headers | `Mailboxes` · `Labels` |
| mailbox rows | `Inbox` · `Today` |
| system label titles | `Starred` · `Important` · `Sent` · `Drafts` · `Spam` · `Trash` |
| footer, refreshing | `Updating counts from Gmail…` (U+2026) |
| footer, offline | `Counts from Gmail · offline` (U+00B7) |
| footer, never fetched | `Counts from Gmail · not loaded yet` |
| footer, fresh | `Counts from Gmail · updated just now` |
| footer, minutes / hours / days | `Counts from Gmail · updated 3 min ago` · `Counts from Gmail · updated 2 h ago` · `Counts from Gmail · updated 4 d ago` |
| empty, initial sync | `Loading labels…` (U+2026) |
| empty, no labels | `No labels` / `Labels appear after the first sync.` |
| empty, unavailable | `Labels unavailable` / `Pull down to try again.` |
| count overflow | `999+` |
| accessibility values | `12 unread` · `5 today` |

### 5.4 SF Symbols

| Use | Symbol |
|---|---|
| Inbox mailbox row | `tray` |
| Today mailbox row | `sun.max` |
| `STARRED` / `IMPORTANT` / `SENT` | `star` / `bookmark` / `paperplane` |
| `DRAFT` / `SPAM` / `TRASH` (defensive; not listed by `labelsForSheet`) | `doc` / `xmark.bin` / `trash` |
| user label without colour, any other label | `tag` |
| empty state: no labels / unavailable | `tag` / `exclamationmark.triangle` |

User labels with a `backgroundColor` render `LabelColorDot` instead of a symbol.

### 5.5 Accessibility identifiers (used by §7.2 hosting tests and 14's device checklist)

`labels.list`, `labels.row.mailbox.inbox`, `labels.row.mailbox.today`, `labels.row.<labelId>` (e.g. `labels.row.Label_12`), `labels.footer`, `labels.empty`, `labels.done`.

### 5.6 Theme tokens used (01 §3.6; no raw colours — enforced by `make lint`)

| Token | Where |
|---|---|
| `background` | pre-model placeholder behind the `NavigationStack` |
| `text` | row titles, chip text fallback |
| `secondaryText` | leading symbols, trailing counts, footer text |
| `chipBackground` | `LabelColorDot` fallback fill, chip capsule fallback |
| `accent` | inherited tint of the "Done" button (set by `RootView`) |

Gmail label colours (`LabelRecord.textColor` / `.backgroundColor`, `"#rrggbb"` strings written by 06 from `GmailLabelColor` `[gmail-api §11]`) are used unchanged in both appearances (09 §10 A9).

### 5.7 Codable / persisted shapes

None. `LabelRow`, `LabelsEmptyState` and `LabelsAux` are in-memory only; this module writes no `UserDefaults` key, no file and no database row.

---

## 6. UI

### 6.1 View hierarchy

```
LabelsScreen                                   @State model: LabelsModel?
                                               @Environment(AppEnvironment.self) env
                                               @Environment(\.dismiss) dismiss
                                               @ThemeTokensReader themeTokens
└─ NavigationStack
   └─ Group {
        if let model { LabelsListView(model: model, onSelect: onSelect) }
        else         { themeTokens.background.ignoresSafeArea() }
      }
      .navigationTitle("Labels")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
              Button("Done") { dismiss() }.accessibilityIdentifier("labels.done")
          }
      }
   .onAppear    { if model == nil { model = LabelsModel(env: env) } }
   .task        { if model == nil { model = LabelsModel(env: env) }; await model?.appeared() }
   .onDisappear { model?.stop() }

LabelsListView (model, onSelect)
└─ List {
     Section("Mailboxes") { ForEach(model.mailboxRows) { row in rowButton(row) } }
     if let empty = model.emptyState {
         Section("Labels") { LabelsEmptyView(state: empty) }
     } else {
         Section { ForEach(model.labelRows) { row in rowButton(row) } }
             header: { Text("Labels") }
             footer: { Text(model.footerText).accessibilityIdentifier("labels.footer") }
     }
   }
   .listStyle(.insetGrouped)
   .accessibilityIdentifier("labels.list")
   .refreshable { await model.refresh() }
   .background(themeTokens.background)
```

`.onAppear` and `.task` both create the model so the first frame has one regardless of which SwiftUI calls first; the `if model == nil` guard makes the second call a no-op (09 §4.1 uses the same pattern for the list).

### 6.2 Row button

```swift
@ViewBuilder private func rowButton(_ row: LabelRow) -> some View {
    Button {
        model.select(row.scope)          // 07 hydration trigger for .label(id:)
        onSelect(row.scope)              // presenter changes scope + dismisses (09 §4.8)
    } label: {
        LabelRowView(row: row)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("labels.row.\(row.id)")
}
```

No haptic is fired here: module 09's `setScope` increments `filterChangeId`, which drives `.sensoryFeedback(.selection, …)` on the inbox (09 §6.1). Firing one here as well would double it.

### 6.3 `LabelRowView`

```swift
HStack(spacing: 12) {
    ZStack {                                                     // fixed 20 pt leading gutter → titles align
        if let symbol = row.symbol {
            Image(systemName: symbol).foregroundStyle(themeTokens.secondaryText)
        } else {
            LabelColorDot(colorHex: row.colorHex)
        }
    }
    .frame(width: 20, height: 20)

    Text(row.title).font(.body).foregroundStyle(themeTokens.text).lineLimit(1).truncationMode(.middle)

    Spacer(minLength: 8)

    if let count = row.countText {
        Text(count).font(.subheadline).monospacedDigit().foregroundStyle(themeTokens.secondaryText)
    }
}
.contentShape(Rectangle())
.accessibilityElement(children: .ignore)
.accessibilityLabel(row.accessibilityLabel)
.accessibilityValue(row.accessibilityValue ?? "")
.accessibilityAddTraits(.isButton)
```

`truncationMode(.middle)` keeps the leaf of a nested label visible (`Customers/…/ACME`). System text styles only; Dynamic Type is honoured by construction (no fixed font sizes, no fixed row heights — only the 20 pt icon gutter and the 10 pt dot are fixed, both smaller than the smallest body line at any content size).

### 6.4 State → rendering matrix

| Model state | Rendering |
|---|---|
| `labelRows` non-empty | Mailboxes section (2 rows) + Labels section (n rows) + footer |
| `labelRows` empty, `emptyState == .initialSync` | Mailboxes section + Labels section containing `ProgressView("Loading labels…")` |
| `labelRows` empty, `emptyState == .noLabels` | Mailboxes section + `ContentUnavailableView("No labels", …)` (identifier `labels.empty`) |
| `labelRows` empty, `emptyState == .unavailable` | Mailboxes section + `ContentUnavailableView("Labels unavailable", …)` (identifier `labels.empty`) |
| `isRefreshing == true` | system pull-to-refresh spinner + footer "Updating counts from Gmail…" |
| `env.syncStatus.isOffline == true` | footer "Counts from Gmail · offline"; rows unchanged (cached counts stay) |
| `countsFetchedAt == nil` | footer "Counts from Gmail · not loaded yet" |
| `inboxUnreadCount == 0` | Inbox row without a trailing number |
| `label.threadsUnread == nil` (never fetched) | label row without a trailing number |

### 6.5 User action → effect

| Action | Effect |
|---|---|
| Tap "Inbox" | `select(.inbox)` (no network) → `onSelect(.inbox)` → 09 sets scope `.inbox`, dismisses |
| Tap "Today" | `select(.today)` (no network) → `onSelect(.today)` → 09 sets scope `.today`, dismisses |
| Tap a label row | `select(.label(id:))` → `Task { sync.run(.labelOpened(id)) }` → `onSelect(.label(id:))` → 09 sets the label scope, dismisses; the list fills as hydration commits |
| Pull down | `model.refresh()` → `refreshLabelCounts(force: true)`; footer switches to "Updating…" and back |
| Tap "Done" | `dismiss()`; no scope change, no network |
| Swipe the sheet down | SwiftUI clears 09's `activeSheet` binding; `onDisappear` → `model.stop()` |
| VoiceOver swipe over a row | reads "`<title>`, `<n> unread`, Button" |

### 6.6 Navigation

The sheet is presented by 09 (`.sheet(item: $model.activeSheet)`, case `.labels`) and inherits `AppEnvironment`, `ThemeStore` and `SettingsStore` from the window environment. It pushes nothing and presents nothing; its own `NavigationStack` exists only to own the title bar and the "Done" button. Scope switching never pushes (architecture §8.1: "Filter changes replace the observation in place").

---

## 7. Tests

Every test in this module is an **app test** run on the simulator with `xcodebuild` (`make test-app`, or one class with `make test-one T=minimailTests/<Class>`). No `MailCore` package test is added, so `swift test` on Linux is unaffected. Classes are `final class …: XCTestCase` and run on the main actor (01 §7, `[ios-platform §5.6]`).

**Fixtures:** none on disk for §7.1/§7.2 — data is produced in code by module 06's `minimailTests/Support/TestDatabase.swift`. §7.3 uses module 03's Gmail JSON fixtures through 07's `SyncTestSupport.swift` helpers.

| Helper | Origin | Use here |
|---|---|---|
| `TestDatabase.seedLabels(_:_:)` + `TestDatabase.sampleLabels` | 06 §3.17 | the label table: INBOX, UNREAD, STARRED, IMPORTANT, SENT, TRASH, CATEGORY_PROMOTIONS, `Label_12` "Customers/ACME" (colour `#ffffff`/`#4a86e8`), `Label_13` "Hidden" (`labelHide`), `Label_14` "IfUnread" (`labelShowIfUnread`) |
| `TestDatabase.parsed(id:threadId:internalDate:labels:…)` / `.seed(_:_:)` | 06 §3.17 | seeded messages for the local counts |
| `TestDatabase.seedMany(_:count:base:)` | 06 §3.17 | 200 messages / 100 threads, every 5th unread, every 7th `Label_12` |
| `InvariantChecks.assertAll(_:)` | 06 §3.17 | after the contract tests that let 07 write |
| `SyncHarness`, `BatchStub`, `JSONFixtures`, `FixedTokenProvider`, `StubURLProtocol` | 07 §3.6 / 05 | §7.3 only |

**Shared setup** for §7.1 and §7.2:

```swift
var env: AppEnvironment!          // AppEnvironment(testing: true): temporary pool (06), OfflineURLProtocol (05 D8),
                                  // auth .signedOut, isolated UserDefaults suite
var model: LabelsModel!
let seedNow: Int64 = 1_757_500_000_000          // 2025-09-10 10:26:40 UTC
let fixed = Date(timeIntervalSince1970: 1_757_500_000)
let berlin = TimeZone(identifier: "Europe/Berlin")!

override func setUp() async throws { env = AppEnvironment(testing: true) }
override func tearDown() async throws { model?.stop(); model = nil; env = nil }

/// Polls every 20 ms until `cond()` or `timeout`; XCTFail on timeout (09 §7).
func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async
```

Because the test host answers every request with `GmailError.offline` and `auth.state == .signedOut`, `SyncEngine.refreshLabelCounts` and `run(.labelOpened:)` return without network work — §7.1 therefore asserts this module's decisions (`countsRefreshes`, `openedLabelIds`), and §7.3 asserts 07's behaviour against a scripted stub.

### 7.1 `minimailTests/Labels/LabelsModelTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testImmediateRowsOnInit` | `try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)`; `model = LabelsModel(env: env, clock: { fixed }, timeZone: berlin)` | synchronously after `init`: `model.labelRows.map(\.id) == ["STARRED","IMPORTANT","SENT","Label_12","Label_14"]` (INBOX filtered, `Label_13` hidden by `labelHide`, `TRASH`/`CATEGORY_PROMOTIONS`/`UNREAD` excluded by `labelsForSheet`; `Label_14` is present because `seedLabels` goes through `LabelRepository.replaceAll`, which leaves `threadsUnread` NULL, and the `labelShowIfUnread` rule shows NULL — if 06's helper is ever changed to write counts as well, drop `"Label_14"` from this expectation and from `testShowIfUnreadRuleFollowsQueries`'s starting state); `model.mailboxRows.map(\.id) == ["mailbox.inbox","mailbox.today"]`; `model.emptyState == nil`; `model.observationError == nil` |
| `testInboxNeverAppearsTwice` | as above | `model.labelRows.contains { $0.id == "INBOX" } == false`; `LabelsModel.hiddenLabelIds == ["INBOX"]`; `model.mailboxRows[0].scope == .inbox` |
| `testRowTitlesAndIcons` | as above | `row("STARRED").title == "Starred"`, `.symbol == "star"`, `.colorHex == nil`; `row("SENT").title == "Sent"`, `.symbol == "paperplane"`; `row("Label_12").title == "Customers/ACME"`, `.symbol == nil`, `.colorHex == "#4a86e8"`; `row("Label_14").title == "IfUnread"`, `.symbol == "tag"`, `.colorHex == nil`; every label row has `scope == .label(id: $0.id)` |
| `testLocalMailboxCounts` | `try TestDatabase.seedMany(env.db, count: 200)`; model | `model.inboxUnreadCount == (try env.db.read { try Queries.inboxUnreadThreadCount($0) })`; `model.mailboxRows[0].countText == String(model.inboxUnreadCount)`; `model.mailboxRows[0].accessibilityValue == "\(model.inboxUnreadCount) unread"`; `model.todayCount == 0`; `model.mailboxRows[1].countText == nil`; `model.mailboxRows[1].accessibilityValue == nil` |
| `testTodayCountObserved` | `seedMany(count: 40)`; model with `clock: { Date() }` | seed one extra INBOX message with `internalDate = Int64(Date().timeIntervalSince1970 * 1000)` → `await waitUntil { model.todayCount == 1 }`; `model.mailboxRows[1].countText == "1"`; `model.mailboxRows[1].accessibilityValue == "1 today"` |
| `testServerUnreadCountsOnLabelRows` | `seedLabels(sampleLabels)`; model | `try await env.db.write { var l = try LabelRecord.fetchOne($0, key: "Label_12")!; l.threadsUnread = 3; try l.update($0) }` → `await waitUntil { model.labelRows.first { $0.id == "Label_12" }?.countText == "3" }`; set `threadsUnread = 0` → `await waitUntil { … == nil }`; set `1200` → `await waitUntil { … == "999+" }` |
| `testLabelRenameUpdatesRow` | `seedLabels(sampleLabels)`; model | `try await env.db.write { var l = try LabelRecord.fetchOne($0, key: "Label_12")!; l.name = "Renamed"; try l.update($0) }` → `await waitUntil { model.labelRows.first { $0.id == "Label_12" }?.title == "Renamed" }` |
| `testLabelDeletionRemovesRow` | `seedLabels(sampleLabels)`; model | `try await env.db.write { _ = try LabelRecord.deleteOne($0, key: "Label_14") }` → `await waitUntil { !model.labelRows.contains { $0.id == "Label_14" } }` |
| `testShowIfUnreadRuleFollowsQueries` | `seedLabels(sampleLabels)`; model | set `Label_14.threadsUnread = 0` → `await waitUntil { !model.labelRows.contains { $0.id == "Label_14" } }`; set `2` → `await waitUntil { model.labelRows.contains { $0.id == "Label_14" } }` (mirrors 06 `testLabelsForSheet`) |
| `testEmptyStates` | no `seedLabels`; model | `model.labelRows.isEmpty`; `model.emptyState == .noLabels`; `env.syncStatus.phase = .initialSync` → `model.emptyState == .initialSync`; `env.syncStatus.phase = .idle`; `model._simulateObservationError("boom")` → `model.emptyState == .unavailable` |
| `testEmptyStateNilWhenRowsExist` | `seedLabels(sampleLabels)`; model; `env.syncStatus.phase = .initialSync` | `model.emptyState == nil` |
| `testStalenessTriggersRefresh` | `try await env.db.write { try SyncStateRepository.set($0, .lastLabelCountsAt, String(Int64(fixed.timeIntervalSince1970 * 1000) - 400_000)) }`; model with `clock: { fixed }` | `await model.appeared()` → `model.countsRefreshes == 1`; `model.didCheckStaleness == true`; `model.isRefreshing == false` |
| `testFreshCountsSkipRefresh` | `lastLabelCountsAt = fixed − 10 s`; model with `clock: { fixed }` | `await model.appeared()` → `model.countsRefreshes == 0`; `model.didCheckStaleness == true` |
| `testMissingTimestampRefreshes` | no `lastLabelCountsAt`; model | `model.countsFetchedAt == nil`; `await model.appeared()` → `countsRefreshes == 1` |
| `testAppearedChecksOnlyOnce` | `lastLabelCountsAt = fixed − 400 s`; model | `await model.appeared()`; `await model.appeared()` → `countsRefreshes == 1` |
| `testBoundaryExactlyFiveMinutes` | `lastLabelCountsAt = fixed − 300 s`; model with `clock: { fixed }` | `await model.appeared()` → `countsRefreshes == 1` (the comparison is `>=`) |
| `testRefreshAlwaysForces` | `lastLabelCountsAt = fixed − 10 s`; model | `await model.refresh()`; `await model.refresh()` → `countsRefreshes == 2` (pull-to-refresh bypasses the throttle) |
| `testSelectLabelRunsLabelOpened` | `seedLabels(sampleLabels)`; model | `model.select(.label(id: "Label_12"))` → `model.lastSelected == .label(id: "Label_12")`; `await waitUntil { model.openedLabelIds == ["Label_12"] }`; the sheet is not dismissed (nothing to assert beyond `model` still observing: `model.labelRows.isEmpty == false`) |
| `testSelectMailboxDoesNotHydrate` | model | `model.select(.inbox)` → `lastSelected == .inbox`, `openedLabelIds.isEmpty`; `model.select(.today)` → `lastSelected == .today`, `openedLabelIds.isEmpty` |
| `testCountsFetchedAtObserved` | model with `clock: { fixed }` | `footerText == "Counts from Gmail · not loaded yet"`; `try await env.db.write { try SyncStateRepository.set($0, .lastLabelCountsAt, String(Int64(fixed.timeIntervalSince1970 * 1000) - 120_000)) }` → `await waitUntil { model.footerText == "Counts from Gmail · updated 2 min ago" }` |
| `testFooterOffline` | model with `clock: { fixed }`; `lastLabelCountsAt = fixed − 120 s` | `env.syncStatus.isOffline = true` → `model.footerText == "Counts from Gmail · offline"` |
| `testObservationErrorRecovery` | `seedLabels(sampleLabels)`; model; `model._simulateObservationError("boom")` | `model.observationError != nil`; `await model.refresh()` → `model.observationError == nil`; `model.labelRows.map(\.id) == ["STARRED","IMPORTANT","SENT","Label_12","Label_14"]`; `model.countsRefreshes == 1` |
| `testStopCancelsObservation` | `seedLabels(sampleLabels)`; model; `model.stop()` | `try await env.db.write { var l = try LabelRecord.fetchOne($0, key: "Label_12")!; l.name = "After stop"; try l.update($0) }`; after 300 ms `model.labelRows.first { $0.id == "Label_12" }?.title == "Customers/ACME"` |

23 tests. Helper used above: `func row(_ id: String) -> LabelRow { model.labelRows.first { $0.id == id }! }`.

### 7.2 `minimailTests/Labels/LabelsViewsTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testDisplayNamePureFunction` | `LabelRecord` builders | system `"STARRED"` → `"Starred"`; system `"SENT"` → `"Sent"`; system `"CATEGORY_PROMOTIONS"` → `"CATEGORY_PROMOTIONS"` (no entry → name verbatim); user label named `"SENT"` → `"SENT"` (type decides); user `"Customers/ACME"` → `"Customers/ACME"` |
| `testSymbolPureFunction` | — | system `"IMPORTANT"` → `"bookmark"`; system `"TRASH"` → `"trash"`; system unknown → `"tag"`; user with `backgroundColor "#4a86e8"` → `nil`; user without colour → `"tag"` |
| `testCountTextPureFunction` | — | `countText(nil) == nil`; `countText(0) == nil`; `countText(-3) == nil`; `countText(1) == "1"`; `countText(999) == "999"`; `countText(1000) == "999+"` |
| `testRowProjection` | `LabelRecord(id: "Label_12", name: "Customers/ACME", type: "user", …, backgroundColor: "#4a86e8", threadsUnread: 2, …)` | `row.id == "Label_12"`; `.title == "Customers/ACME"`; `.countText == "2"`; `.symbol == nil`; `.colorHex == "#4a86e8"`; `.scope == .label(id: "Label_12")`; `.accessibilityLabel == "Customers/ACME"`; `.accessibilityValue == "2 unread"` |
| `testMailboxRowsProjection` | — | `mailboxRows(inboxUnread: 12, today: 0)` → ids `["mailbox.inbox","mailbox.today"]`, titles `["Inbox","Today"]`, symbols `["tray","sun.max"]`, countTexts `["12", nil]`, a11y values `["12 unread", nil]`, scopes `[.inbox, .today]` |
| `testFooterPureFunction` | `now = fixed` | `footer(nil, now, false, false) == "Counts from Gmail · not loaded yet"`; `footer(now − 10, now, false, false) == "Counts from Gmail · updated just now"`; `footer(now − 180, …) == "Counts from Gmail · updated 3 min ago"`; `footer(now − 7_200, …) == "Counts from Gmail · updated 2 h ago"`; `footer(now − 4 × 86_400, …) == "Counts from Gmail · updated 4 d ago"`; `footer(now − 10, now, true, false) == "Counts from Gmail · offline"`; `footer(nil, now, true, true) == "Updating counts from Gmail…"`; `footer(now + 60, now, false, false) == "Counts from Gmail · updated just now"` (negative age clamped) |
| `testLabelChipStillParsesHexAfterMove` | — | `LabelChip.color(hex: "#ff0000") != nil`; `"#FF0000"` non-nil; `"#ff000"` → `nil`; `"ff0000"` → `nil`; `"#gg0000"` → `nil`; `nil` → `nil`; the blue component of `UIColor(LabelChip.color(hex: "#0000ff")!)` is `1 ± 0.01` (duplicates 09's `testLabelChipColorParsing` on purpose: it proves the moved file still compiles and behaves) |
| `testLabelColorDotFallback` | `LabelColorDot(colorHex: nil)` and `LabelColorDot(colorHex: "#4a86e8")` | both host inside a `UIHostingController` without crashing; `LabelColorDot.diameter == 10` |
| `testLabelsScreenHostsSeededLabels` | `try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)`; `let vc = UIHostingController(rootView: LabelsScreen(onSelect: { _ in }).environment(env).environment(env.theme).environment(env.settings))`; `vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)`; `vc.view.layoutIfNeeded()`; `RunLoop.main.run(until: Date() + 0.3)` | no crash; `vc.view.subviews.isEmpty == false`; a `UICollectionView`/`UITableView` descendant exists (recursive `subviews` walk — SwiftUI `List` backing); `env.deferredWorkStarted == false` |
| `testLabelsScreenHostsEmptyDatabase` | no seed; same hosting | no crash; hierarchy non-empty (the Mailboxes section always renders) |
| `testLabelsScreenInSheetHosting` | host a tiny presenter view `struct Host: View { @State var shown = true; var body: some View { Color.clear.sheet(isPresented: $shown) { LabelsScreen(onSelect: { _ in }) } } }` with the three `.environment` modifiers; layout + `RunLoop.main.run(until: Date() + 0.5)` | no crash (proves the sheet path resolves `AppEnvironment` from the presenter's environment) |

11 tests.

### 7.3 `minimailTests/Labels/LabelSyncContractTests.swift`

These verify the **07 behaviours this sheet depends on** (modules.md §12: "`SyncEngine.refreshLabelCounts` + `hydrateLabelView` behaviour verification tests"). They use 07's `SyncHarness` (in-memory DB, stubbed `GmailClient` over `StubURLProtocol`, frozen clock, `auth.state == .signedIn`), so they exercise the real engine. Overlap with 07 §7.2 (`testLabelOpenedHydratesOnce`, `testCountsThrottled`) is deliberate: 07 owns the implementation, 12 owns the contract; both suites must stay green.

Shared setup:

```swift
var h: SyncHarness!
override func setUp() async throws { StubURLProtocol.reset(); h = try SyncHarness() ; try h.seedSyncState(historyId: 5000) }
override func tearDown() async throws { StubURLProtocol.reset(); h = nil }

/// labels.list body containing INBOX, STARRED, IMPORTANT, SENT, Label_12 ("Customers/ACME", user, colour) — fixture
/// `labels.list.json` (module 03) unless a test needs a different set.

/// Local copy of §7.1's poller (it is a private method of another test class); used only by `testPagingHandoffToInboxModel`.
func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async
```

| Test function | Setup | Assertions |
|---|---|---|
| `testForceRefreshIgnoresThrottle` | `lastLabelCountsAt = now − 60 s`; `BatchStub.install(routes: [labels.list], parts: BatchStub.responder(labels: ["INBOX": fixture("labels.get.inbox"), "Label_12": fixture("labels.get.user")]))`; `await h.sync.refreshLabelCounts(force: true)` | one `GET …/labels` request and one batch POST; `try h.db.read { try LabelRecord.fetchOne($0, key: "Label_12")?.threadsUnread } == 2`; `syncState.lastLabelCountsAt == String(nowMs)` |
| `testThrottleSkipsWhenFresh` | `lastLabelCountsAt = now − 60 s`; same routes; `await h.sync.refreshLabelCounts(force: false)` | zero requests recorded by `StubURLProtocol`; `BatchStub.batchCount == 0` |
| `testThrottleExpiresAfterFiveMinutes` | `lastLabelCountsAt = now − 60 s`; `h.advance(seconds: 301)`; `await h.sync.refreshLabelCounts(force: false)` | one labels request + one batch; `SyncEngine.labelCountsStaleness == 300` |
| `testCountsBatchSelectionMatchesSheet` | `labels.list` extended inline with a `labelHide` user label `Label_99` and 70 visible user labels; `refreshLabelCounts(force: true)` | batch part paths contain `INBOX`, `STARRED`, `IMPORTANT`, `SENT` and 56 user ids (cap 60); no part for `Label_99`; every id that `Queries.labelsForSheet` returns afterwards (minus `Label_14`-style `labelShowIfUnread` rows with count 0) appears in the part list |
| `testCountsWriteRowsTheSheetReads` | as `testForceRefreshIgnoresThrottle` | `try h.db.read { try Queries.labelsForSheet($0) }.map(\.id)` starts with `["INBOX","STARRED","IMPORTANT","SENT"]`; `LabelRecord.fetchOne("Label_12")!.backgroundColor == "#4a86e8"`; `countsFetchedAt != nil` |
| `testLabelOpenedHydratesOnce` | `LabelRepository.replaceAll` with `Label_12` (`viewFetchedAt` nil); routes: `GET …/messages?labelIds=Label_12&maxResults=50` → `JSONFixtures.messageList(["l1"], nextPageToken: "lp2")`, parts → `JSONFixtures.metadataMessage(id: "l1", thread: "l1", labels: ["Label_12"], …)`, plus history/labels routes for the `syncCore` tail; `await h.sync.run(.labelOpened("Label_12"))` twice | exactly one `messages?labelIds=Label_12` request; `LabelRecord.fetchOne("Label_12")!.viewFetchedAt != nil`; `.viewNextPageToken == "lp2"`; `message l1` exists; `thread_label(Label_12, l1)` exists; `try h.db.read { try Queries.threads(ThreadQuery(scope: .label(id: "Label_12"), unreadOnly: false, limit: 60), now: h.now, timeZone: .current, locale: .init(identifier: "en_US"), labels: try Queries.labelsById($0))($0) }.map(\.id) == ["l1"]`; `h.assertInvariants()` |
| `testLabelOpenedRehydratesAfter24h` | `viewFetchedAt = now − 25 h`; same routes; one `run(.labelOpened("Label_12"))` | one `messages?labelIds=Label_12` request; `viewFetchedAt == nowMs`; `SyncEngine.labelViewMaxAge == 86_400` |
| `testLabelOpenedUnknownLabelIsNoop` | no `Label_77` row; `run(.labelOpened("Label_77"))` | zero `messages?labelIds=Label_77` requests; no crash; `status.lastError == nil` |
| `testLoadOlderLabelUsesViewToken` | `Label_12` with `viewNextPageToken = "lp2"`; route `GET …/messages?labelIds=Label_12&maxResults=50&pageToken=lp2` → `messageList(["l2"], nextPageToken: nil)`, parts → metadata `l2`; `await h.sync.run(.loadOlderLabel("Label_12"))` | the recorded query contains `pageToken=lp2`; `LabelRecord.fetchOne("Label_12")!.viewNextPageToken == nil`; `message l2` exists; no `history` request |
| `testLoadOlderLabelWithoutTokenIsNoop` | `viewNextPageToken = nil`; `run(.loadOlderLabel("Label_12"))` | zero requests |
| `testPagingHandoffToInboxModel` | `h`-independent: `env = AppEnvironment(testing: true)`; `TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)`; `try await env.db.write { try LabelRepository.markViewFetched($0, labelId: "Label_12", nextPageToken: "lp", now: 1_757_500_000_000) }`; `let inbox = InboxModel(env: env, scope: .inbox)`; `let labels = LabelsModel(env: env)`; `labels.select(.label(id: "Label_12"))`; `inbox.setScope(labels.lastSelected!)` | `inbox.query.scope == .label(id: "Label_12")`; `inbox.olderReason == .loadOlderLabel("Label_12")`; `await waitUntil { inbox.hasOlder }`; `labels.openedLabelIds == ["Label_12"]` (this is the §4.12 wiring, asserted without network) |

11 tests. Total for this module: 45.

### 7.4 `minimailTests/Inbox/InboxViewsTests.swift` (modify)

Module 09's two placeholder tests host `LabelsScreen` with no environment; the real screen reads `@Environment(AppEnvironment.self)`, so both must supply it. Exact edits (nothing else in the file changes):

```swift
// testPlaceholderSignatures — the LabelsScreen line becomes:
_ = LabelsScreen(onSelect: { _ in })
hostAndLayout(LabelsScreen(onSelect: { _ in })
    .environment(env).environment(env.theme).environment(env.settings))

// testLabelsPlaceholderCallsOnSelect — renamed body, same name and same contract:
var picked: InboxScope?
hostAndLayout(LabelsScreen(onSelect: { picked = $0 })
    .environment(env).environment(env.theme).environment(env.settings))
XCTAssertNil(picked)                       // hosting alone selects nothing; the closure type is the contract
```

`hostAndLayout` is 09's existing private helper (`UIHostingController` + frame + `layoutIfNeeded`). The test names are unchanged so 09's §9 acceptance list keeps matching.

### 7.5 Running them

```
make test-app                                          # whole app suite
make test-one T=minimailTests/LabelsModelTests
make test-one T=minimailTests/LabelsViewsTests
make test-one T=minimailTests/LabelSyncContractTests
make test-one T=minimailTests/InboxViewsTests          # 09's suite must stay green after the move + edits
```

---

## 8. Tasks

- [ ] **T12.1 Move `LabelChip`, add `LabelColorDot`** — files: `minimail/Features/Labels/LabelChip.swift` (new: `LabelChip` moved verbatim, `LabelChip.color(hex:)`, `LabelColorDot`), `minimail/Features/Inbox/ThreadRowView.swift` (delete the `LabelChip` struct and the now-unused `import CoreGraphics`). Done when `make build` succeeds, `make test-one T=minimailTests/InboxViewsTests` still passes unchanged (`testLabelChipColorParsing`, `testThreadRowAccessibilityLabel`), and `grep -rn "struct LabelChip" minimail | wc -l` prints `1`. Verify: `make build && make test-one T=minimailTests/InboxViewsTests`. (~60 lines)

- [ ] **T12.2 `LabelsModel` pure projection** — file: `minimail/Features/Labels/LabelsModel.swift` (`LabelRow`, `LabelsEmptyState`, the six `nonisolated static` helpers `displayName`, `symbol`, `countText`, `row`, `mailboxRows`, `footer`, plus the constants of §5.2); file: `minimailTests/Labels/LabelsViewsTests.swift` (the six pure tests `testDisplayNamePureFunction`, `testSymbolPureFunction`, `testCountTextPureFunction`, `testRowProjection`, `testMailboxRowsProjection`, `testFooterPureFunction`). Done when those six tests pass. Verify: `make test-one T=minimailTests/LabelsViewsTests`. (~170 lines)

- [ ] **T12.3 `LabelsModel` observation, staleness, selection** — files: `minimail/Features/Labels/LabelsModel.swift` (the `@Observable` class: `init`, `start`, `apply`, `emptyState`, `footerText`, `appeared`, `refresh`, `refreshCounts`, `select`, `stop`, `observationFailed`, `_simulateObservationError`), `minimailTests/Labels/LabelsModelTests.swift` (all 23 tests of §7.1). Done when all 23 pass and no test leaks an observation (`tearDown` calls `stop()`). Verify: `make test-one T=minimailTests/LabelsModelTests`. (~230 lines model + ~300 lines tests)

- [ ] **T12.4 `LabelsScreen` UI and placeholder removal** — files: `minimail/Features/Labels/LabelsScreen.swift` (`LabelsScreen`, `LabelsListView`, `LabelRowView`, `LabelsEmptyView`), `minimail/Features/Inbox/InboxPlaceholders.swift` (delete `struct LabelsScreen`), `minimailTests/Inbox/InboxViewsTests.swift` (the two edits of §7.4), `minimailTests/Labels/LabelsViewsTests.swift` (the five view/hosting tests `testLabelChipStillParsesHexAfterMove`, `testLabelColorDotFallback`, `testLabelsScreenHostsSeededLabels`, `testLabelsScreenHostsEmptyDatabase`, `testLabelsScreenInSheetHosting`). Done when both view suites and 09's suite pass and `grep -rn "struct LabelsScreen" minimail` prints exactly the `Features/Labels/LabelsScreen.swift` line. Verify: `make test-one T=minimailTests/LabelsViewsTests && make test-one T=minimailTests/InboxViewsTests`. (~200 lines)

- [ ] **T12.5 Sync contract tests** — file: `minimailTests/Labels/LabelSyncContractTests.swift` (the 11 tests of §7.3). Done when all 11 pass against the real `SyncEngine` through `SyncHarness` and `h.assertInvariants()` holds in `testLabelOpenedHydratesOnce`. Verify: `make test-one T=minimailTests/LabelSyncContractTests`. (~280 lines)

- [ ] **T12.6 Lint, acceptance sweep and cross-module green** — files: none (fixes only, if the greps fail). Done when every item of §9 holds: `make lint` exits 0 (no raw colour and no SQL under `minimail/Features/Labels`), `make test-app` is green (this module's 45 tests plus 01/04/05/06/07/08/09/10's suites), and `cd Packages/MailCore && swift test` is unaffected. Verify: `make lint && make test-app && (cd Packages/MailCore && swift test)`. (~0–40 lines)

---

## 9. Acceptance criteria

1. **Files exist exactly as listed in §2**: `ls minimail/Features/Labels/` prints `LabelChip.swift  LabelsModel.swift  LabelsScreen.swift`; `grep -c "struct LabelChip" minimail/Features/Inbox/ThreadRowView.swift` prints `0`; `grep -c "struct LabelsScreen" minimail/Features/Inbox/InboxPlaceholders.swift` prints `0`.
2. **Build and full test suite**: `make build && make test-app` exits 0, including this module's 23 + 11 + 11 tests and module 09's unchanged suite.
3. **Package tests untouched**: `cd Packages/MailCore && swift test` exits 0 and reports the same test count as before this module (no package file added).
4. **Lint**: `make lint` exits 0. Specifically `grep -rnE "Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)|\.tint\(\.(blue|indigo|green|red)\)" minimail/Features/Labels` prints nothing, and `grep -rn "SELECT\|INSERT\|UPDATE\|DELETE" minimail/Features/Labels | wc -l` prints `0`.
5. **First frame from cache**: `testImmediateRowsOnInit` asserts the label rows synchronously after `LabelsModel.init` — no `await`, no spinner.
6. **INBOX appears once**: `testInboxNeverAppearsTwice` passes; the sheet shows Inbox only in the Mailboxes section, with the local unread count.
7. **Counts source is honest**: the Labels section footer always names Gmail as the source and its age (`testFooterPureFunction`, `testCountsFetchedAtObserved`, `testFooterOffline`); the Mailboxes section has no footer and uses local SQL (`testLocalMailboxCounts`).
8. **Sheet-open throttle**: counts younger than 5 minutes cost zero requests (`testFreshCountsSkipRefresh`, `testThrottleSkipsWhenFresh`); older or missing counts force one refresh (`testStalenessTriggersRefresh`, `testForceRefreshIgnoresThrottle`); pull-to-refresh always refreshes (`testRefreshAlwaysForces`).
9. **Selection wiring**: selecting a label fires exactly one `sync.run(.labelOpened(id))` and hands `.label(id:)` to `onSelect` (`testSelectLabelRunsLabelOpened`); selecting Inbox/Today fires none (`testSelectMailboxDoesNotHydrate`).
10. **Hydration contract**: a label view is hydrated at most once per 24 h and produces the `thread_label` rows the label scope queries (`testLabelOpenedHydratesOnce`, `testLabelOpenedRehydratesAfter24h`).
11. **Paging hand-off**: after a label selection, module 09's model reports `olderReason == .loadOlderLabel(id)` and picks up `viewNextPageToken` (`testPagingHandoffToInboxModel`, `testLoadOlderLabelUsesViewToken`).
12. **No blocking UI**: the screen contains no `alert`, no `fullScreenCover`, no `ProgressView` overlay other than the `.initialSync` empty state — `grep -rn "\.alert(\|fullScreenCover" minimail/Features/Labels | wc -l` prints `0`.
13. **Manual device step (14's checklist entry, owner's iPhone)**: open the Labels sheet twice within five minutes — the second open shows the same counts and Console shows no `labels` request (`log stream --predicate 'subsystem == "de.newtelco.minimail" AND category == "net"'`); tap a user label — the list switches to that label, and the first tap issues exactly one `messages?labelIds=…` request while a second tap within 24 h issues none; pull down in the sheet — the footer reads "Updating counts from Gmail…" and then "updated just now".
14. **Dark mode / Dynamic Type (manual)**: at `AX3` text size the row titles truncate in the middle and the counts stay visible; in Dark appearance the Gmail label colours are unchanged and every other colour comes from the theme tokens (§5.6).

---

## 10. Open questions & assumptions

### Deviations from architecture.md / modules.md

| # | Point | Kind | Resolution / reason |
|---|---|---|---|
| D1 | modules.md lists the Labels section as "INBOX pinned, STARRED/IMPORTANT/SENT, user labels…", and `Queries.labelsForSheet` returns `INBOX` first; architecture §8.2 also puts Inbox in the Mailboxes section. | DEVIATION | `LabelsModel.hiddenLabelIds = ["INBOX"]` drops the INBOX row from the Labels section. Showing Inbox twice — once with a local count (Mailboxes) and once with a possibly different server count under a footer that says "Counts from Gmail" — would contradict architecture §4.6's rule that Inbox counts are local. One constant reverses the decision. `Queries.labelsForSheet` itself is unchanged (06 keeps INBOX for any other consumer). |
| D2 | Architecture §8.2 says "tap → `onSelect(scope)` (dismiss + scope change)" and modules.md says "selection → `onSelect(.label(id))` + dismiss". | DEVIATION (placement only) | The dismissal happens in module 09's `onSelect` closure (`model.setScope(scope); model.activeSheet = nil`, 09 §4.8), which is the binding owner; this screen must **not** dismiss on selection (09's placeholder doc comment states the contract). Net user-visible behaviour is identical. |
| D3 | Architecture §2.4 / modules.md name `LabelsScreen(onSelect:)` and `LabelsModel` but no row type. | ADDITION | `LabelRow` (precomputed projection), `LabelsEmptyState` and `LabelColorDot` are additive; they exist so `body` performs no formatting (architecture §12.3 "precomputed rows"). |
| D4 | modules.md assigns `LabelChip` to this module; 09 shipped it first inside `Features/Inbox/ThreadRowView.swift` (09 D4). | resolved | The struct moves to `minimail/Features/Labels/LabelChip.swift` unchanged, as 09 D4 explicitly permits. No API change, no test rewrite (09's `testLabelChipColorParsing` keeps passing); §7.2 adds one duplicate assertion to pin the moved file. |
| D5 | modules.md: "`loadOlderLabel` paging hook". | resolved | 09 already implements the paging (`olderReason`, `hasOlder` from `viewNextPageToken`); this module contributes the selection that produces the label scope and the tests of §4.12. No paging code is added here. |
| D6 | 09's `testPlaceholderSignatures` and `testLabelsPlaceholderCallsOnSelect` host `LabelsScreen` without an environment. | DEVIATION (cross-module test edit) | Both hosting calls gain `.environment(env).environment(env.theme).environment(env.settings)` (§7.4). Without the edit they crash once the real screen replaces the placeholder. Test names are unchanged so 09's acceptance list still matches. |

### Assumptions and UNVERIFIED facts

| # | Item | Status | Chosen assumption / fallback |
|---|---|---|---|
| A1 | `AnyDatabaseCancellable` and `ValueObservation.start(in:scheduling:onError:onChange:)` names (GRDB 7.11.1). | UNVERIFIED (architecture §14 #17, `[ios-platform §2.6]`; same as 09 §10 A2) | Use the same spelling module 09 compiled; if it differs, both modules change together in one commit. |
| A2 | A labels sheet left open across midnight or a time-zone change shows a stale Today count. | assumed acceptable | The sheet is a modal opened for seconds; the boundary is recomputed on every presentation. Fallback if it ever matters: reuse 09's `InboxScreen.dayChangeStream()` and call a `dayChanged()` on this model (≈ 8 lines). |
| A3 | The sheet shows "Starred"/"Important"/"Sent" while module 09's navigation title for the same scope shows the raw Gmail name ("STARRED"), because 09 §4.4 defines `title = labels[id]?.name ?? id`. | accepted cosmetic inconsistency | User labels (the common case) are identical in both places. One-line fix if the owner dislikes it, to be applied inside module 09: `case .label(let id): labels[id].map(LabelsModel.displayName(for:)) ?? id`. Not done here because 09's title is specified in its own spec. |
| A4 | `labels.get` counts are thread counts (`threadsUnread`) and are the right number to show next to a label. | verified `[gmail-api §11]` | `threadsUnread` = "The number of unread threads with the label"; the list shows threads, so thread counts match. `messagesUnread` is stored by 06 but not displayed. |
| A5 | User-label colours are present in `labels.list` responses often enough to matter. | UNVERIFIED `[gmail-api §10]` ("in practice `color` is often present … do not rely on it") | Colours are only ever read from the `label` table, which `LabelRepository.updateCounts` fills from `labels.get` (and `replaceAll` never clears a stored colour on a nil, 06 §4). A label whose colour has not arrived yet renders the `tag` symbol; the next count refresh gives it a dot. |
| A6 | `labelListVisibility == "labelShowIfUnread"` with a **server** count decides visibility, so a label the user has unread mail in locally may still be hidden until the next count refresh. | resolved (06 §10 A10) | Accepted: the same rule Gmail's sidebar uses. The 5-minute refresh on sheet open bounds the staleness. |
| A7 | `ContentUnavailableView` inside a `List` section keeps `.refreshable` working. | assumed (09 §4.7 uses the same construction for the inbox) | If the gesture is swallowed, move the empty view out of the `List` into a `.overlay` and keep `.refreshable` on the `List` (09's fallback). |
| A8 | Hosting a SwiftUI sheet in `UIHostingController` inside a unit test presents its content within 0.5 s (`testLabelsScreenInSheetHosting`). | assumed | If the sheet does not present headlessly, the test is reduced to hosting `LabelsScreen` directly (the other two hosting tests already cover the content) and the sheet path is verified on device (§9 item 13). |
| A9 | `SyncEngine.refreshLabelCounts(force: true)` is cheap enough to call on every sheet open when counts are stale (≤ 1 + 60 quota units, 07 §4.4.7). | verified against the pessimistic table (architecture §4.1, `[gmail-api "Quotas"]`, UNVERIFIED numbers) | Within the ≤ 2,600 units/minute budget even if the sheet is opened repeatedly, because the throttle caps it at one refresh per 5 min unless the user pulls. |
| A10 | `SENT` / `STARRED` / `IMPORTANT` label views are useful in stage 1 even though only the newest 50 messages of each are hydrated on first open. | accepted | Documented in §4.8; deeper history is reachable through "load older" (`viewNextPageToken`). Nothing else in stage 1 shows sent mail. |
| A11 | Two tests in this module duplicate 07 tests (`testLabelOpenedHydratesOnce`, throttle behaviour). | deliberate | modules.md assigns the verification to 12 while 07 owns the implementation; both suites run in `make test-app` and cost < 1 s each. If 07's suite is later restructured, this module's contract tests are the ones that must keep passing. |
