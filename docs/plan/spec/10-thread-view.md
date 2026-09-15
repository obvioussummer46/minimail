# Module 10 — thread view (`Features/Thread`)

Status: detailed spec. Sources of truth: `docs/plan/design/architecture.md` (§2.4 app interfaces, §3.2 DDL, §4.5 thread open, §4.6 badge, §8.1 navigation graph, §8.2 screen contracts, §8.4 thread screen conventions, §9.2–§9.6 HTML rendering, §10 theming, §11 settings, §12.1/§12.3 performance, §13.3 app tests, §14 risks, §15 D12/D19/D20, §16 non-goals, Appendix A), `docs/plan/design/modules.md` (scope of 10 and of 07/08/09/11), `PLAN.md`, research `[ios-platform §*]`, `[html-rendering §*]`, `[gmail-api §*]`.

Dependencies: **07-sync-outbox** (`SyncEngine.ensureThreadLoaded`, `MailActions`), **08-html-rendering** (`ThreadDocument`, `WebViewHost`, `MailWebView`, `WebBridge`, `WebMessage`, `LinkPolicy`), **09-inbox-list** (`ThreadRoute` push target, `ComposeInput`, `InboxPlaceholders.ThreadScreen`). Transitively: 01 (`AppEnvironment`, `ThemeStore`, `ThemeTokensReader`, `SettingsStore`, `Log`, `Formatters`), 05 (`GmailClient`, `GmailError`), 06 (`Queries.threadDetail`, records, `BodyRepository`, `ThreadRepository`, `SyncStateRepository`, `RowDateLabeler`), 02/03 (`SubjectPrefix`, `Mailbox`, `MessageParser`, `ParsedAttachment`).

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. `ThreadScreen(threadId:)` — the pushed thread screen (architecture §8.1): the pooled `WKWebView` fills the content area and **is** the scroller, an inline navigation title, a native bottom toolbar (Reply all · Forward · Archive · Read/Unread), a compose sheet, a QuickLook preview and a non-blocking notice row.
2. `ThreadModel` — the main-actor model: `ValueObservation` of `Queries.threadDetail`, `expanded`/`imagesAllowed` state, document building through `ThreadDocument.render` with the theme's CSS tokens and forced scheme, the `revision`-driven reload rules of architecture §8.4, `evaluateJavaScript` expand/collapse, "Load images", `WebMessage` routing, mark-read-on-open, `SyncEngine.ensureThreadLoaded`, the four toolbar actions through `MailActions`, Dynamic-Type and theme reloads, and web-view hand-back on disappear.
3. `AttachmentOpener` — tap an attachment chip → download with the stored `attachmentId`, exactly one re-resolve through `messages.get?format=full&fields=payload` on 404 `[gmail-api §6, gotcha 14]`, write to the attachment file cache, hand the URL to `.quickLookPreview` `[ios-platform §5.4]`.
4. Deletion of the interim `ThreadScreen` placeholder that module 09 created in `minimail/Features/Inbox/InboxPlaceholders.swift`.
5. Two `AppEnvironment` additions: `AppEnvironment.attachmentsCacheDirectory(testing:)` and the attachment-cache purge in the sign-out wipe tail.

### 1.2 Explicitly out of scope (owned elsewhere)

| Not here | Owner |
|---|---|
| `Sanitizer`, `StyleScrubber`, `QuoteExtractor`, `ThreadDocument.render`/`css`/`csp`/`strippedIds`/`toggleScript`, `WebViewHost`, `MailWebView`, `WebBridge`, `CIDSchemeHandler`, `InlineImageStore`, `LinkPolicy`, the rule lists, the CSP strings | 08 |
| `SyncEngine.ensureThreadLoaded` internals (`threads.get?format=full`, body batches, `prepareBody`, sanitizer fallback), `MailActions` internals, outbox, badge | 07 |
| Inbox list, rows, swipe actions, `ThreadRoute`, `ComposeInput`, `ActiveSheet`, `StatusBanner`, `LabelChip` | 09 |
| Compose prefill (`makeDraft`), quote snapshot, `SendJob`, the compose form | 11 |
| Labels sheet, label hydration | 12 |
| Settings screen, signature editor, theme picker UI | 13 |
| Any SQL string; all reads go through `Queries`/repositories | 06 |
| Per-message read/unread, star, move, trash, snooze, search, "always load images for this sender" | architecture §16 (non-goals) |

### 1.3 Consumers and what they take from this module

| Consumer | Takes |
|---|---|
| 09 `InboxScreen` | `ThreadScreen(threadId:)` as the `.navigationDestination(for: ThreadRoute.self)` body |
| 11 `ComposeScreen` | `ComposeInput.fromMessage(mode:threadId:messageId:)` values produced by `ThreadModel.replyAll()` / `.forward()` (the message id is always the newest **visible** message of the thread) |
| 13 `SettingsScreen` | nothing directly; `Settings.markReadOnOpen` and `Settings.loadRemoteImages` are read here |
| 14 QA | `ThreadModel`, `AttachmentOpener` for `SmokeTests`; the device-checklist items for JS toggle, CSP, dark mode, QuickLook |

---

## 2. Files

| Path (repo root) | Kind | Purpose |
|---|---|---|
| `minimail/Features/Thread/ThreadModel.swift` | new | `ThreadModel`, `ThreadAction`, `ThreadModel.RenderKey` (private), document building, observation, web-message routing, toolbar actions |
| `minimail/Features/Thread/ThreadScreen.swift` | new | `ThreadScreen(threadId:)`, private `ThreadContentView`, private `ThreadNotice`, bottom toolbar, sheet/QuickLook presentation, Dynamic-Type stream |
| `minimail/Features/Thread/AttachmentOpener.swift` | new | `AttachmentOpener` (download, re-resolve, file cache, QuickLook URL), filename/MIME helpers |
| `minimail/Features/Inbox/InboxPlaceholders.swift` | modify | delete the interim `struct ThreadScreen` (file keeps `ComposeScreen`, `LabelsScreen`, `SettingsScreen` until 11–13) |
| `minimail/App/AppEnvironment.swift` | modify | add `static func attachmentsCacheDirectory(testing:)`; add the attachment-cache purge to the wipe tail (`[10]` marker) |
| `minimailTests/Thread/ThreadModelTests.swift` | new | model behaviour against `AppEnvironment(testing: true)` + seeded pool (§7.1) |
| `minimailTests/Thread/AttachmentOpenerTests.swift` | new | download / re-resolve / cache / filename / error mapping (§7.2) |
| `minimailTests/Thread/ThreadViewsTests.swift` | new | pure view helpers, hosting smoke, notification stream (§7.3) |

No `MailCore`/`MailHTML` files. No `project.yml` change (the app target globs `minimail/`, the test target globs `minimailTests/`).

---

## 3. Public interface

App-target types are `@MainActor` by the project default (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); everything crossing into `@Sendable` GRDB closures, actors or pure helpers is marked `nonisolated`. Signatures marked `// verbatim` are copied from architecture §2.4 / §8.1 / modules.md.

### 3.1 `minimail/Features/Thread/ThreadModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import MailHTML
import Observation
import SwiftUI
import UIKit

/// The four bottom-toolbar actions (architecture §8.3 "Thread bottom bar", §8.4). Raw values double as accessibility identifiers.
nonisolated enum ThreadAction: String, CaseIterable, Sendable {
    case replyAll   = "thread.replyAll"
    case forward    = "thread.forward"
    case archive    = "thread.archive"
    case toggleRead = "thread.toggleRead"

    /// SF Symbol (§5.3). `isUnread` only matters for `.toggleRead`.
    func symbol(isUnread: Bool) -> String
    /// Accessibility label / VoiceOver text (§5.2).
    func title(isUnread: Bool) -> String
}

/// Main-actor model of one thread screen (architecture §8.2, row "ThreadScreen / ThreadModel"). One instance per pushed screen;
/// created in `ThreadScreen.ensureModel()`, released when the screen is popped (`stop()` cancels the observation).
@Observable final class ThreadModel {
    /// Owner of the attachment download + QuickLook URL. Created in `init` from `env.gmail`, `env.db` and the attachment cache directory.
    let attachments: AttachmentOpener

    // ---- identity ----
    let env: AppEnvironment
    let threadId: String

    // ---- observed state (private(set): only the model mutates) ----
    /// `Queries.threadDetail(db, threadId:)` through `ValueObservation(.immediate)`; nil once the thread row is gone.
    private(set) var detail: ThreadDetail?
    /// Message ids rendered expanded. Seeded with "every unread message + the newest message" (architecture §8.2).
    private(set) var expanded: Set<String> = []
    /// Message ids for which the user tapped "Load images" in this screen (architecture §9.4: scope is the thread view, no per-sender memory).
    private(set) var imagesAllowedIds: Set<String> = []
    /// The rendered document handed to `MailWebView`.
    private(set) var document: String = ""
    /// Increments on every document change and on every forced reload; `MailWebView` reloads when it changes (08 §4.10).
    private(set) var revision: Int = 0
    /// True while `SyncEngine.ensureThreadLoaded` runs.
    private(set) var loading = false
    /// Thread-level load failure text (§5.2); nil when the last attempt succeeded or none ran.
    private(set) var errorText: String?
    /// GRDB error text of a failed observation; shown through `errorText` and cleared by `retryLoad()`.
    private(set) var observationError: String?
    /// Set when the thread row disappears (404 during `ensureThreadLoaded`, delta delete, or Archive). The screen calls `dismiss()`.
    private(set) var shouldDismiss = false
    /// `.sensoryFeedback(.impact(weight: .light), trigger:)` (architecture §8.3 haptics).
    private(set) var lastActionId = 0
    /// True once mark-read-on-open ran for this screen (tests; also prevents a second mark on re-appear).
    private(set) var didMarkRead = false
    /// Bound by the screen with `.sheet(item:)`; 11's `ComposeScreen(input:)` consumes it.
    var composeInput: ComposeInput?

    // ---- derived (computed, no storage) ----
    /// `SubjectPrefix.stripForDisplay(detail.thread.subject)`; `"(No subject)"` when empty or no detail (§5.2).
    var title: String { get }
    /// `detail?.thread.unreadCount ?? 0 > 0` — whole-thread read state (architecture decision 13 / §15 D19).
    var isUnread: Bool { get }
    /// `detail?.messages.last?.id` — newest visible message; the compose origin and the "is there anything to reply to" test.
    var newestMessageId: String? { get }
    /// `newestMessageId != nil`.
    var canCompose: Bool { get }
    /// Document-level image policy: `env.settings.settings.loadRemoteImages || !imagesAllowedIds.isEmpty`.
    /// Drives `ThreadDocument.render(imagesAllowed:)` (CSP gains `https:`) and `MailWebView.imagesAllowed` (rule-list swap).
    var documentImagesAllowed: Bool { get }

    /// Starts the observation synchronously (`.immediate`), seeds `expanded`, builds the first document and sets `revision = 1`
    /// — all before `init` returns, so the first `MailWebView` update already carries the cached thread (architecture §12.1:
    /// "Thread open, cached & complete: < 16 ms to `loadHTMLString`"). No network, no `Task`, no sync call.
    /// `clock`/`timeZone`/`locale` feed `RowDateLabeler` and the full-date formatter.
    init(env: AppEnvironment, threadId: String,
         clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current, locale: Locale = .current)

    /// Called once from `ThreadScreen.task`. Marks the thread read when `Settings.markReadOnOpen` and `unreadCount > 0`
    /// (one local transaction, never waits for bodies), then awaits `SyncEngine.ensureThreadLoaded(threadId:)`. Idempotent.
    func appeared() async

    /// Installs this model as the owner of the shared web plumbing (08): `WebBridge.onMessage`, `LinkPolicy.onAction`, `LinkPolicy.openURL`.
    /// `openURL` is `@Environment(\.openURL)` of the screen. Records `ThreadModel.webOwner = self` (§4.9).
    func attachWeb(openURL: @escaping (URL) -> Void)
    /// Reverse of `attachWeb` **only when this model is still the owner** (a push-pop-push sequence can interleave
    /// `onDisappear` of the old screen with `onAppear` of the new one). Then clears the handlers and calls `WebViewHost.didLeaveThread()`.
    func detachWeb()

    /// Single entry point for every in-document interaction (08 `WebMessage`), used by both the script bridge and the
    /// `minimail-action:` link fallback (08 O1/F1).
    func handle(_ message: WebMessage)

    // ---- individual effects (called by `handle`, exposed for tests) ----
    /// Expand/collapse: `evaluateJavaScript(ThreadDocument.toggleScript(id))` when the loaded document is current and the
    /// section is not stripped; otherwise a rebuild + reload (§4.6).
    func toggle(messageId: String)
    /// "Load images" for one message: inserts into `imagesAllowedIds`, rebuilds, bumps `revision` (§4.7).
    func loadImages(messageId: String)
    /// "Retry" inside an unavailable message: `BodyRepository.resetUnavailable` + `ThreadRepository.recomputeAggregates`
    /// in one write, then `ensureThreadLoaded` (§4.8).
    func retry(messageId: String)
    /// Attachment chip tap → `attachments.open(messageId:partId:)` in a `Task`.
    func openAttachment(messageId: String, partId: String)

    // ---- toolbar ----
    /// `composeInput = .fromMessage(mode: .replyAll, threadId: threadId, messageId: newestMessageId)`; no-op without a message.
    func replyAll()
    /// Same with `.forward`.
    func forward()
    /// `env.actions.archive(threadId:)` then `shouldDismiss = true` (architecture §8.2: "Archive (pops)").
    func archive() async
    /// `isUnread ? env.actions.markRead : env.actions.markUnread`; the screen stays open (§10 A3).
    func toggleRead() async

    // ---- environment changes ----
    /// `.onAppear` and `.onChange(of: colorScheme)` / `.onChange(of: env.theme.choice)`: recomputes the CSS tokens and the forced
    /// document theme; rebuilds + reloads when anything changed (architecture §9.5).
    func systemSchemeChanged(_ scheme: ColorScheme)
    /// `UIContentSizeCategory.didChangeNotification`: forces a reload of the identical document (architecture §14 #26).
    func contentSizeChanged()
    /// Re-runs `ensureThreadLoaded` after a failure (notice row "Retry"); clears `errorText`/`observationError` and restarts a
    /// failed observation.
    func retryLoad() async
    /// Cancels the observation (tests; `deinit` also cancels through the cancellable's own deinit).
    func stop()

    // ---- pure helpers (nonisolated, unit-tested without a model) ----
    /// Projection of one `ThreadDetail` into 08's document input. Pure; `labeler`/`fullDate` are passed in because
    /// `RowDateLabeler` and `DateFormatter` are not `Sendable` (06 §3.4).
    nonisolated static func documentMessages(detail: ThreadDetail, expanded: Set<String>, imagesAllowedIds: Set<String>,
                                             loadRemoteImages: Bool, labeler: RowDateLabeler,
                                             fullDate: DateFormatter) -> [ThreadDocumentMessage]
    /// `expanded` seed for a detail: every message with `isUnread` plus the newest message (architecture §8.2).
    nonisolated static func initialExpanded(_ detail: ThreadDetail) -> Set<String>
    /// User-facing text for a thread-load failure (§5.2 table).
    nonisolated static func loadErrorText(for error: any Error) -> String
    /// `DateFormatter` used for the `title` attribute of the date span (`dateFull`): `.full` date + `.short` time.
    nonisolated static func makeFullDateFormatter(timeZone: TimeZone, locale: Locale) -> DateFormatter
}
```

Private members of `ThreadModel` (named so tests and later modules can reason about them):

```swift
/// Everything `ThreadDocument.render` consumes. Equality decides whether a reload is needed (architecture §8.4:
/// "rebuilt and reloaded ONLY when `detail` changes (bodies arrived), `imagesAllowed` changes, or theme / Dynamic Type changes").
nonisolated private struct RenderKey: Equatable {
    var subject: String
    var messages: [ThreadDocumentMessage]
    var light: ThemeCSSTokens
    var dark: ThemeCSSTokens
    var forcedScheme: String?
    var imagesAllowed: Bool
}

/// The model that currently owns `WebBridge.onMessage` / `LinkPolicy` (§4.9). Weak so a popped screen cannot keep itself alive.
private static weak var webOwner: ThreadModel?

private var cancellable: AnyDatabaseCancellable?    // whatever `ValueObservation.start` returns (09 §10 A2)
private var renderKey: RenderKey?
private var knownMessageIds: Set<String> = []       // ids seen in a previous tick (drives `mergeExpanded`)
private var didAppear = false
private var openURLAction: ((URL) -> Void)?
private let clock: () -> Date
private let timeZone: TimeZone
private let locale: Locale
private var labeler: RowDateLabeler
private let fullDate: DateFormatter
private var lightTokens: ThemeCSSTokens
private var darkTokens: ThemeCSSTokens
private var forcedScheme: String?

private func startObservation()
private func apply(_ detail: ThreadDetail?)
private func mergeExpanded(for detail: ThreadDetail)
private func rebuild(force: Bool)
private func makeRenderKey() -> RenderKey
private func loadThread() async
private func observationFailed(_ error: any Error)
private func evaluate(_ script: String, onFalse: @escaping () -> Void)
```

### 3.2 `minimail/Features/Thread/ThreadScreen.swift`

```swift
import MailCore
import SwiftUI
import UIKit
import WebKit

/// The pushed thread screen (architecture §8.1, §8.4). Pure presentation: every decision lives in `ThreadModel`.
struct ThreadScreen: View {                                                                   // verbatim: ThreadScreen(threadId:)
    init(threadId: String)
    var body: some View
    /// `AsyncStream<Void>` yielding once per `UIContentSizeCategory.didChangeNotification` (architecture §14 #26; same pattern as
    /// 09's `dayChangeStream`, and for the same Swift-6 reason — `Notification` is not `Sendable`).
    nonisolated static func contentSizeChangeStream() -> AsyncStream<Void>
}

/// The web view plus its overlays; split out so `@Bindable var model` is available (private).
private struct ThreadContentView: View {
    @Bindable var model: ThreadModel
    let tokens: ThemeTokens
    var body: some View
}

/// One-line, non-blocking notice above the document (load failure, attachment failure). Never an alert (architecture §8.2).
private struct ThreadNotice: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?
    let dismiss: (() -> Void)?
    var body: some View
}
```

### 3.3 `minimail/Features/Thread/AttachmentOpener.swift`

```swift
import Foundation
import GRDB
import MailCore
import Observation
import os

/// Downloads one attachment on tap and hands its file URL to `.quickLookPreview` (architecture §8.4, `[ios-platform §5.4]`).
/// Never prefetches (architecture decision 8). DEVIATION D3: `db` is `any DatabaseWriter` (as in 07 D1 / 08 D3) so tests pass a `DatabaseQueue`.
@Observable final class AttachmentOpener {
    enum State: Equatable {
        case idle
        case downloading(messageId: String, partId: String)
        case failed(String)                       // user-facing text (§5.2)
    }

    /// Refuse to open above this size (JSON `attachments.get` inflates bytes by 4/3; architecture caps forwards at 20 MB, §7.6).
    static let maxBytes = 25_000_000
    /// MIME type → file extension, used when the stored filename has none (`[ios-platform §5.4]`: "file must have the right extension").
    nonisolated static let mimeExtensions: [String: String]

    private(set) var state: State = .idle
    /// Bound to `.quickLookPreview($previewURL)`; QuickLook sets it back to nil on dismissal `[ios-platform §5.4]`.
    var previewURL: URL?

    init(gmail: GmailClient, db: any DatabaseWriter, directory: URL, fileManager: FileManager = .default)

    /// §4.10. Never throws; failures land in `state = .failed(text)`. A second call while `.downloading` is ignored.
    func open(messageId: String, partId: String) async
    /// `state = .idle` (notice row "×").
    func dismissError()

    /// `<directory>/<messageId>/<partId>/<filename>`; `messageId` and `partId` are percent-encoded with `.urlPathAllowed` minus `/`.
    nonisolated static func fileURL(root: URL, messageId: String, partId: String, filename: String) -> URL
    /// §4.11: strips path separators and control characters, trims, caps at 120 UTF-8 bytes, falls back to `attachment-<partId>`,
    /// and appends the `mimeExtensions` extension when the name has none.
    nonisolated static func sanitizedFilename(_ raw: String, partId: String, mimeType: String) -> String
    /// User-facing text for a download failure (§5.2 table).
    nonisolated static func message(for error: any Error) -> String
    /// Removes `directory` recursively (sign-out wipe tail, tests).
    nonisolated static func purge(directory: URL, fileManager: FileManager = .default) throws
    /// Writes `data` atomically, creating intermediate directories. Called from a detached task (never on the main actor).
    nonisolated static func write(_ data: Data, to url: URL, fileManager: FileManager) throws
}
```

### 3.4 `minimail/App/AppEnvironment.swift` additions (`[10]`)

```swift
// static helper added next to 08's `cidCacheDirectory(testing:)`
/// `<Caches>/attachments` (purged by `Maintenance.purgeFiles`, 07 §3.9); when `testing`: `NSTemporaryDirectory()/minimail-att-<UUID>`.
static func attachmentsCacheDirectory(testing: Bool) -> URL
```
Wipe tail (`auth.hooks.wipeAccountData`), appended after 08's `await inlineImages.purge(); webHost.recycle()`:
```swift
try? AttachmentOpener.purge(directory: AppEnvironment.attachmentsCacheDirectory(testing: isTesting))   // [10]
```
No stored property is added: `ThreadModel` constructs its `AttachmentOpener` from `env.gmail`, `env.db` and this directory, so nothing is built during the < 15 ms launch step 1 (architecture §12.2).

### 3.5 `minimail/Features/Inbox/InboxPlaceholders.swift` (modify)

```swift
// DELETED by this module:
// /// Replaced by module 10 (`Features/Thread/ThreadScreen.swift`).
// struct ThreadScreen: View { init(threadId: String); var body: some View }
```
`ComposeScreen`, `LabelsScreen` and `SettingsScreen` stay until 11, 12 and 13 remove them; 13 deletes the file. 09's `testPlaceholderSignatures` keeps compiling because the real `ThreadScreen(threadId:)` has the same signature.

---

## 4. Behaviour

### 4.1 Construction and first document (architecture §12.1 "Thread open, cached & complete")

```
ThreadScreen.ensureModel():                       // idempotent; called from BOTH .onAppear and .task (order is not guaranteed)
    if model == nil { model = ThreadModel(env: env, threadId: threadId) }

ThreadModel.init(env, threadId, clock, timeZone, locale):
 1. self.env = env; self.threadId = threadId; self.clock = clock; self.timeZone = timeZone; self.locale = locale
 2. labeler  = RowDateLabeler(now: clock(), timeZone: timeZone, locale: locale)
    fullDate = ThreadModel.makeFullDateFormatter(timeZone: timeZone, locale: locale)
 3. attachments = AttachmentOpener(gmail: env.gmail, db: env.db,
                                   directory: AppEnvironment.attachmentsCacheDirectory(testing: env.isTesting))
 4. let theme = env.theme.resolved(for: env.theme.preferredColorScheme ?? .light)
    lightTokens = theme.cssTokens(for: .light); darkTokens = theme.cssTokens(for: .dark)
    forcedScheme = env.theme.forcedDocumentTheme                      // "light" | "dark" | nil (01 §3.7)
 5. startObservation()                                                // .immediate → `detail` is set synchronously
 6. (inside the first `apply`) expanded = ThreadModel.initialExpanded(detail); rebuild(force: true) → revision = 1
```
Step 5's first value is fetched on the main thread through GRDB's `.immediate` scheduling (`[ios-platform §2.6]`); `Queries.threadDetail` is one PK lookup plus three indexed reads (`message_thread_date`, `message_body` PK, `attachment` PK prefix) — well inside the 16 ms budget for a cached thread.

`startObservation()`:
```swift
cancellable?.cancel()
cancellable = ValueObservation
    .trackingConstantRegion { [threadId] db in try Queries.threadDetail(db, threadId: threadId) }
    .removeDuplicates()                                      // ThreadDetail is Equatable (06 §3.9)
    .start(in: env.db, scheduling: .immediate,
           onError:  { [weak self] e in MainActor.assumeIsolated { self?.observationFailed(e) } },
           onChange: { [weak self] d in MainActor.assumeIsolated { self?.apply(d) } })
```
- The observed region depends only on the captured `threadId`, so `trackingConstantRegion` is valid (same argument as 09 §4.2).
- `.immediate` delivers the first value synchronously on the caller (main) and later values on the main dispatch queue, which is why `MainActor.assumeIsolated` is correct inside the `@Sendable` callbacks (09 §10 A5 gives the fallback).

`apply(detail)`:
```
 1. guard let d = detail else {                                 // thread row gone (404 during ensureThreadLoaded, delta delete, cleanup)
        self.detail = nil; shouldDismiss = true
        Log.ui.debug("thread.gone \(threadId, privacy: .public)"); return }
 2. self.detail = d
 3. mergeExpanded(for: d)
 4. rebuild(force: false)
```

`mergeExpanded(for: d)`:
```
 let ids = Set(d.messages.map(\.id))
 if knownMessageIds.isEmpty { expanded = ThreadModel.initialExpanded(d) }
 else {
     for m in d.messages where !knownMessageIds.contains(m.id) {
         if m.isUnread || m.id == d.messages.last?.id { expanded.insert(m.id) }      // a reply that arrived while the screen is open
     }
 }
 expanded.formIntersection(ids)                                   // drop ids of deleted messages
 knownMessageIds = ids
```
`initialExpanded(d)` = `Set(d.messages.filter(\.isUnread).map(\.id))` ∪ `[d.messages.last?.id]` (nil-safe; empty thread → empty set).

### 4.2 Document building

`makeRenderKey()`:
```
RenderKey(subject: SubjectPrefix.stripForDisplay(detail?.thread.subject ?? ""),
          messages: detail.map { ThreadModel.documentMessages(detail: $0, expanded: expanded, imagesAllowedIds: imagesAllowedIds,
                                                              loadRemoteImages: env.settings.settings.loadRemoteImages,
                                                              labeler: labeler, fullDate: fullDate) } ?? [],
          light: lightTokens, dark: darkTokens, forcedScheme: forcedScheme, imagesAllowed: documentImagesAllowed)
```

`documentMessages(detail:expanded:imagesAllowedIds:loadRemoteImages:labeler:fullDate:)` — one `ThreadDocumentMessage` per element of `detail.messages` (already `isHidden = 0`, `internalDate ASC`, 06 §3.9):

| `ThreadDocumentMessage` field | Value |
|---|---|
| `id` | `m.id` |
| `fromName` | `m.fromName ?? ""` (08 renders `fromName.isEmpty ? fromAddr : fromName`) |
| `fromAddr` | `m.fromAddr` |
| `toLine` | `m.toList.map(\.displayName).joined(separator: ", ")`; empty list → `""` |
| `ccLine` | `m.ccList.isEmpty ? nil : m.ccList.map(\.displayName).joined(separator: ", ")` |
| `dateLabel` | `labeler.label(epochMs: m.internalDate)` |
| `dateFull` | `fullDate.string(from: Date(timeIntervalSince1970: Double(m.internalDate) / 1000))` |
| `snippet` | `m.snippet` |
| `isUnread` | `m.isUnread` (E-derived flag, 06) |
| `expanded` | `expanded.contains(m.id)` |
| `bodyHTML` | `detail.bodies[m.id]?.bodyHtml` |
| `bodyState` | `m.bodyState` (0 loading, 1 cached, 2 unavailable) |
| `darkStrategy` | `detail.bodies[m.id]?.darkStrategy ?? "plain"` |
| `hasRemoteImages` | `detail.bodies[m.id]?.hasRemoteImages ?? false` |
| `imagesAllowed` | `loadRemoteImages || imagesAllowedIds.contains(m.id)` |
| `attachments` | `detail.attachments.filter { $0.messageId == m.id && !$0.isInline }` → `ThreadDocumentAttachment(partId:, filename:, sizeLabel: Formatters.bytes($0.size))`, order preserved (`messageId, partId` from `Queries.threadDetail`) |

Inline parts (`isInline = 1`) are **not** listed as chips — they are already visible in the body through `minimail-cid://` (architecture §9.4). This matches `thread.hasAttachments` (06: "any row with `isInline = 0`"). §10 A5 records the trade-off.

`rebuild(force:)`:
```
 let key = makeRenderKey()
 guard force || key != renderKey else { return }                  // an unrelated observation tick must not reload the document
 renderKey = key
 document = ThreadDocument.render(subject: key.subject, messages: key.messages, light: key.light, dark: key.dark,
                                  forcedScheme: key.forcedScheme, imagesAllowed: key.imagesAllowed)
 revision &+= 1
 Log.ui.debug("thread.document.rebuilt \(threadId, privacy: .public) rev=\(revision) bytes=\(document.utf8.count)")
```
`revision` starts at 0 and is 1 after `init`; `MailWebView.Coordinator.appliedRevision` starts at −1, so the first `updateUIView` always loads (08 §4.10).

Reload triggers, exhaustively (architecture §8.4):

| Trigger | Path | Reload? |
|---|---|---|
| Bodies arrived / message added / labels changed so that the projection differs | `apply` → `rebuild(force: false)` | yes (key differs) |
| Observation tick with an identical projection (e.g. `thread.isComplete` flipped, `bodiesMissing` changed, a label chip changed) | `apply` → `rebuild(force: false)` | no |
| "Load images" tapped | `loadImages` → `rebuild(force: false)` | yes |
| Expand/collapse | `toggle` → `evaluateJavaScript` | no |
| Expand of a section stripped by the 6 MB document cap | `toggle` → `rebuild(force: true)` | yes |
| Theme choice / system scheme changed | `systemSchemeChanged` → `rebuild(force: false)` | yes when the tokens or `forcedScheme` differ |
| Dynamic Type changed | `contentSizeChanged` → `rebuild(force: true)` | yes (document text may be identical; `revision` still changes) |
| Loaded document is stale (`webHost.loadedRevision != revision`) when a toggle arrives | `toggle` → `rebuild(force: true)` | yes |

Scroll position survives every JS toggle; a reload starts at the top (accepted, architecture §9.6 — no measuring, no `scrollTo` in stage 1).

### 4.3 `appeared()` — mark read + `ensureThreadLoaded` (architecture §4.5, §8.2)

```
appeared():
 1. guard !didAppear else { return }; didAppear = true
 2. if env.settings.settings.markReadOnOpen, (detail?.thread.unreadCount ?? 0) > 0 {
        didMarkRead = true
        await env.actions.markRead(threadId: threadId)        // one local transaction + Outbox.kick(); never waits for the network
    }
 3. await loadThread()

loadThread():
 guard !loading else { return }
 loading = true; errorText = nil; defer { loading = false }
 do { try await env.sync.ensureThreadLoaded(threadId: threadId) }
 catch is CancellationError { }
 catch {
     errorText = ThreadModel.loadErrorText(for: error)
     Log.ui.error("thread.load.failed \(threadId, privacy: .public) \(String(describing: error), privacy: .public)")
 }
```
- Step 2 is awaited rather than detached because `MailActions.archive/markRead/markUnread` only writes one transaction and kicks the outbox (07 §4.6); "not waiting for bodies" (architecture §8.2) is satisfied — no network call is awaited before the body fetch starts.
- `markRead` flips `unreadCount` to 0 in the same transaction, so the observation ticks and the `mm-unread` dots disappear; `expanded` was seeded from the pre-mark state, so the expansion of the previously-unread messages stays.
- `ensureThreadLoaded` is deduplicated per thread inside the actor (07 §4.4.6), so a pop-and-push while a fetch is running joins the existing task.
- A 404 thread does not throw (07): the engine deletes the rows, the observation yields nil and `apply` sets `shouldDismiss`.
- `retryLoad()`: `observationError = nil`; if the observation was cancelled by an error → `startObservation()`; then `await loadThread()`.

### 4.4 Toolbar actions (architecture §8.2, §8.4)

| Action | Steps |
|---|---|
| `replyAll()` | `guard let id = newestMessageId else { return }`; `lastActionId += 1`; `composeInput = .fromMessage(mode: .replyAll, threadId: threadId, messageId: id)` |
| `forward()` | same with `mode: .forward` |
| `archive()` | `lastActionId += 1`; `await env.actions.archive(threadId: threadId)`; `shouldDismiss = true` |
| `toggleRead()` | `lastActionId += 1`; `isUnread ? await env.actions.markRead(threadId: threadId) : await env.actions.markUnread(threadId: threadId)` |

- Archive removes `INBOX` from every message of the thread through one coalesced outbox op (07 §4.6); in the inbox/today scope the row is gone on the next tick, in a label scope it stays (09 §4.10).
- `toggleRead()` does **not** pop (§10 A3). The toolbar icon flips on the next observation tick.
- 11 is responsible for deleting an old failed-send job when the user re-sends; this module only produces `.fromMessage` inputs.

### 4.5 `handle(_:)` — routing the web messages (08 §3.8)

```
switch message {
case .toggle(let id):                toggle(messageId: id)
case .loadImages(let id):            loadImages(messageId: id)
case .attachment(let mid, let pid):  openAttachment(messageId: mid, partId: pid)
case .retry(let id):                 retry(messageId: id)
case .link(let url):                 openURLAction?(url)          // set by attachWeb from @Environment(\.openURL)
}
```
`LinkPolicy` already cancels every navigation and hands `http(s)`/`mailto:`/`tel:` URLs to its `openURL` closure (08 §4.8); this module points that closure at `handle(.link(url))` so a single switch covers both transports and the behaviour is testable without WebKit. `mailto:` goes to the system (architecture §15 D20 — compose-new is out of scope).

### 4.6 `toggle(messageId:)`

```
 1. guard var key = renderKey, let idx = key.messages.firstIndex(where: { $0.id == messageId }) else { return }
 2. let willExpand = !expanded.contains(messageId)
    if willExpand { expanded.insert(messageId) } else { expanded.remove(messageId) }
 3. if willExpand, ThreadDocument.strippedIds(messages: key.messages).contains(messageId) {
        rebuild(force: true); return }                      // the body was replaced by "Tap to load this message" under the 6 MB cap
 4. guard env.webHost.loadedRevision == revision else { rebuild(force: true); return }
 5. key.messages[idx].expanded = willExpand; renderKey = key   // keep the key in sync so the next tick does not reload
 6. evaluate(ThreadDocument.toggleScript(messageId: messageId), onFalse: { [weak self] in self?.rebuild(force: true) })
```
`evaluate(script, onFalse:)`:
```swift
let webView = env.webHost.webView
Task { @MainActor in
    let result = try? await webView.evaluateJavaScript(script)
    if (result as? Bool) == false { onFalse() }              // section not in the DOM → the document is out of date
}
```
App JavaScript keeps working with `allowsContentJavaScript = false` (`[html-rendering §2.1]`, WWDC20 10188). The documented fallback if a device check disproves it (architecture §14 #3) is step 4's path for every toggle: `rebuild(force: true)` — correct, only the scroll position is lost (§10 A2).

### 4.7 `loadImages(messageId:)` (architecture §9.4)

```
 1. guard imagesAllowedIds.insert(messageId).inserted else { return }
 2. lastActionId += 1
 3. rebuild(force: false)        // key changes: this message's `imagesAllowed` = true and, for the first tap, the document-level flag
 4. Log.ui.debug("thread.images.loaded \(threadId, privacy: .public)")
```
Effects downstream, in one `updateUIView` pass (08 §4.10): `MailWebView.imagesAllowed` becomes true → `WebViewHost.setImagesAllowed(true)` swaps the block-all rule list for the images-only one **before** the load; `ThreadDocument.csp(imagesAllowed: true)` adds `https:` to `img-src`; `ThreadDocument.restoringRemoteImages` puts `data-src` back into `src` **only inside the messages whose per-message flag is true**. Tracking pixels were already removed at sanitize time (08 §4.3). The scope is this screen only; leaving and re-entering shows placeholders again (architecture §9.4: no per-sender memory in stage 1).

When `Settings.loadRemoteImages` is true, `documentImagesAllowed` is true from the first render and every message carries `imagesAllowed: true`, so no "Load images" row is emitted at all (08 §4.6 `images` is `hasRemoteImages && !imagesAllowed`).

### 4.8 `retry(messageId:)` (08 D2)

```
Task {
    do {
        try await env.db.write { db in
            try BodyRepository.resetUnavailable(db, messageId: messageId)                      // bodyState 2 → 0
            try ThreadRepository.recomputeAggregates(db, threadIds: [threadId],
                                                     selfAddresses: try SyncStateRepository.selfAddresses(db))   // keeps invariant 6
        }
    } catch { Log.ui.error("thread.retry.failed \(messageId, privacy: .public) \(String(describing: error), privacy: .public)") }
    await loadThread()
}
```
This is the only write this module performs directly. It calls repositories (no SQL string in `Features/`, architecture §2.1 rule 3) and recomputes the aggregate in the same transaction so invariant §3.5-6 (`bodiesMissing == COUNT(bodyState = 0)`) holds. 08 §10 D2 assigns exactly this behaviour to module 10.

### 4.9 Ownership of the shared web plumbing

There is one `WebBridge`, one `LinkPolicy` and one pooled `WKWebView` for the whole app (08). SwiftUI may run the *new* screen's `onAppear` before the *old* screen's `onDisappear`, so the handlers are guarded by an owner token:

```
attachWeb(openURL):
    ThreadModel.webOwner = self
    openURLAction = openURL
    env.webBridge.onMessage         = { [weak self] msg in self?.handle(msg) }
    env.webHost.linkPolicy.onAction = { [weak self] msg in self?.handle(msg) }
    env.webHost.linkPolicy.openURL  = { [weak self] url in self?.handle(.link(url)) }

detachWeb():
    guard ThreadModel.webOwner === self else { return }        // a newer screen already took over: leave its handlers alone
    ThreadModel.webOwner = nil
    env.webBridge.onMessage         = { _ in }
    env.webHost.linkPolicy.onAction = nil
    env.webHost.linkPolicy.openURL  = { _ in }
    env.webHost.didLeaveThread()                               // 60 s delayed recycle (08 §4.10, A6)
```
`didLeaveThread()` rather than `recycle()` keeps a back-and-forth between list and thread free of a warm-up; a memory warning still recycles the unattached instance (08 §4.10). Architecture §8.4 ("recycle on leave") and §9.3 ("60 s after leaving") are reconciled this way, as 08 §10 A6 recommends.

### 4.10 `AttachmentOpener.open(messageId:partId:)` (architecture §8.4, `[gmail-api §6, gotcha 14]`)

```
open(messageId, partId):
 1. if case .downloading = state { return }                                   // one download at a time per screen
 2. state = .idle
 3. rec = try? await db.read { try BodyRepository.attachment($0, messageId: messageId, partId: partId) }
    guard let rec else { state = .failed(unavailableText); return }
 4. name = sanitizedFilename(rec.filename, partId: partId, mimeType: rec.mimeType)
    url  = fileURL(root: directory, messageId: messageId, partId: partId, filename: name)
 5. if fileManager.fileExists(atPath: url.path) {                             // cache hit: no network at all
        previewURL = url; Log.ui.debug("attachment.cache.hit …"); return }
 6. guard rec.size <= Self.maxBytes else { state = .failed(tooLargeText(rec.size)); return }
 7. state = .downloading(messageId: messageId, partId: partId)
    defer { if case .downloading = state { state = .idle } }
 8. var data: Data?
    if let id = rec.attachmentId {
        do { data = try await gmail.getAttachment(messageId: messageId, attachmentId: id) }
        catch GmailError.notFound { data = nil }                              // stale id → re-resolve below
        catch { state = .failed(Self.message(for: error)); return }
    }
 9. if data == nil {                                                          // re-resolve exactly once
        let msg: GmailMessage
        do { msg = try await gmail.getMessage(id: messageId, format: .full, fields: "payload") }
        catch { state = .failed(Self.message(for: error)); return }
        let parsed = MessageParser.parse(msg)
        try? await db.write { try BodyRepository.updateAttachmentIds($0, messageId: messageId, parsed: parsed.attachments) }
        guard let part = parsed.attachments.first(where: { $0.partId == partId }) else {
            state = .failed(unavailableText); return }
        if let inline = part.inlineData { data = inline }                     // small parts arrive inline, no second request
        else if let newId = part.attachmentId {
            do { data = try await gmail.getAttachment(messageId: messageId, attachmentId: newId) }
            catch GmailError.notFound { state = .failed(unavailableText); return }   // second 404 → give up
            catch { state = .failed(Self.message(for: error)); return }
        } else { state = .failed(unavailableText); return }
    }
10. guard let bytes = data else { state = .failed(unavailableText); return }
    if rec.size > 0, bytes.count != rec.size { Log.ui.notice("attachment.size.mismatch …") }   // log only, still open
11. do { try await Task.detached(priority: .userInitiated) { try AttachmentOpener.write(bytes, to: url, fileManager: fm) }.value }
    catch { state = .failed(writeFailedText); return }
12. state = .idle; previewURL = url
```
- `getAttachment` returns base64url-decoded bytes (05 §3); no decoding happens here.
- `messages.get?format=full&fields=payload` is the re-resolve call named by architecture §8.4 and §7.6; it is also what refreshes the whole message's attachment ids for later taps (`updateAttachmentIds`).
- Downloads are never retried automatically beyond the one re-resolve; the user taps again (the retry policy of `GmailClient` already covers transient statuses, 05 §4.1).
- Concurrency: `open` is main-actor; both awaits hop to the `GmailClient` actor / a GRDB reader, and the file write runs in a detached task, so no bytes are copied on the main thread beyond the `Data` handle.
- The file stays in `<Caches>/attachments/...` and is purged by `Maintenance.purgeFiles` after 7 days (07 §3.9) and by the sign-out wipe tail (§3.4).

### 4.11 `sanitizedFilename(_:partId:mimeType:)`

```
 1. var name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
 2. name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
 3. name = name.trimmingCharacters(in: .whitespacesAndNewlines)
 4. if name == "." || name == ".." || name.hasPrefix(".") { name = "attachment-" + partId + name }
 5. if name.isEmpty { name = "attachment-" + partId }
 6. while name.utf8.count > 120 { name.removeLast() }                 // keeps the extension only if it still fits; see step 7
 7. if URL(fileURLWithPath: name).pathExtension.isEmpty,
       let ext = AttachmentOpener.mimeExtensions[mimeType.lowercased().split(separator: ";")[0].trimmed] {
        name += "." + ext }
 8. return name
```
Step 7 matters for QuickLook: type detection is extension-based `[ios-platform §5.4]`. Unknown MIME types keep the name unchanged (QuickLook then shows a generic preview or the share sheet).

### 4.12 Concurrency and isolation

| Type | Isolation | Notes |
|---|---|---|
| `ThreadModel`, `ThreadScreen`, `ThreadContentView`, `ThreadNotice`, `AttachmentOpener` | `@MainActor` (project default) | UI state; every `env.actions`/`env.sync`/`env.outbox` call is `await`ed inside a `Task { }` created on the main actor |
| `ThreadAction`, `RenderKey`, the `nonisolated static` helpers | `nonisolated` | pure; `RenderKey` is `Equatable` only (not `Sendable`-required — it never crosses an actor boundary) |
| GRDB observation callbacks | `@Sendable`, delivered on the main queue | wrapped in `MainActor.assumeIsolated` (09 §10 A5) |
| `AttachmentOpener.write`, `purge`, `fileURL`, `sanitizedFilename`, `message(for:)` | `nonisolated` | `write` runs in a detached task |

No `DatabasePool.read` is called from the model outside `ValueObservation`; the single `db.write` is the retry path of §4.8 (architecture §12.3 "UI only observes", with the exception 08 §10 D2 sanctions).

### 4.13 Error handling summary

| Source | Error | Handling |
|---|---|---|
| `SyncEngine.ensureThreadLoaded` | `GmailError.offline` | `errorText = "You're offline — showing what's cached."`, notice row with "Retry" |
| | `.unauthorized` | `errorText = "Sign in again to load this thread."`; `AuthStore` already flipped to `.needsReauth` (07), the inbox shows the sign-in banner |
| | `.rateLimited` | `"Gmail is busy. Try again in a moment."` |
| | `.forbidden`, `.badRequest`, `.server`, `.network`, `.decoding`, `.batchMalformed` | `"Couldn't load this thread."` |
| | `CancellationError` | ignored (the screen is gone) |
| | thread 404 | no throw; rows deleted by 07 → observation nil → `shouldDismiss` |
| per-message body | `bodyState == 2` | rendered by 08 as `Couldn't load this message · Retry`; the Retry link routes to §4.8 |
| `ValueObservation` | any `Error` | `Log.ui.error`; `observationError` set; the notice row shows `"Couldn't read the local database."` with "Retry"; `retryLoad()` restarts the observation |
| `AttachmentOpener` | see §4.10 / §5.2 | `state = .failed(text)` → notice row with "×"; never an alert |
| `env.actions.*` | never throws (07 logs) | nothing to show; optimistic state stays |
| `evaluateJavaScript` | throws or returns `false` | `rebuild(force: true)` (documented fallback for architecture §14 #3) |

---

## 5. Data

### 5.1 Identifiers, formats, constants

| Item | Value |
|---|---|
| Attachment file cache | `<Caches>/attachments/<messageId>/<partId>/<sanitized filename>` (architecture §3.4; purged by 07's `Maintenance.purgeFiles` after 7 days) |
| Testing attachment cache | `NSTemporaryDirectory()/minimail-att-<UUID>` |
| `AttachmentOpener.maxBytes` | `25_000_000` |
| Filename length cap | 120 UTF-8 bytes before the extension is appended |
| `revision` | starts at 0, `1` after `init`, `&+= 1` per reload |
| Size label | `Formatters.bytes(attachment.size)` (01 §3.5 — `ByteCountFormatter`, `.file`) |
| `dateFull` format | `DateFormatter(dateStyle: .full, timeStyle: .short, timeZone:, locale:)` |
| `dateLabel` | `RowDateLabeler.label(epochMs:)` (06 §3.4) — "14:32", "Yesterday", "Mon", "11 Sep", "11.09.25" |

### 5.2 Strings (English literals; `SWIFT_EMIT_LOC_STRINGS = YES` collects them)

Thread screen:

| Key | Text |
|---|---|
| empty subject | `(No subject)` |
| Reply all button | `Reply All` (accessibility label) |
| Forward button | `Forward` |
| Archive button | `Archive` |
| Read toggle, thread unread | `Mark as Read` |
| Read toggle, thread read | `Mark as Unread` |
| notice action | `Retry` |
| notice dismiss | `Dismiss` (accessibility label of the "×") |
| loading indicator | `Loading thread` (accessibility label of the toolbar `ProgressView`) |
| downloading overlay | `Downloading…` (U+2026) |

`ThreadModel.loadErrorText(for:)`:

| Error | Text |
|---|---|
| `GmailError.offline` | `You're offline — showing what's cached.` |
| `GmailError.unauthorized` | `Sign in again to load this thread.` |
| `GmailError.rateLimited` | `Gmail is busy. Try again in a moment.` |
| any other `GmailError`, any other `Error` | `Couldn't load this thread.` |
| (observation failure, set directly) | `Couldn't read the local database.` |

`AttachmentOpener.message(for:)` / inline texts:

| Condition | Text |
|---|---|
| `GmailError.offline` | `You're offline. Try again when you have a connection.` |
| `GmailError.unauthorized` | `Sign in again to download attachments.` |
| `GmailError.rateLimited` | `Gmail is busy. Try again in a moment.` |
| no attachment row / part gone / second 404 (`unavailableText`) | `This attachment is no longer available.` |
| over `maxBytes` (`tooLargeText(size)`) | `This attachment is too large to open (\(Formatters.bytes(size))).` |
| file write failure (`writeFailedText`) | `Couldn't save this attachment.` |
| any other error | `Couldn't download this attachment.` |

In-document strings (subject `h1`, `Loading…`, `Couldn't load this message · Retry`, `Tap to load this message`, `Load images`, `Message truncated`, the attachment separator ` · `) belong to 08 §5.4 and are not repeated here.

### 5.3 SF Symbols

| Where | Symbol |
|---|---|
| Reply all | `arrowshape.turn.up.left.2` |
| Forward | `arrowshape.turn.up.right` |
| Archive | `archivebox` |
| Read toggle, thread unread (action = mark read) | `envelope.open` |
| Read toggle, thread read (action = mark unread) | `envelope.badge` |
| Notice row | `exclamationmark.triangle` |
| Notice dismiss | `xmark` |

Identical to architecture §8.3's bottom-bar list; the read-toggle mapping matches 09's swipe action (`isUnread → envelope.open`).

### 5.4 Accessibility identifiers (for 14's device checklist and hosting tests)

| Element | Identifier |
|---|---|
| web view container | `thread.web` |
| notice row | `thread.notice` |
| notice action button | `thread.notice.action` |
| bottom-bar buttons | `ThreadAction.rawValue` — `thread.replyAll`, `thread.forward`, `thread.archive`, `thread.toggleRead` |
| toolbar progress | `thread.loading` |
| download overlay | `thread.downloading` |

### 5.5 Theme tokens used (01 §3.6; no raw colours — `make lint`)

`background` (screen background and the `UIColor` handed to `MailWebView`), `secondaryText` (notice symbol and text), `accent` (notice action button). Document colours come from `ThemeCSSTokens` (`light`/`dark`), never from SwiftUI `Color`.

`ThemeCSSTokens` are taken from `env.theme.resolved(for:)` so a future non-system theme is honoured; `forcedScheme = env.theme.forcedDocumentTheme` writes `html[data-theme]` and `MailWebView.interfaceStyle = env.theme.interfaceStyle` writes `overrideUserInterfaceStyle` — both paths from day one (architecture §9.5, §14 #5).

### 5.6 `AttachmentOpener.mimeExtensions` (exact table)

```swift
nonisolated static let mimeExtensions: [String: String] = [
    "application/pdf": "pdf",
    "application/rtf": "rtf",
    "application/json": "json",
    "application/zip": "zip",
    "application/msword": "doc",
    "application/vnd.ms-excel": "xls",
    "application/vnd.ms-powerpoint": "ppt",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
    "application/vnd.apple.pages": "pages",
    "application/vnd.apple.numbers": "numbers",
    "application/vnd.apple.keynote": "key",
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/gif": "gif",
    "image/heic": "heic",
    "image/tiff": "tiff",
    "image/svg+xml": "svg",
    "text/plain": "txt",
    "text/html": "html",
    "text/csv": "csv",
    "text/calendar": "ics",
    "message/rfc822": "eml",
    "audio/mpeg": "mp3",
    "video/mp4": "mp4",
]
```
Types outside the table (including `application/octet-stream`) keep the stored filename unchanged.

### 5.7 Log lines (category, level, template; ids `%{public}`, addresses/subjects `%{private}` — architecture §6.5)

| Logger | Level | Template |
|---|---|---|
| `Log.ui` | `.debug` | `thread.open \(threadId) messages=\(n) complete=\(isComplete)` |
| `Log.ui` | `.debug` | `thread.document.rebuilt \(threadId) rev=\(revision) bytes=\(n)` |
| `Log.ui` | `.debug` | `thread.images.loaded \(threadId)` |
| `Log.ui` | `.debug` | `thread.gone \(threadId)` |
| `Log.ui` | `.error` | `thread.load.failed \(threadId) \(error)` |
| `Log.ui` | `.error` | `thread.observation.failed \(threadId) \(error)` |
| `Log.ui` | `.error` | `thread.retry.failed \(messageId) \(error)` |
| `Log.ui` | `.debug` | `attachment.cache.hit \(messageId)/\(partId)` |
| `Log.ui` | `.notice` | `attachment.reresolve \(messageId)/\(partId)` |
| `Log.ui` | `.notice` | `attachment.size.mismatch \(messageId)/\(partId) expected=\(size) got=\(count)` |
| `Log.ui` | `.error` | `attachment.failed \(messageId)/\(partId) \(error)` |

No signpost is begun here: `Log.Interval.threadOpen` and `.bodyLoad` are owned by 07, `.documentLoad` by 08's `WebViewHost.load`.

---

## 6. UI

### 6.1 View hierarchy

```
ThreadScreen(threadId:)                       @State model: ThreadModel?
└─ Group {
     if let model { ThreadContentView(model: model, tokens: themeTokens) }
     else         { themeTokens.background.ignoresSafeArea() }              // one invisible frame at most
   }
   .navigationTitle(model?.title ?? "")
   .navigationBarTitleDisplayMode(.inline)                                  // architecture §8.4
   .toolbar(.visible, for: .bottomBar)
   .toolbar { bottomBar; loadingIndicator }                                 (§6.2)
   .onAppear  { ensureModel(); model?.systemSchemeChanged(colorScheme); model?.attachWeb(openURL: { openURL($0) }) }
   .task      { ensureModel(); await model?.appeared() }
   .task      { for await _ in ThreadScreen.contentSizeChangeStream() { model?.contentSizeChanged() } }
   .onDisappear { model?.detachWeb() }
   .onChange(of: colorScheme)      { model?.systemSchemeChanged($1) }
   .onChange(of: env.theme.choice) { model?.systemSchemeChanged(colorScheme) }
   .onChange(of: model?.shouldDismiss ?? false) { if $1 { dismiss() } }
   .sheet(item: composeBinding) { input in ComposeScreen(input: input) }    // 11 (placeholder until then)
   .quickLookPreview(previewBinding)                                        // [ios-platform §5.4]
   .sensoryFeedback(.impact(weight: .light), trigger: model?.lastActionId ?? 0)

ThreadContentView(model:tokens:)
└─ ZStack {
     tokens.background.ignoresSafeArea()
     MailWebView(host: env.webHost,
                 document: model.document,
                 revision: model.revision,
                 interfaceStyle: env.theme.interfaceStyle,
                 imagesAllowed: model.documentImagesAllowed,
                 backgroundColor: UIColor(tokens.background))
       .accessibilityIdentifier("thread.web")
       .ignoresSafeArea(edges: .bottom)
   }
   .safeAreaInset(edge: .top, spacing: 0) { noticeRow }                     (§6.4)
   .overlay(alignment: .center) { downloadingOverlay }                      (§6.5)
```

`composeBinding` / `previewBinding` are plain `Binding`s built in `ThreadScreen.body` (`Binding(get:set:)` over `model.composeInput` and `model.attachments.previewURL`), because `@Bindable` cannot be declared for a nested object inside `body`.

### 6.2 Toolbar

```swift
ToolbarItemGroup(placement: .bottomBar) {
    button(.replyAll)   { model.replyAll() }        .disabled(!model.canCompose)
    Spacer()
    button(.forward)    { model.forward() }         .disabled(!model.canCompose)
    Spacer()
    button(.archive)    { Task { await model.archive() } }
    Spacer()
    button(.toggleRead) { Task { await model.toggleRead() } }
}
ToolbarItem(placement: .topBarTrailing) {
    if model.loading { ProgressView().accessibilityLabel("Loading thread").accessibilityIdentifier("thread.loading") }
}
```
`button(_ action:)` = `Button(role: nil) { … } label: { Image(systemName: action.symbol(isUnread: model.isUnread)) }` with
`.accessibilityLabel(action.title(isUnread: model.isUnread))` and `.accessibilityIdentifier(action.rawValue)`. System tint only
(`.tint(themeTokens.accent)` is already applied by `RootView`); no explicit colours.

### 6.3 The document (owned by 08, listed for completeness)

One `<h1 class="mm-subject">`, then one `<section class="mm-msg …" data-id="…">` per visible message with: header row (sender, unread dot via `.mm-unread`, date with a `title` full date), collapsed snippet, `To:`/`Cc:` lines, an optional `Load images` row, the body (or `Loading…` / `Couldn't load this message · Retry` / `Tap to load this message`), and a chip row of non-inline attachments with an inline paperclip SVG, filename and size. Colours come from the CSS variables of `ThemeCSSTokens`; text uses `font: -apple-system-body` so Dynamic Type applies (08 §5.5).

### 6.4 Notice row (`ThreadNotice`)

Shown as a `safeAreaInset(edge: .top)` when `model.errorText != nil` **or** `model.attachments.state` is `.failed`. Priority: a failed attachment (the more recent, more explicit action) wins over a thread-load error.

```swift
HStack(spacing: 10) {
    Image(systemName: "exclamationmark.triangle").foregroundStyle(themeTokens.secondaryText).accessibilityHidden(true)
    Text(text).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(2)
    Spacer(minLength: 8)
    if let actionTitle, let action { Button(actionTitle, action: action).font(.footnote.weight(.semibold)) }
    if let dismiss { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss") }
}
.padding(.horizontal, 16).padding(.vertical, 8)
.frame(maxWidth: .infinity)
.background(themeTokens.background)
.accessibilityIdentifier("thread.notice")
```
- thread-load error → `actionTitle = "Retry"`, `action = { Task { await model.retryLoad() } }`, `dismiss = nil`.
- attachment error → `actionTitle = nil`, `dismiss = { model.attachments.dismissError() }`.

This module does not reuse 09's `StatusBanner`: its `InboxBanner` cases (`reauth`/`offline`/`error`) are inbox semantics, and the thread notice needs a dismiss button on a non-reauth kind (§10 D4).

### 6.5 Downloading overlay

```swift
if case .downloading = model.attachments.state {
    VStack(spacing: 8) { ProgressView(); Text("Downloading…").font(.footnote).foregroundStyle(themeTokens.secondaryText) }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("thread.downloading")
}
```
Non-modal: the document stays scrollable. QuickLook opens by itself when `previewURL` becomes non-nil.

### 6.6 States → rendering matrix

| State | Rendering |
|---|---|
| Model not yet created | `themeTokens.background` fills the screen (same colour as `LaunchBackground`) |
| Thread cached, bodies present | full document, newest message expanded, unread messages expanded |
| Thread cached, `isComplete = 0` or `bodiesMissing > 0` | headers render instantly; each missing body shows `Loading…`; toolbar `ProgressView` while `loading` |
| Body arrived | document rebuilt, `revision` bumped, `loadHTMLString` (< 16 ms build; painted < 120 ms, architecture §12.1) |
| `bodyState == 2` | `Couldn't load this message · Retry` inside that section |
| Remote images present, images off | per-message `Load images` row; placeholders collapse to 1×1 |
| Images allowed for a message | that body's `data-src` restored; CSP `img-src` gains `https:`; rule list swapped to images-only |
| Thread-load failure | notice row on top, document unchanged |
| Attachment downloading | centred overlay |
| Attachment failed | notice row with `×` |
| Thread row deleted / archived | `shouldDismiss` → `dismiss()` (pops to the list) |
| Empty thread (no visible message) | cannot happen: `ThreadRepository.recomputeAggregates` deletes thread rows with no visible message (06), so `threadDetail` returns nil → dismiss |

### 6.7 Haptics and navigation

- `.sensoryFeedback(.impact(weight: .light), trigger: model.lastActionId)` fires for Reply all, Forward, Archive, Read/Unread and "Load images" — the same weight 09 uses for swipe actions (architecture §8.3).
- Navigation: this screen is pushed by 09's `NavigationLink(value: ThreadRoute(threadId:))`; it pushes nothing. Compose is a sheet, QuickLook is a system presentation, Archive pops through `dismiss()`. No `NavigationStack` is created here.

---

## 7. Tests

All tests in this module are app tests (`xcodebuild test`; `make test-app`, single file `make test-one T=minimailTests/ThreadModelTests`). No package (`MailCore`/`MailHTML`) files, so nothing runs under `swift test` on Linux.

Shared setup (private to each file; 14 owns `minimailTests/Support`):
```swift
AppEnvironment.testURLProtocolClasses = [StubURLProtocol.self]     // 05 §4.9 hook; reset in tearDown
StubURLProtocol.reset()
env = AppEnvironment(testing: true)                                // temporary DatabasePool, auth .signedOut, no deferred work
db  = env.db
```
Seeding through 06's `TestDatabase` (`parsed(id:threadId:internalDate:labels:…)`, `seed(_:_:)`, `seedLabels`) and 07's `JSONFixtures`. `now = 1_757_500_000_000`. Bodies are written directly:
```swift
try await db.write { d in
    try BodyRepository.storeBody(d, messageId: "m1",
        body: SanitizedBody(html: "<div>Hello</div>", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []),
        text: "Hello", attachments: [], referenced: [], sanitizerVersion: Sanitizer.version, now: now)
    try ThreadRepository.recomputeAggregates(d, threadIds: ["t1"], selfAddresses: ["user@example.com"])
}
```
Helper `func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async` polls every 20 ms (same as 09 §7). `tearDown`: `model.stop()`, `try? env.db.close()`, `StubURLProtocol.reset()`, `AppEnvironment.testURLProtocolClasses = [OfflineURLProtocol.self]`.

### 7.1 `minimailTests/Thread/ThreadModelTests.swift`

| Test | Setup | Assertions |
|---|---|---|
| `testFirstDocumentIsBuiltSynchronously` | seed `m1`,`m2` in `t1` (dates 1, 2, labels `["INBOX"]`), body for both; `ThreadModel(env:threadId:"t1")` | right after `init`: `revision == 1`; `document.contains("<section class=\"mm-msg")`; `document` contains `data-id="m1"` and `data-id="m2"`; `document.hasPrefix("<!doctype html><html")`; `detail?.messages.map(\.id) == ["m1","m2"]` |
| `testInitialExpandedUnreadAndNewest` | three messages in `t1` (`m1` < `m2` < `m3` by `internalDate`) | case A — only `m3` unread: `expanded == ["m3"]` (unread ∪ newest); case B — only `m2` unread: `expanded == ["m2", "m3"]`; case C — none unread: `expanded == ["m3"]`; case D — all unread: `expanded == ["m1","m2","m3"]`; each case also equals `ThreadModel.initialExpanded(model.detail!)` |
| `testExpandedClassesInDocument` | as above | the `<section … data-id="m1">` markup contains `mm-collapsed` and the one for the newest contains `mm-expanded` |
| `testTitleStripsPrefixes` | thread subject `"Re: Fwd: Angebot"` (seed `m1` with that subject; the aggregator strips, then the model strips again) | `model.title == "Angebot"`; `document.contains("<h1 class=\"mm-subject\">Angebot</h1>")`; empty subject → `title == "(No subject)"` and the document carries `(No subject)` |
| `testMissingThreadDismissesImmediately` | no seed; `ThreadModel(env:threadId:"nope")` | `detail == nil`; `shouldDismiss == true`; `document.isEmpty == false` (renders the empty subject document) |
| `testThreadDeletedLaterDismisses` | seed `t1`; model; `try await db.write { _ = try MessageRepository.delete($0, ids: ["m1"]); try ThreadRepository.recomputeAggregates($0, threadIds: ["t1"], selfAddresses: []) }` | `waitUntil { model.shouldDismiss }`; `detail == nil` |
| `testBodyArrivalRebuildsAndBumpsRevision` | seed `m1` with no body; model (`revision == 1`, document contains `Loading…`) | write the body → `waitUntil { model.revision == 2 }`; `document.contains("Hello")`; `document.contains("Loading…") == false` |
| `testUnrelatedTickDoesNotRebuild` | seed `m1` with body; model | `try await db.write { try ThreadRepository.markComplete($0, threadId: "t1", complete: true) }`; after 300 ms `revision == 1` and `document` unchanged |
| `testToggleKeepsRevision` | seed 2 messages with bodies; model | `model.toggle(messageId: "m1")` → `expanded` flipped for `m1`; `revision == 1` (no rebuild); a following unrelated write does not reload (`revision == 1`) because the render key was patched |
| `testToggleOfStrippedSectionRebuilds` | seed 6 messages, each with a 1.2 MB body (so `strippedIds` is non-empty), all collapsed except the newest; model | `ThreadDocument.strippedIds(messages:)` of the model's messages is non-empty; `toggle(messageId: <a stripped id>)` → `revision == 2`; the document for that id no longer contains `Tap to load this message` |
| `testLoadImagesRebuildsAndOpensCSP` | seed `m1` with `hasRemoteImages: true` and an `<img data-src="https://x/y.png" src="\(ThreadDocument.placeholderGIF)">` body | before: `documentImagesAllowed == false`, `document.contains("img-src data: minimail-cid:;")`, `document.contains("Load images")`; `loadImages(messageId: "m1")` → `revision == 2`, `documentImagesAllowed == true`, `document.contains("img-src data: minimail-cid: https:")`, `document.contains("src=\"https://x/y.png\"")`, `document.contains("Load images") == false`; `lastActionId == 1` |
| `testLoadImagesIsPerMessage` | two messages, both with remote images | `loadImages(messageId: "m1")` → `m1`'s body has `src="https://…"`, `m2`'s body still has the placeholder and still shows `Load images` |
| `testGlobalSettingAllowsImages` | `env.settings.update { $0.loadRemoteImages = true }` before the model; seed a remote-image body | `documentImagesAllowed == true`; document has the `https:` CSP; no `Load images` row |
| `testRetryResetsBodyStateAndReloads` | seed `m1`; `try await db.write { try BodyRepository.markUnavailable($0, messageId: "m1") }`; model (document contains `Couldn't load this message`) | `model.retry(messageId: "m1")` → `waitUntil { (try? db.read { try MessageRecord.fetchOne($0, key: "m1")!.bodyState }) == 0 }`; `try InvariantChecks.assertAll(db)` passes (invariant 6: `bodiesMissing` recomputed); `waitUntil { model.document.contains("Loading…") }` |
| `testMarkReadOnOpen` | seed `m1` `["INBOX","UNREAD"]`; model; `await model.appeared()` | `didMarkRead == true`; `waitUntil { model.isUnread == false }`; after 600 ms exactly one pending modify op with `removeLabelIds == ["UNREAD"]` (`OutboxRepository.pendingModifies`); `try InvariantChecks.assertAll(db)` |
| `testMarkReadOnOpenDisabled` | `env.settings.update { $0.markReadOnOpen = false }`; seed unread; `await model.appeared()` | `didMarkRead == false`; `model.isUnread == true`; `pendingModifies(db).isEmpty` |
| `testMarkReadSkippedWhenAlreadyRead` | seed `["INBOX"]` (read); `await appeared()` | `didMarkRead == false`; no outbox row |
| `testAppearedIsIdempotent` | seed unread; `await appeared(); await appeared()` | one modify op only; `StubURLProtocol.recorded` shows at most one `threads/t1?format=full` request |
| `testEnsureThreadLoadedErrorShowsNotice` | seed `t1` with `isComplete = 0`; `StubURLProtocol.install { _ in .error(.notConnectedToInternet) }`; `await appeared()` | `errorText == "You're offline — showing what's cached."`; `loading == false`; `document` still renders the cached headers |
| `testRetryLoadClearsError` | as above, then `StubURLProtocol.routes([(method:"GET", path:"/gmail/v1/users/me/threads/t1", responses:[.json(200, JSONFixtures.thread(id:"t1", messages:[JSONFixtures.fullMessage(id:"m1", thread:"t1", labels:["INBOX"], date: now, html:"<p>Body</p>", text:nil)]))])])`; `await model.retryLoad()` | `errorText == nil`; `waitUntil { model.document.contains("Body") }`; `try db.read { try ThreadRecord.fetchOne($0, key: "t1")!.isComplete } == true` |
| `testArchiveEnqueuesAndDismisses` | seed `t1` `["INBOX"]`; model; `await model.archive()` | `shouldDismiss == true`; `lastActionId == 1`; after 600 ms one pending op `removeLabelIds == ["INBOX"]`; `try db.read { try ThreadRecord.fetchOne($0, key:"t1")!.inInbox } == false`; invariants hold |
| `testToggleReadMarksUnreadThenRead` | seed read thread; model | `await model.toggleRead()` → `waitUntil { model.isUnread }`; `await model.toggleRead()` → `waitUntil { !model.isUnread }`; after 600 ms `pendingModifies(db).isEmpty` (inverse coalesced, 07 §4.6); `lastActionId == 2`; `shouldDismiss == false` |
| `testComposeInputs` | seed `m1`,`m2` in `t1`; model | `replyAll()` → `composeInput == .fromMessage(mode: .replyAll, threadId: "t1", messageId: "m2")`; `forward()` → `.fromMessage(mode: .forward, threadId: "t1", messageId: "m2")`; `canCompose == true`; with an empty thread `canCompose == false` and both calls leave `composeInput == nil` |
| `testHandleRoutesEveryWebMessage` | seed `m1` with one attachment row (`partId "2"`, `attachmentId "A"`); model; `model.attachWeb(openURL: { captured = $0 })` | `handle(.toggle(messageId:"m1"))` flips `expanded`; `handle(.loadImages(messageId:"m1"))` inserts into `imagesAllowedIds`; `handle(.link(URL(string:"https://x")!))` → `captured?.absoluteString == "https://x"`; `handle(.attachment(messageId:"m1", partId:"2"))` → `waitUntil { model.attachments.state != .idle || model.attachments.previewURL != nil }`; `handle(.retry(messageId:"m1"))` does not crash |
| `testThemeChangeRebuilds` | seed with body; model | `model.systemSchemeChanged(.dark)` with `env.theme.choice == .system` → `revision` unchanged (tokens are scheme-independent: both are always emitted); `env.theme.choice = .dark; model.systemSchemeChanged(.dark)` → `revision == 2` and `document.hasPrefix("<!doctype html><html data-theme=\"dark\">")` |
| `testContentSizeChangeForcesReload` | seed with body; model | `let before = model.document`; `model.contentSizeChanged()` → `revision == 2`, `model.document == before` |
| `testDetachWebOnlyByOwner` | two models `a` and `b` for the same env | `a.attachWeb(openURL: { _ in })`; `b.attachWeb(openURL: { _ in })`; `a.detachWeb()` → `env.webBridge.onMessage` still routes to `b` (post a `.toggle` through `env.webBridge.onMessage` and observe `b.expanded` changing); `b.detachWeb()` → routing is a no-op |
| `testStopCancelsObservation` | seed; model; `model.stop()`; write a body | after 300 ms `revision == 1` |

Every test that enqueues an outbox op ends with `try InvariantChecks.assertAll(db)`.

### 7.2 `minimailTests/Thread/AttachmentOpenerTests.swift`

Setup: `let q = try TestDatabase.make()` (in-memory `DatabaseQueue`), one message row plus one attachment row via `TestDatabase.seed` + `BodyRepository.storeBody`; `gmail = GmailClient(tokens: FixedTokenProvider(), session: .minimail(protocolClasses: [StubURLProtocol.self]), limiter: RequestLimiter(max: 2), log: nil, sleep: { _ in })` (07 §3.11's `FixedTokenProvider`); `dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)`; `opener = AttachmentOpener(gmail: gmail, db: q, directory: dir)`; `tearDown` removes `dir`.

| Test | Setup | Assertions |
|---|---|---|
| `testDownloadWritesFileAndSetsPreview` | attachment `(partId "2", filename "report.pdf", mime "application/pdf", size 5, attachmentId "A")`; route `GET /gmail/v1/users/me/messages/m1/attachments/A` → `.json(200, JSONFixtures.attachment(bytes: Data([1,2,3,4,5])))` | `await opener.open(messageId:"m1", partId:"2")`; `previewURL?.lastPathComponent == "report.pdf"`; file exists with 5 bytes; `state == .idle`; exactly one recorded request |
| `testCacheHitSkipsNetwork` | as above, run twice | second `open` records no additional request (`StubURLProtocol.recorded.count` unchanged); `previewURL` set |
| `testReResolveOn404` | attachment id `"STALE"`; routes: `.../attachments/STALE` → 404 envelope, `GET /gmail/v1/users/me/messages/m1` → `.json(200, JSONFixtures.fullMessage(id:"m1", thread:"t1", labels:["INBOX"], date: now, html:"<p>x</p>", text:nil, attachments:[(partId:"2", filename:"report.pdf", mime:"application/pdf", size:5, attachmentId:"FRESH", cid:nil)]))`, `.../attachments/FRESH` → bytes | `previewURL != nil`; the stored row's `attachmentId == "FRESH"` (`BodyRepository.attachment(q, …)`); the recorded paths are exactly `[…/attachments/STALE, …/messages/m1, …/attachments/FRESH]` and the `messages/m1` request query contains `fields=payload` |
| `testSecondNotFoundIsUnavailable` | `.../attachments/STALE` → 404; `messages/m1` returns the part with `attachmentId "FRESH"`; `.../attachments/FRESH` → 404 | `state == .failed("This attachment is no longer available.")`; `previewURL == nil` |
| `testMissingAttachmentIdResolvesFirst` | attachment row with `attachmentId = nil` | the first recorded request is `messages/m1` (no attachment call with a nil id); then `attachments/FRESH`; `previewURL != nil` |
| `testInlineDataFromReResolve` | attachment row with `attachmentId = nil`; `messages/m1` returns a part whose body carries `data` (base64url) and no `attachmentId` | `previewURL != nil`; only one recorded request; the file content equals the decoded inline bytes |
| `testUnknownPartFails` | `open(messageId:"m1", partId:"99")` | `state == .failed("This attachment is no longer available.")`; no request recorded |
| `testTooLargeRefusedBeforeNetwork` | attachment row `size = AttachmentOpener.maxBytes + 1` | `state == .failed("This attachment is too large to open (\(Formatters.bytes(AttachmentOpener.maxBytes + 1))).")`; `StubURLProtocol.recorded.isEmpty` |
| `testOfflineMessage` | `StubURLProtocol.install { _ in .error(.notConnectedToInternet) }` | `state == .failed("You're offline. Try again when you have a connection.")` |
| `testUnauthorizedMessage` | route → 401 envelope twice (client refreshes once, then gives up) | `state == .failed("Sign in again to download attachments.")` |
| `testSecondOpenWhileDownloadingIgnored` | route with `delay: 0.3` | start `Task { await opener.open(…"2") }`; immediately `await opener.open(messageId:"m1", partId:"3")` → returns without recording a request for part 3; after the first finishes `previewURL` points at part 2's file |
| `testSizeMismatchStillOpens` | row `size = 10`, response carries 5 bytes | `previewURL != nil`; file has 5 bytes |
| `testSanitizedFilenames` | pure | `("report.pdf","2","application/pdf") → "report.pdf"`; `("a/b\\c.txt","2","text/plain") → "a_b_c.txt"`; `("","2","application/pdf") → "attachment-2.pdf"`; `("  ","2","image/png") → "attachment-2.png"`; `("notes","2","text/plain") → "notes.txt"`; `("notes","2","application/octet-stream") → "notes"`; `(".ssh","2","text/plain") → "attachment-2.ssh"`; `(String(repeating:"x", count: 300) + ".pdf","2","application/pdf")` has `utf8.count <= 124` and ends with `.pdf`; a name with `U+0000` loses the control character |
| `testFileURLLayout` | pure | `let u = AttachmentOpener.fileURL(root: URL(fileURLWithPath: "/tmp/a"), messageId: "m 1", partId: "0.1", filename: "x.pdf")`; `u.isFileURL`; `u.path.hasSuffix("/0.1/x.pdf")`; `u.pathComponents.contains(" ") == false` and the message-id component is `"m%201"` (space percent-encoded, so no shell/path surprises); a second call with the same inputs returns an equal URL |
| `testPurgeRemovesDirectory` | download once, then `try AttachmentOpener.purge(directory: dir)` | `FileManager.default.fileExists(atPath: dir.path) == false` |

### 7.3 `minimailTests/Thread/ThreadViewsTests.swift`

| Test | Setup | Assertions |
|---|---|---|
| `testThreadActionSymbolsAndTitles` | pure | `ThreadAction.replyAll.symbol(isUnread: false) == "arrowshape.turn.up.left.2"`; `.forward → "arrowshape.turn.up.right"`; `.archive → "archivebox"`; `.toggleRead.symbol(isUnread: true) == "envelope.open"` and `(isUnread: false) == "envelope.badge"`; `.toggleRead.title(isUnread: true) == "Mark as Read"`, `(false) == "Mark as Unread"`; `ThreadAction.allCases.map(\.rawValue) == ["thread.replyAll","thread.forward","thread.archive","thread.toggleRead"]` |
| `testLoadErrorTexts` | pure | `loadErrorText(for: GmailError.offline) == "You're offline — showing what's cached."`; `.unauthorized` → `"Sign in again to load this thread."`; `.rateLimited(retryAfter: nil)` → `"Gmail is busy. Try again in a moment."`; `.server(status: 500)` → `"Couldn't load this thread."`; `CancellationError()` → `"Couldn't load this thread."` |
| `testAttachmentErrorTexts` | pure | `AttachmentOpener.message(for: GmailError.offline)`, `.unauthorized`, `.rateLimited(retryAfter: 3)`, `.notFound`, `.badRequest(reason: nil, message: nil)` match §5.2 |
| `testDocumentMessagesProjection` | build a `ThreadDetail` by hand: 1 message, `toList` two mailboxes, `ccList` empty, one inline and one normal attachment, body row with `darkStrategy "card"`, `hasRemoteImages true` | `documentMessages(...)` returns one element with `toLine == "Alice, bob@x"`, `ccLine == nil`, `darkStrategy == "card"`, `hasRemoteImages == true`, `attachments.count == 1` (the inline one is excluded), `attachments[0].sizeLabel == Formatters.bytes(size)`, `expanded == true` when the id is in the set, `bodyState` copied |
| `testDocumentMessagesWithoutBodyRow` | detail with `bodyState = 0` and no body row | `bodyHTML == nil`, `darkStrategy == "plain"`, `hasRemoteImages == false` |
| `testThreadScreenHostsDocument` | `env = AppEnvironment(testing: true)`; seed `t1` + body; `UIHostingController(rootView: NavigationStack { ThreadScreen(threadId: "t1") }.environment(env).environment(env.theme).environment(env.settings))`; frame 390×844; `layoutIfNeeded()`; `RunLoop.main.run(until: Date() + 0.3)` | no crash; a `WKWebView` descendant exists (walk `view` recursively); `env.deferredWorkStarted == false` |
| `testContentSizeChangeStreamYields` | `let s = ThreadScreen.contentSizeChangeStream()`; consume one value in a `Task`; post `UIContentSizeCategory.didChangeNotification` | expectation fulfilled within 1 s; cancelling the task and posting again does not crash |
| `testPlaceholderThreadScreenRemoved` | pure | `ThreadScreen(threadId: "t")` resolves to `minimail.ThreadScreen` declared in `Features/Thread` — asserted indirectly by `String(describing: ThreadScreen.self) == "ThreadScreen"` plus the file-level acceptance grep of §9.1 (the compiler would reject two identical top-level types anyway) |

Test count: 28 (`ThreadModelTests`) + 15 (`AttachmentOpenerTests`) + 8 (`ThreadViewsTests`) = 51.

---

## 8. Tasks

Ordered; each one sitting (~50–300 lines). Verification runs on the macOS runner unless noted.

- [ ] **T10.1 Model skeleton, observation, first document** — files: `minimail/Features/Thread/ThreadModel.swift` (`ThreadAction`, `ThreadModel` stored/derived state, `init`, `startObservation`, `apply`, `mergeExpanded`, `initialExpanded`, `documentMessages`, `makeRenderKey`, `rebuild`, `makeFullDateFormatter`, `stop`), `minimail/App/AppEnvironment.swift` (`attachmentsCacheDirectory(testing:)`). Done when `make build` passes and a model built over a seeded pool has `revision == 1` and a non-empty `document`. Verify: `make build`. (~230 lines)
- [ ] **T10.2 AttachmentOpener** — file: `minimail/Features/Thread/AttachmentOpener.swift` (complete); test file `minimailTests/Thread/AttachmentOpenerTests.swift` (all 15 tests of §7.2). Done when those pass. Verify: `make test-one T=minimailTests/AttachmentOpenerTests`. (~260 lines)
- [ ] **T10.3 Model behaviour** — file: `ThreadModel.swift` (`appeared`, `loadThread`, `retryLoad`, `toggle`, `evaluate`, `loadImages`, `retry`, `openAttachment`, `handle`, `replyAll`, `forward`, `archive`, `toggleRead`, `systemSchemeChanged`, `contentSizeChanged`, `attachWeb`, `detachWeb`, `observationFailed`, `loadErrorText`); test file `minimailTests/Thread/ThreadModelTests.swift` with the first 14 tests of §7.1 (`testFirstDocumentIsBuiltSynchronously` … `testRetryResetsBodyStateAndReloads`). Done when those 14 pass. Verify: `make test-one T=minimailTests/ThreadModelTests`. (~260 lines)
- [ ] **T10.4 Screen, toolbar, notice, QuickLook** — files: `minimail/Features/Thread/ThreadScreen.swift` (`ThreadScreen`, `ThreadContentView`, `ThreadNotice`, `contentSizeChangeStream`, toolbar, sheet/preview bindings, haptics), `minimail/Features/Inbox/InboxPlaceholders.swift` (delete the placeholder `ThreadScreen`). Done when `make build` passes, 09's `testPlaceholderSignatures` still compiles and `make lint` reports no raw colour under `minimail/Features/Thread`. Verify: `make build && make lint`. (~200 lines)
- [ ] **T10.5 Remaining model tests** — file: `minimailTests/Thread/ThreadModelTests.swift` (the 14 tests from `testMarkReadOnOpen` to `testStopCancelsObservation`). Done when all 28 pass with invariants. Verify: `make test-one T=minimailTests/ThreadModelTests`. (~220 lines)
- [ ] **T10.6 View tests** — file: `minimailTests/Thread/ThreadViewsTests.swift` (all 8 tests of §7.3). Done when they pass. Verify: `make test-one T=minimailTests/ThreadViewsTests`. (~150 lines)
- [ ] **T10.7 Wipe tail + full suite + lint** — files: `minimail/App/AppEnvironment.swift` (attachment purge in `wipeAccountData`). Done when `make test-app` shows `failedTests: 0`, `make format` produces no diff on a second run and `make lint` exits 0. Verify: `make format && git diff --stat && make lint && make test-app`. (~20 lines)
- [ ] **T10.8 Device check** (owner's iPhone after 04's sign-in; adds the thread-view rows to `docs/plan/device-checklist.md`, owned by 14) — no production files. Items and expected outcomes: (a) open a cached thread → headers paint immediately, bodies appear within ~1.5 s on LTE; (b) tap a header → the section collapses/expands **without** the view scrolling to the top (proves `evaluateJavaScript` works with `allowsContentJavaScript = false`, architecture §14 #3; if it jumps, the fallback of §10 A2 is already in place); (c) a newsletter shows placeholders, "Load images" loads them and no other request appears in Charles/`RequestLog`; (d) dark mode: `mm-plain` bodies readable, `mm-card` bodies on a white card, `mm-native` untouched — check with theme = System, Light and Dark (architecture §14 #5); (e) tap a PDF attachment → QuickLook opens with the correct filename; tap again offline → opens from the cache; (f) Archive pops back and the row is gone from the inbox; (g) mark unread → the toolbar icon flips and the inbox row shows the blue dot; (h) change Dynamic Type in Settings and return → the document re-lays out. Verify: checklist items ticked; screenshots to `.build/shot-thread-{light,dark}.png`.

---

## 9. Acceptance criteria

1. `make build` succeeds under Swift 6 / MainActor default with `minimail/Features/Thread/{ThreadModel,ThreadScreen,AttachmentOpener}.swift` present, and the placeholder is gone: `grep -n "struct ThreadScreen" minimail/Features/Inbox/InboxPlaceholders.swift | wc -l` prints `0`.
2. `make test-app` passes the 51 tests of §7 plus every earlier module's tests (`failedTests: 0` in `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact`).
3. `make lint` exits 0 — no raw colour and no SQL string in the new folder: `grep -rnE "Color\((red|\.white|\.black|\.blue|\.indigo|\.green|\.red)" minimail/Features/Thread` prints nothing; `grep -rnE "SELECT |INSERT |UPDATE |DELETE " minimail/Features/Thread` prints nothing.
4. A `ThreadModel` over a seeded pool has `revision == 1` and a complete document **after `init` returns** — no `await` between push and the first `loadHTMLString` (`testFirstDocumentIsBuiltSynchronously`; architecture §12.1 "< 16 ms to `loadHTMLString`").
5. Expand/collapse does not reload: `revision` is unchanged after `toggle` and the following unrelated observation tick (`testToggleKeepsRevision`); a section stripped by the 6 MB cap rebuilds instead (`testToggleOfStrippedSectionRebuilds`).
6. Opening an unread thread marks it read locally and leaves exactly one pending `modify` op with `removeLabelIds == ["UNREAD"]`, with invariants §3.5 holding (`testMarkReadOnOpen`); the behaviour is off when `Settings.markReadOnOpen` is false (`testMarkReadOnOpenDisabled`).
7. "Load images" changes the CSP to `img-src data: minimail-cid: https:`, restores `data-src` **only** for the tapped message and removes that message's "Load images" row (`testLoadImagesRebuildsAndOpensCSP`, `testLoadImagesIsPerMessage`).
8. An attachment tap downloads with the stored `attachmentId`, re-resolves exactly once through `messages.get?format=full&fields=payload` on 404, persists the fresh id and sets `previewURL` (`testReResolveOn404`); a second 404 reports "This attachment is no longer available." (`testSecondNotFoundIsUnavailable`); a cached file costs zero requests (`testCacheHitSkipsNetwork`).
9. Archive pops the screen and clears `inInbox` (`testArchiveEnqueuesAndDismisses`); a deleted thread pops by itself (`testThreadDeletedLaterDismisses`); no alert is ever presented: `grep -rn "\.alert(" minimail/Features/Thread | wc -l` prints `0`.
10. No timer and no polling exists in the module: `grep -rnE "Timer|DispatchSourceTimer|CADisplayLink" minimail/Features/Thread | wc -l` prints `0`; the only `db.write` is the retry path: `grep -rn "db.write" minimail/Features/Thread | wc -l` prints `1`.
11. Manual device step T10.8 items (a)–(h) tick, in particular (b) — the JS toggle keeps the scroll position — and (d) — all three theme settings render correctly in the web view.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | Architecture §8.4 says attachments are written to `tmp/attachments/<messageId>/<filename>`, §3.4 says the file cache is `Caches/attachments/<messageId>/<partId>/<filename>` and §4.9 purges `Caches/attachments` (implemented by 07's `Maintenance.purgeFiles`). | DEVIATION (§8.4 phrasing) | The `Caches/attachments/<messageId>/<partId>/<filename>` layout wins: it is the one the cleanup statement and 07's implementation address, and `<partId>` prevents two parts with the same filename from colliding. QuickLook reads from `Caches` as happily as from `tmp`. |
| D2 | Architecture §8.2 lists `previewURL: URL?` as `ThreadModel` state. | DEVIATION (placement) | It lives on `AttachmentOpener` (`model.attachments.previewURL`) so download state and the binding stay in one object; `ThreadScreen` builds the `Binding` for `.quickLookPreview`. No behaviour changes. |
| D3 | `AttachmentOpener.init(gmail:db:directory:)` takes `any DatabaseWriter`, not `DatabasePool`. | DEVIATION (additive) | Same reason as 07 D1 / 08 D3: tests pass a `DatabaseQueue`. |
| D4 | Reusing 09's `StatusBanner` for the thread notice. | choice | Not reused: `InboxBanner` models inbox states (reauth/offline/error) and its dismiss button is `.reauth`-only. `ThreadNotice` is ~25 lines, uses the same symbols/tokens, and keeps 09's type free of thread concerns. |
| D5 | `ThreadModel` performs one `db.write` (the per-message Retry). | DEVIATION (architecture §12.3 "UI only observes") | Sanctioned by 08 §10 D2, which assigns `BodyRepository.resetUnavailable` + `ensureThreadLoaded` to module 10. The write calls repositories only (no SQL in `Features/`) and recomputes the thread aggregate in the same transaction so invariant §3.5-6 holds. |
| D6 | Test files `minimailTests/Thread/*.swift` are not in the architecture §1.3 tree (which lists only `SmokeTests` for screen hosting). | DEVIATION (additive) | Same precedent as 01/06/07/08/09; 14's `SmokeTests` still hosts `ThreadScreen`. |
| D7 | `ThreadAction` is not named in the architecture. | additive | Pure enum carrying the symbol/title/identifier tables so §7.3 can test them without hosting a view. |
| A1 | `evaluateJavaScript` and `window.webkit.messageHandlers` keep working with `allowsContentJavaScript = false`. | UNVERIFIED (`[html-rendering §2.1]` quotes WWDC20 10188; architecture §14 #3) | Assumed true. Fallback already coded: `toggle` falls back to `rebuild(force: true)` whenever the script returns `false`/throws or the loaded revision is stale, so a device failure degrades to "reload on toggle, scroll position lost" without a code change. Device check T10.8 (b). |
| A2 | Scroll position after a forced reload | accepted loss | Stage 1 does no `scrollTo` restore (architecture §9.6 "no measuring"). Reloads happen only when bodies arrive, images are enabled, the theme changes or Dynamic Type changes. |
| A3 | "Mark as Unread" does not pop back to the list. | choice | The architecture does not specify it; staying open lets the user flip back immediately, and `markReadOnOpen` will not re-mark (it runs once per screen, guarded by `didAppear`). If the owner prefers Mail's behaviour, add `shouldDismiss = true` in the `markUnread` branch (one line). |
| A4 | Inline `cid:` parts (`attachment.isInline = 1`) are not listed as attachment chips. | choice | They are already visible in the body (architecture §9.4) and `thread.hasAttachments` counts only non-inline rows (06). Consequence: an inline image cannot be saved from the thread view in stage 1; it can be attached when forwarding (architecture §7.6). |
| A5 | `expanded` is seeded before mark-read runs, so previously-unread messages stay expanded after the thread turns read. | choice | Matches "default: all unread + newest" (architecture §8.2) read as "unread at the moment of opening". |
| A6 | A reply arriving while the screen is open is expanded automatically when it is unread or newest (`mergeExpanded`). | assumption | Keeps the newest message visible, which is what the initial rule does. Existing messages never change expansion behind the user's back. |
| A7 | `.quickLookPreview(_:)` (iOS 14) sets the binding back to nil on dismissal. | `[ios-platform §5.4]` (quoted from Apple's doc) | If it does not, `AttachmentOpener.previewURL` stays set and a second tap on the same attachment would not re-present; fallback: clear `previewURL` in `ThreadScreen.onDisappear` and set it through a `UUID`-keyed wrapper. |
| A8 | `.toolbar(.visible, for: .bottomBar)` + `ToolbarItemGroup(placement: .bottomBar)` renders four evenly spaced buttons on iOS 17. | assumed (Apple docs; not in the research files) | Fallback: `.safeAreaInset(edge: .bottom) { HStack { … } }` with the same symbols, labels and identifiers. |
| A9 | `UIColor(themeTokens.background)` round-trips the dynamic system colour used for the web view's background/`underPageBackgroundColor`. | UNVERIFIED (08 §10 A11) | Stock themes resolve to `UIColor.systemBackground`, which `WebViewHost` already applies before the first load; if the conversion loses dynamism, pass `UIColor.systemBackground` for the stock themes (still token-derived; `make lint` unaffected). |
| A10 | Two `ThreadScreen`s never coexist, but their appear/disappear callbacks can interleave. | assumption | Handled by the `ThreadModel.webOwner` token (§4.9) and tested by `testDetachWebOnlyByOwner`. |
| A11 | `AppEnvironment.testURLProtocolClasses` may be assigned before constructing a test environment (05 D8). | 05 §4.9 | If 14 later centralises this in `Support/`, the two test files use that helper instead; no production change. |
| A12 | `SubjectPrefix.stripForDisplay` applied to `thread.subject` (already stripped by `ThreadAggregator`) is idempotent. | assumption | Architecture §8.4 says to apply it for the nav title; applying it to an already-stripped string must be a no-op. `testTitleStripsPrefixes` pins it. |
| O1 | Whether a very long thread (> 6 MB of bodies) needs a "load the rest" affordance beyond the per-section `Tap to load this message` skeleton. | open | Stage 1 keeps 08's behaviour (tap a stripped section → rebuild with that body). Revisit only if the owner hits it. |
| O2 | Whether `markReadOnOpen` should wait until the thread is actually readable (bodies loaded). | open | No: architecture §8.2 says "not waiting for bodies". A thread opened by accident is marked read, same as iOS Mail. |
