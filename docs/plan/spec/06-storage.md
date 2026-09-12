# 06-storage — Schema, records, repositories, queries, label algebra, aggregator, day boundary

Module 06 of `docs/plan/design/modules.md`. Sources of truth: `architecture.md` §2.2 (Sync/LabelAlgebra, Sync/OutboxCoalescer, Sync/ThreadAggregator, Support/DayBoundary), §2.4 ("Store" block, `ThreadQuery`/`ThreadRow`/`ThreadDetail`), §3 (data model, DDL, mapping, invariants), §4.7–§4.9 (what the repositories must make possible), §8.6 (filter SQL), §12.2 (launch order), §13.3 (tests). Research: `[ios-platform §2]` (GRDB 7.11.1 facts), `[gmail-api §10–11]` (labels), `[gmail-api gotcha 20]` ("Today" is local).

Depends on: **01-project-setup** (`Package.swift`, app skeleton, `AppEnvironment`, `Log.db`, `Formatters`), **03-mailcore-gmail-model** (`ParsedMessage`, `ParsedHeaders`, `ParsedAttachment`, `GmailLabel`, `GmailLabelColor`) and, transitively through 03, **02-mailcore-mime** (`Mailbox`, `SubjectPrefix.stripForDisplay`, `ComposeMode`, `QuoteSource`).

---

## 1. Purpose & scope

### 1.1 In scope

1. The SQLite schema (migration `v1`, byte-exact DDL of architecture §3.2) and the GRDB connection lifecycle: open (WAL pool, file protection, migrate), temporary/in-memory variants for tests, destroy, in-place reset for account wipe.
2. `Codable` + `FetchableRecord` + `PersistableRecord` structs for every table, plus the `SendJob`/`ForwardAttachmentRef` JSON shapes, `OutboxKind`/`OutboxState`/`TransmitState`, `SyncKey`.
3. Repositories (enums of static functions taking a GRDB `Database` so several compose inside **one** transaction): message (S/E writes), thread (aggregates), body, label, outbox (coalescing enqueue, claim/ack/discard/retry/fail/re-arm), sync state, and the three cache-bound statements of §4.9.
4. `Queries`: every `SELECT` the UI observes — list rows per scope (§8.6 SQL), thread detail, labels sheet, failed sends, counts.
5. Pure MailCore algorithms: `LabelAlgebra` (S ⊕ P = E, flags, sorted JSON, user-visible filter), `OutboxCoalescer.merge`, `ThreadAggregator.aggregate`, `DayBoundary`, `RowDateLabel`.
6. `SanitizedBody`/`DarkStrategy` value types in `MailHTML` (declaration only; the sanitizer that produces them is module 08).
7. Test support `TestDatabase` and `InvariantChecks` (§3.5 invariants) and the tests `DatabaseTests`, `RepositoryTests`, `QueriesTests`, `LabelAlgebraTests`, `OutboxCoalescerTests`, `ThreadAggregatorTests`, `DayBoundaryTests`.
8. `AppEnvironment` insertion: open the pool in launch step 1, expose `db`, fill `cachedEmail`, wire `auth.hooks.wipeAccountData`.

### 1.2 Explicitly out of scope

- Network: `GmailClient`, `URLSession` (05). No file in this module imports `AppAuth`, `WebKit`, `Security` or `SwiftSoup`.
- `SyncEngine`, `Outbox`, `MailActions`, `HistoryReducer`, `HydrationPolicy`, `Backoff`, `BackgroundRefresh`, `Maintenance` (07). This module provides the SQL those call; it decides nothing about *when* they run.
- `Sanitizer`, `ThreadDocument`, `WebViewHost` (08). `BodyRepository.storeBody` takes a `SanitizedBody` value; it never sanitizes.
- Every screen (09–13). `Queries.threads` returns fully precomputed `ThreadRow`s; the row view does `String → Text` only.
- `StubURLProtocol`, `FixtureLoader`, `SmokeTests`, the fixture catalog, device checklist (14). `TestDatabase` and `InvariantChecks` are created here (modules.md lists them under 06); 14 documents their conventions and may extend them.
- File caches (`Caches/attachments`, `Caches/cid`, `tmp/attachments`) — never touched by this module (08/10 own them).

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 04 `AuthStore` (via `AppEnvironment`) | `cachedEmail` read (`SyncStateRepository.get(db, .accountEmail)`), `auth.hooks.wipeAccountData` = `AppDatabase.reset(db)` |
| 07 `SyncEngine` | `MessageRepository.{upsertMetadata,applyServerLabels,applyServerDelta,recomputeEffective,delete,idsExisting,staleIds,threadIds(of:)}`, `ThreadRepository.{recomputeAggregates,markComplete,messageIds,fetch,idsExisting,deleteExpired}`, `BodyRepository.{storeBody,markUnavailable,missingBodyIds,updateAttachmentIds,pruneBodies}`, `LabelRepository.{replaceAll,updateCounts,markViewFetched,cachedViewLabelIds,displayedLabelIds}`, `SyncStateRepository.*`, `Queries.{inboxUnreadThreadCount,outboxCounts}`, `OutboxRepository.{releaseInFlight,activeThreadIds,deleteFailedSends}` |
| 07 `Outbox` / `MailActions` | `OutboxRepository.{enqueueModify,enqueueSend,claimModifies,claimSend,ackModify,discardModify,retryLater,fail,setTransmitState,deleteSend,retrySend,rearmFailedModifies,pendingModifies,record}`, `OutboxRecord` (+ `delta`, `sendJob`), `SendJob`, `ForwardAttachmentRef`, `TransmitState`, `ThreadRepository.messageIds`, `Queries.outboxCounts` |
| 08 `InlineImageStore`, 10 `AttachmentOpener` | `BodyRepository.attachment`, `BodyRepository.updateAttachmentIds`, `AttachmentRecord`, `SanitizedBody`, `DarkStrategy` |
| 09 `InboxModel` | `ThreadQuery`, `ThreadRow`, `ThreadChip`, `Queries.{threads,labelsById,failedSends,inboxUnreadThreadCount,todayThreadCount}`, `DayBoundary`, `OutboxRecord` |
| 10 `ThreadModel` | `Queries.threadDetail`, `ThreadDetail`, `ThreadRecord`, `MessageRecord`, `MessageBodyRecord`, `AttachmentRecord`, `BodyRepository.resetUnavailable` |
| 11 `ComposeModel` | `MessageRecord` (headers, `referencesList`, `messageIdHeader`, `inReplyTo`), `MessageBodyRecord.bodyHtml/bodyText`, `AttachmentRecord` (forward refs), `SendJob`, `ForwardAttachmentRef`, `OutboxRecord.sendJob` (reopen failed send) |
| 12 `LabelsModel` | `Queries.{labelsForSheet,labelsById,inboxUnreadThreadCount,todayThreadCount}`, `LabelRecord`, `LabelRepository.displayedLabelIds` |
| 13 `SettingsScreen` | `SyncStateRepository.get` (`accountEmail`, `historyId`, `lastDeltaSyncAt`, `sendAsSignature`), `Queries.outboxCounts` |
| 14 QA | `TestDatabase`, `InvariantChecks`, `AppDatabase.openInMemory/openTemporary` |

---

## 2. Files

| Path (repo root) | Kind | Purpose |
|---|---|---|
| `Packages/MailCore/Sources/MailCore/Sync/LabelAlgebra.swift` | new | `LabelDelta`, `DerivedFlags`, `LabelAlgebra` (effective, flags, sortedJSON/parseJSON, userVisible, system-id table) |
| `Packages/MailCore/Sources/MailCore/Sync/OutboxCoalescer.swift` | new | `OutboxCoalescer.merge(existing:new:)` |
| `Packages/MailCore/Sources/MailCore/Sync/ThreadAggregator.swift` | new | `AggregateInput`, `ThreadAggregate`, `ThreadAggregator.aggregate` |
| `Packages/MailCore/Sources/MailCore/Support/DayBoundary.swift` | new | `DayBoundary`, `RowDateLabel`, `RowDateLabeler` |
| `Packages/MailCore/Sources/MailHTML/SanitizedBody.swift` | new | `DarkStrategy`, `SanitizedBody` (declaration only; DEVIATION D2) |
| `Packages/MailCore/Tests/MailCoreTests/LabelAlgebraTests.swift` | new | algebra, flags, JSON, user-visible, Codable |
| `Packages/MailCore/Tests/MailCoreTests/OutboxCoalescerTests.swift` | new | inverse cancels, merge, idempotence |
| `Packages/MailCore/Tests/MailCoreTests/ThreadAggregatorTests.swift` | new | subject/snippet/counts/lastInboxDate/participants/labels |
| `Packages/MailCore/Tests/MailCoreTests/DayBoundaryTests.swift` | new | DST edges, contains, `RowDateLabel` matrix (de_DE, en_US), `vectors/today.json` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/today.json` | new | day-boundary vectors (§5.6) |
| `minimail/Store/Database.swift` | new | `AppDatabase` — open pool, migrate, file protection, temporary/in-memory, destroy, reset |
| `minimail/Store/Schema.swift` | new | `Schema.v1SQL` (verbatim §3.2 DDL), table/index name tables, `dropAllSQL`, migrator registration |
| `minimail/Store/Records.swift` | new | `LabelRecord`, `ThreadRecord`, `ThreadLabelRecord`, `MessageRecord`, `MessageBodyRecord`, `AttachmentRecord`, `OutboxRecord`, `SyncStateRecord`, `OutboxKind`, `OutboxState`, `TransmitState`, `SendJob`, `ForwardAttachmentRef`, `SyncKey`, `RecordJSON` |
| `minimail/Store/Queries.swift` | new | `ThreadQuery`, `ThreadRow`, `ThreadChip`, `ThreadDetail`, `Queries` (every UI `SELECT`) |
| `minimail/Store/MessageRepository.swift` | new | S writes, E recompute, delete, existence, stale ids |
| `minimail/Store/ThreadRepository.swift` | new | aggregates + `thread_label`, completeness, message ids, expiry |
| `minimail/Store/BodyRepository.swift` | new | body/attachment rows, missing bodies, attachment id refresh, body pruning |
| `minimail/Store/LabelRepository.swift` | new | `replaceAll`, `updateCounts`, view state, displayed ids |
| `minimail/Store/OutboxRepository.swift` | new | coalescing enqueue, claim, ack, discard, retry, fail, send helpers, re-arm, maintenance |
| `minimail/Store/SyncStateRepository.swift` | new | key/value + typed helpers (`historyId`, `selfAddresses`) |
| `minimail/App/AppEnvironment.swift` | modify | launch step 2 (`db`), `cachedEmail` read, `wipeAccountData` hook (§4.13) |
| `minimailTests/Support/TestDatabase.swift` | new | in-memory queue + migrations + seed builders |
| `minimailTests/Support/InvariantChecks.swift` | new | `InvariantChecks.assertAll` (§3.5) |
| `minimailTests/Store/DatabaseTests.swift` | new | DDL compare, pragmas, cascade, destroy/reset, recovery |
| `minimailTests/Store/RepositoryTests.swift` | new | every repository function + invariants after each |
| `minimailTests/Store/QueriesTests.swift` | new | scopes × unreadOnly, paging, query plans, 5,000-message timing, row precomputation, detail, labels, counts |
| `minimailTests/App/AppEnvironmentTests.swift` | modify | adds `testTestingModeOpensTemporaryDatabase`, `testCachedEmailReadFromSyncState`, `testWipeAccountDataResetsDatabase` |

No change to `Package.swift` (SwiftPM picks the new sources up), `project.yml` (the app target globs `minimail/`), `PrivacyInfo.xcprivacy` (no required-reason API is used: `setAttributes(_:ofItemAtPath:)` and `removeItem(at:)` are not in the file-timestamp category; `attributesOfItem(atPath:)` is **never** called by production code — closes 01 §10 A13 with "not needed").

---

## 3. Public interface

Conventions (from 01 §3): app-target declarations are `internal`; package declarations are `public`. **Every type in `minimail/Store/` and both test-support types are declared `nonisolated`** because the app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and these functions run inside `DatabasePool.read/write` closures on GRDB's queues and inside `ValueObservation` reader closures; an inferred `@MainActor` isolation (or an inferred isolated conformance to `FetchableRecord`) would be a compile error at the first `pool.write { db in try MessageRepository… }`. Fallback if `nonisolated` on a type declaration does not compile (01 §10 A7): mark every member `nonisolated` and every conformance `nonisolated` (`extension MessageRecord: nonisolated FetchableRecord`).

In the app target GRDB's `Database` class is referred to as `GRDB.Database` **only in this spec's prose**; in code the name `Database` resolves to GRDB's class because this module names its own enum `AppDatabase` (DEVIATION D1, §10).

### 3.1 `MailCore` — `Sync/LabelAlgebra.swift`

```swift
import Foundation

/// A label change: `add` wins over `remove` when both contain an id (see `applied(to:)`). `Codable` form: `{"add":["A","B"],"remove":["C"]}` with each array sorted ascending (custom `encode(to:)`), so JSON is stable.
public struct LabelDelta: Codable, Sendable, Equatable {
    public var add: Set<String>
    public var remove: Set<String>
    public init(add: Set<String> = [], remove: Set<String> = [])
    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
    /// `(labels − remove) ∪ add`.
    public func applied(to labels: Set<String>) -> Set<String>
    /// Convenience for the outbox columns: `add.sorted()` / `remove.sorted()`.
    public var sortedAdd: [String] { get }
    public var sortedRemove: [String] { get }
}

/// Flags every message row carries, derived from its effective label set.
public struct DerivedFlags: Sendable, Equatable {
    public var isUnread: Bool
    public var inInbox: Bool
    public var isHidden: Bool
    public init(isUnread: Bool, inInbox: Bool, isHidden: Bool)
}

public enum LabelAlgebra {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let sent = "SENT"
    public static let starred = "STARRED"
    public static let important = "IMPORTANT"
    /// TRASH ∨ SPAM ∨ DRAFT ∨ CHAT (architecture D25).
    public static let hiddenIds: Set<String> = ["TRASH", "SPAM", "DRAFT", "CHAT"]
    /// Ids never shown as chips: INBOX, UNREAD, SENT, DRAFT, CHAT, SPAM, TRASH, STARRED, IMPORTANT (+ every `CATEGORY_*`, see `isSystem`).
    public static let systemIds: Set<String> = ["INBOX", "UNREAD", "SENT", "DRAFT", "CHAT", "SPAM", "TRASH", "STARRED", "IMPORTANT"]
    /// `systemIds.contains(id) || id.hasPrefix("CATEGORY_")`.
    public static func isSystem(_ id: String) -> Bool
    /// Folds `applied(to:)` over `pending` in array order: E = pₙ(…p₁(S)).
    public static func effective(server: Set<String>, pending: [LabelDelta]) -> Set<String>
    /// isUnread = contains UNREAD; inInbox = contains INBOX; isHidden = intersects `hiddenIds`.
    public static func flags(_ labels: Set<String>) -> DerivedFlags
    /// `["A","B"]` — ids sorted ascending by `String.<` (Unicode scalar order), JSON-escaped, no whitespace, `/` not escaped. `[]` for the empty set.
    public static func sortedJSON(_ labels: Set<String>) -> String
    /// Inverse of `sortedJSON`; any JSON array of strings is accepted; malformed input (not a JSON array of strings) → `[]`.
    public static func parseJSON(_ json: String) -> Set<String>
    /// Sorted ascending; excludes every id for which `isSystem` is true.
    public static func userVisible(_ labels: Set<String>) -> [String]
}
```
Additions to §2.2 (all additive): the five id constants, `hiddenIds`, `systemIds`, `isSystem`, `parseJSON`, `sortedAdd/sortedRemove`, `LabelDelta.init` defaults, `DerivedFlags.init`.

### 3.2 `MailCore` — `Sync/OutboxCoalescer.swift`

```swift
public enum OutboxCoalescer {
    /// add = (existing.add − new.remove) ∪ new.add ; remove = (existing.remove − new.add) ∪ new.remove.
    /// The newer intent wins; opposite intents cancel (read then unread → both sets empty).
    public static func merge(existing: LabelDelta, new: LabelDelta) -> LabelDelta
}
```

### 3.3 `MailCore` — `Sync/ThreadAggregator.swift`

```swift
import Foundation

/// One VISIBLE (isHidden = 0) message of a thread, as read from the `message` table.
public struct AggregateInput: Sendable, Equatable {
    public var id: String
    public var internalDate: Int64
    public var subject: String
    public var snippet: String
    public var fromName: String?
    public var fromAddr: String
    public var isFromMe: Bool
    public var isUnread: Bool
    public var inInbox: Bool
    public var hasAttachments: Bool
    public var bodyState: Int
    public var labelIds: Set<String>
    public init(id: String, internalDate: Int64, subject: String, snippet: String, fromName: String?, fromAddr: String, isFromMe: Bool,
                isUnread: Bool, inInbox: Bool, hasAttachments: Bool, bodyState: Int, labelIds: Set<String>)
}

/// The derived `thread` row (+ the `thread_label` set) for one thread.
public struct ThreadAggregate: Sendable, Equatable {
    public var subject: String            // oldest message, `SubjectPrefix.stripForDisplay`
    public var snippet: String            // newest message
    public var lastDate: Int64            // max internalDate
    public var lastInboxDate: Int64?      // max internalDate of messages with inInbox && !isFromMe (received into INBOX); nil if none
    public var messageCount: Int
    public var unreadCount: Int
    public var inInbox: Bool              // any message inInbox
    public var hasAttachments: Bool       // any message hasAttachments
    public var participants: String       // "Alice, Bob, Me" — §4.3 rule
    public var userLabelIds: [String]     // sorted union of `LabelAlgebra.userVisible(labelIds)` over messages
    public var allLabelIds: Set<String>   // union of every labelIds (drives thread_label)
    public var bodiesMissing: Int         // messages with bodyState == 0
    public init(subject: String, snippet: String, lastDate: Int64, lastInboxDate: Int64?, messageCount: Int, unreadCount: Int, inInbox: Bool,
                hasAttachments: Bool, participants: String, userLabelIds: [String], allLabelIds: Set<String>, bodiesMissing: Int)
}

public enum ThreadAggregator {
    /// `nil` when `messages` is empty. Input order is irrelevant (sorted internally by (internalDate, id)).
    /// `selfAddresses` are lowercased addr-specs; a sender counts as "Me" when `isFromMe` or `selfAddresses.contains(fromAddr.lowercased())`.
    public static func aggregate(_ messages: [AggregateInput], selfAddresses: Set<String>) -> ThreadAggregate?
    /// First-name rule of §4.3 (exposed for tests): `"Alice Müller"` → `"Alice"`, `"Müller, Bob"` → `"Bob"`, `nil`/blank → local part of `addr`.
    public static func firstName(name: String?, addr: String) -> String
    public static let maxParticipants = 3
}
```

### 3.4 `MailCore` — `Support/DayBoundary.swift`

```swift
import Foundation

/// Half-open range [startMs, endMs) of one local calendar day in `timeZone`.
public struct DayBoundary: Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public init(startMs: Int64, endMs: Int64)
    /// `calendar` copy with `timeZone` set; `startMs = startOfDay(now)`, `endMs = startOfDay + 1 day` (23 h / 24 h / 25 h on DST days).
    public static func today(now: Date, timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian)) -> DayBoundary
    /// `startMs <= epochMs && epochMs < endMs`.
    public func contains(_ epochMs: Int64) -> Bool
}

public enum RowDateLabel {
    /// Convenience over `RowDateLabeler` (creates the formatters per call; use the labeler for lists).
    public static func label(epochMs: Int64, now: Date, timeZone: TimeZone, locale: Locale) -> String
}

/// Formats list-row dates; holds four `DateFormatter`s, so it is a class, NOT `Sendable`; create one per query evaluation.
public final class RowDateLabeler {
    public init(now: Date, timeZone: TimeZone, locale: Locale, calendar: Calendar = Calendar(identifier: .gregorian))
    /// Rule table of §4.5: today → short time; yesterday → "Yesterday"; last 6 days → abbreviated weekday; same year → "d MMM" template; else short date.
    public func label(epochMs: Int64) -> String
}
```
`RowDateLabeler` is an addition (the per-row `DateFormatter` construction of the static function is too slow for 60 rows per observation tick; §12.3 budget).

### 3.5 `MailHTML` — `SanitizedBody.swift` (DEVIATION D2: declaration split out of module 08's `Sanitizer.swift`; verbatim architecture §2.3 plus inits)

```swift
import Foundation

public enum DarkStrategy: String, Sendable, Codable { case plain, card, native }

public struct SanitizedBody: Sendable, Equatable {
    public var html: String
    public var hasRemoteImages: Bool
    public var darkStrategy: DarkStrategy
    public var referencedContentIDs: Set<String>
    public init(html: String, hasRemoteImages: Bool, darkStrategy: DarkStrategy, referencedContentIDs: Set<String>)
}
```
Module 08 writes `Sanitizer.swift` **without** redefining these two types.

### 3.6 App — `Store/Database.swift`

```swift
import Foundation
import GRDB

/// Connection lifecycle. DEVIATION D1: named `AppDatabase` (architecture: `enum Database`) because `Database` would shadow `GRDB.Database`
/// in every repository signature `(_ db: Database)`.
nonisolated enum AppDatabase {
    static let directoryName = "minimail-db"
    static let fileName = "db.sqlite"
    /// `Application Support/minimail-db` (directory created if missing) `[ios-platform §2.2]`.
    static func defaultDirectory() throws -> URL
    /// Creates `directory`, sets `FileProtectionType.completeUntilFirstUserAuthentication` on it (failure → `Log.db.error`, continue),
    /// opens `DatabasePool(path: directory/db.sqlite)` (WAL), runs the migrator (no-op when current), sets the same protection on every
    /// file now in the directory (best effort). Throws `DatabaseError` from GRDB when the file cannot be opened or migrated.
    static func open(directory: URL) throws -> DatabasePool
    /// `open` on a fresh directory `NSTemporaryDirectory()/minimail-db-<UUID>`; used by `AppEnvironment(testing: true)` and tests that need a pool. ADDITION.
    static func openTemporary() throws -> DatabasePool
    /// `DatabaseQueue()` (in-memory) + migrator. Tests only.
    static func openInMemory() throws -> DatabaseQueue
    /// `FileManager.removeItem(at: directory)` (db.sqlite, -wal, -shm and the directory). Missing directory → no error.
    /// Precondition: no open pool on that directory (`try pool.close()` first).
    static func destroy(directory: URL) throws
    /// In-place account wipe keeping the pool object valid for every actor holding it: one write transaction executing `Schema.dropAllSQL`
    /// then `Schema.v1SQL`, followed by `VACUUM`. ADDITION (§4.13, DEVIATION D3).
    static func reset(_ pool: DatabasePool) throws
    /// `DatabaseMigrator` with `Schema.register(in:)`; `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true #endif` (name UNVERIFIED `[ios-platform §2.3]`; delete the line if it does not compile).
    static func makeMigrator() -> DatabaseMigrator
}
```

### 3.7 App — `Store/Schema.swift`

```swift
import Foundation
import GRDB

nonisolated enum Schema {
    /// The verbatim DDL of §5.1 (architecture §3.2), one string, statements separated by `;`.
    static let v1SQL: String
    static let tableNames = ["label", "thread", "thread_label", "message", "message_body", "attachment", "outbox", "syncState"]
    static let indexNames = ["thread_inbox_date", "thread_inbox_unread", "thread_inbox_today", "thread_label_date",
                             "message_thread_date", "message_generation", "outbox_due", "outbox_thread"]
    /// `DROP TABLE IF EXISTS` for `tableNames` in reverse order, then `DELETE FROM sqlite_sequence WHERE name = 'outbox'`.
    static let dropAllSQL: String
    /// `migrator.registerMigration("v1") { db in try db.execute(sql: v1SQL) }`.
    static func register(in migrator: inout DatabaseMigrator)
}
```

### 3.8 App — `Store/Records.swift`

Column = property name (no `CodingKeys`). Arrays and nested structs become JSON `TEXT` through GRDB's Codable support `[ios-platform §2.4]`; every record overrides `databaseJSONEncoder(for:)`/`databaseJSONDecoder(for:)` with `RecordJSON`.

```swift
import Foundation
import GRDB
import MailCore

/// Shared JSON configuration for JSON columns: `.sortedKeys` + `.withoutEscapingSlashes`, dates as `millisecondsSince1970`.
nonisolated enum RecordJSON {
    static let encoder: JSONEncoder
    static let decoder: JSONDecoder
    static func string<T: Encodable>(_ value: T) -> String          // encoder → UTF-8 string; precondition: T encodes (programmer error otherwise)
    static func value<T: Decodable>(_ type: T.Type, from string: String) -> T?
}

nonisolated struct LabelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "label"
    var id: String
    var name: String
    var type: String                      // "system" | "user"
    var labelListVisibility: String?
    var messageListVisibility: String?
    var textColor: String?
    var backgroundColor: String?
    var messagesUnread: Int?
    var threadsUnread: Int?
    var threadsTotal: Int?
    var countsFetchedAt: Int64?
    var sortOrder: Int
    var viewFetchedAt: Int64?
    var viewNextPageToken: String?
    var isUser: Bool { type == "user" }
}

nonisolated struct ThreadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "thread"
    var id: String
    var subject: String
    var snippet: String
    var lastDate: Int64
    var lastInboxDate: Int64?
    var messageCount: Int
    var unreadCount: Int
    var inInbox: Bool
    var hasAttachments: Bool
    var participants: String
    var userLabelIds: [String]            // JSON column, sorted
    var isComplete: Bool
    var bodiesMissing: Int
}

nonisolated struct ThreadLabelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "thread_label"
    var labelId: String
    var threadId: String
    var lastDate: Int64
    var unreadCount: Int
}

nonisolated struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "message"
    var id: String
    var threadId: String
    var historyId: Int64
    var internalDate: Int64
    var fromName: String?
    var fromAddr: String
    var isFromMe: Bool
    var toList: [Mailbox]                 // JSON `[{"addr":"…","name":"…"}]`
    var ccList: [Mailbox]
    var replyToList: [Mailbox]
    var subject: String
    var snippet: String
    var messageIdHeader: String?
    var inReplyTo: String?
    var referencesList: [String]
    var topMimeType: String?
    var serverLabelIds: [String]          // S, sorted
    var labelIds: [String]                // E, sorted — the ONLY label column the UI reads
    var isUnread: Bool
    var inInbox: Bool
    var isHidden: Bool
    var hasAttachments: Bool
    var bodyState: Int                    // 0 none, 1 cached, 2 unavailable
    var syncGeneration: Int
    var fetchedAt: Int64
    var from: Mailbox { Mailbox(name: fromName, addr: fromAddr) }
    var serverLabelSet: Set<String> { Set(serverLabelIds) }
    var labelSet: Set<String> { Set(labelIds) }
}

nonisolated struct MessageBodyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "message_body"
    var messageId: String
    var bodyHtml: String
    var bodyText: String?
    var hasRemoteImages: Bool
    var darkStrategy: String              // "plain" | "card" | "native"
    var sanitizerVersion: Int
    var fetchedAt: Int64
}

nonisolated struct AttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "attachment"
    var messageId: String
    var partId: String
    var filename: String
    var mimeType: String
    var size: Int
    var contentId: String?
    var isInline: Bool
    var attachmentId: String?
}

nonisolated enum OutboxKind: String, Codable, Sendable { case modify, send }
nonisolated enum OutboxState: String, Codable, Sendable { case pending, inFlight, failed }
nonisolated enum TransmitState: String, Codable, Sendable { case notSent, maybeSent }

/// `outbox.sendJob` JSON (architecture §2.4 verbatim + memberwise init).
nonisolated struct SendJob: Codable, Sendable, Equatable {
    var mode: ComposeMode
    var originalMessageId: String
    var threadId: String
    var messageID: String                 // "<uuid@domain>", frozen at compose time
    var to: [Mailbox]
    var cc: [Mailbox]
    var subject: String
    var typedText: String
    var inReplyTo: String?
    var references: [String]
    var quoteSource: QuoteSource          // snapshot; never re-read from the cache at drain time
    var attachments: [ForwardAttachmentRef]
    var includeSignature: Bool
}
nonisolated struct ForwardAttachmentRef: Codable, Sendable, Equatable {
    var partId: String
    var filename: String
    var mimeType: String
    var size: Int
    var attachmentId: String?
}

nonisolated struct OutboxRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "outbox"
    var id: Int64
    var kind: OutboxKind
    var state: OutboxState
    var attempts: Int
    var nextAttemptAt: Int64
    var createdAt: Int64
    var lastError: String?
    var threadId: String?                 // modify: target thread; send: job.threadId (stored for maintenance lookups)
    var addLabelIds: [String]?            // modify only, sorted
    var removeLabelIds: [String]?         // modify only, sorted
    var affectedMessageIds: [String]?     // modify only, sorted
    var sendJob: SendJob?                 // send only (JSON)
    var rfc822MessageId: String?          // send only
    var transmitState: TransmitState?     // send only
    /// `LabelDelta(add: Set(addLabelIds ?? []), remove: Set(removeLabelIds ?? []))`.
    var delta: LabelDelta { get }
    var affectedSet: Set<String> { Set(affectedMessageIds ?? []) }
}

nonisolated struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "syncState"
    var key: String
    var value: String
}

nonisolated enum SyncKey: String, CaseIterable, Sendable {
    case historyId, syncGeneration, lastFullSyncAt, lastDeltaSyncAt, lastLabelCountsAt, lastCleanupAt, accountEmail, displayName, selfAddresses, sendAsSignature, inboxNextPageToken
}
```

### 3.9 App — `Store/Queries.swift`

```swift
import Foundation
import GRDB
import MailCore

nonisolated struct ThreadQuery: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case inbox, today(DayBoundary), label(id: String) }
    var scope: Scope
    var unreadOnly: Bool
    var limit: Int                                  // 60, +60 per page
    static let pageSize = 60
    init(scope: Scope, unreadOnly: Bool = false, limit: Int = ThreadQuery.pageSize)
}

/// DEVIATION D4: the architecture's `chips: [(id:name:textColor:backgroundColor:)]` tuple array cannot synthesize `Equatable`; a struct is used.
nonisolated struct ThreadChip: Equatable, Sendable, Identifiable {
    var id: String                                  // label id
    var name: String                                // label name verbatim
    var textColor: String?                          // "#rrggbb" or nil → theme fallback
    var backgroundColor: String?
}

/// Fully precomputed row projection (no formatting in `body`).
nonisolated struct ThreadRow: Identifiable, Equatable, Sendable {
    var id: String
    var participants: String
    var subject: String
    var snippet: String
    var dateLabel: String
    var isUnread: Bool                              // unreadCount > 0
    var messageCount: Int
    var hasAttachments: Bool
    var chips: [ThreadChip]                         // ≤ 2 user labels present in the label table
}

nonisolated struct ThreadDetail: Sendable, Equatable {
    var thread: ThreadRecord
    var messages: [MessageRecord]                   // visible only, internalDate ASC
    var bodies: [String: MessageBodyRecord]         // keyed by messageId
    var attachments: [AttachmentRecord]             // ordered by (messageId, partId)
}

nonisolated enum Queries {
    static let maxChips = 2
    /// §8.6 SQL + row mapping; the returned closure is what `ValueObservation.trackingConstantRegion` evaluates on a reader connection.
    static func threads(_ q: ThreadQuery, now: Date, timeZone: TimeZone, locale: Locale, labels: [String: LabelRecord]) -> @Sendable (Database) throws -> [ThreadRow]
    /// The SQL text + arguments the closure runs (exposed for `EXPLAIN QUERY PLAN` tests). ADDITION.
    static func threadsSQL(_ q: ThreadQuery) -> (sql: String, arguments: StatementArguments)
    static func threadDetail(_ db: Database, threadId: String) throws -> ThreadDetail?
    /// Labels sheet rows in display order (§4.9): INBOX, STARRED, IMPORTANT, SENT, then user labels by visibility rule, name-ordered.
    static func labelsForSheet(_ db: Database) throws -> [LabelRecord]
    /// Every label row keyed by id (chip lookup for `threads`). ADDITION.
    static func labelsById(_ db: Database) throws -> [String: LabelRecord]
    /// `kind = 'send' AND state = 'failed'`, `id ASC`.
    static func failedSends(_ db: Database) throws -> [OutboxRecord]
    static func inboxUnreadThreadCount(_ db: Database) throws -> Int
    static func todayThreadCount(_ db: Database, _ day: DayBoundary) throws -> Int
    /// pending = rows with state ∈ {pending, inFlight} (both kinds); failed = `kind = 'send' AND state = 'failed'`.
    static func outboxCounts(_ db: Database) throws -> (pending: Int, failed: Int)
}
```

### 3.10 App — `Store/MessageRepository.swift`

```swift
import Foundation
import GRDB
import MailCore

nonisolated enum MessageRepository {
    /// Writes S (+ headers, snippet, topMimeType, syncGeneration, fetchedAt = now) for every parsed message; inserts or updates; never touches
    /// `message_body`, `bodyState`, or an exact `hasAttachments` (bodyState == 1). Then `recomputeEffective` for these ids.
    /// Returns the thread ids of every message written (caller: `ThreadRepository.recomputeAggregates` in the same transaction).
    static func upsertMetadata(_ db: Database, parsed: [ParsedMessage], selfAddresses: Set<String>, generation: Int, now: Int64) throws -> Set<String>
    /// S := labels (sorted). No-op when the message row does not exist. Does NOT recompute E (caller batches `recomputeEffective`).
    static func applyServerLabels(_ db: Database, messageId: String, labels: Set<String>) throws
    /// S := delta.applied(to: S). No-op when the row does not exist. Does NOT recompute E.
    static func applyServerDelta(_ db: Database, messageId: String, delta: LabelDelta) throws
    /// E = effective(S, pending/inFlight modify ops whose affectedMessageIds contain the id, in outbox.id order); flags from E.
    /// Writes `labelIds/isUnread/inInbox/isHidden` only when a value changed. Returns the thread ids of the given messages that exist.
    static func recomputeEffective(_ db: Database, messageIds: Set<String>) throws -> Set<String>
    /// `DELETE FROM message WHERE id IN ids` (cascades message_body + attachment). Returns thread ids of the deleted rows.
    /// Caller must `recomputeAggregates` those thread ids in the same transaction.
    static func delete(_ db: Database, ids: Set<String>) throws -> Set<String>
    static func idsExisting(_ db: Database, among ids: [String]) throws -> Set<String>
    /// ids with `syncGeneration < g`, minus ids referenced by pending/inFlight outbox rows (`affectedMessageIds` of modify ops, `sendJob.originalMessageId` of sends).
    static func staleIds(_ db: Database, olderThanGeneration g: Int) throws -> Set<String>
    /// Distinct `threadId` of the given message ids. ADDITION (architecture §4.2 `threadIds(of: stale)`).
    static func threadIds(_ db: Database, of ids: Set<String>) throws -> Set<String>
    /// One row or nil. ADDITION (tests, 11).
    static func fetch(_ db: Database, id: String) throws -> MessageRecord?
}
```

### 3.11 App — `Store/ThreadRepository.swift`

```swift
nonisolated enum ThreadRepository {
    /// For each thread id: visible messages → `ThreadAggregator.aggregate`; nil → delete thread + thread_label rows; else upsert the thread
    /// row (keeping `isComplete` of an existing row; 0 on insert) and replace its thread_label rows.
    static func recomputeAggregates(_ db: Database, threadIds: Set<String>, selfAddresses: Set<String>) throws
    /// `UPDATE thread SET isComplete = ? WHERE id = ?` (no-op when no row).
    static func markComplete(_ db: Database, threadId: String, complete: Bool) throws
    /// ALL message ids of the thread (hidden included — `threads.modify` applies server-side to every message), internalDate ASC, id ASC.
    static func messageIds(_ db: Database, threadId: String) throws -> [String]
    static func fetch(_ db: Database, id: String) throws -> ThreadRecord?                       // ADDITION
    static func idsExisting(_ db: Database, among ids: Set<String>) throws -> Set<String>        // ADDITION (HydrationScope.knownThreadIds)
    /// §4.9 step 1: deletes threads with `inInbox = 0 AND unreadCount = 0 AND lastDate < olderThan`, excluding threads that have a
    /// thread_label row for any id in `protectedLabelIds` or appear in `protectedThreadIds`; deletes their messages (cascade bodies/attachments)
    /// and thread_label rows. Returns the number of threads deleted. ADDITION.
    static func deleteExpired(_ db: Database, olderThan: Int64, protectedLabelIds: Set<String>, protectedThreadIds: Set<String>) throws -> Int
}
```

### 3.12 App — `Store/BodyRepository.swift`

```swift
import MailHTML

nonisolated enum BodyRepository {
    /// Upserts `message_body` (nil body → the "could not be displayed" fragment of §4.7), replaces the message's attachment rows
    /// (`isInline = contentId ∈ referenced`), sets `bodyState = 1` and the exact `hasAttachments` (any row with isInline = 0).
    /// No-op when the message row does not exist. Does NOT recompute aggregates (caller does).
    /// DEVIATION D6: `sanitizerVersion` added (architecture signature has no way to fill `message_body.sanitizerVersion`).
    static func storeBody(_ db: Database, messageId: String, body: SanitizedBody?, text: String?, attachments: [ParsedAttachment], referenced: Set<String>, sanitizerVersion: Int, now: Int64) throws
    /// `bodyState = 2`; body row untouched.
    static func markUnavailable(_ db: Database, messageId: String) throws
    /// `bodyState = 2 → 0` (Retry in the thread view). ADDITION.
    static func resetUnavailable(_ db: Database, messageId: String) throws
    /// Visible messages of the thread with `bodyState = 0`, or `bodyState = 1` whose body row has `sanitizerVersion < sanitizerVersion`
    /// (or no body row at all); newest first (internalDate DESC).
    static func missingBodyIds(_ db: Database, threadId: String, sanitizerVersion: Int) throws -> [String]
    static func attachment(_ db: Database, messageId: String, partId: String) throws -> AttachmentRecord?
    /// For each parsed attachment: `UPDATE attachment SET attachmentId = ? WHERE messageId = ? AND partId = ?`. Unknown partIds ignored.
    static func updateAttachmentIds(_ db: Database, messageId: String, parsed: [ParsedAttachment]) throws
    /// §4.9 step 2: deletes body rows beyond the newest `keepNewest` by `fetchedAt` (ties: messageId ASC kept first), sets `bodyState = 0` on
    /// their messages and recomputes the aggregates of their threads (reads selfAddresses from syncState). Returns rows deleted. ADDITION.
    static func pruneBodies(_ db: Database, keepNewest: Int) throws -> Int
}
```

### 3.13 App — `Store/LabelRepository.swift`

```swift
nonisolated enum LabelRepository {
    static let pinnedSystemIds = ["INBOX", "STARRED", "IMPORTANT", "SENT"]     // sortOrder 0, 10, 20, 30
    static let otherSystemSortOrder = 500
    static let userSortOrder = 1000
    /// Upserts identity/visibility/sortOrder for every label; keeps counts, colour (when the incoming colour is nil), viewFetchedAt,
    /// viewNextPageToken of rows that still exist; deletes rows whose id is not in `labels`.
    static func replaceAll(_ db: Database, labels: [GmailLabel]) throws
    /// From `labels.get`: counts + colour + `countsFetchedAt = now`; ids without a row are ignored.
    static func updateCounts(_ db: Database, labels: [GmailLabel], now: Int64) throws
    static func markViewFetched(_ db: Database, labelId: String, nextPageToken: String?, now: Int64) throws
    /// ids with `viewFetchedAt IS NOT NULL`, id ASC.
    static func cachedViewLabelIds(_ db: Database) throws -> [String]
    /// §4.6 `labels.get` set: pinned system ids present + user labels with `labelListVisibility != 'labelHide'`, capped at 60. ADDITION.
    static func displayedLabelIds(_ db: Database, cap: Int = 60) throws -> [String]
    static func fetch(_ db: Database, id: String) throws -> LabelRecord?                       // ADDITION
}
```

### 3.14 App — `Store/OutboxRepository.swift`

```swift
nonisolated enum OutboxRepository {
    static let maxModifyAttempts = 8
    static let maxSendAttempts = 5
    /// §4.8 enqueue: coalesces into the thread's `pending` op (never an inFlight one); an empty merge deletes the op; recomputes E for the
    /// affected ids and the thread aggregate. Returns the op id, or nil when the op cancelled out or `delta.isEmpty`.
    static func enqueueModify(_ db: Database, threadId: String, delta: LabelDelta, affectedMessageIds: [String], now: Int64) throws -> Int64?
    /// Inserts a pending send (`transmitState = notSent`, `rfc822MessageId = job.messageID`, `threadId = job.threadId`). Returns its id.
    static func enqueueSend(_ db: Database, job: SendJob, now: Int64) throws -> Int64
    /// `kind = 'modify' AND state = 'pending' AND nextAttemptAt <= now`, id ASC, `LIMIT limit` → state inFlight, attempts + 1. Returns the updated rows.
    static func claimModifies(_ db: Database, limit: Int, now: Int64) throws -> [OutboxRecord]
    /// Oldest due pending send → inFlight, attempts + 1; nil when none.
    static func claimSend(_ db: Database, now: Int64) throws -> OutboxRecord?
    /// S := delta(S) for every affected message; for every id in `serverLabelsByMessage` that exists, S := that set instead; op deleted;
    /// E recomputed for the union; aggregates recomputed. Returns thread ids. Unknown op → `[]`.
    static func ackModify(_ db: Database, opId: Int64, serverLabelsByMessage: [String: Set<String>]?) throws -> Set<String>
    /// Deletes the op, recomputes E for its affected ids (reverting the optimistic state), recomputes aggregates. Returns thread ids.
    static func discardModify(_ db: Database, opId: Int64) throws -> Set<String>
    /// DEVIATION D5 (primitive arguments instead of `GmailError` + `random`): state → pending, `nextAttemptAt`, `lastError = error`;
    /// when `!countsAsAttempt` the attempt counted by claim is decremented; when the (adjusted) attempts ≥ `maxModifyAttempts`
    /// (modify) / `maxSendAttempts` (send) the row becomes `failed` instead (never deleted).
    static func retryLater(_ db: Database, opId: Int64, error: String, countsAsAttempt: Bool, nextAttemptAt: Int64) throws
    /// state → failed, `lastError = error`.
    static func fail(_ db: Database, opId: Int64, error: String) throws
    static func setTransmitState(_ db: Database, opId: Int64, _ s: TransmitState) throws
    /// `DELETE FROM outbox WHERE id = ? AND kind = 'send'`.
    static func deleteSend(_ db: Database, opId: Int64) throws
    /// failed send → pending, attempts 0, nextAttemptAt 0, lastError nil (`transmitState` kept so the rfc822msgid check still runs).
    static func retrySend(_ db: Database, opId: Int64) throws
    /// launch: every inFlight row → pending (nextAttemptAt unchanged).
    static func releaseInFlight(_ db: Database) throws
    /// failed modify ops → pending, attempts 0, nextAttemptAt 0; when the thread already has a pending op the failed op absorbs it
    /// (`merge(existing: failed.delta, new: pending.delta)`, affected ∪, pending row deleted) so invariant 4 holds. E is unchanged by definition.
    static func rearmFailedModifies(_ db: Database) throws
    /// `kind = 'modify' AND state = 'pending'`, id ASC.
    static func pendingModifies(_ db: Database) throws -> [OutboxRecord]
    static func record(_ db: Database, id: Int64) throws -> OutboxRecord?                              // ADDITION
    /// Every pending/inFlight modify op, id ASC (the P of §4.7). ADDITION (used by recomputeEffective and InvariantChecks).
    static func activeModifies(_ db: Database) throws -> [OutboxRecord]
    /// Thread ids referenced by pending/inFlight rows of both kinds (maintenance protection). ADDITION.
    static func activeThreadIds(_ db: Database) throws -> Set<String>
    /// Message ids referenced by pending/inFlight rows (affectedMessageIds ∪ sendJob.originalMessageId). ADDITION (staleIds).
    static func referencedMessageIds(_ db: Database) throws -> Set<String>
    /// §4.9 step 3: `DELETE … WHERE kind = 'send' AND state = 'failed' AND createdAt < olderThan`. Returns rows deleted. ADDITION.
    static func deleteFailedSends(_ db: Database, olderThan: Int64) throws -> Int
}
```

### 3.15 App — `Store/SyncStateRepository.swift`

```swift
nonisolated enum SyncStateRepository {
    static func get(_ db: Database, _ key: SyncKey) throws -> String?
    /// `value == nil` deletes the row; else `INSERT OR REPLACE`.
    static func set(_ db: Database, _ key: SyncKey, _ value: String?) throws
    static func int64(_ db: Database, _ key: SyncKey) throws -> Int64?                        // ADDITION: `Int64(value)`
    static func setInt64(_ db: Database, _ key: SyncKey, _ value: Int64?) throws            // ADDITION
    static func historyId(_ db: Database) throws -> UInt64?                                   // ADDITION: `UInt64(value)`
    /// Invariant 5: no-op (`Log.sync.notice`) when `value < current` unless `allowDecrease` (full resync). ADDITION.
    static func setHistoryId(_ db: Database, _ value: UInt64, allowDecrease: Bool = false) throws
    static func selfAddresses(_ db: Database) throws -> Set<String>                           // ADDITION: JSON [String] → set; [] when absent
    static func setSelfAddresses(_ db: Database, _ addresses: Set<String>) throws             // ADDITION: sorted, lowercased JSON
    static func all(_ db: Database) throws -> [SyncKey: String]                               // ADDITION (Settings → Advanced)
}
```

### 3.16 App — `App/AppEnvironment.swift` (modify)

```swift
@Observable final class AppEnvironment {
    // … 01/04 members …
    /// The one `DatabasePool` of the process (WAL). Opened in launch step 2; never replaced (`AppDatabase.reset` wipes it in place).
    let db: DatabasePool
    /// `AppDatabase.defaultDirectory()` in production; the temporary directory of `openTemporary()` when `isTesting`.
    let databaseDirectory: URL
    /// Test-only overload: `databaseDirectory != nil` opens (and migrates) that directory instead of a fresh temporary one, so a test can
    /// pre-seed `syncState` and check launch routing. The public `init(testing:)` forwards `nil`.
    init(testing: Bool, databaseDirectory: URL?)
}
```

### 3.17 Test support (`minimailTests/Support/`)

```swift
// TestDatabase.swift
import GRDB
import MailCore
@testable import minimail

nonisolated enum TestDatabase {
    /// `AppDatabase.openInMemory()`.
    static func make() throws -> DatabaseQueue
    /// `ParsedMessage` builder with defaults: threadId = id, historyId 1, snippet "", from "Alice <alice@example.com>", to "user@newtelco.de",
    /// subject "Subject", topMimeType "text/plain", body nil, attachments [].
    static func parsed(id: String, threadId: String? = nil, internalDate: Int64, labels: [String], from: Mailbox = Mailbox(name: "Alice", addr: "alice@example.com"),
                       to: [Mailbox] = [Mailbox(name: nil, addr: "user@newtelco.de")], cc: [Mailbox] = [], subject: String = "Subject", snippet: String = "",
                       topMimeType: String? = "text/plain", messageID: String? = nil, inReplyTo: String? = nil, references: [String] = []) -> ParsedMessage
    /// `upsertMetadata` + `recomputeAggregates` for the given messages in one write. selfAddresses default `["user@newtelco.de"]`.
    static func seed(_ writer: any DatabaseWriter, _ messages: [ParsedMessage], selfAddresses: Set<String> = ["user@newtelco.de"], generation: Int = 1, now: Int64 = 1_757_500_000_000) throws
    /// Seeds `count` messages spread over `count / 2` threads (two per thread), internalDate = base + i × 60_000, every 5th unread,
    /// every 7th carries `Label_12`, every 11th hidden (TRASH); labels INBOX/UNREAD/Label_12/STARRED/SENT rows inserted first.
    static func seedMany(_ writer: any DatabaseWriter, count: Int, base: Int64 = 1_757_000_000_000) throws
    static func seedLabels(_ writer: any DatabaseWriter, _ labels: [GmailLabel]) throws
    static let sampleLabels: [GmailLabel]        // INBOX, UNREAD, STARRED, IMPORTANT, SENT, TRASH, CATEGORY_PROMOTIONS (system), Label_12 "Customers/ACME" (user, colour), Label_13 "Hidden" (labelHide), Label_14 "IfUnread" (labelShowIfUnread)
}

// InvariantChecks.swift
nonisolated enum InvariantChecks {
    /// Runs §3.5 invariants 1–4 and 6 (5 is checked by `SyncStateRepository.setHistoryId`'s own test) with `XCTAssert*` (file/line forwarded).
    static func assertAll(_ db: Database, file: StaticString = #filePath, line: UInt = #line) throws
    static func assertAll(_ reader: any DatabaseReader, file: StaticString = #filePath, line: UInt = #line) throws   // `reader.read { try assertAll($0) }`
}
```

---

## 4. Behaviour

Every repository function is synchronous, takes the `Database` handle of the enclosing `read`/`write` closure, throws only GRDB `DatabaseError` (or `EncodingError` from `RecordJSON.string`, a programmer error), and never opens its own transaction. Callers (07) compose several calls in ONE `pool.write { }` — the invariants of §3.5 hold at every transaction boundary, not between calls. Logging: `Log.db.debug` for row counts of bulk operations (`"upsertMetadata n=\(n, privacy: .public)"`), `Log.db.error` for attribute/reset failures; never subjects, addresses or bodies.

### 4.1 `LabelAlgebra`

- `applied(to:)`: `labels.subtracting(remove).union(add)`.
- `effective(server:pending:)`: `pending.reduce(server) { $1.applied(to: $0) }`.
- `flags`: as declared. `flags([])` = `(false, false, false)`.
- `sortedJSON`: `labels.sorted()` (`String.<`), encoded with a `JSONEncoder` whose `outputFormatting = [.withoutEscapingSlashes]` (sortedKeys irrelevant for arrays); result is `"[]"` for the empty set, `"[\"INBOX\",\"Label_12\",\"UNREAD\"]"` for `{"UNREAD","INBOX","Label_12"}` (uppercase sorts before lowercase: `"INBOX" < "Label_12" < "UNREAD"`). Linux and Darwin produce identical bytes for ASCII ids; non-ASCII is escaped as UTF-8 (not `\uXXXX`) by both.
- `parseJSON`: `JSONDecoder().decode([String].self, from: Data(json.utf8))`; any throw → `[]`.
- `userVisible`: `labels.filter { !isSystem($0) }.sorted()`.
- `LabelDelta` `encode(to:)`: keyed container, `add` then `remove`, each `sorted()`; `init(from:)`: arrays → sets (duplicates collapse).

### 4.2 `OutboxCoalescer.merge`

`LabelDelta(add: existing.add.subtracting(new.remove).union(new.add), remove: existing.remove.subtracting(new.add).union(new.remove))`. Examples: (remove UNREAD) then (add UNREAD) → `(add: [], remove: [])` (isEmpty → op deleted); (remove INBOX) then (remove UNREAD) → `(add: [], remove: [INBOX, UNREAD])`; (remove INBOX) then (add INBOX, remove UNREAD) → `(add: [INBOX], remove: [UNREAD])` — Gmail receives `addLabelIds:[INBOX]`, which is a no-op server-side for a message already in INBOX and correct for one another client archived meanwhile.

### 4.3 `ThreadAggregator.aggregate`

1. `guard !messages.isEmpty else { return nil }`; `let sorted = messages.sorted { ($0.internalDate, $0.id) < ($1.internalDate, $1.id) }`.
2. `subject = SubjectPrefix.stripForDisplay(sorted.first!.subject)`; `snippet = sorted.last!.snippet`.
3. `lastDate = sorted.last!.internalDate`; `lastInboxDate = sorted.filter { $0.inInbox && !isMe($0) }.map(\.internalDate).max()` where `isMe(m) = m.isFromMe || selfAddresses.contains(m.fromAddr.lowercased())`.
4. `messageCount = sorted.count`; `unreadCount = count(isUnread)`; `inInbox = any(inInbox)`; `hasAttachments = any(hasAttachments)`; `bodiesMissing = count(bodyState == 0)`.
5. Participants: iterate `sorted`; key = `isMe ? "me" : fromAddr.lowercased()`; skip keys already seen; display = `isMe ? "Me" : firstName(name: fromName, addr: fromAddr)`; collect in order. If more than `maxParticipants` (3) distinct: `participants = first 3 joined by ", " + "…"` (U+2026, no space); else joined by ", ". Empty `fromAddr` and nil name → `"?"` (from `firstName` fallback).
6. `firstName(name:addr:)`: `var s = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)`; strip one pair of surrounding `"` if present and trim again; if `s` contains `,`: `s = substring after the first comma`, trimmed; if `s` is non-empty: return the first maximal run of non-whitespace characters of `s`; else: `let local = addr.split(separator: "@", maxSplits: 1).first.map(String.init) ?? addr`; return `local.isEmpty ? "?" : local`.
7. `allLabelIds = union of labelIds`; `userLabelIds = LabelAlgebra.userVisible(allLabelIds)`.
8. Return the aggregate. Pure; O(n log n).

### 4.4 `DayBoundary`

- `today(now:timeZone:calendar:)`: `var cal = calendar; cal.timeZone = timeZone; let start = cal.startOfDay(for: now); let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)`; `startMs = Int64((start.timeIntervalSince1970 * 1000).rounded())`, likewise `endMs`. On 2026-03-29 in Europe/Berlin `endMs − startMs == 23 × 3_600_000`; on 2026-10-25 it is 25 h; on 2026-09-27 in Pacific/Auckland 23 h.
- `contains`: half-open. A message at 23:59:59.999 local is inside; 00:00:00.000 of the next day is outside (matches the `< :endMs` SQL of §8.6 and decision D16 "upper bound included" read as "the last millisecond of the day counts").

### 4.5 `RowDateLabeler.label(epochMs:)`

Setup in `init`: `cal` = calendar copy with `timeZone` and `locale`; `todayStart = cal.startOfDay(for: now)`; `yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!`; `weekStart = cal.date(byAdding: .day, value: -6, to: todayStart)!`; `yearOfNow = cal.component(.year, from: now)`; four formatters, each with `locale`, `timeZone`, `calendar`: `time` (`dateStyle = .none, timeStyle = .short`), `weekday` (`setLocalizedDateFormatFromTemplate("EEE")`), `dayMonth` (`setLocalizedDateFormatFromTemplate("d MMM")`), `shortDate` (`dateStyle = .short, timeStyle = .none`).

Rule table (`date = Date(timeIntervalSince1970: Double(epochMs) / 1000)`), first match wins:

| Condition | Output | en_US example (now = 2026-09-11 15:00 Berlin) | de_DE example |
|---|---|---|---|
| `date >= todayStart` (today or future) and `cal.isDate(date, inSameDayAs: now)` | `time.string(from: date)` | `"2:32 PM"` (ICU may insert U+202F before PM) | `"14:32"` |
| `date >= todayStart` (future day) | falls through to the same-year / else rows | | |
| `yesterdayStart <= date < todayStart` | `"Yesterday"` (English literal; §16 non-goal localisation) | `"Yesterday"` | `"Yesterday"` |
| `weekStart <= date < yesterdayStart` | `weekday.string(from: date)` | `"Mon"` | `"Mo."` |
| `cal.component(.year, from: date) == yearOfNow` | `dayMonth.string(from: date)` | `"Sep 1"` | `"1. Sept."` (ICU-version dependent) |
| else | `shortDate.string(from: date)` | `"9/11/25"` | `"11.09.25"` |

Exact locale strings are ICU-version dependent; tests (§7) compare against a reference formatter built with the same template in the test, and assert literal values only where every ICU agrees (`"14:32"`, `"Yesterday"`, `"11.09.25"`).

### 4.6 `AppDatabase`

**open(directory:)**
1. `try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)`.
2. `do { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path) } catch { Log.db.error("file protection failed: \(error.localizedDescription, privacy: .public)") }`.
3. `var config = Configuration(); config.foreignKeysEnabled = true` (GRDB default, set explicitly); `config.label = "minimail"`; `#if DEBUG config.publicStatementArguments = true #endif` (UNVERIFIED name; delete if absent).
4. `let pool = try DatabasePool(path: directory.appendingPathComponent(fileName).path, configuration: config)`.
5. `try makeMigrator().migrate(pool)` — `v1` runs once; later opens are no-ops (`hasCompletedMigrations`).
6. For each of `db.sqlite`, `db.sqlite-wal`, `db.sqlite-shm` that exists: `setAttributes` protection as in step 2 (best effort, logged).
7. Return `pool`. Budget on device: < 10 ms when current (§12.1).

**openTemporary()**: `directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minimail-db-\(UUID().uuidString)", isDirectory: true)`; `open(directory:)`.

**openInMemory()**: `let q = try DatabaseQueue(configuration: config)` (in-memory); `try makeMigrator().migrate(q)`; return.

**destroy(directory:)**: `do { try FileManager.default.removeItem(at: directory) } catch CocoaError.fileNoSuchFile { }` (also swallow `NSFileNoSuchFileError` via `(error as NSError).code == NSFileNoSuchFileError`).

**reset(pool)**: `try pool.write { db in try db.execute(sql: Schema.dropAllSQL); try db.execute(sql: Schema.v1SQL) }; try pool.vacuum()` (`DatabaseWriter.vacuum()` — UNVERIFIED name; fallback `try pool.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }`). The migrator's bookkeeping row for `v1` is untouched (schema content identical), so the next `open` is still a no-op. `Log.db.notice("database reset")`.

Concurrency: `open`/`destroy`/`reset` are called from `AppEnvironment` (main) at launch and sign-out, and from tests; `reset` performs a blocking write — `AppEnvironment` runs it inside `Task.detached` (§4.13).

### 4.7 `Schema`

`v1SQL` is the §5.1 string. `dropAllSQL` =
```sql
DROP TABLE IF EXISTS syncState; DROP TABLE IF EXISTS outbox; DROP TABLE IF EXISTS attachment; DROP TABLE IF EXISTS message_body;
DROP TABLE IF EXISTS message; DROP TABLE IF EXISTS thread_label; DROP TABLE IF EXISTS thread; DROP TABLE IF EXISTS label;
DELETE FROM sqlite_sequence WHERE name = 'outbox';
```
Dropping a table drops its indexes. Foreign-key checks are deferred inside GRDB migrations `[ios-platform §2.3]`; the drop order above respects them anyway.

The fallback text when a body is unavailable: `Schema.unavailableBodyHTML = "<p><i>This message could not be displayed.</i></p>"` (architecture §9.1 step 7).

### 4.8 `MessageRepository`

**upsertMetadata(parsed, selfAddresses, generation, now)**
For each `p in parsed` (ids deduplicated, last wins):
1. `existing = try fetch(db, id: p.id)`.
2. Column mapping (architecture §3.3): `threadId = p.threadId`; `historyId = Int64(clamping: p.historyId)`; `internalDate = p.internalDate`; `fromName = p.headers.from?.name` (nil when empty); `fromAddr = p.headers.from?.addr ?? ""`; `isFromMe = selfAddresses.contains(fromAddr.lowercased())`; `toList/ccList/replyToList = p.headers.to/cc/replyTo`; `subject = p.headers.subject`; `snippet = p.snippet`; `messageIdHeader = p.headers.messageID`; `inReplyTo = p.headers.inReplyTo`; `referencesList = p.headers.references`; `topMimeType = p.topMimeType`; `serverLabelIds = Set(p.labelIds).sorted()`; `syncGeneration = generation`; `fetchedAt = now`.
3. Preserved from `existing` (or defaults on insert): `bodyState` (0), `labelIds`/`isUnread`/`inInbox`/`isHidden` (recomputed in step 5), `hasAttachments`: if `existing?.bodyState == 1` keep `existing.hasAttachments`; else `topMimeType == "multipart/mixed"` (hint).
4. `INSERT` or `UPDATE` (record `save`/`upsert`); `message_body` and `attachment` rows are never touched.
5. After the loop: `_ = try recomputeEffective(db, messageIds: ids)`.
6. Return `Set(parsed.map(\.threadId))`. Empty input → `[]`, no SQL.

**applyServerLabels / applyServerDelta**: read `serverLabelIds` of the row (`SELECT serverLabelIds FROM message WHERE id = ?`); missing → return; compute the new S; `UPDATE message SET serverLabelIds = ? WHERE id = ?` only if changed.

**recomputeEffective(messageIds)**
1. `rows = SELECT id, threadId, serverLabelIds, labelIds, isUnread, inInbox, isHidden FROM message WHERE id IN (chunks of 500)`.
2. `ops = OutboxRepository.activeModifies(db)` (pending + inFlight, id ASC) — read once.
3. For each row: `pending = ops.filter { $0.affectedSet.contains(row.id) }.map(\.delta)`; `E = LabelAlgebra.effective(server: row.serverSet, pending: pending)`; `f = LabelAlgebra.flags(E)`; if `E.sorted() != row.labelIds || f != row flags` → `UPDATE message SET labelIds = ?, isUnread = ?, inInbox = ?, isHidden = ? WHERE id = ?`.
4. Return the thread ids of the rows found. Complexity: O(rows × ops); ops ≤ a few dozen.

**delete(ids)**: `threads = threadIds(of: ids)`; `DELETE FROM message WHERE id IN (…)` in chunks of 500; return `threads`. Cascade removes `message_body` and `attachment` (foreign keys on).

**idsExisting(among:)**: chunks of 500, `SELECT id FROM message WHERE id IN (…)`. **threadIds(of:)**: `SELECT DISTINCT threadId … WHERE id IN`. **staleIds(olderThanGeneration:)**: `SELECT id FROM message WHERE syncGeneration < ?` minus `OutboxRepository.referencedMessageIds(db)`.

### 4.9 `ThreadRepository`, `LabelRepository`, `SyncStateRepository`

**recomputeAggregates(threadIds, selfAddresses)** — for each id:
1. `inputs = SELECT id, internalDate, subject, snippet, fromName, fromAddr, isFromMe, isUnread, inInbox, hasAttachments, bodyState, labelIds FROM message WHERE threadId = ? AND isHidden = 0` → `[AggregateInput]` (`labelIds` parsed with `LabelAlgebra.parseJSON` of the raw TEXT, or `Set(record.labelIds)`).
2. `agg = ThreadAggregator.aggregate(inputs, selfAddresses:)`.
3. `agg == nil` → `DELETE FROM thread_label WHERE threadId = ?; DELETE FROM thread WHERE id = ?`; continue.
4. `isComplete = (SELECT isComplete FROM thread WHERE id = ?) ?? false`; upsert `ThreadRecord(id:, subject: agg.subject, snippet:, lastDate:, lastInboxDate:, messageCount:, unreadCount:, inInbox:, hasAttachments:, participants:, userLabelIds: agg.userLabelIds, isComplete:, bodiesMissing:)`.
5. `DELETE FROM thread_label WHERE threadId = ?`; for `labelId in agg.allLabelIds.sorted()`: insert `ThreadLabelRecord(labelId:, threadId:, lastDate: agg.lastDate, unreadCount: agg.unreadCount)`.
Unknown thread ids (no messages) go through step 3 (idempotent deletes).

**deleteExpired(olderThan, protectedLabelIds, protectedThreadIds)**: `candidates = SELECT id FROM thread WHERE inInbox = 0 AND unreadCount = 0 AND lastDate < ?`; remove ids in `protectedThreadIds` and ids with `EXISTS (SELECT 1 FROM thread_label WHERE threadId = ? AND labelId IN (protected))`; for the rest: `DELETE FROM message WHERE threadId = ?` (cascade), `DELETE FROM thread_label WHERE threadId = ?`, `DELETE FROM thread WHERE id = ?`; return the count. (Hidden-only messages of those threads are deleted too; they were unreachable.)

**LabelRepository.replaceAll(labels)**: `incoming = Set(labels.map(\.id))`; `DELETE FROM label WHERE id NOT IN incoming`; for each `l`: `sortOrder = pinnedSystemIds.firstIndex(of: l.id).map { $0 * 10 } ?? (l.type == "user" ? userSortOrder : otherSystemSortOrder)`; if a row exists: `UPDATE label SET name, type, labelListVisibility, messageListVisibility, sortOrder` and `textColor/backgroundColor` only when `l.color != nil`; else `INSERT` with counts/view columns NULL (`sortOrder` set, `type = l.type ?? "user"`). Colour source `[gmail-api §10]`: list responses may omit `color`; never clear a stored colour on a nil.
**updateCounts(labels, now)**: `UPDATE label SET messagesUnread = ?, threadsUnread = ?, threadsTotal = ?, textColor = COALESCE(?, textColor), backgroundColor = COALESCE(?, backgroundColor), countsFetchedAt = ? WHERE id = ?`.
**markViewFetched**: `UPDATE label SET viewFetchedAt = ?, viewNextPageToken = ? WHERE id = ?`.
**displayedLabelIds(cap)**: `SELECT id FROM label WHERE id IN ('INBOX','STARRED','IMPORTANT','SENT') OR (type = 'user' AND (labelListVisibility IS NULL OR labelListVisibility != 'labelHide')) ORDER BY sortOrder, name COLLATE NOCASE LIMIT cap`.

**SyncStateRepository**: `get` = `SELECT value FROM syncState WHERE key = ?`; `set` = `INSERT OR REPLACE` / `DELETE`; `historyId` = `get(.historyId).flatMap(UInt64.init)`; `setHistoryId(v, allowDecrease)`: `if let cur = historyId, v < cur, !allowDecrease { Log.sync.notice("historyId decrease ignored"); return }; set(.historyId, String(v))`; `selfAddresses` = `parseJSON`-style decode of `[String]` (lowercased on write; `[]` when absent/malformed); `setSelfAddresses` writes `addresses.map { $0.lowercased() }.sorted()` as JSON.

### 4.10 `BodyRepository`

**storeBody(messageId, body, text, attachments, referenced, now)**
1. `guard message row exists else return` (no-op, `Log.db.notice`).
2. `html = body?.html ?? Schema.unavailableBodyHTML`; `hasRemote = body?.hasRemoteImages ?? false`; `strategy = body?.darkStrategy.rawValue ?? "plain"`; `version = sanitizerVersion` (the added parameter of DEVIATION D6 — `SanitizedBody` carries no version; 07 passes `Sanitizer.version`; a nil body is stored with the same version so it is not re-fetched on every open).
3. Upsert `MessageBodyRecord(messageId:, bodyHtml: html, bodyText: text, hasRemoteImages:, darkStrategy:, sanitizerVersion:, fetchedAt: now)`.
4. `DELETE FROM attachment WHERE messageId = ?`; for `a in attachments where !a.filename.isEmpty` (deferred text parts are excluded by their empty filename; duplicate partIds: last wins): insert `AttachmentRecord(messageId:, partId: a.partId, filename: a.filename, mimeType: a.mimeType, size: a.size, contentId: a.contentId, isInline: a.contentId.map(referenced.contains) ?? false, attachmentId: a.attachmentId)`.
5. `UPDATE message SET bodyState = 1, hasAttachments = ? WHERE id = ?` with `hasAttachments = inserted.contains { !$0.isInline }`.
`inlineData` is never stored (§3.4); a row with `attachmentId == nil` means the bytes were inline in `messages.get` and 08 re-fetches through `messages.get?format=full` (§10 A6).

**markUnavailable** / **resetUnavailable**: single `UPDATE message SET bodyState = ? WHERE id = ?` (2 / 0; `resetUnavailable` only `WHERE bodyState = 2`).

**missingBodyIds(threadId, sanitizerVersion)**:
```sql
SELECT m.id FROM message m LEFT JOIN message_body b ON b.messageId = m.id
WHERE m.threadId = ? AND m.isHidden = 0
  AND (m.bodyState = 0 OR (m.bodyState = 1 AND (b.messageId IS NULL OR b.sanitizerVersion < ?)))
ORDER BY m.internalDate DESC, m.id DESC
```

**updateAttachmentIds**: loop of `UPDATE attachment SET attachmentId = ? WHERE messageId = ? AND partId = ?` for parsed parts with non-nil `attachmentId`.

**pruneBodies(keepNewest)**: `victims = SELECT messageId FROM message_body ORDER BY fetchedAt DESC, messageId ASC LIMIT -1 OFFSET keepNewest`; if empty return 0; `DELETE FROM message_body WHERE messageId IN victims`; `UPDATE message SET bodyState = 0 WHERE id IN victims AND bodyState = 1`; `ThreadRepository.recomputeAggregates(db, threadIds: threadIds(of: victims), selfAddresses: SyncStateRepository.selfAddresses(db))`; return `victims.count`.

### 4.11 `OutboxRepository`

**enqueueModify(threadId, delta, affectedMessageIds, now)**
1. `guard !delta.isEmpty else { return nil }`.
2. `pendingOp = SELECT * FROM outbox WHERE kind = 'modify' AND state = 'pending' AND threadId = ? LIMIT 1` (index `outbox_thread`; invariant 4 guarantees ≤ 1).
3. If `pendingOp` exists: `merged = OutboxCoalescer.merge(existing: pendingOp.delta, new: delta)`; `affected = pendingOp.affectedSet ∪ affectedMessageIds`;
   - `merged.isEmpty` → `DELETE FROM outbox WHERE id = ?`; `result = nil`.
   - else → `UPDATE outbox SET addLabelIds = ?, removeLabelIds = ?, affectedMessageIds = ? WHERE id = ?` (sorted JSON each); `result = pendingOp.id`.
4. Else `INSERT INTO outbox (kind, state, attempts, nextAttemptAt, createdAt, threadId, addLabelIds, removeLabelIds, affectedMessageIds) VALUES ('modify', 'pending', 0, 0, now, threadId, sortedJSON(delta.add), sortedJSON(delta.remove), sortedJSON(affected))`; `result = db.lastInsertedRowID`; `affected = Set(affectedMessageIds)`.
5. `threads = MessageRepository.recomputeEffective(db, messageIds: affected)`; `ThreadRepository.recomputeAggregates(db, threadIds: threads ∪ [threadId], selfAddresses: SyncStateRepository.selfAddresses(db))`.
6. Return `result`. An `inFlight` op for the same thread is ignored (step 2 filters on `pending`); the new pending op is applied on top of it in E (id order) and sent in the next batch.

**enqueueSend(job, now)**: `INSERT INTO outbox (kind, state, attempts, nextAttemptAt, createdAt, threadId, sendJob, rfc822MessageId, transmitState) VALUES ('send', 'pending', 0, 0, now, job.threadId, RecordJSON.string(job), job.messageID, 'notSent')`; return `db.lastInsertedRowID`.

**claimModifies(limit, now)**: `ids = SELECT id FROM outbox WHERE kind = 'modify' AND state = 'pending' AND nextAttemptAt <= ? ORDER BY id LIMIT ?`; `UPDATE outbox SET state = 'inFlight', attempts = attempts + 1 WHERE id IN ids`; return `OutboxRecord` rows for `ids` in id order. **claimSend(now)**: same with `kind = 'send'`, `LIMIT 1`.

**ackModify(opId, serverLabelsByMessage)**
1. `guard let op = record(db, id: opId), op.kind == .modify else { return [] }`.
2. `touched = op.affectedSet`; for `id in touched`: if `let s = serverLabelsByMessage?[id]` → `applyServerLabels(id, s)` else `applyServerDelta(id, op.delta)`.
3. For `(id, s) in serverLabelsByMessage ?? [:] where !touched.contains(id)`: `applyServerLabels(id, s)` (no-op for unknown ids); `touched.insert(id)`.
4. `DELETE FROM outbox WHERE id = ?`.
5. `threads = recomputeEffective(touched)`; `recomputeAggregates(threads ∪ [op.threadId])`; return `threads ∪ [op.threadId]`.

**discardModify(opId)**: `guard op` → delete row → `threads = recomputeEffective(op.affectedSet)` → `recomputeAggregates(threads ∪ [op.threadId])` → return.

**retryLater(opId, error, countsAsAttempt, nextAttemptAt)**
1. `guard let op = record(opId) else return`.
2. `attempts = countsAsAttempt ? op.attempts : max(0, op.attempts - 1)`.
3. `limit = op.kind == .modify ? maxModifyAttempts : maxSendAttempts`; `state = attempts >= limit ? "failed" : "pending"`.
4. `UPDATE outbox SET state = ?, attempts = ?, nextAttemptAt = ?, lastError = ? WHERE id = ?` (`nextAttemptAt` as given; ignored by the claim query once failed). `Log.outbox.notice("op \(id) retry attempts=\(attempts) state=\(state)")`.

**fail**: `UPDATE outbox SET state = 'failed', lastError = ? WHERE id = ?`. **setTransmitState**: `UPDATE outbox SET transmitState = ? WHERE id = ? AND kind = 'send'`. **deleteSend**: as declared. **retrySend**: `UPDATE outbox SET state = 'pending', attempts = 0, nextAttemptAt = 0, lastError = NULL WHERE id = ? AND kind = 'send' AND state = 'failed'`. **releaseInFlight**: `UPDATE outbox SET state = 'pending' WHERE state = 'inFlight'`.

**rearmFailedModifies**
1. `failed = SELECT * FROM outbox WHERE kind = 'modify' AND state = 'failed' ORDER BY id`.
2. For each `f`: `pendingOp = pending op for f.threadId`; if exists: `merged = merge(existing: f.delta, new: pendingOp.delta)`; if `merged.isEmpty`: delete both rows; else: `UPDATE f SET add/remove = merged, affectedMessageIds = f.affected ∪ pending.affected` and delete `pendingOp`. Then (in both branches where `f` survives) `UPDATE outbox SET state = 'pending', attempts = 0, nextAttemptAt = 0, lastError = NULL WHERE id = f.id`.
3. E is unchanged (the set of active deltas per message is the same, applied in the same relative order because `f.id < pendingOp.id`), so no recompute. Invariant 4 holds after the call.

**activeModifies / activeThreadIds / referencedMessageIds / deleteFailedSends**: single `SELECT`/`DELETE` statements as declared; `referencedMessageIds` decodes `affectedMessageIds` of modify rows and `sendJob.originalMessageId` of send rows with `state IN ('pending','inFlight')`.

### 4.12 `Queries`

**threadsSQL(q)** (verbatim architecture §8.6, columns fixed):
```sql
-- inbox
SELECT id, subject, snippet, participants, lastDate, unreadCount, messageCount, hasAttachments, userLabelIds
FROM thread WHERE inInbox = 1 [AND unreadCount > 0] ORDER BY lastDate DESC LIMIT ?
-- today(day)
SELECT id, subject, snippet, participants, lastDate, unreadCount, messageCount, hasAttachments, userLabelIds
FROM thread WHERE inInbox = 1 AND lastInboxDate >= ? AND lastInboxDate < ? [AND unreadCount > 0] ORDER BY lastInboxDate DESC LIMIT ?
-- label(id)
SELECT t.id, t.subject, t.snippet, t.participants, t.lastDate, t.unreadCount, t.messageCount, t.hasAttachments, t.userLabelIds
FROM thread_label tl JOIN thread t ON t.id = tl.threadId
WHERE tl.labelId = ? [AND tl.unreadCount > 0] ORDER BY tl.lastDate DESC LIMIT ?
```
Arguments in order: today → `[startMs, endMs, limit]`; label → `[labelId, limit]`; inbox → `[limit]`. The `[AND …]` fragment is inserted only when `unreadOnly`.

**threads(q, now, timeZone, locale, labels)** returns `{ db in let (sql, args) = threadsSQL(q); let rows = try Row.fetchAll(db, sql: sql, arguments: args); let labeler = RowDateLabeler(now:timeZone:locale:); return rows.map { r in ThreadRow(id: r["id"], participants: r["participants"], subject: r["subject"], snippet: r["snippet"], dateLabel: labeler.label(epochMs: r["lastDate"]), isUnread: (r["unreadCount"] as Int) > 0, messageCount: r["messageCount"], hasAttachments: r["hasAttachments"], chips: chips(r["userLabelIds"], labels)) } }` where `chips(json, labels)` = `LabelAlgebra.parseJSON(json).sorted().compactMap { labels[$0] }.prefix(maxChips).map { ThreadChip(id: $0.id, name: $0.name, textColor: $0.textColor, backgroundColor: $0.backgroundColor) }`. Label ids absent from `labels` are skipped (label table not yet synced). `dateLabel` uses `lastDate` in every scope.

**threadDetail(threadId)**: `thread = ThreadRecord.fetchOne(db, key: threadId)` → nil → return nil; `messages = SELECT * FROM message WHERE threadId = ? AND isHidden = 0 ORDER BY internalDate ASC, id ASC`; `bodies = SELECT * FROM message_body WHERE messageId IN (message ids)` → dictionary; `attachments = SELECT * FROM attachment WHERE messageId IN (…) ORDER BY messageId, partId`.

**labelsForSheet**: `SELECT * FROM label WHERE id IN ('INBOX','STARRED','IMPORTANT','SENT') OR (type = 'user' AND (labelListVisibility IS NULL OR labelListVisibility = 'labelShow' OR (labelListVisibility = 'labelShowIfUnread' AND (threadsUnread IS NULL OR threadsUnread > 0)))) ORDER BY sortOrder, name COLLATE NOCASE`.

**labelsById**: `LabelRecord.fetchAll(db)` → `Dictionary(uniqueKeysWithValues:)`. **failedSends**: `SELECT * FROM outbox WHERE kind = 'send' AND state = 'failed' ORDER BY id`. **inboxUnreadThreadCount** / **todayThreadCount**: the two COUNT statements of §8.6. **outboxCounts**: `SELECT SUM(state IN ('pending','inFlight')), SUM(kind = 'send' AND state = 'failed') FROM outbox` (NULL → 0).

Performance: every list statement is served by one partial index (`thread_inbox_date`, `thread_inbox_unread`, `thread_inbox_today`, `thread_label_date`) and reads ≤ `limit` rows; target < 5 ms for 60 rows on a 5,000-message DB (§12.3 test). `ValueObservation.trackingConstantRegion` requires the closure to touch a constant region: the SQL text and tables do not depend on data, only on `q` (captured constant) — satisfied.

### 4.13 `AppEnvironment` (modify)

`init(testing:)` step 2 (the `// [06]` insertion point of 01 §4.10):
```swift
let dir: URL
let pool: DatabasePool
if testing {
    pool = try! AppDatabase.openTemporary(); dir = URL(fileURLWithPath: pool.path).deletingLastPathComponent()
} else {
    dir = try! AppDatabase.defaultDirectory()
    do { pool = try AppDatabase.open(directory: dir) }
    catch {                                                           // corrupt/unopenable file: rebuild once, never loop
        Log.db.error("open failed: \(String(describing: error), privacy: .public) — destroying and recreating")
        try? AppDatabase.destroy(directory: dir)
        pool = try! AppDatabase.open(directory: dir)                  // second failure is fatal (disk full / sandbox broken)
    }
}
db = pool; databaseDirectory = dir
```
Step 3 (04's `cachedEmail`): `let cachedEmail: String? = try? pool.read { try SyncStateRepository.get($0, .accountEmail) }` — one synchronous indexed read (< 1 ms), explicitly allowed by §12.2 step 1.
Step 9 hook: `auth.hooks.wipeAccountData = { [db] in await Task.detached { do { try AppDatabase.reset(db) } catch { Log.db.error("reset failed: \(String(describing: error), privacy: .public)") } }.value }` — 08 appends its cache purge and `webHost.recycle()` to the same closure.
DEVIATION D3: the pool is reset in place instead of "close → destroy → reopen" (§5.4) because `SyncEngine`, `Outbox`, `InlineImageStore`, `MailActions` are constructed with the pool object (§2.4) and GRDB's rule is one pool per file per process `[ios-platform §2.2]`; `AppDatabase.destroy` remains for tests and for the crash-recovery path above. Content-wise the outcome is identical (every row gone, file vacuumed).

---

## 5. Data

### 5.1 DDL — `Schema.v1SQL` (verbatim architecture §3.2; executed by `registerMigration("v1")`)

```sql
CREATE TABLE label (
  id                    TEXT PRIMARY KEY NOT NULL,      -- "INBOX", "Label_12"
  name                  TEXT NOT NULL,
  type                  TEXT NOT NULL,                  -- 'system' | 'user'
  labelListVisibility   TEXT,                           -- labelShow | labelShowIfUnread | labelHide | NULL
  messageListVisibility TEXT,                           -- show | hide | NULL
  textColor             TEXT,                           -- '#rrggbb' (user labels)
  backgroundColor       TEXT,
  messagesUnread        INTEGER,                        -- NULL until labels.get
  threadsUnread         INTEGER,
  threadsTotal          INTEGER,
  countsFetchedAt       INTEGER,                        -- epoch ms
  sortOrder             INTEGER NOT NULL DEFAULT 1000,  -- system pinned first, then user labels by name
  viewFetchedAt         INTEGER,                        -- non-NULL once messages.list for this label ran (label view cached)
  viewNextPageToken     TEXT                            -- "Load older" inside the label view
);

CREATE TABLE thread (
  id              TEXT PRIMARY KEY NOT NULL,
  subject         TEXT NOT NULL DEFAULT '',             -- oldest visible message, prefixes stripped
  snippet         TEXT NOT NULL DEFAULT '',             -- newest visible message
  lastDate        INTEGER NOT NULL,                     -- max(internalDate) of visible messages
  lastInboxDate   INTEGER,                              -- max(internalDate) of visible messages with INBOX in labelIds; NULL if none
  messageCount    INTEGER NOT NULL,
  unreadCount     INTEGER NOT NULL,
  inInbox         INTEGER NOT NULL,                     -- any visible message has INBOX (effective)
  hasAttachments  INTEGER NOT NULL,
  participants    TEXT NOT NULL DEFAULT '',             -- precomputed "Alice, Bob, Me"
  userLabelIds    TEXT NOT NULL DEFAULT '[]',           -- sorted JSON of user labels across visible messages (chips)
  isComplete      INTEGER NOT NULL DEFAULT 0,           -- 1 after threads.get was ingested
  bodiesMissing   INTEGER NOT NULL DEFAULT 0            -- visible messages with bodyState = 0
);
CREATE INDEX thread_inbox_date   ON thread(lastDate DESC)      WHERE inInbox = 1;
CREATE INDEX thread_inbox_unread ON thread(lastDate DESC)      WHERE inInbox = 1 AND unreadCount > 0;
CREATE INDEX thread_inbox_today  ON thread(lastInboxDate DESC) WHERE inInbox = 1;

CREATE TABLE thread_label (                             -- one row per (label, thread) over ALL labels of visible messages
  labelId     TEXT NOT NULL,
  threadId    TEXT NOT NULL,
  lastDate    INTEGER NOT NULL,                         -- copy of thread.lastDate
  unreadCount INTEGER NOT NULL,                         -- copy of thread.unreadCount
  PRIMARY KEY (labelId, threadId)
) WITHOUT ROWID;
CREATE INDEX thread_label_date ON thread_label(labelId, lastDate DESC);

CREATE TABLE message (
  id               TEXT PRIMARY KEY NOT NULL,
  threadId         TEXT NOT NULL,
  historyId        INTEGER NOT NULL DEFAULT 0,          -- uint64 string → Int64 (informational)
  internalDate     INTEGER NOT NULL,                    -- epoch ms; ordering key everywhere
  fromName         TEXT,
  fromAddr         TEXT NOT NULL DEFAULT '',
  isFromMe         INTEGER NOT NULL DEFAULT 0,          -- fromAddr ∈ selfAddresses
  toList           TEXT NOT NULL DEFAULT '[]',          -- JSON [{"addr":…,"name":…}]
  ccList           TEXT NOT NULL DEFAULT '[]',
  replyToList      TEXT NOT NULL DEFAULT '[]',
  subject          TEXT NOT NULL DEFAULT '',            -- RFC 2047-decoded, prefix kept
  snippet          TEXT NOT NULL DEFAULT '',            -- entity-decoded
  messageIdHeader  TEXT,                                -- '<…>'
  inReplyTo        TEXT,
  referencesList   TEXT NOT NULL DEFAULT '[]',          -- JSON ["<a>","<b>"]
  topMimeType      TEXT,                                -- payload.mimeType (format=metadata)
  serverLabelIds   TEXT NOT NULL DEFAULT '[]',          -- S: sorted JSON, last state told by the server
  labelIds         TEXT NOT NULL DEFAULT '[]',          -- E: sorted JSON = effective(S, pending deltas); the ONLY column the UI reads
  isUnread         INTEGER NOT NULL DEFAULT 0,          -- derived from labelIds
  inInbox          INTEGER NOT NULL DEFAULT 0,
  isHidden         INTEGER NOT NULL DEFAULT 0,          -- TRASH ∨ SPAM ∨ DRAFT ∨ CHAT
  hasAttachments   INTEGER NOT NULL DEFAULT 0,          -- hint (topMimeType = multipart/mixed) until bodyState = 1, then exact
  bodyState        INTEGER NOT NULL DEFAULT 0,          -- 0 none, 1 cached, 2 unavailable (404 / parse failure)
  syncGeneration   INTEGER NOT NULL DEFAULT 0,          -- generation of the full sync that (re)wrote this row
  fetchedAt        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX message_thread_date ON message(threadId, internalDate);
CREATE INDEX message_generation  ON message(syncGeneration);

CREATE TABLE message_body (
  messageId        TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  bodyHtml         TEXT NOT NULL,                       -- sanitized fragment (plain-text mails converted); never raw HTML
  bodyText         TEXT,                                -- decoded text/plain part, for quoting
  hasRemoteImages  INTEGER NOT NULL DEFAULT 0,
  darkStrategy     TEXT NOT NULL DEFAULT 'plain',       -- plain | card | native
  sanitizerVersion INTEGER NOT NULL,
  fetchedAt        INTEGER NOT NULL
);

CREATE TABLE attachment (
  messageId    TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  partId       TEXT NOT NULL,
  filename     TEXT NOT NULL,
  mimeType     TEXT NOT NULL,
  size         INTEGER NOT NULL DEFAULT 0,
  contentId    TEXT,                                    -- without <>
  isInline     INTEGER NOT NULL DEFAULT 0,              -- referenced by cid: in the sanitized HTML
  attachmentId TEXT,                                    -- TRANSIENT cache; re-resolved via messages.get on 404 [gmail-api §6]
  PRIMARY KEY (messageId, partId)
) WITHOUT ROWID;

CREATE TABLE outbox (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT, -- execution order
  kind               TEXT NOT NULL,                     -- 'modify' | 'send'
  state              TEXT NOT NULL DEFAULT 'pending',   -- pending | inFlight | failed
  attempts           INTEGER NOT NULL DEFAULT 0,
  nextAttemptAt      INTEGER NOT NULL DEFAULT 0,        -- epoch ms
  createdAt          INTEGER NOT NULL,
  lastError          TEXT,
  -- kind = 'modify' (thread-level ops only in stage 1)
  threadId           TEXT,
  addLabelIds        TEXT,                              -- sorted JSON
  removeLabelIds     TEXT,                              -- sorted JSON
  affectedMessageIds TEXT,                              -- JSON: message ids the delta applies to locally (snapshot at enqueue, unioned on coalesce)
  -- kind = 'send'
  sendJob            TEXT,                              -- JSON SendJob (§2.4)
  rfc822MessageId    TEXT,                              -- '<uuid@domain>'
  transmitState      TEXT                               -- notSent | maybeSent
);
CREATE INDEX outbox_due    ON outbox(state, nextAttemptAt);
CREATE INDEX outbox_thread ON outbox(threadId) WHERE kind = 'modify';

CREATE TABLE syncState (
  key   TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;
```
Pragmas: GRDB sets `PRAGMA foreign_keys = ON` per connection (`foreignKeysEnabled`), WAL journal for the pool; nothing else. `sqlite_master` after migration contains the 8 tables, the 8 named indexes, `sqlite_autoindex_*` entries for the TEXT primary keys, `sqlite_sequence`, and GRDB's `grdb_migrations` (name UNVERIFIED — tests filter on `Schema.tableNames`/`indexNames` only).

### 5.2 JSON column formats (`RecordJSON`: `.sortedKeys`, `.withoutEscapingSlashes`, dates `millisecondsSince1970`)

| Column | Example bytes |
|---|---|
| `message.toList` | `[{"addr":"bob@example.com","name":"Bob"},{"addr":"user@newtelco.de"}]` (nil `name` omitted) |
| `message.referencesList` | `["<root@example.com>","<m-plain@example.com>"]` |
| `message.serverLabelIds` / `labelIds` / `thread.userLabelIds` / `outbox.addLabelIds` / `removeLabelIds` / `affectedMessageIds` | `["INBOX","Label_12","UNREAD"]` — `LabelAlgebra.sortedJSON` bytes; `[]` when empty |
| `syncState.selfAddresses` | `["alias@newtelco.de","user@newtelco.de"]` |
| `outbox.sendJob` | `{"attachments":[{"attachmentId":"ANGjdJ…","filename":"a.pdf","mimeType":"application/pdf","partId":"2","size":1234}],"cc":[],"includeSignature":true,"inReplyTo":"<m-plain@example.com>","messageID":"<8F0A…@newtelco.de>","mode":"replyAll","originalMessageId":"m-plain","quoteSource":{"author":{"addr":"alice@example.com","name":"Alice"},"cc":[],"date":1757488353000,"html":"<div>hi</div>","subject":"Plain hello","text":"hi","to":[{"addr":"user@newtelco.de"}]},"references":["<m-plain@example.com>"],"subject":"Re: Plain hello","threadId":"t-plain","to":[{"addr":"alice@example.com","name":"Alice"}],"typedText":"Thanks!"}` |

`QuoteSource.date` therefore round-trips as an integer millisecond count (no float drift).

### 5.3 `syncState` keys and value formats

| `SyncKey` | Value | Writer |
|---|---|---|
| `historyId` | decimal `UInt64` string, e.g. `"1234567"`; never decreases except `setHistoryId(_, allowDecrease: true)` (full resync) | 07 |
| `syncGeneration` | decimal `Int`, starts at `1` on the first full sync | 07 |
| `lastFullSyncAt`, `lastDeltaSyncAt`, `lastLabelCountsAt`, `lastCleanupAt` | epoch ms decimal | 07 |
| `accountEmail` | `"user@newtelco.de"` (routing key of §5.2) | 07 |
| `displayName` | `"Jane Doe"` | 07 |
| `selfAddresses` | sorted, lowercased JSON `[String]` | 07 |
| `sendAsSignature` | raw HTML from `sendAs.signature` (import source only) | 07 |
| `inboxNextPageToken` | opaque token; deleted (`set(_, nil)`) when the last page was reached | 07 |

### 5.4 Label `sortOrder` values

`INBOX` 0, `STARRED` 10, `IMPORTANT` 20, `SENT` 30, every other system label 500, every user label 1000 (then `name COLLATE NOCASE`).

### 5.5 Outbox row examples

Modify (archive + mark read coalesced): `(id 7, kind 'modify', state 'pending', attempts 0, nextAttemptAt 0, createdAt 1757500000000, threadId 't1', addLabelIds '[]', removeLabelIds '["INBOX","UNREAD"]', affectedMessageIds '["m1","m2"]')`.
Send after one transient failure: `(id 8, kind 'send', state 'pending', attempts 1, nextAttemptAt 1757500002000, lastError 'server(status: 503)', threadId 't-plain', sendJob '{…}', rfc822MessageId '<8F0A…@newtelco.de>', transmitState 'maybeSent')`.

### 5.6 `Fixtures/vectors/today.json`

```json
{"cases":[
 {"name":"berlin-normal",    "tz":"Europe/Berlin",    "now":"2026-09-11T13:00:00Z", "startMs":1757541600000, "endMs":1757628000000},
 {"name":"berlin-dst-start", "tz":"Europe/Berlin",    "now":"2026-03-29T12:00:00Z", "startMs":1774738800000, "endMs":1774821600000},
 {"name":"berlin-dst-end",   "tz":"Europe/Berlin",    "now":"2026-10-25T12:00:00Z", "startMs":1777068000000, "endMs":1777158000000},
 {"name":"auckland-dst-start","tz":"Pacific/Auckland","now":"2026-09-27T05:00:00Z", "startMs":1758888000000, "endMs":1758970800000},
 {"name":"utc",              "tz":"UTC",              "now":"2026-01-01T00:00:00Z", "startMs":1767225600000, "endMs":1767312000000},
 {"name":"berlin-just-before-midnight","tz":"Europe/Berlin","now":"2026-09-11T21:59:59.999Z","startMs":1757541600000,"endMs":1757628000000},
 {"name":"berlin-midnight",  "tz":"Europe/Berlin",    "now":"2026-09-11T22:00:00Z", "startMs":1757628000000, "endMs":1757714400000}
]}
```
Derivation: Europe/Berlin is UTC+2 on 2026-09-11 (local midnight = 22:00Z of the previous day); 2026-03-29 local midnight = 23:00Z (UTC+1), day length 23 h; 2026-10-25 local midnight = 22:00Z (UTC+2), day length 25 h; Pacific/Auckland 2026-09-27 local midnight = 12:00Z of 09-26 (UTC+12), day length 23 h. The implementing agent recomputes these seven numbers with `TZ=<tz> date -d '<local midnight>' +%s` before committing; a mismatch means the vector, not the code, is wrong.

---

## 6. UI

Not a screen module. Contract for screen modules: they read only `Queries.*` results and record structs; they never write SQL, never read `serverLabelIds`, and format nothing in `body` (`ThreadRow` arrives finished). Theme, SF Symbols and accessibility belong to 09–13.

---

## 7. Tests

Package tests run with `cd Packages/MailCore && swift test` (Linux + macOS). App tests run with `make test-app` on the macOS runner (`xcodebuild test … -only-testing:minimailTests`). `XCTest` throughout. Every `RepositoryTests`/`QueriesTests` function ends with `try InvariantChecks.assertAll(q)` (the in-memory queue) unless stated.

### 7.1 Package tests

| File | Test | Setup | Assertions |
|---|---|---|---|
| `LabelAlgebraTests.swift` | `testAppliedRemovesThenAdds` | `LabelDelta(add: ["A"], remove: ["A","B"])` on `["B","C"]` | result `== ["A","C"]` (add wins over remove for `A`) |
| | `testEffectiveFoldsInOrder` | S `["INBOX","UNREAD"]`, pending `[remove UNREAD, add UNREAD, remove INBOX]` | `== ["UNREAD"]` |
| | `testEffectiveNoPending` | S `["X"]`, `[]` | `== ["X"]` |
| | `testFlagsMatrix` | sets `[]`, `["UNREAD"]`, `["INBOX"]`, `["TRASH"]`, `["SPAM","INBOX","UNREAD"]`, `["DRAFT"]`, `["CHAT"]` | flags `(f,f,f)`, `(t,f,f)`, `(f,t,f)`, `(f,f,t)`, `(t,t,t)`, `(f,f,t)`, `(f,f,t)` |
| | `testSortedJSONBytes` | `["UNREAD","INBOX","Label_12"]`, `[]` | `== "[\"INBOX\",\"Label_12\",\"UNREAD\"]"`, `== "[]"` |
| | `testSortedJSONEscaping` | `["a\"b", "c/d", "é"]` | `== "[\"a\\\"b\",\"c/d\",\"é\"]"` |
| | `testParseJSONRoundTripAndMalformed` | sortedJSON of a set; `"nope"`, `"[1]"` | `parseJSON(sortedJSON(s)) == s`; malformed → `[]` |
| | `testUserVisible` | `["Label_2","INBOX","CATEGORY_PROMOTIONS","Label_1","STARRED","IMPORTANT","SENT","UNREAD","DRAFT","CHAT","SPAM","TRASH"]` | `== ["Label_1","Label_2"]`; `isSystem("CATEGORY_X") == true`; `isSystem("Label_1") == false` |
| | `testLabelDeltaCodableSorted` | encode `LabelDelta(add: ["B","A"], remove: ["Z"])` with sortedKeys | bytes `{"add":["A","B"],"remove":["Z"]}`; decode round-trips; decoding `{"add":["A","A"],"remove":[]}` → `add == ["A"]` |
| | `testIsEmpty` | `LabelDelta()` / `(add: ["A"])` | `true` / `false` |
| `OutboxCoalescerTests.swift` | `testInverseCancels` | existing remove UNREAD; new add UNREAD | `merged.isEmpty` |
| | `testArchiveThenRead` | remove INBOX; remove UNREAD | `add == []`, `remove == ["INBOX","UNREAD"]` |
| | `testNewIntentWins` | remove INBOX; add INBOX + remove UNREAD | `add == ["INBOX"]`, `remove == ["UNREAD"]` |
| | `testIdempotent` | same delta twice | `merged == delta` |
| | `testMergeIntoEmpty` | `LabelDelta()`; new d | `== d` |
| `ThreadAggregatorTests.swift` | `testEmptyReturnsNil` | `[]` | `nil` |
| | `testSubjectFromOldestStripped` | m1 (t=1, "Re: Fwd: Angebot"), m2 (t=2, "AW: Angebot") | `subject == "Angebot"` |
| | `testSnippetFromNewest` | m1 (t=1,"old"), m2 (t=2,"new") in reversed input order | `snippet == "new"`, `lastDate == 2` |
| | `testCounts` | 3 messages: unread, unread+attachment, read; bodyState 0,1,2 | `messageCount 3`, `unreadCount 2`, `hasAttachments true`, `bodiesMissing 1` |
| | `testLastInboxDateIgnoresNonInboxAndSelfSent` | m1 t=1 INBOX from alice; m2 t=2 INBOX isFromMe; m3 t=3 no INBOX | `lastInboxDate == 1`, `inInbox == true`, `lastDate == 3` |
| | `testLastInboxDateNilWhenNone` | one message without INBOX | `lastInboxDate == nil`, `inInbox == false` |
| | `testLastInboxDateSelfViaSelfAddresses` | m from `Me@NewTelco.de`, `isFromMe false`, selfAddresses `["me@newtelco.de"]` | `lastInboxDate == nil`, `participants == "Me"` |
| | `testParticipantsOrderDedupeMe` | alice t=1, me t=2, alice t=3 (`Alice@Example.com`), bob t=4 | `participants == "Alice, Me, Bob"` |
| | `testParticipantsMaxThree` | alice, bob, carol, dave | `== "Alice, Bob, Carol…"` |
| | `testFirstNameRules` | `("Alice Müller","a@x")`, `("Müller, Bob","b@x")`, `("\"Carol Q\"","c@x")`, `(nil,"dave@x")`, `("  ","eve@x")`, `(nil,"")` | `"Alice"`, `"Bob"`, `"Carol"`, `"dave"`, `"eve"`, `"?"` |
| | `testUserLabelIdsAndAllLabelIds` | m1 `["INBOX","Label_2"]`, m2 `["Label_1","UNREAD","CATEGORY_UPDATES"]` | `userLabelIds == ["Label_1","Label_2"]`; `allLabelIds == ["CATEGORY_UPDATES","INBOX","Label_1","Label_2","UNREAD"]` |
| | `testInputOrderIndependent` | same 4 messages shuffled 3 ways | equal aggregates |
| `DayBoundaryTests.swift` | `testVectors` | `Fixture.json("vectors/today.json", as: TodayVectors.self)`; `ISO8601DateFormatter` with fractional seconds for `now` | for each case `DayBoundary.today(now:, timeZone: TimeZone(identifier: tz)!) == DayBoundary(startMs:, endMs:)` |
| | `testDSTLengths` | Berlin 2026-03-29, 2026-10-25, Auckland 2026-09-27 | `endMs − startMs` == 23 h, 25 h, 23 h (ms) |
| | `testContainsEdges` | berlin-normal boundary | `contains(startMs)`, `contains(endMs − 1)`, `!contains(endMs)`, `!contains(startMs − 1)` |
| | `testLabelTodayTime` | now 2026-09-11 15:00 Berlin, msg 14:32 same day; locales de_DE, en_US | de `== "14:32"`; en matches `^2:32[ \u{202F}]PM$` |
| | `testLabelYesterdayAcrossMidnight` | now 2026-09-12 00:00:30 Berlin, msg 2026-09-11 23:59:59 | `== "Yesterday"` |
| | `testLabelWeekday` | now Friday 2026-09-11; msg Monday 2026-09-07 10:00; msg 2026-09-05 (6 days ago) ; msg 2026-09-04 (7 days ago) | first two `== reference("EEE")` output for those dates; the 7-days-ago one `== reference("d MMM")` |
| | `testLabelSameYear` | msg 2026-01-15 | `== reference("d MMM")`; de contains `"15"`, en contains `"Jan"` |
| | `testLabelOtherYear` | msg 2025-09-11 | de `== "11.09.25"`; en `== reference shortDate` |
| | `testLabelFutureSameDay` | msg now + 1 h | equals the short-time string |
| | `testStaticMatchesLabeler` | any 5 dates | `RowDateLabel.label(...) == RowDateLabeler(...).label(...)` |

`reference(template)` in the test file builds a `DateFormatter` with the same locale/timeZone/template and formats the same date (locks behaviour, tolerates ICU differences). `TodayVectors` is a private `Decodable` struct in the test file.

### 7.2 App tests (`xcodebuild test`)

| File | Test | Setup | Assertions |
|---|---|---|---|
| `Store/DatabaseTests.swift` | `testFreshSchemaMatchesDDL` | `AppDatabase.openInMemory()`; `SELECT type, name, sql FROM sqlite_master` | table names ⊇ `Schema.tableNames`, index names ⊇ `Schema.indexNames`; for each table, `normalize(sql) == normalize(statement from Schema.v1SQL)` where `normalize` strips `--` comments and collapses whitespace |
| | `testForeignKeysOnAndCascade` | insert message + body + attachment via records; `PRAGMA foreign_keys`; delete message | pragma `== 1`; body and attachment rows gone |
| | `testPoolIsWAL` | `openTemporary()`; `PRAGMA journal_mode` | `== "wal"`; `pool.path` ends with `db.sqlite`; tearDown `close` + `destroy` |
| | `testOpenIsIdempotent` | `open(directory:)` twice on the same temp dir (close between) | second open succeeds; `migrator.hasCompletedMigrations` true; row count of a seeded `syncState` key survives |
| | `testDestroyRemovesDirectory` | temp pool closed; `destroy` | `FileManager.fileExists(dir) == false`; second `destroy` does not throw |
| | `testResetLeavesEmptyMigratedSchema` | temp pool seeded with `seedMany(count: 40)` + outbox row; `reset` | every table `COUNT(*) == 0`; `sqlite_master` still has all names; inserting an outbox row yields `id == 1` (sequence reset); `open` again on the same dir is a no-op |
| | `testInvariantsHoldOnEmptyDB` | fresh queue | `InvariantChecks.assertAll` passes |
| | `testOpenRecoversFromGarbageFile` | write 100 random bytes to `dir/db.sqlite`; `AppDatabase.open` | throws `DatabaseError`; after `destroy` + `open` succeeds (mirrors the `AppEnvironment` path) |
| `Store/RepositoryTests.swift` | `testUpsertMetadataMapsColumns` | `parsed(id:"m1", …)` with cc, reply-to, references, `topMimeType "multipart/mixed"`, labels `["UNREAD","INBOX"]` | `MessageRecord` fields equal the inputs; `serverLabelIds == labelIds == ["INBOX","UNREAD"]`; `isUnread`, `inInbox` true; `hasAttachments == true` (hint); `bodyState == 0`; `syncGeneration == 1`; `fetchedAt == now`; returned thread ids `== ["m1"]`; thread row exists after `recomputeAggregates` |
| | `testUpsertKeepsBodyAndExactAttachments` | seed m1; `storeBody` with no attachments (`hasAttachments` false, bodyState 1); upsert m1 again with `multipart/mixed` | `bodyState == 1`, `hasAttachments == false`, body row unchanged |
| | `testUpsertRecomputesEWithPendingOp` | seed m1 `["INBOX","UNREAD"]`; `enqueueModify(remove UNREAD)`; upsert m1 with server `["INBOX","UNREAD"]` | `serverLabelIds == ["INBOX","UNREAD"]`, `labelIds == ["INBOX"]`, `isUnread == false` (the SIMPLE race) |
| | `testApplyServerLabelsAndDelta` | seed m1 `["INBOX"]`; `applyServerLabels(["INBOX","STARRED"])`; `applyServerDelta(remove INBOX, add UNREAD)`; `recomputeEffective` | S `== ["STARRED","UNREAD"]`; E equal; unknown id → no throw |
| | `testRecomputeEffectiveOrder` | seed m1 `["INBOX"]`; ops: #1 inFlight remove INBOX (inserted via `enqueueModify` + `claimModifies`), #2 pending add INBOX | E `== ["INBOX"]` (later op wins); after `ackModify(#1, nil)` S `== []`, E `== ["INBOX"]` |
| | `testEnqueueModifyInsertsAndAppliesInstantly` | seed thread t1 (m1 unread, m2 read, both INBOX); `enqueueModify(t1, remove INBOX, [m1,m2])` | returns id; `thread.inInbox == false`; `thread_label` has no `INBOX` row; op columns per §5.5 |
| | `testEnqueueInverseCancelsToZeroRows` | remove UNREAD then add UNREAD on t1 | second call returns nil; `outbox` count 0; `thread.unreadCount` back to 1 |
| | `testEnqueueArchiveThenReadMerges` | remove INBOX, then remove UNREAD | one row; `removeLabelIds == ["INBOX","UNREAD"]`; affected union |
| | `testEnqueueDoesNotMergeIntoInFlight` | enqueue A; `claimModifies`; enqueue B | two rows: A inFlight, B pending; `pendingModifies().count == 1` |
| | `testEnqueueEmptyDeltaIsNoop` | `LabelDelta()` | nil, no rows |
| | `testAckModifyWithoutServerLabels` | archive op on t1; `ackModify(id, nil)` | op gone; S of m1,m2 `== ["UNREAD"]`/`[]` minus INBOX; E == S; returns `["t1"]` |
| | `testAckModifyWithServerLabels` | archive op; `ackModify(id, ["m1": ["UNREAD","STARRED"], "m9": ["INBOX"]])` | m1 S `== ["STARRED","UNREAD"]`; m2 S = delta applied; m9 ignored; E == S |
| | `testAckUnknownOp` | `ackModify(999, nil)` | `== []`, no throw |
| | `testDiscardModifyRevertsE` | mark-read op on t1; `discardModify` | `m1.isUnread == true`; `thread.unreadCount == 1`; op gone |
| | `testRetryLaterCountsAndFailsAfterEight` | op claimed 8 times with `retryLater(countsAsAttempt: true, nextAttemptAt: 5)` between | after each: state pending, `nextAttemptAt == 5`, attempts n; after the 8th: `state == .failed`, never deleted |
| | `testRetryLaterNotCountedDecrements` | claim (attempts 1) → `retryLater(countsAsAttempt: false)` | `attempts == 0`, pending |
| | `testRetryLaterSendFailsAfterFive` | send op claimed 5× | failed after the 5th |
| | `testFailAndRetrySend` | send op `fail("badRequest")`; `retrySend`; `setTransmitState(.maybeSent)`; `deleteSend` | failed with lastError; then pending/attempts 0/lastError nil; transmitState `maybeSent`; then row gone; `deleteSend` on a modify id leaves it |
| | `testClaimModifiesDueOnlyAndOrder` | ops with nextAttemptAt 0, 10, 20; `claimModifies(limit: 2, now: 15)` | returns ids [1,2] with `state == .inFlight`, `attempts == 1`; third untouched |
| | `testClaimSendOldest` | two pending sends | first id returned, second untouched; second call returns the other |
| | `testReleaseInFlight` | one inFlight modify + one inFlight send | both pending; attempts unchanged |
| | `testRearmFailedModifies` | failed op (attempts 8) | pending, attempts 0, nextAttemptAt 0 |
| | `testRearmMergesIntoPending` | failed A (remove INBOX) + pending B (remove UNREAD) same thread | one row (A's id), `removeLabelIds == ["INBOX","UNREAD"]`, affected union, pending; E unchanged before/after |
| | `testStaleIdsExcludesOutboxReferenced` | m1,m2 gen 1; m3 gen 2; pending op affecting m2; send job originalMessageId m1 | `staleIds(olderThanGeneration: 2) == []`; delete the ops → `== ["m1","m2"]` |
| | `testDeleteReturnsThreadIdsAndCascades` | t1 (m1 with body+attachment), t2 (m2) | `delete([m1]) == ["t1"]`; body/attachment gone; after `recomputeAggregates(["t1"])` thread t1 gone, `thread_label` for t1 gone |
| | `testRecomputeAggregatesWritesThreadLabel` | t1: m1 `["INBOX","Label_12"]`, m2 `["INBOX","UNREAD"]` | `thread_label` rows == {INBOX, Label_12, UNREAD} with `lastDate == m2.date`, `unreadCount == 1`; `thread.userLabelIds == ["Label_12"]` |
| | `testRecomputeAggregatesHiddenOnly` | t1: m1 TRASH only | no thread row; message row exists |
| | `testRecomputeKeepsIsComplete` | `markComplete(t1, true)`; recompute | `isComplete == true` |
| | `testMessageIdsIncludesHidden` | t1: m1 visible, m2 TRASH | `messageIds(t1) == ["m1","m2"]` (date order) |
| | `testStoreBodySetsStateAndAttachments` | m1; `storeBody(body: SanitizedBody(html:"<p>x</p>", hasRemoteImages: true, darkStrategy: .card, referencedContentIDs: ["img1"]), text: "x", attachments: [inline img1 (contentId "img1"), "a.pdf", deferred (filename "")], referenced: ["img1"], sanitizerVersion: 1, now:)` | body row equals; attachment rows: img1 `isInline true`, a.pdf `false`; `bodyState == 1`; `hasAttachments == true`; `thread.bodiesMissing == 0` after recompute |
| | `testStoreBodyNilFallback` | `storeBody(body: nil, …)` | `bodyHtml == Schema.unavailableBodyHTML`, `darkStrategy == "plain"`, `bodyState == 1` |
| | `testStoreBodyUnknownMessageNoop` | id "nope" | no rows, no throw |
| | `testMarkAndResetUnavailable` | m1 | `markUnavailable` → 2; `resetUnavailable` → 0; `resetUnavailable` on 1 leaves 1 |
| | `testMissingBodyIdsOrderAndStale` | t1: m1 (t=1, bodyState 0), m2 (t=2, body v1), m3 (t=3, body v2), m4 (t=4, state 2), m5 hidden state 0 | `missingBodyIds(t1, sanitizerVersion: 2) == ["m2","m1"]` |
| | `testUpdateAttachmentIds` | attachment row partId "2" id "old"; parsed with partId "2" id "new", partId "9" | `attachment(m1,"2").attachmentId == "new"`; "9" absent |
| | `testPruneBodies` | 5 bodies with fetchedAt 1…5; `pruneBodies(keepNewest: 2)` | `== 3`; remaining fetchedAt {4,5}; pruned messages `bodyState == 0`; their threads' `bodiesMissing` updated |
| | `testLabelReplaceAllKeepsCountsAndColor` | `replaceAll(sampleLabels)`; `updateCounts` Label_12 (3 unread, colour); `replaceAll` again with Label_12 without colour and without Label_14 | Label_12 keeps `threadsUnread == 3` and colour; Label_14 row gone; INBOX `sortOrder == 0`, SENT 30, TRASH 500, Label_12 1000 |
| | `testMarkViewFetchedAndCachedIds` | `markViewFetched(Label_12, "tok", now)` | `cachedViewLabelIds() == ["Label_12"]`; token stored; `markViewFetched(…, nil, …)` clears the token |
| | `testDisplayedLabelIds` | sampleLabels | `== ["INBOX","STARRED","IMPORTANT","SENT","Label_12","Label_14"]` (sortOrder, then name: "Customers/ACME" before "IfUnread"); Label_13 (labelHide), TRASH, CATEGORY_PROMOTIONS excluded; `cap: 5` → first 5 |
| | `testSyncStateRoundTrip` | set/get/nil | `get == value`; `set(nil)` deletes; `int64`, `all()` |
| | `testSetHistoryIdNeverDecreases` | set 100; set 50; set 50 allowDecrease | 100; 100; 50 |
| | `testSelfAddresses` | `setSelfAddresses(["B@x","a@x"])` | `get(.selfAddresses) == "[\"a@x\",\"b@x\"]"`; `selfAddresses() == ["a@x","b@x"]`; absent → `[]` |
| | `testDeleteExpiredThreads` | t1 archived read lastDate old; t2 archived read old but Label_12 (protected); t3 old but pending op; t4 inbox old; t5 archived unread old | `deleteExpired(olderThan: now − 30 d, protectedLabelIds: ["Label_12"], protectedThreadIds: ["t3"]) == 1`; only t1 (and its messages) gone |
| | `testDeleteFailedSends` | failed send createdAt old, failed send new, pending old | `== 1` |
| `Store/QueriesTests.swift` | `testInboxScope` | `seedMany(count: 200)` | ids == threads with `inInbox = 1` ordered by `lastDate DESC`, count ≤ 60; no hidden-only thread present |
| | `testInboxUnreadOnly` | same | every row `isUnread`; set == expected |
| | `testTodayScope` | seed 3 threads: A inbox received today, B inbox received yesterday but replied today (self-sent), C archived today | rows == [A] with `DayBoundary.today(now:…)`; `todayThreadCount == 1` |
| | `testTodayUnreadOnly` | A unread, D today read | `[A]` |
| | `testLabelScope` | seedMany; `.label(id: "Label_12")` | ids == `SELECT threadId FROM thread_label WHERE labelId = 'Label_12' ORDER BY lastDate DESC LIMIT 60` |
| | `testLabelUnreadOnly` | same | subset with `unreadCount > 0` |
| | `testLimitPaging` | `limit 60` vs `120` | first 60 of the second == first |
| | `testExplainQueryPlanUsesIndexes` | `EXPLAIN QUERY PLAN` of `threadsSQL` for inbox / inbox+unread / today / label | detail strings contain `thread_inbox_date`, `thread_inbox_unread`, `thread_inbox_today`, `thread_label_date` respectively |
| | `testInboxQueryUnder5msWith5000Messages` | `seedMany(count: 5000)`; warm once; 20 timed runs of the closure | median < 5 ms (`XCTAssertLessThan`); also `measure {}` block for the report |
| | `testThreadRowPrecomputation` | thread with alice, me, bob; labels Label_12 + Label_1 + Label_9 (only 12 and 1 in the label table) | `participants == "Alice, Me, Bob"`; `dateLabel == RowDateLabeler(...).label(lastDate)`; `chips.map(\.id) == ["Label_1","Label_12"]` (sorted, ≤ 2, unknown skipped); chip colours from the label rows; `isUnread`, `messageCount == 3` |
| | `testThreadDetail` | t1 with 2 visible + 1 hidden message, 1 body, 2 attachments | `messages.count == 2` ascending; `bodies.keys == [m1]`; attachments ordered (messageId, partId); unknown id → nil |
| | `testLabelsForSheet` | sampleLabels; Label_14 (`labelShowIfUnread`) with `threadsUnread 0` then 2 | order `[INBOX, STARRED, IMPORTANT, SENT, Label_12]` then with Label_14 appended when unread > 0; Label_13, TRASH, CATEGORY excluded |
| | `testLabelsById` | sampleLabels | `labelsById().count == sampleLabels.count`; `["Label_12"]?.name == "Customers/ACME"` |
| | `testFailedSendsAndOutboxCounts` | 1 pending modify, 1 inFlight send, 1 failed send, 1 failed modify | `failedSends().count == 1`; `outboxCounts == (pending: 2, failed: 1)` |
| | `testInboxUnreadThreadCount` | seedMany(200) | equals `SELECT COUNT(*) … inInbox = 1 AND unreadCount > 0` |
| `App/AppEnvironmentTests.swift` | `testTestingModeOpensTemporaryDatabase` | `AppEnvironment(testing: true)` | `env.databaseDirectory.path.contains("minimail-db-")`; `try env.db.read { try SyncStateRepository.get($0, .accountEmail) } == nil` |
| | `testCachedEmailReadFromSyncState` | temp dir with `accountEmail = "x@newtelco.de"` written through `AppDatabase.open`; construct `AppEnvironment` pointing at it (via a `testing: true` env whose pool is then seeded and a second init reading the same directory — use the internal `init(testing:databaseDirectory:)` overload added for tests) | `auth.state == .needsReauth("x@newtelco.de")` when no Keychain item (04 truth table) |
| | `testWipeAccountDataResetsDatabase` | seed a message; `await env.auth.hooks.wipeAccountData()` | `message` count 0; `env.db` still usable (`read` succeeds) |

`AppEnvironment` gains an internal convenience `init(testing: Bool, databaseDirectory: URL?)` (nil → the default behaviour) for the second test; the public `init(testing:)` forwards `nil`.

---

## 8. Tasks

- [ ] **T06.1 LabelAlgebra + OutboxCoalescer** — files: `Sources/MailCore/Sync/LabelAlgebra.swift`, `Sources/MailCore/Sync/OutboxCoalescer.swift`, `Tests/MailCoreTests/LabelAlgebraTests.swift`, `Tests/MailCoreTests/OutboxCoalescerTests.swift`. Done when §3.1–§3.2 compile with the exact signatures and all 14 tests of §7.1 for these files pass. Verify: `cd Packages/MailCore && swift test --filter 'LabelAlgebraTests|OutboxCoalescerTests'`.
- [ ] **T06.2 ThreadAggregator** — files: `Sources/MailCore/Sync/ThreadAggregator.swift`, `Tests/MailCoreTests/ThreadAggregatorTests.swift`. Done when the 12 tests pass (uses `SubjectPrefix.stripForDisplay` from 02 and `LabelAlgebra.userVisible`). Verify: `swift test --filter ThreadAggregatorTests`.
- [ ] **T06.3 DayBoundary + RowDateLabel** — files: `Sources/MailCore/Support/DayBoundary.swift`, `Tests/MailCoreTests/DayBoundaryTests.swift`, `Tests/MailCoreTests/Fixtures/vectors/today.json`. Done when the 10 tests pass on Linux and macOS (recompute the seven vector timestamps with `TZ=… date` first). Verify: `swift test --filter DayBoundaryTests` (Linux) and `make core-test` (macOS in CI).
- [ ] **T06.4 SanitizedBody + Schema + AppDatabase** — files: `Sources/MailHTML/SanitizedBody.swift`, `minimail/Store/Schema.swift`, `minimail/Store/Database.swift`, `minimailTests/Store/DatabaseTests.swift` (all but the cascade test), `minimailTests/Support/TestDatabase.swift` (`make()` only). Done when `make build` passes and `testFreshSchemaMatchesDDL`, `testPoolIsWAL`, `testOpenIsIdempotent`, `testDestroyRemovesDirectory`, `testResetLeavesEmptyMigratedSchema`, `testOpenRecoversFromGarbageFile` pass. Verify: `make test-one T=minimailTests/DatabaseTests`.
- [ ] **T06.5 Records** — files: `minimail/Store/Records.swift`; add `testForeignKeysOnAndCascade` to `DatabaseTests`. Done when every record round-trips through insert + `fetchOne` with the JSON bytes of §5.2 (add a `testRecordJSONBytes` in `DatabaseTests` asserting `RecordJSON.string(SendJob sample)` equals the §5.2 literal and `toList` bytes). Verify: `make test-one T=minimailTests/DatabaseTests`.
- [ ] **T06.6 SyncStateRepository + LabelRepository** — files: `minimail/Store/SyncStateRepository.swift`, `minimail/Store/LabelRepository.swift`, `minimailTests/Support/TestDatabase.swift` (`seedLabels`, `sampleLabels`), `minimailTests/Store/RepositoryTests.swift` (the 6 label/syncState tests), `minimailTests/Support/InvariantChecks.swift` (skeleton: invariants 4 and 6 only, extended in T06.8). Verify: `make test-one T=minimailTests/RepositoryTests`.
- [ ] **T06.7 MessageRepository + ThreadRepository** — files: `minimail/Store/MessageRepository.swift`, `minimail/Store/ThreadRepository.swift`, `TestDatabase.swift` (`parsed`, `seed`, `seedMany`), `RepositoryTests.swift` (upsert/apply/recompute/delete/stale/aggregate/messageIds/deleteExpired tests), `InvariantChecks.swift` (invariants 1–3 complete). Verify: `make test-one T=minimailTests/RepositoryTests`.
- [ ] **T06.8 BodyRepository** — files: `minimail/Store/BodyRepository.swift`, `RepositoryTests.swift` (body/attachment/prune tests). Verify: `make test-one T=minimailTests/RepositoryTests`.
- [ ] **T06.9 OutboxRepository** — files: `minimail/Store/OutboxRepository.swift`, `RepositoryTests.swift` (the outbox tests of §7.2, `testEnqueueModifyInsertsAndAppliesInstantly` through `testRearmMergesIntoPending`, plus `testStaleIdsExcludesOutboxReferenced` and `testDeleteFailedSends`). Done when coalescing, ack, discard, retry thresholds, re-arm merge all pass with invariants. Verify: `make test-one T=minimailTests/RepositoryTests`.
- [ ] **T06.10 Queries** — files: `minimail/Store/Queries.swift`, `minimailTests/Store/QueriesTests.swift`. Done when all 15 tests pass including the query-plan and 5 ms tests. Verify: `make test-one T=minimailTests/QueriesTests`.
- [ ] **T06.11 AppEnvironment wiring** — files: `minimail/App/AppEnvironment.swift` (modify), `minimailTests/App/AppEnvironmentTests.swift` (modify). Done when launch step 2 opens the pool, `cachedEmail` is read, the wipe hook resets, and the three new tests pass together with 01's and 04's existing `AppEnvironmentTests`. Verify: `make test-one T=minimailTests/AppEnvironmentTests`.
- [ ] **T06.12 Full pass** — `make lint`, `make core-test`, `make test-app`; record `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact` showing `failedTests: 0`; note any UNVERIFIED API name that needed its fallback (§10) in the implementation notes of this spec.

---

## 9. Acceptance criteria

1. `cd Packages/MailCore && swift test` passes on Linux (Swift 6.1+) with the four new MailCore test files; `MailCore` still imports only `Foundation` (`make lint` grep passes).
2. `make test-app` passes with `DatabaseTests`, `RepositoryTests`, `QueriesTests`, `AppEnvironmentTests` green; `InvariantChecks.assertAll` runs at the end of every repository/query test.
3. `sqlite_master` of a fresh database equals the DDL of §5.1 statement by statement (`testFreshSchemaMatchesDDL`).
4. For every scope × unreadOnly, `EXPLAIN QUERY PLAN` names the intended partial index and the inbox query over a 5,000-message seed completes in < 5 ms median on the simulator (`testExplainQueryPlanUsesIndexes`, `testInboxQueryUnder5msWith5000Messages`).
5. Read→unread on the same thread produces zero outbox rows; archive→read produces one merged row; an inFlight op is never merged into; a failed modify op is never deleted by `retryLater`; `rearmFailedModifies` leaves at most one pending op per thread (`RepositoryTests`).
6. A metadata re-write or body store while a mark-read op is pending leaves the thread read (`testUpsertRecomputesEWithPendingOp`).
7. `AppEnvironment(testing: true)` opens a temporary WAL pool synchronously; production launch step 1 performs exactly one `DatabasePool` open + migrate + one `syncState` read (code review of `AppEnvironment.init`; on-device timing via `log stream --predicate 'subsystem == "de.newtelco.minimail"'` shows `coldStartToList` unchanged within noise versus module 01).
8. `auth.hooks.wipeAccountData` empties every table and the pool remains usable (`testWipeAccountDataResetsDatabase`); manual device step: Settings → Sign out → sign in again → inbox fills from an empty cache.
9. No file under `minimail/Store` imports `AppAuth`, `WebKit`, `Security` or `SwiftSoup`; `INSERT/UPDATE/DELETE` appear only in `*Repository.swift` and `Database.swift` (`reset`); UI `SELECT`s only in `Queries.swift` (grep: `grep -lE "INSERT|UPDATE|DELETE" minimail/Store/*.swift` lists only repositories + `Database.swift`).

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | `enum Database` (architecture §2.4) shadows `GRDB.Database` inside the app module, breaking every `(_ db: Database)` repository signature. | DEVIATION | Renamed to `AppDatabase`; all other names verbatim. 01/04 insertion-point comments that say `Database.open`/`Database.destroy` are updated to `AppDatabase.*` when this module edits `AppEnvironment.swift`. |
| D2 | `SanitizedBody`/`DarkStrategy` are declared in module 08's `Sanitizer.swift`, but `BodyRepository.storeBody` (this module, earlier in the order) takes a `SanitizedBody`. | DEVIATION (additive split, same pattern as 01 D1/D2) | This module creates `Sources/MailHTML/SanitizedBody.swift` with the verbatim §2.3 declarations + inits; 08 does not redefine them. `Store/BodyRepository.swift` imports `MailHTML`. |
| D3 | Sign-out wipe = "close pool → `Database.destroy` → reopen" (§5.4), but four actors are constructed with the pool object and GRDB wants one pool per file per process. | DEVIATION | `AppDatabase.reset(pool)` drops and recreates the schema in place + `VACUUM`; the pool object stays valid. `destroy(directory:)` is kept for tests and crash recovery. Outcome for the user is identical (no rows, file compacted). |
| D4 | `ThreadRow.chips` is a tuple array in §2.4; tuples do not synthesize `Equatable`, which `ThreadRow: Equatable` needs for the list diff. | DEVIATION | `struct ThreadChip` with the same four fields. |
| D5 | `OutboxRepository.retryLater(_, opId:, error: GmailError, now:, random:)` and `fail(_, opId:, error: GmailError)` reference module 05's `GmailError` and imply 07's `Backoff`; 06 depends on neither, and §4.8 already calls `retryLater(opId, countsAsAttempt: false)`, which the §2.4 signature lacks. | DEVIATION | Primitive arguments: `retryLater(_, opId:, error: String, countsAsAttempt: Bool, nextAttemptAt: Int64)`, `fail(_, opId:, error: String)`. 07's `Outbox` computes `nextAttemptAt = now + Backoff.outbox.delay(...) × 1000` and `countsAsAttempt = error.countsAsAttempt`, passing `String(describing: error)`. The 8/5 attempt thresholds (§4.8, §7.7) live in the repository. |
| D6 | `storeBody` has no way to learn the sanitizer version (`SanitizedBody` carries none) but `message_body.sanitizerVersion` is NOT NULL. | DEVIATION (one added parameter) | `storeBody(…, sanitizerVersion: Int, now:)`; 07 passes `Sanitizer.version`. |
| D7 | modules.md lists `TestDatabase`/`InvariantChecks` under both 06 ("app tests … `TestDatabase`, `InvariantChecks`") and 14 ("conventions"). | resolved | 06 creates both files; 14 documents/extends them (route tables, seeds for sync tests) without changing the signatures of §3.17. |
| D8 | Additive API not in §2.4: `AppDatabase.{openTemporary,reset,defaultDirectory,makeMigrator}`, `Schema.*`, `RecordJSON`, `ThreadQuery.pageSize/init`, `Queries.{threadsSQL,labelsById,maxChips}`, `MessageRepository.{threadIds,fetch}`, `ThreadRepository.{fetch,idsExisting,deleteExpired}`, `BodyRepository.{resetUnavailable,pruneBodies}`, `LabelRepository.{displayedLabelIds,fetch,sortOrder constants}`, `OutboxRepository.{record,activeModifies,activeThreadIds,referencedMessageIds,deleteFailedSends,maxModifyAttempts,maxSendAttempts}`, `SyncStateRepository.{int64,setInt64,historyId,setHistoryId,selfAddresses,setSelfAddresses,all}`, `LabelAlgebra.{constants,isSystem,parseJSON}`, `RowDateLabeler`, `ThreadAggregator.{firstName,maxParticipants}`, `OutboxRecord.{delta,affectedSet}`, `MessageRecord.{from,serverLabelSet,labelSet}`. | additive | Needed so 07 can honour "no SQL outside Store" (§4.9 cleanup, §4.2 `threadIds(of:)`, hydration scope) and 09/12 can build chips. None changes an architecture signature. |
| A1 | `nonisolated` on type declarations (SE-0449) under Swift 6.3. | assumed OK (01 A7) | Fallback: per-member `nonisolated` + `nonisolated` conformances. |
| A2 | GRDB Codable records encode `[String]`/`[Mailbox]`/`SendJob` as JSON TEXT and honour `databaseJSONEncoder(for:)`/`databaseJSONDecoder(for:)` `[ios-platform §2.4]`. | verified in research (README "JSON Columns") | If the override hook names differ in 7.11.1, keep the columns as `String` in the records and encode/decode through `RecordJSON` in the repositories (same bytes). |
| A3 | `DatabaseMigrator.eraseDatabaseOnSchemaChange`, `Configuration.publicStatementArguments`, `DatabaseWriter.vacuum()`, `DatabasePool.close()`, `Database.lastInsertedRowID`, `hasCompletedMigrations` names. | UNVERIFIED (arch §14 #17; `[ios-platform §2.3]`) | Compile-time facts; fallbacks: delete the DEBUG line; skip the flag; `writeWithoutTransaction { try $0.execute(sql: "VACUUM") }`; keep the pool open in tests and only `destroy` after the test process ends; `SELECT last_insert_rowid()`. |
| A4 | `FileProtectionType.completeUntilFirstUserAuthentication` on the directory is inherited by files GRDB creates later (`-wal`, `-shm`). | UNVERIFIED `[ios-platform §2.2]` | `open` re-applies the attribute to every existing file after migration (best effort); BG refresh (07) tolerates `SQLITE_AUTH`/`SQLITE_IOERR` regardless. |
| A5 | `EXPLAIN QUERY PLAN` detail wording differs across SQLite versions (`SCAN TABLE thread USING INDEX …` vs `SCAN thread USING INDEX …`). | assumed | Tests assert only that the index name appears in the concatenated plan rows. |
| A6 | Small inline parts (`ParsedAttachment.inlineData`) are not persisted (§3.4 "attachment bytes" never in the DB), so `attachment.attachmentId == nil` rows have no local bytes. | resolved | 08/10 treat `attachmentId == nil` like a 404: one `messages.get?format=full` re-resolve, which returns the inline `data` again. Documented for 08. |
| A7 | ICU-dependent strings in `RowDateLabel` (`"Sep 1"` vs `"Sept 1"`, U+202F before `PM`) differ between Linux and Apple ICU versions. | assumed | Tests compare against a reference `DateFormatter` with the same template; literal assertions only for `"14:32"`, `"Yesterday"`, `"11.09.25"`. UI strings other than "Yesterday" are locale-driven. |
| A8 | The 5 ms threshold (`testInboxQueryUnder5msWith5000Messages`) is met by a Debug simulator build. | assumed (60 rows, one indexed scan) | If it fails only under Debug, raise the assertion to 15 ms for Debug via `#if DEBUG` and keep 5 ms as the Release/device target recorded in §12.1. |
| A9 | Vector timestamps in `today.json` were derived by hand. | must be verified in T06.3 | The agent runs `TZ=Europe/Berlin date -d '2026-09-11 00:00' +%s` (and the six others) and fixes the JSON, never the code, on mismatch. |
| A10 | `labelsForSheet` visibility rule for `labelShowIfUnread` uses the server `threadsUnread` (NULL → shown). | chosen | Matches Gmail's sidebar semantics `[gmail-api §11]`; 12 may refine using local counts for cached label views. |
| A11 | `messageIds(threadId)` returns hidden messages too (so `threads.modify` local effect matches the server's whole-thread semantics). | chosen | Hidden rows never surface in the UI; their E is kept consistent for invariant 1. |
| A12 | `dateLabel` uses `lastDate` in the Today scope although rows are ordered by `lastInboxDate`. | chosen | The row shows the newest message time like iOS Mail; ordering by receipt is what D16 asks for. |
