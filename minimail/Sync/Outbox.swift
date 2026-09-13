import Foundation
import GRDB
import MailCore
import os

/// Drains the `outbox` table: `threads.modify` batches and `messages.send` (architecture §4.8, §7.6–§7.7). One instance.
actor Outbox {
    /// Forward budget (architecture §7.6): Σ `ForwardAttachmentRef.size` above this fails the job before any request.
    nonisolated static let maxForwardAttachmentBytes = 20_000_000
    /// Counted transient attempts before a modify op becomes `failed`.
    nonisolated static let maxModifyAttempts = 8
    /// Counted transient attempts before a send becomes `failed`.
    nonisolated static let maxSendAttempts = 5
    /// `kick()` debounce.
    nonisolated static let kickDelay: TimeInterval = 0.3
    /// Claim size = `GmailClient.batchChunkSize` (25).
    nonisolated static let claimLimit = 25

    private var db: any DatabaseWriter
    private let gmail: GmailClient
    private let status: SyncStatus
    private let identity: @Sendable () async -> (SelfIdentity, ComposeStyle, signatureHTML: String?)
    private let clock: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private let syncBox = OSAllocatedUnfairLock<SyncEngine?>(initialState: nil)
    private var draining = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var kickTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var isForeground = false
    private var cancelRequested = false
    private var pausedForQuota = false

    init(
        db: any DatabaseWriter, gmail: GmailClient, status: SyncStatus,
        identity: @escaping @Sendable () async -> (SelfIdentity, ComposeStyle, signatureHTML: String?),
        clock: @escaping @Sendable () -> Date = Date.init,
        random: @escaping @Sendable () -> Double,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.db = db
        self.gmail = gmail
        self.status = status
        self.identity = identity
        self.clock = clock
        self.random = random
        self.sleeper = sleep
    }

    // MARK: kick / wake

    func kick() {
        guard kickTask == nil, !draining else { return }
        kickTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper(Self.kickDelay)
            await self.clearKick()
            await self.drain()
        }
    }
    private func clearKick() { kickTask = nil }

    func setForeground(_ isForeground: Bool) {
        self.isForeground = isForeground
        if !isForeground {
            wakeTask?.cancel()
            wakeTask = nil
        }
    }

    private func scheduleWake(after: TimeInterval) {
        guard isForeground, wakeTask == nil else { return }
        wakeTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper(after)
            if Task.isCancelled { return }
            await self.clearWake()
            await self.drain()
        }
    }
    private func clearWake() { wakeTask = nil }

    // MARK: drain

    private struct BatchOutcome {
        var acked = false
        var stop = false
        var offline = false
        var unauthorized = false
        var quota = false
    }

    func drain() async {
        if draining {
            await withCheckedContinuation { drainWaiters.append($0) }
            return
        }
        guard !pausedForQuota else { return }
        draining = true
        defer {
            draining = false
            let waiters = drainWaiters
            drainWaiters = []
            for w in waiters { w.resume() }
        }

        var ackedAny = false
        var sawOffline = false
        var sawUnauthorized = false
        let signpost = Log.begin(.outboxDrain)
        defer { Log.end(.outboxDrain, signpost) }

        loop: while true {
            if cancelRequested || Task.isCancelled { break }
            do {
                let now = nowMs()
                let rnd = random
                let mods = try await db.write {
                    try OutboxRepository.claimModifies($0, limit: Self.claimLimit, now: now)
                }
                if !mods.isEmpty {
                    let calls = mods.map {
                        ThreadModifyCall(
                            opId: $0.id, threadId: $0.threadId ?? "", add: $0.addLabelIds ?? [],
                            remove: $0.removeLabelIds ?? [])
                    }
                    var results: [Int64: Result<GmailThread, GmailError>]
                    do {
                        results = try await gmail.modifyThreads(calls)
                    } catch let e as GmailError {
                        results = Dictionary(uniqueKeysWithValues: calls.map { ($0.opId, .failure(e)) })
                    } catch {
                        results = Dictionary(uniqueKeysWithValues: calls.map { ($0.opId, .failure(.cancelled)) })
                    }

                    let finalResults = results
                    let outcome = try await db.write { db -> BatchOutcome in
                        var o = BatchOutcome()
                        for op in mods {
                            let r = finalResults[op.id] ?? .failure(.batchMalformed)
                            switch r {
                            case .success(let thread):
                                let labels: [String: Set<String>]? = thread.messages.map { msgs in
                                    Dictionary(uniqueKeysWithValues: msgs.map { ($0.id, Set($0.labelIds ?? [])) })
                                }
                                _ = try OutboxRepository.ackModify(db, opId: op.id, serverLabelsByMessage: labels)
                                o.acked = true
                            case .failure(.notFound):
                                _ = try OutboxRepository.ackModify(db, opId: op.id, serverLabelsByMessage: nil)
                                o.acked = true
                            case .failure(.badRequest):
                                _ = try OutboxRepository.discardModify(db, opId: op.id)
                                Log.outbox.error("modify \(op.id, privacy: .public) discarded (badRequest)")
                            case .failure(.forbidden(let reason)) where reason != "dailyLimitExceeded":
                                _ = try OutboxRepository.discardModify(db, opId: op.id)
                                Log.outbox.error("modify \(op.id, privacy: .public) discarded (forbidden)")
                            case .failure(.forbidden):
                                try Self.retry(db, op: op, error: .forbidden(reason: "dailyLimitExceeded"), now: now, random: rnd)
                                o.stop = true
                                o.quota = true
                            case .failure(.unauthorized):
                                try Self.retry(db, op: op, error: .unauthorized, now: now, random: rnd)
                                o.stop = true
                                o.unauthorized = true
                            case .failure(.offline):
                                try Self.retry(db, op: op, error: .offline, now: now, random: rnd)
                                o.stop = true
                                o.offline = true
                            case .failure(.cancelled):
                                try Self.retry(db, op: op, error: .cancelled, now: now, random: rnd)
                                o.stop = true
                            case .failure(let e) where e.isTransient:
                                if op.attempts >= Self.maxModifyAttempts {
                                    try OutboxRepository.fail(db, opId: op.id, error: e.userMessage)
                                } else {
                                    try Self.retry(db, op: op, error: e, now: now, random: rnd)
                                }
                            case .failure(let e):
                                try OutboxRepository.fail(db, opId: op.id, error: e.userMessage)
                            }
                        }
                        return o
                    }
                    ackedAny = ackedAny || outcome.acked
                    if outcome.offline { sawOffline = true }
                    if outcome.unauthorized { sawUnauthorized = true }
                    if outcome.quota { pausedForQuota = true }
                    if outcome.stop { break loop }
                }

                let now2 = nowMs()
                let send = try await db.write { try OutboxRepository.claimSend($0, now: now2) }
                if let send {
                    if await performSend(send) == .stop { break loop }
                }
                if mods.isEmpty && send == nil { break loop }
            } catch {
                Log.outbox.error("drain aborted: \(String(describing: error), privacy: .public)")
                break loop
            }
        }

        let counts = (try? await db.read { try Queries.outboxCounts($0) }) ?? (pending: 0, failed: 0)
        let now = nowMs()
        let due: Int64? = try? await db.read { db -> Int64? in
            var times = try OutboxRepository.pendingModifies(db).map(\.nextAttemptAt)
            times += try OutboxRecord
                .filter(Column("kind") == "send" && Column("state") == "pending")
                .fetchAll(db).map(\.nextAttemptAt)
            return times.filter { $0 > now }.min()
        }
        let offline = sawOffline
        let unauthorized = sawUnauthorized
        await MainActor.run {
            status.pendingOps = counts.pending
            status.failedSends = counts.failed
            // Only raise the offline flag; clearing it is the job of a successful request (SyncEngine.noteResult),
            // so a no-op drain at the end of an offline run does not wipe the flag the run just set.
            if offline { status.isOffline = true }
            if unauthorized { status.lastError = GmailError.unauthorized.userMessage }
        }
        if ackedAny, let sync = syncBox.withLock({ $0 }) { await sync.updateBadge() }
        if let due { scheduleWake(after: Double(due - nowMs()) / 1000) }
    }

    /// One `retryLater` with the outbox backoff schedule (06's `retryLater` takes a precomputed `nextAttemptAt`).
    private static func retry(
        _ db: Database, op: OutboxRecord, error: GmailError, now: Int64, random: @Sendable () -> Double
    ) throws {
        let attempts = error.countsAsAttempt ? op.attempts : max(0, op.attempts - 1)
        let delay = Backoff.outbox.delay(attempt: attempts, retryAfter: error.retryAfter, random: random())
        try OutboxRepository.retryLater(
            db, opId: op.id, error: error.userMessage, countsAsAttempt: error.countsAsAttempt,
            nextAttemptAt: now + Int64(delay * 1000))
    }

    // MARK: send

    private enum SendOutcome: Equatable { case `continue`, stop }
    private enum AttachmentsResult { case success([OutgoingAttachment]); case permanent(String); case transient(GmailError) }

    private func performSend(_ op: OutboxRecord) async -> SendOutcome {
        guard let job = op.sendJob else {
            try? await db.write { try OutboxRepository.fail($0, opId: op.id, error: GmailError.decoding("sendJob").userMessage) }
            return .continue
        }

        if op.transmitState == .maybeSent {
            do {
                let found = try await gmail.listMessages(
                    labelIds: [], q: "rfc822msgid:\(job.messageID)", maxResults: 1, pageToken: nil)
                if !(found.messages ?? []).isEmpty {
                    Log.outbox.notice("send \(op.id, privacy: .public) already delivered (rfc822msgid)")
                    try await db.write { try OutboxRepository.deleteSend($0, opId: op.id) }
                    afterSend()
                    return .continue
                }
            } catch let e as GmailError where e == .offline || e == .unauthorized || e.isTransient {
                try? await retryLater(op, e)
                return .stop
            } catch {
                Log.outbox.error("outbox.send.duplicate-risk \(op.id, privacy: .public)")
            }
        }

        let total = job.attachments.reduce(0) { $0 + $1.size }
        if total > Self.maxForwardAttachmentBytes {
            let mb = String(format: "%.1f", Double(total) / 1_000_000)
            try? await db.write {
                try OutboxRepository.fail($0, opId: op.id, error: "Attachments too large to forward (\(mb) MB)")
            }
            return .continue
        }

        let atts: [OutgoingAttachment]
        switch await fetchAttachments(job) {
        case .success(let a):
            atts = a
        case .permanent(let text):
            try? await db.write { try OutboxRepository.fail($0, opId: op.id, error: text) }
            return .continue
        case .transient(let e):
            try? await retryLater(op, e)
            return .stop
        }

        let (me, style, signature) = await identity()
        let tz = TimeZone.current
        let quoteHTML =
            job.mode == .replyAll
            ? Quoting.replyHTML(job.quoteSource, timeZone: tz) : Quoting.forwardHTML(job.quoteSource, timeZone: tz)
        let quoteText =
            job.mode == .replyAll
            ? Quoting.replyText(job.quoteSource, timeZone: tz) : Quoting.forwardText(job.quoteSource, timeZone: tz)
        let sig = job.includeSignature ? signature : nil
        let html = OutgoingBodies.document(
            bodyFragment: OutgoingBodies.html(
                typed: job.typedText, style: style, signatureHTML: sig, quoteHTML: quoteHTML))
        let text = OutgoingBodies.text(
            typed: job.typedText, signatureText: sig.map(Quoting.textFromHTML), quoteText: quoteText)
        let bytes = MIMEBuilder.build(
            OutgoingMessage(
                from: me.primary, to: job.to, cc: job.cc, subject: job.subject, date: clock(), timeZone: tz,
                messageID: job.messageID, inReplyTo: job.inReplyTo, references: job.references, textBody: text,
                htmlBody: html, attachments: atts))

        try? await db.write { try OutboxRepository.setTransmitState($0, opId: op.id, .maybeSent) }
        do {
            _ = try await gmail.send(raw: bytes, threadId: job.threadId)
            try await db.write { try OutboxRepository.deleteSend($0, opId: op.id) }
            afterSend()
            return .continue
        } catch let e as GmailError {
            switch e {
            case .offline, .unauthorized, .cancelled:
                try? await retryLater(op, e)
                return .stop
            case .network, .server, .rateLimited, .batchMalformed:
                if op.attempts >= Self.maxSendAttempts {
                    try? await db.write { try OutboxRepository.fail($0, opId: op.id, error: e.userMessage) }
                    return .continue
                }
                try? await retryLater(op, e)
                return .stop
            default:
                try? await db.write { try OutboxRepository.fail($0, opId: op.id, error: e.userMessage) }
                return .continue
            }
        } catch {
            try? await retryLater(op, .cancelled)
            return .stop
        }
    }

    private func retryLater(_ op: OutboxRecord, _ e: GmailError) async throws {
        let now = nowMs()
        let rnd = random
        try await db.write { try Self.retry($0, op: op, error: e, now: now, random: rnd) }
    }

    private func fetchAttachments(_ job: SendJob) async -> AttachmentsResult {
        var out: [OutgoingAttachment] = []
        var reresolved = false
        for ref in job.attachments {
            var attId = ref.attachmentId
            var data: Data? = nil
            roundLoop: for round in 0..<2 {
                if let id = attId {
                    do {
                        data = try await gmail.getAttachment(messageId: job.originalMessageId, attachmentId: id)
                        break roundLoop
                    } catch GmailError.notFound {
                        // fall through to re-resolve
                    } catch let e as GmailError
                        where e == .offline || e == .unauthorized || e.isTransient || e == .cancelled {
                        return .transient(e)
                    } catch let e as GmailError {
                        return .permanent(e.userMessage)
                    } catch {
                        return .transient(.cancelled)
                    }
                }
                if round == 0 && !reresolved {
                    do {
                        let m = try await gmail.getMessage(
                            id: job.originalMessageId, format: .full, fields: "id,payload")
                        let parsed = MessageParser.parse(m)
                        try await db.write {
                            try BodyRepository.updateAttachmentIds(
                                $0, messageId: job.originalMessageId, parsed: parsed.attachments)
                        }
                        attId = parsed.attachments.first { $0.partId == ref.partId }?.attachmentId
                        reresolved = true
                    } catch GmailError.notFound {
                        return .permanent("Original message no longer available")
                    } catch let e as GmailError
                        where e == .offline || e == .unauthorized || e.isTransient || e == .cancelled {
                        return .transient(e)
                    } catch let e as GmailError {
                        return .permanent(e.userMessage)
                    } catch {
                        return .transient(.cancelled)
                    }
                } else {
                    break roundLoop
                }
            }
            guard let bytes = data else {
                return .permanent("Attachment \(ref.filename) no longer available")
            }
            if bytes.count != ref.size {
                Log.outbox.notice(
                    "attachment size mismatch \(ref.partId, privacy: .public): \(bytes.count, privacy: .public) vs \(ref.size, privacy: .public)"
                )
            }
            out.append(
                OutgoingAttachment(
                    filename: Self.sanitizedFilename(ref.filename), mimeType: ref.mimeType, data: bytes))
        }
        return .success(out)
    }

    nonisolated static func sanitizedFilename(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in name.unicodeScalars {
            if s == "/" || s == "\\" || (s.value <= 0x1F) || s.value == 0x7F {
                scalars.append("_")
            } else {
                scalars.append(s)
            }
        }
        var out = String(scalars)
        if out.hasPrefix(".") { out = "_" + out.dropFirst() }
        return out.isEmpty ? "attachment" : out
    }

    private func afterSend() {
        if let sync = syncBox.withLock({ $0 }) {
            Task { await sync.run(.afterSend) }
        }
    }

    // MARK: user-facing operations

    func retrySend(id: Int64) async {
        try? await db.write { try OutboxRepository.retrySend($0, opId: id) }
        await drain()
    }

    func discardSend(id: Int64) async {
        try? await db.write { try OutboxRepository.deleteSend($0, opId: id) }
        await refreshCounts()
    }

    func rearmFailedModifies() async {
        try? await db.write { try OutboxRepository.rearmFailedModifies($0) }
        await refreshCounts()
    }

    private func refreshCounts() async {
        let counts = (try? await db.read { try Queries.outboxCounts($0) }) ?? (pending: 0, failed: 0)
        await MainActor.run {
            status.pendingOps = counts.pending
            status.failedSends = counts.failed
        }
    }

    // MARK: lifecycle

    nonisolated func bind(sync: SyncEngine) { syncBox.withLock { $0 = sync } }

    func cancelAll() async {
        cancelRequested = true
        kickTask?.cancel()
        kickTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        if draining {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    func replaceDatabase(_ db: any DatabaseWriter) {
        precondition(!draining, "replaceDatabase while draining")
        self.db = db
        cancelRequested = false
        pausedForQuota = false
    }

    var isPausedForQuota: Bool { pausedForQuota }
    var isDraining: Bool { draining }

    private func nowMs() -> Int64 { Int64(clock().timeIntervalSince1970 * 1000) }
}

/// Main-actor source of the send identity (D12). Owned by `AppEnvironment`.
@Observable final class OutboxIdentitySource {
    var db: any DatabaseWriter
    let settings: SettingsStore
    init(db: any DatabaseWriter, settings: SettingsStore) {
        self.db = db
        self.settings = settings
    }

    func current() async -> (SelfIdentity, ComposeStyle, signatureHTML: String?) {
        let state = (try? await db.read { try SyncStateRepository.all($0) }) ?? [:]
        let accountEmail = state[.accountEmail] ?? ""
        if accountEmail.isEmpty { Log.outbox.error("identity: no accountEmail") }
        let primary = Mailbox(name: state[.displayName], addr: accountEmail)
        var addresses = state[.selfAddresses].map(LabelAlgebra.parseJSON) ?? []
        if !accountEmail.isEmpty { addresses.insert(accountEmail.lowercased()) }
        let identity = SelfIdentity(primary: primary, allAddresses: addresses)
        let snapshot = settings.snapshot
        let signature =
            (snapshot.signatureEnabled && !snapshot.signatureHTML.isEmpty) ? snapshot.signatureHTML : nil
        return (identity, snapshot.composeStyle, signature)
    }
}
