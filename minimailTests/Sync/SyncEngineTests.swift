import GRDB
import MailCore
import XCTest

@testable import minimail

nonisolated final class SyncEngineTests: XCTestCase {
    override func setUp() { super.setUp(); StubURLProtocol.reset() }

    private func delayed(_ body: Data, _ delay: TimeInterval) -> StubURLProtocol.Response {
        var r = StubURLProtocol.Response.json(200, body)
        r.delay = delay
        return r
    }

    // MARK: - Opening split (thread open)

    private func gmailMessage(_ id: String, date: Int64, unread: Bool = false) -> GmailMessage {
        GmailMessage(
            id: id, threadId: "t1", labelIds: unread ? ["INBOX", "UNREAD"] : ["INBOX"],
            internalDate: StringInt64(date))
    }

    func testOpeningIndicesTakesNewestAndUnread() {
        let messages = [
            gmailMessage("m1", date: 1_000),
            gmailMessage("m2", date: 2_000, unread: true),
            gmailMessage("m3", date: 3_000),
            gmailMessage("m4", date: 2_500),
        ]
        // m3 is newest, m2 is unread; m1 and m4 are read history and wait for the second commit.
        XCTAssertEqual(SyncEngine.openingIndices(messages), [1, 2])
    }

    func testOpeningIndicesNewestIsNotTheLastElement() {
        let messages = [gmailMessage("m1", date: 9_000), gmailMessage("m2", date: 1_000)]
        XCTAssertEqual(SyncEngine.openingIndices(messages), [0])
    }

    func testOpeningIndicesSingleMessageThread() {
        XCTAssertEqual(SyncEngine.openingIndices([gmailMessage("m1", date: 1_000)]), [0])
    }

    func testOpeningIndicesEmptyThread() {
        XCTAssertEqual(SyncEngine.openingIndices([]), [])
    }

    /// Nothing unread, no dates at all: the first commit must still carry a message rather than come out
    /// empty, so the screen has something to paint.
    func testOpeningIndicesIsNeverEmpty() {
        let undated = [GmailMessage(id: "m1", threadId: "t1"), GmailMessage(id: "m2", threadId: "t1")]
        XCTAssertFalse(SyncEngine.openingIndices(undated).isEmpty)
    }

    /// Every unread message is expanded on open, so every unread message is in the first commit.
    func testOpeningIndicesTakesAllUnread() {
        let messages = [
            gmailMessage("m1", date: 1_000, unread: true),
            gmailMessage("m2", date: 2_000, unread: true),
            gmailMessage("m3", date: 3_000),
        ]
        XCTAssertEqual(SyncEngine.openingIndices(messages), [0, 1, 2])
    }

    @MainActor
    func testPausedWhenNeedsReauth() async throws {
        let h = try SyncHarness()
        h.auth.markNeedsReauth()
        await h.sync.run(.launch)
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        XCTAssertEqual(h.status.phase, .idle)
    }

    @MainActor
    func testBadgeOnlyWhenEnabled() async throws {
        let h = try SyncHarness()
        await h.sync.updateBadge()
        XCTAssertEqual(h.badgeCalls, [])
        h.setSettings { $0.showBadge = true }
        try h.seed([msg("a1"), msg("b1"), msg("c1")])
        await h.sync.updateBadge()
        XCTAssertEqual(h.badgeCalls, [3])
    }

    @MainActor
    func testOfflineSetsFlagNoError() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 1000)
        BatchStub.install(
            routes: [
                (
                    "GET", "/gmail/v1/users/me/history",
                    [
                        .error(.notConnectedToInternet),
                        .json(200, JSONFixtures.history(records: [], historyId: 1000)),
                    ]
                )
            ], parts: BatchStub.responder())

        await h.sync.run(.afterSend)
        XCTAssertTrue(h.status.isOffline)
        XCTAssertNil(h.status.lastError)

        await h.sync.run(.afterSend)
        XCTAssertFalse(h.status.isOffline)
        h.assertInvariants()
    }

    @MainActor
    func testDeltaAddedFetched() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 1000)
        try h.seed([msg("a1")])
        BatchStub.install(
            routes: [
                (
                    "GET", "/gmail/v1/users/me/history",
                    [
                        .json(
                            200,
                            JSONFixtures.history(
                                records: [
                                    JSONFixtures.messagesAdded(id: "n1", thread: "n1", labels: ["INBOX", "UNREAD"])
                                ],
                                historyId: 2001))
                    ]
                )
            ],
            parts: BatchStub.responder(messages: [
                "n1": JSONFixtures.metadataMessage(
                    id: "n1", thread: "n1", labels: ["INBOX", "UNREAD"], date: 1_757_580_000_000,
                    from: "alice@example.com", subject: "Hi")
            ]))

        await h.sync.run(.afterSend)

        XCTAssertEqual(BatchStub.batchCount, 1)
        XCTAssertEqual(BatchStub.partCount, 1)
        let n1 = try XCTUnwrap(h.message("n1"))
        XCTAssertEqual(n1.serverLabelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(try h.thread("n1")?.inInbox, true)
        XCTAssertEqual(try h.syncStateValue(.historyId), "2001")
        XCTAssertEqual(try h.syncStateValue(.lastDeltaSyncAt), String(Int64(h.now.timeIntervalSince1970 * 1000)))
        h.assertInvariants()
    }

    @MainActor
    func testDeltaHistoryIdNeverDecreases() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 9000)
        BatchStub.install(
            routes: [
                (
                    "GET", "/gmail/v1/users/me/history",
                    [.json(200, JSONFixtures.history(records: [], historyId: 2001))]
                )
            ], parts: BatchStub.responder())
        await h.sync.run(.afterSend)
        XCTAssertEqual(try h.syncStateValue(.historyId), "9000")
    }

    @MainActor
    func testFullSyncRequestSequence() async throws {
        let h = try SyncHarness()
        var messages: [String: Data] = [:]
        for i in 1...30 {
            messages["m\(i)"] = JSONFixtures.metadataMessage(
                id: "m\(i)", thread: "m\(i)", labels: ["INBOX"], date: 1_757_580_000_000 + Int64(i),
                from: "alice@example.com", subject: "S\(i)")
        }
        let ids = (1...30).map { "m\($0)" }
        BatchStub.install(
            routes: [
                (
                    "GET", "/gmail/v1/users/me/profile",
                    [.json(200, JSONFixtures.profile(email: "me@example.com", historyId: 5000))]
                ),
                (
                    "GET", "/gmail/v1/users/me/settings/sendAs",
                    [
                        .json(
                            200,
                            Data(
                                #"{"sendAs":[{"sendAsEmail":"me@example.com","isPrimary":true,"isDefault":true,"displayName":"Me"}]}"#
                                    .utf8))
                    ]
                ),
                (
                    "GET", "/gmail/v1/users/me/labels",
                    [.json(200, Data(#"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"}]}"#.utf8))]
                ),
                (
                    "GET", "/gmail/v1/users/me/messages",
                    [.json(200, JSONFixtures.messageList(ids: ids, nextPageToken: "p2"))]
                ),
                ("GET", "/gmail/v1/users/me/history", [.json(200, JSONFixtures.history(records: [], historyId: 5000))]),
            ],
            parts: BatchStub.responder(
                messages: messages,
                labels: ["INBOX": Data(#"{"id":"INBOX","name":"INBOX","type":"system","threadsUnread":0}"#.utf8)]))

        await h.sync.run(.launch)

        let messageCount = try await h.db.read { try MessageRecord.fetchCount($0) }
        let threadCount = try await h.db.read { try ThreadRecord.fetchCount($0) }
        XCTAssertEqual(messageCount, 30)
        XCTAssertEqual(threadCount, 30)
        XCTAssertEqual(try h.syncStateValue(.historyId), "5000")
        XCTAssertEqual(try h.syncStateValue(.syncGeneration), "1")
        XCTAssertEqual(try h.syncStateValue(.inboxNextPageToken), "p2")
        XCTAssertEqual(try h.syncStateValue(.accountEmail), "me@example.com")
        XCTAssertEqual(h.status.phase, .idle)
        XCTAssertNil(h.status.lastError)
        XCTAssertNotNil(h.status.lastSyncAt)
        h.assertInvariants()
    }

    @MainActor
    func testCancelAllStopsRun() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 9000)
        BatchStub.install(
            routes: [
                (
                    "GET", "/gmail/v1/users/me/history",
                    [delayed(JSONFixtures.history(records: [], historyId: 9001), 0.5)]
                )
            ], parts: BatchStub.responder())

        let task = Task { await h.sync.run(.launch) }
        try await Task.sleep(for: .seconds(0.1))
        await h.sync.cancelAll()
        await task.value

        let running = await h.sync.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(try h.syncStateValue(.historyId), "9000")
        XCTAssertNil(h.status.lastError)
    }

    @MainActor
    func testSingleFlightRerun() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 1000)
        BatchStub.install(
            routes: [
                (
                    "GET", "/gmail/v1/users/me/history",
                    [delayed(JSONFixtures.history(records: [], historyId: 1000), 0.2)]
                ),
                ("GET", "/gmail/v1/users/me/labels", [.json(200, Data(#"{"labels":[]}"#.utf8))]),
            ], parts: BatchStub.responder())

        let t1 = Task { await h.sync.run(.launch) }
        try await Task.sleep(for: .seconds(0.02))
        let start = Date()
        await h.sync.run(.pullToRefresh)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
        await t1.value

        let historyRequests = StubURLProtocol.recorded.filter { $0.path == "/gmail/v1/users/me/history" }.count
        XCTAssertEqual(historyRequests, 2)
        XCTAssertEqual(h.status.lastRunReason, .pullToRefresh)
    }

    // MARK: - Plain-text body preload

    private func emptyDeltaRoute() -> (String, String, [StubURLProtocol.Response]) {
        ("GET", "/gmail/v1/users/me/history", [.json(200, JSONFixtures.history(records: [], historyId: 1001))])
    }

    private func threadRoute(_ id: String, body: String) -> (String, String, [StubURLProtocol.Response]) {
        (
            "GET", "/gmail/v1/users/me/threads/\(id)",
            [
                .json(
                    200,
                    JSONFixtures.thread(
                        id: id,
                        messages: [
                            JSONFixtures.fullMessage(
                                id: id, thread: id, labels: ["INBOX", "UNREAD"], date: 1_757_580_000_000,
                                html: body, text: nil)
                        ]))
            ]
        )
    }

    @MainActor
    func testPreloadLoadsInboxThreadsInPlainTextMode() async throws {
        let h = try SyncHarness()
        h.setSettings { $0.plainTextBodies = true }
        try h.seedSyncState(historyId: 1000)
        try h.seed([msg("a1"), msg("a2")], complete: false)
        BatchStub.install(
            routes: [emptyDeltaRoute(), threadRoute("a1", body: "<p>One</p>"), threadRoute("a2", body: "<p>Two</p>")],
            parts: BatchStub.responder())

        await h.sync.run(.afterSend)

        XCTAssertEqual(try h.message("a1")?.bodyState, 1)
        XCTAssertEqual(try h.message("a2")?.bodyState, 1)
        XCTAssertEqual(try h.thread("a1")?.isComplete, true)
        XCTAssertEqual(try h.thread("a2")?.isComplete, true)
        h.assertInvariants()
    }

    @MainActor
    func testPreloadSkippedWhenPlainTextOff() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 1000)
        try h.seed([msg("a1")], complete: false)
        BatchStub.install(routes: [emptyDeltaRoute()], parts: BatchStub.responder())

        await h.sync.run(.afterSend)

        XCTAssertEqual(try h.message("a1")?.bodyState, 0)
        XCTAssertEqual(try h.thread("a1")?.isComplete, false)
    }

    @MainActor
    func testPreloadSkippedInLowPowerMode() async throws {
        let h = try SyncHarness()
        h.setSettings { $0.plainTextBodies = true }
        h.setLowPower(true)
        try h.seedSyncState(historyId: 1000)
        try h.seed([msg("a1")], complete: false)
        BatchStub.install(routes: [emptyDeltaRoute()], parts: BatchStub.responder())

        await h.sync.run(.afterSend)

        XCTAssertEqual(try h.message("a1")?.bodyState, 0)
    }

    @MainActor
    func testPreloadSkippedOnBackgroundSync() async throws {
        let h = try SyncHarness()
        h.setSettings { $0.plainTextBodies = true }
        try h.seedSyncState(historyId: 1000)
        try h.seed([msg("a1")], complete: false)
        BatchStub.install(routes: [emptyDeltaRoute()], parts: BatchStub.responder())

        await h.sync.run(.background)

        XCTAssertEqual(try h.message("a1")?.bodyState, 0)
    }

    /// Newest inbox threads first, capped, and non-inbox or already-complete threads excluded.
    @MainActor
    func testPreloadCandidatesQuery() async throws {
        let h = try SyncHarness()
        try h.seed(
            [
                msg("a1", date: 1_000), msg("a2", date: 2_000), msg("a3", date: 3_000),
                msg("b1", labels: ["UNREAD"], date: 4_000),
            ], complete: false)
        try await h.db.write { try ThreadRepository.markComplete($0, threadId: "a1", complete: true) }

        let ids = try await h.db.read { try ThreadRepository.preloadCandidates($0, limit: 2).map(\.id) }
        XCTAssertEqual(ids, ["a3", "a2"])
    }
}
