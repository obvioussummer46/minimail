import GRDB
import MailCore

@testable import minimail

nonisolated enum TestDatabase {
    static func make() throws -> DatabaseQueue { try AppDatabase.openInMemory() }

    static func parsed(
        id: String, threadId: String? = nil, internalDate: Int64, labels: [String],
        from: Mailbox = Mailbox(name: "Alice", addr: "alice@example.com"),
        to: [Mailbox] = [Mailbox(name: nil, addr: "user@example.com")], cc: [Mailbox] = [],
        subject: String = "Subject", snippet: String = "", topMimeType: String? = "text/plain",
        messageID: String? = nil, inReplyTo: String? = nil, references: [String] = []
    ) -> ParsedMessage {
        ParsedMessage(
            id: id, threadId: threadId ?? id, historyId: 1, internalDate: internalDate, labelIds: labels,
            snippet: snippet,
            headers: ParsedHeaders(
                from: from, to: to, cc: cc, replyTo: [], subject: subject, messageID: messageID, inReplyTo: inReplyTo,
                references: references),
            topMimeType: topMimeType, body: nil, attachments: [])
    }

    static func seed(
        _ writer: any DatabaseWriter, _ messages: [ParsedMessage], selfAddresses: Set<String> = ["user@example.com"],
        generation: Int = 1, now: Int64 = 1_757_500_000_000
    ) throws {
        try writer.write { db in
            try SyncStateRepository.setSelfAddresses(db, selfAddresses)
            let threads = try MessageRepository.upsertMetadata(
                db, parsed: messages, selfAddresses: selfAddresses, generation: generation, now: now)
            try ThreadRepository.recomputeAggregates(db, threadIds: threads, selfAddresses: selfAddresses)
        }
    }

    static func seedMany(_ writer: any DatabaseWriter, count: Int, base: Int64 = 1_757_000_000_000) throws {
        try seedLabels(
            writer,
            [
                GmailLabel(id: "INBOX", name: "INBOX", type: "system"),
                GmailLabel(id: "UNREAD", name: "UNREAD", type: "system"),
                GmailLabel(id: "STARRED", name: "STARRED", type: "system"),
                GmailLabel(id: "SENT", name: "SENT", type: "system"),
                GmailLabel(id: "Label_12", name: "Customers/ACME", type: "user"),
            ])
        var messages: [ParsedMessage] = []
        for i in 0..<count {
            var labels: [String]
            if i % 11 == 0 {
                labels = ["TRASH"]
            } else {
                labels = ["INBOX"]
                if i % 5 == 0 { labels.append("UNREAD") }
                if i % 7 == 0 { labels.append("Label_12") }
            }
            messages.append(
                parsed(id: "m\(i)", threadId: "t\(i / 2)", internalDate: base + Int64(i) * 60_000, labels: labels))
        }
        try seed(writer, messages)
    }

    static func seedLabels(_ writer: any DatabaseWriter, _ labels: [GmailLabel]) throws {
        try writer.write { db in try LabelRepository.replaceAll(db, labels: labels) }
    }

    static let sampleLabels: [GmailLabel] = [
        GmailLabel(id: "INBOX", name: "INBOX", type: "system"),
        GmailLabel(id: "UNREAD", name: "UNREAD", type: "system"),
        GmailLabel(id: "STARRED", name: "STARRED", type: "system"),
        GmailLabel(id: "IMPORTANT", name: "IMPORTANT", type: "system"),
        GmailLabel(id: "SENT", name: "SENT", type: "system"),
        GmailLabel(id: "TRASH", name: "TRASH", type: "system"),
        GmailLabel(id: "CATEGORY_PROMOTIONS", name: "Promotions", type: "system"),
        GmailLabel(
            id: "Label_12", name: "Customers/ACME", type: "user", labelListVisibility: "labelShow",
            color: GmailLabelColor(textColor: "#ffffff", backgroundColor: "#4a86e8")),
        GmailLabel(id: "Label_13", name: "Hidden", type: "user", labelListVisibility: "labelHide"),
        GmailLabel(id: "Label_14", name: "IfUnread", type: "user", labelListVisibility: "labelShowIfUnread"),
    ]
}
