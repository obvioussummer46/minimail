import CryptoKit
import Foundation
import GRDB
import MailCore

enum InlineImageError: Error, Equatable, Sendable {
    /// No attachment row with that contentId for the message (after one re-resolve).
    case unknownContentId
    /// Same key failed < 60 s ago; no network was touched.
    case recentlyFailed
    /// `attachments.get` answered but the part has neither attachmentId nor inline data.
    case noBytes
}

/// Inline-image bytes for the cid scheme handler. Memory cache → disk cache → `attachments.get`.
/// T08.5 shell: the caches and the fetch path land in T08.6.
actor InlineImageStore {
    static let maxInFlight = 2
    static let failureTTL: TimeInterval = 60
    static let memoryBudgetBytes = 8_000_000

    private let gmail: GmailClient
    private let db: any DatabaseWriter
    private let root: URL
    private let clock: @Sendable () -> Date

    init(gmail: GmailClient, db: any DatabaseWriter, cacheDirectory: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        self.gmail = gmail
        self.db = db
        self.root = cacheDirectory
        self.clock = clock
    }

    func bytes(messageId: String, contentId: String) async throws -> (Data, String) {
        throw InlineImageError.unknownContentId
    }

    func purge() async {}

    /// `cacheDirectory/<messageId>/<sha1hex(contentId)>.bin`.
    nonisolated static func cacheFileURL(root: URL, messageId: String, contentId: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(contentId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(messageId, isDirectory: true)
            .appendingPathComponent("\(hex).bin", isDirectory: false)
    }

    var failureCount: Int { 0 }
}
