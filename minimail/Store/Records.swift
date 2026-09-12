import Foundation
import GRDB
import MailCore

/// Shared JSON configuration for JSON columns: `.sortedKeys` + `.withoutEscapingSlashes`, dates as ms.
nonisolated enum RecordJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
    static func string<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func value<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        try? decoder.decode(type, from: Data(string.utf8))
    }
}

/// Records with JSON columns use the shared `RecordJSON` configuration for byte-stable columns.
nonisolated protocol JSONColumnRecord: FetchableRecord, PersistableRecord {}
extension JSONColumnRecord {
    nonisolated static func databaseJSONEncoder(for column: String) -> JSONEncoder { RecordJSON.encoder }
    nonisolated static func databaseJSONDecoder(for column: String) -> JSONDecoder { RecordJSON.decoder }
}

nonisolated struct LabelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "label"
    var id: String
    var name: String
    var type: String
    var labelListVisibility: String?
    var messageListVisibility: String?
    var textColor: String?
    var backgroundColor: String?
    var messagesUnread: Int?
    var threadsUnread: Int?
    var threadsTotal: Int?
    var countsFetchedAt: Int64?
    var sortOrder: Int
    var viewFetchedAt: Int64?
    var viewNextPageToken: String?
    var isUser: Bool { type == "user" }
}

nonisolated struct ThreadRecord: Codable, JSONColumnRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "thread"
    var id: String
    var subject: String
    var snippet: String
    var lastDate: Int64
    var lastInboxDate: Int64?
    var messageCount: Int
    var unreadCount: Int
    var inInbox: Bool
    var hasAttachments: Bool
    var participants: String
    var userLabelIds: [String]
    var isComplete: Bool
    var bodiesMissing: Int
}

nonisolated struct ThreadLabelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "thread_label"
    var labelId: String
    var threadId: String
    var lastDate: Int64
    var unreadCount: Int
}

nonisolated struct MessageRecord: Codable, JSONColumnRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "message"
    var id: String
    var threadId: String
    var historyId: Int64
    var internalDate: Int64
    var fromName: String?
    var fromAddr: String
    var isFromMe: Bool
    var toList: [Mailbox]
    var ccList: [Mailbox]
    var replyToList: [Mailbox]
    var subject: String
    var snippet: String
    var messageIdHeader: String?
    var inReplyTo: String?
    var referencesList: [String]
    var topMimeType: String?
    var serverLabelIds: [String]
    var labelIds: [String]
    var isUnread: Bool
    var inInbox: Bool
    var isHidden: Bool
    var hasAttachments: Bool
    var bodyState: Int
    var syncGeneration: Int
    var fetchedAt: Int64
    var from: Mailbox { Mailbox(name: fromName, addr: fromAddr) }
    var serverLabelSet: Set<String> { Set(serverLabelIds) }
    var labelSet: Set<String> { Set(labelIds) }
}

nonisolated struct MessageBodyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "message_body"
    var messageId: String
    var bodyHtml: String
    var bodyText: String?
    var hasRemoteImages: Bool
    var darkStrategy: String
    var sanitizerVersion: Int
    var fetchedAt: Int64
}

nonisolated struct AttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "attachment"
    var messageId: String
    var partId: String
    var filename: String
    var mimeType: String
    var size: Int
    var contentId: String?
    var isInline: Bool
    var attachmentId: String?
}

nonisolated enum OutboxKind: String, Codable, Sendable { case modify, send }
nonisolated enum OutboxState: String, Codable, Sendable { case pending, inFlight, failed }
nonisolated enum TransmitState: String, Codable, Sendable { case notSent, maybeSent }

/// `outbox.sendJob` JSON.
nonisolated struct SendJob: Codable, Sendable, Equatable {
    var mode: ComposeMode
    var originalMessageId: String
    var threadId: String
    var messageID: String
    var to: [Mailbox]
    var cc: [Mailbox]
    var subject: String
    var typedText: String
    var inReplyTo: String?
    var references: [String]
    var quoteSource: QuoteSource
    var attachments: [ForwardAttachmentRef]
    var includeSignature: Bool
}

nonisolated struct ForwardAttachmentRef: Codable, Sendable, Equatable {
    var partId: String
    var filename: String
    var mimeType: String
    var size: Int
    var attachmentId: String?
}

nonisolated struct OutboxRecord: Codable, JSONColumnRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "outbox"
    var id: Int64
    var kind: OutboxKind
    var state: OutboxState
    var attempts: Int
    var nextAttemptAt: Int64
    var createdAt: Int64
    var lastError: String?
    var threadId: String?
    var addLabelIds: [String]?
    var removeLabelIds: [String]?
    var affectedMessageIds: [String]?
    var sendJob: SendJob?
    var rfc822MessageId: String?
    var transmitState: TransmitState?
    var delta: LabelDelta { LabelDelta(add: Set(addLabelIds ?? []), remove: Set(removeLabelIds ?? [])) }
    var affectedSet: Set<String> { Set(affectedMessageIds ?? []) }
}

nonisolated struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "syncState"
    var key: String
    var value: String
}

nonisolated enum SyncKey: String, CaseIterable, Sendable {
    case historyId, syncGeneration, lastFullSyncAt, lastDeltaSyncAt, lastLabelCountsAt, lastCleanupAt, accountEmail,
        displayName, selfAddresses, sendAsSignature, inboxNextPageToken
}
