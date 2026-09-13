import GRDB
import MailCore
import XCTest

@testable import minimail

nonisolated final class OutboxTests: XCTestCase {
    override func setUp() { super.setUp(); StubURLProtocol.reset() }

    @MainActor
    private func nowMs(_ h: SyncHarness) -> Int64 { Int64(h.now.timeIntervalSince1970 * 1000) }

    @MainActor
    private func enqueueArchive(_ h: SyncHarness, _ threadId: String) throws {
        try h.db.write { db in
            let ids = try ThreadRepository.messageIds(db, threadId: threadId)
            _ = try OutboxRepository.enqueueModify(
                db, threadId: threadId, delta: LabelDelta(add: [], remove: ["INBOX"]), affectedMessageIds: ids,
                now: Int64(h.now.timeIntervalSince1970 * 1000))
        }
    }

    @MainActor
    func testArchiveEnqueuesAndDrains() async throws {
        let h = try SyncHarness()
        try h.seed([msg("a1", labels: ["INBOX", "UNREAD"])])
        BatchStub.install(
            routes: [],
            parts: BatchStub.responder(modify: [
                "a1": (200, JSONFixtures.modifyResponse(threadId: "a1", messages: [("a1", ["UNREAD"])]))
            ]))

        await h.actions.archive(threadId: "a1")
        await h.outbox.drain()  // wait for the debounced kick's drain to settle
        XCTAssertTrue(try h.outboxRows().isEmpty)
        XCTAssertEqual(try h.message("a1")?.serverLabelIds, ["UNREAD"])
        XCTAssertEqual(try h.message("a1")?.labelIds, ["UNREAD"])
        XCTAssertEqual(try h.thread("a1")?.inInbox, false)
        XCTAssertTrue(h.sleeps.contains(0.3))
        h.assertInvariants()
    }

    @MainActor
    func testOfflineNotCounted() async throws {
        let h = try SyncHarness()
        try h.seed([msg("a1", labels: ["INBOX", "UNREAD"])])
        try enqueueArchive(h, "a1")
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }

        await h.outbox.drain()

        let row = try XCTUnwrap(try h.outboxRows().first)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.attempts, 0)
        XCTAssertTrue(h.status.isOffline)
        h.assertInvariants()
    }

    @MainActor
    func testPermanent4xxRevertsE() async throws {
        let h = try SyncHarness()
        try h.seed([msg("a1", labels: ["INBOX", "UNREAD"])])
        try enqueueArchive(h, "a1")
        // Optimistic E already dropped INBOX.
        XCTAssertFalse(try h.message("a1")!.labelIds.contains("INBOX"))
        BatchStub.install(
            routes: [],
            parts: BatchStub.responder(modify: [
                "a1": (403, JSONFixtures.errorEnvelope(code: 403, reason: "insufficientPermissions", message: "no"))
            ]))

        await h.outbox.drain()

        XCTAssertTrue(try h.outboxRows().isEmpty)
        let m = try XCTUnwrap(h.message("a1"))
        XCTAssertEqual(m.labelIds, m.serverLabelIds, "E reverts to S")
        XCTAssertTrue(m.labelIds.contains("INBOX"))
        h.assertInvariants()
    }

    @MainActor
    func testBackoffSchedule() async throws {
        let h = try SyncHarness()
        try h.seed([msg("a1", labels: ["INBOX", "UNREAD"])])
        try enqueueArchive(h, "a1")
        BatchStub.install(
            routes: [],
            parts: BatchStub.responder(modify: [
                "a1": (500, JSONFixtures.errorEnvelope(code: 500, reason: "backendError", message: "boom"))
            ]))

        var delays: [Int64] = []
        for i in 1...8 {
            await h.outbox.drain()
            let row = try XCTUnwrap(try h.outboxRows().first { $0.kind == .modify })
            if i < 8 {
                XCTAssertEqual(row.state, .pending, "drain \(i)")
                XCTAssertEqual(row.attempts, i, "drain \(i)")
                let delta = row.nextAttemptAt - nowMs(h)
                delays.append(delta)
                h.advance(seconds: Double(delta) / 1000)
            } else {
                XCTAssertEqual(row.state, .failed)
            }
        }
        XCTAssertEqual(delays, [2000, 4000, 8000, 16000, 32000, 64000, 128000])
        XCTAssertFalse(try h.message("a1")!.labelIds.contains("INBOX"), "failed op keeps optimistic E")
        h.assertInvariants()
    }
}
