import GRDB
import MailCore
import XCTest

@testable import minimail

nonisolated final class QueriesTests: XCTestCase {
    private var queue: DatabaseQueue!
    private let now = Date(timeIntervalSince1970: 1_757_600_000)
    private let tz = TimeZone(identifier: "Europe/Berlin")!
    private let locale = Locale(identifier: "en_US")

    override func setUpWithError() throws {
        queue = try TestDatabase.make()
    }

    private func labelsById() throws -> [String: LabelRecord] {
        try queue.read { try Queries.labelsById($0) }
    }

    private func run(_ q: ThreadQuery) throws -> [ThreadRow] {
        let labels = try labelsById()
        return try queue.read { try Queries.threads(q, now: now, timeZone: tz, locale: locale, labels: labels)($0) }
    }

    func testInboxScope() throws {
        try TestDatabase.seedMany(queue, count: 200)
        let rows = try run(ThreadQuery(scope: .inbox))
        XCTAssertLessThanOrEqual(rows.count, 60)
        // Sorted by lastDate DESC → the query returns the newest inbox threads.
        let expected = try queue.read {
            try String.fetchAll($0, sql: "SELECT id FROM thread WHERE inInbox = 1 ORDER BY lastDate DESC LIMIT 60")
        }
        XCTAssertEqual(rows.map(\.id), expected)
    }

    func testInboxUnreadOnly() throws {
        try TestDatabase.seedMany(queue, count: 200)
        let rows = try run(ThreadQuery(scope: .inbox, unreadOnly: true))
        XCTAssertTrue(rows.allSatisfy(\.isUnread))
        let expected = try queue.read {
            try String.fetchAll(
                $0, sql: "SELECT id FROM thread WHERE inInbox = 1 AND unreadCount > 0 ORDER BY lastDate DESC LIMIT 60")
        }
        XCTAssertEqual(Set(rows.map(\.id)), Set(expected))
    }

    func testLabelScope() throws {
        try TestDatabase.seedMany(queue, count: 200)
        let rows = try run(ThreadQuery(scope: .label(id: "Label_12")))
        let expected = try queue.read {
            try String.fetchAll(
                $0,
                sql: "SELECT threadId FROM thread_label WHERE labelId = 'Label_12' ORDER BY lastDate DESC LIMIT 60")
        }
        XCTAssertEqual(rows.map(\.id), expected)
    }

    func testTodayScope() throws {
        let day = DayBoundary.today(now: now, timeZone: tz)
        let inToday = day.startMs + 3_600_000
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(
                    id: "a", threadId: "A", internalDate: inToday, labels: ["INBOX"],
                    from: Mailbox(name: "Al", addr: "al@x")),
                TestDatabase.parsed(id: "c", threadId: "C", internalDate: inToday, labels: []),  // archived today
            ])
        let rows = try run(ThreadQuery(scope: .today(day)))
        XCTAssertEqual(rows.map(\.id), ["A"])
        XCTAssertEqual(try queue.read { try Queries.todayThreadCount($0, day) }, 1)
    }

    func testThreadRowPrecomputation() throws {
        try TestDatabase.seedLabels(
            queue,
            [
                GmailLabel(id: "INBOX", name: "INBOX", type: "system"),
                GmailLabel(id: "Label_1", name: "One", type: "user"),
                GmailLabel(id: "Label_12", name: "Twelve", type: "user"),
            ])
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(
                    id: "m1", threadId: "t1", internalDate: 10, labels: ["INBOX", "Label_12"],
                    from: Mailbox(name: "Alice", addr: "alice@x")),
                TestDatabase.parsed(
                    id: "m2", threadId: "t1", internalDate: 20, labels: ["INBOX"],
                    from: Mailbox(name: "Me", addr: "user@example.com")),
                TestDatabase.parsed(
                    id: "m3", threadId: "t1", internalDate: 30, labels: ["INBOX", "Label_1", "Label_9"],
                    from: Mailbox(name: "Bob", addr: "bob@x")),
            ])
        let rows = try run(ThreadQuery(scope: .inbox))
        let row = try XCTUnwrap(rows.first { $0.id == "t1" })
        XCTAssertEqual(row.participants, "Alice, Me, Bob")
        XCTAssertEqual(row.chips.map(\.id), ["Label_1", "Label_12"])
        XCTAssertEqual(row.messageCount, 3)
        XCTAssertEqual(row.dateLabel, RowDateLabeler(now: now, timeZone: tz, locale: locale).label(epochMs: 30))
    }

    func testThreadDetail() throws {
        try TestDatabase.seed(
            queue,
            [
                TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: 1, labels: ["INBOX"]),
                TestDatabase.parsed(id: "m2", threadId: "t1", internalDate: 2, labels: ["INBOX"]),
                TestDatabase.parsed(id: "m3", threadId: "t1", internalDate: 3, labels: ["TRASH"]),
            ])
        try queue.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1", body: nil, text: nil, attachments: [], referenced: [], sanitizerVersion: 1, now: 1)
        }
        let detail = try XCTUnwrap(try queue.read { try Queries.threadDetail($0, threadId: "t1") })
        XCTAssertEqual(detail.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(Array(detail.bodies.keys), ["m1"])
        XCTAssertNil(try queue.read { try Queries.threadDetail($0, threadId: "nope") })
    }

    func testLabelsForSheet() throws {
        try TestDatabase.seedLabels(queue, TestDatabase.sampleLabels)
        // Label_14 is labelShowIfUnread; with threadsUnread 0 it is excluded until unread > 0.
        try queue.write {
            try LabelRepository.updateCounts(
                $0, labels: [GmailLabel(id: "Label_14", name: "IfUnread", type: "user", threadsUnread: 0)], now: 1)
        }
        var ids = try queue.read { try Queries.labelsForSheet($0).map(\.id) }
        XCTAssertEqual(ids, ["INBOX", "STARRED", "IMPORTANT", "SENT", "Label_12"])
        try queue.write {
            try LabelRepository.updateCounts(
                $0, labels: [GmailLabel(id: "Label_14", name: "IfUnread", type: "user", threadsUnread: 2)], now: 1)
        }
        ids = try queue.read { try Queries.labelsForSheet($0).map(\.id) }
        XCTAssertTrue(ids.contains("Label_14"))
        XCTAssertFalse(ids.contains("Label_13"))
        XCTAssertFalse(ids.contains("TRASH"))
    }

    func testLabelsById() throws {
        try TestDatabase.seedLabels(queue, TestDatabase.sampleLabels)
        let byId = try labelsById()
        XCTAssertEqual(byId.count, TestDatabase.sampleLabels.count)
        XCTAssertEqual(byId["Label_12"]?.name, "Customers/ACME")
    }

    func testFailedSendsAndOutboxCounts() throws {
        try queue.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: [], now: 1)
            let send1 = try OutboxRepository.enqueueSend(db, job: sampleSendJob(), now: 1)
            _ = try OutboxRepository.claimSend(db, now: 1)
            _ = send1
            let send2 = try OutboxRepository.enqueueSend(db, job: sampleSendJob(), now: 1)
            try OutboxRepository.fail(db, opId: send2, error: "x")
            let mod2 = try OutboxRepository.enqueueModify(
                db, threadId: "t2", delta: LabelDelta(remove: ["INBOX"]), affectedMessageIds: [], now: 1)!
            try OutboxRepository.fail(db, opId: mod2, error: "x")
        }
        XCTAssertEqual(try queue.read { try Queries.failedSends($0).count }, 1)
        let counts = try queue.read { try Queries.outboxCounts($0) }
        XCTAssertEqual(counts.pending, 2)  // pending modify t1 + inFlight send
        XCTAssertEqual(counts.failed, 1)
    }

    func testInboxUnreadThreadCount() throws {
        try TestDatabase.seedMany(queue, count: 200)
        let expected = try queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM thread WHERE inInbox = 1 AND unreadCount > 0")
        }
        XCTAssertEqual(try queue.read { try Queries.inboxUnreadThreadCount($0) }, expected)
    }

    func testExplainQueryPlanUsesIndexes() throws {
        try TestDatabase.seedMany(queue, count: 200)
        let day = DayBoundary.today(now: now, timeZone: tz)
        let cases: [(ThreadQuery, String)] = [
            (ThreadQuery(scope: .inbox), "thread_inbox_date"),
            (ThreadQuery(scope: .inbox, unreadOnly: true), "thread_inbox_unread"),
            (ThreadQuery(scope: .today(day)), "thread_inbox_today"),
            (ThreadQuery(scope: .label(id: "Label_12")), "thread_label_date"),
        ]
        for (q, index) in cases {
            let (sql, args) = Queries.threadsSQL(q)
            let plan = try queue.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: args).map { $0["detail"] as String }
            }
            XCTAssertTrue(plan.contains { $0.contains(index) }, "\(index) not used: \(plan)")
        }
    }

    private func sampleSendJob() -> SendJob {
        SendJob(
            mode: .replyAll, originalMessageId: "m1", threadId: "t1", messageID: "<x@x>", to: [], cc: [], subject: "",
            typedText: "", inReplyTo: nil, references: [],
            quoteSource: QuoteSource(
                author: nil, date: Date(timeIntervalSince1970: 1), subject: "", to: [], cc: [], html: nil, text: nil),
            attachments: [], includeSignature: false)
    }
}
