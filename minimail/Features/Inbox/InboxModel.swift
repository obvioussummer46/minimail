import Foundation
import GRDB
import MailCore
import Observation

/// Which mailbox the list shows.
nonisolated enum InboxScope: Hashable, Sendable {
    case inbox
    case today
    /// A Gmail label id, e.g. `"Label_12"`. Never `"INBOX"` (that is `.inbox`).
    case label(id: String)
}

/// Navigation value pushed by a thread row (architecture §8.1).
nonisolated struct ThreadRoute: Hashable, Sendable {
    let threadId: String
    init(threadId: String) { self.threadId = threadId }
}

/// Input of `ComposeScreen(input:)` (module 11).
nonisolated enum ComposeInput: Equatable, Sendable, Identifiable {
    case fromMessage(mode: ComposeMode, threadId: String, messageId: String)
    case failedSend(outboxId: Int64, job: SendJob)
    var id: String {
        switch self {
        case .fromMessage(let mode, _, let messageId): return "message:\(mode.rawValue):\(messageId)"
        case .failedSend(let outboxId, _): return "failedSend:\(outboxId)"
        }
    }
}

/// The single sheet slot of the inbox (architecture §8.1).
enum ActiveSheet: Identifiable, Equatable {
    case labels
    case settings
    case compose(ComposeInput)
    var id: String {
        switch self {
        case .labels: return "labels"
        case .settings: return "settings"
        case .compose(let input): return "compose:" + input.id
        }
    }
}

/// The status row shown above the threads. At most one is visible (priority order in `InboxModel.banner`).
enum InboxBanner: Equatable {
    case reauth
    case offline
    case error(String)
}

/// What the list shows when it has no thread rows (§4.7).
enum InboxEmptyState: Equatable {
    case initialSync
    case allCaughtUp
    case noMail
    case nothingToday
    case noMessages
}

/// One fetch of everything the screen needs besides the rows (§4.3).
nonisolated private struct InboxAux: Equatable, Sendable {
    var labels: [String: LabelRecord]
    var inboxUnread: Int
    var today: Int
    var failedSends: [OutboxRecord]
    var inboxNextPageToken: String?
}

/// Main-actor model of the inbox list (architecture §8.2).
@Observable final class InboxModel {

    static let pageSize: Int = ThreadQuery.pageSize
    static let maxAutoOlderLoads = 3

    let env: AppEnvironment

    private(set) var scope: InboxScope
    private(set) var unreadOnly: Bool = false
    private(set) var limit: Int = InboxModel.pageSize
    private(set) var day: DayBoundary
    private(set) var rows: [ThreadRow] = []
    private(set) var labels: [String: LabelRecord] = [:]
    private(set) var inboxUnreadCount: Int = 0
    private(set) var todayCount: Int = 0
    private(set) var failedSends: [OutboxRecord] = []
    private(set) var hasOlder: Bool = false
    private(set) var isLoadingOlder: Bool = false
    private(set) var observationError: String?
    var activeSheet: ActiveSheet?
    private(set) var lastActionId: Int = 0
    private(set) var filterChangeId: Int = 0
    private(set) var reauthBannerDismissed: Bool = false

    @ObservationIgnored private var threadsCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var auxCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var chipFingerprint: [String: ThreadChip] = [:]
    @ObservationIgnored private var lastInboxToken: String?
    @ObservationIgnored private var lastAppearedId: String?
    @ObservationIgnored private var autoOlderLoads: Int = 0
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timeZone: TimeZone
    @ObservationIgnored private let locale: Locale

    // MARK: derived

    var query: ThreadQuery {
        let s: ThreadQuery.Scope
        switch scope {
        case .inbox: s = .inbox
        case .today: s = .today(day)
        case .label(let id): s = .label(id: id)
        }
        return ThreadQuery(scope: s, unreadOnly: unreadOnly, limit: limit)
    }

    var title: String {
        switch scope {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .label(let id): return labels[id]?.name ?? id
        }
    }

    var banner: InboxBanner? {
        if case .needsReauth = env.auth.state, !reauthBannerDismissed { return .reauth }
        if env.syncStatus.isOffline { return .offline }
        if let e = env.syncStatus.lastError { return .error(e) }
        if observationError != nil { return .error("Database unavailable") }
        return nil
    }

    var emptyState: InboxEmptyState? {
        guard rows.isEmpty else { return nil }
        if env.syncStatus.phase == .initialSync { return .initialSync }
        if unreadOnly { return .allCaughtUp }
        switch scope {
        case .inbox: return .noMail
        case .today: return .nothingToday
        case .label: return .noMessages
        }
    }

    var olderReason: SyncReason {
        switch scope {
        case .inbox, .today: return .loadOlderInbox
        case .label(let id): return .loadOlderLabel(id)
        }
    }

    // MARK: init

    init(
        env: AppEnvironment, scope: InboxScope, clock: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) {
        self.env = env
        self.scope = scope
        self.clock = clock
        self.timeZone = timeZone
        self.locale = locale
        self.day = DayBoundary.today(now: clock(), timeZone: timeZone)
        startAux()
        startThreads()
    }

    // MARK: observations

    private func startThreads() {
        threadsCancellable?.cancel()
        let fetch = Queries.threads(query, now: clock(), timeZone: timeZone, locale: locale, labels: labels)
        threadsCancellable =
            ValueObservation
            .trackingConstantRegion(fetch)
            .removeDuplicates()
            .start(
                in: env.db, scheduling: .immediate,
                onError: { [weak self] error in MainActor.assumeIsolated { self?.observationFailed(error) } },
                onChange: { [weak self] rows in MainActor.assumeIsolated { self?.rows = rows } })
    }

    private func startAux() {
        auxCancellable?.cancel()
        let day = self.day
        auxCancellable =
            ValueObservation
            .tracking { db in
                InboxAux(
                    labels: try Queries.labelsById(db),
                    inboxUnread: try Queries.inboxUnreadThreadCount(db),
                    today: try Queries.todayThreadCount(db, day),
                    failedSends: try Queries.failedSends(db),
                    inboxNextPageToken: try SyncStateRepository.get(db, .inboxNextPageToken))
            }
            .removeDuplicates()
            .start(
                in: env.db, scheduling: .immediate,
                onError: { [weak self] e in MainActor.assumeIsolated { self?.observationFailed(e) } },
                onChange: { [weak self] aux in MainActor.assumeIsolated { self?.apply(aux) } })
    }

    private func apply(_ aux: InboxAux) {
        labels = aux.labels
        inboxUnreadCount = aux.inboxUnread
        todayCount = aux.today
        failedSends = aux.failedSends
        recomputeHasOlder(inboxToken: aux.inboxNextPageToken)
        let fp = aux.labels.mapValues {
            ThreadChip(id: $0.id, name: $0.name, textColor: $0.textColor, backgroundColor: $0.backgroundColor)
        }
        if fp != chipFingerprint {
            chipFingerprint = fp
            if threadsCancellable != nil { startThreads() }
        }
    }

    private func recomputeHasOlder(inboxToken: String?) {
        lastInboxToken = inboxToken
        switch scope {
        case .inbox, .today: hasOlder = (inboxToken != nil)
        case .label(let id): hasOlder = (labels[id]?.viewNextPageToken != nil)
        }
    }

    private func observationFailed(_ error: any Error) {
        Log.ui.error("inbox observation failed: \(String(describing: error), privacy: .public)")
        observationError = String(describing: error)
    }

    // MARK: filters

    func setScope(_ scope: InboxScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        limit = Self.pageSize
        autoOlderLoads = 0
        filterChangeId += 1
        recomputeHasOlder(inboxToken: lastInboxToken)
        startThreads()
    }

    func toggleUnreadOnly() {
        unreadOnly.toggle()
        limit = Self.pageSize
        autoOlderLoads = 0
        filterChangeId += 1
        startThreads()
    }

    // MARK: paging

    func rowAppeared(_ threadId: String) {
        lastAppearedId = threadId
        guard observationError == nil else { return }
        guard threadId == rows.last?.id else { return }
        if rows.count >= limit {
            limit += Self.pageSize
            autoOlderLoads = 0
            startThreads()
            return
        }
        guard hasOlder, !isLoadingOlder else { return }
        loadOlder()
    }

    private func loadOlder() {
        isLoadingOlder = true
        let before = rows.count
        let reason = olderReason
        Task { [weak self] in
            guard let self else { return }
            await env.sync.run(reason)
            await Task.yield()
            isLoadingOlder = false
            if rows.count > before {
                autoOlderLoads = 0
                return
            }
            if hasOlder, autoOlderLoads < Self.maxAutoOlderLoads, rows.last?.id == lastAppearedId {
                autoOlderLoads += 1
                loadOlder()
            }
        }
    }

    func refresh() async {
        if observationError != nil {
            observationError = nil
            startAux()
            startThreads()
        }
        await env.sync.run(.pullToRefresh)
    }

    // MARK: day change

    func dayChanged(now: Date = Date(), timeZone: TimeZone = .current) {
        let d = DayBoundary.today(now: now, timeZone: timeZone)
        guard d != day || timeZone.identifier != self.timeZone.identifier else { return }
        day = d
        self.timeZone = timeZone
        startAux()
        startThreads()
    }

    // MARK: actions

    func archive(threadId: String) {
        lastActionId += 1
        Task { await env.actions.archive(threadId: threadId) }
    }

    func toggleRead(threadId: String, isUnread: Bool) {
        lastActionId += 1
        Task {
            if isUnread {
                await env.actions.markRead(threadId: threadId)
            } else {
                await env.actions.markUnread(threadId: threadId)
            }
        }
    }

    func retrySend(_ outboxId: Int64) {
        Task { await env.outbox.retrySend(id: outboxId) }
    }

    func discardSend(_ outboxId: Int64) {
        lastActionId += 1
        Task { await env.outbox.discardSend(id: outboxId) }
    }

    func openFailedSend(_ record: OutboxRecord) {
        guard record.kind == .send, let job = record.sendJob else {
            Log.ui.error("openFailedSend: outbox row \(record.id, privacy: .public) is not a failed send")
            return
        }
        activeSheet = .compose(.failedSend(outboxId: record.id, job: job))
    }

    func dismissReauthBanner() {
        reauthBannerDismissed = true
    }

    func authStateChanged(_ state: AuthStore.State) {
        if case .signedIn = state { reauthBannerDismissed = false }
    }

    func stop() {
        threadsCancellable?.cancel()
        threadsCancellable = nil
        auxCancellable?.cancel()
        auxCancellable = nil
    }

    #if DEBUG
        func _simulateObservationError(_ text: String) {
            observationError = text
        }
    #endif
}
