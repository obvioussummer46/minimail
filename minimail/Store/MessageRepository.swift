import Foundation
import GRDB
import MailCore

nonisolated enum MessageRepository {
    private static let chunkSize = 500

    /// Writes S (+ headers, snippet, topMimeType, syncGeneration, fetchedAt) for every parsed message; then
    /// recomputes E for these ids. Returns the thread ids of every message written.
    static func upsertMetadata(
        _ db: Database, parsed: [ParsedMessage], selfAddresses: Set<String>, generation: Int, now: Int64
    ) throws -> Set<String> {
        guard !parsed.isEmpty else { return [] }
        // De-duplicate ids, last wins.
        var byId: [String: ParsedMessage] = [:]
        for p in parsed { byId[p.id] = p }

        for p in byId.values {
            let existing = try MessageRecord.fetchOne(db, key: p.id)
            let fromAddr = p.headers.from?.addr ?? ""
            let fromName = p.headers.from?.name.flatMap { $0.isEmpty ? nil : $0 }
            let hasAttachments: Bool
            if existing?.bodyState == 1 {
                hasAttachments = existing?.hasAttachments ?? false
            } else {
                hasAttachments = p.topMimeType == "multipart/mixed"
            }
            let record = MessageRecord(
                id: p.id,
                threadId: p.threadId,
                historyId: Int64(clamping: p.historyId),
                internalDate: p.internalDate,
                fromName: fromName,
                fromAddr: fromAddr,
                isFromMe: selfAddresses.contains(fromAddr.lowercased()),
                toList: p.headers.to,
                ccList: p.headers.cc,
                replyToList: p.headers.replyTo,
                subject: p.headers.subject,
                snippet: p.snippet,
                messageIdHeader: p.headers.messageID,
                inReplyTo: p.headers.inReplyTo,
                referencesList: p.headers.references,
                topMimeType: p.topMimeType,
                serverLabelIds: Set(p.labelIds).sorted(),
                labelIds: existing?.labelIds ?? [],
                isUnread: existing?.isUnread ?? false,
                inInbox: existing?.inInbox ?? false,
                isHidden: existing?.isHidden ?? false,
                hasAttachments: hasAttachments,
                bodyState: existing?.bodyState ?? 0,
                syncGeneration: generation,
                fetchedAt: now
            )
            try record.save(db)
        }
        Log.db.debug("upsertMetadata n=\(byId.count, privacy: .public)")
        _ = try recomputeEffective(db, messageIds: Set(byId.keys))
        return Set(parsed.map(\.threadId))
    }

    static func applyServerLabels(_ db: Database, messageId: String, labels: Set<String>) throws {
        try setServer(db, messageId: messageId) { _ in labels }
    }

    static func applyServerDelta(_ db: Database, messageId: String, delta: LabelDelta) throws {
        try setServer(db, messageId: messageId) { delta.applied(to: $0) }
    }

    private static func setServer(_ db: Database, messageId: String, transform: (Set<String>) -> Set<String>) throws {
        guard
            let current = try String.fetchOne(
                db, sql: "SELECT serverLabelIds FROM message WHERE id = ?", arguments: [messageId])
        else { return }
        let newSet = transform(LabelAlgebra.parseJSON(current))
        let newJSON = LabelAlgebra.sortedJSON(newSet)
        if newJSON != current {
            try db.execute(
                sql: "UPDATE message SET serverLabelIds = ? WHERE id = ?", arguments: [newJSON, messageId])
        }
    }

    /// E = effective(S, active modify deltas affecting the id); flags from E. Returns thread ids of found rows.
    static func recomputeEffective(_ db: Database, messageIds: Set<String>) throws -> Set<String> {
        guard !messageIds.isEmpty else { return [] }
        let ops = try OutboxRepository.activeModifies(db)
        var threadIds = Set<String>()
        for chunk in Array(messageIds).chunked(chunkSize) {
            let placeholders = databaseQuestionMarks(count: chunk.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, threadId, serverLabelIds, labelIds, isUnread, inInbox, isHidden
                    FROM message WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(chunk))
            for row in rows {
                let id: String = row["id"]
                threadIds.insert(row["threadId"])
                let serverSet = LabelAlgebra.parseJSON(row["serverLabelIds"])
                let pending = ops.filter { $0.affectedSet.contains(id) }.map(\.delta)
                let effective = LabelAlgebra.effective(server: serverSet, pending: pending)
                let flags = LabelAlgebra.flags(effective)
                let effJSON = LabelAlgebra.sortedJSON(effective)
                let changed =
                    effJSON != (row["labelIds"] as String) || flags.isUnread != (row["isUnread"] as Bool)
                    || flags.inInbox != (row["inInbox"] as Bool) || flags.isHidden != (row["isHidden"] as Bool)
                if changed {
                    try db.execute(
                        sql: "UPDATE message SET labelIds = ?, isUnread = ?, inInbox = ?, isHidden = ? WHERE id = ?",
                        arguments: [effJSON, flags.isUnread, flags.inInbox, flags.isHidden, id])
                }
            }
        }
        return threadIds
    }

    static func delete(_ db: Database, ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let threads = try threadIds(db, of: ids)
        for chunk in Array(ids).chunked(chunkSize) {
            let placeholders = databaseQuestionMarks(count: chunk.count)
            try db.execute(
                sql: "DELETE FROM message WHERE id IN (\(placeholders))", arguments: StatementArguments(chunk))
        }
        return threads
    }

    static func idsExisting(_ db: Database, among ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        for chunk in ids.chunked(chunkSize) {
            let placeholders = databaseQuestionMarks(count: chunk.count)
            found.formUnion(
                try String.fetchAll(
                    db, sql: "SELECT id FROM message WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)))
        }
        return found
    }

    static func staleIds(_ db: Database, olderThanGeneration g: Int) throws -> Set<String> {
        let stale = Set(
            try String.fetchAll(db, sql: "SELECT id FROM message WHERE syncGeneration < ?", arguments: [g]))
        return stale.subtracting(try OutboxRepository.referencedMessageIds(db))
    }

    static func threadIds(_ db: Database, of ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var threads = Set<String>()
        for chunk in Array(ids).chunked(chunkSize) {
            let placeholders = databaseQuestionMarks(count: chunk.count)
            threads.formUnion(
                try String.fetchAll(
                    db, sql: "SELECT DISTINCT threadId FROM message WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)))
        }
        return threads
    }

    static func fetch(_ db: Database, id: String) throws -> MessageRecord? {
        try MessageRecord.fetchOne(db, key: id)
    }
}

extension Array {
    /// Splits into subarrays of at most `size` elements.
    nonisolated func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
