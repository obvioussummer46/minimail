import GRDB
import MailCore
import XCTest

@testable import minimail

/// Spec 12 §7.1. Drives `LabelsModel` against `AppEnvironment(testing: true)` (temporary pool, offline transport,
/// `auth == .signedOut`), so `refreshLabelCounts`/`labelOpened` do no network and the assertions are this module's
/// own decisions.
nonisolated final class LabelsModelTests: XCTestCase {
    private var env: AppEnvironment!
    private var model: LabelsModel!
    private let seedNow: Int64 = 1_757_500_000_000
    private let fixed = Date(timeIntervalSince1970: 1_757_500_000)
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        model?.stop()
        await env.sync.cancelAll()
        await env.outbox.cancelAll()
        model = nil
        env = nil
    }

    @MainActor private func row(_ id: String) -> LabelRow { model.labelRows.first { $0.id == id }! }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func setLastCounts(_ ms: Int64) async throws {
        try await env.db.write { try SyncStateRepository.set($0, .lastLabelCountsAt, String(ms)) }
    }

    // MARK: - immediate rows

    @MainActor
    func testImmediateRowsOnInit() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env, clock: { self.fixed }, timeZone: berlin)
        XCTAssertEqual(model.labelRows.map(\.id), ["STARRED", "IMPORTANT", "SENT", "Label_12", "Label_14"])
        XCTAssertEqual(model.mailboxRows.map(\.id), ["mailbox.inbox", "mailbox.today"])
        XCTAssertNil(model.emptyState)
        XCTAssertNil(model.observationError)
    }

    @MainActor
    func testInboxNeverAppearsTwice() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        XCTAssertFalse(model.labelRows.contains { $0.id == "INBOX" })
        XCTAssertEqual(LabelsModel.hiddenLabelIds, ["INBOX"])
        XCTAssertEqual(model.mailboxRows[0].scope, .inbox)
    }

    @MainActor
    func testRowTitlesAndIcons() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        XCTAssertEqual(row("STARRED").title, "Starred")
        XCTAssertEqual(row("STARRED").symbol, "star")
        XCTAssertNil(row("STARRED").colorHex)
        XCTAssertEqual(row("SENT").title, "Sent")
        XCTAssertEqual(row("SENT").symbol, "paperplane")
        XCTAssertEqual(row("Label_12").title, "Customers/ACME")
        XCTAssertNil(row("Label_12").symbol)
        XCTAssertEqual(row("Label_12").colorHex, "#4a86e8")
        XCTAssertEqual(row("Label_14").title, "IfUnread")
        XCTAssertEqual(row("Label_14").symbol, "tag")
        XCTAssertNil(row("Label_14").colorHex)
        for r in model.labelRows { XCTAssertEqual(r.scope, .label(id: r.id)) }
    }

    // MARK: - counts

    @MainActor
    func testLocalMailboxCounts() throws {
        try TestDatabase.seedMany(env.db, count: 200)
        model = LabelsModel(env: env)
        let expected = try env.db.read { try Queries.inboxUnreadThreadCount($0) }
        XCTAssertEqual(model.inboxUnreadCount, expected)
        XCTAssertEqual(model.mailboxRows[0].countText, String(expected))
        XCTAssertEqual(model.mailboxRows[0].accessibilityValue, "\(expected) unread")
        XCTAssertEqual(model.todayCount, 0)
        XCTAssertNil(model.mailboxRows[1].countText)
        XCTAssertNil(model.mailboxRows[1].accessibilityValue)
    }

    @MainActor
    func testTodayCountObserved() async throws {
        try TestDatabase.seedMany(env.db, count: 40)
        model = LabelsModel(env: env, clock: { Date() })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try TestDatabase.seed(
            env.db, [TestDatabase.parsed(id: "today1", threadId: "todayT", internalDate: nowMs, labels: ["INBOX"])])
        await waitUntil { self.model.todayCount == 1 }
        XCTAssertEqual(model.mailboxRows[1].countText, "1")
        XCTAssertEqual(model.mailboxRows[1].accessibilityValue, "1 today")
    }

    @MainActor
    func testServerUnreadCountsOnLabelRows() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        try await setLabelUnread("Label_12", 3)
        await waitUntil { self.model.labelRows.first { $0.id == "Label_12" }?.countText == "3" }
        try await setLabelUnread("Label_12", 0)
        await waitUntil { self.model.labelRows.first { $0.id == "Label_12" }?.countText == nil }
        try await setLabelUnread("Label_12", 1200)
        await waitUntil { self.model.labelRows.first { $0.id == "Label_12" }?.countText == "999+" }
    }

    @MainActor
    private func setLabelUnread(_ id: String, _ n: Int) async throws {
        try await env.db.write { db in
            var l = try LabelRecord.fetchOne(db, key: id)!
            l.threadsUnread = n
            try l.update(db)
        }
    }

    @MainActor
    func testLabelRenameUpdatesRow() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        try await env.db.write { db in
            var l = try LabelRecord.fetchOne(db, key: "Label_12")!
            l.name = "Renamed"
            try l.update(db)
        }
        await waitUntil { self.model.labelRows.first { $0.id == "Label_12" }?.title == "Renamed" }
    }

    @MainActor
    func testLabelDeletionRemovesRow() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        try await env.db.write { _ = try LabelRecord.deleteOne($0, key: "Label_14") }
        await waitUntil { !self.model.labelRows.contains { $0.id == "Label_14" } }
    }

    @MainActor
    func testShowIfUnreadRuleFollowsQueries() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        try await setLabelUnread("Label_14", 0)
        await waitUntil { !self.model.labelRows.contains { $0.id == "Label_14" } }
        try await setLabelUnread("Label_14", 2)
        await waitUntil { self.model.labelRows.contains { $0.id == "Label_14" } }
    }

    // MARK: - empty states

    @MainActor
    func testEmptyStates() {
        model = LabelsModel(env: env)
        XCTAssertTrue(model.labelRows.isEmpty)
        XCTAssertEqual(model.emptyState, .noLabels)
        env.syncStatus.phase = .initialSync
        XCTAssertEqual(model.emptyState, .initialSync)
        env.syncStatus.phase = .idle
        model._simulateObservationError("boom")
        XCTAssertEqual(model.emptyState, .unavailable)
    }

    @MainActor
    func testEmptyStateNilWhenRowsExist() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        env.syncStatus.phase = .initialSync
        XCTAssertNil(model.emptyState)
    }

    // MARK: - staleness

    @MainActor
    func testStalenessTriggersRefresh() async throws {
        try await setLastCounts(Int64(fixed.timeIntervalSince1970 * 1000) - 400_000)
        model = LabelsModel(env: env, clock: { self.fixed })
        await model.appeared()
        XCTAssertEqual(model.countsRefreshes, 1)
        XCTAssertTrue(model.didCheckStaleness)
        XCTAssertFalse(model.isRefreshing)
    }

    @MainActor
    func testFreshCountsSkipRefresh() async throws {
        try await setLastCounts(Int64(fixed.timeIntervalSince1970 * 1000) - 10_000)
        model = LabelsModel(env: env, clock: { self.fixed })
        await model.appeared()
        XCTAssertEqual(model.countsRefreshes, 0)
        XCTAssertTrue(model.didCheckStaleness)
    }

    @MainActor
    func testMissingTimestampRefreshes() async {
        model = LabelsModel(env: env)
        XCTAssertNil(model.countsFetchedAt)
        await model.appeared()
        XCTAssertEqual(model.countsRefreshes, 1)
    }

    @MainActor
    func testAppearedChecksOnlyOnce() async throws {
        try await setLastCounts(Int64(fixed.timeIntervalSince1970 * 1000) - 400_000)
        model = LabelsModel(env: env, clock: { self.fixed })
        await model.appeared()
        await model.appeared()
        XCTAssertEqual(model.countsRefreshes, 1)
    }

    @MainActor
    func testBoundaryExactlyFiveMinutes() async throws {
        try await setLastCounts(Int64(fixed.timeIntervalSince1970 * 1000) - 300_000)
        model = LabelsModel(env: env, clock: { self.fixed })
        await model.appeared()
        XCTAssertEqual(model.countsRefreshes, 1)
    }

    @MainActor
    func testRefreshAlwaysForces() async throws {
        try await setLastCounts(Int64(fixed.timeIntervalSince1970 * 1000) - 10_000)
        model = LabelsModel(env: env, clock: { self.fixed })
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(model.countsRefreshes, 2)
    }

    // MARK: - selection

    @MainActor
    func testSelectLabelRunsLabelOpened() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        model.select(.label(id: "Label_12"))
        XCTAssertEqual(model.lastSelected, .label(id: "Label_12"))
        await waitUntil { self.model.openedLabelIds == ["Label_12"] }
        XCTAssertFalse(model.labelRows.isEmpty)
    }

    @MainActor
    func testSelectMailboxDoesNotHydrate() {
        model = LabelsModel(env: env)
        model.select(.inbox)
        XCTAssertEqual(model.lastSelected, .inbox)
        XCTAssertTrue(model.openedLabelIds.isEmpty)
        model.select(.today)
        XCTAssertEqual(model.lastSelected, .today)
        XCTAssertTrue(model.openedLabelIds.isEmpty)
    }

    // MARK: - footer

    @MainActor
    func testCountsFetchedAtObserved() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env, clock: { self.fixed })
        XCTAssertEqual(model.footerText, "Counts from Gmail · not loaded yet")
        // Production writes lastLabelCountsAt alongside the label-count rows in one transaction; do the same.
        let ms = Int64(fixed.timeIntervalSince1970 * 1000) - 120_000
        try await env.db.write { db in
            try SyncStateRepository.set(db, .lastLabelCountsAt, String(ms))
            var l = try LabelRecord.fetchOne(db, key: "Label_12")!
            l.threadsUnread = 1
            try l.update(db)
        }
        await waitUntil { self.model.countsFetchedAt != nil }
        XCTAssertEqual(model.footerText, "Counts from Gmail · updated 2 min ago")
    }

    @MainActor
    func testFooterOffline() async throws {
        try await setLastCounts(Int64(fixed.timeIntervalSince1970 * 1000) - 120_000)
        model = LabelsModel(env: env, clock: { self.fixed })
        env.syncStatus.isOffline = true
        XCTAssertEqual(model.footerText, "Counts from Gmail · offline")
    }

    // MARK: - errors & lifecycle

    @MainActor
    func testObservationErrorRecovery() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        model._simulateObservationError("boom")
        XCTAssertNotNil(model.observationError)
        await model.refresh()
        XCTAssertNil(model.observationError)
        XCTAssertEqual(model.labelRows.map(\.id), ["STARRED", "IMPORTANT", "SENT", "Label_12", "Label_14"])
        XCTAssertEqual(model.countsRefreshes, 1)
    }

    @MainActor
    func testStopCancelsObservation() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = LabelsModel(env: env)
        model.stop()
        try await env.db.write { db in
            var l = try LabelRecord.fetchOne(db, key: "Label_12")!
            l.name = "After stop"
            try l.update(db)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.labelRows.first { $0.id == "Label_12" }?.title, "Customers/ACME")
    }
}
