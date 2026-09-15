import Foundation
import GRDB
import MailCore

nonisolated struct ThreadQuery: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case inbox, today(DayBoundary), label(id: String) }
    var scope: Scope
    var unreadOnly: Bool
    var limit: Int
    static let pageSize = 60
    init(scope: Scope, unreadOnly: Bool = false, limit: Int = ThreadQuery.pageSize) {
        self.scope = scope
        self.unreadOnly = unreadOnly
        self.limit = limit
    }
}

/// DEVIATION D4: a struct instead of the architecture's tuple array (tuples cannot synthesize `Equatable`).
nonisolated struct ThreadChip: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var textColor: String?
    var backgroundColor: String?
}

/// Fully precomputed row projection (no formatting in `body`).
nonisolated struct ThreadRow: Identifiable, Equatable, Sendable {
    var id: String
    var participants: String
    var subject: String
    var snippet: String
    var dateLabel: String
    var isUnread: Bool
    var messageCount: Int
    var hasAttachments: Bool
    var chips: [ThreadChip]
}

nonisolated struct ThreadDetail: Sendable, Equatable {
    var thread: ThreadRecord
    var messages: [MessageRecord]
    var bodies: [String: MessageBodyRecord]
    var attachments: [AttachmentRecord]
}

nonisolated enum Queries {
    static let maxChips = 2

    static func threadsSQL(_ q: ThreadQuery) -> (sql: String, arguments: StatementArguments) {
        let unread = q.unreadOnly
        switch q.scope {
        case .inbox:
            let sql = """
                SELECT id, subject, snippet, participants, lastDate, unreadCount, messageCount, hasAttachments, userLabelIds
                FROM thread WHERE inInbox = 1\(unread ? " AND unreadCount > 0" : "") ORDER BY lastDate DESC LIMIT ?
                """
            return (sql, [q.limit])
        case .today(let day):
            let sql = """
                SELECT id, subject, snippet, participants, lastDate, unreadCount, messageCount, hasAttachments, userLabelIds
                FROM thread WHERE inInbox = 1 AND lastInboxDate >= ? AND lastInboxDate < ?\(unread ? " AND unreadCount > 0" : "")
                ORDER BY lastInboxDate DESC LIMIT ?
                """
            return (sql, [day.startMs, day.endMs, q.limit])
        case .label(let id):
            let sql = """
                SELECT t.id, t.subject, t.snippet, t.participants, t.lastDate, t.unreadCount, t.messageCount, t.hasAttachments, t.userLabelIds
                FROM thread_label tl JOIN thread t ON t.id = tl.threadId
                WHERE tl.labelId = ?\(unread ? " AND tl.unreadCount > 0" : "") ORDER BY tl.lastDate DESC LIMIT ?
                """
            return (sql, [id, q.limit])
        }
    }

    static func threads(
        _ q: ThreadQuery, now: Date, timeZone: TimeZone, locale: Locale, labels: [String: LabelRecord]
    ) -> @Sendable (Database) throws -> [ThreadRow] {
        return { db in
            let (sql, args) = threadsSQL(q)
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            let labeler = RowDateLabeler(now: now, timeZone: timeZone, locale: locale)
            return rows.map { r in
                ThreadRow(
                    id: r["id"], participants: r["participants"], subject: r["subject"], snippet: r["snippet"],
                    dateLabel: labeler.label(epochMs: r["lastDate"]), isUnread: (r["unreadCount"] as Int) > 0,
                    messageCount: r["messageCount"], hasAttachments: r["hasAttachments"],
                    chips: chips(r["userLabelIds"], labels))
            }
        }
    }

    private static func chips(_ json: String, _ labels: [String: LabelRecord]) -> [ThreadChip] {
        LabelAlgebra.parseJSON(json).sorted().compactMap { labels[$0] }.prefix(maxChips).map {
            ThreadChip(id: $0.id, name: $0.name, textColor: $0.textColor, backgroundColor: $0.backgroundColor)
        }
    }

    static func threadDetail(_ db: Database, threadId: String) throws -> ThreadDetail? {
        guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
        let messages = try MessageRecord.fetchAll(
            db, sql: "SELECT * FROM message WHERE threadId = ? AND isHidden = 0 ORDER BY internalDate ASC, id ASC",
            arguments: [threadId])
        let ids = messages.map(\.id)
        var bodies: [String: MessageBodyRecord] = [:]
        var attachments: [AttachmentRecord] = []
        if !ids.isEmpty {
            let placeholders = databaseQuestionMarks(count: ids.count)
            for body in try MessageBodyRecord.fetchAll(
                db, sql: "SELECT * FROM message_body WHERE messageId IN (\(placeholders))",
                arguments: StatementArguments(ids))
            {
                bodies[body.messageId] = body
            }
            attachments = try AttachmentRecord.fetchAll(
                db, sql: "SELECT * FROM attachment WHERE messageId IN (\(placeholders)) ORDER BY messageId, partId",
                arguments: StatementArguments(ids))
        }
        return ThreadDetail(thread: thread, messages: messages, bodies: bodies, attachments: attachments)
    }

    static func labelsForSheet(_ db: Database) throws -> [LabelRecord] {
        try LabelRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM label WHERE id IN ('INBOX','STARRED','IMPORTANT','SENT')
                   OR (type = 'user' AND (labelListVisibility IS NULL OR labelListVisibility = 'labelShow'
                        OR (labelListVisibility = 'labelShowIfUnread' AND (threadsUnread IS NULL OR threadsUnread > 0))))
                ORDER BY sortOrder, name COLLATE NOCASE
                """)
    }

    static func labelsById(_ db: Database) throws -> [String: LabelRecord] {
        Dictionary(uniqueKeysWithValues: try LabelRecord.fetchAll(db).map { ($0.id, $0) })
    }

    static func failedSends(_ db: Database) throws -> [OutboxRecord] {
        try OutboxRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE kind = 'send' AND state = 'failed' ORDER BY id")
    }

    static func inboxUnreadThreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE inInbox = 1 AND unreadCount > 0") ?? 0
    }

    static func todayThreadCount(_ db: Database, _ day: DayBoundary) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM thread WHERE inInbox = 1 AND lastInboxDate >= ? AND lastInboxDate < ?",
            arguments: [day.startMs, day.endMs]) ?? 0
    }

    static func outboxCounts(_ db: Database) throws -> (pending: Int, failed: Int) {
        let row = try Row.fetchOne(
            db,
            sql:
                "SELECT SUM(state IN ('pending','inFlight')) AS p, SUM(kind = 'send' AND state = 'failed') AS f FROM outbox"
        )
        return (pending: row?["p"] ?? 0, failed: row?["f"] ?? 0)
    }
}
