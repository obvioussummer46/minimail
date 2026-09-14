import Foundation
import GRDB
import MailCore
import Observation
import os

/// Downloads one attachment on tap and hands its file URL to `.quickLookPreview` (architecture §8.4).
/// Never prefetches (architecture decision 8). `db` is `any DatabaseWriter` so tests can pass a `DatabaseQueue`.
/// T10.1 shell: the download, cache and filename logic land in T10.2.
@Observable final class AttachmentOpener {
    enum State: Equatable {
        case idle
        case downloading(messageId: String, partId: String)
        /// User-facing text (spec §5.2).
        case failed(String)
    }

    /// Refuse to open above this size (JSON `attachments.get` inflates bytes by 4/3).
    static let maxBytes = 25_000_000

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

    func open(messageId: String, partId: String) async {
        state = .failed("Couldn't open this attachment.")
    }

    func dismissError() {
        state = .idle
    }

    /// Removes `directory` recursively (sign-out wipe tail, tests).
    nonisolated static func purge(directory: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}
