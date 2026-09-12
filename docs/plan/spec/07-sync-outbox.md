# 07-sync-outbox — `SyncEngine`, `HistoryReducer`/`HydrationPolicy`/`Backoff`, `Outbox`, `MailActions`, `SyncStatus`, `BackgroundRefresh`, `Maintenance`

Module id: `07-sync-outbox`. Depends on: `05-gmail-client` (`GmailClient`, `GmailError`, `ThreadModifyCall`), `06-storage` (schema, records, repositories, `Queries`, `LabelAlgebra`, `OutboxCoalescer`, `ThreadAggregator`, `TestDatabase`, `InvariantChecks`), and transitively `03-mailcore-gmail-model` (DTOs, `MessageParser`), `02-mailcore-mime` (`MIMEBuilder`, `Quoting`, `OutgoingBodies`, `MessageIDs`, `Mailbox`), `04-auth` (`AuthStore`, `AuthError`), `01-project-setup` (`AppEnvironment`, `Log`, `Settings`, `SettingsStore`), `08-html-rendering` (`Sanitizer.sanitize`, `Sanitizer.fromPlainText`, `Sanitizer.version`, `Sanitizer.maxInputBytes` — called, never implemented here). Consumed by: `09-inbox-list`, `10-thread-view`, `11-compose`, `12-labels`, `13-settings-theme-signature`, `14-qa`.

Source of truth: architecture §2.2 (MailCore `Sync/*` signatures — copied verbatim in §3.1–§3.3), §2.4 (`SyncStatus`, `SyncReason`, `SyncEngine`, `Outbox`, `MailActions`, `BackgroundRefresh`, `Maintenance` — copied verbatim in §3.4–§3.9), §4.1–§4.10 (algorithms), §5.3–§5.4 (reauth pause, sign-out cancellation), §6.4 (rate-limit abort), §7.6–§7.7 (forward attachments, send), §9.1 (sanitizer call site), §12.2–§12.3 (launch order, tactics), §13.3 (tests), §14 #6/#8/#9/#12/#13/#14/#22/#23/#25, §15 D5–D8/D10/D11/D18/D21/D23. Research facts are cited as `[gmail-api §n]`, `[ios-platform §n]`, `[mime-rfc §n]`. Anything the research marks UNVERIFIED stays UNVERIFIED here (§10).

Conventions: "S" = `message.serverLabelIds`, "P" = the ordered pending outbox deltas for a message, "E" = `message.labelIds` = `LabelAlgebra.effective(S, P)` (architecture §4.7). "one write" = one `db.write { }` = one SQLite transaction. "now ms" = `Int64(clock().timeIntervalSince1970 * 1000)`. `⏎` is never used in this module (no wire bytes are produced here). The GRDB writer type is written `any DatabaseWriter` (see DEVIATION D1: `DatabasePool` in production, `DatabaseQueue` in tests).

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. Three pure `MailCore` files (Foundation only, `swift test` on Linux): `Sync/HistoryReducer.swift` (history pages → net `HistoryChanges`), `Sync/HydrationPolicy.swift` (which history-added messages are worth a `messages.get`), `Sync/Backoff.swift` (exponential backoff with jitter and `Retry-After` precedence) — plus their tests.
2. `actor SyncEngine` (`minimail/Sync/SyncEngine.swift`): `run(reason)` single-flight coordinator; generation-based full sync; `history.list` delta sync with 404/400 → resync and the 5,000-record cap; metadata hydration in 25-id batches with one transaction per batch; label-view hydration; "load older" paging for INBOX and label views; `ensureThreadLoaded` (one `threads.get?format=full` for incomplete threads, batched `messages.get?format=full` for missing bodies, deferred text parts, sanitizer fallback); label counts throttled to 5 minutes; app badge; full-resync request; account-mismatch abort; reauth pause; cancellation for sign-out.
3. `actor Outbox` (`minimail/Sync/Outbox.swift`): 300 ms debounced `kick()`, `drain()` = claim → one `threads.modify` HTTP batch → per-part ack/discard/retry/fail → send via `performSend` with `transmitState = maybeSent` and the `rfc822msgid:` idempotency check, forward-attachment fetch with one `attachmentId` re-resolution, the 20 MB budget, `retrySend`/`discardSend`, `rearmFailedModifies`, wake-up sleep until the earliest `nextAttemptAt` while foregrounded, daily-quota pause.
4. `struct MailActions` (`minimail/Sync/MailActions.swift`, main actor): `archive`, `markRead`, `markUnread`, `send` — each one transaction (optimistic E update + outbox row) followed by `kick()`/`drain()`; `send` wrapped in `beginBackgroundTask`.
5. `@Observable final class SyncStatus` (`minimail/Sync/SyncStatus.swift`).
6. `enum BackgroundRefresh` (`minimail/App/BackgroundRefresh.swift`): `schedule()` (`BGAppRefreshTaskRequest`, +15 min, iOS 27 async branch) and `run(env)` (reschedule → signed-in guard → delta → drain → badge).
7. `enum Maintenance` (`minimail/App/Maintenance.swift`) with its SQL in `minimail/Store/MaintenanceRepository.swift` (DEVIATION D2): the three once-per-24 h statements of architecture §4.9 plus the file purge.
8. The `[07]` insertions in `AppEnvironment` (construction of `SyncStatus`, `Outbox`, `SyncEngine`, `MailActions`, identity source; `prepareSignOut`/`didSignIn`/wipe hooks; `startDeferredWork` steps b and d) and in `MinimailApp` (`.backgroundTask`, `.onChange(of: scenePhase)`).
9. App tests `SyncEngineTests`, `ResyncTests`, `OutboxTests`, `ConflictTests`, `SendTests`, `MaintenanceTests`, `BackgroundRefreshTests` and the shared harness `SyncTestSupport.swift`.

### 1.2 Explicitly out of scope

- SQL. This module calls repository functions (module 06) and GRDB primary-key record fetches only (`Record.fetchOne(db, key:)`, `fetchAll(db, keys:)`, `fetchAll(db)`); the single exception is `Store/MaintenanceRepository.swift`, which this module creates precisely so that `App/Maintenance.swift` contains no SQL (architecture §2.1 rule 3; D2).
- The sanitizer implementation (module 08). This module calls `Sanitizer.sanitize(html:messageId:)`, `Sanitizer.fromPlainText(_:)`, `Sanitizer.version`, `Sanitizer.maxInputBytes` and nothing else from `MailHTML`.
- MIME building, quoting, reply-all computation, subject prefixes (module 02) — called via `MIMEBuilder.build`, `Quoting.*`, `OutgoingBodies.*`, `MessageIDs.*`.
- Compose UI, draft prefill, `SendJob` construction, the > 20 MB Send-button disable (module 11). This module only defines the shared constant `Outbox.maxForwardAttachmentBytes` and refuses over-budget jobs at drain time.
- The Labels sheet, the inbox list, the thread screen, banners (09/10/12). This module exposes state (`SyncStatus`, `AuthStore.state` reads) and entry points; it renders nothing.
- `SendJob`, `ForwardAttachmentRef`, `OutboxRecord`, `OutboxKind`, `OutboxState`, `TransmitState`, `SyncKey` (module 06 `Store/Records.swift`).
- HTTP retries, batching, 401 refresh (module 05). This module never retries a `GmailClient` call itself except through the outbox rows' `nextAttemptAt`.
- Notification authorization prompts (module 13 requests `[.badge]`); this module only reads `notificationSettings()` and calls `setBadgeCount`.
- Sign-out itself (module 04); this module supplies `prepareSignOut` (cancel + await) and `replaceDatabase` after the wipe.

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 09 inbox list | `SyncEngine.run(.pullToRefresh / .loadOlderInbox / .loadOlderLabel(id))`, `SyncStatus` (phase, isOffline, lastError, pendingOps, failedSends), `MailActions.archive/markRead/markUnread`, `Outbox.retrySend(id:)`, `Outbox.discardSend(id:)` |
| 10 thread view | `SyncEngine.ensureThreadLoaded(threadId:)`, `MailActions.archive/markRead/markUnread` |
| 11 compose | `MailActions.send(_:)`, `Outbox.maxForwardAttachmentBytes`, `Outbox.discardSend(id:)` (delete the old failed job on resend) |
| 12 labels | `SyncEngine.run(.labelOpened(id))`, `SyncEngine.refreshLabelCounts(force:)`, `SyncEngine.labelCountsStaleness` (5 min constant) |
| 13 settings | `SyncEngine.requestFullResync()`, `SyncEngine.updateBadge()`, `SyncStatus.lastSyncAt/pendingOps/failedSends`, `SyncStatus.lastError` |
| 14 qa | `SyncTestSupport` harness conventions, `BackgroundRefresh.run(env)` in the device checklist, `Maintenance.cleanup` |
| 04 auth (wiring only) | `AuthStore.hooks.prepareSignOut` ← `SyncEngine.cancelAll()` + `Outbox.cancelAll()`; `hooks.didSignIn` ← `sync.run(.launch)` |

---

## 2. Files

| Path | Kind | Purpose |
|---|---|---|
| `Packages/MailCore/Sources/MailCore/Sync/HistoryReducer.swift` | new | `HistoryChanges`, `HistoryReducer.reduce(_:)` |
| `Packages/MailCore/Sources/MailCore/Sync/HydrationPolicy.swift` | new | `HydrationScope`, `HydrationPolicy.shouldFetch(ref:scope:)` |
| `Packages/MailCore/Sources/MailCore/Sync/Backoff.swift` | new | `Backoff` struct, `.transient`, `.outbox`, `delay(attempt:retryAfter:random:)` |
| `Packages/MailCore/Tests/MailCoreTests/HistoryReducerTests.swift` | new | 14 tests over the `history.*.json` fixtures of module 03 |
| `Packages/MailCore/Tests/MailCoreTests/HydrationPolicyTests.swift` | new | rule matrix (8 tests) |
| `Packages/MailCore/Tests/MailCoreTests/BackoffTests.swift` | new | growth, cap, jitter, `Retry-After` precedence (7 tests) |
| `minimail/Sync/SyncStatus.swift` | new | `@Observable SyncStatus` |
| `minimail/Sync/SyncEngine.swift` | new | `SyncReason`, `actor SyncEngine`, private `SyncError`, private `PreparedBody` |
| `minimail/Sync/Outbox.swift` | new | `actor Outbox`, `OutboxIdentitySource` (main actor), private `SendOutcome` |
| `minimail/Sync/MailActions.swift` | new | `struct MailActions` (main actor) |
| `minimail/Store/MaintenanceRepository.swift` | new | `enum MaintenanceRepository` — the only SQL this module writes (D2) |
| `minimail/App/Maintenance.swift` | new | `enum Maintenance.cleanup(_:now:)` + file purge |
| `minimail/App/BackgroundRefresh.swift` | new | `enum BackgroundRefresh.schedule()` / `run(_:)` |
| `minimail/App/AppEnvironment.swift` | modify | `[07]` insertions: `syncStatus`, `outbox`, `sync`, `actions`, `identitySource` properties + construction; `prepareSignOut`/`didSignIn` hooks; `[07]` part of `wipeAccountData`; `startDeferredWork` steps b and d |
| `minimail/App/MinimailApp.swift` | modify | `.backgroundTask(.appRefresh(BackgroundRefresh.taskID))`, `@Environment(\.scenePhase)` + `.onChange(of: scenePhase)` |
| `minimailTests/Sync/SyncTestSupport.swift` | new | harness: in-memory DB, stubbed `GmailClient`, `FixedTokenProvider`, `BatchStub`, seeding helpers, clock/random injection |
| `minimailTests/Sync/SyncEngineTests.swift` | new | full/delta/hydration/label views/load older/`ensureThreadLoaded`/counts/badge (§7) |
| `minimailTests/Sync/ResyncTests.swift` | new | 404 / 400-invalid → generation resync (§7) |
| `minimailTests/Sync/OutboxTests.swift` | new | drain, per-part results, backoff, attempts, re-arm, debounce, daily-quota pause (§7) |
| `minimailTests/Sync/ConflictTests.swift` | new | the 8 interleavings of architecture §13.3 (§7) |
| `minimailTests/Sync/SendTests.swift` | new | `maybeSent`/`rfc822msgid:`, attachments, budget, permanent failure, snapshot quote, Date at build time (§7) |
| `minimailTests/Sync/MaintenanceTests.swift` | new | the three statements, throttle, guards, file purge (§7; additive, D8) |
| `minimailTests/Sync/BackgroundRefreshTests.swift` | new | signed-out guard, call order, cancellation checkpoint (§7; additive, D8) |

No fixture files are created: MailCore tests use module 03's `Fixtures/gmail/history.*.json`; app tests use the same fixtures copied into the `minimailTests` bundle (spec 01 §5.1) plus JSON built inline. No Info.plist key is added — `UIBackgroundModes: [fetch]` and `BGTaskSchedulerPermittedIdentifiers: [com.minimail.refresh]` are already in `project.yml` (spec 01, architecture §1.4, `[ios-platform §3.1]`). `make lint`: the three package files import only `Foundation`; `minimail/Sync/*` import `Foundation`, `os`, `GRDB`, `MailCore`, `MailHTML`, `UIKit` (only `MailActions.swift`, for `beginBackgroundTask`), `UserNotifications` (only `SyncEngine.swift`); never `AppAuth`, `WebKit`, `SwiftUI`.

---

## 3. Public interface

Package declarations are `public` and nonisolated. App declarations are `internal`; every non-actor type in `minimail/Sync/`, `minimail/App/BackgroundRefresh.swift`, `minimail/App/Maintenance.swift` and `minimail/Store/MaintenanceRepository.swift` is written with an explicit `nonisolated` (app default isolation is `MainActor`, `[tooling §3.3]`), except `SyncStatus`, `MailActions` and `OutboxIdentitySource`, which are deliberately `@MainActor` (implicit).

### 3.1 `MailCore` — `Sync/HistoryReducer.swift`

Verbatim from architecture §2.2 plus public initialisers (additive).

```swift
import Foundation

/// Net effect of one or more `history.list` pages (architecture §4.3 reducer rules). Pure value; every field is Sendable.
public struct HistoryChanges: Sendable, Equatable {
    public var added: [String: GmailMessageRef]        // net of later deletes; last wins
    public var deleted: Set<String>
    public var labelOps: [String: [LabelDelta]]        // chronological per message id; excludes deleted
    public var finalLabels: [String: Set<String>]      // last message.labelIds seen in any change record
    public var touchedThreads: Set<String>
    public var recordCount: Int
    public var newHistoryId: UInt64?
    public init(added: [String: GmailMessageRef] = [:], deleted: Set<String> = [], labelOps: [String: [LabelDelta]] = [:],
                finalLabels: [String: Set<String>] = [:], touchedThreads: Set<String> = [], recordCount: Int = 0, newHistoryId: UInt64? = nil)
    /// `added.keys ∪ labelOps.keys ∪ deleted` — the ids whose local existence the delta must look up.
    public var mentionedIds: Set<String> { get }
}
public enum HistoryReducer {
    /// Reduces pages in the given order (records inside a page in array order). Never throws. Empty input → `HistoryChanges()` with `newHistoryId = nil`.
    public static func reduce(_ pages: [GmailListHistoryResponse]) -> HistoryChanges
}
```

### 3.2 `MailCore` — `Sync/HydrationPolicy.swift`

Verbatim from architecture §2.2 plus the public initialiser.

```swift
import Foundation

public struct HydrationScope: Sendable, Equatable {
    public var cachedLabelIds: Set<String>     // {"INBOX"} ∪ label ids whose view has been fetched (label.viewFetchedAt != NULL)
    public var knownThreadIds: Set<String>     // thread ids that have a `thread` row locally (intersected with the delta's touchedThreads)
    public init(cachedLabelIds: Set<String>, knownThreadIds: Set<String>)
}
public enum HydrationPolicy {
    /// Architecture §4.3: true if `ref.labelIds == nil`, or `ref.threadId ∈ knownThreadIds`, or `labelIds ∩ cachedLabelIds ≠ ∅`.
    public static func shouldFetch(ref: GmailMessageRef, scope: HydrationScope) -> Bool
}
```

### 3.3 `MailCore` — `Sync/Backoff.swift`

Verbatim from architecture §2.2 plus the public initialiser.

```swift
import Foundation

/// Exponential backoff with proportional jitter. `attempt` = number of failures so far (≥ 1; values < 1 are treated as 1).
public struct Backoff: Sendable, Equatable {
    public var base: TimeInterval, factor: Double, cap: TimeInterval, jitter: Double
    public init(base: TimeInterval, factor: Double, cap: TimeInterval, jitter: Double)
    /// `retryAfter` non-nil → returned unchanged (no jitter, no cap) `[gmail-api "Quotas"]`; else
    /// `min(cap, base × factor^(attempt−1)) × (1 + jitter × (2·random − 1))`, `random ∈ [0,1)` injected.
    public func delay(attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval
    public static let transient = Backoff(base: 1, factor: 2, cap: 16, jitter: 0.25)    // 1 s → 16 s cap (architecture §6.2)
    public static let outbox    = Backoff(base: 2, factor: 2, cap: 300, jitter: 0.25)   // 2 s → 300 s cap (architecture §4.8)
}
```

### 3.4 `minimail/Sync/SyncStatus.swift`

Verbatim from architecture §2.4; `lastRunReason` is additive (D3).

```swift
import Foundation
import Observation

/// Observable sync state for banners, the initial-sync footer, the Outbox section and Settings → Advanced. Main actor (implicit). One instance.
@Observable final class SyncStatus {
    enum Phase: Equatable { case idle, syncing, initialSync }
    var phase: Phase = .idle
    var isOffline = false            // last network attempt failed with GmailError.offline; cleared by the next successful request
    var lastError: String?           // GmailError.userMessage (or "Database unavailable"); nil after a successful run
    var lastSyncAt: Date?            // end of the last successful run (any reason)
    var pendingOps = 0               // outbox rows in state pending/inFlight (both kinds)
    var failedSends = 0              // outbox rows kind = send, state = failed
    /// ADDITION (D3): reason of the run that last changed `phase` (Settings → Advanced status line; tests).
    var lastRunReason: SyncReason?
    init()
}
```

### 3.5 `minimail/Sync/SyncEngine.swift`

`SyncReason` and the five architecture methods are verbatim; everything after `// ---- additive ----` is a marked addition.

```swift
import Foundation
import GRDB
import MailCore
import MailHTML
import UserNotifications
import os

/// Why a run was requested (architecture §4.1). `labelOpened`/`loadOlderLabel` carry a Gmail label id.
nonisolated enum SyncReason: Sendable, Equatable {
    case launch, foreground, pullToRefresh, background, afterSend, labelOpened(String), loadOlderInbox, loadOlderLabel(String)
}

/// The sync coordinator. Exactly one instance; owned by `AppEnvironment`. Never touches the UI; reports through `SyncStatus`
/// (main actor hops) and `AuthStore` (`markNeedsReauth`, `handleAccountMismatch`).
actor SyncEngine {
    /// - db: the app pool (DEVIATION D1: `any DatabaseWriter` so tests pass `DatabaseQueue`; architecture writes `DatabasePool`).
    /// - gmail / outbox / status: shared instances from `AppEnvironment`.
    /// - settings: hops to main and returns `SettingsStore.snapshot` (`inboxPageSize`, `showBadge`).
    /// - auth: state reads (`.signedIn` pause rule), `markNeedsReauth()`, `handleAccountMismatch(expected:got:)`.
    /// - clock: injected time source (tests freeze it).
    /// - badge: ADDITION (D4): the `setBadgeCount` sink; default queries `UNUserNotificationCenter`; tests inject a recorder.
    init(db: any DatabaseWriter, gmail: GmailClient, outbox: Outbox, status: SyncStatus,
         settings: @Sendable () async -> Settings, auth: AuthStore,
         clock: @Sendable () -> Date = Date.init,
         badge: @Sendable (Int) async -> Void = SyncEngine.systemBadge)

    /// Architecture §4.1. Never throws. Single-flight: while a run is active a second caller records `reason` in `queuedReasons`,
    /// sets `rerunRequested` and RETURNS IMMEDIATELY; the active run loops once more at its end, processing the queued reasons (§4.2.2).
    /// Executes inline in the caller's task (cancellation of the caller cancels the run at the next checkpoint).
    func run(_ reason: SyncReason) async
    /// Architecture §4.5. Deduplicated per thread: concurrent callers for the same thread await the same task.
    /// Throws `GmailError` (offline/network/unauthorized/…) so `ThreadModel` can show "Couldn't load"; a 404 thread does not throw (rows deleted).
    func ensureThreadLoaded(threadId: String) async throws
    /// Architecture §4.6. Skipped unless `force` or `lastLabelCountsAt` older than `labelCountsStaleness`. Never throws (errors → `status.lastError`).
    func refreshLabelCounts(force: Bool) async
    /// Settings → Advanced. Clears `syncState.historyId` (one write) and then `run(.pullToRefresh)`, which takes the full-sync path.
    func requestFullResync() async
    /// Architecture §4.6. No-op unless `settings.showBadge`; then `badge(Queries.inboxUnreadThreadCount)`.
    func updateBadge() async

    // ---- additive ----
    /// 5 minutes (architecture §4.6); module 12 uses it for the sheet-open staleness check.
    nonisolated static let labelCountsStaleness: TimeInterval = 300
    /// 60 s foreground throttle (architecture §4.1 triggers).
    nonisolated static let foregroundThrottle: TimeInterval = 60
    /// 24 h label-view re-hydration age (architecture §4.1 `.labelOpened`).
    nonisolated static let labelViewMaxAge: TimeInterval = 86_400
    /// 5,000 (architecture §4.3 `tooManyRecords`).
    nonisolated static let maxHistoryRecords = 5_000
    /// Default `badge` sink: `UNUserNotificationCenter.current().notificationSettings().badgeSetting == .enabled` → `try? setBadgeCount(n)`; else nothing.
    nonisolated static func systemBadge(_ count: Int) async
    /// D5: sign-out support (`AuthStore.hooks.prepareSignOut`). Sets the cancel flag, cancels every `ensureThreadLoaded` task, and awaits the
    /// active run (if any). After it returns nothing of this actor is writing to the DB. Cleared by the next `run`.
    func cancelAll() async
    /// D6: after `AuthStore.hooks.wipeAccountData` reopened the database (module 06 creates a new writer), swap the reference.
    func replaceDatabase(_ db: any DatabaseWriter)
    /// D7: test/diagnostic visibility. `true` while a run is executing.
    var isRunning: Bool { get }
}
```

Private types inside `SyncEngine.swift` (documented so tests can reason about them):

```swift
/// Control-flow errors of one run. Never leaves the actor.
nonisolated private enum SyncError: Error, Equatable {
    case historyExpired          // GmailError.historyExpired from listHistory → fullSync in the same run
    case tooManyRecords          // > maxHistoryRecords history records → fullSync in the same run
    case rateLimitAbort          // third consecutive .rateLimited in one run (architecture §6.4)
    case accountMismatch         // profile e-mail ≠ syncState.accountEmail; AuthStore already signing out
    case paused                  // auth.state is not .signedIn
    case cancelled               // Task.isCancelled or cancelAll()
}
/// Output of `prepareBody` (architecture §4.5) — computed on the actor, outside any write.
nonisolated private struct PreparedBody: Sendable {
    var parsed: ParsedMessage
    var body: SanitizedBody           // never nil: sanitized HTML, or the plain-text/snippet/"could not be displayed" fallback
    var text: String?                 // decoded text/plain part (for quoting), nil when absent
    var referenced: Set<String>       // body.referencedContentIDs
}
```

### 3.6 `minimail/Sync/Outbox.swift`

`init`, `kick`, `drain`, `retrySend`, `discardSend`, `rearmFailedModifies` are verbatim from architecture §2.4.

```swift
import Foundation
import GRDB
import MailCore
import os

/// Drains the `outbox` table: `threads.modify` batches and `messages.send` (architecture §4.8, §7.6–§7.7). One instance.
actor Outbox {
    /// Forward budget (architecture §7.6 "> 20 MB"): Σ `ForwardAttachmentRef.size` above this fails the job before any network call.
    nonisolated static let maxForwardAttachmentBytes = 20_000_000
    /// Counted transient attempts before a modify op becomes `failed` (architecture §4.8).
    nonisolated static let maxModifyAttempts = 8
    /// Counted transient attempts before a send becomes `failed` (architecture §7.7).
    nonisolated static let maxSendAttempts = 5
    /// `kick()` debounce (architecture §4.8).
    nonisolated static let kickDelay: TimeInterval = 0.3
    /// Claim size = `GmailClient.batchChunkSize` (25).
    nonisolated static let claimLimit = 25

    /// - identity: hops to main (`OutboxIdentitySource.current()`) and returns the From identity, compose style and the signature HTML
    ///   (nil when `Settings.signatureEnabled == false` or the sanitized signature is empty).
    /// - random: jitter source for `OutboxRepository.retryLater` (tests inject a constant).
    /// - sleep: ADDITION (D4): injected sleeper for the debounce and the wake-up (tests record instead of waiting).
    init(db: any DatabaseWriter, gmail: GmailClient, status: SyncStatus,
         identity: @Sendable () async -> (SelfIdentity, ComposeStyle, signatureHTML: String?),
         clock: @Sendable () -> Date = Date.init,
         random: @Sendable () -> Double,
         sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
    /// Debounce 300 ms then `drain()`. A kick while a kick is pending or a drain is running is absorbed (the running drain re-checks the table).
    func kick()
    /// Architecture §4.8 loop. Returns when nothing is claimable, or after a `.stop` outcome (offline / unauthorized / transient send failure / daily quota).
    /// Re-entrant callers wait for the running drain and return (they do not start a second loop).
    func drain() async
    /// `OutboxRepository.retrySend` (failed → pending, attempts 0) then `drain()`.
    func retrySend(id: Int64) async
    /// `OutboxRepository.deleteSend`; refreshes `status.failedSends`/`pendingOps`.
    func discardSend(id: Int64) async
    /// `OutboxRepository.rearmFailedModifies` (failed modify → pending, attempts 0), refreshes counts. Does NOT drain (the caller's `sync.run` does).
    func rearmFailedModifies() async

    // ---- additive ----
    /// D9: late binding to the engine (`sync.run(.afterSend)`, `sync.updateBadge()`) — breaks the SyncEngine ↔ Outbox construction cycle.
    nonisolated func bind(sync: SyncEngine)
    /// D10: foreground flag. `true` → after a drain that left due-later ops, sleep until the earliest `nextAttemptAt` then drain again
    /// (a continuation of the user's action, architecture §4.8); `false` (scene → background) cancels that sleeper.
    func setForeground(_ isForeground: Bool)
    /// D5: sign-out support. Cancels the debounce and wake-up tasks, sets the cancel flag, awaits a running drain.
    func cancelAll() async
    /// D6: swap the writer after a wipe.
    func replaceDatabase(_ db: any DatabaseWriter)
    /// D11: `true` after a `.forbidden(reason: "dailyLimitExceeded")`; drains are no-ops until the process restarts (architecture §6.2).
    var isPausedForQuota: Bool { get }
    /// D7: `true` while `drain()` runs.
    var isDraining: Bool { get }
}

/// Main-actor source of the send identity (D12). Owned by `AppEnvironment`; `db` is reassigned after a wipe.
@Observable final class OutboxIdentitySource {
    var db: any DatabaseWriter
    let settings: SettingsStore
    init(db: any DatabaseWriter, settings: SettingsStore)
    /// primary = `Mailbox(name: syncState.displayName, addr: syncState.accountEmail)`; `allAddresses` = JSON `syncState.selfAddresses` ∪ {accountEmail};
    /// style = `settings.snapshot.composeStyle`; signature = `signatureEnabled && !signatureHTML.isEmpty ? signatureHTML : nil`.
    /// Precondition: `accountEmail` present (a send is only enqueued while signed in); if absent → `Mailbox(name: nil, addr: "")` and `Log.outbox.error`.
    func current() async -> (SelfIdentity, ComposeStyle, signatureHTML: String?)
}
```

Private types inside `Outbox.swift`:

```swift
nonisolated private enum SendOutcome: Equatable { case `continue`, stop }
```

### 3.7 `minimail/Sync/MailActions.swift`

Verbatim from architecture §2.4 (`db` type per D1).

```swift
import Foundation
import GRDB
import MailCore
import UIKit

/// Main-actor façade for the four user actions (architecture §4.8 "Enqueue"). Value type; `AppEnvironment.actions` is rebuilt after a wipe (D6).
struct MailActions {
    let db: any DatabaseWriter
    let outbox: Outbox
    let sync: SyncEngine
    /// write { enqueueModify(remove INBOX, affected = messageIds) } → kick
    func archive(threadId: String) async
    /// remove UNREAD
    func markRead(threadId: String) async
    /// add UNREAD
    func markUnread(threadId: String) async
    /// write { enqueueSend } → beginBackgroundTask → drain → endBackgroundTask
    func send(_ job: SendJob) async
}
```

### 3.8 `minimail/App/BackgroundRefresh.swift`

Verbatim from architecture §2.4.

```swift
import BackgroundTasks
import Foundation
import os

nonisolated enum BackgroundRefresh {
    static let taskID = "com.minimail.refresh"
    /// `BGAppRefreshTaskRequest(identifier: taskID)`, `earliestBeginDate = now + 15 min`, submitted from a detached task
    /// (`submitTaskRequest` under `#available(iOS 27, *)`, else `submit`) `[ios-platform §3.3]`. Errors logged at `.notice`, never thrown.
    /// No-op when `AppEnvironment.isTestingProcess` (the simulator test host must not touch BGTaskScheduler).
    static func schedule()
    /// Architecture §4.10: `schedule()` → signed-in guard → `env.sync.run(.background)` → `env.outbox.drain()` → `env.sync.updateBadge()`.
    @MainActor static func run(_ env: AppEnvironment) async
}
```

### 3.9 `minimail/App/Maintenance.swift` and `minimail/Store/MaintenanceRepository.swift`

`Maintenance.cleanup` is verbatim from architecture §2.4 except the writer type (D1). `MaintenanceRepository` is new (D2).

```swift
import Foundation
import GRDB
import os

nonisolated enum Maintenance {
    static let interval: TimeInterval = 86_400          // once per 24 h
    static let threadMaxAge: TimeInterval = 30 * 86_400 // statement 1
    static let bodiesKept = 2_000                       // statement 2
    static let fileMaxAge: TimeInterval = 7 * 86_400    // statement 3
    static let failedSendMaxAge: TimeInterval = 30 * 86_400
    /// Architecture §4.9. Guards (all read in one `db.read`): skip unless `historyId != nil && lastDeltaSyncAt != nil`
    /// (no successful sync yet / first full sync still running) and `lastCleanupAt == nil || now − lastCleanupAt ≥ interval`.
    /// Then one write with the three repository statements + `lastCleanupAt = now`, then the file purge off main. Never throws (errors → `Log.db.error`).
    static func cleanup(_ db: any DatabaseWriter, now: Date) async
    /// ADDITION: the file purge alone (`Caches/attachments`, `Caches/cid`; files whose modification date < now − fileMaxAge; empty directories removed).
    /// `cacheRoot` defaults to `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]`.
    static func purgeFiles(now: Date, cacheRoot: URL) throws -> Int   // number of files removed
}

/// The SQL of architecture §4.9 (D2). Lives in `Store/` so that rule 3 of architecture §2.1 holds.
nonisolated enum MaintenanceRepository {
    /// Statement 1: deletes every thread (its `message` rows — cascading `message_body`/`attachment` — its `thread_label` rows and the `thread` row)
    /// where `inInbox = 0 AND unreadCount = 0 AND lastDate < cutoffMs`, no `thread_label` row for a label in `protectedLabelIds`,
    /// and no `pending`/`inFlight` outbox row references the thread (`outbox.threadId`, or `json_extract(sendJob,'$.threadId')`). Returns the number of threads deleted.
    static func deleteExpiredThreads(_ db: Database, cutoffMs: Int64, protectedLabelIds: [String]) throws -> Int
    /// Statement 2: deletes `message_body` rows beyond the newest `keepNewest` by `fetchedAt DESC`, sets `bodyState = 0` on their messages.
    /// Returns the thread ids of the affected messages (caller runs `ThreadRepository.recomputeAggregates` for `bodiesMissing`).
    static func evictBodies(_ db: Database, keepNewest: Int) throws -> Set<String>
    /// Statement 3b: `DELETE FROM outbox WHERE kind = 'send' AND state = 'failed' AND createdAt < cutoffMs`. Returns the count.
    static func deleteOldFailedSends(_ db: Database, cutoffMs: Int64) throws -> Int
}
```

### 3.10 `AppEnvironment` additions (`[07]`)

```swift
// stored properties added to AppEnvironment (all `let` except `actions` and `db`, see D6)
let syncStatus: SyncStatus
let outbox: Outbox
let sync: SyncEngine
private(set) var actions: MailActions
let identitySource: OutboxIdentitySource
```
`db` itself is module 06's property; this module requires it to be `private(set) var db: any DatabaseWriter` (or a `DatabasePool` that 06 replaces on wipe — see §10 O1).

### 3.11 Test support — `minimailTests/Sync/SyncTestSupport.swift`

```swift
import Foundation
import GRDB
import MailCore
import XCTest
@testable import minimail

/// Fixed-token provider for sync tests (no AppAuth). `invalidations` counts `invalidateAccessToken()` calls.
nonisolated final class FixedTokenProvider: TokenProvider, @unchecked Sendable {
    init(token: String = "tok")
    func accessToken() async throws -> String
    func invalidateAccessToken() async
    var invalidations: Int { get }
}

/// Everything a sync/outbox test needs, built in `setUp`.
@MainActor final class SyncHarness {
    let db: DatabaseQueue                       // `Database.openInMemory()` (module 06)
    let status: SyncStatus
    let auth: AuthStore                         // `.signedIn("me@example.com")`: `AuthStore(tokens: AppAuthTokenProvider(keychainAccount: "test.sync", onNeedsReauth: {}), config: OAuthConfig.fromInfoPlist(), hasKeychainItem: true, cachedEmail: "me@example.com")` (spec 04 §3.3/§4.9; no I/O)
    var settings: Settings                      // returned by the engine's `settings` closure; tests mutate it (e.g. `showBadge = true`) between calls
    let gmail: GmailClient                      // `URLSession.minimail(protocolClasses: [StubURLProtocol.self])`, `RequestLimiter(max: 2)`, sleep recorder, random 0.5
    let outbox: Outbox
    let sync: SyncEngine
    let actions: MailActions
    let identity: OutboxIdentitySource
    /// Frozen clock; tests advance it with `advance(seconds:)`.
    var now: Date
    var badgeCalls: [Int]                       // recorder injected as `badge:`
    var sleeps: [TimeInterval]                  // recorder injected into Outbox `sleep:` (debounce + wake-ups); GmailClient's own sleeper records into `clientSleeps`
    var clientSleeps: [TimeInterval]
    init(settings: Settings = Settings()) throws
    func advance(seconds: TimeInterval)
    /// Seeds via `MessageRepository.upsertMetadata` + `ThreadRepository.recomputeAggregates` inside one write; `generation` = current `syncGeneration`.
    func seed(_ messages: [ParsedMessage], selfAddresses: Set<String> = ["me@example.com"]) throws
    /// Sets `syncState.historyId`, `.syncGeneration` (1), `.accountEmail` ("me@example.com"), `.selfAddresses` (["me@example.com"]), `.lastFullSyncAt`, `.lastDeltaSyncAt` in one write.
    func seedSyncState(historyId: UInt64) throws
    func message(_ db: Database, _ id: String) throws -> MessageRecord?
    func thread(_ db: Database, _ id: String) throws -> ThreadRecord?
    func outboxRows(_ db: Database) throws -> [OutboxRecord]
    /// `InvariantChecks.assertAll(db)` (module 06).
    func assertInvariants(file: StaticString = #filePath, line: UInt = #line)
}

/// Builds a `ParsedMessage` with `format=metadata` content (no body). Defaults: `threadId = id`, `internalDate = 1_757_580_000_000`, `from = "alice@example.com"`, `subject = "Subject <id>"`.
nonisolated func msg(_ id: String, thread: String? = nil, labels: [String] = ["INBOX", "UNREAD"], date: Int64? = nil, from: String = "alice@example.com", subject: String? = nil) -> ParsedMessage

/// Route table + batch responder in one handler. Non-batch requests are answered from `routes` exactly as `StubURLProtocol.routes` does;
/// a POST to `/batch/gmail/v1` is split into parts (the request body is parsed for `Content-ID: <pN>` and the inner request line),
/// each part answered by `parts(method, pathWithQuery)`, and the multipart response is assembled with the boundary `batch_test`.
nonisolated enum BatchStub {
    typealias PartResponder = @Sendable (_ method: String, _ path: String) -> (status: Int, body: Data)
    static func install(routes: [(method: String, path: String, responses: [StubURLProtocol.Response])], parts: @escaping PartResponder)
    /// Parts answered from JSON fixtures by message/thread id: `GET /gmail/v1/users/me/messages/{id}?…` → `messages[id]`,
    /// `POST /gmail/v1/users/me/threads/{id}/modify…` → `modify[id]`, `GET /gmail/v1/users/me/labels/{id}…` → `labels[id]`; unknown id → 404 envelope.
    static func responder(messages: [String: Data] = [:], modify: [String: (Int, Data)] = [:], labels: [String: Data] = [:]) -> PartResponder
    /// Number of batch POSTs and of parts seen since `StubURLProtocol.reset()`.
    static var batchCount: Int { get }
    static var partCount: Int { get }
}

/// JSON builders used instead of fixtures where the ids must match the seed.
nonisolated enum JSONFixtures {
    static func metadataMessage(id: String, thread: String, labels: [String], date: Int64, from: String, subject: String, messageID: String? = nil) -> Data
    static func fullMessage(id: String, thread: String, labels: [String], date: Int64, html: String?, text: String?, attachments: [(partId: String, filename: String, mime: String, size: Int, attachmentId: String, cid: String?)] = []) -> Data
    static func thread(id: String, messages: [Data]) -> Data
    static func history(records: [[String: Any]], historyId: UInt64, nextPageToken: String? = nil) -> Data
    static func messageList(ids: [String], nextPageToken: String? = nil) -> Data
    static func profile(email: String, historyId: UInt64) -> Data
    static func modifyResponse(threadId: String, messages: [(id: String, labels: [String])]) -> Data
    static func attachment(bytes: Data) -> Data
    static func errorEnvelope(code: Int, reason: String, message: String) -> Data
}
```
Fixture loader: the same private `fixture(_:)` as spec 05 §5.6 (`Bundle(for:).url(forResource:withExtension:subdirectory: "Fixtures/gmail")`, flattened fallback, `XCTSkip` when missing).

---

## 4. Behaviour

### 4.1 `HistoryReducer.reduce` (architecture §4.3 rules; `[gmail-api §13]`)

```
reduce(pages):
    var c = HistoryChanges()
    for page in pages:
        for record in page.history ?? []:
            c.recordCount += 1
            for ch in record.messagesAdded ?? []:
                id = ch.message.id
                c.added[id] = ch.message                      // last wins
                c.deleted.remove(id)                          // delete-then-add re-adds
                if let l = ch.message.labelIds: c.finalLabels[id] = Set(l)
                touch(ch.message.threadId)
            for ch in record.messagesDeleted ?? []:
                id = ch.message.id
                c.deleted.insert(id)
                c.added.removeValue(forKey: id); c.labelOps.removeValue(forKey: id); c.finalLabels.removeValue(forKey: id)   // added-then-deleted cancels
                touch(ch.message.threadId)
            for ch in record.labelsAdded ?? []:
                id = ch.message.id
                c.labelOps[id, default: []].append(LabelDelta(add: Set(ch.labelIds ?? []), remove: []))
                if let l = ch.message.labelIds: c.finalLabels[id] = Set(l)
                touch(ch.message.threadId)
            for ch in record.labelsRemoved ?? []:
                id = ch.message.id
                c.labelOps[id, default: []].append(LabelDelta(add: [], remove: Set(ch.labelIds ?? [])))
                if let l = ch.message.labelIds: c.finalLabels[id] = Set(l)
                touch(ch.message.threadId)
    for id in c.deleted: c.labelOps.removeValue(forKey: id); c.finalLabels.removeValue(forKey: id)   // labelOps/finalLabels exclude deleted (post-pass)
    c.newHistoryId = pages.last?.historyId?.value
    return c
touch(t): if let t: c.touchedThreads.insert(t)
```
Edge cases: a record with none of the four arrays counts in `recordCount` and changes nothing; an empty `labelIds` array in a label change appends an empty `LabelDelta` (harmless, `applied(to:)` is identity); `pages = []` → `HistoryChanges()` (`newHistoryId = nil`); a page whose `history` is nil but `historyId` present (fixture `history.empty.json`) → `recordCount = 0`, `newHistoryId = 2000`. Complexity O(records); no allocation beyond the dictionaries.

### 4.2 `HydrationPolicy.shouldFetch` (architecture §4.3)

| `ref.labelIds` | `ref.threadId ∈ knownThreadIds` | `labelIds ∩ cachedLabelIds` | result |
|---|---|---|---|
| nil | any | — | `true` (unknown → fetch; the row's flags decide) |
| non-nil | true | any | `true` (a reply in a thread we show, including our own SENT copy) |
| non-nil | false | non-empty | `true` |
| non-nil (incl. `[]`) | false | empty | `false` (SPAM/TRASH/DRAFT-only, label-only mail never opened) |

`ref.threadId == nil` counts as "not known". Pure, O(|labelIds|).

### 4.3 `Backoff.delay`

```
delay(attempt, retryAfter, random):
    if let r = retryAfter: return r                               // Retry-After wins, unjittered, uncapped
    let n = max(1, attempt)
    let raw = min(cap, base * pow(factor, Double(n - 1)))
    return raw * (1 + jitter * (2 * random - 1))                  // random 0 → −jitter, 0.5 → exact, →1 → +jitter
```
Value table (`random = 0.5`): `.transient` attempts 1…6 → 1, 2, 4, 8, 16, 16 s; `.outbox` attempts 1…10 → 2, 4, 8, 16, 32, 64, 128, 256, 300, 300 s. `attempt ≤ 0` behaves as 1. Precondition: `random ∈ [0, 1)` (not enforced; out-of-range values only scale the jitter).

### 4.4 `SyncEngine` — actor state and helpers

```swift
private var db: any DatabaseWriter
private var running = false
private var rerunRequested = false
private var queuedReasons: [SyncReason] = []            // reasons that arrived during a run (deduplicated, order kept)
private var cancelRequested = false
private var runWaiters: [CheckedContinuation<Void, Never>] = []
private var threadLoads: [String: Task<Void, any Error>] = [:]
private var consecutiveRateLimited = 0                   // reset per run and on every successful request
private var selfAddresses: Set<String> = []              // refreshed from syncState at the start of every run and of ensureThreadLoaded
private var generation = 0                               // syncState.syncGeneration cached per run
```
Helpers (private):
- `nowMs() -> Int64`.
- `checkpoint() throws` — `if Task.isCancelled || cancelRequested { throw SyncError.cancelled }`. Called before every `gmail.*` call and before every `db.write`.
- `setStatus(_ mutate: @MainActor @Sendable (SyncStatus) -> Void) async` — `await MainActor.run { mutate(status) }`.
- `noteResult(_ error: GmailError?) async throws` — success: `consecutiveRateLimited = 0`, `status.isOffline = false`; `.offline`: `status.isOffline = true`; `.rateLimited`: `consecutiveRateLimited += 1`, `if consecutiveRateLimited >= 3 { throw SyncError.rateLimitAbort }`; `.unauthorized`: `await auth.markNeedsReauth()`. Architecture §6.4 ("a third consecutive `.rateLimited` in one run aborts the run"): a single request that throws `.rateLimited` (after module 05's own retries) already ends the run through `call`'s rethrow (`report` → `lastError = "Rate limited — try again later"`); the counter matters for batches, whose per-part failures do not throw — `hydrateMetadata` and `refreshLabelCounts` call `noteResult(.rateLimited(retryAfter: nil))` when any part of a batch failed with `.rateLimited`, and `noteResult(nil)` when none did, so three consecutive rate-limited batches abort the run (`testRateLimitAbort`).
- `call<T>(_ op: () async throws -> T) async throws -> T` — `try checkpoint()`, run `op`, route the outcome through `noteResult`, rethrow (`GmailError.historyExpired` → `SyncError.historyExpired`; `CancellationError` → `SyncError.cancelled`). Every `gmail.*` call in this actor goes through `call`.
- `readState(_ key: SyncKey) async throws -> String?` = `db.read { SyncStateRepository.get($0, key) }`.
- `loadSelfAddresses()` — JSON `[String]` from `syncState.selfAddresses` ∪ `{accountEmail}`; empty when signed-in with no cache yet.

Isolation: all state above is actor-isolated. Sanitizing (`prepareBody`) and parsing run on the actor's executor, never inside `db.write` (architecture §2.1 rule 4). DB access uses the `async` `read`/`write` forms only (`[ios-platform §2.5]`).

#### 4.4.1 `run(reason)` — single flight

```
run(reason):
    if running: queuedReasons.appendIfAbsent(reason); rerunRequested = true; return
    running = true; cancelRequested = false
    var reasons = [reason]
    repeat:
        rerunRequested = false
        for r in reasons: await execute(r)                       // never throws
        reasons = queuedReasons; queuedReasons = []
    while rerunRequested && !cancelRequested && !Task.isCancelled
    running = false
    resume every runWaiters continuation; runWaiters = []
```
`execute(r)`:
```
execute(reason):
    guard case .signedIn = await auth.state else { Log.sync.notice("run skipped: not signed in"); return }     // architecture §5.3 pause rule
    if reason == .foreground, let t = lastDeltaSyncAt, clock().timeIntervalSince(t) < foregroundThrottle:
        await outbox.rearmFailedModifies(); await outbox.drain(); return                                          // re-arm still happens; no delta
    await setStatus { $0.phase = (historyId == nil && lastFullSyncAt == nil) ? .initialSync : .syncing; $0.lastRunReason = reason }
    selfAddresses = loadSelfAddresses(); generation = Int(syncState.syncGeneration ?? "0")!; consecutiveRateLimited = 0
    do {
        switch reason:
        case .launch, .foreground, .pullToRefresh, .background:
            if reason != .background && reason != .launch: await outbox.rearmFailedModifies()          // foreground + pull re-arm (architecture §4.8)
            try await syncCore(force: reason == .pullToRefresh)
        case .afterSend:
            try await deltaOrResync()                                                                  // picks up the SENT copy; no counts
        case .labelOpened(let id):
            try await hydrateLabelViewIfStale(id)
            try await syncCore(force: false)
        case .loadOlderInbox:
            try await loadOlderInbox()                                                                 // no delta
        case .loadOlderLabel(let id):
            try await loadOlderLabel(id)
        await setStatus { $0.lastError = nil; $0.lastSyncAt = clock() }
        if reason != .background: await Maintenance.cleanup(db, now: clock())                          // guarded inside; runs at most once per 24 h
    } catch SyncError.paused, SyncError.cancelled { /* silent */ }
      catch SyncError.rateLimitAbort { await setStatus { $0.lastError = GmailError.rateLimited(retryAfter: nil).userMessage } }
      catch SyncError.accountMismatch { /* AuthStore is signing out; nothing to report */ }
      catch let e as GmailError { await report(e) }
      catch let e as DatabaseError { Log.db.error(...); await setStatus { $0.lastError = "Database unavailable" } }   // SQLITE_AUTH/IOERR in BG
      catch { await setStatus { $0.lastError = String(describing: error) } }
    await setStatus { $0.phase = .idle }
    await outbox.drain()                                                                               // every path ends with a drain (architecture §4.1)
    await updateBadge()
```
`report(e)`: `.offline` → `isOffline = true` (no `lastError`); `.unauthorized` → nothing (banner comes from `auth.state`); `.cancelled` → nothing; else `lastError = e.userMessage`.

`syncCore(force:)`:
```
    if historyId == nil: try await fullSync()               // fullSync ends with deltaSync
    else: try await deltaOrResync()
    await refreshLabelCounts(force: force || justDidFullSync)
```
`deltaOrResync()`: `do { try await deltaSync() } catch SyncError.historyExpired, SyncError.tooManyRecords { Log.sync.notice("sync.history.expired"); try await fullSync() }`.

Single-flight consequences: `BackgroundRefresh.run` awaiting `sync.run(.background)` while a foreground run is active returns at once (the active run re-runs `.background`; the BG handler then drains and updates the badge itself). A `.labelOpened` queued during a run is executed by the same run's second lap, so the Labels sheet never waits on a second `run` call.

#### 4.4.2 `fullSync()` (architecture §4.2)

```
fullSync():
    Log.measure(.fullSync):
    profile = try await call { try await gmail.getProfile() }                                       // baseline BEFORE listing [gmail-api §13 item 1]
    if let cached = syncState.accountEmail, cached != profile.emailAddress:
        await auth.handleAccountMismatch(expected: cached, got: profile.emailAddress); throw SyncError.accountMismatch
    sendAs = (try? await call { try await gmail.listSendAs() }) ?? []                                // tolerated failure
    labels = try await call { try await gmail.listLabels() }
    gen = generation + 1
    identity = deriveIdentity(profile, sendAs)     // displayName: sendAs first isDefault, else isPrimary, else nil; selfAddresses: {profile.email} ∪ {s.sendAsEmail.lowercased() | isPrimary || verificationStatus == "accepted"}; signature: the default/primary sendAs.signature
    try checkpoint()
    try await db.write { db in
        set(.accountEmail, profile.emailAddress); set(.displayName, identity.displayName); set(.selfAddresses, sortedJSONArray(identity.selfAddresses))
        set(.sendAsSignature, identity.signature); set(.syncGeneration, String(gen))
        try LabelRepository.replaceAll(db, labels: labels)
    }
    generation = gen; selfAddresses = identity.selfAddresses
    pageSize = (await settings()).inboxPageSize
    page = try await call { try await gmail.listMessages(labelIds: ["INBOX"], q: nil, maxResults: pageSize, pageToken: nil) }
    try await hydrateMetadata(ids: (page.messages ?? []).map(\.id), generation: gen)                // §4.4.3: one write per 25
    try await db.write { set(.inboxNextPageToken, page.nextPageToken) }
    for labelId in try await db.read { try LabelRepository.cachedViewLabelIds($0) }:
        p = try await call { try await gmail.listMessages(labelIds: [labelId], q: nil, maxResults: 50, pageToken: nil) }
        try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: gen)
        try await db.write { try LabelRepository.markViewFetched($0, labelId: labelId, nextPageToken: p.nextPageToken, now: nowMs()) }
    try checkpoint()
    try await db.write { db in
        stale   = try MessageRepository.staleIds(db, olderThanGeneration: gen)                     // excludes outbox-referenced ids
        threads = Set(try MessageRecord.fetchAll(db, keys: Array(stale)).map(\.threadId))
        _ = try MessageRepository.delete(db, ids: stale)
        for t in threads { try ThreadRepository.markComplete(db, threadId: t, complete: false) }
        try ThreadRepository.recomputeAggregates(db, threadIds: threads, selfAddresses: selfAddresses)
        set(.historyId, String(profile.historyId.value)); set(.lastFullSyncAt, String(nowMs()))
    }
    justDidFullSync = true
    try await deltaSync()                                                                             // idempotent catch-up
```
`sortedJSONArray`: `JSONEncoder` with `.sortedKeys` over the sorted array (byte-stable). `status.phase` was set by `execute` (`.initialSync` only when `lastFullSyncAt == nil`); a resync shows `.syncing`. A thrown error anywhere leaves `historyId` untouched (the old value, or nil → the next run repeats the full sync; already-hydrated rows carry the new generation and survive `staleIds` on the retry because `syncGeneration` was already persisted — the retry uses `gen = persisted + 1`, so those rows are re-listed and re-stamped; rows that are not re-listed are deleted, as intended).

#### 4.4.3 `hydrateMetadata(ids:generation:)` (architecture §4.4)

```
hydrateMetadata(ids, generation):
    for chunk in ids.chunked(into: 25):
        try checkpoint()
        results = try await call { try await gmail.getMessages(ids: chunk, format: .metadata) }     // one HTTP batch; per-part retries inside 05
        Log.measure(.hydrateBatch):
        parsed = results.compactMap { (id, r) in
            switch r { case .success(let m): MessageParser.parse(m)
                       case .failure(.notFound): nil                                                  // deleted meanwhile [gmail-api gotcha 5]
                       case .failure(let e): Log.sync.error("hydrate \(id) \(e)"); nil } }           // picked up by the next delta
        try await noteResult(results.values.contains { if case .failure(.rateLimited) = $0 { true } else { false } } ? .rateLimited(retryAfter: nil) : nil)   // §6.4 counter
        if parsed.isEmpty: continue
        try await db.write { db in
            touched = try MessageRepository.upsertMetadata(db, parsed: parsed, selfAddresses: selfAddresses, generation: generation, now: nowMs())
            try ThreadRepository.recomputeAggregates(db, threadIds: touched, selfAddresses: selfAddresses)
        }
```
Empty `ids` → no request. Order of `parsed` is irrelevant (`upsertMetadata` is per row). `results` also contains `.failure(.unauthorized)` parts after 05's refresh-once path → logged, dropped; the outer `call` never sees them (05 returns per-part results), so `markNeedsReauth` is triggered by the next single request that fails.

#### 4.4.4 `deltaSync()` (architecture §4.3)

```
deltaSync():
    Log.measure(.deltaSync):
    guard let s = syncState.historyId, let start = UInt64(s) else { throw SyncError.historyExpired }
    var pages: [GmailListHistoryResponse] = []; var token: String? = nil; var count = 0
    repeat:
        page = try await call { try await gmail.listHistory(startHistoryId: start, pageToken: token) }   // .historyExpired → catch below
        pages.append(page); token = page.nextPageToken; count += page.history?.count ?? 0
        if count > maxHistoryRecords { throw SyncError.tooManyRecords }
    while token != nil
    changes = HistoryReducer.reduce(pages)
    (existing, cachedViews, known) = try await db.read { db in
        (try MessageRepository.idsExisting(db, among: Array(changes.mentionedIds)),
         try LabelRepository.cachedViewLabelIds(db),
         Set(try ThreadRecord.fetchAll(db, keys: Array(changes.touchedThreads)).map(\.id))) }
    scope = HydrationScope(cachedLabelIds: Set(["INBOX"] + cachedViews), knownThreadIds: known)
    toFetch = changes.added.filter { id, ref in !existing.contains(id) && HydrationPolicy.shouldFetch(ref: ref, scope: scope) }.map(\.key)
            + changes.labelOps.filter { id, deltas in !existing.contains(id) && changes.added[id] == nil
                                                     && deltas.contains { !$0.add.isDisjoint(with: scope.cachedLabelIds) } }.map(\.key)   // moved into scope elsewhere
    try await hydrateMetadata(ids: toFetch.sorted(), generation: generation)                       // sorted → deterministic batches for tests
    try checkpoint()
    try await db.write { db in
        var touched = try MessageRepository.delete(db, ids: changes.deleted.intersection(existing))
        var relabeled = Set<String>()
        for id in existing.subtracting(changes.deleted):
            if let final = changes.finalLabels[id]: try MessageRepository.applyServerLabels(db, messageId: id, labels: final); relabeled.insert(id)
            else if let ops = changes.labelOps[id], !ops.isEmpty: for d in ops { try MessageRepository.applyServerDelta(db, messageId: id, delta: d) }; relabeled.insert(id)
        touched.formUnion(try MessageRepository.recomputeEffective(db, messageIds: relabeled))
        try ThreadRepository.recomputeAggregates(db, threadIds: touched, selfAddresses: selfAddresses)
        newId = max(start, changes.newHistoryId ?? start)                                              // never decreases (invariant 5)
        set(.historyId, String(newId)); set(.lastDeltaSyncAt, String(nowMs()))
    }
```
`GmailError.historyExpired` thrown by `listHistory` is converted in `call`'s rethrow path: `catch GmailError.historyExpired { throw SyncError.historyExpired }` (both 404 and 400-`failedPrecondition`/"historyId", UNVERIFIED code `[gmail-api §13.5]`, mapped by module 05). Messages fetched in `hydrateMetadata` already carry the post-change labels (S from `messages.get`), so they are deliberately not in `existing` and receive no delta replay. A `messagesAdded` for a message that already exists locally (our own send echoed) takes the `existing` path: `finalLabels` (present in `messagesAdded` per `[gmail-api §13]`, UNVERIFIED → fallback is "no-op", the row keeps S).

#### 4.4.5 Label views and load older (architecture §4.1)

```
hydrateLabelViewIfStale(id):
    label = try await db.read { try LabelRecord.fetchOne($0, key: id) }
    guard let label else { return }                                        // unknown label: nothing to do (labels.list will refresh it)
    if let at = label.viewFetchedAt, Double(nowMs() - at) / 1000 < labelViewMaxAge { return }
    p = try await call { try await gmail.listMessages(labelIds: [id], q: nil, maxResults: 50, pageToken: nil) }
    try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: generation)
    try await db.write { try LabelRepository.markViewFetched($0, labelId: id, nextPageToken: p.nextPageToken, now: nowMs()) }

loadOlderInbox():
    guard let token = syncState.inboxNextPageToken else { return }
    p = try await call { try await gmail.listMessages(labelIds: ["INBOX"], q: nil, maxResults: (await settings()).inboxPageSize, pageToken: token) }
    try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: generation)
    try await db.write { set(.inboxNextPageToken, p.nextPageToken) }     // nil when exhausted → module 09 hides "Load older"

loadOlderLabel(id):
    guard let label = fetchOne(id), let token = label.viewNextPageToken else { return }
    p = listMessages(labelIds: [id], maxResults: 50, pageToken: token)
    hydrateMetadata(...); db.write { markViewFetched(id, p.nextPageToken, now) }
```
`INBOX` as a label id in `.labelOpened("INBOX")` / `.loadOlderLabel("INBOX")` is treated as `.loadOlderInbox` semantics? No — module 12 never emits `INBOX` (the Inbox scope is `.inbox`); if it does, the label path runs harmlessly (50 more inbox messages).

#### 4.4.6 `ensureThreadLoaded(threadId:)` (architecture §4.5)

```
ensureThreadLoaded(threadId):
    if let t = threadLoads[threadId] { return try await t.value }
    let task = Task { [self] in try await self.loadThread(threadId) }
    threadLoads[threadId] = task
    defer { threadLoads[threadId] = nil }
    try await task.value

loadThread(threadId):
    Log.measure(.threadOpen):
    selfAddresses = loadSelfAddresses(); generation = current
    guard let t = try await db.read { try ThreadRecord.fetchOne($0, key: threadId) } else { return }
    if t.isComplete == 0:
        let thread: GmailThread
        do { thread = try await call { try await gmail.getThread(id: threadId, format: .full) } }        // 40 units, one round trip
        catch GmailError.notFound {
            try await db.write { db in
                ids = try ThreadRepository.messageIds(db, threadId: threadId)
                touched = try MessageRepository.delete(db, ids: Set(ids))
                try ThreadRepository.recomputeAggregates(db, threadIds: touched.union([threadId]), selfAddresses: selfAddresses) }
            return }
        prepared = try await (thread.messages ?? []).asyncMap(prepareBody)                                // on the actor, outside the write
        try checkpoint()
        try await db.write { db in
            touched = try MessageRepository.upsertMetadata(db, parsed: prepared.map(\.parsed), selfAddresses: selfAddresses, generation: generation, now: nowMs())
            for p in prepared {
                try BodyRepository.storeBody(db, messageId: p.parsed.id, body: p.body, text: p.text, attachments: p.parsed.attachments, referenced: p.referenced, now: nowMs())
                try MessageRepository.applyServerLabels(db, messageId: p.parsed.id, labels: Set(p.parsed.labelIds)) }
            _ = try MessageRepository.recomputeEffective(db, messageIds: Set(prepared.map(\.parsed.id)))
            try ThreadRepository.markComplete(db, threadId: threadId, complete: true)
            try ThreadRepository.recomputeAggregates(db, threadIds: touched.union([threadId]), selfAddresses: selfAddresses) }
    else:
        missing = try await db.read { try BodyRepository.missingBodyIds($0, threadId: threadId, sanitizerVersion: Sanitizer.version) }
        if missing.isEmpty { return }
        dates = internalDate per id (MessageRecord.fetchAll(keys:)); order newest first
        for chunk in missing.sortedNewestFirst.chunked(into: 10):
            Log.measure(.bodyLoad):
            results = try await call { try await gmail.getMessages(ids: chunk, format: .full) }
            var prepared: [PreparedBody] = []; var gone = Set<String>(); var unavailable = Set<String>()
            for (id, r) in results:
                switch r { case .success(let m): if m.payload == nil { unavailable.insert(id) } else { prepared.append(try await prepareBody(m)) }
                           case .failure(.notFound): gone.insert(id)
                           case .failure(let e): Log.sync.error(...) }                                    // transient: left for the next open
            try checkpoint()
            try await db.write { db in
                touched = try MessageRepository.delete(db, ids: gone)
                for p in prepared { storeBody(...); applyServerLabels(...) }
                for id in unavailable { try BodyRepository.markUnavailable(db, messageId: id) }
                touched.formUnion(try MessageRepository.recomputeEffective(db, messageIds: Set(prepared.map(\.parsed.id))))
                try ThreadRepository.recomputeAggregates(db, threadIds: touched.union([threadId]), selfAddresses: selfAddresses) }
```
`prepareBody(msg) async throws -> PreparedBody` (architecture §4.5, §9.1 step 7, `[mime-rfc §5.2 (h)]`):
```
    parsed = MessageParser.parse(msg)
    var html = parsed.body?.html; var text = parsed.body?.text
    if html == nil && text == nil, let part = parsed.body?.deferredTextParts.first, let attId = part.attachmentId:
        if let data = try? await call { try await gmail.getAttachment(messageId: msg.id, attachmentId: attId) }:   // .notFound / transient → fall through to the snippet
            decoded = MessageParser.decodeText(bytes: data, charset: part.charset)
            if part.mimeType == "text/html" { html = decoded } else { text = decoded }
    let body: SanitizedBody
    if let h = html, h.utf8.count <= Sanitizer.maxInputBytes, let s = try? Sanitizer.sanitize(html: h, messageId: msg.id): body = s
    else if let t = text: body = Sanitizer.fromPlainText(t)
    else if let sn = msg.snippet, !sn.isEmpty: body = Sanitizer.fromPlainText(sn)
    else { body = Sanitizer.fromPlainText("This message could not be displayed."); Log.web.error("web.sanitize.failed \(msg.id)") }
    return PreparedBody(parsed: parsed, body: body, text: text, referenced: body.referencedContentIDs)
```
`storeBody`'s `attachments:` receives `parsed.attachments` (inline images included); the repository derives `isInline` from `referenced` (assumption A3). Error surface: `GmailError` from `getThread`/`getMessages` propagates to the caller (`ThreadModel` shows "Couldn't load this message · Retry"); `.unauthorized` also flips `auth` via `noteResult`. Concurrency: two `ThreadScreen` appearances for the same thread share one task; different threads load concurrently (bounded by `RequestLimiter(2)`).

#### 4.4.7 `refreshLabelCounts(force:)` (architecture §4.6)

```
refreshLabelCounts(force):
    guard case .signedIn = await auth.state else { return }
    if !force, let at = Int64(syncState.lastLabelCountsAt ?? ""), Double(nowMs() - at) / 1000 < labelCountsStaleness { return }
    do {
        labels = try await call { try await gmail.listLabels() }                                          // 1 unit; renamed/new labels
        try await db.write { try LabelRepository.replaceAll($0, labels: labels) }
        ids = ["INBOX", "STARRED", "IMPORTANT", "SENT"].filter { id in labels.contains { $0.id == id } }
            + labels.filter { $0.type == "user" && $0.labelListVisibility != "labelHide" }.map(\.id).sorted()
        ids = Array(ids.prefix(60))
        results = try await call { try await gmail.getLabels(ids: ids) }                                   // batches of 25
        fetched = results.compactMap { try? $0.value.get() }
        try await db.write { db in try LabelRepository.updateCounts(db, labels: fetched, now: nowMs()); set(.lastLabelCountsAt, String(nowMs())) }
    } catch let e as GmailError { await report(e) } catch {}
```
Per-label failures (404 for a label deleted between the two calls) are skipped; `lastLabelCountsAt` is still written so a permanently failing label cannot defeat the throttle. Quota: ≤ 1 + 60 units.

#### 4.4.8 `requestFullResync()`, `updateBadge()`, `cancelAll()`, `replaceDatabase(_:)`

- `requestFullResync()`: `try? await db.write { try SyncStateRepository.set($0, .historyId, nil) }` then `await run(.pullToRefresh)`. `lastFullSyncAt` is kept, so the phase is `.syncing` (not `.initialSync`) and the list stays visible during the resync.
- `updateBadge()`: `guard (await settings()).showBadge else { return }`; `n = try? await db.read { try Queries.inboxUnreadThreadCount($0) }`; `await badge(n ?? 0)`. `systemBadge(n)`: `let s = await UNUserNotificationCenter.current().notificationSettings(); guard s.badgeSetting == .enabled else { return }; try? await UNUserNotificationCenter.current().setBadgeCount(n)` `[ios-platform §6]`. Called at the end of every `execute`, by `Outbox.drain` after an ack (through `bind`), by `BackgroundRefresh.run`, and at +2 s of launch.
- `cancelAll()`: `cancelRequested = true`; `for t in threadLoads.values { t.cancel() }`; `if running { await withCheckedContinuation { runWaiters.append($0) } }`. After return: `running == false`, no `db.write` of this actor in flight (each write completes before the next checkpoint throws). `threadLoads` tasks end with `CancellationError`/`.cancelled` and are removed by their `defer`.
- `replaceDatabase(db)`: assigns; precondition `!running` (call only after `cancelAll()`).

#### 4.4.9 Performance constraints (architecture §12.1)

Idle delta = one `history.list` request (2 units, < 600 ms on LTE). Delta with ≤ 5 new messages = 1 + 1 batch, one metadata transaction (< 1 s). Initial sync of 100 messages = `getProfile` + `sendAs.list` + `labels.list` + `messages.list` + 4 metadata batches, each its own transaction so the list fills progressively (< 6 s). Thread open incomplete: exactly one `threads.get?format=full` (< 1.5 s on LTE); sanitizing happens on the actor (500 KB newsletter < 150 ms per module 08's gate). No request is ever issued for bodies outside `ensureThreadLoaded`. Quota per minute stays under 2,600 pessimistic units: sequential batches, `RequestLimiter(2)`.

### 4.5 `Outbox`

Actor state:
```swift
private var db: any DatabaseWriter
private let syncBox = OSAllocatedUnfairLock<SyncEngine?>(initialState: nil)   // nonisolated let
private var draining = false
private var drainWaiters: [CheckedContinuation<Void, Never>] = []
private var kickTask: Task<Void, Never>?
private var wakeTask: Task<Void, Never>?
private var isForeground = false
private var cancelRequested = false
private var pausedForQuota = false
```

#### 4.5.1 `kick()` and the wake-up

```
kick():
    guard kickTask == nil, !draining else { return }
    kickTask = Task { [self] in
        try? await self.sleeper(Self.kickDelay)
        await self.clearKick(); await self.drain() }
setForeground(f):
    isForeground = f
    if !f { wakeTask?.cancel(); wakeTask = nil }
scheduleWake(after: TimeInterval):            // called at the end of drain when ops are pending but not due
    guard isForeground, wakeTask == nil else { return }
    wakeTask = Task { [self] in
        try? await self.sleeper(after)
        await self.clearWake(); if !Task.isCancelled { await self.drain() } }
```
A burst of swipes (each `MailActions.archive` → `enqueueModify` coalescing per thread → `kick()`) therefore results in one batch 300 ms after the first swipe (later swipes are absorbed; if the drain already started, their rows are claimed by the drain's next loop iteration because `claimModifies` runs again until it returns empty).

#### 4.5.2 `drain()` (architecture §4.8)

```
drain():
    if draining { await withCheckedContinuation { drainWaiters.append($0) }; return }
    guard !pausedForQuota else { return }
    draining = true; defer { draining = false; resume drainWaiters; drainWaiters = [] }
    var ackedAny = false; var stop = false; var earliestDue: Int64? = nil
    Log.measure(.outboxDrain):
    loop:
        if cancelRequested || Task.isCancelled { break }
        mods = try await db.write { try OutboxRepository.claimModifies($0, limit: Self.claimLimit, now: nowMs()) }    // pending & due → inFlight, attempts += 1
        if !mods.isEmpty:
            calls = mods.map { ThreadModifyCall(opId: $0.id, threadId: $0.threadId!, add: decodeJSONArray($0.addLabelIds), remove: decodeJSONArray($0.removeLabelIds)) }
            var results: [Int64: Result<GmailThread, GmailError>]
            do { results = try await gmail.modifyThreads(calls) }
            catch let e as GmailError { results = Dictionary(uniqueKeysWithValues: calls.map { ($0.opId, .failure(e)) }) }
            catch { results = … .failure(.cancelled) }
            try await db.write { db in
                for op in mods:
                    let r = results[op.id] ?? .failure(.batchMalformed)
                    switch r {
                    case .success(let thread):
                        labels = thread.messages.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, Set($0.labelIds ?? [])) }) }   // nil when messages absent
                        _ = try OutboxRepository.ackModify(db, opId: op.id, serverLabelsByMessage: labels); ackedAny = true
                    case .failure(.notFound):
                        _ = try OutboxRepository.ackModify(db, opId: op.id, serverLabelsByMessage: nil); ackedAny = true       // target gone; S unchanged
                    case .failure(.badRequest):
                        _ = try OutboxRepository.discardModify(db, opId: op.id); Log.outbox.error("modify \(op.id) discarded: \(r)")
                    case .failure(.forbidden(let reason)) where reason != "dailyLimitExceeded":                                 // permanent (architecture §4.7 row 6)
                        _ = try OutboxRepository.discardModify(db, opId: op.id); Log.outbox.error("modify \(op.id) discarded: \(r)")
                    case .failure(.forbidden):                                                                                   // dailyLimitExceeded: pause until relaunch
                        try OutboxRepository.retryLater(db, opId: op.id, error: e, now: nowMs(), random: random()); stop = true; pausedForQuota = true
                    case .failure(.unauthorized), .failure(.offline), .failure(.cancelled):
                        try OutboxRepository.retryLater(db, opId: op.id, error: e, now: nowMs(), random: random()); stop = true      // attempts not counted (A5)
                    case .failure(let e) where e.isTransient:
                        if op.attempts >= Self.maxModifyAttempts { try OutboxRepository.fail(db, opId: op.id, error: e) }          // attempts already incremented by claim
                        else { try OutboxRepository.retryLater(db, opId: op.id, error: e, now: nowMs(), random: random()) }
                    case .failure(let e):
                        try OutboxRepository.fail(db, opId: op.id, error: e)                                                     // .decoding / .notFound-less leftovers (.historyExpired cannot occur); re-armed next foreground
                    } }
            if stop { break }
        if let s = try await db.write({ try OutboxRepository.claimSend($0, now: nowMs()) }):
            if await performSend(s) == .stop { break }
        if mods.isEmpty && s == nil { break }
    counts = try await db.read { try Queries.outboxCounts($0) }
    earliestDue = try await db.read { pendingModifies + pending sends → min(nextAttemptAt) where > now }      // via OutboxRepository.pendingModifies and Queries.failedSends? see A6
    await MainActor.run { status.pendingOps = counts.pending; status.failedSends = counts.failed; status.isOffline = sawOffline }
    if ackedAny, let sync = syncBox.withLock({ $0 }) { await sync.updateBadge() }
    if let due = earliestDue { scheduleWake(after: Double(due - nowMs()) / 1000) }
```
Only `.forbidden(reason: "dailyLimitExceeded")` is treated as a quota pause (architecture §6.2: "pauses the outbox until next launch"); every other `.forbidden` and every `.badRequest` is permanent → `discardModify` (reverts E, architecture §4.7 row 6). The whole `loop` body is wrapped in `do { … } catch { Log.outbox.error("drain aborted: \(error)"); break }` so a `DatabaseError` (locked DB in BG, `SQLITE_AUTH`) ends the drain without crashing; the claimed rows stay `inFlight` and are released by `releaseInFlight` at the next launch (or re-claimed by `claimModifies` if 06 treats stale `inFlight` rows as due — A20). `.unauthorized`: `AuthStore` was already flipped by the client's caller path? No — 05 never calls `AuthStore`; so the outbox does: `case .failure(.unauthorized)` additionally `await auth?`… the Outbox has no `AuthStore`; it delegates through the bound engine: `sync.noteUnauthorized()`? Simpler: `SyncEngine` exposes nothing; instead `Outbox` calls `await MainActor.run { status.lastError = GmailError.unauthorized.userMessage }` and the next `sync.run` (whose own request fails with 401) calls `markNeedsReauth`. DEVIATION D13 documents this; the reauth banner therefore appears after the next sync trigger, at the latest on the next foreground.

`sawOffline`: true when any part or the send failed with `.offline`; `status.isOffline` mirrors it (cleared when a later drain or run succeeds).

Row kinds are never mixed in one batch: `claimModifies` returns modify rows only; sends go one at a time through `claimSend` (`[gmail-api §14]`: never batched).

#### 4.5.3 `performSend(op)` (architecture §7.7)

```
performSend(op) -> SendOutcome:
    guard let json = op.sendJob, let job = try? JSONDecoder().decode(SendJob.self, from: Data(json.utf8)) else {
        try await db.write { try OutboxRepository.fail($0, opId: op.id, error: .decoding("sendJob")) }; return .continue }
    if op.transmitState == .maybeSent:                                                                       // [gmail-api §14 idempotency], architecture §14 #9/#25
        do {
            found = try await gmail.listMessages(labelIds: [], q: "rfc822msgid:\(job.messageID)", maxResults: 1, pageToken: nil)
            if !(found.messages ?? []).isEmpty {
                Log.outbox.notice("send \(op.id) already delivered (rfc822msgid)")
                try await db.write { try OutboxRepository.deleteSend($0, opId: op.id) }
                afterSend(); return .continue }
        } catch let e as GmailError where e == .offline || e == .unauthorized || e.isTransient {
            try await db.write { try OutboxRepository.retryLater($0, opId: op.id, error: e, now: nowMs(), random: random()) }; return .stop }
          catch { /* .badRequest on the search: proceed to send; duplicate risk logged as outbox.send.duplicate-risk */ Log.outbox.error("outbox.send.duplicate-risk \(op.id)") }
    (me, style, signature) = await identity()
    // §7.6 budget BEFORE any network call
    total = job.attachments.reduce(0) { $0 + $1.size }
    if total > Self.maxForwardAttachmentBytes {
        try await db.write { try OutboxRepository.fail($0, opId: op.id, error: .badRequest(reason: "attachmentsTooLarge", message: "Attachments too large to forward (\(mb(total)) MB)")) }
        return .continue }
    let atts: [OutgoingAttachment]
    switch await fetchAttachments(job) {
    case .success(let a): atts = a
    case .failure(.permanent(let text)): try await db.write { fail(op.id, .badRequest(reason: "attachmentUnavailable", message: text)) }; return .continue
    case .failure(.transient(let e)):    try await db.write { retryLater(op.id, e) }; return .stop
    }
    tz = TimeZone.current
    quoteHTML = job.mode == .replyAll ? Quoting.replyHTML(job.quoteSource, timeZone: tz) : Quoting.forwardHTML(job.quoteSource, timeZone: tz)
    quoteText = job.mode == .replyAll ? Quoting.replyText(job.quoteSource, timeZone: tz) : Quoting.forwardText(job.quoteSource, timeZone: tz)
    sig = job.includeSignature ? signature : nil
    html = OutgoingBodies.document(bodyFragment: OutgoingBodies.html(typed: job.typedText, style: style, signatureHTML: sig, quoteHTML: quoteHTML))
    text = OutgoingBodies.text(typed: job.typedText, signatureText: sig.map(Quoting.textFromHTML), quoteText: quoteText)
    bytes = MIMEBuilder.build(OutgoingMessage(from: me.primary, to: job.to, cc: job.cc, subject: job.subject, date: clock(), timeZone: tz,
                                              messageID: job.messageID, inReplyTo: job.inReplyTo, references: job.references,
                                              textBody: text, htmlBody: html, attachments: atts))                     // Date stamped at build time
    try await db.write { try OutboxRepository.setTransmitState($0, opId: op.id, .maybeSent) }                          // BEFORE the request leaves
    do {
        _ = try await gmail.send(raw: bytes, threadId: job.threadId)
        try await db.write { try OutboxRepository.deleteSend($0, opId: op.id) }
        afterSend(); return .continue
    } catch let e as GmailError {
        switch e {
        case .offline, .unauthorized, .cancelled:
            try await db.write { retryLater(op.id, e) }; return .stop                                                 // not counted (A5)
        case .network, .server, .rateLimited, .batchMalformed:
            if op.attempts >= Self.maxSendAttempts { try await db.write { fail(op.id, e) }; return .continue }
            try await db.write { retryLater(op.id, e) }; return .stop                                                 // next attempt starts with the rfc822msgid check
        default:
            try await db.write { fail(op.id, e) }; return .continue                                                    // 400 / 403 / decoding → Outbox section
        } }
afterSend(): if let sync = syncBox.withLock({ $0 }) { Task { await sync.run(.afterSend) } }                              // not awaited: drain must not wait for a sync
```
`mb(total)` = `String(format: "%.1f", Double(total) / 1_000_000)`. Every `db.write` in `performSend` that throws a `DatabaseError` is caught by `drain` (`Log.outbox.error`, outcome `.stop`).

`fetchAttachments(job)` (architecture §7.6; `[mime-rfc §6]`, `[gmail-api §6, gotcha 14]`):
```
    var out: [OutgoingAttachment] = []
    var reresolved = false
    for ref in job.attachments:
        var attId = ref.attachmentId
        var data: Data? = nil
        for round in 0..<2:
            if let id = attId {
                do { data = try await gmail.getAttachment(messageId: job.originalMessageId, attachmentId: id); break }
                catch GmailError.notFound { /* fall through to re-resolve */ }
                catch let e as GmailError where e == .offline || e == .unauthorized || e.isTransient || e == .cancelled { return .failure(.transient(e)) }
                catch let e as GmailError { return .failure(.permanent(e.userMessage)) }
            }
            if round == 0 && !reresolved:                                                                            // one messages.get?format=full&fields=payload per job
                do { m = try await gmail.getMessage(id: job.originalMessageId, format: .full, fields: "payload")
                     parsed = MessageParser.parse(m)
                     try await db.write { try BodyRepository.updateAttachmentIds($0, messageId: job.originalMessageId, parsed: parsed.attachments) }
                     attId = parsed.attachments.first { $0.partId == ref.partId }?.attachmentId; reresolved = true }
                catch GmailError.notFound { return .failure(.permanent("Original message no longer available")) }
                catch let e as GmailError where e == .offline || e == .unauthorized || e.isTransient || e == .cancelled { return .failure(.transient(e)) }
                catch let e as GmailError { return .failure(.permanent(e.userMessage)) }
            else: break
        guard let data else { return .failure(.permanent("Attachment \(ref.filename) no longer available")) }
        if data.count != ref.size { Log.outbox.notice("attachment size mismatch \(ref.partId): \(data.count) vs \(ref.size)") }   // continue
        out.append(OutgoingAttachment(filename: sanitizedFilename(ref.filename), mimeType: ref.mimeType, data: data))
    return .success(out)
```
`sanitizedFilename`: replaces `/`, `\`, control characters (U+0000…U+001F, U+007F) with `_`; a leading `.` becomes `_`; empty → `attachment`. `getMessage(id:format: .full, fields: "payload")` decodes a `GmailMessage` whose `id` is absent? — the DTO requires `id`; therefore the fields mask is `"id,payload"` (deviation from the architecture's literal `fields=payload`, D14). Attachments are never prefetched and never cached on disk by this module.

#### 4.5.4 `retrySend`, `discardSend`, `rearmFailedModifies`, `cancelAll`, `replaceDatabase`, `bind`

- `retrySend(id)`: `try? await db.write { try OutboxRepository.retrySend($0, opId: id) }` → `await drain()`.
- `discardSend(id)`: `try? await db.write { try OutboxRepository.deleteSend($0, opId: id) }` → refresh counts on main.
- `rearmFailedModifies()`: `try? await db.write { try OutboxRepository.rearmFailedModifies($0) }` → refresh counts.
- `cancelAll()`: `cancelRequested = true; kickTask?.cancel(); kickTask = nil; wakeTask?.cancel(); wakeTask = nil; if draining { await wait }`; cleared (`cancelRequested = false`) at the start of the next `drain()` that is started by `kick`/`sync`/`retrySend` **after** `replaceDatabase` — concretely `replaceDatabase` resets the flag.
- `replaceDatabase(db)`: precondition `!draining`; assigns; `cancelRequested = false; pausedForQuota = false`.
- `bind(sync:)`: `syncBox.withLock { $0 = sync }` — nonisolated, callable from `AppEnvironment.init` without an `await`.

Reads inside `drain` that are not repository calls: none. `decodeJSONArray(String?) -> [String]` is a private helper (`JSONDecoder` over the sorted JSON column; nil/invalid → `[]`).

### 4.6 `MailActions` (architecture §4.8 "Enqueue")

```
archive(threadId):    await modify(threadId, LabelDelta(add: [], remove: ["INBOX"]))
markRead(threadId):   await modify(threadId, LabelDelta(add: [], remove: ["UNREAD"]))
markUnread(threadId): await modify(threadId, LabelDelta(add: ["UNREAD"], remove: []))
private modify(threadId, delta):
    do {
        try await db.write { db in
            ids = try ThreadRepository.messageIds(db, threadId: threadId)                         // visible + hidden members present locally
            guard !ids.isEmpty else { return }
            _ = try OutboxRepository.enqueueModify(db, threadId: threadId, delta: delta, affectedMessageIds: ids, now: nowMs())   // coalesces; recomputes E + aggregates (A4)
        }
    } catch { Log.outbox.error("enqueue failed: \(error)") }
    await outbox.kick()
send(job):
    do { _ = try await db.write { try OutboxRepository.enqueueSend($0, job: job, now: nowMs()) } }
    catch { Log.outbox.error("enqueueSend failed"); return }
    var bgTask = UIBackgroundTaskIdentifier.invalid
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.minimail.send") { [bgTask] in UIApplication.shared.endBackgroundTask(bgTask) }   // [ios-platform §3.5]
    await outbox.drain()
    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
```
The `db.write` is GRDB's async form (hops to the writer queue; the main actor is not blocked). `ValueObservation`s in modules 09/10 tick from the same commit: the row disappears/flips on the next frame (architecture §12.1). `nowMs()` uses `Date()` (no clock injection on the façade; tests assert ordering, not timestamps). Toggling read → unread within 300 ms results in zero outbox rows and zero requests (`enqueueModify` returns nil; the debounced drain finds nothing).

### 4.7 `BackgroundRefresh` (architecture §4.10; `[ios-platform §3]`)

```
schedule():
    guard !AppEnvironment.isTestingProcess else { return }
    let req = BGAppRefreshTaskRequest(identifier: taskID); req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    Task.detached {                                                                              // "Do not call this method from the main thread" (iOS 27 doc)
        do { if #available(iOS 27, *) { try await BGTaskScheduler.shared.submitTaskRequest(req) } else { try BGTaskScheduler.shared.submit(req) } }
        catch { Log.bg.notice("schedule failed: \(error)") } }                                  // e.g. BGTaskScheduler.Error.unavailable in the simulator
run(env):
    schedule()                                                                                    // the request is consumed; re-arm first
    guard case .signedIn = env.auth.state else { Log.bg.notice("bg skipped: not signed in"); return }
    await env.sync.run(.background)                                                              // delta + throttled counts; no bodies; checkpoints between calls
    guard !Task.isCancelled else { return }
    await env.outbox.drain()
    guard !Task.isCancelled else { return }
    await env.sync.updateBadge()
```
Registration is the SwiftUI modifier in `MinimailApp` (§4.9); the closure returning completes the task; expiry cancels the task → `SyncEngine.checkpoint` / `GmailClient` throw `.cancelled` at the next network boundary; a `db.write` in progress completes (SQLite transactions are short). DB protection: `DatabaseError` with `resultCode == .SQLITE_AUTH` or `.SQLITE_IOERR` inside `run` is caught in `execute` (`lastError = "Database unavailable"`, `Log.db.error`) and the handler returns (architecture §4.10, §14 #12). Nothing else runs in the background: no timers, no `NWPathMonitor`, no background `URLSession` (D11, `[ios-platform §3.5]`).

### 4.8 `Maintenance.cleanup` (architecture §4.9)

```
cleanup(db, now):
    nowMs = ms(now)
    do {
        (historyId, lastDelta, lastCleanup, selfAddrs, views) = try await db.read { db in
            (get(.historyId), get(.lastDeltaSyncAt), get(.lastCleanupAt), selfAddresses(db), try LabelRepository.cachedViewLabelIds(db)) }
        guard historyId != nil, lastDelta != nil else { return }                                     // never before/during the first full sync
        if let c = Int64(lastCleanup ?? ""), nowMs - c < Int64(interval * 1000) { return }
        try await db.write { db in
            deletedThreads = try MaintenanceRepository.deleteExpiredThreads(db, cutoffMs: nowMs - Int64(threadMaxAge * 1000), protectedLabelIds: views)
            evicted = try MaintenanceRepository.evictBodies(db, keepNewest: bodiesKept)
            try ThreadRepository.recomputeAggregates(db, threadIds: evicted, selfAddresses: selfAddrs)  // bodiesMissing (invariant 6)
            deletedSends = try MaintenanceRepository.deleteOldFailedSends(db, cutoffMs: nowMs - Int64(failedSendMaxAge * 1000))
            try SyncStateRepository.set(db, .lastCleanupAt, String(nowMs))
            Log.db.notice("cleanup threads=\(deletedThreads) bodies=\(evicted.count) sends=\(deletedSends)") }
        removed = try await Task.detached { try purgeFiles(now: now, cacheRoot: cachesDirectory) }.value
    } catch { Log.db.error("cleanup failed: \(error)") }
```
`purgeFiles`: for each of `cacheRoot/attachments` and `cacheRoot/cid` (missing directory → skip): enumerate regular files (`FileManager.enumerator(at:includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])`), remove those with modification date `< now − fileMaxAge`, then remove directories left empty (deepest first). `tmp/attachments` is not touched here (the system purges `tmp/`, and module 10 deletes on dismiss). Statement 1 protects threads with a `thread_label` row for any cached-view label and threads referenced by a pending/inFlight outbox row (send rows via `json_extract(sendJob, '$.threadId')`). Statement 2 keeps attachment rows (harmless; `storeBody` replaces them on the next fetch) and never touches `attachmentId`. "Never during a full sync": the guard `historyId != nil` covers the first sync (historyId is written last); during a generation resync (historyId present) the run and the cleanup serialize on the writer and the cleanup's predicates only touch threads that are archived, read and > 30 days old — an acceptable overlap (§10 A7).

`MaintenanceRepository` SQL (the only SQL of this module, all parameters bound, id lists chunked by 500):
```sql
-- deleteExpiredThreads: 1) select victims
SELECT t.id FROM thread t
 WHERE t.inInbox = 0 AND t.unreadCount = 0 AND t.lastDate < :cutoff
   AND NOT EXISTS (SELECT 1 FROM thread_label tl WHERE tl.threadId = t.id AND tl.labelId IN (:protected…))
   AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.state IN ('pending','inFlight')
                   AND (o.threadId = t.id OR (o.kind = 'send' AND json_extract(o.sendJob, '$.threadId') = t.id)));
-- 2) per chunk of ids
DELETE FROM message      WHERE threadId IN (…);     -- cascades message_body, attachment (foreign keys ON, module 06)
DELETE FROM thread_label WHERE threadId IN (…);
DELETE FROM thread       WHERE id IN (…);
-- evictBodies
SELECT messageId FROM message_body ORDER BY fetchedAt DESC LIMIT -1 OFFSET :keep;
DELETE FROM message_body WHERE messageId IN (…);
UPDATE message SET bodyState = 0 WHERE id IN (…);
SELECT DISTINCT threadId FROM message WHERE id IN (…);
-- deleteOldFailedSends
DELETE FROM outbox WHERE kind = 'send' AND state = 'failed' AND createdAt < :cutoff;
```
When `protectedLabelIds` is empty the `thread_label` predicate is omitted (an empty `IN ()` is invalid SQL).

### 4.9 `AppEnvironment` and `MinimailApp` wiring (`[07]`)

`AppEnvironment.init(testing:)`, at the `// [05][07][08]` insertion point, after module 05's block (`gmail` exists) and before module 08's:
```swift
syncStatus = SyncStatus()
identitySource = OutboxIdentitySource(db: db, settings: settings)
let outbox = Outbox(db: db, gmail: gmail, status: syncStatus,
                    identity: { [identitySource] in await identitySource.current() },
                    random: { Double.random(in: 0..<1) })
let sync = SyncEngine(db: db, gmail: gmail, outbox: outbox, status: syncStatus,
                      settings: { [settings] in await settings.snapshot }, auth: auth)
outbox.bind(sync: sync)
self.outbox = outbox; self.sync = sync
actions = MailActions(db: db, outbox: outbox, sync: sync)
```
Hooks (module 04's step 9, the `// [07]` lines):
```swift
auth.hooks.prepareSignOut = { [sync, outbox] in await sync.cancelAll(); await outbox.cancelAll() }
auth.hooks.didSignIn = { [sync] in Task { await sync.run(.launch) } }
```
Wipe (`auth.hooks.wipeAccountData`, composed by module 06 with a `[07]` tail): after 06 has reopened the database into `self.db`: `identitySource.db = db; await sync.replaceDatabase(db); await outbox.replaceDatabase(db); actions = MailActions(db: db, outbox: outbox, sync: sync)`.

`startDeferredWork()` replacements:
```swift
// [07] step b
try? await db.write { try OutboxRepository.releaseInFlight($0) }        // a kill mid-request leaves state unknown → pending; maybeSent sends re-check first
await sync.run(.launch)
…
// [07] step d (+2 s, not in testing)
BackgroundRefresh.schedule()
await Maintenance.cleanup(db, now: Date())
await sync.updateBadge()
```
Construction only in `init` (actor inits allocate; `bind` takes a lock; no I/O, no `Task`), so the < 15 ms budget of architecture §12.2 is unaffected.

`MinimailApp`:
```swift
@Environment(\.scenePhase) private var scenePhase
…
WindowGroup {
    RootView().environment(env).environment(env.theme).environment(env.settings)
        // [04] .onOpenURL { _ = env.auth.resume(url: $0) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await env.outbox.setForeground(true) }
                if env.deferredWorkStarted { Task { await env.sync.run(.foreground) } }      // the launch path already runs .launch
            case .background:
                BackgroundRefresh.schedule()
                Task { await env.outbox.setForeground(false) }
            case .inactive: break
            @unknown default: break
            } }
}
.backgroundTask(.appRefresh(BackgroundRefresh.taskID)) { await BackgroundRefresh.run(env) }
```
`run(.foreground)` applies the 60 s throttle itself (§4.4.1), so this modifier needs no timestamp.

### 4.10 Error handling summary

| Source | Error | `SyncEngine` | `Outbox` |
|---|---|---|---|
| any request | `.offline` | run ends; `status.isOffline = true`; no `lastError` | `retryLater` uncounted; `stop`; `isOffline = true` |
| any request | `.unauthorized` | `auth.markNeedsReauth()`; run ends silently | `retryLater` uncounted; `stop`; `lastError = "Sign in again"` |
| `history.list` | `.historyExpired` | `fullSync()` in the same run | — |
| history | > 5,000 records | `fullSync()` in the same run | — |
| any | 3rd consecutive `.rateLimited` | run aborted; `lastError = "Rate limited — try again later"` | per op: `retryLater` (counted) |
| `getProfile` | e-mail mismatch | `auth.handleAccountMismatch`; run aborted | — |
| `messages.get` part | `.notFound` | dropped silently | (bodies) message deleted |
| `threads.get` | `.notFound` | thread's messages deleted; no throw | — |
| `threads.modify` part | `.notFound` | — | `ackModify(nil)` |
| `threads.modify` part | `.badRequest` / non-quota `.forbidden` | — | `discardModify` (E reverts) + `Log.outbox.error` |
| `threads.modify` part | `.forbidden("dailyLimitExceeded")` | — | `retryLater` uncounted; `stop`; paused until relaunch |
| `threads.modify` part | transient (`.network`, `.server`, `.rateLimited`, `.batchMalformed`) | — | `retryLater` counted; `failed` after 8 |
| `threads.modify` part | `.decoding`, `.historyExpired` (impossible) | — | `fail` (silent; re-armed on foreground) |
| `messages.send` | transient | — | `retryLater` counted (next attempt begins with `rfc822msgid:`); `failed` after 5 |
| `messages.send` | `.badRequest` / `.forbidden` / `.decoding` | — | `fail` → Outbox section |
| `attachments.get` | `.notFound` twice | — | job `fail` "Attachment … no longer available" |
| GRDB | `DatabaseError` | `lastError = "Database unavailable"`, logged | drain stops, logged |
| any | `CancellationError` / `.cancelled` | silent | silent (`retryLater` uncounted) |

---

## 5. Data

### 5.1 `syncState` keys written by this module

| `SyncKey` | Writer | Value format |
|---|---|---|
| `historyId` | `fullSync` (profile value), `deltaSync` (max), `requestFullResync` (nil) | decimal `UInt64` string, e.g. `"1234530"` |
| `syncGeneration` | `fullSync` | decimal `Int`, e.g. `"3"` |
| `lastFullSyncAt`, `lastDeltaSyncAt`, `lastLabelCountsAt`, `lastCleanupAt` | `fullSync` / `deltaSync` / `refreshLabelCounts` / `Maintenance.cleanup` | epoch ms decimal string |
| `accountEmail` | `fullSync` | verbatim `GmailProfile.emailAddress` |
| `displayName` | `fullSync` | `sendAs.displayName` of the default (else primary) alias; nil when absent |
| `selfAddresses` | `fullSync` | sorted JSON `["m.mustermann@example.com","max.mustermann@example.com"]`, lowercased |
| `sendAsSignature` | `fullSync` | raw HTML of the default/primary alias signature; nil when absent |
| `inboxNextPageToken` | `fullSync`, `loadOlderInbox` | verbatim token; nil when exhausted |

### 5.2 Outbox row contents produced through the repositories

Modify row (via `enqueueModify`): `kind = 'modify'`, `state = 'pending'`, `threadId`, `addLabelIds`/`removeLabelIds` sorted JSON (`["UNREAD"]`, `[]`), `affectedMessageIds` JSON of `ThreadRepository.messageIds`. Send row (via `enqueueSend`): `kind = 'send'`, `sendJob` = `JSONEncoder` (`.sortedKeys`) of `SendJob`, `rfc822MessageId = job.messageID`, `transmitState = 'notSent'`. Example `sendJob` (formatting added):
```json
{"attachments":[{"attachmentId":"ANGjdJ8w","filename":"invoice.pdf","mimeType":"application/pdf","partId":"1","size":38211}],
 "cc":[],"includeSignature":true,"inReplyTo":"<orig@example.com>","messageID":"<8E9C5D0A-1C2B-4E6F-9A11-000000000001@example.com>",
 "mode":"forward","originalMessageId":"18f2c1a2b3c4d5e6",
 "quoteSource":{"author":{"addr":"alice@example.com","name":"Alice"},"cc":[],"date":757580000,"html":"<div>Original</div>","subject":"Invoice 42","text":"Original","to":[{"addr":"me@example.com","name":null}]},
 "references":["<orig@example.com>"],"subject":"Fwd: Invoice 42","threadId":"18f2c1a2b3c4d5e6","to":[{"addr":"bob@example.com","name":"Bob"}],"typedText":"FYI"}
```
(`date` encodes as `Date`'s default `timeIntervalSinceReferenceDate` double; module 06 owns the encoder — this module only decodes with `JSONDecoder()` defaults, so both sides must keep default date strategies.)

### 5.3 Requests issued (exact shapes; produced by module 05, listed here as the module's network contract)

| Step | Request |
|---|---|
| full sync | `GET profile`, `GET settings/sendAs`, `GET labels`, `GET messages?labelIds=INBOX&maxResults=100&prettyPrint=false`, then per 25 ids one `POST https://www.googleapis.com/batch/gmail/v1` of `GET /gmail/v1/users/me/messages/{id}?format=metadata&metadataHeaders=From&…&fields=id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers&prettyPrint=false`, then per cached label view `GET messages?labelIds={id}&maxResults=50` + batches, then the delta |
| delta | `GET history?startHistoryId={h}&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted&historyTypes=labelAdded&historyTypes=labelRemoved[&pageToken=…]&fields=…&prettyPrint=false` (+ pages), then metadata batches for `toFetch` |
| thread open (incomplete) | `GET threads/{id}?format=full&prettyPrint=false` |
| thread open (bodies) | batches of ≤ 10 `GET /gmail/v1/users/me/messages/{id}?format=full&prettyPrint=false` |
| deferred text part | `GET messages/{id}/attachments/{attachmentId}?prettyPrint=false` |
| counts | `GET labels`, then one batch of ≤ 60 `GET /gmail/v1/users/me/labels/{id}?prettyPrint=false` (2–3 chunks of 25) |
| outbox modify | one batch of ≤ 25 `POST /gmail/v1/users/me/threads/{threadId}/modify?prettyPrint=false` with `{"addLabelIds":[…],"removeLabelIds":[…]}` (empty arrays omitted) |
| send check | `GET messages?q=rfc822msgid:%3C…%3E&maxResults=1&prettyPrint=false` |
| send | `POST messages/send?prettyPrint=false` `{"raw":"…","threadId":"…"}` |
| forward attachment | `GET messages/{originalMessageId}/attachments/{attachmentId}?prettyPrint=false`; on 404: `GET messages/{originalMessageId}?format=full&fields=id,payload&prettyPrint=false` once, then the attachment again |

### 5.4 Constants

| Constant | Value | Where |
|---|---|---|
| metadata batch size | 25 (`GmailClient.batchChunkSize`) | `hydrateMetadata` |
| body batch size | 10 | `loadThread` |
| inbox page size | `Settings.inboxPageSize` (100 default, 50…200) | `fullSync`, `loadOlderInbox` |
| label view page size | 50 | `hydrateLabelViewIfStale`, `loadOlderLabel`, `fullSync` |
| label counts cap | 60 labels | `refreshLabelCounts` |
| `labelCountsStaleness` | 300 s | `refreshLabelCounts`, module 12 |
| `foregroundThrottle` | 60 s | `execute(.foreground)` |
| `labelViewMaxAge` | 86,400 s | `hydrateLabelViewIfStale` |
| `maxHistoryRecords` | 5,000 | `deltaSync` |
| rate-limit abort | 3 consecutive `.rateLimited` | `noteResult` |
| `Outbox.kickDelay` | 0.3 s | `kick` |
| `Outbox.claimLimit` | 25 | `drain` |
| `Outbox.maxModifyAttempts` / `maxSendAttempts` | 8 / 5 | `drain` / `performSend` |
| `Outbox.maxForwardAttachmentBytes` | 20,000,000 | `performSend`, module 11 |
| `Backoff.transient` / `.outbox` | 1→16 s / 2→300 s, ±25 % | 05 (formula copy) / `OutboxRepository.retryLater` |
| BG `earliestBeginDate` | now + 900 s | `BackgroundRefresh.schedule` |
| `Maintenance.interval` / `threadMaxAge` / `bodiesKept` / `fileMaxAge` / `failedSendMaxAge` | 86,400 s / 30 d / 2,000 / 7 d / 30 d | `Maintenance` |
| bg task name | `com.minimail.send` | `MailActions.send` |

### 5.5 Log lines (category, level, template; ids public, text private per architecture §6.5)

| Category | Level | Template |
|---|---|---|
| `sync` | notice | `run skipped: not signed in`, `sync.history.expired`, `run \(reason) done in \(ms) ms` |
| `sync` | error | `hydrate \(id) \(error)`, `run \(reason) failed: \(error)` |
| `web` | error | `web.sanitize.failed \(messageId)` |
| `outbox` | notice | `send \(id) already delivered (rfc822msgid)`, `attachment size mismatch \(partId): \(n) vs \(m)`, `drain: \(acked) acked, \(retried) retried, \(failed) failed` |
| `outbox` | error | `modify \(id) discarded: \(error)`, `send \(id) failed: \(error)`, `outbox.send.duplicate-risk \(id)`, `enqueue failed: \(error)` |
| `bg` | notice | `bg skipped: not signed in`, `schedule failed: \(error)`, `bg refresh done` |
| `db` | notice / error | `cleanup threads=\(n) bodies=\(n) sends=\(n)` / `cleanup failed: \(error)`, `database unavailable: \(code)` |

Signposts: `fullSync`, `deltaSync`, `hydrateBatch` (per batch), `threadOpen`, `bodyLoad` (per body batch), `outboxDrain` (per drain).

---

## 6. UI

Not a screen module. The only user-visible surfaces are the `SyncStatus` fields (rendered by modules 09/13) and the `lastError` strings: `GmailError.userMessage` values (spec 05 §4.1.3), `"Database unavailable"`, and the failed-send `lastError` texts stored by `OutboxRepository.fail` (`GmailError.userMessage`, `"Attachments too large to forward (x.y MB)"`, `"Attachment <name> no longer available"`, `"Original message no longer available"`) that module 09 shows as "Not sent — <short error>". No SF Symbols, fonts, haptics or navigation are defined here.

---

## 7. Tests

Package tests run with `cd Packages/MailCore && swift test` (Linux and macOS). App tests run with `make test-app` / `make test-one T=minimailTests/<Class>/<test>` on the macOS runner. Every app test calls `harness.assertInvariants()` after its last write (architecture §3.5) and `StubURLProtocol.reset()` in `setUp`. `now` is frozen at `2026-09-11T10:00:00Z` (`1_757_584_800_000` ms) unless stated. Seed ids: `a1`, `b1`, `c1` (threads = ids), labels `["INBOX","UNREAD"]` unless stated; `a1`'s thread is `isComplete = 1` via `ThreadRepository.markComplete` in `seed`.

### 7.1 MailCore

| Test file | Test | Setup | Assertions |
|---|---|---|---|
| `Tests/MailCoreTests/HistoryReducerTests.swift` | `testEmptyPages` | `reduce([])` | `== HistoryChanges()`; `newHistoryId == nil` |
| same | `testEmptyHistoryKeepsHistoryId` | `history.empty.json` | `recordCount == 0`; `newHistoryId == 2000`; all collections empty |
| same | `testAdded` | `history.added.json` | `added["n1"]?.labelIds == ["UNREAD","INBOX"]`; `finalLabels["n1"] == ["UNREAD","INBOX"]`; `touchedThreads == ["n1"]`; `deleted.isEmpty` |
| same | `testDeleted` | `history.deleted.json` | `deleted == ["a1"]`; `added.isEmpty`; `touchedThreads == ["a1"]` |
| same | `testLabelsChronologicalAndFinal` | `history.labels.json` | `labelOps["a1"] == [LabelDelta(add: [], remove: ["UNREAD"])]`; `finalLabels["a1"] == ["INBOX"]`; `labelOps["b1"] == [LabelDelta(add: ["Label_12"], remove: [])]`; `finalLabels["b1"] == ["INBOX","Label_12"]`; `newHistoryId == 2004`; `recordCount == 2` |
| same | `testMixed` | `history.mixed.json` | `added.keys == ["n2"]`; `labelOps["a1"] == [LabelDelta(add: [], remove: ["INBOX"])]`; `finalLabels["a1"] == ["UNREAD"]`; `deleted == ["c1"]`; `touchedThreads == ["n2","a1","c1"]`; `newHistoryId == 2010` |
| same | `testAddedThenDeletedCancels` | `history.added-then-deleted.json` | `added.isEmpty`; `deleted == ["n3"]`; `finalLabels["n3"] == nil`; `labelOps["n3"] == nil` |
| same | `testDeletedThenAddedReadds` | inline pages: record deleted `x1`, record added `x1` labels `["INBOX"]` | `added["x1"] != nil`; `deleted.isEmpty` |
| same | `testMultiPage` | `[paged-1, paged-2]` | `added["n4"] != nil`; `labelOps["n4"] == [LabelDelta(add: ["STARRED"], remove: [])]`; `finalLabels["n4"] == ["INBOX","UNREAD","STARRED"]`; `newHistoryId == 2025`; `recordCount == 2` |
| same | `testOwnEchoWithoutLabelIds` | `history.own-modify-echo.json` | `finalLabels["a1"] == ["INBOX"]`; `finalLabels["b1"] == nil`; `labelOps["b1"] == [LabelDelta(add: [], remove: ["INBOX"])]` |
| same | `testTrashIsLabelChange` | `history.trash.json` | `deleted.isEmpty`; `labelOps["b1"] == [LabelDelta(add: ["TRASH"], remove: []), LabelDelta(add: [], remove: ["INBOX"])]`; `finalLabels["b1"] == ["TRASH","UNREAD"]` |
| same | `testLastAddedWins` | two `messagesAdded` for `y1`: labels `["INBOX"]` then `["INBOX","STARRED"]` | `added["y1"]?.labelIds == ["INBOX","STARRED"]`; `finalLabels["y1"] == ["INBOX","STARRED"]` |
| same | `testMentionedIds` | `history.mixed.json` | `mentionedIds == ["n2","a1","c1"]` |
| same | `testRecordWithoutChangesCounts` | inline page with one record `{"id":"1"}` | `recordCount == 1`; everything else empty; `newHistoryId` = page value |
| `Tests/MailCoreTests/HydrationPolicyTests.swift` | `testNilLabelsFetches` | `ref(labelIds: nil)`, empty scope | `true` |
| same | `testKnownThreadFetches` | labels `["SPAM"]`, thread `t1`, scope known `["t1"]` | `true` |
| same | `testInboxFetches` | labels `["INBOX"]`, scope cached `["INBOX"]` | `true` |
| same | `testCachedLabelFetches` | labels `["Label_12"]`, scope cached `["INBOX","Label_12"]` | `true` |
| same | `testSpamOnlySkipped` | labels `["SPAM","UNREAD"]`, cached `["INBOX"]`, known `[]` | `false` |
| same | `testEmptyLabelsSkipped` | labels `[]` | `false` |
| same | `testNilThreadIdNotKnown` | `threadId nil`, labels `["Label_9"]`, known `["x"]` | `false` |
| same | `testSentReplyInKnownThread` | labels `["SENT"]`, thread `t1` known | `true` |
| `Tests/MailCoreTests/BackoffTests.swift` | `testTransientTable` | `random 0.5`, attempts 1…6 | `[1,2,4,8,16,16]` |
| same | `testOutboxTable` | attempts 1…10 | `[2,4,8,16,32,64,128,256,300,300]` |
| same | `testJitterBounds` | attempt 3 outbox, random 0 and 0.999 | `6.0` and `≈ 9.998` (accuracy 0.01); random 0.5 → `8` |
| same | `testRetryAfterWins` | `retryAfter: 42`, attempt 9, random 0 | `== 42` (uncapped, unjittered) |
| same | `testAttemptZeroTreatedAsOne` | attempt 0 and −3 | both `== delay(attempt: 1)` |
| same | `testCapReached` | outbox attempt 50 | `300` |
| same | `testEquatable` | `Backoff.transient == Backoff(base: 1, factor: 2, cap: 16, jitter: 0.25)` | `true` |

### 7.2 App tests — `SyncEngineTests.swift`

Routes use `BatchStub.install`. "profile" = `JSONFixtures.profile(email: "me@example.com", historyId: 5000)`; "sendAs" = fixture `sendas.list.json`; "labels" = fixture `labels.list.json`.

| Test | Setup | Assertions |
|---|---|---|
| `testFullSyncRequestSequence` | empty DB; routes: profile, sendAs, labels, `GET /gmail/v1/users/me/messages` → `messageList(["m1"…"m30"], next: "p2")`, parts → metadata for each id, history → `history(records: [], historyId: 5000)`; `run(.launch)` | recorded non-batch paths in order: `profile`, `settings/sendAs`, `labels`, `messages`, then batches, then `history`, then `labels` (counts) + labels batch; `BatchStub.batchCount == 2` (25 + 5) before history; `message` rows == 30; `thread` rows == 30; `syncState.historyId == "5000"`, `syncGeneration == "1"`, `inboxNextPageToken == "p2"`, `accountEmail == "me@example.com"`, `selfAddresses` contains the sendAs alias; `status.phase == .idle`, `lastError == nil`, `lastSyncAt != nil` |
| `testFullSyncProgressiveCommits` | as above with 30 ids; the second batch part responder answers with `delay: 0.3` (via the route's response `delay`) | a concurrent `db.read` count of `message` polled every 50 ms observes `25` before `30` |
| `testInitialSyncPhase` | empty DB; observe `status.phase` transitions via a `withObservationTracking` loop | sequence contains `.initialSync` then `.idle`; second `run(.pullToRefresh)` (historyId present) shows `.syncing` |
| `testDeltaAddedFetched` | seeded `a1`; `historyId 1000`; history → `history.added.json` bytes; parts → metadata `n1` | one batch POST with one part `messages/n1?format=metadata…`; `message n1` exists with `serverLabelIds == ["INBOX","UNREAD"]`; `thread n1.inInbox == 1`; `historyId == "2001"`; `lastDeltaSyncAt == now ms` |
| `testDeltaHistoryIdNeverDecreases` | seed `historyId 9000`; history page `historyId 2001` | after run `historyId == "9000"` |
| `testDeltaDeleted` | seed `a1`; history → `history.deleted.json` | `message a1 == nil`; `thread a1 == nil` |
| `testDeltaFinalLabelsWin` | seed `a1` labels `["INBOX","UNREAD"]`, `historyId 1000`; history → `history.labels.json` | `a1.serverLabelIds == ["INBOX"]` (final set beats the delta), `a1.isUnread == false`; `message b1 == nil` (unknown id; its delta adds `Label_12`, which is not a cached label, so it is not fetched); no batch POST; `historyId == "2004"` |
| `testDeltaUnknownMessageGainsInbox` | seed nothing; history: `labelsAdded` for `z1` with `labelIds: ["INBOX"]`, `labelIds` added `["INBOX"]`; parts → metadata `z1` | `message z1` exists (moved into scope from another client) |
| `testDeltaOpsWhenNoFinalLabels` | seed `b1` `["INBOX","UNREAD"]`; history → `history.own-modify-echo.json` | `b1.serverLabelIds == ["UNREAD"]` (delta applied), `inInbox == false` |
| `testHydrationPolicySkipsSpamOnly` | history: `messagesAdded s1` labels `["SPAM"]` | no batch POST; `message s1 == nil` |
| `testHydrationKnownThreadFetchesSent` | seed `a1`; history: `messagesAdded r1` thread `a1` labels `["SENT"]`; parts → metadata `r1` | `message r1` exists with `threadId a1`; `thread a1.messageCount == 2` |
| `testDeltaPagination` | seed `historyId 1000`; history route queue: `history.paged-1.json` then `history.paged-2.json`; parts → metadata `n4` with labels `["INBOX","UNREAD","STARRED"]` | two `history` requests, the second with `pageToken=hp2`; `n4.serverLabelIds == ["INBOX","STARRED","UNREAD"]` (from `messages.get`, no delta replay); `historyId == "2025"` |
| `testTooManyRecordsTriggersResync` | history page with 5,001 records (built inline) then routes for a full sync | `profile` requested after `history`; `syncGeneration == "2"` |
| `testHistory404Resync` | history → 404 `history.404.json` (route returns 404) then full-sync routes | `profile` requested; `historyId == "5000"` from profile; `lastError == nil` |
| `testHistory400InvalidResync` | history → 400 `error.400-invalid-history.json` | same as above |
| `testMetadata404Dropped` | history added `n1`; parts → 404 envelope for `n1` | `message n1 == nil`; `lastError == nil`; `historyId` advanced |
| `testForegroundThrottle` | `lastDeltaSyncAt = now − 30 s`; `run(.foreground)` | no `history` request; `run(.foreground)` after `advance(61)` → one `history` request |
| `testForegroundRearmsFailed` | seed a `failed` modify row; `lastDeltaSyncAt = now − 30 s`; `run(.foreground)` | row `state == pending`, `attempts == 0`; one batch POST (drain ran) |
| `testPullToRefreshForcesCounts` | `lastLabelCountsAt = now − 60 s`; `run(.pullToRefresh)` | `labels` requested twice (list + counts batch parts) |
| `testCountsThrottled` | `lastLabelCountsAt = now − 60 s`; `run(.launch)` | no labels batch; `advance(301)`; `refreshLabelCounts(force: false)` → batch with ≤ 60 parts; `label INBOX.threadsUnread` from `labels.get.inbox.json` |
| `testCountsSelection` | `labels.list.json` extended inline with a `labelHide` user label and 70 visible user labels | parts: `INBOX,STARRED,IMPORTANT,SENT` + 56 user ids (cap 60), hidden label absent |
| `testLabelOpenedHydratesOnce` | label `Label_12` row with `viewFetchedAt nil`; `messages?labelIds=Label_12` → `["l1"]`; parts → `l1`; `run(.labelOpened("Label_12"))` twice | one `messages?labelIds=Label_12` request total; `label.viewFetchedAt != nil`; `message l1` exists; `thread_label(Label_12, l1)` exists |
| `testLabelOpenedRehydratesAfter24h` | `viewFetchedAt = now − 25 h` | request issued |
| `testLoadOlderInbox` | `inboxNextPageToken = "p2"`; `messages?…pageToken=p2` → `["o1"]`, no next; `run(.loadOlderInbox)` | request query contains `pageToken=p2`; `inboxNextPageToken == nil`; `o1` exists; no `history` request |
| `testLoadOlderInboxWithoutToken` | token nil; `run(.loadOlderInbox)` | zero requests |
| `testLoadOlderLabel` | `Label_12.viewNextPageToken = "lp2"` | request with `labelIds=Label_12&maxResults=50&pageToken=lp2`; token cleared |
| `testEnsureThreadLoadedIncomplete` | seed `a1` `isComplete 0`; `threads/a1` → `thread(id: a1, messages: [full a1 html, full a2 html])`; `ensureThreadLoaded("a1")` | exactly one request (`threads/a1?format=full&prettyPrint=false`); `message_body` rows for `a1`,`a2`; `a1.bodyState == 1`; `thread a1.isComplete == 1`, `bodiesMissing == 0`, `messageCount == 2` |
| `testEnsureThreadLoadedCompleteBodies` | seed `a1` complete, `bodyState 0`; parts → full `a1` | one batch POST with 1 part `messages/a1?format=full`; body stored; `hasRemoteImages == false`; `darkStrategy == "plain"` |
| `testEnsureThreadLoadedNoop` | body cached with current `sanitizerVersion` | zero requests |
| `testEnsureThreadLoadedStaleSanitizer` | body row with `sanitizerVersion = Sanitizer.version − 1` | one batch; row rewritten with `Sanitizer.version` |
| `testEnsureThreadLoadedDedup` | slow `threads/a1` (delay 0.2); two concurrent calls | one request; both return |
| `testEnsureThreadLoaded404` | `threads/a1` → 404 | no throw; `message a1 == nil`; `thread a1 == nil` |
| `testEnsureThreadLoadedOfflineThrows` | `threads/a1` → transport `.notConnectedToInternet` | throws `GmailError.offline`; `status.isOffline == true` |
| `testDeferredTextPart` | full `a1` with no inline body and `deferredTextParts` (`text/plain`, `attachmentId "att1"`, charset `iso-8859-1`); `messages/a1/attachments/att1` → `attachment(bytes: "caf\u{E9}" latin-1)` | body html contains `café`; two requests (batch + attachment) |
| `testSanitizerFallbackToText` | full `a1` html of 2 MiB + 1 byte, text `"plain body"` | `bodyHtml` contains `plain body`, class `mm-plaintext` |
| `testSanitizerFallbackToSnippet` | full `a1` without html/text, snippet `"snip"` | body contains `snip` |
| `testNoBodyPayloadUnavailable` | part answers a `GmailMessage` with `payload` absent | `a1.bodyState == 2`; `thread.bodiesMissing == 0` |
| `testBodyFetchKeepsPendingRead` | seed `a1` unread; `actions.markRead("a1")` (no drain: stub offline for batch); then part → full `a1` with labels `["INBOX","UNREAD"]`; `ensureThreadLoaded` | `a1.serverLabelIds` contains `UNREAD`; `a1.labelIds` does NOT contain `UNREAD`; `thread.unreadCount == 0` (the SIMPLE race) |
| `testPausedWhenNeedsReauth` | `auth.markNeedsReauth()`; `run(.launch)` | zero requests; `phase == .idle` |
| `testUnauthorizedMarksReauth` | history → 401 twice (`error.401.json`) | `auth.state == .needsReauth("me@example.com")`; `lastError == nil` |
| `testOfflineSetsFlagNoError` | history → transport offline | `status.isOffline == true`; `lastError == nil`; next successful run → `isOffline == false` |
| `testRateLimitAbort` | empty DB; full-sync routes list 100 ids; every metadata batch part answers 429 (`error.429.json`, `Retry-After: 1`) so each chunk exhausts module 05's 3 re-send rounds and returns `.rateLimited` parts | `BatchStub.batchCount == 12` (3 chunks × 4 POSTs each), no 4th chunk, no `history` request; `status.lastError == "Rate limited — try again later"`; `syncState.historyId == nil`; `message` rows == 0 |
| `testAccountMismatchAborts` | `accountEmail = "other@example.com"`; profile `me@example.com`; historyId nil | `auth.state == .signedOut`; `auth.lastAuthError == .accountMismatch(expected: "other@example.com", got: "me@example.com")`; no `messages` request |
| `testSingleFlightRerun` | history delayed 0.2; `run(.launch)` and `run(.pullToRefresh)` concurrently | second call returns before the first finishes (elapsed < 0.1 s); total `history` requests == 2; `status.lastRunReason == .pullToRefresh` |
| `testBadgeOnlyWhenEnabled` | `showBadge false` → `updateBadge()`; then `showBadge true` with 3 unread inbox threads | `badgeCalls == []` then `[3]` |
| `testRequestFullResync` | seed `historyId 5000`, `lastFullSyncAt` set; full-sync routes | `profile` requested; `syncGeneration == "2"`; `status.phase` never `.initialSync` |
| `testCancelAllStopsRun` | history delayed 0.5; `run(.launch)` in a Task; after 0.1 s `cancelAll()` | `cancelAll` returns after the run; `isRunning == false`; `historyId` unchanged; `lastError == nil` |
| `testMaintenanceRunsAfterSuccessfulRun` | `lastCleanupAt nil`; expired thread seeded; successful delta | `lastCleanupAt != nil`; expired thread gone |

### 7.3 `ResyncTests.swift`

| Test | Setup | Assertions |
|---|---|---|
| `testNonRelistedRowsDeleted` | seed `a1`,`b1`,`c1` gen 1, historyId 5000; history → 404; full-sync routes list `["a1","b1"]` | `c1` deleted; `a1`,`b1` present with `syncGeneration == 2`; `thread c1 == nil` |
| `testOutboxReferencedRowsSurvive` | as above + pending modify op on `c1` (`actions.archive("c1")`, batch offline) | `c1` present (gen 1); op still pending; `c1.labelIds` ∌ INBOX (E intact) |
| `testSendReferencedRowSurvives` | pending send row with `originalMessageId c1` | `c1` present |
| `testBodiesOfRelistedSurvive` | `a1` has a body row | `message_body a1` present after resync |
| `testIsCompleteResetForThreadsThatLostMembers` | thread `t` with `a1` (relisted) and `a2` (not relisted), `isComplete 1` | `a2` deleted; `thread t.isComplete == 0`, `messageCount == 1` |
| `testCachedLabelViewsRehydrated` | `Label_12.viewFetchedAt` set; `messages?labelIds=Label_12` → `["l1"]` | request issued during resync; `viewFetchedAt` updated; `l1` present |
| `testDeltaFromNewBaseline` | profile historyId 7000; history after resync → empty page `historyId 7001` | `history` request uses `startHistoryId=7000`; final `historyId == "7001"` |
| `testGenerationIncrements` | two consecutive resyncs | `syncGeneration` `"2"` then `"3"` |
| `testLoadOlderTokenReplaced` | `inboxNextPageToken "old"`; list returns `next "new"` | `== "new"` |

### 7.4 `OutboxTests.swift`

`modifyOK(t)` = `modifyResponse(threadId: t, messages: [(t, ["INBOX"])])` (read acked). Ops are created through `actions`.

| Test | Setup | Assertions |
|---|---|---|
| `testArchiveEnqueuesAndDrains` | seed `a1`; `actions.archive("a1")`; parts → `modifyOK("a1")` with labels `["UNREAD"]`; `sleeps.first == 0.3` then drain | immediately after `archive`: `a1.labelIds == ["UNREAD"]`, `thread a1.inInbox == 0`, one pending row; after drain: zero rows; `a1.serverLabelIds == ["UNREAD"]`; `badgeCalls` non-empty when `showBadge`; batch part body `{"removeLabelIds":["INBOX"]}` |
| `testDebounceCoalescesBurst` | archive `a1`,`b1`,`c1` within 100 ms | one batch POST with 3 parts; `sleeps == [0.3]` |
| `testInverseOpsCancel` | `markRead("a1")` then `markUnread("a1")` | zero outbox rows; zero requests; `a1.labelIds` contains `UNREAD` |
| `testCoalesceArchiveAndRead` | `archive("a1")`, `markRead("a1")` | one row `removeLabelIds == ["INBOX","UNREAD"]`; one part |
| `testInFlightNotMerged` | batch delayed 0.3; `archive("a1")`; during flight `markUnread("a1")` | two rows (one inFlight, one pending); second part sent in the next loop iteration; final S = server response ∪ delta |
| `testMixedPartResults` | five ops; parts: `a1` 200, `b1` 404, `c1` 400 (`error.400` inline), `d1` 429 (`error.429.json`, after 05's rounds), `e1` 500 | `a1` acked (row gone, S updated); `b1` row gone, S unchanged; `c1` row gone, `c1.labelIds` contains INBOX again (E reverted); `d1`,`e1` rows `pending`, `attempts == 1`, `nextAttemptAt == now + 2000 ms` (random 0.5); `status.pendingOps == 2` |
| `testBackoffSchedule` | transient 500 on every drain; advance clock past `nextAttemptAt` and drain 8 times | `nextAttemptAt − now` sequence `[2,4,8,16,32,64,128]` s then state `failed` after the 8th; row never deleted; `a1.labelIds` still ∌ INBOX |
| `testOfflineNotCounted` | batch transport offline | row `pending`, `attempts == 0`, `status.isOffline == true`; drain stopped (`recorded.count == 1`) |
| `testUnauthorizedNotCounted` | batch → 401 ×2 | `attempts == 0`; `status.lastError == "Sign in again"` |
| `testDailyQuotaPauses` | part → 403 `dailyLimitExceeded` | row pending, `attempts == 0`; `isPausedForQuota == true`; a second `drain()` issues no request |
| `testFailedRearmedOnForeground` | row `failed`; `rearmFailedModifies()` | `pending`, `attempts 0`; `sync.run(.foreground)` drains it |
| `testPermanent4xxRevertsE` | part → 403 `insufficientPermissions` | row gone; E == S; `InvariantChecks` pass |
| `testWakeUpWhileForeground` | `setForeground(true)`; transient 500 | `sleeps` contains `≈ 2.0` (the wake) after the drain; after the sleeper resolves a second batch POST is recorded |
| `testNoWakeInBackground` | `setForeground(false)`; transient 500 | `sleeps` contains no wake entry |
| `testReleaseInFlightAtLaunch` | row `inFlight` seeded; `OutboxRepository.releaseInFlight` via harness; drain | row claimed again (`attempts` incremented from the seeded value) |
| `testAckUsesServerLabels` | response `messages: [(a1, ["INBOX","IMPORTANT"])]` for a read op | `a1.serverLabelIds == ["IMPORTANT","INBOX"]` |
| `testAckWithoutMessagesAppliesDelta` | response `{"id":"a1"}` (no messages) | `a1.serverLabelIds == delta(S)` |
| `testStatusCounts` | one pending modify (part → 200) + one seeded `failed` send row | after drain: `status.pendingOps == 0`, `status.failedSends == 1`; `Queries.outboxCounts` agrees |
| `testCancelAllAwaitsDrain` | batch delayed 0.3; `drain()` in a Task; `cancelAll()` after 0.05 | `cancelAll` returns after ≥ 0.25 s; `isDraining == false` |

### 7.5 `ConflictTests.swift` (architecture §13.3; `assertInvariants` after every step)

| Test | Steps | Final assertions |
|---|---|---|
| `test1ArchiveLocalUnreadRemoteAck` | seed `a1` `["INBOX"]` (read); `archive("a1")` (no drain: batch offline); delta with `labelsAdded UNREAD` final `["INBOX","UNREAD"]`; then batch → `modifyOK` with `["UNREAD"]`; drain | `E == ["UNREAD"]`; `S == ["UNREAD"]`; `thread a1` not in inbox, unread |
| `test2AckBeforeEcho` | `markRead("a1")`; drain → ack `["INBOX"]`; delta echo `labelsRemoved UNREAD` final `["INBOX"]` | `E == S == ["INBOX"]`; no outbox rows |
| `test3EchoBeforeAck` | `markRead("a1")`; delta echo first; then ack | same as test 2 |
| `test4ResyncWithPendingOp` | `archive("a1")` pending; history 404 → resync relists `a1` with `["INBOX","UNREAD"]`; then ack | after resync: `a1` present, `E ∌ INBOX`, op pending; after ack: `S ∌ INBOX` |
| `test5Op404ThenDeltaDeletes` | `archive("a1")`; part → 404; delta `messagesDeleted a1` | after 404: row gone, `a1` present with `E == S`; after delta: `a1 == nil` |
| `test6TwoRapidToggles` | `markRead`, `markUnread` within 300 ms; drain | zero requests; `E == S` |
| `test7LaterMessageUntouched` | `markRead("a1")` (affected `[a1]`); delta adds `a2` in thread `a1` labels `["INBOX","UNREAD"]`; ack for `a1` | `a2.labelIds` contains UNREAD; `thread a1.unreadCount == 1` |
| `test8BodyFetchDuringPendingRead` | `markRead("a1")`; `ensureThreadLoaded` body with `["INBOX","UNREAD"]`; then ack | `thread a1.unreadCount == 0` throughout |

### 7.6 `SendTests.swift`

`job()` = forward `SendJob` for `a1` (`quoteSource.html "<div>Original</div>"`, one attachment `partId "1"`, `attachmentId "att1"`, size 5) unless stated; `send.response.json` for `POST messages/send`; `attachments/att1` → `attachment(bytes: "hello")`.

| Test | Setup | Assertions |
|---|---|---|
| `testSendHappyPath` | `actions.send(job())` | requests in order: `attachments/att1`, `messages/send`; POST body JSON has `threadId == "a1"` and `raw` decodes to bytes containing `Subject: Fwd:`; row deleted; `sync` ran `.afterSend` (`status.lastRunReason == .afterSend` after settling); `sleeps` empty |
| `testTransmitStateSetBeforePost` | `messages/send` delayed 0.3; poll the row during flight | `transmitState == maybeSent` before the response arrives |
| `testMaybeSentFoundNoSecondPost` | row seeded `maybeSent`; `messages?q=rfc822msgid:` → `messageList(["sent1"])` | no `messages/send` request; row deleted; `.afterSend` ran |
| `testMaybeSentNotFoundResends` | search → `messageList([])` | `messages/send` requested once; row deleted |
| `testTransientSendRetriesWithCheck` | send → 500; advance 3 s; second drain: search → found | first drain: row `pending`, `attempts 1`, `maybeSent`, `nextAttemptAt == now + 2 s`; second drain: no POST |
| `testFailedAfterFiveAttempts` | send → 500 five times (advance between) | after the 5th: `state == failed`, `lastError == "Gmail server error"`; `status.failedSends == 1` |
| `testPermanent400Fails` | send → 400 | `failed` immediately; `lastError == "Request rejected"`; no retry; `Queries.failedSends` returns it |
| `testAttachmentReresolvedOn404` | `attachments/att1` → 404 then (after re-resolve) `attachments/att2` → bytes; `messages/a1?format=full&fields=id,payload` → full message whose part `1` has `attachmentId "att2"` | requests: `att1` (404), `messages/a1` (fields=id,payload), `att2`, `send`; `attachment(a1,"1").attachmentId == "att2"` |
| `testAttachmentGoneFailsJob` | 404 both times | `failed`; `lastError == "Attachment invoice.pdf no longer available"`; no `messages/send` |
| `testBudgetRefusedBeforeNetwork` | attachment size 25,000,000 | zero requests; `failed` with `lastError == "Attachments too large to forward (25.0 MB)"` |
| `testQuoteFromSnapshotAfterWipe` | `message_body a1` deleted (and `message a1` deleted) before the drain | `raw` (base64url-decoded, QP-decoded HTML part) contains `---------- Forwarded message ---------` and `<div>Original</div>`; the send succeeds (the quote never reads the cache) |
| `testDateStampedAtBuildTime` | enqueue at `harness.now = 2026-09-11T10:00:00Z`; `advance(3600)` before the drain | the `Date:` header of the decoded `raw` parses with `HeaderDate.parse` to `2026-09-11T11:00:00Z` (time-zone independent); the job's `quoteSource.date` is unchanged |
| `testSignatureIncludedWhenEnabled` | settings `signatureHTML "<b>Sig</b>"`, `includeSignature true` vs false | `raw` html part contains `gmail_signature` / does not |
| `testReplyAllUsesReplyQuoting` | `job(mode: .replyAll)` | html part contains `gmail_quote_container` and `wrote:`; `In-Reply-To:` header present |
| `testSendOfflineStopsUncounted` | send → transport offline | `attempts == 0`, `maybeSent`, `status.isOffline == true` |
| `testRetrySendResets` | row `failed`, attempts 5; `outbox.retrySend(id)` | `attempts 0`, then drained (POST recorded) |
| `testDiscardSend` | `outbox.discardSend(id)` | row gone; `status.failedSends == 0` |
| `testSendWrapsBackgroundTask` | `actions.send` on the simulator | completes without assertion failure (beginBackgroundTask returns a valid id or `.invalid`; both paths end the task) |

### 7.7 `MaintenanceTests.swift` and `BackgroundRefreshTests.swift`

| Test file | Test | Setup | Assertions |
|---|---|---|---|
| `MaintenanceTests.swift` | `testSkipsWithoutSync` | empty `syncState` | no writes; `lastCleanupAt == nil` |
| same | `testThrottle24h` | `lastCleanupAt = now − 1 h` | unchanged |
| same | `testDeletesExpiredThreads` | threads: `old` (archived, read, lastDate now − 31 d), `oldUnread` (unread), `oldInbox`, `oldLabeled` (thread_label `Label_12` cached view), `oldPending` (pending modify), `recent` | only `old` deleted (message, body, attachment, thread, thread_label rows gone) |
| same | `testEvictsBodiesBeyond2000` | 2,010 body rows with ascending `fetchedAt` | 10 oldest gone; their `bodyState == 0`; `thread.bodiesMissing` recomputed; invariants hold |
| same | `testDeletesOldFailedSends` | failed send `createdAt now − 31 d`, another `now − 1 d` | first gone, second kept |
| same | `testPurgeFiles` | temp `cacheRoot/attachments/m1/1/a.pdf` (mtime −8 d), `cid/x.png` (−1 d) | `purgeFiles` returns 1; `a.pdf` gone, `x.png` kept, empty `m1/1` and `m1` removed |
| same | `testWritesLastCleanupAt` | eligible | `lastCleanupAt == now ms` |
| `BackgroundRefreshTests.swift` | `testSkipsWhenSignedOut` | `AppEnvironment(testing: true)` with `auth.state == .signedOut` | `run(env)` issues zero requests |
| same | `testRunsDeltaDrainBadge` | signed-in harness env; history empty; pending modify op; `showBadge` true | recorded: `history`, batch POST; `badgeCalls.last == inboxUnread` |
| same | `testScheduleIsNoopInTests` | — | `schedule()` returns without touching `BGTaskScheduler` (no crash on the simulator, no pending request) |
| same | `testCancellationStopsBetweenCalls` | history delayed 0.3; `Task { await run(env) }` cancelled after 0.05 s | no batch POST after the history response; `status.phase == .idle` |

Test count: MailCore 29; app 47 (`SyncEngineTests`) + 9 + 20 + 8 + 18 + 7 + 4 = 113.

---

## 8. Tasks

- [ ] **T07.1 Backoff + HydrationPolicy** — files: `Packages/MailCore/Sources/MailCore/Sync/Backoff.swift`, `Sync/HydrationPolicy.swift`, `Tests/MailCoreTests/BackoffTests.swift`, `HydrationPolicyTests.swift`. Done when the §3.2/§3.3 signatures compile on Linux and the 15 tests pass. Verify: `cd Packages/MailCore && swift test --filter 'BackoffTests|HydrationPolicyTests' 2>&1 | tail -3` shows `Executed 15 tests, with 0 failures`.
- [ ] **T07.2 HistoryReducer** — files: `Sync/HistoryReducer.swift`, `Tests/MailCoreTests/HistoryReducerTests.swift`. Done when all 14 tests pass over module 03's `history.*.json` fixtures. Verify: `cd Packages/MailCore && swift test --filter HistoryReducerTests 2>&1 | tail -3` → `Executed 14 tests, with 0 failures`.
- [ ] **T07.3 SyncStatus + engine skeleton** — files: `minimail/Sync/SyncStatus.swift`, `minimail/Sync/SyncEngine.swift` (state, `run` single-flight, `execute` dispatch, `checkpoint`/`call`/`noteResult`/`report`, `cancelAll`, `replaceDatabase`, `updateBadge`, `systemBadge`), `minimailTests/Sync/SyncTestSupport.swift` (harness, `FixedTokenProvider`, `BatchStub`, `JSONFixtures`, `msg`), tests `testPausedWhenNeedsReauth`, `testSingleFlightRerun`, `testCancelAllStopsRun`, `testBadgeOnlyWhenEnabled`. Done when `make build` succeeds and the 4 tests pass with `fullSync`/`deltaSync` stubbed as `throw SyncError.paused`. Verify: `make test-one T=minimailTests/SyncEngineTests`.
- [ ] **T07.4 Full sync + hydration** — file: `SyncEngine.swift` (`fullSync`, `hydrateMetadata`, `deriveIdentity`), tests `testFullSyncRequestSequence`, `testFullSyncProgressiveCommits`, `testInitialSyncPhase`, `testAccountMismatchAborts`, `testMetadata404Dropped`. Verify: `make test-one T=minimailTests/SyncEngineTests`.
- [ ] **T07.5 Delta sync + resync** — file: `SyncEngine.swift` (`deltaSync`, `deltaOrResync`, `syncCore`), tests `testDelta*` (9), `testHydration*` (2), `testTooManyRecordsTriggersResync`, `testHistory404Resync`, `testHistory400InvalidResync`, `testForegroundThrottle`, `testRequestFullResync`, and `minimailTests/Sync/ResyncTests.swift` (9). Verify: `make test-one T=minimailTests/SyncEngineTests && make test-one T=minimailTests/ResyncTests`.
- [ ] **T07.6 Label views, load older, counts** — file: `SyncEngine.swift` (`hydrateLabelViewIfStale`, `loadOlderInbox`, `loadOlderLabel`, `refreshLabelCounts`), tests `testLabelOpened*` (2), `testLoadOlder*` (3), `testCounts*` (3), `testPullToRefreshForcesCounts`. Verify: `make test-one T=minimailTests/SyncEngineTests`.
- [ ] **T07.7 ensureThreadLoaded + prepareBody** — file: `SyncEngine.swift` (`ensureThreadLoaded`, `loadThread`, `prepareBody`), tests `testEnsureThreadLoaded*` (7), `testDeferredTextPart`, `testSanitizerFallback*` (2), `testNoBodyPayloadUnavailable`, `testBodyFetchKeepsPendingRead`. Requires module 08's `Sanitizer` (until then the test target may skip with `XCTSkip` when `Sanitizer.version` is unavailable — do not stub it). Verify: `make test-one T=minimailTests/SyncEngineTests`.
- [ ] **T07.8 Outbox drain + MailActions** — files: `minimail/Sync/Outbox.swift` (all but `performSend`/`fetchAttachments`), `minimail/Sync/MailActions.swift`, `OutboxIdentitySource`, tests `minimailTests/Sync/OutboxTests.swift` (20) and `ConflictTests.swift` (8). Verify: `make test-one T=minimailTests/OutboxTests && make test-one T=minimailTests/ConflictTests`.
- [ ] **T07.9 performSend + attachments** — file: `Outbox.swift` (`performSend`, `fetchAttachments`, `sanitizedFilename`, `afterSend`), tests `minimailTests/Sync/SendTests.swift` (18). Verify: `make test-one T=minimailTests/SendTests`.
- [ ] **T07.10 Maintenance** — files: `minimail/Store/MaintenanceRepository.swift`, `minimail/App/Maintenance.swift`, tests `minimailTests/Sync/MaintenanceTests.swift` (7), plus `testMaintenanceRunsAfterSuccessfulRun`. Verify: `make test-one T=minimailTests/MaintenanceTests`; `grep -c 'DELETE\|UPDATE\|SELECT' minimail/App/Maintenance.swift` prints `0`.
- [ ] **T07.11 BackgroundRefresh + app wiring** — files: `minimail/App/BackgroundRefresh.swift`, `minimail/App/AppEnvironment.swift` (`[07]` insertions, hooks, wipe tail, `startDeferredWork` steps b/d), `minimail/App/MinimailApp.swift` (`.backgroundTask`, scene phase), tests `minimailTests/Sync/BackgroundRefreshTests.swift` (4). Verify: `make build && make test-one T=minimailTests/BackgroundRefreshTests`; `grep -n 'backgroundTask(.appRefresh' minimail/App/MinimailApp.swift` prints one line.
- [ ] **T07.12 Whole-module pass** — no new files. Done when `make lint` passes (no `import GRDB` outside `Store/`/`Sync/`/`App/`, no SQL keywords in `minimail/Sync/*` and `minimail/App/*`: `! grep -rnE '"(SELECT|INSERT|UPDATE|DELETE) ' minimail/Sync minimail/App`), `make core-test` and `make test-app` report `failedTests: 0`, and every §9 criterion is checked off. Verify: `make lint && make core-test && make test-app`.

---

## 9. Acceptance criteria

1. `HistoryReducer.reduce` reproduces the §7.1 table for all ten `history.*.json` fixtures and the inline cases; `HydrationPolicy` matches the §4.2 matrix; `Backoff` yields `[1,2,4,8,16,16]` / `[2,4,8,…,300]`. Verify: `cd Packages/MailCore && swift test --filter 'HistoryReducerTests|HydrationPolicyTests|BackoffTests'` → 29 tests, 0 failures (Linux and macOS).
2. First launch with an empty cache performs exactly `profile`, `settings/sendAs`, `labels`, `messages?labelIds=INBOX&maxResults=100`, ⌈n/25⌉ metadata batches (each committed separately), one `history` request, `labels` + one counts batch — and nothing else (`testFullSyncRequestSequence`, `testFullSyncProgressiveCommits`).
3. An idle delta is exactly one `history.list` request; `historyId` never decreases; a 404 or 400-`failedPrecondition` on history performs a generation resync that keeps outbox-referenced rows and the bodies of relisted messages and deletes non-relisted rows (`ResyncTests`, `testDeltaHistoryIdNeverDecreases`).
4. Opening an incomplete thread issues exactly one `threads.get?format=full`; a complete thread with cached, current-version bodies issues zero requests; bodies are never fetched by `run(_)` of any reason (`testEnsureThreadLoaded*`, `testRunsDeltaDrainBadge` records no `format=full` request).
5. A swipe archive flips the row in the same transaction as the outbox insert (`E` updated before `kick` returns) and reaches Gmail as one `threads.modify` part inside a batch 300 ms later; read→unread within the debounce produces zero network calls (`testArchiveEnqueuesAndDrains`, `testInverseOpsCancel`, `testDebounceCoalescesBurst`).
6. `InvariantChecks.assertAll` holds after every step of the eight `ConflictTests` interleavings; a body fetch during a pending mark-read never flips the thread back to unread (`test8BodyFetchDuringPendingRead`, `testBodyFetchKeepsPendingRead`).
7. Transient modify failures never delete an op: back-off 2→300 s ± 25 %, `failed` after 8 counted attempts, re-armed on foreground/pull; `offline`/`unauthorized`/`cancelled` do not count; permanent 4xx removes the op and reverts E (`testBackoffSchedule`, `testOfflineNotCounted`, `testFailedRearmedOnForeground`, `testPermanent4xxRevertsE`).
8. A send sets `transmitState = maybeSent` before the POST, retries only after a `rfc822msgid:` search, never POSTs twice when the search finds the message, stamps `Date` at build time, builds the quote from the job snapshot, refuses > 20,000,000 bytes of attachments before any request, and re-resolves an `attachmentId` exactly once on 404 (`SendTests`).
9. Sign-out: `prepareSignOut` returns only after the running sync and drain have stopped; afterwards no `db.write` from `SyncEngine`/`Outbox` occurs (`testCancelAllStopsRun`, `testCancelAllAwaitsDrain`). Reauth: while `auth.state == .needsReauth` no request is issued (`testPausedWhenNeedsReauth`).
10. Background refresh: the handler re-schedules first, skips when signed out, performs delta + drain + badge, checks cancellation between steps, never opens a web view or fetches bodies (`BackgroundRefreshTests`). Manual device step (module 14 checklist): pause in LLDB and run `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.minimail.refresh"]` (selector UNVERIFIED `[ios-platform §3.3]`); `log stream --predicate 'subsystem == "com.minimail" AND category == "bg"'` shows `bg refresh done` and exactly one `history` request in the `net` category.
11. `Maintenance.cleanup` runs at most once per 24 h, only after a successful sync, and applies exactly the three statements + file purge with the protections of §4.8 (`MaintenanceTests`); `minimail/App/Maintenance.swift` and `minimail/Sync/*` contain no SQL string (`make lint` grep in T07.12).
12. The app badge equals `Queries.inboxUnreadThreadCount` after every run, ack and BG refresh when `Settings.showBadge` is true and badge authorization is granted, and is never touched otherwise (`testBadgeOnlyWhenEnabled`; manual: enable the toggle in Settings, archive an unread thread, background the app → the icon badge decrements).
13. Full test suites: `make core-test` and `make test-app` finish with 0 failures; `make lint` passes.

---

## 10. Open questions & assumptions

| # | Question / UNVERIFIED item | Status | Assumption chosen |
|---|---|---|---|
| O1 | How module 06 reopens the database after a wipe (`Database.destroy` → new `DatabasePool`): does `AppEnvironment.db` become `var`? | open (spec 06 not written) | This spec requires `AppEnvironment.db` to be reassignable (`private(set) var db: any DatabaseWriter` or `DatabasePool`) and wires `replaceDatabase` on both actors, `identitySource.db`, and a rebuilt `MailActions` at the end of `wipeAccountData`. If 06 instead keeps one pool and truncates tables in place, the `[07]` wipe tail becomes a no-op and D6 stays harmless. |
| A1 | `OutboxRepository.retryLater(db, opId, error, now, random)` has no `countsAsAttempt` parameter (architecture §2.4) although §4.8 says uncounted errors "decrement back". | assumption for 06 | `retryLater` must: `state = pending`; `if !error.countsAsAttempt { attempts = max(0, attempts − 1) }`; `nextAttemptAt = now + Backoff.outbox.delay(attempt: attempts, retryAfter: error.retryAfter, random: random) × 1000` (uncounted errors: `attempts` may be 0 → delay 2 s, keeps a short pause before the next try). The 8/5 thresholds are decided by `Outbox` (§4.5.2/§4.5.3) using `op.attempts` as returned by `claim*`. |
| A2 | `OutboxRepository.fail(db, opId, error)` stores `lastError = error.userMessage` for `GmailError` and, for the synthetic `.badRequest(reason: "attachmentsTooLarge"/"attachmentUnavailable", message:)`, stores `message` instead. | assumption for 06 | Required so the Outbox row shows "Attachments too large to forward (25.0 MB)" (architecture §7.6). If 06 stores `userMessage` only, module 09 should prefer `message` of a `.badRequest` when present — flagged to 06/09. |
| A3 | `BodyRepository.storeBody(…, attachments:, referenced:)` derives `attachment.isInline = contentId ∈ referenced` and `hasAttachments` exact = any non-inline attachment. | assumption for 06 | Per architecture §4.5 `isInline(att) = att.contentId ∈ body.referencedContentIDs`. |
| A4 | `OutboxRepository.enqueueModify` performs both `recomputeEffective(affected)` and `ThreadRepository.recomputeAggregates` (architecture §4.8 pseudocode) so `MailActions` does not repeat them. | assumption for 06 | If 06 recomputes E only, `MailActions.modify` must add `ThreadRepository.recomputeAggregates(db, threadIds: [threadId], selfAddresses:)` — it would then need `selfAddresses` (read from `syncState` in the same write). |
| A5 | `GmailError.countsAsAttempt` is false for `.offline`, `.cancelled`, `.unauthorized` (spec 05 §4.1.3). | verified in spec 05 | Used to decide "uncounted" in §4.5.2; `.forbidden("dailyLimitExceeded")` counts per 05 but this spec routes it through `retryLater` with `stop` + pause; its `attempts` therefore increments by one per relaunch (acceptable, never reaches 8 in practice). |
| A6 | Earliest due time for the wake-up sleeper: `OutboxRepository.pendingModifies` returns pending modify rows; pending send rows are read with `OutboxRecord.filter(kind == send && state == pending).fetchAll` — a GRDB query-builder call (no SQL string). | assumption | Acceptable under this module's "no SQL strings" rule; if 06 provides `Queries.pendingSends` or `OutboxRepository.earliestPendingAt`, use it. |
| A7 | "Never during a full sync" for `Maintenance.cleanup` is enforced by `historyId != nil && lastDeltaSyncAt != nil` (first sync) and by serialization on the writer during a resync. | design choice | The overlap during a resync only affects archived, read, > 30-day-old, unreferenced threads, which the resync would delete anyway. |
| A8 | `history.list` change records carry `message.labelIds` (`[gmail-api §13]` SNIPPET). | UNVERIFIED | Both paths implemented (`finalLabels` wins, deltas otherwise); fixture `history.own-modify-echo.json` record 2031 exercises the absent case (`testDeltaOpsWhenNoFinalLabels`). |
| A9 | `ListHistoryResponse.historyId` present when `history` is empty. | UNVERIFIED (`[gmail-api §13 item 3]`) | `newHistoryId ?? start` keeps the old id; `history.empty.json` covers the present case. |
| A10 | 400 status for a malformed/expired `startHistoryId`. | UNVERIFIED (`[gmail-api §13.5]`) | Module 05 maps both 404 and 400-`failedPrecondition`/"historyId" to `.historyExpired`; the engine resyncs on either. |
| A11 | Quota unit table (`messages.get` 20, `threads.get` 40, 6,000/user/min). | UNVERIFIED (`[gmail-api "Quotas"]`) | Sizes designed for the pessimistic numbers; the only tunables are `Settings.inboxPageSize` and the body batch size (10). |
| A12 | `rfc822msgid:` index lag right after a send. | UNVERIFIED (architecture §14 #9) | The check runs ≥ 2 s after the failed attempt (backoff); a miss produces at most one duplicate, logged as `outbox.send.duplicate-risk` when the search itself errors. |
| A13 | `attachmentId` instability. | UNVERIFIED (`[gmail-api §6, gotcha 14]`) | Stored id first, exactly one re-resolve per job via `messages.get?format=full&fields=id,payload`. |
| A14 | `BGTaskScheduler.submitTaskRequest` async API on iOS 27 and the "not from the main thread" rule. | `[ios-platform §3.3]` (doc-verified for iOS 27) | Detached task with `#available(iOS 27, *)` branch; failure logged. The LLDB simulate selector is UNVERIFIED (checklist item). |
| A15 | `[.badge, .provisional]` behaviour. | UNVERIFIED (`[ios-platform §6]`) | Not used; `systemBadge` only checks `badgeSetting == .enabled` (module 13 requests `[.badge]`). |
| A16 | Background time budget ("a few tens of seconds"). | UNVERIFIED (`[ios-platform §3.4]`) | Checkpoints before every request and write; the handler returns after at most `history` + 2 metadata batches + one modify batch + one send. |
| A17 | GRDB `DatabaseReader` is `Sendable` in 7.11.1 (so `any DatabaseWriter` can be stored in actors and captured by `@Sendable` closures). | compile-time fact (`[ios-platform §2.5]` says pools/queues are Sendable) | If the existential is not Sendable, store `DatabasePool` in production and give the test harness a `DatabasePool` opened on a temporary file (`Database.open(directory: tmp)`) instead of `DatabaseQueue` — D1 then collapses to the verbatim signature. |
| A18 | `Sanitizer.fromPlainText("This message could not be displayed.")` stands in for the architecture's literal `<p><i>…</i></p>` (module 08's `SanitizedBody` memberwise init is not public). | design choice | Same text, plain-text styling; if 08 exposes `SanitizedBody.init`, switch to the literal markup. |
| A19 | `Settings.inboxPageSize` is read per run via the `settings` closure; a change in Settings applies to the next full sync / load-older page. | design choice | No live re-listing. |
| A20 | Rows left `inFlight` by a drain that aborted on a `DatabaseError` (or a process kill) are recovered only by `OutboxRepository.releaseInFlight` at launch. | assumption for 06 | `claimModifies`/`claimSend` select `state = 'pending'` only (architecture §2.4); this module calls `releaseInFlight` in `startDeferredWork` step b. A foreground `rearmFailedModifies` does not touch `inFlight` rows. |

### Deviations from architecture.md (all additive unless stated)

| # | Deviation | Reason |
|---|---|---|
| D1 | `init(db: any DatabaseWriter, …)` on `SyncEngine`, `Outbox`, `MailActions.db`, `Maintenance.cleanup(_:now:)` instead of `DatabasePool`. | Tests use `Database.openInMemory()` → `DatabaseQueue` (architecture §2.4, §13.1); both types are `DatabaseWriter`. Production still passes the pool. See A17 for the fallback. |
| D2 | New file `minimail/Store/MaintenanceRepository.swift` (not in the §1.3 tree), owned by this module. | modules.md forbids SQL in 07 and architecture §2.1 rule 3 confines writes to `Store/*Repository.swift`; 06's interface has no cleanup functions. |
| D3 | `SyncStatus.lastRunReason`. | Settings → Advanced status line and single-flight tests. |
| D4 | Extra defaulted parameters `badge:` (`SyncEngine.init`) and `sleep:` (`Outbox.init`); `Outbox.random` stays required as in the architecture. | Deterministic tests without `UNUserNotificationCenter` or real sleeping; architecture callers compile unchanged. |
| D5 | `SyncEngine.cancelAll()`, `Outbox.cancelAll()`. | Architecture §5.4 "cancel running sync/drain" and spec 04 `hooks.prepareSignOut` need an awaitable cancel. |
| D6 | `replaceDatabase(_:)` on both actors; `AppEnvironment.actions` and `identitySource.db` reassignable. | Sign-out destroys and reopens the DB (O1). |
| D7 | `SyncEngine.isRunning`, `Outbox.isDraining`. | Test visibility. |
| D8 | Extra test files `MaintenanceTests.swift`, `BackgroundRefreshTests.swift`, `SyncTestSupport.swift`. | Architecture §13.3 lists only the five sync test files; maintenance and BG behaviour need their own. |
| D9 | `Outbox.bind(sync:)` (nonisolated, lock-protected). | `SyncEngine.init` takes `outbox:` while the outbox needs `sync.run(.afterSend)`/`updateBadge()` — a construction cycle the verbatim signatures cannot express. |
| D10 | `Outbox.setForeground(_:)`. | Architecture §4.8 "while foregrounded the actor also sleeps until the earliest nextAttemptAt" needs the scene state. |
| D11 | `Outbox.isPausedForQuota` + pause until relaunch. | Architecture §6.2: `dailyLimitExceeded` "pauses the outbox until next launch". |
| D12 | `OutboxIdentitySource` (main-actor helper) behind the verbatim `identity:` closure. | The closure must read `syncState` (DB, replaceable) and `Settings` (main actor) without capturing `AppEnvironment` during its own `init`. |
| D13 | On `.unauthorized` inside a drain the outbox sets `status.lastError = "Sign in again"` instead of calling `AuthStore.markNeedsReauth()`. | The outbox has no `AuthStore`; the next `SyncEngine` request (every drain is followed by or follows a run) flips the state within seconds. |
| D14 | Forward re-resolve uses `fields=id,payload` instead of the architecture's `fields=payload`. | `GmailMessage.id` is non-optional in module 03's DTO. |
| D15 | `.foreground` throttling lives inside `SyncEngine.execute` rather than in `MinimailApp`. | Keeps the scene-phase handler stateless; the rule ("older than 60 s") is unchanged. |
