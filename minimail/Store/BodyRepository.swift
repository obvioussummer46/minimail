import Foundation
import GRDB
import MailCore
import MailHTML

nonisolated enum BodyRepository {
    /// Upserts the body row, replaces the message's attachment rows, sets `bodyState = 1` and exact `hasAttachments`.
    static func storeBody(
        _ db: Database, messageId: String, body: SanitizedBody?, text: String?, attachments: [ParsedAttachment],
        referenced: Set<String>, sanitizerVersion: Int, now: Int64
    ) throws {
        guard try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE id = ?", arguments: [messageId]) ?? false else {
            Log.db.notice("storeBody: unknown message")
            return
        }
        let record = MessageBodyRecord(
            messageId: messageId,
            bodyHtml: body?.html ?? Schema.unavailableBodyHTML,
            bodyText: text,
            hasRemoteImages: body?.hasRemoteImages ?? false,
            darkStrategy: body?.darkStrategy.rawValue ?? "plain",
            sanitizerVersion: sanitizerVersion,
            fetchedAt: now)
        try record.save(db)

        try db.execute(sql: "DELETE FROM attachment WHERE messageId = ?", arguments: [messageId])
        var anyReal = false
        for a in attachments where !a.filename.isEmpty {
            let isInline = a.contentId.map(referenced.contains) ?? false
            if !isInline { anyReal = true }
            try AttachmentRecord(
                messageId: messageId, partId: a.partId, filename: a.filename, mimeType: a.mimeType, size: a.size,
                contentId: a.contentId, isInline: isInline, attachmentId: a.attachmentId
            ).save(db)
        }
        try db.execute(
            sql: "UPDATE message SET bodyState = 1, hasAttachments = ? WHERE id = ?", arguments: [anyReal, messageId])
    }

    static func markUnavailable(_ db: Database, messageId: String) throws {
        try db.execute(sql: "UPDATE message SET bodyState = 2 WHERE id = ?", arguments: [messageId])
    }

    static func resetUnavailable(_ db: Database, messageId: String) throws {
        try db.execute(sql: "UPDATE message SET bodyState = 0 WHERE id = ? AND bodyState = 2", arguments: [messageId])
    }

    static func missingBodyIds(_ db: Database, threadId: String, sanitizerVersion: Int) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT m.id FROM message m LEFT JOIN message_body b ON b.messageId = m.id
                WHERE m.threadId = ? AND m.isHidden = 0
                  AND (m.bodyState = 0 OR (m.bodyState = 1 AND (b.messageId IS NULL OR b.sanitizerVersion < ?)))
                ORDER BY m.internalDate DESC, m.id DESC
                """,
            arguments: [threadId, sanitizerVersion])
    }

    static func attachment(_ db: Database, messageId: String, partId: String) throws -> AttachmentRecord? {
        try AttachmentRecord.fetchOne(
            db, sql: "SELECT * FROM attachment WHERE messageId = ? AND partId = ?", arguments: [messageId, partId])
    }

    static func updateAttachmentIds(_ db: Database, messageId: String, parsed: [ParsedAttachment]) throws {
        for a in parsed where a.attachmentId != nil {
            try db.execute(
                sql: "UPDATE attachment SET attachmentId = ? WHERE messageId = ? AND partId = ?",
                arguments: [a.attachmentId, messageId, a.partId])
        }
    }

    /// Deletes body rows beyond the newest `keepNewest`, resets their `bodyState`, recomputes aggregates.
    static func pruneBodies(_ db: Database, keepNewest: Int) throws -> Int {
        let victims = try String.fetchAll(
            db, sql: "SELECT messageId FROM message_body ORDER BY fetchedAt DESC, messageId ASC LIMIT -1 OFFSET ?",
            arguments: [keepNewest])
        guard !victims.isEmpty else { return 0 }
        let placeholders = databaseQuestionMarks(count: victims.count)
        try db.execute(
            sql: "DELETE FROM message_body WHERE messageId IN (\(placeholders))", arguments: StatementArguments(victims)
        )
        try db.execute(
            sql: "UPDATE message SET bodyState = 0 WHERE id IN (\(placeholders)) AND bodyState = 1",
            arguments: StatementArguments(victims))
        let threads = try MessageRepository.threadIds(db, of: Set(victims))
        try ThreadRepository.recomputeAggregates(
            db, threadIds: threads, selfAddresses: SyncStateRepository.selfAddresses(db))
        return victims.count
    }
}
