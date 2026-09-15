# 11-compose — `ComposeScreen`, `ComposeModel`, draft prefill, quote snapshot, `SendJob`, failed-send reopen

Module 11 of `docs/plan/design/modules.md`. Sources of truth: `architecture.md` §2.1 (layering + isolation rules), §2.2 (`MailCore` compose interface — `ReplyAll`, `SubjectPrefix`, `Quoting`, `QuoteSource`, `ComposeMode`, `MessageIDs`, `AddressParser`, `Mailbox`), §2.3 (`QuoteExtractor`), §2.4 (`SendJob`, `ForwardAttachmentRef`, `Queries.threadDetail`, `MailActions.send`, `Outbox.discardSend`), §3.2 (`message`, `message_body`, `attachment`, `outbox` columns), §4.8 (outbox enqueue + failed-send UX), §7.1 (reply-all recipients), §7.2 (prefill — this module's core algorithm), §7.3–§7.6 (what the *outbox* does with the job at drain time), §7.7 (`performSend`), §8.1 (navigation graph), §8.2 (screen contract), §8.5 (compose screen conventions), §10 (theme tokens), §12.1/§12.3 (performance), §13.1/§13.3 (test layers), §14 #9/#13/#21/#25, §15 D8/D12/D24, §16 (non-goals); `docs/plan/design/modules.md` §11. Research is cited as `[mime-rfc §n]`, `[ios-platform §n]`, `[html-rendering §n]`, `[gmail-api §n]`; anything those files mark UNVERIFIED stays UNVERIFIED here (§10).

Depends on: **02-mailcore-mime** (`ReplyAll`, `SelfIdentity`, `Recipients`, `SubjectPrefix`, `ComposeMode`, `QuoteSource`, `Quoting.textFromHTML`, `MessageIDs`, `AddressParser`, `Mailbox`, `ComposeStyle`), **07-sync-outbox** (`MailActions.send`, `Outbox.maxForwardAttachmentBytes`, `Outbox.discardSend`, `OutboxIdentitySource.current()`, `SyncEngine.ensureThreadLoaded`), **10-thread-view** (presents this sheet with `ComposeInput.fromMessage`; deletes nothing of this module), and transitively **09-inbox-list** (`ComposeInput`, `ActiveSheet`, the `ComposeScreen(input:)` placeholder this module replaces), **06-storage** (`Queries.threadDetail`, `ThreadDetail`, `MessageRecord`, `MessageBodyRecord`, `AttachmentRecord`, `SendJob`, `ForwardAttachmentRef`, `OutboxRecord`, `SyncStateRepository`, `TestDatabase`, `InvariantChecks`), **08-html-rendering** (`QuoteExtractor.quotable`), **01-project-setup** (`AppEnvironment`, `ThemeTokensReader`, `Formatters.bytes`, `Log.ui`, `Settings.signatureEnabled`).

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. **`ComposeScreen(input:)`** — the reply-all / forward sheet of architecture §8.5: a `NavigationStack` around a `Form` with To / Cc / Subject fields, a plain `TextEditor` body, an optional Attachments section with per-attachment toggles and a size budget, and a read-only `Text` preview of the quoted original. Leading **Cancel** (with a discard confirmation when the draft has content), trailing **Send** (disabled until the draft is valid). Send enqueues and dismisses immediately; it never waits on the network.
2. **`ComposeModel`** — the `@Observable` main-actor model that performs `makeDraft()` (architecture §7.2) from **cached data only**: reply-all recipients through `ReplyAll.recipients`, subject through `SubjectPrefix`, threading headers through `MessageIDs.referencesChain`, a frozen `messageID`, the forward attachment refs, and the `QuoteSource` snapshot built with `QuoteExtractor.quotable`. It gates Send on `quoteReady` while the original body is still loading, validates addresses with `AddressParser`, builds the `SendJob` and hands it to `MailActions.send`.
3. **Failed-send reopen** — the second `ComposeInput` case (`.failedSend(outboxId:job:)`, produced by 09's Outbox section): every field is restored from the stored `SendJob`, and Send creates a new outbox row and then deletes the old failed one (architecture §4.8 "Send creates a new job and deletes the old one").
4. Two pure, testable helpers used by the model: **`ComposeDraftBuilder`** (record → `Draft`, injectable `UUID`) and **`ComposeAddressField`** (mailboxes ↔ editable text, address validation).
5. Deletion of the interim `ComposeScreen` placeholder in `minimail/Features/Inbox/InboxPlaceholders.swift` (09 §3.5).
6. App tests `minimailTests/Compose/ComposeModelTests.swift` and `minimailTests/Compose/ComposeViewsTests.swift` (XCTest on the simulator, `make test-app`).

### 1.2 Explicitly out of scope (owned elsewhere)

- **MIME building and the send network path** — `OutgoingBodies`, `Quoting.replyHTML/replyText/forwardHTML/forwardText`, `MIMEBuilder.build`, `Base64URL`, `GmailClient.send` (02 / 05 / 07). This module stores a `SendJob`; §7.3–§7.7 of the architecture happen at **drain time** inside `Outbox.performSend`.
- **Attachment bytes.** Forward attachments are never downloaded here — only their `ForwardAttachmentRef` metadata travels in the job; `Outbox.fetchAttachments` downloads them at drain time with one `attachmentId` re-resolution (architecture §7.6).
- **Signature content and the compose style.** `Settings.signatureHTML`, `SignatureSanitizer`, the font/size/colour picker and "Import from Gmail" belong to 13; the signature HTML and `ComposeStyle` are read by 07's identity closure at drain time, never by this module. This module only carries the boolean `SendJob.includeSignature`.
- **A second `WKWebView`.** The quoted original is SwiftUI `Text` built from `QuoteSource.text` (architecture D12, §8.5). No height measuring, no HTML rendering, no rich text.
- **Compose-new-mail, drafts UI, autosave, `mailto:` handling, attachment picking from the device, Bcc, per-message read state** — architecture §16 non-goals.
- **Any SQL text.** The only database access is `Queries.threadDetail` (06) through `env.db.read` and one `ValueObservation` over the same function (architecture §2.1 rule 3).
- **Any `GmailClient` / `URLSession` call** (rule 2). The single sync call this module makes is `SyncEngine.ensureThreadLoaded(threadId:)`, and only when the original body is missing (§4.4).
- `ComposeInput`, `ActiveSheet`, `ThreadRoute` — declared by 09; consumed, never redeclared.

### 1.3 Consumers and the exact symbols they take

| Consumer | Symbols consumed from this module |
|---|---|
| 09 inbox list | `ComposeScreen(input:)` — presented for `ActiveSheet.compose(.failedSend(outboxId:job:))`; the placeholder struct in `InboxPlaceholders.swift` is deleted by this module and `testPlaceholderSignatures` keeps compiling |
| 10 thread view | `ComposeScreen(input:)` — presented for `ComposeInput.fromMessage(mode:threadId:messageId:)` from the Reply all / Forward toolbar buttons |
| 13 settings | nothing (it deletes `InboxPlaceholders.swift` after 10/11/12 removed their structs) |
| 14 qa | `ComposeScreen(input:)` hosted in `SmokeTests` ("prefilled recipients" assertion of architecture §13.1), `ComposeModel` state assertions, the accessibility identifiers of §6.8 |

---

## 2. Files

| Path (relative to repo root) | Kind | Purpose |
|---|---|---|
| `minimail/Features/Compose/ComposeModel.swift` | new | `ComposePhase`, `ComposeAttachmentItem`, `ComposeAddressField`, `ComposeDraftBuilder`, `ComposeModel` (prefill, quote gating, validation, job construction, send, resend) |
| `minimail/Features/Compose/ComposeScreen.swift` | new | `ComposeScreen` (NavigationStack + Form + toolbar + discard dialog + haptics), private `ComposeFieldsSection`, `ComposeAttachmentsSection`, `ComposeQuoteSection`, `ComposeUnavailableView` |
| `minimail/Features/Inbox/InboxPlaceholders.swift` | modify | delete the interim `struct ComposeScreen` (09 §3.5); the file keeps `ThreadScreen` (until 10), `LabelsScreen` (until 12) and `SettingsScreen` (until 13) |
| `minimailTests/Compose/ComposeModelTests.swift` | new | prefill, quote snapshot/gating, validation, attachments/budget, job construction, send + resend (§7.1) |
| `minimailTests/Compose/ComposeViewsTests.swift` | new | pure helpers (`ComposeAddressField`, `ComposeDraftBuilder`, strings) + `UIHostingController` smoke tests (§7.2) |

No `Packages/MailCore` file is added or edited: every pure algorithm this screen needs already exists in `MailCore` (02) and `MailHTML` (08). No `project.yml` change (the app target globs `minimail/`, the test target globs `minimailTests/` — 01 §1.4). No `Info.plist` key, no entitlement, no asset, no `UserDefaults` key, no migration.

`make lint` constraints for the two new files: imports are `Foundation`, `GRDB`, `MailCore`, `MailHTML`, `Observation`, `os` (model) and `SwiftUI`, `MailCore` (screen) — never `AppAuth`, `WebKit`, `UIKit` (see §10 A3 for the haptic fallback), never `SwiftSoup`; no raw colour literal (all colours through `ThemeTokensReader`); no `INSERT`/`UPDATE`/`DELETE`/`SELECT` string anywhere.

---

## 3. Public interface

Conventions (01 §3, 06 §3, 09 §3): the app target builds with `SWIFT_VERSION = 6` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` `[ios-platform §5.6]`, so every declaration below is `@MainActor` **implicitly** unless it carries an explicit `nonisolated`. App declarations are `internal` (no `public`). Value types that cross into GRDB `@Sendable` fetch closures or into actor calls (`MailActions`, `Outbox`, `SyncEngine`) are `nonisolated` and `Sendable`.

Signatures marked `// verbatim` are copied from architecture §2.4 / §8.2 / §8.5 or from spec 09. Deviations are listed in §10.

### 3.1 `minimail/Features/Compose/ComposeModel.swift`

```swift
import Foundation
import GRDB
import MailCore
import MailHTML
import Observation
import os

/// Load state of the compose sheet (architecture §8.2, column "Empty / loading / error").
nonisolated enum ComposePhase: Equatable, Sendable {
    /// `makeDraft()` has not finished its single cache read yet. Fields are empty and Send is disabled.
    /// Reached only by `.fromMessage`; `.failedSend` is `.ready` when `init` returns.
    case loading
    /// Draft prefilled, fields editable. Send may still be disabled — see `canSend`.
    case ready
    /// The original message is not in the cache (deleted by a delta sync, hidden by TRASH/SPAM/DRAFT/CHAT,
    /// or its thread was evicted by `Maintenance.cleanup`). Payload = the sentence rendered in §6.4.
    case unavailable(String)
}

/// One row of the "Attachments" section — architecture §8.2 `attachments: [(ref, included)]`.
nonisolated struct ComposeAttachmentItem: Identifiable, Equatable, Sendable {
    /// What travels in `SendJob.attachments` when `included` is true (bytes are fetched by 07 at drain time).
    var ref: ForwardAttachmentRef
    /// The part is referenced by a `cid:` in the sanitized body. Listed but NOT selected by default: its `<img>` was
    /// removed from the quote by `QuoteExtractor`, and stage 1 does not re-attach inline images (architecture §7.6, §14 #21).
    var isInline: Bool
    /// Toggle state. Only included refs reach the `SendJob`.
    var included: Bool
    /// `ref.partId` — unique inside one message.
    var id: String { get }
    /// `Formatters.bytes(ref.size)`, e.g. `"1.5 MB"`.
    var sizeLabel: String { get }
}

/// Mailbox list ↔ editable text-field content, plus address validation (architecture §8.2 "to/cc as
/// comma-separated editable text", §8.5 "`AddressParser.parseList` on Send").
nonisolated enum ComposeAddressField {

    /// `mailboxes.map(display).joined(separator: ", ")`. Empty list → `""`.
    static func text(for mailboxes: [Mailbox]) -> String

    /// Human-readable, re-parsable form of one mailbox (§4.6):
    /// * `name` nil or blank → `addr`
    /// * `name` free of `"(),:;<>@[]\` and of leading/trailing whitespace → `Name <addr>`
    /// * otherwise → `"escaped name" <addr>` (`\` and `"` backslash-escaped)
    /// Non-ASCII names stay literal — unlike `Mailbox.serialized()`, which RFC 2047-encodes them for the wire (§10 D4).
    static func display(_ mailbox: Mailbox) -> String

    /// `AddressParser.parseList(text)` split into addresses that pass `isValidAddrSpec` and the raw `addr`
    /// strings of those that do not. Never throws; `text` that is empty or whitespace yields `([], [])`.
    static func parse(_ text: String) -> (mailboxes: [Mailbox], invalid: [String])

    /// Exactly one `@`; non-empty local part; non-empty domain without a leading/trailing `.` and without `..`;
    /// no whitespace anywhere; none of `<>,;:"\[]()` anywhere. A dotless domain (`user@localhost`) is accepted (§4.6).
    static func isValidAddrSpec(_ addr: String) -> Bool
}

/// Pure prefill of architecture §7.2 — everything `ComposeModel.makeDraft()` computes from one cache read.
/// Kept separate from the model so it is testable without an `AppEnvironment` and with an injected `UUID`.
nonisolated enum ComposeDraftBuilder {

    /// The frozen part of a draft: what the user may not edit and what the `SendJob` inherits verbatim.
    struct Draft: Equatable, Sendable {
        var mode: ComposeMode
        var originalMessageId: String
        var threadId: String
        /// Prefilled recipients (editable afterwards through `ComposeModel.toText` / `.ccText`).
        var to: [Mailbox]
        var cc: [Mailbox]
        var subject: String
        /// `"<UUID@domain>"`, frozen here and never regenerated (architecture §7.2, §14 #9).
        var messageID: String
        var inReplyTo: String?
        var references: [String]
        /// Snapshot of the original; `nil` html when no body row exists yet (`quoteReady == false`) or the
        /// body is unavailable.
        var quote: QuoteSource
        /// `false` while the original body is still loading — Send stays disabled (architecture §7.2).
        var quoteReady: Bool
        /// Forward only; empty for `.replyAll`.
        var attachments: [ComposeAttachmentItem]
    }

    /// Architecture §7.2, steps 1–6 of §4.2/§4.3. Pure; no I/O; never throws.
    /// - Parameters:
    ///   - original: the cached message being replied to / forwarded.
    ///   - body: its `message_body` row when present (`nil` → `quoteReady` follows `original.bodyState`).
    ///   - attachments: the `attachment` rows of `original` in `(messageId, partId)` order; only used for `.forward`.
    ///   - identity: `SelfIdentity` from `OutboxIdentitySource.current()` — drives reply-all self-exclusion and the
    ///     `Message-ID` domain.
    ///   - uuid: injected for deterministic tests; production uses the default.
    static func make(mode: ComposeMode,
                     original: MessageRecord,
                     body: MessageBodyRecord?,
                     attachments: [AttachmentRecord],
                     identity: SelfIdentity,
                     uuid: UUID = UUID()) -> Draft

    /// The `QuoteSource` snapshot alone (§4.4), re-run when a late body arrives.
    /// `ready == false` only when `body == nil && original.bodyState == 0`.
    static func quote(original: MessageRecord, body: MessageBodyRecord?) -> (quote: QuoteSource, ready: Bool)

    /// Everything after the first `@` of `email`, lowercased; `""` when there is none
    /// (`MessageIDs.generate` then substitutes `localhost`).
    static func domain(ofEmail email: String) -> String
}

/// Main-actor model of the compose sheet (architecture §8.2 row "ComposeScreen / ComposeModel").
///
/// One instance per presented sheet, owned by `ComposeScreen` as `@State`. `init` performs **no** I/O for
/// `.fromMessage` (phase `.loading`) and none at all for `.failedSend` (phase `.ready`); the single cache read
/// happens in `makeDraft()`, which the screen awaits in `.task`.
@Observable final class ComposeModel {

    /// Forward budget — `Outbox.maxForwardAttachmentBytes` (20_000_000, architecture §7.6). Re-exported so the
    /// screen and the tests do not reach into the outbox actor's type for a number.
    static let maxAttachmentBytes: Int = Outbox.maxForwardAttachmentBytes

    /// Composition root. `db`, `actions`, `outbox`, `sync`, `identitySource` and `settings` are read from it at call
    /// time (07 D6: `AppEnvironment.actions` is rebuilt after an account wipe, so it is never cached).
    let env: AppEnvironment
    /// What the sheet was opened with (09 §3.1).
    let input: ComposeInput

    // ---- observed state ----
    private(set) var phase: ComposePhase
    /// `.replyAll` or `.forward`; from `input` (both cases carry it) and never changed afterwards.
    private(set) var mode: ComposeMode
    /// Editable recipient fields, comma-separated (`ComposeAddressField.text(for:)` on prefill).
    var toText: String
    var ccText: String
    /// Editable subject (prefilled `"Re: …"` / `"Fwd: …"`).
    var subject: String
    /// The typed body — plain text, exactly what becomes `SendJob.typedText` (architecture §8.5, `[ios-platform §5.3]`).
    var body: String
    /// Attachment toggles; empty for `.replyAll` and for forwards of a message without attachment rows.
    private(set) var attachments: [ComposeAttachmentItem]
    /// `Settings.signatureEnabled` at sheet-open time (`.fromMessage`) or `job.includeSignature` (`.failedSend`).
    /// Not editable in stage 1 — architecture §8.5 lists no signature control (§10 A4).
    private(set) var includeSignature: Bool
    /// `false` while the original body is still being fetched; Send is disabled until it flips (architecture §7.2).
    private(set) var quoteReady: Bool
    /// Read-only preview text of the quoted original (`QuoteSource.text`), rendered by §6.5. `""` until `quoteReady`.
    private(set) var quotePreview: String
    /// `true` from the moment Send was accepted until the sheet goes away; keeps a second tap from enqueuing twice.
    private(set) var isSending: Bool
    /// Monotonic counter feeding `.sensoryFeedback(.success, trigger:)` (architecture §8.3 ".success on send enqueue").
    private(set) var sendFeedbackId: Int

    // ---- derived (computed; no storage, no side effects) ----
    /// `"Reply All"` for `.replyAll`, `"Forward"` for `.forward` (navigation title, §6.2).
    var title: String { get }
    /// Message shown under the To field (§4.6). `nil` when the recipients are valid.
    var validation: String? { get }
    /// Σ `ref.size` of the included attachments.
    var attachmentBytes: Int { get }
    /// Footer of the Attachments section: `"3 attachments · 4.2 MB"`, or the over-budget sentence (§4.7). `nil` when
    /// there are no attachment rows.
    var attachmentFooter: String? { get }
    /// `phase == .ready && quoteReady && !isSending && validation == nil && attachmentBytes <= maxAttachmentBytes`.
    var canSend: Bool { get }
    /// Cancel needs a confirmation: the typed body is not blank, or the recipients/subject differ from the prefill,
    /// or (`.failedSend`) always — the row is being re-edited (§4.9).
    var hasContent: Bool { get }

    /// - Parameters:
    ///   - env: composition root (`env.db` is open after launch step 1).
    ///   - input: `.fromMessage(mode:threadId:messageId:)` (from 10) or `.failedSend(outboxId:job:)` (from 09).
    ///   - uuid: injected `Message-ID` UUID for deterministic tests; production uses the default.
    /// Performs no `await`, no `Task`, no database access. For `.failedSend` every field is filled from the job here.
    init(env: AppEnvironment, input: ComposeInput, uuid: @escaping () -> UUID = UUID.init)

    /// Architecture §7.2 prefill — **main actor, from cached data only**, exactly one `env.db.read`.
    /// Idempotent: a second call while `phase != .loading` returns immediately. Never throws.
    ///
    /// `.failedSend` → immediate return (the draft came from the job).
    /// `.fromMessage` → identity (`OutboxIdentitySource.current()`) → `Queries.threadDetail` → `ComposeDraftBuilder.make`
    /// → `phase = .ready`. A missing thread, a missing/hidden message or a failing read sets
    /// `phase = .unavailable(…)` (§4.2 step 4). When the body has not been cached yet it starts the body
    /// observation (§4.4) and asks `SyncEngine.ensureThreadLoaded(threadId:)` once.
    func makeDraft() async

    /// Attachment toggle (§4.7). Unknown `partId` is ignored.
    func setAttachment(partId: String, included: Bool)

    /// Builds the job the way `Outbox.performSend` expects it (§4.8). `nil` when `canSend == false`.
    /// Recipients are re-parsed from the text fields here, not at prefill time.
    func makeJob() -> SendJob?

    /// Send (architecture §8.2 "→ `MailActions.send(job)` → dismiss immediately").
    /// Returns `false` and does nothing when `canSend == false`; otherwise sets `isSending`, bumps `sendFeedbackId`
    /// and starts one unstructured `Task` that outlives this model: `MailActions.send(job)` and, for `.failedSend`,
    /// `Outbox.discardSend(id:)` afterwards (§4.8). The caller dismisses the sheet in the same turn.
    @discardableResult func send() -> Bool

    /// Cancels the body observation. Called from `.onDisappear` and by the tests.
    func stop()
}
```

### 3.2 `minimail/Features/Compose/ComposeScreen.swift`

```swift
import MailCore
import SwiftUI

/// Reply-all / forward sheet (architecture §8.1 "sheet ComposeScreen(input)", §8.5).
/// Signature verbatim from 09 §3.5 (the placeholder this file replaces).
struct ComposeScreen: View {                                                    // verbatim
    init(input: ComposeInput)                                                   // verbatim
    var body: some View
}

/// Which field owns the keyboard when the sheet appears (§6.7).
private enum ComposeField: Hashable { case to, cc, subject, body }

/// To / Cc / Subject + the validation footer.
private struct ComposeFieldsSection: View {
    @Bindable var model: ComposeModel
    var focus: FocusState<ComposeField?>.Binding
    var body: some View
}

/// Forward attachments with their toggles and the budget footer. Rendered only when `!model.attachments.isEmpty`.
private struct ComposeAttachmentsSection: View {
    let model: ComposeModel
    var body: some View
}

/// Read-only quoted original (`Text`, never a web view — architecture D12).
private struct ComposeQuoteSection: View {
    let model: ComposeModel
    var body: some View
}

/// `phase == .unavailable(text)` state (§6.4).
private struct ComposeUnavailableView: View {
    let text: String
    var body: some View
}
```

### 3.3 `minimail/Features/Inbox/InboxPlaceholders.swift` (modify)

```swift
// DELETED by this module (09 §3.5 said: "Module 11 deletes `ComposeScreen`"):
//
// /// Replaced by module 11 (`minimail/Features/Compose/ComposeScreen.swift`).
// struct ComposeScreen: View { init(input: ComposeInput); var body: some View }
//
// The file keeps `ThreadScreen` (deleted by 10), `LabelsScreen` (12) and `SettingsScreen` (13);
// module 13 deletes the file itself. 09's `testPlaceholderSignatures` must keep compiling unchanged.
```

---

## 4. Behaviour

### 4.1 Lifecycle

```
ComposeScreen.body
  .task        { await model.makeDraft() }          // once per presentation; idempotent
  .onDisappear { model.stop() }

init(env:input:uuid:)                                 // no I/O
  case .failedSend(outboxId, job):
      mode = job.mode; toText = ComposeAddressField.text(for: job.to); ccText = …(job.cc)
      subject = job.subject; body = job.typedText
      attachments = job.attachments.map { ComposeAttachmentItem(ref: $0, isInline: false, included: true) }
      includeSignature = job.includeSignature
      draft = Draft(mode: job.mode, originalMessageId: job.originalMessageId, threadId: job.threadId,
                    to: job.to, cc: job.cc, subject: job.subject, messageID: job.messageID,
                    inReplyTo: job.inReplyTo, references: job.references,
                    quote: job.quoteSource, quoteReady: true, attachments: attachments)
      quoteReady = true; quotePreview = job.quoteSource.text ?? ""
      phase = .ready
  case .fromMessage(mode, _, _):
      self.mode = mode; toText = ""; ccText = ""; subject = ""; body = ""
      attachments = []; includeSignature = env.settings.snapshot.signatureEnabled
      quoteReady = false; quotePreview = ""; phase = .loading
```

`isSending = false`, `sendFeedbackId = 0` in both cases. The model holds `private var draft: ComposeDraftBuilder.Draft?` and `private var bodyCancellable: AnyDatabaseCancellable?` (name UNVERIFIED, `[ios-platform §2.6]`, same assumption as 09 §10 A2).

### 4.2 `makeDraft()` — reply-all (architecture §7.2)

```
makeDraft():
 1. guard case .fromMessage(mode, threadId, messageId) = input else { return }      // .failedSend is already ready
 2. guard phase == .loading else { return }                                          // idempotent
 3. let (identity, _, _) = await env.identitySource.current()                        // 07 §3.6: syncState + Settings
 4. let detail: ThreadDetail? = try? await env.db.read { try Queries.threadDetail($0, threadId: threadId) }
    guard let detail, let original = detail.messages.first(where: { $0.id == messageId }) else {
        phase = .unavailable("This message is no longer available."); Log.ui.notice(…); return }
 5. let body = detail.bodies[messageId]
    let atts = detail.attachments.filter { $0.messageId == messageId }               // already (messageId, partId)-ordered
    let d = ComposeDraftBuilder.make(mode: mode, original: original, body: body,
                                     attachments: atts, identity: identity, uuid: uuid())
 6. draft = d
    toText = ComposeAddressField.text(for: d.to); ccText = ComposeAddressField.text(for: d.cc)
    subject = d.subject; attachments = d.attachments
    quoteReady = d.quoteReady; quotePreview = d.quote.text ?? ""
    phase = .ready
 7. if !d.quoteReady { startBodyObservation(threadId: threadId, messageId: messageId)
                       Task { [sync = env.sync] in try? await sync.ensureThreadLoaded(threadId: threadId) } }   // §4.4
```

`ComposeDraftBuilder.make` for `mode == .replyAll`:

```
r = ReplyAll.recipients(from: original.from,                       // Mailbox(name: fromName, addr: fromAddr)
                        replyTo: original.replyToList,
                        to: original.toList,
                        cc: original.ccList,
                        me: identity)                              // architecture §7.1, [mime-rfc §2.1, §8.1]
to = r.to ; cc = r.cc
subject     = SubjectPrefix.reply(original.subject)                // "Re: " unless already prefixed, [mime-rfc §8.2]
inReplyTo   = original.messageIdHeader                             // may be nil (Gmail sometimes omits Message-ID)
references  = MessageIDs.referencesChain(parentReferences: original.referencesList,
                                         parentInReplyTo: original.inReplyTo,
                                         parentMessageID: original.messageIdHeader)   // RFC 5322 §3.6.4
messageID   = MessageIDs.generate(domain: domain(ofEmail: identity.primary.addr), uuid: uuid)
attachments = []                                                   // replies never carry the original's parts
(quote, quoteReady) = quote(original:body:)
```

Edge cases:
- `original.messageIdHeader == nil` → `inReplyTo = nil` and `references` = the parent's own chain (possibly `[]`). `threadId` still keeps the reply in the Gmail thread (architecture D13).
- `original.subject == ""` → `SubjectPrefix.reply("")` = `"Re: "` (`[mime-rfc §8.2]`, trailing space kept — Gmail-web behaviour).
- `ReplyAll.recipients` never returns an empty `to` when the original has a `from` (last-resort rule, architecture §7.1); a message with an empty `fromAddr` and no `To`/`Cc` yields `to == []`, and `validation` then blocks Send.
- Self-reply (`from` ∈ `identity.allAddresses`) keeps the original `To`/`Cc` and ignores `Reply-To` (`[mime-rfc §8.1]` rows 9, 10, 14).

### 4.3 `makeDraft()` — forward (architecture §7.2, §7.6)

`ComposeDraftBuilder.make` for `mode == .forward` differs from §4.2 in exactly four lines:

```
to = [] ; cc = []                                                  // the user types them
subject = SubjectPrefix.forward(original.subject)                  // "Fwd: " unless already prefixed
// inReplyTo / references / threadId identical to the reply case — Gmail-web behaviour [mime-rfc §1.5, §7.3; D24]
attachments = attachments(records)                                 // see below
```

```
attachments(records) =
    records.map { r in
        ComposeAttachmentItem(
            ref: ForwardAttachmentRef(partId: r.partId, filename: r.filename, mimeType: r.mimeType,
                                      size: r.size, attachmentId: r.attachmentId),
            isInline: r.isInline,
            included: !r.isInline)                                  // non-inline pre-selected (§7.2);
    }                                                               // inline listed but off (§7.6, §14 #21)
```

Edge cases:
- The original was never opened (`bodyState == 0`): there are **no** `attachment` rows yet, so the section starts empty. When the body arrives (§4.4) the model re-reads the attachment rows in the same observation tick and fills the section — the user sees the attachments appear together with the quote.
- `attachmentId == nil` (bytes were delivered inline in `messages.get`): the ref still travels; 07 re-resolves the id through `messages.get?format=full` at drain time (architecture §7.6, §14 #13).
- Filenames are never rewritten here; RFC 2231 encoding happens in `MIMEBuilder` (02).

### 4.4 Quote snapshot and the `quoteReady` gate (architecture §7.2)

```
quote(original, body) -> (QuoteSource, Bool):
    html = body.map { QuoteExtractor.quotable($0.bodyHtml) }        // data-src → src, placeholder removed,
                                                                    // mm-* classes removed, cid <img> REMOVED (08 §4.5)
    html = (html?.isEmpty == true) ? nil : html
    text = body?.bodyText
        ?? html.map(Quoting.textFromHTML)
        ?? original.snippet                                          // bodyState == 2 → snippet (architecture §7.2)
    q = QuoteSource(author: original.from,
                    date: Date(timeIntervalSince1970: Double(original.internalDate) / 1000),
                    subject: original.subject,
                    to: original.toList, cc: original.ccList,
                    html: html, text: text)
    ready = (body != nil) || original.bodyState == 2
    return (q, ready)
```

While `ready == false` the sheet is fully editable, the quote section shows "Loading original…" and **Send is disabled** (`canSend`). The observation that resolves it:

```
startBodyObservation(threadId, messageId):
    obs = ValueObservation.tracking { db in try Queries.threadDetail(db, threadId: threadId) }
    bodyCancellable = obs.start(in: env.db, scheduling: .immediate,
        onError: { e in Log.ui.error("compose body observation: \(e)"); self.quoteReadyFallback() },
        onChange: { detail in
            guard let original = detail?.messages.first(where: { $0.id == messageId }) else { return }
            let (q, ready) = ComposeDraftBuilder.quote(original: original, body: detail?.bodies[messageId])
            guard ready else { return }                               // still loading → keep waiting
            self.draft?.quote = q
            self.quotePreview = q.text ?? ""
            if self.mode == .forward, self.attachments.isEmpty {
                self.attachments = ComposeDraftBuilder.attachments(
                    (detail?.attachments ?? []).filter { $0.messageId == messageId })
            }
            self.quoteReady = true
            self.stop()                                               // snapshot frozen — architecture §7.2
        })
```

- The snapshot is taken **once**: after `quoteReady` flips, the observation is cancelled, so a later body re-fetch, a sanitizer-version bump or a `Maintenance` eviction cannot change the quote under the user's fingers. This is also why `SendJob.quoteSource` is what 07 uses at drain time — "a cache wipe between compose and send cannot break the quote" (architecture §7.2).
- `quoteReadyFallback()` (observation error, e.g. the database was replaced by a sign-out wipe): keeps the provisional snippet snapshot, sets `quoteReady = true` and logs at `.error`, so the user is never stuck with a permanently disabled Send.
- `ensureThreadLoaded` is called at most once per sheet and only when `!quoteReady`; the engine dedupes it per thread (architecture §4.5), so opening compose from a thread screen that is already fetching costs nothing. Its `throws` is swallowed (`try?`): a transient failure leaves Send disabled until the next thread open, which is the same outcome the thread screen shows.
- Timing: for a thread whose body is cached (the normal path — compose is reached from the thread screen, which fetched it) `quoteReady` is `true` when `makeDraft()` returns and no observation is ever started.

### 4.5 Reopening a failed send (architecture §4.8)

`ComposeInput.failedSend(outboxId:job:)` is produced by 09 `InboxModel.openFailedSend(_:)` from an `outbox` row with `kind == .send`, `state == .failed`. `init` restores every field from `job` (§4.1); **no** database read, **no** identity read, `quoteReady = true` — the job already carries the snapshot, so a stale or evicted cache is irrelevant.

The re-send (§4.8) keeps `job.messageID`, `job.inReplyTo`, `job.references`, `job.threadId`, `job.originalMessageId` and `job.quoteSource` and replaces only what the user edited (`to`, `cc`, `subject`, `typedText`, `attachments`). Rationale for reusing the `Message-ID`: the old row may have reached `transmitState == maybeSent` before failing, and a duplicate that carries the same `Message-ID` is threaded and de-duplicated by receiving clients; a later retry of the *new* row also finds the old delivery through the `rfc822msgid:` check of architecture §7.7. The residual duplicate risk is the one already accepted in architecture §14 #9/#25 (§10 A1).

### 4.6 Address fields and validation

`display(_:)` / `text(for:)` produce the editable text; `parse(_:)` reads it back with `AddressParser.parseList` (RFC 5322 §3.4 tokenizer: quoted strings, comments, groups flattened, obs-route dropped, encoded words decoded, null members dropped — 02 §3.7).

```
parse(text):
    let all = AddressParser.parseList(text)
    return (all.filter { isValidAddrSpec($0.addr) },
            all.filter { !isValidAddrSpec($0.addr) }.map(\.addr))

isValidAddrSpec(addr):
    no character of addr is whitespace/newline                                   → else false
    no character of addr is in "<>,;:\"\\[]()"                                   → else false
    addr.split(separator: "@", omittingEmptySubsequences: false).count == 2      → else false
    local  = parts[0]; domain = parts[1]
    !local.isEmpty && !domain.isEmpty                                            → else false
    !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("..")    → else false
    true
```

A dotless domain is accepted on purpose (Workspace intranet hosts); no MX or DNS check, no length limit beyond what the user can type.

```
validation:
    let t = parse(toText)
    if !t.invalid.isEmpty                       → "Not a valid address: \(t.invalid[0])"
    if t.mailboxes.isEmpty                      → "Add at least one recipient."
    let c = parse(ccText)
    if !c.invalid.isEmpty                       → "Not a valid address: \(c.invalid[0])"
    otherwise                                   → nil
```

The message is recomputed on every keystroke (two `parseList` calls over strings of at most a few hundred characters — well under one frame) and rendered as the footer of the recipients section (§6.3). `validation` never mentions attachments; the budget lives in `attachmentFooter`.

### 4.7 Attachments and the 20 MB budget (architecture §7.6)

```
attachmentBytes  = attachments.filter(\.included).reduce(0) { $0 + $1.ref.size }
overBudget       = attachmentBytes > ComposeModel.maxAttachmentBytes            // 20_000_000

attachmentFooter:
    attachments.isEmpty                      → nil
    overBudget                               → "Attachments are \(Formatters.bytes(attachmentBytes)) — the limit is \(Formatters.bytes(maxAttachmentBytes)). Turn some off to send."
    else                                     → "\(n) attachment\(n == 1 ? "" : "s") · \(Formatters.bytes(attachmentBytes))"   // n = included count
    (n == 0 and rows exist)                  → "No attachments included"

setAttachment(partId:included:):
    guard let i = attachments.firstIndex(where: { $0.id == partId }) else { return }
    attachments[i].included = included
```

`canSend` is false while `overBudget` — architecture §7.6 requires Compose to disable Send above the budget so the job never reaches the outbox only to fail there. 07 still enforces the same limit at drain time (defence in depth, and the only place that knows the real byte counts).

Sizes come from `attachment.size`, which is Gmail's `body.size` for the part (base64-decoded byte count, `[gmail-api §6]`); 07 logs a mismatch against the fetched bytes but continues (architecture §7.6).

### 4.8 Send (architecture §8.2, §4.8, §7.7)

```
makeJob() -> SendJob?:
    guard canSend, let d = draft else { return nil }
    SendJob(mode: d.mode,
            originalMessageId: d.originalMessageId,
            threadId: d.threadId,
            messageID: d.messageID,                                   // frozen at prefill / inherited from the old job
            to: ComposeAddressField.parse(toText).mailboxes,
            cc: ComposeAddressField.parse(ccText).mailboxes,
            subject: subject,
            typedText: body,
            inReplyTo: d.inReplyTo,
            references: d.references,
            quoteSource: d.quote,                                      // the frozen snapshot
            attachments: attachments.filter(\.included).map(\.ref),
            includeSignature: includeSignature)

send() -> Bool:
 1. guard let job = makeJob() else { return false }                    // covers canSend == false
 2. isSending = true; sendFeedbackId += 1
 3. let actions = env.actions; let outbox = env.outbox
    let old: Int64? = if case .failedSend(let id, _) = input { id } else { nil }
 4. Task { await actions.send(job)                                     // 07: one write { enqueueSend } + beginBackgroundTask + drain
            if let old { await outbox.discardSend(id: old) } }         // delete the row we re-edited
 5. stop()                                                             // no more observation ticks into a dying model
 6. return true                                                        // the screen calls dismiss() right after
```

Notes:
- The `Task` captures only `actions`, `outbox` and `job` (all `Sendable` values) — never `self` — so the send survives the model's deallocation when the sheet dismisses in the same turn.
- Order in step 4: the **new** job is enqueued first, the old `failed` row is deleted second. A `failed` send row is never claimed by `Outbox.claimSend` (it claims `pending` rows that are due), so the overlap can not produce a second transmission; a crash between the two awaits leaves a harmless orphan row in the Outbox section, which the user can delete (and `Maintenance` removes after 30 days, architecture §4.9).
- `MailActions.send` is awaited inside the task only; the UI never waits (architecture §8.2 "never blocks on network").
- Everything after enqueue — style, signature, quoting, MIME, base64url, the POST, retries, the `rfc822msgid:` idempotency check — is 07/02 (architecture §7.3–§7.7). This module writes no MIME.

### 4.9 Cancel

```
hasContent:
    if case .failedSend = input { return true }                         // re-editing an existing draft
    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    if let d = draft {
        if toText != ComposeAddressField.text(for: d.to) { return true }
        if ccText != ComposeAddressField.text(for: d.cc) { return true }
        if subject != d.subject { return true }
        if attachments != d.attachments { return true }
    }
    return false
```

The screen's Cancel button: `hasContent == false` → `dismiss()` immediately; otherwise present the confirmation dialog of §6.6 ("Discard Draft" destructive / "Keep Editing"). Discarding a `.failedSend` reopen leaves the failed outbox row untouched — it is still listed in 09's Outbox section with Retry / Delete.

### 4.10 Concurrency and isolation

| Element | Isolation | Why |
|---|---|---|
| `ComposeModel`, `ComposeScreen` and its private views | `@MainActor` (implicit, app default `[ios-platform §5.6]`) | pure UI state; observation callbacks are delivered on main by `scheduling: .immediate` |
| `ComposePhase`, `ComposeAttachmentItem`, `ComposeAddressField`, `ComposeDraftBuilder`, `ComposeDraftBuilder.Draft` | `nonisolated`, `Sendable` | evaluated inside GRDB `@Sendable` fetch closures and passed to actors |
| `env.db.read { … }` | GRDB reader pool, off main | one async read per sheet; the model never blocks main on SQL |
| `env.identitySource.current()` | `@MainActor` (07 D12), performs its own `db.read` | one await before the detail read |
| `MailActions.send`, `Outbox.discardSend`, `SyncEngine.ensureThreadLoaded` | actor hops from an unstructured `Task` | fire-and-forget; no result is rendered |

No `@Sendable` closure in this module captures `self`; the observation's `onChange` runs on the main actor and mutates the model directly (same pattern as 09 §4.3).

### 4.11 Performance (architecture §12.1, §12.3)

- Sheet presentation → fields visible: **one** `db.read` of `Queries.threadDetail` for the open thread (indexed by `message_thread_date`) plus one `syncState` read inside `identitySource.current()`. Budget < 30 ms on an iPhone 12-class device; no network, no sanitizing, no MIME building, no image decoding.
- No second `WKWebView` is created (architecture D12) — the pooled instance stays with the thread screen underneath the sheet.
- The body observation exists only in the rare "body not cached yet" case and cancels itself after the first usable tick.
- Typing costs: `validation` runs two `AddressParser.parseList` calls per keystroke; `attachmentBytes` is a sum over ≤ a handful of rows. No formatting, no date math, no regex in `body`.

### 4.12 Error handling — exact cases

| Situation | Detection | Effect |
|---|---|---|
| Thread row missing / message not in `ThreadDetail.messages` (deleted, hidden, evicted) | step 4 of §4.2 | `phase = .unavailable("This message is no longer available.")`, `Log.ui.notice`, Send hidden, Cancel dismisses without a dialog |
| `env.db.read` throws (database replaced by a sign-out wipe, I/O error) | `try?` returns `nil` | same as above; `Log.ui.error` with the error description |
| Body observation fails to start or errors | `onError` | `quoteReadyFallback()` — snippet snapshot, `quoteReady = true`, `Log.ui.error` |
| `ensureThreadLoaded` throws (`GmailError.offline`, `.notFound`, `.unauthorized`, …) | `try?` | ignored; the quote stays at the snippet snapshot and `quoteReady` flips only if the body eventually lands. The user may still Cancel; Send stays disabled |
| Recipients empty or malformed | `validation` | text under To, Send disabled |
| Attachments over 20 MB | `attachmentFooter` + `canSend` | footer sentence, Send disabled (architecture §7.6) |
| `send()` while `canSend == false` (double tap, race with a keystroke) | `makeJob()` returns `nil` | returns `false`, nothing enqueued, the sheet stays |
| `MailActions.send` cannot write the outbox row (disk full) | 07 logs `Log.outbox.error` | the sheet is already dismissed; nothing is shown here (architecture §4.8 "never a blocking alert"). The mail is lost — same contract as every other enqueue in the app |

No error in this module throws to the caller and none presents an alert.

---

## 5. Data

### 5.1 No schema, no defaults, no files

This module creates no table, writes no `UserDefaults` key, touches no file cache and adds no `Info.plist` entry. Its only persistent effect is **one `outbox` row** written by `MailActions.send` (07 §5), plus the deletion of the re-edited row for a `.failedSend` resend.

### 5.2 `SendJob` written for a reply-all (exact shape)

`OutboxRepository.enqueueSend` stores `JSONEncoder(.sortedKeys)` of `SendJob` in `outbox.sendJob`, `rfc822MessageId = job.messageID`, `transmitState = 'notSent'` (06 §3.8, 07 §5). Example produced by this module (whitespace added for reading):

```json
{
  "attachments": [],
  "cc": [{"addr": "carol@partner.example"}],
  "includeSignature": true,
  "inReplyTo": "<CAF=abc123@mail.gmail.com>",
  "messageID": "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>",
  "mode": "replyAll",
  "originalMessageId": "18c2f1a9b3d4e5f6",
  "quoteSource": {
    "cc": [{"addr": "carol@partner.example"}],
    "date": 810000000.0,
    "html": "<div dir=\"ltr\">Hallo Max,<div><br></div><div>ist das Angebot noch aktuell?</div></div>",
    "subject": "Angebot",
    "text": "Hallo Max,\n\nist das Angebot noch aktuell?",
    "to": [{"addr": "max.mustermann@example.com", "name": "Max"}, {"addr": "bob@example.com", "name": "Bob"}]
  },
  "references": ["<CAF=root@mail.gmail.com>", "<CAF=abc123@mail.gmail.com>"],
  "subject": "Re: Angebot",
  "threadId": "18c2f1a9b3d4e5f6",
  "to": [{"addr": "alice@example.com", "name": "Alice"}, {"addr": "bob@example.com", "name": "Bob"}],
  "typedText": "Ja, das Angebot gilt bis Ende des Monats.\n\nViele Grüße\nMax"
}
```

Field origins: `quoteSource.date` is `Date` encoded by `JSONEncoder`'s default strategy (seconds since 2001-01-01, 06 owns the coder configuration); `quoteSource.author` is omitted above because the encoder drops `nil` optionals; `mode` / `subject` / `references` come from §4.2; `typedText` is the `TextEditor` content verbatim, with `\n` line breaks and no trailing normalisation.

A `.forward` job differs only in `"mode": "forward"`, `"subject": "Fwd: …"`, an empty `"cc"`, a user-typed `"to"` and a non-empty `"attachments"`:

```json
"attachments": [
  {"attachmentId": "ANGjdJ_7x…", "filename": "Angebot.pdf", "mimeType": "application/pdf", "partId": "2", "size": 184213}
]
```

### 5.3 Constants and strings

| Symbol / string | Value | Where |
|---|---|---|
| `ComposeModel.maxAttachmentBytes` | `Outbox.maxForwardAttachmentBytes` = `20_000_000` | §4.7 |
| navigation title | `"Reply All"` / `"Forward"` | §6.2 |
| To / Cc / Subject placeholders | `"To"`, `"Cc"`, `"Subject"` | §6.3 |
| empty-recipients validation | `"Add at least one recipient."` | §4.6 |
| invalid-address validation | `"Not a valid address: <token>"` | §4.6 |
| over-budget footer | `"Attachments are 21.4 MB — the limit is 20 MB. Turn some off to send."` | §4.7 |
| included footer | `"2 attachments · 4.2 MB"`, `"1 attachment · 184 KB"`, `"No attachments included"` | §4.7 |
| quote section header | `"Quoted"` | §6.5 |
| quote loading text | `"Loading original…"` | §6.5 |
| unavailable title / body | `"Message unavailable"` / `"This message is no longer available."` | §6.4 |
| discard dialog | `"Discard this draft?"` · `"Discard Draft"` · `"Keep Editing"` | §6.6 |
| attachments section header | `"Attachments"` | §6.4 |

All strings are English literals (architecture §16: no localisation in stage 1). `…` is U+2026, `—` is U+2014, `·` is U+00B7.

---

## 6. UI

### 6.1 View hierarchy

```
ComposeScreen                                        @State model: ComposeModel?
                                                     @State showsDiscard = false
                                                     @FocusState focus: ComposeField?
                                                     @Environment(AppEnvironment.self) env
                                                     @Environment(\.dismiss) dismiss
                                                     @ThemeTokensReader themeTokens
└─ NavigationStack
   └─ Group {
        switch model?.phase {
        case .none, .some(.loading): ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                                                   .accessibilityIdentifier("compose.loading")
        case .some(.unavailable(let t)): ComposeUnavailableView(text: t)
        case .some(.ready):
            Form {
              ComposeFieldsSection(model:, focus: $focus)                        (§6.3)
              Section { TextEditor(text: $model.body).frame(minHeight: 200)
                          .focused($focus, equals: .body)
                          .accessibilityIdentifier("compose.body")
                          .accessibilityLabel("Message body") }
              if !model.attachments.isEmpty { ComposeAttachmentsSection(model:) } (§6.4)
              ComposeQuoteSection(model:)                                        (§6.5)
            }
            .scrollDismissesKeyboard(.interactively)
        }
      }
      .background(themeTokens.groupedBackground)
      .navigationTitle(model?.title ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { cancelButton ; sendButton }                                     (§6.2)
      .confirmationDialog(…, isPresented: $showsDiscard) { … }                   (§6.6)
      .sensoryFeedback(.success, trigger: model?.sendFeedbackId ?? 0)
   .onAppear { if model == nil { model = ComposeModel(env: env, input: input) } }
   .task      { await model?.makeDraft() }
   .onDisappear { model?.stop() }
   .interactiveDismissDisabled(model?.hasContent ?? false)
```

The sheet inherits `AppEnvironment`, `ThemeStore` and `SettingsStore` from the presenting window (09 §4.8). The whole screen is one `Form` — no custom scroll view, no height measurement, no web view (architecture §8.5, D12).

### 6.2 Toolbar

```swift
ToolbarItem(placement: .cancellationAction) {
    Button("Cancel") { if model?.hasContent == true { showsDiscard = true } else { dismiss() } }
        .accessibilityIdentifier("compose.cancel")
}
ToolbarItem(placement: .confirmationAction) {
    Button { if model?.send() == true { dismiss() } } label: { Image(systemName: "paperplane.fill") }
        .disabled(!(model?.canSend ?? false))
        .accessibilityLabel("Send")
        .accessibilityIdentifier("compose.send")
}
```

SF Symbols: `paperplane.fill` (Send, architecture §8.3). Cancel is a text button (iOS Mail convention). Send is `.confirmationAction`, so it sits trailing and is bold.

### 6.3 Recipients section

```swift
Section {
    TextField("To", text: $model.toText, axis: .vertical)
        .textContentType(.emailAddress).keyboardType(.emailAddress)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused(focus, equals: .to)
        .accessibilityIdentifier("compose.to").accessibilityLabel("To")
    TextField("Cc", text: $model.ccText, axis: .vertical)
        …same modifiers…
        .focused(focus, equals: .cc)
        .accessibilityIdentifier("compose.cc").accessibilityLabel("Cc")
    TextField("Subject", text: $model.subject)
        .focused(focus, equals: .subject)
        .accessibilityIdentifier("compose.subject").accessibilityLabel("Subject")
} footer: {
    if let v = model.validation {
        Text(v).font(.footnote).foregroundStyle(themeTokens.secondaryText)
            .accessibilityIdentifier("compose.validation")
    }
}
```

The validation footer uses `themeTokens.secondaryText`: `ThemeTokens` (architecture §10) has no error colour and adding one belongs to module 01 (§10 A8). The disabled Send button is the primary affordance.

### 6.4 Attachments section and the unavailable state

```swift
// ComposeAttachmentsSection
Section("Attachments") {
    ForEach(model.attachments) { item in
        Toggle(isOn: Binding(get: { item.included },
                             set: { model.setAttachment(partId: item.id, included: $0) })) {
            HStack(spacing: 8) {
                Image(systemName: item.isInline ? "photo" : "paperclip")
                    .foregroundStyle(themeTokens.secondaryText).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.ref.filename.isEmpty ? "Attachment" : item.ref.filename)
                        .font(.subheadline).lineLimit(1).foregroundStyle(themeTokens.text)
                    Text(item.sizeLabel).font(.caption).foregroundStyle(themeTokens.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("compose.attachment.\(item.id)")
        .accessibilityLabel("\(item.ref.filename), \(item.sizeLabel)\(item.isInline ? ", inline image" : "")")
    }
} footer: {
    if let f = model.attachmentFooter {
        Text(f).font(.footnote).foregroundStyle(themeTokens.secondaryText)
            .accessibilityIdentifier("compose.attachmentFooter")
    }
}

// ComposeUnavailableView
ContentUnavailableView("Message unavailable", systemImage: "exclamationmark.triangle",
                       description: Text(text))
    .accessibilityIdentifier("compose.unavailable")
```

### 6.5 Quoted-original section

```swift
Section("Quoted") {
    if model.quoteReady {
        Text(model.quotePreview.isEmpty ? "(No quoted text)" : model.quotePreview)
            .font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(12)
            .textSelection(.enabled)
            .accessibilityIdentifier("compose.quote")
            .accessibilityLabel("Quoted original")
    } else {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading original…").font(.footnote).foregroundStyle(themeTokens.secondaryText)
        }
        .accessibilityIdentifier("compose.quoteLoading")
    }
}
```

Read-only by construction (`Text`, architecture §8.5). The full quote is always sent, no matter how many lines the preview shows (`lineLimit(12)` is display only).

### 6.6 Discard confirmation

```swift
.confirmationDialog("Discard this draft?", isPresented: $showsDiscard, titleVisibility: .visible) {
    Button("Discard Draft", role: .destructive) { dismiss() }
    Button("Keep Editing", role: .cancel) { }
}
```

`.interactiveDismissDisabled(model.hasContent)` makes the swipe-down gesture go through the same question instead of silently dropping the draft.

### 6.7 Focus and keyboard

| Case | First responder on appear |
|---|---|
| `.fromMessage(mode: .replyAll, …)` | `.body` — recipients are prefilled, the user types the reply |
| `.fromMessage(mode: .forward, …)` | `.to` — the forward has no recipients yet |
| `.failedSend` | `.body` — everything is prefilled, the user is fixing the mail |

Set once, in `makeDraft()`'s completion via `focus = …` on the screen (`.onChange(of: model.phase)`), never re-applied. `TextEditor` uses the system body font and `themeTokens.text`; the draft's `ComposeStyle` (family/size/colour) is **not** applied to the editor — a black `#000000` compose colour would be unreadable on a dark background, and the style is an outgoing-HTML concern applied by `OutgoingBodies` at build time (architecture §7.5; §10 A5).

### 6.8 User action → effect

| Action | Effect |
|---|---|
| type in To / Cc | `validation` recomputed, Send enables/disables |
| type in Subject / body | `hasContent` becomes true; no other effect |
| toggle an attachment | `setAttachment`, footer + `canSend` recomputed |
| tap Send | `model.send()` → `MailActions.send(job)` (+ `Outbox.discardSend` for a reopen) → `dismiss()`; success haptic |
| tap Cancel with content | discard dialog; "Discard Draft" → `dismiss()`, "Keep Editing" → nothing |
| tap Cancel without content | `dismiss()` |
| swipe the sheet down with content | same dialog (`.interactiveDismissDisabled`) |
| body arrives while composing | quote preview fills in, forward attachments appear, Send enables |
| original disappears while composing | nothing (the snapshot is frozen; `phase` is not downgraded after `.ready`) |

### 6.9 Appearance, Dynamic Type, haptics

- Colours only through `ThemeTokensReader`; `RootView` applies `.preferredColorScheme` and `.tint`, so Light / Dark / System need no branch here (architecture §10, `make lint` greps raw colours in `minimail/Features`).
- Fonts: system text styles only (`.body` for the fields and the editor, `.footnote` for footers and the quote, `.caption` for sizes). No fixed point size; Dynamic Type reflows the `Form`.
- Haptics: `.sensoryFeedback(.success, trigger: model.sendFeedbackId)` on send enqueue (architecture §8.3). No other haptic in this module — attachment toggles use the system switch feedback.
- No animation is added beyond the sheet presentation and the `Form`'s default row insertion.

---

## 7. Tests

Both files are **app tests** (`XCTest`, simulator, `xcodebuild test`); this module adds no `MailCore` package test — every pure algorithm it uses (`ReplyAll`, `SubjectPrefix`, `MessageIDs`, `Quoting`, `AddressParser`) is already covered by 02's `swift test` suite, and `QuoteExtractor` by 08's `MailHTMLTests`.

**Shared setup** (both files), following 09 §7:

```swift
var env: AppEnvironment!            // AppEnvironment(testing: true): temporary pool (06), offline stub (05 D8),
                                    // auth .signedOut, isolated UserDefaults suite
var model: ComposeModel!
let seedNow: Int64 = 1_757_500_000_000                 // 2025-09-10 10:26:40 UTC
let fixedUUID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

override func setUp() async throws {
    env = AppEnvironment(testing: true)
    try await env.db.write { db in
        try SyncStateRepository.set(db, .accountEmail, "max.mustermann@example.com")
        try SyncStateRepository.set(db, .displayName, "Max Mustermann")
        try SyncStateRepository.set(db, .selfAddresses,
            #"["m.mustermann@example.com","max.mustermann@example.com"]"#)
    }
}
override func tearDown() async throws { model?.stop(); model = nil; env = nil }

/// Polls every 20 ms until `cond()` or `timeout`; XCTFail on timeout (09 §7).
func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async
```

**Fixtures** — no new files; the tests build their rows with the module-06 helpers:

| Helper | Use here |
|---|---|
| `TestDatabase.parsed(id:threadId:internalDate:labels:from:to:cc:subject:snippet:messageID:inReplyTo:references:)` | the original message `m1` in thread `t1` |
| `TestDatabase.seed(_:_:selfAddresses:generation:now:)` | writes it through `upsertMetadata` + `recomputeAggregates` |
| `BodyRepository.storeBody(_:messageId:body:text:attachments:referenced:sanitizerVersion:now:)` | body row + `attachment` rows |
| `SanitizedBody(html:hasRemoteImages:darkStrategy:referencedContentIDs:)` | the sanitized fragment used for the quote |
| `ParsedAttachment(partId:filename:mimeType:size:contentId:attachmentId:inlineData:)` | forward attachment rows |
| `OutboxRepository.enqueueSend` + `OutboxRepository.fail` | the failed row behind a `.failedSend` input |
| `InvariantChecks.assertAll(env.db)` | after every test that enqueues a send |

`seedOriginal()` used by most tests (helper inside `ComposeModelTests`):

```swift
// m1 in t1: From Alice; To Max (self) + Bob; Cc Carol; Subject "Angebot";
// Message-ID <CAF=abc123@mail.gmail.com>; In-Reply-To <CAF=root@mail.gmail.com>; References [<CAF=root@mail.gmail.com>]
// body: SanitizedBody(html: "<div class=\"mm-plaintext\"><div>Hallo Max,</div></div>"
//                            + "<img data-src=\"https://t.example/p.gif\" src=\"<placeholderGIF>\" class=\"mm-remote\">"
//                            + "<img src=\"minimail-cid://m1/ii_logo\">",
//                     hasRemoteImages: true, darkStrategy: .plain, referencedContentIDs: ["ii_logo"])
// bodyText: "Hallo Max,\n\nist das Angebot noch aktuell?"
// attachments: partId "2" Angebot.pdf application/pdf 184213 (attachmentId "att2"),
//              partId "3" logo.png image/png 4096 contentId "ii_logo" (inline)
```

### 7.1 `minimailTests/Compose/ComposeModelTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testReplyAllPrefill` | `seedOriginal()`; `model = ComposeModel(env:, input: .fromMessage(mode: .replyAll, threadId: "t1", messageId: "m1"), uuid: { fixedUUID })`; `await model.makeDraft()` | `phase == .ready`; `toText == "Alice <alice@example.com>, Bob <bob@example.com>"`; `ccText == "carol@partner.example"`; `subject == "Re: Angebot"`; `model.title == "Reply All"`; `attachments.isEmpty`; `quoteReady`; `canSend` |
| `testReplyAllThreadingHeaders` | as above | `makeJob()!.inReplyTo == "<CAF=abc123@mail.gmail.com>"`; `makeJob()!.references == ["<CAF=root@mail.gmail.com>", "<CAF=abc123@mail.gmail.com>"]`; `makeJob()!.threadId == "t1"`; `makeJob()!.originalMessageId == "m1"` |
| `testMessageIDIsFrozenAndUsesAccountDomain` | as above | `makeJob()!.messageID == "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>"`; after `model.body = "x"` a second `makeJob()!.messageID` is the same string |
| `testSelfReplyKeepsOriginalRecipients` | original with `from: Mailbox(name: "Max", addr: "max.mustermann@example.com")`, `to: [alice, bob]`, `cc: [carol]`, `replyTo: [list@example.com]` (seeded through `parsed(…)`) | `toText == "Alice <alice@example.com>, Bob <bob@example.com>"`; `ccText == "carol@partner.example"` (Reply-To ignored — `[mime-rfc §8.1]` rows 9/10) |
| `testSubjectPrefixNotDoubled` | original subject `"Re: Angebot"` | reply → `subject == "Re: Angebot"`; a second model with `.forward` → `subject == "Fwd: Re: Angebot"` |
| `testForwardPrefill` | `seedOriginal()`; `.fromMessage(mode: .forward, …)` | `toText == ""`; `ccText == ""`; `subject == "Fwd: Angebot"`; `title == "Forward"`; `attachments.map(\.id) == ["2", "3"]`; `attachments[0].included == true`; `attachments[1].isInline == true && attachments[1].included == false`; `makeJob() == nil` (no recipients); `validation == "Add at least one recipient."` |
| `testForwardKeepsThreadingHeaders` | as above; `model.toText = "bob@example.com"` | `makeJob()!.inReplyTo == "<CAF=abc123@mail.gmail.com>"`; `references` as in `testReplyAllThreadingHeaders`; `threadId == "t1"` (architecture D24) |
| `testQuoteSnapshotStripsRemoteAndCIDImages` | `seedOriginal()`; reply model loaded | `makeJob()!.quoteSource.html!.contains("https://t.example/p.gif")` (the `data-src` was restored); `!html.contains("minimail-cid:")`; `!html.contains("mm-plaintext")`; `!html.contains("mm-remote")`; `quoteSource.text == "Hallo Max,\n\nist das Angebot noch aktuell?"`; `quoteSource.subject == "Angebot"`; `quoteSource.author == Mailbox(name: "Alice", addr: "alice@example.com")`; `quoteSource.date == Date(timeIntervalSince1970: Double(seedNow) / 1000)` |
| `testQuotePreviewIsQuoteText` | as above | `quotePreview == "Hallo Max,\n\nist das Angebot noch aktuell?"` |
| `testQuoteWaitsForBodyThenEnables` | seed `m1` **without** `storeBody` (`bodyState == 0`); reply model; `await model.makeDraft()` | immediately: `phase == .ready`, `quoteReady == false`, `canSend == false`, `quotePreview == ""`; then `try await env.db.write { try BodyRepository.storeBody($0, messageId: "m1", body: sanitized, text: "Hallo Max,", attachments: [], referenced: [], sanitizerVersion: 1, now: seedNow) }`; `await waitUntil { model.quoteReady }`; `canSend == true`; `makeJob()!.quoteSource.text == "Hallo Max,"` |
| `testForwardAttachmentsAppearWithLateBody` | seed `m1` without body; forward model; `model.toText = "bob@example.com"` | `attachments.isEmpty`; then `storeBody` with the two parsed attachments and `referenced: ["ii_logo"]`; `await waitUntil { model.attachments.count == 2 }`; `attachments[0].included == true`; `attachments[1].isInline == true` |
| `testBodyUnavailableUsesSnippet` | seed `m1` with `snippet: "Kurzfassung"`, then `try await env.db.write { try BodyRepository.markUnavailable($0, messageId: "m1") }`; reply model | `quoteReady == true` right after `makeDraft()`; `makeJob()!.quoteSource.html == nil`; `.text == "Kurzfassung"`; `canSend == true` |
| `testSnapshotFrozenAfterReady` | `seedOriginal()`; reply model loaded; `let h = model.makeJob()!.quoteSource.html`; then overwrite the body with different HTML through `storeBody` | after 300 ms `model.makeJob()!.quoteSource.html == h` (the observation was cancelled — architecture §7.2) |
| `testUnknownMessageIsUnavailable` | `seedOriginal()`; `.fromMessage(mode: .replyAll, threadId: "t1", messageId: "nope")` | `phase == .unavailable("This message is no longer available.")`; `canSend == false`; `makeJob() == nil`; `hasContent == false` |
| `testUnknownThreadIsUnavailable` | no seed; `.fromMessage(mode: .replyAll, threadId: "tX", messageId: "m1")` | same three assertions |
| `testMakeDraftIsIdempotent` | `seedOriginal()`; reply model; `await model.makeDraft()`; `model.toText = "x@y.de"`; `await model.makeDraft()` | `toText == "x@y.de"` (the second call did not overwrite the user's edit) |
| `testValidationMatrix` | `seedOriginal()`; reply model | `toText = ""` → `validation == "Add at least one recipient."`, `!canSend`; `toText = "not-an-address"` → `"Not a valid address: not-an-address"`; `toText = "a@b.de"` → `nil`, `canSend`; `ccText = "x@"` → `"Not a valid address: x@"`, `!canSend`; `ccText = ""` → `nil` |
| `testAttachmentBudgetBlocksSend` | forward model with two refs of 12_000_000 and 9_000_000 (seeded through `storeBody`); `toText = "bob@example.com"` | `attachmentBytes == 21_000_000`; `canSend == false`; `attachmentFooter == "Attachments are 21 MB — the limit is 20 MB. Turn some off to send."` (exact string built with `Formatters.bytes`); `setAttachment(partId: "3", included: false)` → `canSend == true`, footer `"1 attachment · 12 MB"` |
| `testAttachmentTogglesReachTheJob` | `seedOriginal()`; forward model; `toText = "bob@example.com"` | `makeJob()!.attachments.map(\.partId) == ["2"]`; `setAttachment(partId: "3", included: true)` → `["2", "3"]`; `setAttachment(partId: "2", included: false)` → `["3"]`; `setAttachment(partId: "99", included: true)` changes nothing |
| `testIncludeSignatureFollowsSettings` | `env.settings.update { $0.signatureEnabled = false }` **before** creating the model; `seedOriginal()`; reply model; `toText` valid | `includeSignature == false`; `makeJob()!.includeSignature == false`; a second model created after `signatureEnabled = true` → `true` |
| `testSendEnqueuesOneOutboxRow` | `seedOriginal()`; reply model; `model.body = "Ja, passt."` | `model.send() == true`; `sendFeedbackId == 1`; `isSending == true`; `await waitUntil { (try? env.db.read { try Queries.outboxCounts($0).pending }) == 1 }`; the stored row has `kind == .send`, `transmitState == .notSent`, `rfc822MessageId == "<3F2504E0-…@example.com>"`, and `sendJob` decodes equal to `makeJob()` captured before the call; `try InvariantChecks.assertAll(env.db)` |
| `testSendRejectedWhenInvalid` | `seedOriginal()`; reply model; `model.toText = ""` | `model.send() == false`; `sendFeedbackId == 0`; after 300 ms `try env.db.read { try Queries.outboxCounts($0).pending } == 0` |
| `testSecondSendIsIgnored` | as `testSendEnqueuesOneOutboxRow` | `model.send() == true`; `model.send() == false` (`isSending` blocks it); exactly one row |
| `testFailedSendPrefillFromJob` | build `job` (reply-all, to `[Bob]`, cc `[]`, subject `"Re: Angebot"`, typedText `"Erste Fassung"`, `quoteSource.text "Hallo"`, one attachment ref, `includeSignature: false`); `let id = try await env.db.write { db -> Int64 in let i = try OutboxRepository.enqueueSend(db, job: job, now: seedNow); try OutboxRepository.fail(db, opId: i, error: "Invalid recipient"); return i }`; `model = ComposeModel(env:, input: .failedSend(outboxId: id, job: job))` | **without** calling `makeDraft()`: `phase == .ready`, `toText == "Bob <bob@example.com>"`, `subject == "Re: Angebot"`, `body == "Erste Fassung"`, `quoteReady`, `quotePreview == "Hallo"`, `attachments.count == 1 && attachments[0].included`, `includeSignature == false`, `hasContent == true`, `canSend == true`; `await model.makeDraft()` changes nothing |
| `testFailedSendResendKeepsIdentityAndDeletesOldRow` | as above; `model.body = "Zweite Fassung"`; `model.toText = "bob@example.com, carol@partner.example"` | `model.send() == true`; `await waitUntil { (try? env.db.read { try OutboxRecord.fetchOne($0, key: id) }) == nil }`; exactly one `outbox` row exists; its `sendJob` has `messageID == job.messageID`, `inReplyTo == job.inReplyTo`, `references == job.references`, `quoteSource == job.quoteSource`, `typedText == "Zweite Fassung"`, `to.count == 2`; `try InvariantChecks.assertAll(env.db)` |
| `testHasContentRules` | `seedOriginal()`; reply model loaded | `hasContent == false`; `model.body = "  \n "` → `false`; `model.body = "Hi"` → `true`; reset `body = ""`, `model.subject = "Anderes"` → `true`; reset subject, `model.toText += ", dave@example.com"` → `true` |
| `testStopCancelsBodyObservation` | seed `m1` without body; reply model; `await model.makeDraft()`; `model.stop()`; then `storeBody` | after 300 ms `model.quoteReady == false` (no tick after `stop`) |

29 tests.

### 7.2 `minimailTests/Compose/ComposeViewsTests.swift`

| Test function | Setup | Assertions |
|---|---|---|
| `testAddressFieldDisplay` | — | `display(Mailbox(name: nil, addr: "a@b.de")) == "a@b.de"`; `display(Mailbox(name: "  ", addr: "a@b.de")) == "a@b.de"`; `display(Mailbox(name: "Alice", addr: "a@b.de")) == "Alice <a@b.de>"`; `display(Mailbox(name: "Müller", addr: "a@b.de")) == "Müller <a@b.de>"` (no RFC 2047 — unlike `Mailbox.serialized()`); `display(Mailbox(name: "Müller, Alice", addr: "a@b.de")) == "\"Müller, Alice\" <a@b.de>"`; `display(Mailbox(name: "He said \"hi\"", addr: "a@b.de")) == "\"He said \\\"hi\\\"\" <a@b.de>"` |
| `testAddressFieldRoundTrip` | list `[Mailbox(name: "Müller, Alice", addr: "a@b.de"), Mailbox(name: nil, addr: "c@d.de"), Mailbox(name: "Bob", addr: "e@f.de")]` | `parse(text(for: list)).mailboxes.map(\.addr) == ["a@b.de", "c@d.de", "e@f.de"]`; `parse(...).mailboxes[0].name == "Müller, Alice"`; `parse(...).invalid.isEmpty` |
| `testAddressValidationMatrix` | — | `isValidAddrSpec` true for `"a@b.de"`, `"a.b+c@sub.example.co.uk"`, `"user@localhost"`; false for `""`, `"a"`, `"@b.de"`, `"a@"`, `"a@@b.de"`, `"a b@c.de"`, `"a@b..de"`, `"a@.de"`, `"a@de."`, `"<a@b.de>"`, `"a,b@c.de"` |
| `testParseSplitsAndFlags` | `parse("Alice <a@b.de>, junk, c@d.de")` | `mailboxes.map(\.addr) == ["a@b.de", "c@d.de"]`; `invalid == ["junk"]`; `parse("   ")` → `([], [])` |
| `testDraftBuilderReplyAll` | `MessageRecord` built inline (from Alice, to `[max, bob]`, cc `[carol]`, subject `"Angebot"`, ids as in §7.1) + `identity = SelfIdentity(primary: Mailbox(name: "Max Mustermann", addr: "max.mustermann@example.com"), allAddresses: ["max.mustermann@example.com", "m.mustermann@example.com"])` | `make(mode: .replyAll, …, uuid: fixedUUID)` returns `to == [alice, bob]`, `cc == [carol]`, `subject == "Re: Angebot"`, `messageID == "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>"`, `attachments.isEmpty`, `quoteReady == false` (body nil, `bodyState == 0`) |
| `testDraftBuilderForwardAttachments` | same record, `bodyState = 1`, a body row, three `AttachmentRecord`s (two normal, one `isInline`) | `make(mode: .forward, …)` → `to.isEmpty`, `subject == "Fwd: Angebot"`, `attachments.map(\.id) == ["1", "2", "3"]`, `attachments.map(\.included) == [true, true, false]`, `quoteReady == true` |
| `testDraftBuilderDomain` | — | `domain(ofEmail: "max.mustermann@example.com") == "example.com"`; `domain(ofEmail: "Max@example.com") == "example.com"`; `domain(ofEmail: "broken") == ""`; `MessageIDs.generate(domain: "", uuid: fixedUUID)` ends with `"@localhost>"` |
| `testAttachmentItemSizeLabel` | item with `size: 184_213` | `sizeLabel == Formatters.bytes(184_213)`; `size: 0` → `Formatters.bytes(0)` |
| `testComposeScreenHostsReplyAll` | `env = AppEnvironment(testing: true)`; seed `m1`/`t1` + body; `let vc = UIHostingController(rootView: ComposeScreen(input: .fromMessage(mode: .replyAll, threadId: "t1", messageId: "m1")).environment(env).environment(env.theme).environment(env.settings))`; frame 390×844; `layoutIfNeeded()`; `RunLoop.main.run(until: Date() + 0.3)` | no crash; `vc.view.subviews.isEmpty == false`; `env.deferredWorkStarted == false` |
| `testComposeScreenHostsFailedSend` | as above with `.failedSend(outboxId: 1, job: job)` | no crash; `vc.view.subviews.isEmpty == false` |
| `testComposeScreenHostsUnavailable` | `.fromMessage(mode: .forward, threadId: "tX", messageId: "mX")` on an empty database | no crash after 0.3 s of run loop (the `ContentUnavailableView` path renders) |
| `testPlaceholderStructRemoved` | — | `grep`-level guarantee is §9 item 5; here: `_ = ComposeScreen(input: .fromMessage(mode: .replyAll, threadId: "t", messageId: "m"))` compiles against `minimail/Features/Compose/ComposeScreen.swift` (the file's `#sourceLocation`-free existence is asserted by 09's `testPlaceholderSignatures` still passing) |

12 tests. Total for this module: 41.

### 7.3 Running them

```
make test-app                                      # whole app suite (01/04/05/06/07/08/09/10 + this module)
make test-one T=minimailTests/ComposeModelTests     # this module's model tests
make test-one T=minimailTests/ComposeViewsTests     # helpers + hosting smoke tests
make lint                                           # package boundary + raw-colour rule
```

`swift test` (Linux) is unaffected: this module adds no package source and no package test.

---

## 8. Tasks

- [ ] **T11.1 Value types and pure helpers** — files: `minimail/Features/Compose/ComposeModel.swift` (`ComposePhase`, `ComposeAttachmentItem`, `ComposeAddressField`), `minimailTests/Compose/ComposeViewsTests.swift` (`testAddressFieldDisplay`, `testAddressFieldRoundTrip`, `testAddressValidationMatrix`, `testParseSplitsAndFlags`, `testAttachmentItemSizeLabel`). Done when the five tests pass and `ComposeAddressField.parse(text(for: list))` round-trips the quoted/non-ASCII cases. Verify: `make test-one T=minimailTests/ComposeViewsTests`. (~150 lines)

- [ ] **T11.2 `ComposeDraftBuilder`** — files: `minimail/Features/Compose/ComposeModel.swift` (`ComposeDraftBuilder.make`, `.quote`, `.attachments`, `.domain`), `minimailTests/Compose/ComposeViewsTests.swift` (+`testDraftBuilderReplyAll`, `testDraftBuilderForwardAttachments`, `testDraftBuilderDomain`). Done when the prefill of §4.2/§4.3/§4.4 is reproduced from records alone, with an injected `UUID`, and the three tests pass. Verify: `make test-one T=minimailTests/ComposeViewsTests`. (~160 lines)

- [ ] **T11.3 `ComposeModel` — init, `makeDraft`, quote gating** — files: `minimail/Features/Compose/ComposeModel.swift` (`ComposeModel` stored state, `init`, `makeDraft`, `startBodyObservation`, `quoteReadyFallback`, `stop`), `minimailTests/Compose/ComposeModelTests.swift` (`testReplyAllPrefill`, `testReplyAllThreadingHeaders`, `testMessageIDIsFrozenAndUsesAccountDomain`, `testSelfReplyKeepsOriginalRecipients`, `testSubjectPrefixNotDoubled`, `testForwardPrefill`, `testForwardKeepsThreadingHeaders`, `testQuoteSnapshotStripsRemoteAndCIDImages`, `testQuotePreviewIsQuoteText`, `testQuoteWaitsForBodyThenEnables`, `testForwardAttachmentsAppearWithLateBody`, `testBodyUnavailableUsesSnippet`, `testSnapshotFrozenAfterReady`, `testUnknownMessageIsUnavailable`, `testUnknownThreadIsUnavailable`, `testMakeDraftIsIdempotent`, `testStopCancelsBodyObservation`). Done when all 17 pass. Verify: `make test-one T=minimailTests/ComposeModelTests`. (~260 lines)

- [ ] **T11.4 Validation, attachments, job construction, send** — files: `minimail/Features/Compose/ComposeModel.swift` (`validation`, `canSend`, `hasContent`, `attachmentBytes`, `attachmentFooter`, `setAttachment`, `makeJob`, `send`), `minimailTests/Compose/ComposeModelTests.swift` (+`testValidationMatrix`, `testAttachmentBudgetBlocksSend`, `testAttachmentTogglesReachTheJob`, `testIncludeSignatureFollowsSettings`, `testSendEnqueuesOneOutboxRow`, `testSendRejectedWhenInvalid`, `testSecondSendIsIgnored`, `testFailedSendPrefillFromJob`, `testFailedSendResendKeepsIdentityAndDeletesOldRow`, `testHasContentRules`). Done when all 10 pass and `InvariantChecks.assertAll` holds after every enqueue. Verify: `make test-one T=minimailTests/ComposeModelTests`. (~180 lines)

- [ ] **T11.5 `ComposeScreen` + placeholder removal** — files: `minimail/Features/Compose/ComposeScreen.swift` (screen, four private views, toolbar, dialog, focus, haptic), `minimail/Features/Inbox/InboxPlaceholders.swift` (delete `struct ComposeScreen`). Done when `make build` succeeds, 09's `testPlaceholderSignatures` and `testInboxScreenHostsSeededRows` still pass, and `grep -n "struct ComposeScreen" minimail/Features/Inbox/InboxPlaceholders.swift` prints nothing. Verify: `make build && make test-one T=minimailTests/InboxViewsTests`. (~230 lines)

- [ ] **T11.6 Hosting smoke tests and lint** — files: `minimailTests/Compose/ComposeViewsTests.swift` (+`testComposeScreenHostsReplyAll`, `testComposeScreenHostsFailedSend`, `testComposeScreenHostsUnavailable`, `testPlaceholderStructRemoved`). Done when the four tests pass and `make lint` is clean (no raw colour in `minimail/Features/Compose`, no forbidden import). Verify: `make test-one T=minimailTests/ComposeViewsTests && make lint`. (~120 lines)

---

## 9. Acceptance criteria

1. `make build` succeeds with `SWIFT_VERSION = 6` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, no new warnings. Verify: `make build`.
2. All 41 tests of §7 pass and the whole app suite stays green. Verify: `make test-app`, then `xcrun xcresulttool get test-results summary --path .build/results/unit.xcresult --compact` shows `failedTests: 0`.
3. Reply-all prefill matches `[mime-rfc §8.1]` for the seeded rows (self excluded in both spellings, Reply-To replacing From, self-reply keeping the original To/Cc) and the subject table of `[mime-rfc §8.2]`. Verify: `make test-one T=minimailTests/ComposeModelTests` (`testReplyAllPrefill`, `testSelfReplyKeepsOriginalRecipients`, `testSubjectPrefixNotDoubled`).
4. A `SendJob` written by this module decodes in 07 without loss: `rfc822MessageId` equals `sendJob.messageID`, `transmitState == 'notSent'`, `quoteSource` is the frozen snapshot. Verify: `testSendEnqueuesOneOutboxRow`.
5. The interim placeholder is gone and nothing else references it. Verify: `grep -rn "struct ComposeScreen" minimail | grep -v "minimail/Features/Compose/ComposeScreen.swift"` prints nothing.
6. No SQL text, no forbidden import, no raw colour in this module. Verify: `make lint` and `grep -rnE "SELECT|INSERT|UPDATE |DELETE FROM" minimail/Features/Compose` prints nothing.
7. Send is impossible without a valid recipient, with a still-loading quote, or above 20 MB of attachments. Verify: `testValidationMatrix`, `testQuoteWaitsForBodyThenEnables`, `testAttachmentBudgetBlocksSend`.
8. Re-sending a failed job deletes exactly the row it was opened from and keeps the original `Message-ID` and threading headers. Verify: `testFailedSendResendKeepsIdentityAndDeletesOldRow`.
9. No `WKWebView` is created by the compose sheet. Verify: `grep -rn "WKWebView\|WebViewHost\|MailWebView" minimail/Features/Compose` prints nothing.
10. Manual device step (added to `docs/plan/device-checklist.md` by module 14): on the owner's iPhone, open a thread → **Reply all** → the recipients are prefilled without the own address, the quoted original is visible, typing and tapping Send dismisses the sheet within one frame, the mail arrives in Gmail with the correct `In-Reply-To`, in the same thread, with the signature and the configured font/colour (proving the 07 drain path this module feeds). Repeat with **Forward** on a message with a PDF: the attachment toggle is on, the mail arrives with the PDF, and the inline logo is offered as a separate (off) attachment.
11. Manual device step: turn on Airplane Mode, send a reply → the sheet dismisses, the mail appears in the Outbox section only after the send finally fails permanently; with connectivity restored it is delivered without a duplicate. Verify against Gmail's Sent folder (architecture §14 #9).

---

## 10. Open questions & assumptions

| # | Item | Status / assumption chosen | Fallback |
|---|---|---|---|
| A1 | Re-sending a `failed` job reuses the old `SendJob.messageID`. If the old row had reached `transmitState == maybeSent` and Gmail did accept it, the recipient may receive two copies with the same `Message-ID`, and a later retry of the **new** row may find the *old* copy through `rfc822msgid:` and drop the edited version. | assumption: reuse the id — duplicates are then dedupable/threadable by the receiving client, and architecture §14 #9/#25 already accept a residual duplicate risk | Generate a fresh id in `send()` for `.failedSend` (one line: `messageID: MessageIDs.generate(domain:)`); duplicates then arrive as two distinct messages |
| A2 | `AddressParser.parseList` accepts a raw (non-RFC-2047) UTF-8 display name inside a quoted string, so `display(_:)`'s output round-trips. | assumption (02 §3.7 describes a character-level tokenizer with quoted-string support) | If it does not, `display(_:)` falls back to `Mailbox.serialized()` and the UI shows encoded words for non-ASCII names — ugly but correct; `testAddressFieldRoundTrip` catches it at build time |
| A3 | `.sensoryFeedback(.success, trigger:)` fires when the trigger changes in the same update that starts the sheet dismissal. | assumed (the view is alive for the dismissal animation) | `send()` calls `UINotificationFeedbackGenerator().notificationOccurred(.success)` directly; that adds `import UIKit` to `ComposeScreen.swift` (allowed by `make lint`) |
| A4 | No signature on/off control in the compose form. `includeSignature` is initialised from `Settings.signatureEnabled` and is not editable. | decision: architecture §8.5 lists exactly To/Cc/Subject, the editor, attachment toggles and the quote; per-draft signature control is not in stage 1 | Add one `Toggle("Include signature", isOn:)` row to the attachments section and make `includeSignature` a `var` — the `SendJob` field already exists |
| A5 | The compose `TextEditor` uses the system body font and `themeTokens.text`, not `Settings.composeStyle`. | decision: a `#000000` compose colour is unreadable on a dark background, and the style is an outgoing-HTML concern applied by `OutgoingBodies` (architecture §7.5, D14) | Apply `.font(.system(size: CGFloat(style.sizePx)))` only (never the colour) if the owner asks for a closer preview |
| A6 | `ComposeModel` calls `SyncEngine.ensureThreadLoaded(threadId:)` when the original body is missing. 07's consumer table lists only `MailActions.send`, `Outbox.maxForwardAttachmentBytes` and `Outbox.discardSend` for this module. | assumption: the extra call is safe (public API, deduped per thread inside the actor, no write of its own) | Drop the call: compose is only reachable from the thread screen, which already issued `ensureThreadLoaded` on appear; the quote then waits for that fetch instead |
| A7 | Inline (`cid:`) parts are listed in the forward attachment section but **not** selected by default. | decision reconciling architecture §7.2 ("attachments = the original's non-inline rows, all selected") with §7.6/§14 #21 ("listed as normal attachments the user may include") | List only non-inline rows (drop the `isInline` rows from `ComposeDraftBuilder.attachments`) if the extra rows confuse the owner |
| A8 | The validation footer uses `themeTokens.secondaryText`; `ThemeTokens` (architecture §10) defines no error colour. | decision: adding a token is module 01's scope; the disabled Send button carries the affordance | Module 13/01 may add `ThemeTokens.error`; this screen then swaps one `foregroundStyle` |
| A9 | `SelfIdentity` comes from `env.identitySource.current()` (07 D12), which reads `syncState.accountEmail` / `selfAddresses` / `displayName` plus `Settings`. Its style and signature return values are ignored here. | assumption: `OutboxIdentitySource` is reachable from `AppEnvironment` as `let identitySource` (07 §3.10) | Read the three `syncState` keys directly with `SyncStateRepository.get` inside the same `db.read` as `threadDetail` — one extra read, no new API |
| A10 | A body row whose `bodyHtml` is 06's "could not be displayed" placeholder fragment (stored when 07 sanitized a nil body) is quoted as-is. | accepted: the quote then contains that sentence, which is honest about what was cached | Treat `bodyHtml == Schema.unavailableBodyHTML` as "no body" and fall back to the snippet (one comparison in `ComposeDraftBuilder.quote`) |
| A11 | `Queries.threadDetail` returns only visible messages (`isHidden = 0`, 06 §3.9), so replying to a message that has just been trashed or marked spam by another client lands in `.unavailable`. | accepted (rare; the thread screen shows the same disappearance) | — |
| A12 | `AnyDatabaseCancellable` is the type returned by `ValueObservation.start` (`[ios-platform §2.6]`, UNVERIFIED — same item as 09 §10 A2). | assumed | Store the returned value as `Any?` / the concrete type the compiler reports; the call sites do not change |
| A13 | Architecture §14 #9 (send idempotency without a server key), #13 (`attachmentId` instability) and #25 (`URLSession` cannot report whether a body was fully transmitted) stay **UNVERIFIED**; this module inherits them through the `SendJob` it writes. | carried forward unchanged | As in architecture §7.7 / §7.6 — the `rfc822msgid:` check and the one re-resolve happen in 07 |
| A14 | `Formatters.bytes` renders 21_000_000 as `"21 MB"` and 20_000_000 as `"20 MB"` (`ByteCountFormatter`, `.file`, decimal MB). | assumed; the exact strings in §5.3 and `testAttachmentBudgetBlocksSend` are built by calling `Formatters.bytes` rather than hard-coding | If the formatter's output differs, the test still passes (it compares against the same call) and only §5.3's illustration is stale |

### Deviations from `architecture.md`

| # | Deviation | Reason |
|---|---|---|
| D1 | `ComposeModel` exposes `toText`, `ccText`, `subject`, `body`, `attachments`, `includeSignature` as top-level properties instead of a nested `draft` value (architecture §8.2 lists them as fields of "draft"). | `@Bindable` + `TextField($model.toText)` needs directly bindable stored properties; the immutable part of the draft is still one value (`ComposeDraftBuilder.Draft`, held privately) and is what the `SendJob` inherits. No behaviour changes. |
| D2 | `ComposeAttachmentItem` (named struct) instead of the architecture's tuple `[(ref, included)]`. | Tuples cannot synthesise `Identifiable`/`Equatable`, which `ForEach` and the tests need. Same fields plus `isInline` (required by §7.6). |
| D3 | `ComposeDraftBuilder` and `ComposeAddressField` are additions; architecture names only `ComposeModel.makeDraft`. | Keeps the prefill and the address-field formatting pure and unit-testable without an `AppEnvironment`; `makeDraft()` keeps its architecture name and is the only entry point. |
| D4 | Display serialisation of a mailbox is app-side (`ComposeAddressField.display`) rather than `Mailbox.serialized()`. | `Mailbox.serialized()` produces header bytes (RFC 2047 encoded words for non-ASCII names, 02 §3.6) — unreadable in a text field. The wire form is still produced by `MIMEBuilder` from the parsed `Mailbox` values, so nothing on the wire changes. |
| D5 | `send()` returns `Bool` and runs the enqueue in an unstructured `Task`; architecture §8.2 writes `MailActions.send(job) → dismiss immediately`. | The dismissal must not wait for the actor hop, and the model dies with the sheet. Capturing only `Sendable` values keeps the send alive; the observable behaviour is exactly "enqueue, then dismiss". |
| D6 | The model calls `SyncEngine.ensureThreadLoaded` (see A6). | Prevents a permanently disabled Send when compose is opened while the body fetch failed transiently. |
