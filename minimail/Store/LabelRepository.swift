import Foundation
import GRDB
import MailCore

nonisolated enum LabelRepository {
    static let pinnedSystemIds = ["INBOX", "STARRED", "IMPORTANT", "SENT"]
    static let otherSystemSortOrder = 500
    static let userSortOrder = 1000

    private static func sortOrder(for label: GmailLabel) -> Int {
        if let index = pinnedSystemIds.firstIndex(of: label.id) { return index * 10 }
        return (label.type == "user") ? userSortOrder : otherSystemSortOrder
    }

    /// Upserts identity/visibility/sortOrder; keeps counts/colour/view columns of surviving rows; deletes absent rows.
    static func replaceAll(_ db: Database, labels: [GmailLabel]) throws {
        let incoming = labels.map(\.id)
        if incoming.isEmpty {
            try db.execute(sql: "DELETE FROM label")
        } else {
            let placeholders = databaseQuestionMarks(count: incoming.count)
            try db.execute(
                sql: "DELETE FROM label WHERE id NOT IN (\(placeholders))",
                arguments: StatementArguments(incoming))
        }
        for label in labels {
            let order = sortOrder(for: label)
            let type = label.type ?? "user"
            let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM label WHERE id = ?", arguments: [label.id]) ?? false
            if exists {
                if let color = label.color {
                    try db.execute(
                        sql: """
                            UPDATE label SET name = ?, type = ?, labelListVisibility = ?, messageListVisibility = ?,
                            sortOrder = ?, textColor = ?, backgroundColor = ? WHERE id = ?
                            """,
                        arguments: [
                            label.name, type, label.labelListVisibility, label.messageListVisibility, order,
                            color.textColor, color.backgroundColor, label.id,
                        ])
                } else {
                    try db.execute(
                        sql: """
                            UPDATE label SET name = ?, type = ?, labelListVisibility = ?, messageListVisibility = ?,
                            sortOrder = ? WHERE id = ?
                            """,
                        arguments: [
                            label.name, type, label.labelListVisibility, label.messageListVisibility, order, label.id,
                        ])
                }
            } else {
                let record = LabelRecord(
                    id: label.id, name: label.name, type: type, labelListVisibility: label.labelListVisibility,
                    messageListVisibility: label.messageListVisibility, textColor: label.color?.textColor,
                    backgroundColor: label.color?.backgroundColor, messagesUnread: nil, threadsUnread: nil,
                    threadsTotal: nil, countsFetchedAt: nil, sortOrder: order, viewFetchedAt: nil,
                    viewNextPageToken: nil)
                try record.insert(db)
            }
        }
    }

    /// From `labels.get`: counts + colour + `countsFetchedAt`; ids without a row are ignored.
    static func updateCounts(_ db: Database, labels: [GmailLabel], now: Int64) throws {
        for label in labels {
            try db.execute(
                sql: """
                    UPDATE label SET messagesUnread = ?, threadsUnread = ?, threadsTotal = ?,
                    textColor = COALESCE(?, textColor), backgroundColor = COALESCE(?, backgroundColor),
                    countsFetchedAt = ? WHERE id = ?
                    """,
                arguments: [
                    label.messagesUnread, label.threadsUnread, label.threadsTotal, label.color?.textColor,
                    label.color?.backgroundColor, now, label.id,
                ])
        }
    }

    static func markViewFetched(_ db: Database, labelId: String, nextPageToken: String?, now: Int64) throws {
        try db.execute(
            sql: "UPDATE label SET viewFetchedAt = ?, viewNextPageToken = ? WHERE id = ?",
            arguments: [now, nextPageToken, labelId])
    }

    static func cachedViewLabelIds(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM label WHERE viewFetchedAt IS NOT NULL ORDER BY id")
    }

    static func displayedLabelIds(_ db: Database, cap: Int = 60) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT id FROM label
                WHERE id IN ('INBOX','STARRED','IMPORTANT','SENT')
                   OR (type = 'user' AND (labelListVisibility IS NULL OR labelListVisibility != 'labelHide'))
                ORDER BY sortOrder, name COLLATE NOCASE
                LIMIT ?
                """,
            arguments: [cap])
    }

    static func fetch(_ db: Database, id: String) throws -> LabelRecord? {
        try LabelRecord.fetchOne(db, key: id)
    }
}

/// `?,?,?` for `count` bindings.
nonisolated func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
