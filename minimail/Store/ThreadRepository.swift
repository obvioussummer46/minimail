import Foundation
import GRDB
import MailCore

nonisolated enum ThreadRepository {
    /// Recomputes the `thread` row and its `thread_label` set for each id; deletes empty threads.
    static func recomputeAggregates(_ db: Database, threadIds: Set<String>, selfAddresses: Set<String>) throws {
        for threadId in threadIds {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, internalDate, subject, snippet, fromName, fromAddr, isFromMe, isUnread, inInbox,
                    hasAttachments, bodyState, labelIds FROM message WHERE threadId = ? AND isHidden = 0
                    """,
                arguments: [threadId])
            let inputs = rows.map { row in
                AggregateInput(
                    id: row["id"],
                    internalDate: row["internalDate"],
                    subject: row["subject"],
                    snippet: row["snippet"],
                    fromName: row["fromName"],
                    fromAddr: row["fromAddr"],
                    isFromMe: row["isFromMe"],
                    isUnread: row["isUnread"],
                    inInbox: row["inInbox"],
                    hasAttachments: row["hasAttachments"],
                    bodyState: row["bodyState"],
                    labelIds: LabelAlgebra.parseJSON(row["labelIds"])
                )
            }
            guard let agg = ThreadAggregator.aggregate(inputs, selfAddresses: selfAddresses) else {
                try db.execute(sql: "DELETE FROM thread_label WHERE threadId = ?", arguments: [threadId])
                try db.execute(sql: "DELETE FROM thread WHERE id = ?", arguments: [threadId])
                continue
            }
            let isComplete =
                try Bool.fetchOne(db, sql: "SELECT isComplete FROM thread WHERE id = ?", arguments: [threadId]) ?? false
            let record = ThreadRecord(
                id: threadId, subject: agg.subject, snippet: agg.snippet, lastDate: agg.lastDate,
                lastInboxDate: agg.lastInboxDate, messageCount: agg.messageCount, unreadCount: agg.unreadCount,
                inInbox: agg.inInbox, hasAttachments: agg.hasAttachments, participants: agg.participants,
                userLabelIds: agg.userLabelIds, isComplete: isComplete, bodiesMissing: agg.bodiesMissing)
            try record.save(db)

            try db.execute(sql: "DELETE FROM thread_label WHERE threadId = ?", arguments: [threadId])
            for labelId in agg.allLabelIds.sorted() {
                try ThreadLabelRecord(
                    labelId: labelId, threadId: threadId, lastDate: agg.lastDate, unreadCount: agg.unreadCount
                ).insert(db)
            }
        }
    }

    static func markComplete(_ db: Database, threadId: String, complete: Bool) throws {
        try db.execute(sql: "UPDATE thread SET isComplete = ? WHERE id = ?", arguments: [complete, threadId])
    }

    /// ALL message ids of the thread (hidden included), internalDate ASC, id ASC.
    static func messageIds(_ db: Database, threadId: String) throws -> [String] {
        try String.fetchAll(
            db, sql: "SELECT id FROM message WHERE threadId = ? ORDER BY internalDate, id", arguments: [threadId])
    }

    static func fetch(_ db: Database, id: String) throws -> ThreadRecord? {
        try ThreadRecord.fetchOne(db, key: id)
    }

    static func idsExisting(_ db: Database, among ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        for chunk in Array(ids).chunked(500) {
            let placeholders = databaseQuestionMarks(count: chunk.count)
            found.formUnion(
                try String.fetchAll(
                    db, sql: "SELECT id FROM thread WHERE id IN (\(placeholders))", arguments: StatementArguments(chunk)
                ))
        }
        return found
    }

    /// Deletes archived, fully-read, old threads (excluding protected labels/ids); returns the count.
    static func deleteExpired(
        _ db: Database, olderThan: Int64, protectedLabelIds: Set<String>, protectedThreadIds: Set<String>
    ) throws -> Int {
        let candidates = try String.fetchAll(
            db, sql: "SELECT id FROM thread WHERE inInbox = 0 AND unreadCount = 0 AND lastDate < ?",
            arguments: [olderThan])
        var deleted = 0
        for threadId in candidates {
            if protectedThreadIds.contains(threadId) { continue }
            if !protectedLabelIds.isEmpty {
                let placeholders = databaseQuestionMarks(count: protectedLabelIds.count)
                let isProtected =
                    try Bool.fetchOne(
                        db,
                        sql: "SELECT 1 FROM thread_label WHERE threadId = ? AND labelId IN (\(placeholders)) LIMIT 1",
                        arguments: StatementArguments([threadId] + Array(protectedLabelIds))) ?? false
                if isProtected { continue }
            }
            try db.execute(sql: "DELETE FROM message WHERE threadId = ?", arguments: [threadId])
            try db.execute(sql: "DELETE FROM thread_label WHERE threadId = ?", arguments: [threadId])
            try db.execute(sql: "DELETE FROM thread WHERE id = ?", arguments: [threadId])
            deleted += 1
        }
        return deleted
    }
}
