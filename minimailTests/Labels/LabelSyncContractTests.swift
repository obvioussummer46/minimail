import GRDB
import MailCore
import XCTest

@testable import minimail

/// Spec 12 §7.3. Verifies the module-07 label behaviours the labels sheet depends on (`refreshLabelCounts`
/// throttle/force, `.labelOpened` once-per-24 h hydration, `.loadOlderLabel` page-token paging) against the real
/// `SyncEngine` via 07's `SyncHarness`/`BatchStub`. Overlap with 07 is deliberate: 07 owns the code, 12 owns the
/// contract.
nonisolated final class LabelSyncContractTests: XCTestCase {
    override func setUp() { super.setUp(); StubURLProtocol.reset() }

    @MainActor private func nowMs(_ h: SyncHarness) -> Int64 { Int64(h.now.timeIntervalSince1970 * 1000) }

    private static let labelsPath = "/gmail/v1/users/me/labels"
    private static let messagesPath = "/gmail/v1/users/me/messages"
    private static let historyPath = "/gmail/v1/users/me/history"

    private func labelsListBody() -> Data {
        Data(
            #"""
            {"labels":[{"id":"INBOX","name":"INBOX","type":"system"},\#
            {"id":"STARRED","name":"STARRED","type":"system"},\#
            {"id":"IMPORTANT","name":"IMPORTANT","type":"system"},\#
            {"id":"SENT","name":"SENT","type":"system"},\#
            {"id":"Label_12","name":"Customers/ACME","type":"user","labelListVisibility":"labelShow",\#
            "color":{"textColor":"#ffffff","backgroundColor":"#4a86e8"}}]}
            """#.utf8)
    }

    private func labelGetBody(id: String, name: String, type: String, unread: Int) -> Data {
        Data(#"{"id":"\#(id)","name":"\#(name)","type":"\#(type)","threadsUnread":\#(unread)}"#.utf8)
    }

    private func countsRoutes(_ h: SyncHarness) {
        BatchStub.install(
            routes: [
                ("GET", Self.labelsPath, [.json(200, labelsListBody())]),
                ("GET", Self.historyPath, [.json(200, JSONFixtures.history(records: [], historyId: 5000))]),
            ],
            parts: BatchStub.responder(labels: [
                "INBOX": labelGetBody(id: "INBOX", name: "INBOX", type: "system", unread: 4),
                "STARRED": labelGetBody(id: "STARRED", name: "STARRED", type: "system", unread: 0),
                "IMPORTANT": labelGetBody(id: "IMPORTANT", name: "IMPORTANT", type: "system", unread: 0),
                "SENT": labelGetBody(id: "SENT", name: "SENT", type: "system", unread: 0),
                "Label_12": labelGetBody(id: "Label_12", name: "Customers/ACME", type: "user", unread: 2),
            ]))
    }

    private func labelRequests() -> Int {
        StubURLProtocol.recorded.filter { $0.path == Self.labelsPath }.count
    }
    private func labelMessageRequests(_ id: String) -> [StubURLProtocol.Request] {
        StubURLProtocol.recorded.filter {
            $0.path == Self.messagesPath && ($0.query ?? "").contains("labelIds=\(id)")
        }
    }

    // MARK: - refreshLabelCounts

    @MainActor
    func testForceRefreshFetchesAndWritesCounts() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        countsRoutes(h)

        await h.sync.refreshLabelCounts(force: true)

        XCTAssertEqual(labelRequests(), 1)
        XCTAssertEqual(BatchStub.batchCount, 1)
        let unread = try await h.db.read { try LabelRecord.fetchOne($0, key: "Label_12")?.threadsUnread }
        XCTAssertEqual(unread, 2)
        XCTAssertEqual(try h.syncStateValue(.lastLabelCountsAt), String(nowMs(h)))
        h.assertInvariants()
    }

    @MainActor
    func testThrottleSkipsWhenFresh() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        let fresh = nowMs(h) - 60_000
        try await h.db.write { try SyncStateRepository.set($0, .lastLabelCountsAt, String(fresh)) }
        countsRoutes(h)

        await h.sync.refreshLabelCounts(force: false)

        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
        XCTAssertEqual(BatchStub.batchCount, 0)
    }

    @MainActor
    func testThrottleExpiresAfterFiveMinutes() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        let stale = nowMs(h) - 60_000
        try await h.db.write { try SyncStateRepository.set($0, .lastLabelCountsAt, String(stale)) }
        countsRoutes(h)
        h.advance(seconds: 301)

        await h.sync.refreshLabelCounts(force: false)

        XCTAssertEqual(labelRequests(), 1)
        XCTAssertEqual(BatchStub.batchCount, 1)
        XCTAssertEqual(SyncEngine.labelCountsStaleness, 300)
    }

    // MARK: - .labelOpened hydration

    @MainActor
    private func seedLabel12(_ h: SyncHarness) async throws {
        try await h.db.write {
            try LabelRepository.replaceAll(
                $0, labels: [GmailLabel(id: "Label_12", name: "Customers/ACME", type: "user")])
        }
    }

    @MainActor
    private func labelViewRoutes(_ h: SyncHarness, ids: [String], nextPageToken: String?) {
        BatchStub.install(
            routes: [
                ("GET", Self.messagesPath, [.json(200, JSONFixtures.messageList(ids: ids, nextPageToken: nextPageToken))]),
                ("GET", Self.labelsPath, [.json(200, labelsListBody())]),
                ("GET", Self.historyPath, [.json(200, JSONFixtures.history(records: [], historyId: 5000))]),
            ],
            parts: BatchStub.responder(
                messages: Dictionary(
                    uniqueKeysWithValues: ids.map {
                        ($0, JSONFixtures.metadataMessage(id: $0, thread: $0, labels: ["Label_12"], date: 1, from: "a@example.com", subject: "S"))
                    }),
                labels: ["Label_12": labelGetBody(id: "Label_12", name: "Customers/ACME", type: "user", unread: 1)]))
    }

    @MainActor
    func testLabelOpenedHydratesOnce() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        try await seedLabel12(h)
        labelViewRoutes(h, ids: ["l1"], nextPageToken: "lp2")

        await h.sync.run(.labelOpened("Label_12"))
        await h.sync.run(.labelOpened("Label_12"))

        XCTAssertEqual(labelMessageRequests("Label_12").count, 1, "second open within 24h must not re-fetch")
        let label = try await h.db.read { try LabelRecord.fetchOne($0, key: "Label_12") }
        XCTAssertNotNil(label?.viewFetchedAt)
        XCTAssertEqual(label?.viewNextPageToken, "lp2")
        let hasMessage = try await h.db.read { try Bool.fetchOne($0, sql: "SELECT 1 FROM message WHERE id = 'l1'") ?? false }
        XCTAssertTrue(hasMessage)
        let hasThreadLabel = try await h.db.read {
            try Bool.fetchOne($0, sql: "SELECT 1 FROM thread_label WHERE labelId = 'Label_12' AND threadId = 'l1'") ?? false
        }
        XCTAssertTrue(hasThreadLabel)
        h.assertInvariants()
    }

    @MainActor
    func testLabelOpenedRehydratesAfter24h() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        try await seedLabel12(h)
        let staleAt = nowMs(h) - 25 * 3_600_000
        try await h.db.write {
            var l = try LabelRecord.fetchOne($0, key: "Label_12")!
            l.viewFetchedAt = staleAt
            try l.update($0)
        }
        labelViewRoutes(h, ids: ["l1"], nextPageToken: "lp3")

        await h.sync.run(.labelOpened("Label_12"))

        XCTAssertEqual(labelMessageRequests("Label_12").count, 1)
        let at = try await h.db.read { try LabelRecord.fetchOne($0, key: "Label_12")?.viewFetchedAt }
        XCTAssertEqual(at, nowMs(h))
        XCTAssertEqual(SyncEngine.labelViewMaxAge, 86_400)
    }

    @MainActor
    func testLabelOpenedUnknownLabelIsNoop() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        labelViewRoutes(h, ids: ["l1"], nextPageToken: nil)

        await h.sync.run(.labelOpened("Label_77"))

        XCTAssertTrue(labelMessageRequests("Label_77").isEmpty)
        XCTAssertNil(h.status.lastError)
    }

    // MARK: - .loadOlderLabel paging

    @MainActor
    func testLoadOlderLabelUsesViewToken() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        try await seedLabel12(h)
        let now = nowMs(h)
        try await h.db.write {
            try LabelRepository.markViewFetched($0, labelId: "Label_12", nextPageToken: "lp2", now: now)
        }
        labelViewRoutes(h, ids: ["l2"], nextPageToken: nil)

        await h.sync.run(.loadOlderLabel("Label_12"))

        let reqs = labelMessageRequests("Label_12")
        XCTAssertEqual(reqs.count, 1)
        XCTAssertTrue((reqs.first?.query ?? "").contains("pageToken=lp2"))
        let token = try await h.db.read { try LabelRecord.fetchOne($0, key: "Label_12")?.viewNextPageToken }
        XCTAssertNil(token)
        let hasMessage = try await h.db.read { try Bool.fetchOne($0, sql: "SELECT 1 FROM message WHERE id = 'l2'") ?? false }
        XCTAssertTrue(hasMessage)
    }

    @MainActor
    func testLoadOlderLabelWithoutTokenIsNoop() async throws {
        let h = try SyncHarness()
        try h.seedSyncState(historyId: 5000)
        try await seedLabel12(h)  // replaceAll leaves viewNextPageToken nil
        labelViewRoutes(h, ids: ["l2"], nextPageToken: nil)

        await h.sync.run(.loadOlderLabel("Label_12"))

        XCTAssertTrue(labelMessageRequests("Label_12").isEmpty)
    }
}
