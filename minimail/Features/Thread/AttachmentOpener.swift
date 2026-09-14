import Foundation
import GRDB
import MailCore
import Observation
import os

/// Downloads one attachment on tap and hands its file URL to `.quickLookPreview` (architecture §8.4).
/// Never prefetches (architecture decision 8). `db` is `any DatabaseWriter` so tests can pass a `DatabaseQueue`.
@Observable final class AttachmentOpener {
    enum State: Equatable {
        case idle
        case downloading(messageId: String, partId: String)
        /// User-facing text (spec §5.2).
        case failed(String)
    }

    /// Refuse to open above this size (JSON `attachments.get` inflates bytes by 4/3).
    static let maxBytes = 25_000_000

    /// MIME type → file extension, used when the stored filename has none: QuickLook detects type by extension.
    nonisolated static let mimeExtensions: [String: String] = [
        "application/pdf": "pdf",
        "application/rtf": "rtf",
        "application/json": "json",
        "application/zip": "zip",
        "application/msword": "doc",
        "application/vnd.ms-excel": "xls",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.apple.pages": "pages",
        "application/vnd.apple.numbers": "numbers",
        "application/vnd.apple.keynote": "key",
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/gif": "gif",
        "image/heic": "heic",
        "image/tiff": "tiff",
        "image/svg+xml": "svg",
        "text/plain": "txt",
        "text/html": "html",
        "text/csv": "csv",
        "text/calendar": "ics",
        "message/rfc822": "eml",
        "audio/mpeg": "mp3",
        "video/mp4": "mp4",
    ]

    private static let unavailableText = "This attachment is no longer available."
    private static let writeFailedText = "Couldn't save this attachment."

    private(set) var state: State = .idle
    /// Bound to `.quickLookPreview($previewURL)`; QuickLook sets it back to nil on dismissal.
    var previewURL: URL?

    @ObservationIgnored private let gmail: GmailClient
    @ObservationIgnored private let db: any DatabaseWriter
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager: FileManager

    init(gmail: GmailClient, db: any DatabaseWriter, directory: URL, fileManager: FileManager = .default) {
        self.gmail = gmail
        self.db = db
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Never throws; failures land in `state = .failed(text)`. A second call while `.downloading` is ignored.
    func open(messageId: String, partId: String) async {
        if case .downloading = state { return }
        state = .idle

        let record = try? await db.read { db in
            try BodyRepository.attachment(db, messageId: messageId, partId: partId)
        }
        guard let record else {
            state = .failed(Self.unavailableText)
            return
        }

        let name = Self.sanitizedFilename(record.filename, partId: partId, mimeType: record.mimeType)
        let url = Self.fileURL(root: directory, messageId: messageId, partId: partId, filename: name)

        if fileManager.fileExists(atPath: url.path) {
            previewURL = url
            Log.ui.debug("attachment.cache.hit \(messageId, privacy: .public) \(partId, privacy: .public)")
            return
        }

        guard record.size <= Self.maxBytes else {
            state = .failed("This attachment is too large to open (\(Formatters.bytes(record.size))).")
            return
        }

        state = .downloading(messageId: messageId, partId: partId)
        defer {
            if case .downloading = state { state = .idle }
        }

        var data: Data?
        if let attachmentId = record.attachmentId {
            do {
                data = try await gmail.getAttachment(messageId: messageId, attachmentId: attachmentId)
            } catch GmailError.notFound {
                data = nil  // stale id: re-resolve below
            } catch {
                state = .failed(Self.message(for: error))
                return
            }
        }

        if data == nil {
            // Re-resolve exactly once; this also refreshes the ids of every other part for later taps.
            let message: GmailMessage
            do {
                message = try await gmail.getMessage(id: messageId, format: .full, fields: "payload")
            } catch {
                state = .failed(Self.message(for: error))
                return
            }
            let parsed = MessageParser.parse(message)
            try? await db.write { db in
                try BodyRepository.updateAttachmentIds(db, messageId: messageId, parsed: parsed.attachments)
            }
            guard let part = parsed.attachments.first(where: { $0.partId == partId }) else {
                state = .failed(Self.unavailableText)
                return
            }
            if let inline = part.inlineData {
                data = inline  // small parts arrive inline, no second request
            } else if let resolved = part.attachmentId {
                do {
                    data = try await gmail.getAttachment(messageId: messageId, attachmentId: resolved)
                } catch GmailError.notFound {
                    state = .failed(Self.unavailableText)  // second 404: give up
                    return
                } catch {
                    state = .failed(Self.message(for: error))
                    return
                }
            } else {
                state = .failed(Self.unavailableText)
                return
            }
        }

        guard let bytes = data else {
            state = .failed(Self.unavailableText)
            return
        }
        if record.size > 0, bytes.count != record.size {
            Log.ui.notice("attachment.size.mismatch \(messageId, privacy: .public) expected=\(record.size, privacy: .public) got=\(bytes.count, privacy: .public)")
        }

        let manager = fileManager
        do {
            try await Task.detached(priority: .userInitiated) {
                try AttachmentOpener.write(bytes, to: url, fileManager: manager)
            }.value
        } catch {
            state = .failed(Self.writeFailedText)
            return
        }

        state = .idle
        previewURL = url
    }

    /// Notice row "×".
    func dismissError() {
        state = .idle
    }

    // MARK: pure helpers

    /// `<directory>/<messageId>/<partId>/<filename>`.
    nonisolated static func fileURL(root: URL, messageId: String, partId: String, filename: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let message = messageId.addingPercentEncoding(withAllowedCharacters: allowed) ?? messageId
        let part = partId.addingPercentEncoding(withAllowedCharacters: allowed) ?? partId
        return
            root
            .appendingPathComponent(message, isDirectory: true)
            .appendingPathComponent(part, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Strips path separators and control characters, trims, caps at 120 UTF-8 bytes, falls back to
    /// `attachment-<partId>`, and appends the `mimeExtensions` extension when the name has none.
    nonisolated static func sanitizedFilename(_ raw: String, partId: String, mimeType: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        name = String(String.UnicodeScalarView(scalars))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "." || name == ".." || name.hasPrefix(".") { name = "attachment-" + partId + name }
        if name.isEmpty { name = "attachment-" + partId }
        while name.utf8.count > 120 { name.removeLast() }
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            let type = mimeType.lowercased().split(separator: ";").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if let type, let ext = mimeExtensions[type] { name += "." + ext }
        }
        return name
    }

    /// User-facing text for a download failure (spec §5.2).
    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case GmailError.offline: return "You're offline. Try again when you have a connection."
        case GmailError.unauthorized: return "Sign in again to download attachments."
        case GmailError.rateLimited: return "Gmail is busy. Try again in a moment."
        default: return "Couldn't download this attachment."
        }
    }

    /// Removes `directory` recursively (sign-out wipe tail, tests).
    nonisolated static func purge(directory: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// Writes `data` atomically, creating intermediate directories. Called from a detached task.
    nonisolated static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
