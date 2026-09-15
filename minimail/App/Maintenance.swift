import Foundation
import GRDB
import os

/// Once-per-24h cleanup (architecture §4.9). Contains no SQL: the three statements are the existing module-06
/// repository functions (`ThreadRepository.deleteExpired`, `BodyRepository.pruneBodies`,
/// `OutboxRepository.deleteFailedSends`), so `Store/MaintenanceRepository.swift` (D2) is unnecessary — 06 already
/// exposes cleanup functions.
nonisolated enum Maintenance {
    static let interval: TimeInterval = 86_400
    static let threadMaxAge: TimeInterval = 30 * 86_400
    static let bodiesKept = 2_000
    static let fileMaxAge: TimeInterval = 7 * 86_400
    static let failedSendMaxAge: TimeInterval = 30 * 86_400

    static func cleanup(_ db: any DatabaseWriter, now: Date) async {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        do {
            let (historyId, lastDelta, lastCleanup, views) = try await db.read {
                db -> (String?, String?, String?, [String]) in
                (
                    try SyncStateRepository.get(db, .historyId),
                    try SyncStateRepository.get(db, .lastDeltaSyncAt),
                    try SyncStateRepository.get(db, .lastCleanupAt),
                    try LabelRepository.cachedViewLabelIds(db)
                )
            }
            guard historyId != nil, lastDelta != nil else { return }
            if let c = Int64(lastCleanup ?? ""), nowMs - c < Int64(interval * 1000) { return }

            try await db.write { db in
                let protectedThreads = try OutboxRepository.activeThreadIds(db)
                let deletedThreads = try ThreadRepository.deleteExpired(
                    db, olderThan: nowMs - Int64(threadMaxAge * 1000), protectedLabelIds: Set(views),
                    protectedThreadIds: protectedThreads)
                let evicted = try BodyRepository.pruneBodies(db, keepNewest: bodiesKept)
                let deletedSends = try OutboxRepository.deleteFailedSends(
                    db, olderThan: nowMs - Int64(failedSendMaxAge * 1000))
                try SyncStateRepository.set(db, .lastCleanupAt, String(nowMs))
                Log.db.notice(
                    "cleanup threads=\(deletedThreads, privacy: .public) bodies=\(evicted, privacy: .public) sends=\(deletedSends, privacy: .public)"
                )
            }

            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            _ = try await Task.detached { try purgeFiles(now: now, cacheRoot: root) }.value
        } catch {
            Log.db.error("cleanup failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Removes files older than `fileMaxAge` under `<cacheRoot>/attachments` and `<cacheRoot>/cid`, then removes
    /// directories left empty (deepest first). Returns the number of files removed.
    static func purgeFiles(now: Date, cacheRoot: URL) throws -> Int {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-fileMaxAge)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var removed = 0
        for sub in ["attachments", "cid"] {
            let dir = cacheRoot.appendingPathComponent(sub, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { continue }
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: Array(keys)) {
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: keys)
                    if values?.isRegularFile == true, let modified = values?.contentModificationDate,
                        modified < cutoff
                    {
                        try? fm.removeItem(at: url)
                        removed += 1
                    }
                }
            }
            removeEmptyDirectories(dir, fm: fm)
        }
        return removed
    }

    private static func removeEmptyDirectories(_ root: URL, fm: FileManager) {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var dirs: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(url) }
        }
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
