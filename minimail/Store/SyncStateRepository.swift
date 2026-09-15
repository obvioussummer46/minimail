import Foundation
import GRDB
import MailCore

nonisolated enum SyncStateRepository {
    static func get(_ db: Database, _ key: SyncKey) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key.rawValue])
    }

    /// `value == nil` deletes the row; else `INSERT OR REPLACE`.
    static func set(_ db: Database, _ key: SyncKey, _ value: String?) throws {
        if let value {
            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, ?)", arguments: [key.rawValue, value])
        } else {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [key.rawValue])
        }
    }

    static func int64(_ db: Database, _ key: SyncKey) throws -> Int64? {
        try get(db, key).flatMap(Int64.init)
    }

    static func setInt64(_ db: Database, _ key: SyncKey, _ value: Int64?) throws {
        try set(db, key, value.map(String.init))
    }

    static func historyId(_ db: Database) throws -> UInt64? {
        try get(db, .historyId).flatMap(UInt64.init)
    }

    /// Invariant 5: no-op when `value < current` unless `allowDecrease` (full resync).
    static func setHistoryId(_ db: Database, _ value: UInt64, allowDecrease: Bool = false) throws {
        if let current = try historyId(db), value < current, !allowDecrease {
            Log.sync.notice("historyId decrease ignored")
            return
        }
        try set(db, .historyId, String(value))
    }

    static func selfAddresses(_ db: Database) throws -> Set<String> {
        guard let json = try get(db, .selfAddresses) else { return [] }
        return LabelAlgebra.parseJSON(json)
    }

    static func setSelfAddresses(_ db: Database, _ addresses: Set<String>) throws {
        let normalized = Set(addresses.map { $0.lowercased() })
        try set(db, .selfAddresses, LabelAlgebra.sortedJSON(normalized))
    }

    static func all(_ db: Database) throws -> [SyncKey: String] {
        var result: [SyncKey: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM syncState") {
            if let key = SyncKey(rawValue: row["key"]) { result[key] = row["value"] }
        }
        return result
    }
}
