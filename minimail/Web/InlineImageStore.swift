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

/// Inline-image bytes for the cid scheme handler. Memory cache → disk cache → `attachments.get`
/// (stored id, one re-resolve on 404), at most `maxInFlight` network fetches at a time, failures cached
/// for `failureTTL` (architecture §9.4). `db` is `any DatabaseWriter` so tests can pass a `DatabaseQueue`.
actor InlineImageStore {
    static let maxInFlight = 2
    static let failureTTL: TimeInterval = 60
    static let memoryBudgetBytes = 8_000_000

    private let gmail: GmailClient
    private let db: any DatabaseWriter
    private let root: URL
    private let clock: @Sendable () -> Date
    private let limiter = RequestLimiter(max: InlineImageStore.maxInFlight)

    private var memory: [String: (data: Data, mime: String)] = [:]
    private var order: [String] = []
    private var memoryBytes = 0
    private var failedAt: [String: Date] = [:]
    private var inFlight: [String: Task<(Data, String), any Error>] = [:]

    init(
        gmail: GmailClient, db: any DatabaseWriter, cacheDirectory: URL,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.gmail = gmail
        self.db = db
        self.root = cacheDirectory
        self.clock = clock
    }

    /// `(bytes, mimeType)`; the mime type comes from the attachment row
    /// (`"application/octet-stream"` when empty).
    func bytes(messageId: String, contentId: String) async throws -> (Data, String) {
        let key = messageId + "/" + contentId

        if let hit = memory[key] {
            touch(key)
            return (hit.data, hit.mime)
        }

        if let failed = failedAt[key] {
            if clock().timeIntervalSince(failed) < Self.failureTTL { throw InlineImageError.recentlyFailed }
            failedAt[key] = nil
        }

        if let running = inFlight[key] { return try await running.value }

        let task = Task { [weak self] () throws -> (Data, String) in
            guard let self else { throw CancellationError() }
            return try await self.fetchUncached(messageId: messageId, contentId: contentId, key: key)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            return try await task.value
        } catch is CancellationError {
            throw CancellationError()  // a cancelled fetch is never cached as a failure
        } catch {
            failedAt[key] = clock()
            throw error
        }
    }

    /// Deletes the cache directory, clears the memory and failure caches. Called on sign-out.
    func purge() async {
        memory = [:]
        order = []
        memoryBytes = 0
        failedAt = [:]
        try? FileManager.default.removeItem(at: root)
    }

    /// `cacheDirectory/<messageId>/<sha1hex(contentId)>.bin`.
    nonisolated static func cacheFileURL(root: URL, messageId: String, contentId: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(contentId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(messageId, isDirectory: true)
            .appendingPathComponent("\(hex).bin", isDirectory: false)
    }

    /// Number of entries currently in the failure cache (not yet expired).
    var failureCount: Int {
        let now = clock()
        return failedAt.values.filter { now.timeIntervalSince($0) < Self.failureTTL }.count
    }

    // MARK: - Fetch

    private func fetchUncached(messageId: String, contentId: String, key: String) async throws -> (Data, String) {
        let file = Self.cacheFileURL(root: root, messageId: messageId, contentId: contentId)
        let mimeFile = file.deletingPathExtension().appendingPathExtension("mime")
        if let data = try? Data(contentsOf: file), let mime = try? String(contentsOf: mimeFile, encoding: .utf8) {
            remember(key, data, mime)
            return (data, mime)
        }

        let rows = try await db.read { db in
            try AttachmentRecord.filter(Column("messageId") == messageId).fetchAll(db)
        }
        let match =
            rows.first { $0.contentId == contentId }
            ?? rows.first { $0.contentId?.lowercased() == contentId.lowercased() }
        guard let record = match else { throw InlineImageError.unknownContentId }

        let gmail = self.gmail
        let db = self.db
        let data = try await limiter.withPermit {
            try await Self.download(gmail: gmail, db: db, record: record, messageId: messageId)
        }

        write(data: data, to: file, mimeFile: mimeFile, mime: record.mimeType)
        let mime = record.mimeType.isEmpty ? "application/octet-stream" : record.mimeType
        remember(key, data, mime)
        return (data, mime)
    }

    /// Stored id first; exactly one re-resolve through `messages.get` when it answers 404
    /// (`[gmail-api §6, gotcha 14]`). A 404 after the re-resolve propagates as `GmailError.notFound`.
    private static func download(
        gmail: GmailClient, db: any DatabaseWriter, record: AttachmentRecord, messageId: String
    ) async throws -> Data {
        if let attachmentId = record.attachmentId {
            do {
                return try await gmail.getAttachment(messageId: messageId, attachmentId: attachmentId)
            } catch GmailError.notFound {
                // fall through to the one re-resolve
            }
        }

        let message = try await gmail.getMessage(id: messageId, format: .full, fields: "id,payload")
        let parsed = MessageParser.parse(message)
        try await db.write { db in
            try BodyRepository.updateAttachmentIds(db, messageId: messageId, parsed: parsed.attachments)
        }
        guard let part = parsed.attachments.first(where: { $0.partId == record.partId }) else {
            throw InlineImageError.noBytes
        }
        if let inline = part.inlineData { return inline }
        guard let resolved = part.attachmentId else { throw InlineImageError.noBytes }
        return try await gmail.getAttachment(messageId: messageId, attachmentId: resolved)
    }

    private func write(data: Data, to file: URL, mimeFile: URL, mime: String) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try Data((mime.isEmpty ? "application/octet-stream" : mime).utf8)
                .write(to: mimeFile, options: .atomic)
        } catch {
            Log.web.error("web.cid.write failed \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Memory cache

    private func remember(_ key: String, _ data: Data, _ mime: String) {
        if let existing = memory[key] {
            memoryBytes -= existing.data.count
            order.removeAll { $0 == key }
        }
        memory[key] = (data, mime)
        memoryBytes += data.count
        order.append(key)
        while memoryBytes > Self.memoryBudgetBytes, order.count > 1 {
            let oldest = order.removeFirst()
            memoryBytes -= memory[oldest]?.data.count ?? 0
            memory[oldest] = nil
        }
    }

    private func touch(_ key: String) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}
