import GRDB
import MailCore
import XCTest

@testable import minimail

/// Runs the §3.5 invariants 1–4 and 6 (5 is checked by `SyncStateRepository.setHistoryId`'s own test).
nonisolated enum InvariantChecks {
    static func assertAll(_ reader: any DatabaseReader, file: StaticString = #filePath, line: UInt = #line) throws {
        try reader.read { try assertAll($0, file: file, line: line) }
    }

    static func assertAll(_ db: Database, file: StaticString = #filePath, line: UInt = #line) throws {
        let messages = try MessageRecord.fetchAll(db)
        let ops = try OutboxRepository.modifiesAffectingEffective(db)

        // 1 + 2: effective labels and flags per message.
        for m in messages {
            let pending = ops.filter { $0.affectedSet.contains(m.id) }.map(\.delta)
            let effective = LabelAlgebra.effective(server: m.serverLabelSet, pending: pending)
            XCTAssertEqual(m.labelIds, effective.sorted(), "invariant 1: message \(m.id)", file: file, line: line)
            let flags = LabelAlgebra.flags(m.labelSet)
            XCTAssertEqual(m.isUnread, flags.isUnread, "invariant 2 isUnread \(m.id)", file: file, line: line)
            XCTAssertEqual(m.inInbox, flags.inInbox, "invariant 2 inInbox \(m.id)", file: file, line: line)
            XCTAssertEqual(m.isHidden, flags.isHidden, "invariant 2 isHidden \(m.id)", file: file, line: line)
        }

        // 3: thread aggregates + thread_label; every visible message has a thread row.
        let selfAddresses = try SyncStateRepository.selfAddresses(db)
        let threads = try ThreadRecord.fetchAll(db)
        let threadIds = Set(threads.map(\.id))
        for m in messages where !m.isHidden {
            XCTAssertTrue(
                threadIds.contains(m.threadId), "invariant 3: visible \(m.id) has no thread", file: file, line: line)
        }
        for thread in threads {
            let inputs = messages.filter { $0.threadId == thread.id && !$0.isHidden }.map {
                AggregateInput(
                    id: $0.id, internalDate: $0.internalDate, subject: $0.subject, snippet: $0.snippet,
                    fromName: $0.fromName, fromAddr: $0.fromAddr, isFromMe: $0.isFromMe, isUnread: $0.isUnread,
                    inInbox: $0.inInbox, hasAttachments: $0.hasAttachments, bodyState: $0.bodyState,
                    labelIds: $0.labelSet)
            }
            guard let agg = ThreadAggregator.aggregate(inputs, selfAddresses: selfAddresses) else {
                XCTFail("invariant 3: thread \(thread.id) has no visible messages", file: file, line: line)
                continue
            }
            XCTAssertEqual(thread.subject, agg.subject, "invariant 3 subject \(thread.id)", file: file, line: line)
            XCTAssertEqual(thread.lastDate, agg.lastDate, "invariant 3 lastDate \(thread.id)", file: file, line: line)
            XCTAssertEqual(
                thread.unreadCount, agg.unreadCount, "invariant 3 unread \(thread.id)", file: file, line: line)
            XCTAssertEqual(thread.inInbox, agg.inInbox, "invariant 3 inInbox \(thread.id)", file: file, line: line)
            XCTAssertEqual(
                thread.userLabelIds, agg.userLabelIds, "invariant 3 labels \(thread.id)", file: file, line: line)
            // 6: bodiesMissing
            XCTAssertEqual(thread.bodiesMissing, agg.bodiesMissing, "invariant 6 \(thread.id)", file: file, line: line)

            let labelRows = try ThreadLabelRecord.fetchAll(
                db, sql: "SELECT * FROM thread_label WHERE threadId = ?", arguments: [thread.id])
            XCTAssertEqual(
                Set(labelRows.map(\.labelId)), agg.allLabelIds, "invariant 3 thread_label \(thread.id)", file: file,
                line: line)
            for row in labelRows {
                XCTAssertEqual(
                    row.lastDate, agg.lastDate, "invariant 3 tl.lastDate \(thread.id)", file: file, line: line)
                XCTAssertEqual(
                    row.unreadCount, agg.unreadCount, "invariant 3 tl.unread \(thread.id)", file: file, line: line)
            }
        }

        // 4: at most one pending modify per thread.
        let dupes =
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (SELECT threadId FROM outbox WHERE kind = 'modify' AND state = 'pending'
                    GROUP BY threadId HAVING COUNT(*) > 1)
                    """) ?? 0
        XCTAssertEqual(dupes, 0, "invariant 4: multiple pending ops per thread", file: file, line: line)
    }
}
