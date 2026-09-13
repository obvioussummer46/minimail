import Foundation
import GRDB
import MailCore

nonisolated enum OutboxRepository {
    static let maxModifyAttempts = 8
    static let maxSendAttempts = 5

    // MARK: Enqueue

    /// Coalesces into the thread's pending op (never inFlight); empty merge deletes it. Returns the op id or nil.
    static func enqueueModify(
        _ db: Database, threadId: String, delta: LabelDelta, affectedMessageIds: [String], now: Int64
    ) throws -> Int64? {
        guard !delta.isEmpty else { return nil }
        let result: Int64?
        var affected: Set<String>
        if let pendingOp = try OutboxRecord.fetchOne(
            db, sql: "SELECT * FROM outbox WHERE kind = 'modify' AND state = 'pending' AND threadId = ? LIMIT 1",
            arguments: [threadId])
        {
            let merged = OutboxCoalescer.merge(existing: pendingOp.delta, new: delta)
            affected = pendingOp.affectedSet.union(affectedMessageIds)
            if merged.isEmpty {
                try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [pendingOp.id])
                result = nil
            } else {
                try db.execute(
                    sql: "UPDATE outbox SET addLabelIds = ?, removeLabelIds = ?, affectedMessageIds = ? WHERE id = ?",
                    arguments: [
                        LabelAlgebra.sortedJSON(merged.add), LabelAlgebra.sortedJSON(merged.remove),
                        LabelAlgebra.sortedJSON(affected), pendingOp.id,
                    ])
                result = pendingOp.id
            }
        } else {
            affected = Set(affectedMessageIds)
            try db.execute(
                sql: """
                    INSERT INTO outbox (kind, state, attempts, nextAttemptAt, createdAt, threadId, addLabelIds,
                    removeLabelIds, affectedMessageIds) VALUES ('modify', 'pending', 0, 0, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    now, threadId, LabelAlgebra.sortedJSON(delta.add), LabelAlgebra.sortedJSON(delta.remove),
                    LabelAlgebra.sortedJSON(affected),
                ])
            result = db.lastInsertedRowID
        }
        let threads = try MessageRepository.recomputeEffective(db, messageIds: affected)
        try ThreadRepository.recomputeAggregates(
            db, threadIds: threads.union([threadId]), selfAddresses: SyncStateRepository.selfAddresses(db))
        return result
    }

    static func enqueueSend(_ db: Database, job: SendJob, now: Int64) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO outbox (kind, state, attempts, nextAttemptAt, createdAt, threadId, sendJob,
                rfc822MessageId, transmitState) VALUES ('send', 'pending', 0, 0, ?, ?, ?, ?, 'notSent')
                """,
            arguments: [now, job.threadId, RecordJSON.string(job), job.messageID])
        return db.lastInsertedRowID
    }

    // MARK: Claim

    static func claimModifies(_ db: Database, limit: Int, now: Int64) throws -> [OutboxRecord] {
        let ids = try Int64.fetchAll(
            db,
            sql:
                "SELECT id FROM outbox WHERE kind = 'modify' AND state = 'pending' AND nextAttemptAt <= ? ORDER BY id LIMIT ?",
            arguments: [now, limit])
        return try claim(db, ids: ids)
    }

    static func claimSend(_ db: Database, now: Int64) throws -> OutboxRecord? {
        let ids = try Int64.fetchAll(
            db,
            sql:
                "SELECT id FROM outbox WHERE kind = 'send' AND state = 'pending' AND nextAttemptAt <= ? ORDER BY id LIMIT 1",
            arguments: [now])
        return try claim(db, ids: ids).first
    }

    private static func claim(_ db: Database, ids: [Int64]) throws -> [OutboxRecord] {
        guard !ids.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: ids.count)
        try db.execute(
            sql: "UPDATE outbox SET state = 'inFlight', attempts = attempts + 1 WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids))
        var records: [OutboxRecord] = []
        for id in ids { if let r = try OutboxRecord.fetchOne(db, key: id) { records.append(r) } }
        return records
    }

    // MARK: Ack / discard

    static func ackModify(_ db: Database, opId: Int64, serverLabelsByMessage: [String: Set<String>]?) throws
        -> Set<String>
    {
        guard let op = try record(db, id: opId), op.kind == .modify else { return [] }
        var touched = op.affectedSet
        for id in op.affectedSet {
            if let s = serverLabelsByMessage?[id] {
                try MessageRepository.applyServerLabels(db, messageId: id, labels: s)
            } else {
                try MessageRepository.applyServerDelta(db, messageId: id, delta: op.delta)
            }
        }
        for (id, s) in serverLabelsByMessage ?? [:] where !touched.contains(id) {
            try MessageRepository.applyServerLabels(db, messageId: id, labels: s)
            touched.insert(id)
        }
        try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [opId])
        let threads = try MessageRepository.recomputeEffective(db, messageIds: touched)
        let all = threads.union(op.threadId.map { [$0] } ?? [])
        try ThreadRepository.recomputeAggregates(
            db, threadIds: all, selfAddresses: SyncStateRepository.selfAddresses(db))
        return all
    }

    static func discardModify(_ db: Database, opId: Int64) throws -> Set<String> {
        guard let op = try record(db, id: opId) else { return [] }
        try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [opId])
        let threads = try MessageRepository.recomputeEffective(db, messageIds: op.affectedSet)
        let all = threads.union(op.threadId.map { [$0] } ?? [])
        try ThreadRepository.recomputeAggregates(
            db, threadIds: all, selfAddresses: SyncStateRepository.selfAddresses(db))
        return all
    }

    // MARK: Retry / fail

    static func retryLater(_ db: Database, opId: Int64, error: String, countsAsAttempt: Bool, nextAttemptAt: Int64)
        throws
    {
        guard let op = try record(db, id: opId) else { return }
        let attempts = countsAsAttempt ? op.attempts : max(0, op.attempts - 1)
        let limit = op.kind == .modify ? maxModifyAttempts : maxSendAttempts
        let state = attempts >= limit ? "failed" : "pending"
        try db.execute(
            sql: "UPDATE outbox SET state = ?, attempts = ?, nextAttemptAt = ?, lastError = ? WHERE id = ?",
            arguments: [state, attempts, nextAttemptAt, error, opId])
        Log.outbox.notice(
            "op \(opId, privacy: .public) retry attempts=\(attempts, privacy: .public) state=\(state, privacy: .public)"
        )
    }

    static func fail(_ db: Database, opId: Int64, error: String) throws {
        try db.execute(sql: "UPDATE outbox SET state = 'failed', lastError = ? WHERE id = ?", arguments: [error, opId])
    }

    static func setTransmitState(_ db: Database, opId: Int64, _ s: TransmitState) throws {
        try db.execute(
            sql: "UPDATE outbox SET transmitState = ? WHERE id = ? AND kind = 'send'", arguments: [s.rawValue, opId])
    }

    static func deleteSend(_ db: Database, opId: Int64) throws {
        try db.execute(sql: "DELETE FROM outbox WHERE id = ? AND kind = 'send'", arguments: [opId])
    }

    static func retrySend(_ db: Database, opId: Int64) throws {
        try db.execute(
            sql:
                "UPDATE outbox SET state = 'pending', attempts = 0, nextAttemptAt = 0, lastError = NULL WHERE id = ? AND kind = 'send' AND state = 'failed'",
            arguments: [opId])
    }

    static func releaseInFlight(_ db: Database) throws {
        try db.execute(sql: "UPDATE outbox SET state = 'pending' WHERE state = 'inFlight'")
    }

    /// Failed modify ops → pending; absorbs a same-thread pending op so invariant 4 holds.
    static func rearmFailedModifies(_ db: Database) throws {
        let failed = try OutboxRecord.fetchAll(
            db, sql: "SELECT * FROM outbox WHERE kind = 'modify' AND state = 'failed' ORDER BY id")
        for f in failed {
            guard let threadId = f.threadId else { continue }
            if let pendingOp = try OutboxRecord.fetchOne(
                db, sql: "SELECT * FROM outbox WHERE kind = 'modify' AND state = 'pending' AND threadId = ? LIMIT 1",
                arguments: [threadId])
            {
                let merged = OutboxCoalescer.merge(existing: f.delta, new: pendingOp.delta)
                if merged.isEmpty {
                    try db.execute(sql: "DELETE FROM outbox WHERE id IN (?, ?)", arguments: [f.id, pendingOp.id])
                    continue
                }
                let affected = f.affectedSet.union(pendingOp.affectedSet)
                try db.execute(
                    sql: "UPDATE outbox SET addLabelIds = ?, removeLabelIds = ?, affectedMessageIds = ? WHERE id = ?",
                    arguments: [
                        LabelAlgebra.sortedJSON(merged.add), LabelAlgebra.sortedJSON(merged.remove),
                        LabelAlgebra.sortedJSON(affected), f.id,
                    ])
                try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [pendingOp.id])
            }
            try db.execute(
                sql:
                    "UPDATE outbox SET state = 'pending', attempts = 0, nextAttemptAt = 0, lastError = NULL WHERE id = ?",
                arguments: [f.id])
        }
    }

    // MARK: Reads

    static func pendingModifies(_ db: Database) throws -> [OutboxRecord] {
        try OutboxRecord.fetchAll(
            db, sql: "SELECT * FROM outbox WHERE kind = 'modify' AND state = 'pending' ORDER BY id")
    }

    static func record(_ db: Database, id: Int64) throws -> OutboxRecord? {
        try OutboxRecord.fetchOne(db, key: id)
    }

    static func activeModifies(_ db: Database) throws -> [OutboxRecord] {
        try OutboxRecord.fetchAll(
            db, sql: "SELECT * FROM outbox WHERE kind = 'modify' AND state IN ('pending','inFlight') ORDER BY id")
    }

    /// Modify ops that contribute to effective labels: pending, inFlight, AND failed. A failed op's optimistic
    /// change persists (the archive stays visually applied) until it is acked, discarded, or rearmed — which is
    /// what makes `rearmFailedModifies` a no-op on E (spec §4.11 step 3). id ASC.
    static func modifiesAffectingEffective(_ db: Database) throws -> [OutboxRecord] {
        try OutboxRecord.fetchAll(
            db,
            sql: "SELECT * FROM outbox WHERE kind = 'modify' AND state IN ('pending','inFlight','failed') ORDER BY id")
    }

    static func activeThreadIds(_ db: Database) throws -> Set<String> {
        Set(
            try String.fetchAll(
                db,
                sql:
                    "SELECT DISTINCT threadId FROM outbox WHERE threadId IS NOT NULL AND state IN ('pending','inFlight')"
            ))
    }

    static func referencedMessageIds(_ db: Database) throws -> Set<String> {
        var ids = Set<String>()
        for json in try String.fetchAll(
            db,
            sql:
                "SELECT affectedMessageIds FROM outbox WHERE kind = 'modify' AND state IN ('pending','inFlight') AND affectedMessageIds IS NOT NULL"
        ) {
            ids.formUnion(LabelAlgebra.parseJSON(json))
        }
        for json in try String.fetchAll(
            db,
            sql:
                "SELECT sendJob FROM outbox WHERE kind = 'send' AND state IN ('pending','inFlight') AND sendJob IS NOT NULL"
        ) {
            if let job = RecordJSON.value(SendJob.self, from: json) { ids.insert(job.originalMessageId) }
        }
        return ids
    }

    static func deleteFailedSends(_ db: Database, olderThan: Int64) throws -> Int {
        try db.execute(
            sql: "DELETE FROM outbox WHERE kind = 'send' AND state = 'failed' AND createdAt < ?", arguments: [olderThan]
        )
        return db.changesCount
    }
}
