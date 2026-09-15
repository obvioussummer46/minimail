import GRDB
import MailCore
import MailHTML
import XCTest

@testable import minimail

nonisolated final class RepositoryTests: XCTestCase {
    private var queue: DatabaseQueue!
    private let now: Int64 = 1_757_500_000_000

    override func setUpWithError() throws {
        queue = try TestDatabase.make()
    }

    private func check() throws { try InvariantChecks.assertAll(queue) }

    // MARK: Message

    func testUpsertMetadataMapsColumns() throws {
        let p = TestDatabase.parsed(
            id: "m1", internalDate: 1000, labels: ["UNREAD", "INBOX"],
            cc: [Mailbox(name: "C", addr: "c@x")], topMimeType: "multipart/mixed")
        try TestDatabase.seed(queue, [p])
        let m = try queue.read { try MessageRepository.fetch($0, id: "m1") }!
        XCTAssertEqual(m.serverLabelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(m.labelIds, ["INBOX", "UNREAD"])
        XCTAssertTrue(m.isUnread)
        XCTAssertTrue(m.inInbox)
        XCTAssertTrue(m.hasAttachments)
        XCTAssertEqual(m.bodyState, 0)
        XCTAssertEqual(m.syncGeneration, 1)
        XCTAssertEqual(m.fetchedAt, now)
        XCTAssertNotNil(try queue.read { try ThreadRepository.fetch($0, id: "m1") })
        try check()
    }

    func testUpsertRecomputesEWithPendingOp() throws {
        try TestDatabase.seed(queue, [TestDatabase.parsed(id: "m1", internalDate: 1, labels: ["INBOX", "UNREAD"])])
        try queue.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "m1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)
            _ = try MessageRepository.upsertMetadata(
                db, parsed: [TestDatabase.parsed(id: "m1", internalDate: 1, labels: ["INBOX", "UNREAD"])],
                selfAddresses: ["user@example.com"], generation: 2, now: now)
            try ThreadRepository.recomputeAggregates(db, threadIds: ["m1"], selfAddresses: ["user@example.com"])
        }
        let m = try queue.read { try MessageRepository.fetch($0, id: "m1") }!
        XCTAssertEqual(m.serverLabelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(m.labelIds, ["INBOX"])
        XCTAssertFalse(m.isUnread)
        try check()
    }

    func testApplyServerLabelsAndDelta() throws {
        try TestDatabase.seed(queue, [TestDatabase.parsed(id: "m1", internalDate: 1, labels: ["INBOX"])])
        try queue.write { db in
            try MessageRepository.applyServerLabels(db, messageId: "m1", labels: ["INBOX", "STARRED"])
            try MessageRepository.applyServerDelta(
                db, messageId: "m1", delta: LabelDelta(add: ["UNREAD"], remove: ["INBOX"]))
            let threads = try MessageRepository.recomputeEffective(db, messageIds: ["m1"])
            try ThreadRepository.recomputeAggregates(db, threadIds: threads, selfAddresses: ["user@example.com"])
            try MessageRepository.applyServerLabels(db, messageId: "nope", labels: ["X"])  // no throw
        }
        let m = try queue.read { try MessageRepository.fetch($0, id: "m1") }!
        XCTAssertEqual(m.serverLabelIds, ["STARRED", "UNREAD"])
        XCTAssertEqual(m.labelIds, ["STARRED", "UNREAD"])
        try check()
    }

    // MARK: Outbox

    func testEnqueueModifyInsertsAndAppliesInstantly() throws {
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"]),
                TestDatabase.parsed(id: "m2", threadId: "t1", internalDate: 2, labels: ["INBOX"]),
            ])
        let opId = try queue.write { db in
            try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m1", "m2"], now: now)
        }
        XCTAssertNotNil(opId)
        let thread = try queue.read { try ThreadRepository.fetch($0, id: "t1") }!
        XCTAssertFalse(thread.inInbox)
        let hasInbox = try queue.read {
            try Bool.fetchOne(
                $0, sql: "SELECT 1 FROM thread_label WHERE threadId = 't1' AND labelId = 'INBOX'") ?? false
        }
        XCTAssertFalse(hasInbox)
        try check()
    }

    func testEnqueueInverseCancelsToZeroRows() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"])])
        try queue.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)
            let second = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(add: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)
            XCTAssertNil(second)
        }
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") }
        XCTAssertEqual(count, 0)
        let thread = try queue.read { try ThreadRepository.fetch($0, id: "t1") }!
        XCTAssertEqual(thread.unreadCount, 1)
        try check()
    }

    func testEnqueueArchiveThenReadMerges() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"])])
        try queue.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m1"], now: now)
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)
        }
        let ops = try queue.read { try OutboxRepository.pendingModifies($0) }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].removeLabelIds, ["INBOX", "UNREAD"])
        try check()
    }

    func testEnqueueDoesNotMergeIntoInFlight() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"])])
        try queue.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m1"], now: now)
            _ = try OutboxRepository.claimModifies(db, limit: 10, now: now)
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)
        }
        let total = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") }
        XCTAssertEqual(total, 2)
        XCTAssertEqual(try queue.read { try OutboxRepository.pendingModifies($0).count }, 1)
        try check()
    }

    func testAckModifyWithoutServerLabels() throws {
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"]),
                TestDatabase.parsed(id: "m2", threadId: "t1", internalDate: 2, labels: ["INBOX"]),
            ])
        let threads = try queue.write { db -> Set<String> in
            let opId = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m1", "m2"], now: now)!
            return try OutboxRepository.ackModify(db, opId: opId, serverLabelsByMessage: nil)
        }
        XCTAssertEqual(threads, ["t1"])
        let m1 = try queue.read { try MessageRepository.fetch($0, id: "m1") }!
        XCTAssertEqual(m1.serverLabelIds, ["UNREAD"])
        XCTAssertEqual(m1.labelIds, ["UNREAD"])
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") }, 0)
        try check()
    }

    func testDiscardModifyRevertsE() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"])])
        try queue.write { db in
            let opId = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)!
            _ = try OutboxRepository.discardModify(db, opId: opId)
        }
        let m1 = try queue.read { try MessageRepository.fetch($0, id: "m1") }!
        XCTAssertTrue(m1.isUnread)
        XCTAssertEqual(try queue.read { try ThreadRepository.fetch($0, id: "t1")!.unreadCount }, 1)
        try check()
    }

    func testRetryLaterCountsAndFailsAfterEight() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX"])])
        let opId = try queue.write { db in
            try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m1"], now: now)!
        }
        for n in 1...8 {
            try queue.write { db in
                _ = try OutboxRepository.claimModifies(db, limit: 10, now: now)
                try OutboxRepository.retryLater(db, opId: opId, error: "x", countsAsAttempt: true, nextAttemptAt: 5)
            }
            let op = try queue.read { try OutboxRepository.record($0, id: opId) }!
            XCTAssertEqual(op.attempts, n)
            XCTAssertEqual(op.state, n >= 8 ? .failed : .pending)
        }
        XCTAssertNotNil(try queue.read { try OutboxRepository.record($0, id: opId) })
        try check()
    }

    func testRearmMergesIntoPending() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "UNREAD"])])
        try queue.write { db in
            let failedId = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m1"], now: now)!
            try OutboxRepository.fail(db, opId: failedId, error: "boom")
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: now)
            try OutboxRepository.rearmFailedModifies(db)
        }
        let ops = try queue.read { try OutboxRepository.pendingModifies($0) }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].removeLabelIds, ["INBOX", "UNREAD"])
        try check()
    }

    func testStaleIdsExcludesOutboxReferenced() throws {
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX"]),
                TestDatabase.parsed(id: "m2", threadId: "t2", internalDate: 2, labels: ["INBOX"]),
            ], generation: 1)
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m3", threadId: "t3", internalDate: 3, labels: ["INBOX"])], generation: 2)
        try queue.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t2", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: ["m2"], now: now)
            _ = try OutboxRepository.enqueueSend(
                db,
                job: SendJob(
                    mode: .replyAll, originalMessageId: "m1", threadId: "t1", messageID: "<x@x>", to: [], cc: [],
                    subject: "", typedText: "", inReplyTo: nil, references: [],
                    quoteSource: QuoteSource(
                        author: nil, date: Date(timeIntervalSince1970: 1), subject: "", to: [], cc: [], html: nil,
                        text: nil), attachments: [], includeSignature: false), now: now)
        }
        XCTAssertEqual(try queue.read { try MessageRepository.staleIds($0, olderThanGeneration: 2) }, [])
        try check()
    }

    // MARK: Thread / body / label

    func testRecomputeAggregatesWritesThreadLabel() throws {
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX", "Label_12"]),
                TestDatabase.parsed(id: "m2", threadId: "t1", internalDate: 2, labels: ["INBOX", "UNREAD"]),
            ])
        let rows = try queue.read {
            try ThreadLabelRecord.fetchAll($0, sql: "SELECT * FROM thread_label WHERE threadId = 't1'")
        }
        XCTAssertEqual(Set(rows.map(\.labelId)), ["INBOX", "Label_12", "UNREAD"])
        XCTAssertTrue(rows.allSatisfy { $0.lastDate == 2 && $0.unreadCount == 1 })
        XCTAssertEqual(try queue.read { try ThreadRepository.fetch($0, id: "t1")!.userLabelIds }, ["Label_12"])
        try check()
    }

    func testMessageIdsIncludesHidden() throws {
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX"]),
                TestDatabase.parsed(id: "m2", threadId: "t1", internalDate: 2, labels: ["TRASH"]),
            ])
        XCTAssertEqual(try queue.read { try ThreadRepository.messageIds($0, threadId: "t1") }, ["m1", "m2"])
        try check()
    }

    func testStoreBodySetsStateAndAttachments() throws {
        try TestDatabase.seed(
            queue, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX"])])
        try queue.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "<p>x</p>", hasRemoteImages: true, darkStrategy: .card, referencedContentIDs: ["img1"]),
                text: "x",
                attachments: [
                    ParsedAttachment(
                        partId: "1", filename: "logo.png", mimeType: "image/png", size: 10, contentId: "img1",
                        attachmentId: "a1", inlineData: nil, charset: nil),
                    ParsedAttachment(
                        partId: "2", filename: "a.pdf", mimeType: "application/pdf", size: 20, contentId: nil,
                        attachmentId: "a2", inlineData: nil, charset: nil),
                    ParsedAttachment(
                        partId: "3", filename: "", mimeType: "text/plain", size: 0, contentId: nil, attachmentId: nil,
                        inlineData: nil, charset: nil),
                ], referenced: ["img1"], sanitizerVersion: 1, now: now)
            try ThreadRepository.recomputeAggregates(db, threadIds: ["t1"], selfAddresses: ["user@example.com"])
        }
        let m = try queue.read { try MessageRepository.fetch($0, id: "m1") }!
        XCTAssertEqual(m.bodyState, 1)
        XCTAssertTrue(m.hasAttachments)
        XCTAssertTrue(try queue.read { try BodyRepository.attachment($0, messageId: "m1", partId: "1")!.isInline })
        XCTAssertFalse(try queue.read { try BodyRepository.attachment($0, messageId: "m1", partId: "2")!.isInline })
        XCTAssertNil(try queue.read { try BodyRepository.attachment($0, messageId: "m1", partId: "3") })
        XCTAssertEqual(try queue.read { try ThreadRepository.fetch($0, id: "t1")!.bodiesMissing }, 0)
        try check()
    }

    func testPruneBodies() throws {
        var messages: [ParsedMessage] = []
        for i in 1...5 {
            messages.append(
                TestDatabase.parsed(id: "m\(i)", threadId: "t\(i)", internalDate: Int64(i), labels: ["INBOX"]))
        }
        try TestDatabase.seed(queue, messages)
        try queue.write { db in
            for i in 1...5 {
                try BodyRepository.storeBody(
                    db, messageId: "m\(i)",
                    body: SanitizedBody(
                        html: "<p>\(i)</p>", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []),
                    text: nil, attachments: [], referenced: [], sanitizerVersion: 1, now: Int64(i))
            }
            try ThreadRepository.recomputeAggregates(
                db, threadIds: ["t1", "t2", "t3", "t4", "t5"], selfAddresses: ["user@example.com"])
        }
        let pruned = try queue.write { try BodyRepository.pruneBodies($0, keepNewest: 2) }
        XCTAssertEqual(pruned, 3)
        let remaining = try queue.read {
            try Int64.fetchAll($0, sql: "SELECT fetchedAt FROM message_body ORDER BY fetchedAt")
        }
        XCTAssertEqual(remaining, [4, 5])
        try check()
    }

    func testLabelReplaceAllKeepsCountsAndColor() throws {
        try queue.write { db in
            try LabelRepository.replaceAll(db, labels: TestDatabase.sampleLabels)
            try LabelRepository.updateCounts(
                db,
                labels: [
                    GmailLabel(
                        id: "Label_12", name: "Customers/ACME", type: "user", threadsUnread: 3,
                        color: GmailLabelColor(textColor: "#ffffff", backgroundColor: "#4a86e8"))
                ],
                now: now)
            // replaceAll again without Label_12's colour and without Label_14
            try LabelRepository.replaceAll(
                db,
                labels: TestDatabase.sampleLabels.filter { $0.id != "Label_14" }.map {
                    $0.id == "Label_12"
                        ? GmailLabel(
                            id: "Label_12", name: "Customers/ACME", type: "user", labelListVisibility: "labelShow") : $0
                })
        }
        let label12 = try queue.read { try LabelRepository.fetch($0, id: "Label_12") }!
        XCTAssertEqual(label12.threadsUnread, 3)
        XCTAssertEqual(label12.backgroundColor, "#4a86e8")
        XCTAssertNil(try queue.read { try LabelRepository.fetch($0, id: "Label_14") })
        XCTAssertEqual(try queue.read { try LabelRepository.fetch($0, id: "INBOX")!.sortOrder }, 0)
        XCTAssertEqual(try queue.read { try LabelRepository.fetch($0, id: "SENT")!.sortOrder }, 30)
        XCTAssertEqual(try queue.read { try LabelRepository.fetch($0, id: "TRASH")!.sortOrder }, 500)
        XCTAssertEqual(try queue.read { try LabelRepository.fetch($0, id: "Label_12")!.sortOrder }, 1000)
    }

    func testDisplayedLabelIds() throws {
        try TestDatabase.seedLabels(queue, TestDatabase.sampleLabels)
        XCTAssertEqual(
            try queue.read { try LabelRepository.displayedLabelIds($0) },
            ["INBOX", "STARRED", "IMPORTANT", "SENT", "Label_12", "Label_14"])
        XCTAssertEqual(try queue.read { try LabelRepository.displayedLabelIds($0, cap: 5) }.count, 5)
    }

    // MARK: SyncState

    func testSyncStateRoundTrip() throws {
        try queue.write { db in
            try SyncStateRepository.set(db, .accountEmail, "x@example.com")
            XCTAssertEqual(try SyncStateRepository.get(db, .accountEmail), "x@example.com")
            try SyncStateRepository.setInt64(db, .syncGeneration, 5)
            XCTAssertEqual(try SyncStateRepository.int64(db, .syncGeneration), 5)
            try SyncStateRepository.set(db, .accountEmail, nil)
            XCTAssertNil(try SyncStateRepository.get(db, .accountEmail))
        }
    }

    func testSetHistoryIdNeverDecreases() throws {
        try queue.write { db in
            try SyncStateRepository.setHistoryId(db, 100)
            try SyncStateRepository.setHistoryId(db, 50)
            XCTAssertEqual(try SyncStateRepository.historyId(db), 100)
            try SyncStateRepository.setHistoryId(db, 50, allowDecrease: true)
            XCTAssertEqual(try SyncStateRepository.historyId(db), 50)
        }
    }

    func testSelfAddresses() throws {
        try queue.write { db in
            try SyncStateRepository.setSelfAddresses(db, ["B@x", "a@x"])
            XCTAssertEqual(try SyncStateRepository.get(db, .selfAddresses), "[\"a@x\",\"b@x\"]")
            XCTAssertEqual(try SyncStateRepository.selfAddresses(db), ["a@x", "b@x"])
        }
        XCTAssertEqual(try queue.read { try SyncStateRepository.selfAddresses($0) }, ["a@x", "b@x"])
    }

    func testDeleteExpiredThreads() throws {
        let old: Int64 = 1_000_000
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: old, labels: []),  // archived, read, old
                TestDatabase.parsed(id: "m2", threadId: "t2", internalDate: old, labels: ["Label_12"]),  // protected
                TestDatabase.parsed(id: "m3", threadId: "t3", internalDate: old, labels: []),  // protected id
                TestDatabase.parsed(id: "m4", threadId: "t4", internalDate: 9_000_000_000_000, labels: ["INBOX"]),
                TestDatabase.parsed(id: "m5", threadId: "t5", internalDate: old, labels: ["UNREAD"]),  // unread
            ])
        let deleted = try queue.write {
            try ThreadRepository.deleteExpired(
                $0, olderThan: 5_000_000, protectedLabelIds: ["Label_12"], protectedThreadIds: ["t3"])
        }
        XCTAssertEqual(deleted, 1)
        XCTAssertNil(try queue.read { try ThreadRepository.fetch($0, id: "t1") })
        XCTAssertNotNil(try queue.read { try ThreadRepository.fetch($0, id: "t2") })
        XCTAssertNotNil(try queue.read { try ThreadRepository.fetch($0, id: "t3") })
        try check()
    }
}
