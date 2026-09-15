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
}
