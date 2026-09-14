import Foundation
import GRDB
import MailCore
import MailHTML
import Observation
import os

/// Load state of the compose sheet (architecture §8.2).
nonisolated enum ComposePhase: Equatable, Sendable {
    /// `makeDraft()` has not finished its single cache read yet. Fields are empty and Send is disabled.
    case loading
    /// Draft prefilled, fields editable. Send may still be disabled — see `canSend`.
    case ready
    /// The original message is not in the cache. Payload = the sentence rendered by `ComposeUnavailableView`.
    case unavailable(String)
}

/// One row of the "Attachments" section — architecture §8.2 `attachments: [(ref, included)]`.
nonisolated struct ComposeAttachmentItem: Identifiable, Equatable, Sendable {
    /// What travels in `SendJob.attachments` when `included` is true (bytes are fetched by 07 at drain time).
    var ref: ForwardAttachmentRef
    /// Referenced by a `cid:` in the sanitized body. Listed but not selected by default: its `<img>` was removed
    /// from the quote by `QuoteExtractor`, and stage 1 does not re-attach inline images (architecture §7.6).
    var isInline: Bool
    /// Toggle state. Only included refs reach the `SendJob`.
    var included: Bool

    var id: String { ref.partId }

    var sizeLabel: String { Formatters.bytes(ref.size) }
}

/// Mailbox list ↔ editable text-field content, plus address validation (architecture §8.5).
nonisolated enum ComposeAddressField {

    static func text(for mailboxes: [Mailbox]) -> String {
        mailboxes.map(display).joined(separator: ", ")
    }

    /// Human-readable, re-parsable form of one mailbox. Unlike `Mailbox.serialized()` this never RFC 2047-encodes
    /// a non-ASCII name: the text field is read back by `AddressParser`, not put on the wire (§10 D4).
    static func display(_ mailbox: Mailbox) -> String {
        let trimmed = (mailbox.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return mailbox.addr }
        let specials = Set("(),:;<>@[]\\\"")
        let needsQuoting =
            trimmed.contains(where: { specials.contains($0) }) || trimmed != (mailbox.name ?? "")
        if !needsQuoting { return "\(trimmed) <\(mailbox.addr)>" }
        var escaped = ""
        for character in trimmed {
            if character == "\\" || character == "\"" { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\" <\(mailbox.addr)>"
    }

    /// `AddressParser.parseList` split into addresses that pass `isValidAddrSpec` and the raw `addr` strings of
    /// those that do not. Never throws; empty or blank `text` yields `([], [])`.
    static func parse(_ text: String) -> (mailboxes: [Mailbox], invalid: [String]) {
        let all = AddressParser.parseList(text)
        return (all.filter { isValidAddrSpec($0.addr) }, all.filter { !isValidAddrSpec($0.addr) }.map(\.addr))
    }

    /// Exactly one `@`; non-empty local part; non-empty domain without a leading/trailing `.` and without `..`;
    /// no whitespace; none of `<>,;:"\[]()`. A dotless domain (`user@localhost`) is accepted on purpose.
    static func isValidAddrSpec(_ addr: String) -> Bool {
        if addr.contains(where: { $0.isWhitespace || $0.isNewline }) { return false }
        let forbidden = Set("<>,;:\"\\[]()")
        if addr.contains(where: { forbidden.contains($0) }) { return false }
        let parts = addr.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        return true
    }
}

/// Pure prefill of architecture §7.2 — everything `ComposeModel.makeDraft()` computes from one cache read.
/// Separate from the model so it is testable without an `AppEnvironment` and with an injected `UUID`.
nonisolated enum ComposeDraftBuilder {

    /// The frozen part of a draft: what the user may not edit and what the `SendJob` inherits verbatim.
    struct Draft: Equatable, Sendable {
        var mode: ComposeMode
        var originalMessageId: String
        var threadId: String
        var to: [Mailbox]
        var cc: [Mailbox]
        var subject: String
        /// `"<UUID@domain>"`, frozen here and never regenerated (architecture §7.2, §14 #9).
        var messageID: String
        var inReplyTo: String?
        var references: [String]
        var quote: QuoteSource
        /// `false` while the original body is still loading — Send stays disabled.
        var quoteReady: Bool
        /// Forward only; empty for `.replyAll`.
        var attachments: [ComposeAttachmentItem]
    }

    /// Architecture §7.2. Pure; no I/O; never throws.
    static func make(
        mode: ComposeMode, original: MessageRecord, body: MessageBodyRecord?, attachments records: [AttachmentRecord],
        identity: SelfIdentity, uuid: UUID = UUID()
    ) -> Draft {
        let recipients =
            mode == .replyAll
            ? ReplyAll.recipients(
                from: original.from, replyTo: original.replyToList, to: original.toList, cc: original.ccList,
                me: identity)
            : Recipients(to: [], cc: [])
        let subject =
            mode == .replyAll
            ? SubjectPrefix.reply(original.subject) : SubjectPrefix.forward(original.subject)
        let (quote, ready) = self.quote(original: original, body: body)
        return Draft(
            mode: mode,
            originalMessageId: original.id,
            threadId: original.threadId,
            to: recipients.to,
            cc: recipients.cc,
            subject: subject,
            messageID: MessageIDs.generate(domain: domain(ofEmail: identity.primary.addr), uuid: uuid),
            // Threading headers are identical for a forward — Gmail-web behaviour (architecture D24).
            inReplyTo: original.messageIdHeader,
            references: MessageIDs.referencesChain(
                parentReferences: original.referencesList, parentInReplyTo: original.inReplyTo,
                parentMessageID: original.messageIdHeader),
            quote: quote,
            quoteReady: ready,
            attachments: mode == .forward ? self.attachments(records) : [])
    }

    /// Non-inline parts are pre-selected; inline ones are listed but off (architecture §7.6, §14 #21).
    static func attachments(_ records: [AttachmentRecord]) -> [ComposeAttachmentItem] {
        records.map { record in
            ComposeAttachmentItem(
                ref: ForwardAttachmentRef(
                    partId: record.partId, filename: record.filename, mimeType: record.mimeType, size: record.size,
                    attachmentId: record.attachmentId),
                isInline: record.isInline,
                included: !record.isInline)
        }
    }

    /// The `QuoteSource` snapshot alone, re-run when a late body arrives.
    /// `ready == false` only when `body == nil && original.bodyState == 0`.
    static func quote(original: MessageRecord, body: MessageBodyRecord?) -> (quote: QuoteSource, ready: Bool) {
        var html = body.map { QuoteExtractor.quotable($0.bodyHtml) }
        if html?.isEmpty == true { html = nil }
        let text = body?.bodyText ?? html.map(Quoting.textFromHTML) ?? original.snippet
        let quote = QuoteSource(
            author: original.from,
            date: Date(timeIntervalSince1970: Double(original.internalDate) / 1000),
            subject: original.subject,
            to: original.toList,
            cc: original.ccList,
            html: html,
            text: text)
        return (quote, body != nil || original.bodyState == 2)
    }

    /// Everything after the first `@` of `email`, lowercased; `""` when there is none.
    static func domain(ofEmail email: String) -> String {
        guard let index = email.firstIndex(of: "@") else { return "" }
        return String(email[email.index(after: index)...]).lowercased()
    }
}

/// Main-actor model of the compose sheet (architecture §8.2).
///
/// One instance per presented sheet, owned by `ComposeScreen` as `@State`. `init` performs no I/O; the single
/// cache read happens in `makeDraft()`, which the screen awaits in `.task`.
@Observable final class ComposeModel {

    /// Forward budget — `Outbox.maxForwardAttachmentBytes` (architecture §7.6), re-exported so the screen and the
    /// tests do not reach into the outbox actor's type for a number.
    static let maxAttachmentBytes: Int = Outbox.maxForwardAttachmentBytes

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored let input: ComposeInput

    private(set) var phase: ComposePhase
    private(set) var mode: ComposeMode
    var toText: String
    var ccText: String
    var subject: String
    /// The typed body — plain text, exactly what becomes `SendJob.typedText`.
    var body: String
    private(set) var attachments: [ComposeAttachmentItem]
    /// `Settings.signatureEnabled` at sheet-open time, or `job.includeSignature` for a reopen. Not editable in
    /// stage 1 — architecture §8.5 lists no signature control.
    private(set) var includeSignature: Bool
    private(set) var quoteReady: Bool
    private(set) var quotePreview: String
    /// `true` from the moment Send was accepted until the sheet goes away; keeps a second tap from enqueuing twice.
    private(set) var isSending: Bool
    private(set) var sendFeedbackId: Int

    @ObservationIgnored private var draft: ComposeDraftBuilder.Draft?
    @ObservationIgnored private var bodyCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private let uuid: () -> UUID

    init(env: AppEnvironment, input: ComposeInput, uuid: @escaping () -> UUID = UUID.init) {
        self.env = env
        self.input = input
        self.uuid = uuid
        isSending = false
        sendFeedbackId = 0
        switch input {
        case .failedSend(_, let job):
            mode = job.mode
            toText = ComposeAddressField.text(for: job.to)
            ccText = ComposeAddressField.text(for: job.cc)
            subject = job.subject
            body = job.typedText
            let items = job.attachments.map { ComposeAttachmentItem(ref: $0, isInline: false, included: true) }
            attachments = items
            includeSignature = job.includeSignature
            quoteReady = true
            quotePreview = job.quoteSource.text ?? ""
            phase = .ready
            // The job already carries the snapshot, so a stale or evicted cache is irrelevant (§4.5).
            draft = ComposeDraftBuilder.Draft(
                mode: job.mode, originalMessageId: job.originalMessageId, threadId: job.threadId, to: job.to,
                cc: job.cc, subject: job.subject, messageID: job.messageID, inReplyTo: job.inReplyTo,
                references: job.references, quote: job.quoteSource, quoteReady: true, attachments: items)
        case .fromMessage(let mode, _, _):
            self.mode = mode
            toText = ""
            ccText = ""
            subject = ""
            body = ""
            attachments = []
            includeSignature = env.settings.snapshot.signatureEnabled
            quoteReady = false
            quotePreview = ""
            phase = .loading
        }
    }

    // MARK: prefill

    /// Architecture §7.2 prefill — main actor, from cached data only, exactly one `env.db.read`. Idempotent.
    func makeDraft() async {
        guard case .fromMessage(let mode, let threadId, let messageId) = input, phase == .loading else { return }
        let (identity, _, _) = await env.identitySource.current()
        let detail: ThreadDetail?
        do {
            detail = try await env.db.read { try Queries.threadDetail($0, threadId: threadId) }
        } catch {
            Log.ui.error("compose.read.failed \(String(describing: error), privacy: .public)")
            phase = .unavailable(ComposeModel.unavailableText)
            return
        }
        guard let detail, let original = detail.messages.first(where: { $0.id == messageId }) else {
            Log.ui.notice("compose.original.missing \(messageId, privacy: .public)")
            phase = .unavailable(ComposeModel.unavailableText)
            return
        }
        let draft = ComposeDraftBuilder.make(
            mode: mode, original: original, body: detail.bodies[messageId],
            attachments: detail.attachments.filter { $0.messageId == messageId }, identity: identity, uuid: uuid())
        self.draft = draft
        toText = ComposeAddressField.text(for: draft.to)
        ccText = ComposeAddressField.text(for: draft.cc)
        subject = draft.subject
        attachments = draft.attachments
        quoteReady = draft.quoteReady
        quotePreview = draft.quote.text ?? ""
        phase = .ready
        guard !draft.quoteReady else { return }
        startBodyObservation(threadId: threadId, messageId: messageId)
        // Deduped per thread by the engine, so opening compose over a thread that is already fetching costs nothing.
        Task { [sync = env.sync] in try? await sync.ensureThreadLoaded(threadId: threadId) }
    }

    /// Resolves `quoteReady` as soon as the original body lands, then cancels itself: the snapshot is taken once,
    /// so a later re-fetch or eviction cannot change the quote under the user's fingers (architecture §7.2).
    private func startBodyObservation(threadId: String, messageId: String) {
        bodyCancellable?.cancel()
        bodyCancellable =
            ValueObservation
            .tracking { db in try Queries.threadDetail(db, threadId: threadId) }
            .start(
                in: env.db, scheduling: .immediate,
                onError: { [weak self] error in
                    MainActor.assumeIsolated { self?.quoteReadyFallback(error) }
                },
                onChange: { [weak self] detail in
                    MainActor.assumeIsolated { self?.bodyArrived(detail, messageId: messageId) }
                })
    }

    private func bodyArrived(_ detail: ThreadDetail?, messageId: String) {
        guard !quoteReady, let original = detail?.messages.first(where: { $0.id == messageId }) else { return }
        let (quote, ready) = ComposeDraftBuilder.quote(original: original, body: detail?.bodies[messageId])
        guard ready else { return }
        draft?.quote = quote
        quotePreview = quote.text ?? ""
        if mode == .forward, attachments.isEmpty {
            let records = (detail?.attachments ?? []).filter { $0.messageId == messageId }
            attachments = ComposeDraftBuilder.attachments(records)
            draft?.attachments = attachments
        }
        draft?.quoteReady = true
        quoteReady = true
        stop()
    }

    /// The database was replaced (a sign-out wipe) or the read failed. Keep the provisional snippet snapshot and
    /// unblock Send rather than leaving the user stuck.
    private func quoteReadyFallback(_ error: any Error) {
        Log.ui.error("compose.body.observation.failed \(String(describing: error), privacy: .public)")
        draft?.quoteReady = true
        quoteReady = true
        stop()
    }

    /// Cancels the body observation. Called from `.onDisappear` and by the tests.
    func stop() {
        bodyCancellable?.cancel()
        bodyCancellable = nil
    }

    // MARK: derived

    var title: String { mode == .replyAll ? "Reply All" : "Forward" }

    /// Recomputed on every keystroke: two `parseList` calls over a few hundred characters, well under one frame.
    var validation: String? {
        let to = ComposeAddressField.parse(toText)
        if let first = to.invalid.first { return "Not a valid address: \(first)" }
        if to.mailboxes.isEmpty { return "Add at least one recipient." }
        if let first = ComposeAddressField.parse(ccText).invalid.first { return "Not a valid address: \(first)" }
        return nil
    }

    var attachmentBytes: Int { attachments.filter(\.included).reduce(0) { $0 + $1.ref.size } }

    private var isOverBudget: Bool { attachmentBytes > ComposeModel.maxAttachmentBytes }

    var attachmentFooter: String? {
        guard !attachments.isEmpty else { return nil }
        if isOverBudget {
            let used = Formatters.bytes(attachmentBytes)
            let limit = Formatters.bytes(ComposeModel.maxAttachmentBytes)
            return "Attachments are \(used) — the limit is \(limit). Turn some off to send."
        }
        let count = attachments.filter(\.included).count
        if count == 0 { return "No attachments included" }
        return "\(count) attachment\(count == 1 ? "" : "s") · \(Formatters.bytes(attachmentBytes))"
    }

    var canSend: Bool {
        phase == .ready && quoteReady && !isSending && validation == nil && !isOverBudget
    }

    /// Cancel needs a confirmation when the draft has content.
    var hasContent: Bool {
        if case .failedSend = input { return true }
        if !self.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let draft else { return false }
        if toText != ComposeAddressField.text(for: draft.to) { return true }
        if ccText != ComposeAddressField.text(for: draft.cc) { return true }
        if subject != draft.subject { return true }
        return attachments != draft.attachments
    }

    // MARK: actions

    func setAttachment(partId: String, included: Bool) {
        guard let index = attachments.firstIndex(where: { $0.id == partId }) else { return }
        attachments[index].included = included
    }

    /// Builds the job the way `Outbox.performSend` expects it. `nil` when `canSend == false`.
    func makeJob() -> SendJob? {
        guard canSend, let draft else { return nil }
        return SendJob(
            mode: draft.mode,
            originalMessageId: draft.originalMessageId,
            threadId: draft.threadId,
            messageID: draft.messageID,
            to: ComposeAddressField.parse(toText).mailboxes,
            cc: ComposeAddressField.parse(ccText).mailboxes,
            subject: subject,
            typedText: self.body,
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            quoteSource: draft.quote,
            attachments: attachments.filter(\.included).map(\.ref),
            includeSignature: includeSignature)
    }

    /// Enqueues and returns; the caller dismisses the sheet in the same turn. The task captures only `Sendable`
    /// values — never `self` — so the send survives the model's deallocation.
    @discardableResult func send() -> Bool {
        guard let job = makeJob() else { return false }
        isSending = true
        sendFeedbackId += 1
        let actions = env.actions
        let outbox = env.outbox
        var old: Int64?
        if case .failedSend(let id, _) = input { old = id }
        Task {
            await actions.send(job)
            // New job first, then delete the row we re-edited: a failed row is never claimed by `claimSend`, so
            // the overlap cannot produce a second transmission (§4.8).
            if let old { await outbox.discardSend(id: old) }
        }
        stop()
        return true
    }

    static let unavailableText = "This message is no longer available."
}
