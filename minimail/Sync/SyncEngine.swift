import Foundation
import GRDB
import MailCore
import MailHTML
import UserNotifications
import os

/// Why a run was requested (architecture §4.1). `labelOpened`/`loadOlderLabel` carry a Gmail label id.
nonisolated enum SyncReason: Sendable, Equatable {
    case launch, foreground, pullToRefresh, background, afterSend, labelOpened(String), loadOlderInbox,
        loadOlderLabel(String)
}

/// Control-flow errors of one run. Never leaves the actor.
nonisolated private enum SyncError: Error, Equatable {
    case historyExpired
    case tooManyRecords
    case rateLimitAbort
    case accountMismatch
    case paused
    case cancelled
}

/// Output of `fetchBody`: everything the sanitiser needs, and nothing that has to stay on the actor.
nonisolated private struct RawBody: Sendable {
    var parsed: ParsedMessage
    var html: String?
    var text: String?
    var snippet: String?
}

/// Output of `sanitize` — computed off the actor, outside any write.
nonisolated private struct PreparedBody: Sendable {
    var parsed: ParsedMessage
    var body: SanitizedBody
    var text: String?
    var referenced: Set<String>
}

/// The sync coordinator. Exactly one instance; owned by `AppEnvironment`.
actor SyncEngine {
    nonisolated static let labelCountsStaleness: TimeInterval = 300
    /// Concurrent SwiftSoup parses. Small on purpose: three multi-megabyte documents in flight is already a
    /// real memory spike on a phone, and the wall-clock win flattens out past the performance cores.
    nonisolated static let sanitizeWidth = 3
    nonisolated static let foregroundThrottle: TimeInterval = 60
    nonisolated static let labelViewMaxAge: TimeInterval = 86_400
    nonisolated static let maxHistoryRecords = 5_000

    private var db: any DatabaseWriter
    private let gmail: GmailClient
    private let outbox: Outbox
    private let status: SyncStatus
    private let settings: @Sendable () async -> Settings
    private let auth: AuthStore
    private let clock: @Sendable () -> Date
    private let badge: @Sendable (Int) async -> Void

    private var running = false
    private var rerunRequested = false
    private var queuedReasons: [SyncReason] = []
    private var cancelRequested = false
    private var runWaiters: [CheckedContinuation<Void, Never>] = []
    private var threadLoads: [String: Task<Void, any Error>] = [:]
    private var consecutiveRateLimited = 0
    private var selfAddresses: Set<String> = []
    private var generation = 0

    init(
        db: any DatabaseWriter, gmail: GmailClient, outbox: Outbox, status: SyncStatus,
        settings: @escaping @Sendable () async -> Settings, auth: AuthStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        badge: @escaping @Sendable (Int) async -> Void = SyncEngine.systemBadge
    ) {
        self.db = db
        self.gmail = gmail
        self.outbox = outbox
        self.status = status
        self.settings = settings
        self.auth = auth
        self.clock = clock
        self.badge = badge
    }

    // MARK: run — single flight

    func run(_ reason: SyncReason) async {
        if running {
            if !queuedReasons.contains(reason) { queuedReasons.append(reason) }
            rerunRequested = true
            return
        }
        running = true
        cancelRequested = false
        var reasons = [reason]
        repeat {
            rerunRequested = false
            for r in reasons { await execute(r) }
            reasons = queuedReasons
            queuedReasons = []
        } while rerunRequested && !cancelRequested && !Task.isCancelled
        running = false
        let waiters = runWaiters
        runWaiters = []
        for w in waiters { w.resume() }
    }

    private func execute(_ reason: SyncReason) async {
        guard case .signedIn = await auth.state else {
            Log.sync.notice("run skipped: not signed in")
            return
        }
        let state = (try? await db.read { try SyncStateRepository.all($0) }) ?? [:]
        let hasHistory = state[.historyId] != nil
        let hasFullSync = state[.lastFullSyncAt] != nil

        if reason == .foreground, let raw = state[.lastDeltaSyncAt], let ms = Int64(raw) {
            let last = Date(timeIntervalSince1970: Double(ms) / 1000)
            if clock().timeIntervalSince(last) < Self.foregroundThrottle {
                await outbox.rearmFailedModifies()
                await outbox.drain()
                return
            }
        }

        await setStatus {
            $0.phase = (!hasHistory && !hasFullSync) ? .initialSync : .syncing
            $0.lastRunReason = reason
        }
        selfAddresses = loadSelfAddresses(state)
        generation = Int(state[.syncGeneration] ?? "0") ?? 0
        consecutiveRateLimited = 0

        do {
            switch reason {
            case .launch, .foreground, .pullToRefresh, .background:
                if reason != .background && reason != .launch { await outbox.rearmFailedModifies() }
                try await syncCore(force: reason == .pullToRefresh)
            case .afterSend:
                try await deltaOrResync()
            case .labelOpened(let id):
                try await hydrateLabelViewIfStale(id)
                try await syncCore(force: false)
            case .loadOlderInbox:
                try await loadOlderInbox()
            case .loadOlderLabel(let id):
                try await loadOlderLabel(id)
            }
            await setStatus {
                $0.lastError = nil
                $0.lastSyncAt = self.clock()
            }
            if reason != .background { await Maintenance.cleanup(db, now: clock()) }
        } catch SyncError.paused {
        } catch SyncError.cancelled {
        } catch SyncError.rateLimitAbort {
            await setStatus { $0.lastError = GmailError.rateLimited(retryAfter: nil).userMessage }
        } catch SyncError.accountMismatch {
        } catch let e as SyncError {
            Log.sync.error(
                "run \(String(describing: reason), privacy: .public) failed: \(String(describing: e), privacy: .public)"
            )
        } catch let e as GmailError {
            await report(e)
        } catch let e as DatabaseError {
            Log.db.error("database unavailable: \(e.resultCode.rawValue, privacy: .public)")
            await setStatus { $0.lastError = "Database unavailable" }
        } catch {
            await setStatus { $0.lastError = String(describing: error) }
        }
        await setStatus { $0.phase = .idle }
        await outbox.drain()
        await updateBadge()
    }

    private func report(_ e: GmailError) async {
        switch e {
        case .offline:
            await setStatus { $0.isOffline = true }
        case .unauthorized, .cancelled:
            break
        default:
            await setStatus { $0.lastError = e.userMessage }
        }
    }

    private func syncCore(force: Bool) async throws {
        let hasHistory = try await readState(.historyId) != nil
        var didFull = false
        if !hasHistory {
            try await fullSync()
            didFull = true
        } else {
            try await deltaOrResync()
        }
        await refreshLabelCounts(force: force || didFull)
    }

    private func deltaOrResync() async throws {
        do {
            try await deltaSync()
        } catch SyncError.historyExpired, SyncError.tooManyRecords {
            Log.sync.notice("sync.history.expired")
            try await fullSync()
        }
    }

    // MARK: full sync

    private struct Identity {
        var displayName: String?
        var selfAddresses: Set<String>
        var signature: String?
    }

    private func deriveIdentity(_ profile: GmailProfile, _ sendAs: [GmailSendAs]) -> Identity {
        let preferred = sendAs.first { $0.isDefault == true } ?? sendAs.first { $0.isPrimary == true }
        var addresses = Set([profile.emailAddress.lowercased()])
        for s in sendAs where s.isPrimary == true || s.verificationStatus == "accepted" {
            addresses.insert(s.sendAsEmail.lowercased())
        }
        return Identity(displayName: preferred?.displayName, selfAddresses: addresses, signature: preferred?.signature)
    }

    private func fullSync() async throws {
        try await Log.measure(.fullSync) {
            let profile = try await call { try await self.gmail.getProfile() }
            if let cached = try await readState(.accountEmail), cached != profile.emailAddress {
                await auth.handleAccountMismatch(expected: cached, got: profile.emailAddress)
                throw SyncError.accountMismatch
            }
            let sendAs = (try? await call { try await self.gmail.listSendAs() }) ?? []
            let labels = try await call { try await self.gmail.listLabels() }
            let gen = generation + 1
            let identity = deriveIdentity(profile, sendAs)
            try checkpoint()
            try await db.write { db in
                try SyncStateRepository.set(db, .accountEmail, profile.emailAddress)
                try SyncStateRepository.set(db, .displayName, identity.displayName)
                try SyncStateRepository.set(db, .selfAddresses, LabelAlgebra.sortedJSON(identity.selfAddresses))
                try SyncStateRepository.set(db, .sendAsSignature, identity.signature)
                try SyncStateRepository.set(db, .syncGeneration, String(gen))
                try LabelRepository.replaceAll(db, labels: labels)
            }
            generation = gen
            selfAddresses = identity.selfAddresses

            let pageSize = await settings().inboxPageSize
            let page = try await call {
                try await self.gmail.listMessages(labelIds: ["INBOX"], q: nil, maxResults: pageSize, pageToken: nil)
            }
            try await hydrateMetadata(ids: (page.messages ?? []).map(\.id), generation: gen)
            try await db.write { try SyncStateRepository.set($0, .inboxNextPageToken, page.nextPageToken) }

            for labelId in try await db.read({ try LabelRepository.cachedViewLabelIds($0) }) {
                let p = try await call {
                    try await self.gmail.listMessages(labelIds: [labelId], q: nil, maxResults: 50, pageToken: nil)
                }
                try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: gen)
                try await db.write {
                    try LabelRepository.markViewFetched(
                        $0, labelId: labelId, nextPageToken: p.nextPageToken, now: self.nowMs())
                }
            }

            try checkpoint()
            let addresses = selfAddresses
            try await db.write { db in
                let stale = try MessageRepository.staleIds(db, olderThanGeneration: gen)
                let threads = Set(try MessageRecord.fetchAll(db, keys: Array(stale)).map(\.threadId))
                _ = try MessageRepository.delete(db, ids: stale)
                for t in threads { try ThreadRepository.markComplete(db, threadId: t, complete: false) }
                try ThreadRepository.recomputeAggregates(db, threadIds: threads, selfAddresses: addresses)
                try SyncStateRepository.setHistoryId(db, profile.historyId.value)
                try SyncStateRepository.set(db, .lastFullSyncAt, String(self.nowMs()))
            }
            try await deltaSync()
        }
    }

    // MARK: hydration

    private func hydrateMetadata(ids: [String], generation: Int) async throws {
        for chunk in ids.chunked(25) {
            try checkpoint()
            let results = try await call { try await self.gmail.getMessages(ids: chunk, format: .metadata) }
            try await Log.measure(.hydrateBatch) {
                var parsed: [ParsedMessage] = []
                for (id, r) in results {
                    switch r {
                    case .success(let m): parsed.append(MessageParser.parse(m))
                    case .failure(.notFound): break
                    case .failure(let e):
                        Log.sync.error("hydrate \(id, privacy: .public) \(String(describing: e), privacy: .public)")
                    }
                }
                let sawRateLimit = results.values.contains {
                    if case .failure(.rateLimited) = $0 { return true } else { return false }
                }
                try await noteResult(sawRateLimit ? .rateLimited(retryAfter: nil) : nil)
                if parsed.isEmpty { return }
                let batch = parsed
                let addresses = selfAddresses
                let now = nowMs()
                try await db.write { db in
                    let touched = try MessageRepository.upsertMetadata(
                        db, parsed: batch, selfAddresses: addresses, generation: generation, now: now)
                    try ThreadRepository.recomputeAggregates(db, threadIds: touched, selfAddresses: addresses)
                }
            }
        }
    }

    // MARK: delta sync

    private func deltaSync() async throws {
        try await Log.measure(.deltaSync) {
            guard let raw = try await self.readState(.historyId), let start = UInt64(raw) else {
                throw SyncError.historyExpired
            }
            var pages: [GmailListHistoryResponse] = []
            var token: String? = nil
            var count = 0
            repeat {
                let pageToken = token
                let page = try await self.call {
                    try await self.gmail.listHistory(startHistoryId: start, pageToken: pageToken)
                }
                pages.append(page)
                token = page.nextPageToken
                count += page.history?.count ?? 0
                if count > Self.maxHistoryRecords { throw SyncError.tooManyRecords }
            } while token != nil

            let changes = HistoryReducer.reduce(pages)
            let mentioned = Array(changes.mentionedIds)
            let touchedThreads = Array(changes.touchedThreads)
            let (existing, cachedViews, known) = try await self.db.read { db in
                (
                    try MessageRepository.idsExisting(db, among: mentioned),
                    try LabelRepository.cachedViewLabelIds(db),
                    Set(try ThreadRecord.fetchAll(db, keys: touchedThreads).map(\.id))
                )
            }
            let scope = HydrationScope(cachedLabelIds: Set(["INBOX"] + cachedViews), knownThreadIds: known)
            var toFetch =
                changes.added.filter { id, ref in
                    !existing.contains(id) && HydrationPolicy.shouldFetch(ref: ref, scope: scope)
                }.map(\.key)
            toFetch +=
                changes.labelOps.filter { id, deltas in
                    !existing.contains(id) && changes.added[id] == nil
                        && deltas.contains { !$0.add.isDisjoint(with: scope.cachedLabelIds) }
                }.map(\.key)
            try await self.hydrateMetadata(ids: toFetch.sorted(), generation: self.generation)

            try self.checkpoint()
            let addresses = self.selfAddresses
            let now = self.nowMs()
            try await self.db.write { db in
                var touched = try MessageRepository.delete(db, ids: changes.deleted.intersection(existing))
                var relabeled = Set<String>()
                for id in existing.subtracting(changes.deleted) {
                    if let final = changes.finalLabels[id] {
                        try MessageRepository.applyServerLabels(db, messageId: id, labels: final)
                        relabeled.insert(id)
                    } else if let ops = changes.labelOps[id], !ops.isEmpty {
                        for d in ops { try MessageRepository.applyServerDelta(db, messageId: id, delta: d) }
                        relabeled.insert(id)
                    }
                }
                touched.formUnion(try MessageRepository.recomputeEffective(db, messageIds: relabeled))
                try ThreadRepository.recomputeAggregates(db, threadIds: touched, selfAddresses: addresses)
                let newId = max(start, changes.newHistoryId ?? start)
                try SyncStateRepository.setHistoryId(db, newId)
                try SyncStateRepository.set(db, .lastDeltaSyncAt, String(now))
            }
        }
    }

    // MARK: label views and load older

    private func hydrateLabelViewIfStale(_ id: String) async throws {
        guard let label = try await db.read({ try LabelRecord.fetchOne($0, key: id) }) else { return }
        if let at = label.viewFetchedAt, Double(nowMs() - at) / 1000 < Self.labelViewMaxAge { return }
        let p = try await call {
            try await self.gmail.listMessages(labelIds: [id], q: nil, maxResults: 50, pageToken: nil)
        }
        try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: generation)
        try await db.write {
            try LabelRepository.markViewFetched($0, labelId: id, nextPageToken: p.nextPageToken, now: self.nowMs())
        }
    }

    private func loadOlderInbox() async throws {
        guard let token = try await readState(.inboxNextPageToken) else { return }
        let pageSize = await settings().inboxPageSize
        let p = try await call {
            try await self.gmail.listMessages(labelIds: ["INBOX"], q: nil, maxResults: pageSize, pageToken: token)
        }
        try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: generation)
        try await db.write { try SyncStateRepository.set($0, .inboxNextPageToken, p.nextPageToken) }
    }

    private func loadOlderLabel(_ id: String) async throws {
        guard let label = try await db.read({ try LabelRecord.fetchOne($0, key: id) }),
            let token = label.viewNextPageToken
        else { return }
        let p = try await call {
            try await self.gmail.listMessages(labelIds: [id], q: nil, maxResults: 50, pageToken: token)
        }
        try await hydrateMetadata(ids: (p.messages ?? []).map(\.id), generation: generation)
        try await db.write {
            try LabelRepository.markViewFetched($0, labelId: id, nextPageToken: p.nextPageToken, now: self.nowMs())
        }
    }

    // MARK: ensureThreadLoaded

    func ensureThreadLoaded(threadId: String) async throws {
        if let existing = threadLoads[threadId] { return try await existing.value }
        let task = Task { [self] in try await self.loadThread(threadId) }
        threadLoads[threadId] = task
        defer { threadLoads[threadId] = nil }
        try await task.value
    }

    private func loadThread(_ threadId: String) async throws {
        try await Log.measure(.threadOpen) {
            // One read, not three: this sits directly in front of the request the open is waiting on, and
            // `syncGeneration` is part of the same state row set `all` already returns.
            let (state, record) = try await self.db.read { db in
                (try SyncStateRepository.all(db), try ThreadRecord.fetchOne(db, key: threadId))
            }
            self.selfAddresses = self.loadSelfAddresses(state)
            self.generation = Int(state[.syncGeneration] ?? "0") ?? 0
            guard let t = record else { return }
            let addresses = self.selfAddresses

            if !t.isComplete {
                let thread: GmailThread
                do {
                    thread = try await self.call { try await self.gmail.getThread(id: threadId, format: .full) }
                } catch GmailError.notFound {
                    try await self.db.write { db in
                        let ids = try ThreadRepository.messageIds(db, threadId: threadId)
                        let touched = try MessageRepository.delete(db, ids: Set(ids))
                        try ThreadRepository.recomputeAggregates(
                            db, threadIds: touched.union([threadId]), selfAddresses: addresses)
                    }
                    return
                }
                // The messages 10 opens expanded are sanitised and written first, so the screen paints what the
                // user is looking at without waiting for the quoted history below it. Metadata for the WHOLE
                // thread rides the first transaction: the section list, the message count and the unread state
                // are then already final, which leaves the second commit a body-only change 10 can patch into
                // the live document instead of reloading it.
                let all = thread.messages ?? []
                let parsed = all.map { MessageParser.parse($0) }
                let opening = Set(SyncEngine.openingIndices(all))
                let rest = all.indices.filter { !opening.contains($0) }
                try await self.commitBodies(
                    opening.sorted().map { (all[$0], parsed[$0]) }, metadata: parsed, threadId: threadId,
                    addresses: addresses, markingComplete: rest.isEmpty)
                if !rest.isEmpty {
                    try await self.commitBodies(
                        rest.map { (all[$0], parsed[$0]) }, metadata: [], threadId: threadId,
                        addresses: addresses, markingComplete: true)
                }
            } else {
                let missing = try await self.db.read {
                    try BodyRepository.missingBodyIds($0, threadId: threadId, sanitizerVersion: Sanitizer.version)
                }
                if missing.isEmpty { return }
                for chunk in missing.chunked(10) {
                    try await Log.measure(.bodyLoad) {
                        let results = try await self.call {
                            try await self.gmail.getMessages(ids: chunk, format: .full)
                        }
                        var raws: [RawBody] = []
                        var goneBuilt = Set<String>()
                        var unavailableBuilt = Set<String>()
                        for (id, r) in results {
                            switch r {
                            case .success(let m):
                                if m.payload == nil {
                                    unavailableBuilt.insert(id)
                                } else {
                                    raws.append(try await self.fetchBody(m, parsed: MessageParser.parse(m)))
                                }
                            case .failure(.notFound): goneBuilt.insert(id)
                            case .failure(let e):
                                Log.sync.error(
                                    "body \(id, privacy: .public) \(String(describing: e), privacy: .public)")
                            }
                        }
                        let prepared = await SyncEngine.sanitizeAll(raws)
                        let gone = goneBuilt
                        let unavailable = unavailableBuilt
                        try self.checkpoint()
                        let now = self.nowMs()
                        try await self.db.write { db in
                            var touched = try MessageRepository.delete(db, ids: gone)
                            for p in prepared {
                                try BodyRepository.storeBody(
                                    db, messageId: p.parsed.id, body: p.body, text: p.text,
                                    attachments: p.parsed.attachments, referenced: p.referenced,
                                    sanitizerVersion: Sanitizer.version, now: now)
                                try MessageRepository.applyServerLabels(
                                    db, messageId: p.parsed.id, labels: Set(p.parsed.labelIds))
                            }
                            for id in unavailable { try BodyRepository.markUnavailable(db, messageId: id) }
                            touched.formUnion(
                                try MessageRepository.recomputeEffective(
                                    db, messageIds: Set(prepared.map(\.parsed.id))))
                            try ThreadRepository.recomputeAggregates(
                                db, threadIds: touched.union([threadId]), selfAddresses: addresses)
                        }
                    }
                }
            }
        }
    }

    /// Indices of the messages `ThreadModel` renders expanded on open — every unread one plus the newest
    /// (architecture §8.2) — in ascending order. Never empty for a non-empty thread: the newest always
    /// qualifies, so the first commit always carries something to paint.
    nonisolated static func openingIndices(_ messages: [GmailMessage]) -> [Int] {
        guard messages.count > 1 else { return Array(messages.indices) }
        let newestId = messages.max { ($0.internalDate?.value ?? 0) < ($1.internalDate?.value ?? 0) }?.id
        return messages.indices.filter {
            messages[$0].id == newestId || (messages[$0].labelIds?.contains("UNREAD") ?? false)
        }
    }

    /// Prepares one group of messages and writes it in a single transaction, upserting `metadata` alongside
    /// (the whole thread's, on the first call; empty afterwards, since it is already in). Only the last group
    /// passes `markingComplete`, so a run that dies half-way leaves `isComplete` false and the next open
    /// refetches the whole thread rather than trusting a partial one.
    private func commitBodies(
        _ group: [(message: GmailMessage, parsed: ParsedMessage)], metadata: [ParsedMessage], threadId: String,
        addresses: Set<String>, markingComplete: Bool
    ) async throws {
        var raws: [RawBody] = []
        for m in group { raws.append(try await self.fetchBody(m.message, parsed: m.parsed)) }
        let prepared = await SyncEngine.sanitizeAll(raws)
        try self.checkpoint()
        let now = self.nowMs()
        let gen = self.generation
        try await self.db.write { db in
            let touched = try MessageRepository.upsertMetadata(
                db, parsed: metadata, selfAddresses: addresses, generation: gen, now: now)
            for p in prepared {
                try BodyRepository.storeBody(
                    db, messageId: p.parsed.id, body: p.body, text: p.text, attachments: p.parsed.attachments,
                    referenced: p.referenced, sanitizerVersion: Sanitizer.version, now: now)
                try MessageRepository.applyServerLabels(
                    db, messageId: p.parsed.id, labels: Set(p.parsed.labelIds))
            }
            _ = try MessageRepository.recomputeEffective(db, messageIds: Set(prepared.map(\.parsed.id)))
            if markingComplete { try ThreadRepository.markComplete(db, threadId: threadId, complete: true) }
            try ThreadRepository.recomputeAggregates(
                db, threadIds: touched.union([threadId]), selfAddresses: addresses)
        }
    }

    /// The actor-side half of preparing a body: parse, and fetch a deferred text part when Gmail delivered the
    /// only text part by id. Everything here either touches actor state or goes through `call`.
    private func fetchBody(_ msg: GmailMessage, parsed: ParsedMessage) async throws -> RawBody {
        var html = parsed.body?.html
        var text = parsed.body?.text
        if html == nil && text == nil, let part = parsed.body?.deferredTextParts.first,
            let attId = part.attachmentId
        {
            if let data = try? await call({
                try await self.gmail.getAttachment(messageId: msg.id, attachmentId: attId)
            }) {
                let decoded = MessageParser.decodeText(bytes: data, charset: part.charset)
                if part.mimeType == "text/html" { html = decoded } else { text = decoded }
            }
        }
        return RawBody(parsed: parsed, html: html, text: text, snippet: msg.snippet)
    }

    /// The CPU-bound half: SwiftSoup. Runs off the actor, so a multi-megabyte newsletter cannot block every
    /// other sync operation while it parses.
    nonisolated private static func sanitize(_ raw: RawBody) -> PreparedBody {
        let body: SanitizedBody
        if let h = raw.html, h.utf8.count <= Sanitizer.maxInputBytes,
            let s = try? Sanitizer.sanitize(html: h, messageId: raw.parsed.id)
        {
            body = s
        } else if let t = raw.text {
            body = Sanitizer.fromPlainText(t)
        } else if let sn = raw.snippet, !sn.isEmpty {
            body = Sanitizer.fromPlainText(sn)
        } else {
            body = Sanitizer.fromPlainText("This message could not be displayed.")
            Log.web.error("web.sanitize.failed \(raw.parsed.id, privacy: .public)")
        }
        return PreparedBody(parsed: raw.parsed, body: body, text: raw.text, referenced: body.referencedContentIDs)
    }

    /// Sanitises a group off the actor, at most `sanitizeWidth` at a time. `Sanitizer` holds no mutable state,
    /// so the cap is about memory and thermals on a phone, not correctness. Input order is preserved.
    nonisolated private static func sanitizeAll(_ raws: [RawBody]) async -> [PreparedBody] {
        guard raws.count > 1 else { return raws.map(sanitize) }
        return await withTaskGroup(of: (Int, PreparedBody).self) { group in
            var results = [PreparedBody?](repeating: nil, count: raws.count)
            var next = 0
            for _ in 0..<min(sanitizeWidth, raws.count) {
                let index = next
                next += 1
                group.addTask { return (index, sanitize(raws[index])) }
            }
            while let (index, prepared) = await group.next() {
                results[index] = prepared
                if next < raws.count {
                    let following = next
                    next += 1
                    group.addTask { return (following, sanitize(raws[following])) }
                }
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: label counts

    func refreshLabelCounts(force: Bool) async {
        guard case .signedIn = await auth.state else { return }
        if !force, let raw = try? await readState(.lastLabelCountsAt), let at = Int64(raw ?? ""),
            Double(nowMs() - at) / 1000 < Self.labelCountsStaleness
        {
            return
        }
        do {
            let labels = try await call { try await self.gmail.listLabels() }
            try await db.write { try LabelRepository.replaceAll($0, labels: labels) }
            var ids = ["INBOX", "STARRED", "IMPORTANT", "SENT"].filter { id in labels.contains { $0.id == id } }
            ids += labels.filter { $0.type == "user" && $0.labelListVisibility != "labelHide" }.map(\.id).sorted()
            let selected = Array(ids.prefix(60))
            let results = try await call { try await self.gmail.getLabels(ids: selected) }
            let fetched = results.compactMap { try? $0.value.get() }
            let now = nowMs()
            try await db.write { db in
                try LabelRepository.updateCounts(db, labels: fetched, now: now)
                try SyncStateRepository.set(db, .lastLabelCountsAt, String(now))
            }
        } catch let e as GmailError {
            await report(e)
        } catch {
        }
    }

    // MARK: misc entry points

    func requestFullResync() async {
        try? await db.write { try SyncStateRepository.set($0, .historyId, nil) }
        await run(.pullToRefresh)
    }

    func updateBadge() async {
        guard await settings().showBadge else { return }
        let n = try? await db.read { try Queries.inboxUnreadThreadCount($0) }
        await badge(n ?? 0)
    }

    func cancelAll() async {
        cancelRequested = true
        for t in threadLoads.values { t.cancel() }
        if running {
            await withCheckedContinuation { runWaiters.append($0) }
        }
    }

    func replaceDatabase(_ db: any DatabaseWriter) {
        precondition(!running, "replaceDatabase while running")
        self.db = db
    }

    var isRunning: Bool { running }

    nonisolated static func systemBadge(_ count: Int) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.badgeSetting == .enabled else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // MARK: helpers

    private nonisolated func nowMs() -> Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

    private func checkpoint() throws {
        if Task.isCancelled || cancelRequested { throw SyncError.cancelled }
    }

    private func setStatus(_ mutate: @escaping @MainActor @Sendable (SyncStatus) -> Void) async {
        await MainActor.run { mutate(status) }
    }

    private func noteResult(_ error: GmailError?) async throws {
        switch error {
        case nil:
            consecutiveRateLimited = 0
            await setStatus { $0.isOffline = false }
        case .offline:
            await setStatus { $0.isOffline = true }
        case .rateLimited:
            consecutiveRateLimited += 1
            if consecutiveRateLimited >= 3 { throw SyncError.rateLimitAbort }
        case .unauthorized:
            await auth.markNeedsReauth()
        default:
            break
        }
    }

    private func call<T>(_ op: @Sendable () async throws -> T) async throws -> T {
        try checkpoint()
        do {
            let result = try await op()
            try await noteResult(nil)
            return result
        } catch let e as GmailError {
            try await noteResult(e)
            if e == .historyExpired { throw SyncError.historyExpired }
            throw e
        } catch is CancellationError {
            throw SyncError.cancelled
        }
    }

    private func readState(_ key: SyncKey) async throws -> String? {
        try await db.read { try SyncStateRepository.get($0, key) }
    }

    private func loadSelfAddresses(_ state: [SyncKey: String]) -> Set<String> {
        var addresses = state[.selfAddresses].map(LabelAlgebra.parseJSON) ?? []
        if let email = state[.accountEmail] { addresses.insert(email.lowercased()) }
        return addresses
    }
}
