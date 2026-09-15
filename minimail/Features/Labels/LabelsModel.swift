import Foundation
import GRDB
import MailCore
import Observation

/// One fully precomputed row of the labels sheet — a mailbox row (Inbox / Today) or a label row. Everything the view
/// needs is a `String`; `body` performs no formatting and no colour parsing beyond `LabelChip.color(hex:)`.
nonisolated struct LabelRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let countText: String?
    let symbol: String?
    let colorHex: String?
    let scope: InboxScope
    let accessibilityLabel: String
    let accessibilityValue: String?
}

/// What the Labels section shows when it has no label rows (§4.6).
nonisolated enum LabelsEmptyState: Equatable, Sendable {
    case initialSync
    case noLabels
    case unavailable
}

/// One fetch of everything the sheet shows. `Equatable` so `removeDuplicates()` suppresses ticks from writes to
/// unrelated tables that do not change a count.
nonisolated private struct LabelsAux: Equatable, Sendable {
    var labels: [LabelRecord]
    var inboxUnread: Int
    var today: Int
    var lastLabelCountsAt: Int64?
}

/// Main-actor model of the labels sheet (architecture §8.2). One instance per sheet presentation.
@Observable final class LabelsModel {

    // ---- constants ----
    static let countsStaleness: TimeInterval = SyncEngine.labelCountsStaleness
    /// Label ids dropped from the Labels section because the Mailboxes section shows them with a local count (D1).
    static let hiddenLabelIds: Set<String> = ["INBOX"]
    nonisolated static let systemDisplayNames: [String: String] = [
        "INBOX": "Inbox", "STARRED": "Starred", "IMPORTANT": "Important", "SENT": "Sent",
        "DRAFT": "Drafts", "SPAM": "Spam", "TRASH": "Trash",
    ]
    nonisolated static let systemSymbols: [String: String] = [
        "INBOX": "tray", "STARRED": "star", "IMPORTANT": "bookmark", "SENT": "paperplane",
        "DRAFT": "doc", "SPAM": "xmark.bin", "TRASH": "trash",
    ]
    nonisolated static let maxDisplayedCount = 999

    let env: AppEnvironment

    // ---- observed state ----
    private(set) var mailboxRows: [LabelRow] = []
    private(set) var labelRows: [LabelRow] = []
    private(set) var inboxUnreadCount: Int = 0
    private(set) var todayCount: Int = 0
    private(set) var countsFetchedAt: Date?
    private(set) var isRefreshing: Bool = false
    /// Number of `refreshLabelCounts(force:)` calls this model made — observable so tests assert the throttle.
    private(set) var countsRefreshes: Int = 0
    private(set) var openedLabelIds: [String] = []
    private(set) var lastSelected: InboxScope?
    private(set) var didCheckStaleness: Bool = false
    private(set) var observationError: String?

    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let day: DayBoundary

    // ---- derived ----
    var emptyState: LabelsEmptyState? {
        guard labelRows.isEmpty else { return nil }
        if observationError != nil { return .unavailable }
        if env.syncStatus.phase == .initialSync { return .initialSync }
        return .noLabels
    }

    var footerText: String {
        LabelsModel.footer(
            countsFetchedAt: countsFetchedAt, now: clock(), isOffline: env.syncStatus.isOffline,
            isRefreshing: isRefreshing)
    }

    init(env: AppEnvironment, clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.env = env
        self.clock = clock
        self.timeZone = timeZone
        self.day = DayBoundary.today(now: clock(), timeZone: timeZone)
        start()
    }

    /// Called once from `LabelsScreen.task`. Performs the sheet-open staleness check (§4.7). Idempotent.
    func appeared() async {
        guard !didCheckStaleness else { return }
        didCheckStaleness = true
        let at = countsFetchedAt
        if at == nil || clock().timeIntervalSince(at!) >= Self.countsStaleness {
            await refreshCounts()
        }
    }

    /// Pull-to-refresh: restart a failed observation, then always force a label-count refresh (§4.7).
    func refresh() async {
        if observationError != nil { start() }
        await refreshCounts()
    }

    /// Row tap (§4.8). Records the selection and, for a label, fires the single-flight `.labelOpened` sync.
    /// Does not dismiss the sheet and does not call `onSelect` — the screen does that.
    func select(_ scope: InboxScope) {
        lastSelected = scope
        if case .label(let id) = scope {
            openedLabelIds.append(id)
            Log.ui.debug("labels.select \(id, privacy: .public)")
            Task { await env.sync.run(.labelOpened(id)) }
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    // ---- observation ----

    private func start() {
        cancellable?.cancel()
        let day = self.day
        cancellable =
            ValueObservation
            .tracking { db in
                LabelsAux(
                    labels: try Queries.labelsForSheet(db),
                    inboxUnread: try Queries.inboxUnreadThreadCount(db),
                    today: try Queries.todayThreadCount(db, day),
                    lastLabelCountsAt: try SyncStateRepository.get(db, .lastLabelCountsAt).flatMap(Int64.init))
            }
            .removeDuplicates()
            .start(
                in: env.db, scheduling: .immediate,
                onError: { [weak self] e in MainActor.assumeIsolated { self?.observationFailed(e) } },
                onChange: { [weak self] aux in MainActor.assumeIsolated { self?.apply(aux) } })
    }

    private func apply(_ aux: LabelsAux) {
        inboxUnreadCount = aux.inboxUnread
        todayCount = aux.today
        mailboxRows = LabelsModel.mailboxRows(inboxUnread: aux.inboxUnread, today: aux.today)
        labelRows = aux.labels.filter { !LabelsModel.hiddenLabelIds.contains($0.id) }.map(LabelsModel.row(for:))
        countsFetchedAt = aux.lastLabelCountsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        observationError = nil
    }

    private func refreshCounts() async {
        isRefreshing = true
        countsRefreshes += 1
        await env.sync.refreshLabelCounts(force: true)
        isRefreshing = false
    }

    private func observationFailed(_ error: any Error) {
        Log.ui.error("labels observation failed: \(String(describing: error), privacy: .public)")
        observationError = String(describing: error)
    }

    // ---- pure helpers (unit-tested in §7.2) ----

    nonisolated static func displayName(for label: LabelRecord) -> String {
        if label.type == "system" { return systemDisplayNames[label.id] ?? label.name }
        return label.name
    }

    nonisolated static func symbol(for label: LabelRecord) -> String? {
        if label.isUser, label.backgroundColor != nil { return nil }
        if label.type == "system" { return systemSymbols[label.id] ?? "tag" }
        return "tag"
    }

    nonisolated static func countText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > maxDisplayedCount ? "999+" : String(count)
    }

    nonisolated static func row(for label: LabelRecord) -> LabelRow {
        let title = displayName(for: label)
        let count = countText(label.threadsUnread)
        return LabelRow(
            id: label.id, title: title, countText: count, symbol: symbol(for: label),
            colorHex: (label.isUser && label.backgroundColor != nil) ? label.backgroundColor : nil,
            scope: .label(id: label.id), accessibilityLabel: title,
            accessibilityValue: count.map { "\($0) unread" })
    }

    nonisolated static func mailboxRows(inboxUnread: Int, today: Int) -> [LabelRow] {
        let inbox = countText(inboxUnread)
        let todayText = countText(today)
        return [
            LabelRow(
                id: "mailbox.inbox", title: "Inbox", countText: inbox, symbol: "tray", colorHex: nil,
                scope: .inbox, accessibilityLabel: "Inbox", accessibilityValue: inbox.map { "\($0) unread" }),
            LabelRow(
                id: "mailbox.today", title: "Today", countText: todayText, symbol: "sun.max", colorHex: nil,
                scope: .today, accessibilityLabel: "Today", accessibilityValue: todayText.map { "\($0) today" }),
        ]
    }

    nonisolated static func footer(countsFetchedAt: Date?, now: Date, isOffline: Bool, isRefreshing: Bool) -> String {
        if isRefreshing { return "Updating counts from Gmail…" }
        if isOffline { return "Counts from Gmail · offline" }
        guard let at = countsFetchedAt else { return "Counts from Gmail · not loaded yet" }
        let s = max(0, now.timeIntervalSince(at))
        if s < 60 { return "Counts from Gmail · updated just now" }
        if s < 3600 { return "Counts from Gmail · updated \(Int(s / 60)) min ago" }
        if s < 86_400 { return "Counts from Gmail · updated \(Int(s / 3600)) h ago" }
        return "Counts from Gmail · updated \(Int(s / 86_400)) d ago"
    }

    #if DEBUG
        /// Test hook: feeds `observationFailed` with a synthetic error. Never called by production code.
        func _simulateObservationError(_ text: String) {
            observationFailed(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text]))
        }
    #endif
}
