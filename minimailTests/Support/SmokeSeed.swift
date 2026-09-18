import GRDB
import MailCore
import MailHTML

@testable import minimail

/// Spec 14 §3.2 / §4.4.1. Additive `TestDatabase` helpers the smoke tests share (module 06 owns the base file).
extension TestDatabase {

    /// What `seedSmoke` wrote, so the smoke tests assert against values instead of literals.
    nonisolated struct SmokeSeed: Sendable, Equatable {
        let threadIds: [String]
        let openThreadId: String
        let newestMessageId: String
        let subject: String
        let bodyMarker: String
        let sender: Mailbox
        let ccRecipient: Mailbox
        let selfAddress: String
        let now: Int64
    }

    /// Seeds the fixture account the smoke tests share, in one write transaction (§4.4.1).
    @discardableResult
    static func seedSmoke(_ writer: any DatabaseWriter, now: Int64 = 1_757_500_000_000) throws -> SmokeSeed {
        let sender = Mailbox(name: "Alice Adams", addr: "alice@example.com")
        let cc = Mailbox(name: "Bob Brown", addr: "bob@example.com")
        let me = Mailbox(name: nil, addr: "user@example.com")
        let selfAddresses: Set<String> = ["user@example.com"]
        let bodyMarker = "MM-SMOKE-BODY"

        let messages = [
            parsed(
                id: "m1a", threadId: "t1", internalDate: now - 3_600_000, labels: ["INBOX"], from: sender, to: [me],
                subject: "Quarterly report", messageID: "<m1a@example.com>"),
            parsed(
                id: "m1b", threadId: "t1", internalDate: now, labels: ["INBOX", "UNREAD", "Label_12"], from: sender,
                to: [me], cc: [cc], subject: "Re: Quarterly report", topMimeType: "multipart/mixed",
                messageID: "<m1b@example.com>", inReplyTo: "<m1a@example.com>", references: ["<m1a@example.com>"]),
            parsed(id: "m2", threadId: "t2", internalDate: now - 7_200_000, labels: ["INBOX"], subject: "Invoice 4711"),
            parsed(
                id: "m3", threadId: "t3", internalDate: now - 10_800_000, labels: ["INBOX", "UNREAD"], subject: "Lunch?"
            ),
        ]

        try writer.write { db in
            try LabelRepository.replaceAll(db, labels: sampleLabels)
            try SyncStateRepository.set(db, .accountEmail, "user@example.com")
            try SyncStateRepository.setSelfAddresses(db, selfAddresses)
            try SyncStateRepository.set(db, .displayName, "Smoke User")
            try SyncStateRepository.set(db, .historyId, "5000")
            try SyncStateRepository.set(db, .syncGeneration, "1")
            let threads = try MessageRepository.upsertMetadata(
                db, parsed: messages, selfAddresses: selfAddresses, generation: 1, now: now)
            try ThreadRepository.recomputeAggregates(db, threadIds: threads, selfAddresses: selfAddresses)

            let attachment = ParsedAttachment(
                partId: "2", filename: "report.pdf", mimeType: "application/pdf", size: 125, contentId: nil,
                attachmentId: "att-smoke", inlineData: nil)
            try BodyRepository.storeBody(
                db, messageId: "m1b",
                body: SanitizedBody(
                    html: "<div>\(bodyMarker) quarterly numbers attached</div>", hasRemoteImages: false,
                    darkStrategy: .plain, referencedContentIDs: []),
                text: "\(bodyMarker) quarterly numbers attached", attachments: [attachment], referenced: [],
                sanitizerVersion: Sanitizer.version, now: now)
            try ThreadRepository.recomputeAggregates(db, threadIds: ["t1"], selfAddresses: selfAddresses)
            try ThreadRepository.markComplete(db, threadId: "t1", complete: true)
        }

        return SmokeSeed(
            threadIds: ["t1", "t2", "t3"], openThreadId: "t1", newestMessageId: "m1b", subject: "Quarterly report",
            bodyMarker: bodyMarker, sender: sender, ccRecipient: cc, selfAddress: "user@example.com", now: now)
    }

    /// Stores a sanitized body for one existing message, then recomputes the owning thread's aggregates (§3.2).
    static func seedBody(
        _ writer: any DatabaseWriter, messageId: String, html: String, text: String?,
        attachments: [ParsedAttachment] = [], now: Int64 = 1_757_500_000_000
    ) throws {
        try writer.write { db in
            try BodyRepository.storeBody(
                db, messageId: messageId,
                body: SanitizedBody(
                    html: html, hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []),
                text: text, attachments: attachments, referenced: [], sanitizerVersion: Sanitizer.version, now: now)
            let selfAddresses = try SyncStateRepository.selfAddresses(db)
            if let threadId = try String.fetchOne(
                db, sql: "SELECT threadId FROM message WHERE id = ?", arguments: [messageId])
            {
                try ThreadRepository.recomputeAggregates(db, threadIds: [threadId], selfAddresses: selfAddresses)
            }
        }
    }
}
