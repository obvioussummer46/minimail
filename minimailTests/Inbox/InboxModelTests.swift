import GRDB
import MailCore
import XCTest

@testable import minimail

nonisolated final class InboxModelTests: XCTestCase {
    var env: AppEnvironment!
    var model: InboxModel!
    let seedNow: Int64 = 1_757_500_000_000
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    @MainActor override func setUp() async throws { env = AppEnvironment(testing: true) }
    @MainActor override func tearDown() async throws {
        model?.stop()
        model = nil
        env = nil
    }

    @MainActor func waitUntil(_ timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private func seed(_ messages: [ParsedMessage]) throws { try TestDatabase.seed(env.db, messages) }

    @MainActor
    func testImmediateRowsOnInit() throws {
        try seed([
            TestDatabase.parsed(id: "t1", internalDate: seedNow + 180_000, labels: ["INBOX"]),
            TestDatabase.parsed(id: "t2", internalDate: seedNow + 120_000, labels: ["INBOX"]),
            TestDatabase.parsed(id: "t3", internalDate: seedNow + 60_000, labels: ["INBOX"]),
        ])
        model = InboxModel(env: env, scope: .inbox)
        XCTAssertEqual(model.rows.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(model.title, "Inbox")
        XCTAssertNil(model.emptyState)
        XCTAssertNil(model.banner)
        XCTAssertFalse(model.hasOlder)
        XCTAssertEqual(model.query, ThreadQuery(scope: .inbox, unreadOnly: false, limit: 60))
    }

    @MainActor
    func testEmptyStatesPerScope() {
        model = InboxModel(env: env, scope: .inbox)
        XCTAssertEqual(model.emptyState, .noMail)
        model.setScope(.today)
        XCTAssertEqual(model.emptyState, .nothingToday)
        model.setScope(.label(id: "Label_12"))
        XCTAssertEqual(model.emptyState, .noMessages)
        model.toggleUnreadOnly()
        XCTAssertEqual(model.emptyState, .allCaughtUp)
        env.syncStatus.phase = .initialSync
        XCTAssertEqual(model.emptyState, .initialSync)
        env.syncStatus.phase = .idle
        XCTAssertEqual(model.emptyState, .allCaughtUp)
    }

    @MainActor
    func testQueryMirrorsState() {
        let fixed = Date(timeIntervalSince1970: 1_757_580_000)
        model = InboxModel(env: env, scope: .inbox, clock: { fixed }, timeZone: berlin)
        model.setScope(.today)
        let expected = DayBoundary.today(now: fixed, timeZone: berlin)
        XCTAssertEqual(model.query.scope, .today(expected))
        XCTAssertEqual(expected.startMs, 1_757_541_600_000)
        XCTAssertEqual(expected.endMs, 1_757_628_000_000)
        model.setScope(.label(id: "L"))
        XCTAssertEqual(model.query.scope, .label(id: "L"))
        model.toggleUnreadOnly()
        XCTAssertTrue(model.query.unreadOnly)
    }

    @MainActor
    func testSetScopeSameIsNoop() {
        model = InboxModel(env: env, scope: .inbox)
        model.setScope(.inbox)
        XCTAssertEqual(model.filterChangeId, 0)
        model.setScope(.today)
        XCTAssertEqual(model.filterChangeId, 1)
        model.setScope(.today)
        XCTAssertEqual(model.filterChangeId, 1)
    }

    @MainActor
    func testUnreadToggleFilters() throws {
        try TestDatabase.seedMany(env.db, count: 200)
        model = InboxModel(env: env, scope: .inbox)
        model.toggleUnreadOnly()
        XCTAssertTrue(model.rows.allSatisfy { $0.isUnread })
        XCTAssertEqual(model.filterChangeId, 1)
    }

    @MainActor
    func testPagingIncreasesLimit() throws {
        try TestDatabase.seedMany(env.db, count: 200)
        model = InboxModel(env: env, scope: .inbox)
        XCTAssertEqual(model.rows.count, 60)
        model.rowAppeared(model.rows[10].id)
        XCTAssertEqual(model.limit, 60)
        model.rowAppeared(model.rows.last!.id)
        XCTAssertEqual(model.limit, 120)
        XCTAssertGreaterThan(model.rows.count, 60)
    }

    @MainActor
    func testToggleResetsLimit() throws {
        try TestDatabase.seedMany(env.db, count: 200)
        model = InboxModel(env: env, scope: .inbox)
        model.rowAppeared(model.rows.last!.id)
        XCTAssertEqual(model.limit, 120)
        model.toggleUnreadOnly()
        XCTAssertEqual(model.limit, 60)
        model.setScope(.today)
        XCTAssertEqual(model.limit, 60)
    }

    @MainActor
    func testHasOlderFromInboxToken() async throws {
        // Seed the page token before the model so it is part of the first immediate aux value.
        try await env.db.write { try SyncStateRepository.set($0, .inboxNextPageToken, "p2") }
        try seed([TestDatabase.parsed(id: "t1", internalDate: seedNow, labels: ["INBOX"])])
        model = InboxModel(env: env, scope: .inbox)
        XCTAssertTrue(model.hasOlder)
        XCTAssertEqual(model.olderReason, .loadOlderInbox)
        model.setScope(.today)
        XCTAssertTrue(model.hasOlder)
        XCTAssertEqual(model.olderReason, .loadOlderInbox)
    }

    @MainActor
    func testHasOlderFromLabelToken() async throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        let now = seedNow
        try await env.db.write {
            try LabelRepository.markViewFetched($0, labelId: "Label_12", nextPageToken: "lp", now: now)
        }
        model = InboxModel(env: env, scope: .inbox)
        model.setScope(.label(id: "Label_12"))
        XCTAssertTrue(model.hasOlder)
        XCTAssertEqual(model.olderReason, .loadOlderLabel("Label_12"))
    }

    @MainActor
    func testTitleForLabelScope() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        model = InboxModel(env: env, scope: .inbox)
        model.setScope(.label(id: "Label_12"))
        XCTAssertEqual(model.title, "Customers/ACME")
        model.setScope(.label(id: "Label_999"))
        XCTAssertEqual(model.title, "Label_999")
        model.setScope(.today)
        XCTAssertEqual(model.title, "Today")
        model.setScope(.inbox)
        XCTAssertEqual(model.title, "Inbox")
    }

    @MainActor
    func testChipsFromLabelTable() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        try seed([TestDatabase.parsed(id: "t1", internalDate: seedNow, labels: ["INBOX", "Label_12", "Label_13"])])
        model = InboxModel(env: env, scope: .inbox)
        XCTAssertEqual(model.rows[0].chips.map(\.id), ["Label_12", "Label_13"])
        XCTAssertEqual(model.rows[0].chips[0].name, "Customers/ACME")
    }

    @MainActor
    func testArchiveRemovesRowAndEnqueues() async throws {
        try seed([
            TestDatabase.parsed(id: "t1", internalDate: seedNow + 60_000, labels: ["INBOX", "UNREAD"]),
            TestDatabase.parsed(id: "t2", internalDate: seedNow, labels: ["INBOX", "UNREAD"]),
        ])
        model = InboxModel(env: env, scope: .inbox)
        model.archive(threadId: "t1")
        XCTAssertEqual(model.lastActionId, 1)
        await waitUntil { self.model.rows.map(\.id) == ["t2"] }
        let ops = try await env.db.read { try OutboxRepository.activeModifies($0) }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.threadId, "t1")
        XCTAssertEqual(ops.first?.removeLabelIds, ["INBOX"])
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor
    func testToggleReadFlipsAndCoalesces() async throws {
        try seed([TestDatabase.parsed(id: "t1", internalDate: seedNow, labels: ["INBOX", "UNREAD"])])
        model = InboxModel(env: env, scope: .inbox)
        model.toggleRead(threadId: "t1", isUnread: true)
        await waitUntil { self.model.rows.first?.isUnread == false }
        model.toggleRead(threadId: "t1", isUnread: false)
        await waitUntil { self.model.rows.first?.isUnread == true }
        XCTAssertEqual(model.lastActionId, 2)
        try await waitUntilOpsEmpty()
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor private func waitUntilOpsEmpty() async throws {
        let db = env.db
        await waitUntil { (try? db.read { try OutboxRepository.activeModifies($0) })?.isEmpty ?? false }
    }

    @MainActor
    func testFailedSendsSectionAndOpen() async throws {
        let job = InboxViewsTests.job(subject: "Hi", to: [Mailbox(name: "Bob", addr: "bob@example.com")], cc: [])
        let now = seedNow
        let id = try await env.db.write { db -> Int64 in
            let id = try OutboxRepository.enqueueSend(db, job: job, now: now)
            try OutboxRepository.fail(db, opId: id, error: "Daily quota exceeded")
            return id
        }
        model = InboxModel(env: env, scope: .inbox)
        await waitUntil { self.model.failedSends.count == 1 }
        XCTAssertEqual(model.failedSends[0].id, id)
        XCTAssertEqual(model.failedSends[0].kind, .send)
        model.openFailedSend(model.failedSends[0])
        XCTAssertEqual(model.activeSheet?.id, "compose:failedSend:\(id)")
    }

    @MainActor
    func testDiscardSendRemovesRow() async throws {
        let job = InboxViewsTests.job(subject: "Hi", to: [], cc: [])
        let now = seedNow
        let id = try await env.db.write { db -> Int64 in
            let id = try OutboxRepository.enqueueSend(db, job: job, now: now)
            try OutboxRepository.fail(db, opId: id, error: "x")
            return id
        }
        model = InboxModel(env: env, scope: .inbox)
        await waitUntil { self.model.failedSends.count == 1 }
        model.discardSend(id)
        await waitUntil { self.model.failedSends.isEmpty }
        XCTAssertEqual(model.lastActionId, 1)
    }

    @MainActor
    func testBannerPriority() {
        model = InboxModel(env: env, scope: .inbox)
        env.syncStatus.isOffline = true
        env.syncStatus.lastError = "x"
        XCTAssertEqual(model.banner, .offline)
        env.syncStatus.isOffline = false
        XCTAssertEqual(model.banner, .error("x"))
        env.syncStatus.lastError = nil
        XCTAssertNil(model.banner)
        model._simulateObservationError("boom")
        XCTAssertEqual(model.banner, .error("Database unavailable"))
    }

    @MainActor
    func testRefreshWhenSignedOutReturnsFast() async {
        model = InboxModel(env: env, scope: .inbox)
        let t = Date()
        await model.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        XCTAssertEqual(env.syncStatus.phase, .idle)
    }

    @MainActor
    func testObservationErrorRecovery() async throws {
        try seed([TestDatabase.parsed(id: "t1", internalDate: seedNow, labels: ["INBOX"])])
        model = InboxModel(env: env, scope: .inbox)
        model._simulateObservationError("boom")
        XCTAssertNotNil(model.observationError)
        XCTAssertEqual(model.banner, .error("Database unavailable"))
        await model.refresh()
        XCTAssertNil(model.observationError)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.rows.map(\.id), ["t1"])
    }

    @MainActor
    func testStopCancelsObservations() async throws {
        try seed([TestDatabase.parsed(id: "t1", internalDate: seedNow, labels: ["INBOX"])])
        model = InboxModel(env: env, scope: .inbox)
        model.stop()
        try seed([TestDatabase.parsed(id: "t2", internalDate: seedNow + 60_000, labels: ["INBOX"])])
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.rows.map(\.id), ["t1"])
    }
}
