import GRDB
import XCTest

@testable import minimail

nonisolated final class DatabaseTests: XCTestCase {

    private func normalize(_ sql: String) -> String {
        var s = sql
        // strip -- comments
        s = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let range = line.range(of: "--") { return String(line[..<range.lowerBound]) }
            return String(line)
        }.joined(separator: " ")
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    func testFreshSchemaMatchesDDL() throws {
        let queue = try AppDatabase.openInMemory()
        try queue.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            for name in Schema.tableNames { XCTAssertTrue(tables.contains(name), "missing table \(name)") }
            let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            for name in Schema.indexNames { XCTAssertTrue(indexes.contains(name), "missing index \(name)") }

            // Compare each CREATE TABLE statement to the DDL, whitespace-normalized.
            var expected: [String: String] = [:]
            for statement in Schema.v1SQL.components(separatedBy: ";") where statement.contains("CREATE TABLE") {
                let words = statement.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "(" })
                if let idx = words.firstIndex(of: "TABLE"), idx + 1 < words.count {
                    expected[String(words[idx + 1])] = normalize(statement)
                }
            }
            for name in Schema.tableNames {
                let stored = try String.fetchOne(
                    db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [name])
                XCTAssertEqual(normalize(stored ?? ""), expected[name], "DDL mismatch for \(name)")
            }
        }
    }

    func testForeignKeysOnAndCascade() throws {
        let queue = try AppDatabase.openInMemory()
        try queue.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            try MessageRecord.fetchAll(db)  // no-op to ensure table exists
            try insertMessage(db, id: "m1")
            try MessageBodyRecord(
                messageId: "m1", bodyHtml: "<p>x</p>", bodyText: nil, hasRemoteImages: false, darkStrategy: "plain",
                sanitizerVersion: 1, fetchedAt: 1
            ).insert(db)
            try AttachmentRecord(
                messageId: "m1", partId: "2", filename: "a.pdf", mimeType: "application/pdf", size: 1, contentId: nil,
                isInline: false, attachmentId: nil
            ).insert(db)
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["m1"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_body"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment"), 0)
        }
    }

    func testPoolIsWAL() throws {
        let pool = try AppDatabase.openTemporary()
        let dir = URL(fileURLWithPath: pool.path).deletingLastPathComponent()
        defer { try? AppDatabase.destroy(directory: dir) }
        let mode = try pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode, "wal")
        XCTAssertTrue(pool.path.hasSuffix("db.sqlite"))
        try pool.close()
    }

    func testOpenIsIdempotent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-\(UUID().uuidString)")
        defer { try? AppDatabase.destroy(directory: dir) }
        let first = try AppDatabase.open(directory: dir)
        try first.write { try SyncStateRepository.set($0, .accountEmail, "x@example.com") }
        try first.close()
        let second = try AppDatabase.open(directory: dir)
        let email = try second.read { try SyncStateRepository.get($0, .accountEmail) }
        XCTAssertEqual(email, "x@example.com")
        try second.close()
    }

    func testDestroyRemovesDirectory() throws {
        let pool = try AppDatabase.openTemporary()
        let dir = URL(fileURLWithPath: pool.path).deletingLastPathComponent()
        try pool.close()
        try AppDatabase.destroy(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNoThrow(try AppDatabase.destroy(directory: dir))
    }

    func testResetLeavesEmptyMigratedSchema() throws {
        let pool = try AppDatabase.openTemporary()
        let dir = URL(fileURLWithPath: pool.path).deletingLastPathComponent()
        defer { try? AppDatabase.destroy(directory: dir) }
        try TestDatabase.seedMany(pool, count: 40)
        try pool.write { try $0.execute(sql: "INSERT INTO outbox (kind, createdAt) VALUES ('modify', 1)") }

        try AppDatabase.reset(pool)

        try pool.read { db in
            for table in Schema.tableNames {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0, table)
            }
        }
        try pool.write { db in
            try db.execute(sql: "INSERT INTO outbox (kind, createdAt) VALUES ('modify', 1)")
            XCTAssertEqual(db.lastInsertedRowID, 1)
        }
    }

    func testInvariantsHoldOnEmptyDB() throws {
        let queue = try TestDatabase.make()
        try InvariantChecks.assertAll(queue)
    }

    func testOpenRecoversFromGarbageFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? AppDatabase.destroy(directory: dir) }
        let file = dir.appendingPathComponent("db.sqlite")
        try Data((0..<100).map { _ in UInt8.random(in: 0...255) }).write(to: file)
        XCTAssertThrowsError(try AppDatabase.open(directory: dir))
        try AppDatabase.destroy(directory: dir)
        let pool = try AppDatabase.open(directory: dir)
        try pool.close()
    }

    // MARK: helpers

    private func insertMessage(_ db: Database, id: String) throws {
        try MessageRecord(
            id: id, threadId: id, historyId: 0, internalDate: 1, fromName: nil, fromAddr: "a@x", isFromMe: false,
            toList: [], ccList: [], replyToList: [], subject: "s", snippet: "", messageIdHeader: nil, inReplyTo: nil,
            referencesList: [], topMimeType: nil, serverLabelIds: [], labelIds: [], isUnread: false, inInbox: false,
            isHidden: false, hasAttachments: false, bodyState: 0, syncGeneration: 1, fetchedAt: 1
        ).insert(db)
    }
}
