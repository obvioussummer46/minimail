import Foundation
import GRDB

/// Connection lifecycle. DEVIATION D1: named `AppDatabase` (architecture: `enum Database`) because `Database`
/// would shadow `GRDB.Database` in every repository signature `(_ db: Database)`.
nonisolated enum AppDatabase {
    static let directoryName = "minimail-db"
    static let fileName = "db.sqlite"

    /// `Application Support/minimail-db`.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "minimail"
        #if DEBUG
            config.publicStatementArguments = true
        #endif
        return config
    }

    /// Creates `directory`, protects it, opens a WAL `DatabasePool`, migrates, protects the files.
    static func open(directory: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        protect(path: directory.path)

        let pool = try DatabasePool(
            path: directory.appendingPathComponent(fileName).path, configuration: configuration())
        try makeMigrator().migrate(pool)

        for suffix in ["", "-wal", "-shm"] {
            let file = directory.appendingPathComponent(fileName + suffix).path
            if FileManager.default.fileExists(atPath: file) { protect(path: file) }
        }
        return pool
    }

    /// `open` on a fresh temporary directory; used by `AppEnvironment(testing: true)` and tests that need a pool.
    static func openTemporary() throws -> DatabasePool {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("minimail-db-\(UUID().uuidString)", isDirectory: true)
        return try open(directory: directory)
    }

    /// In-memory queue + migrator. Tests only.
    static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: configuration())
        try makeMigrator().migrate(queue)
        return queue
    }

    /// Removes the database directory. Missing directory → no error. Precondition: no open pool on it.
    static func destroy(directory: URL) throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
        }
    }

    /// In-place account wipe keeping the pool object valid: drop + recreate the schema, then VACUUM.
    static func reset(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: Schema.dropAllSQL)
            try db.execute(sql: Schema.v1SQL)
        }
        try pool.vacuum()
        Log.db.notice("database reset")
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = true
        #endif
        Schema.register(in: &migrator)
        return migrator
    }

    private static func protect(path: String) {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        } catch {
            Log.db.error("file protection failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
