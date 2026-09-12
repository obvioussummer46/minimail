import Foundation

/// A Gmail `uint64` that travels as a JSON string. A plain number is accepted too, because the API is not
/// consistent about it across endpoints.
public struct StringUInt64: Codable, Sendable, Equatable, Comparable, Hashable, ExpressibleByIntegerLiteral {
    public var value: UInt64

    public init(_ value: UInt64) { self.value = value }
    public init(integerLiteral value: UInt64) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard let parsed = UInt64(trimmed) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected a decimal uint64 string, got \"\(string)\""
                )
            }
            value = parsed
            return
        }
        value = try container.decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }

    public static func < (lhs: StringUInt64, rhs: StringUInt64) -> Bool { lhs.value < rhs.value }
}

/// A Gmail `int64` that travels as a JSON string, such as `internalDate` in epoch milliseconds.
public struct StringInt64: Codable, Sendable, Equatable, Comparable, Hashable, ExpressibleByIntegerLiteral {
    public var value: Int64

    public init(_ value: Int64) { self.value = value }
    public init(integerLiteral value: Int64) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard let parsed = Int64(trimmed) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected a decimal int64 string, got \"\(string)\""
                )
            }
            value = parsed
            return
        }
        value = try container.decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }

    public static func < (lhs: StringInt64, rhs: StringInt64) -> Bool { lhs.value < rhs.value }
}

/// `users.getProfile`.
public struct GmailProfile: Codable, Sendable, Equatable {
    public var emailAddress: String
    public var historyId: StringUInt64

    public init(emailAddress: String, historyId: StringUInt64) {
        self.emailAddress = emailAddress
        self.historyId = historyId
    }
}

/// Label colours are `#rrggbb` strings. Gmail only accepts its own palette on write; reads are not validated.
public struct GmailLabelColor: Codable, Sendable, Equatable {
    public var textColor: String?
    public var backgroundColor: String?

    public init(textColor: String?, backgroundColor: String?) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}

/// A label. `labels.list` fills the identity fields only; the counts and colour need `labels.get`.
public struct GmailLabel: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String?
    public var messageListVisibility: String?
    public var labelListVisibility: String?
    public var messagesTotal: Int?
    public var messagesUnread: Int?
    public var threadsTotal: Int?
    public var threadsUnread: Int?
    public var color: GmailLabelColor?

    public init(
        id: String,
        name: String,
        type: String? = nil,
        messageListVisibility: String? = nil,
        labelListVisibility: String? = nil,
        messagesTotal: Int? = nil,
        messagesUnread: Int? = nil,
        threadsTotal: Int? = nil,
        threadsUnread: Int? = nil,
        color: GmailLabelColor? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.messageListVisibility = messageListVisibility
        self.labelListVisibility = labelListVisibility
        self.messagesTotal = messagesTotal
        self.messagesUnread = messagesUnread
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
        self.color = color
    }
}

public struct GmailListLabelsResponse: Codable, Sendable, Equatable {
    public var labels: [GmailLabel]?

    public init(labels: [GmailLabel]?) { self.labels = labels }
}

public struct GmailHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// `data` is base64url of the part's bytes with its transfer encoding already removed.
public struct GmailPartBody: Codable, Sendable, Equatable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?

    public init(attachmentId: String? = nil, size: Int? = nil, data: String? = nil) {
        self.attachmentId = attachmentId
        self.size = size
        self.data = data
    }
}

/// One MIME part, recursive through `parts`.
public struct GmailPart: Codable, Sendable, Equatable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeader]?
    public var body: GmailPartBody?
    public var parts: [GmailPart]?

    public init(
        partId: String? = nil,
        mimeType: String? = nil,
        filename: String? = nil,
        headers: [GmailHeader]? = nil,
        body: GmailPartBody? = nil,
        parts: [GmailPart]? = nil
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }

    /// First header matching `name` case-insensitively, unfolded and trimmed.
    public func header(_ name: String) -> String? {
        let target = name.lowercased()
        guard let match = headers?.first(where: { $0.name.lowercased() == target }) else { return nil }
        return HeaderFolding.unfold(match.value)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}

/// A message. `payload` is absent for `format=minimal`, and carries only the mime type and headers for
/// `format=metadata` under the hydration field mask.
public struct GmailMessage: Codable, Sendable, Equatable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: StringUInt64?
    public var internalDate: StringInt64?
    public var sizeEstimate: Int?
    public var payload: GmailPart?

    public init(
        id: String,
        threadId: String? = nil,
        labelIds: [String]? = nil,
        snippet: String? = nil,
        historyId: StringUInt64? = nil,
        internalDate: StringInt64? = nil,
        sizeEstimate: Int? = nil,
        payload: GmailPart? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.sizeEstimate = sizeEstimate
        self.payload = payload
    }
}

public struct GmailThread: Codable, Sendable, Equatable {
    public var id: String
    public var historyId: StringUInt64?
    public var snippet: String?
    public var messages: [GmailMessage]?

    public init(
        id: String,
        historyId: StringUInt64? = nil,
        snippet: String? = nil,
        messages: [GmailMessage]? = nil
    ) {
        self.id = id
        self.historyId = historyId
        self.snippet = snippet
        self.messages = messages
    }
}

/// The lightweight `{id, threadId[, labelIds]}` shape used by list responses and history records.
public struct GmailMessageRef: Codable, Sendable, Equatable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?

    public init(id: String, threadId: String? = nil, labelIds: [String]? = nil) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
    }
}

public struct GmailListMessagesResponse: Codable, Sendable, Equatable {
    public var messages: [GmailMessageRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?

    public init(
        messages: [GmailMessageRef]? = nil,
        nextPageToken: String? = nil,
        resultSizeEstimate: Int? = nil
    ) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
}

public struct GmailHistoryMessageChange: Codable, Sendable, Equatable {
    public var message: GmailMessageRef

    public init(message: GmailMessageRef) { self.message = message }
}

public struct GmailHistoryLabelChange: Codable, Sendable, Equatable {
    public var message: GmailMessageRef
    public var labelIds: [String]?

    public init(message: GmailMessageRef, labelIds: [String]?) {
        self.message = message
        self.labelIds = labelIds
    }
}

/// One history record. The redundant top-level `messages` array is deliberately not decoded.
public struct GmailHistory: Codable, Sendable, Equatable {
    public var id: StringUInt64
    public var messagesAdded: [GmailHistoryMessageChange]?
    public var messagesDeleted: [GmailHistoryMessageChange]?
    public var labelsAdded: [GmailHistoryLabelChange]?
    public var labelsRemoved: [GmailHistoryLabelChange]?

    public init(
        id: StringUInt64,
        messagesAdded: [GmailHistoryMessageChange]? = nil,
        messagesDeleted: [GmailHistoryMessageChange]? = nil,
        labelsAdded: [GmailHistoryLabelChange]? = nil,
        labelsRemoved: [GmailHistoryLabelChange]? = nil
    ) {
        self.id = id
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }
}

public struct GmailListHistoryResponse: Codable, Sendable, Equatable {
    public var history: [GmailHistory]?
    public var nextPageToken: String?
    public var historyId: StringUInt64?

    public init(
        history: [GmailHistory]? = nil,
        nextPageToken: String? = nil,
        historyId: StringUInt64? = nil
    ) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
}

/// A send-as identity. Its `signature` is the one the Gmail web UI uses; the API never appends it for us.
public struct GmailSendAs: Codable, Sendable, Equatable {
    public var sendAsEmail: String
    public var displayName: String?
    public var signature: String?
    public var isPrimary: Bool?
    public var isDefault: Bool?
    public var verificationStatus: String?

    public init(
        sendAsEmail: String,
        displayName: String? = nil,
        signature: String? = nil,
        isPrimary: Bool? = nil,
        isDefault: Bool? = nil,
        verificationStatus: String? = nil
    ) {
        self.sendAsEmail = sendAsEmail
        self.displayName = displayName
        self.signature = signature
        self.isPrimary = isPrimary
        self.isDefault = isDefault
        self.verificationStatus = verificationStatus
    }
}

public struct GmailListSendAsResponse: Codable, Sendable, Equatable {
    public var sendAs: [GmailSendAs]?

    public init(sendAs: [GmailSendAs]?) { self.sendAs = sendAs }
}

/// Body of `threads.modify` and `messages.modify`. Nil arrays are omitted from the JSON.
public struct GmailModifyRequest: Encodable, Sendable, Equatable {
    public var addLabelIds: [String]?
    public var removeLabelIds: [String]?

    public init(addLabelIds: [String]?, removeLabelIds: [String]?) {
        self.addLabelIds = addLabelIds
        self.removeLabelIds = removeLabelIds
    }
}

/// Body of `messages.send`. `raw` is padded base64url of the RFC 5322 bytes.
public struct GmailSendRequest: Encodable, Sendable, Equatable {
    public var raw: String
    public var threadId: String?

    public init(raw: String, threadId: String?) {
        self.raw = raw
        self.threadId = threadId
    }
}

/// Google's error envelope. Decoding throws when the body carries no `error` object.
public struct GmailErrorEnvelope: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var reason: String?
        public var message: String?

        public init(reason: String?, message: String?) {
            self.reason = reason
            self.message = message
        }
    }

    public struct Inner: Codable, Sendable, Equatable {
        public var code: Int?
        public var message: String?
        public var status: String?
        public var errors: [Item]?

        public init(code: Int?, message: String?, status: String?, errors: [Item]?) {
            self.code = code
            self.message = message
            self.status = status
            self.errors = errors
        }
    }

    public var error: Inner

    public init(error: Inner) { self.error = error }

    /// The reason string the client maps to its own error cases.
    public var primaryReason: String? { error.errors?.first?.reason }
}

/// `format=` values of `messages.get` and `threads.get`.
public enum GmailFormat: String, Sendable {
    case minimal, full, raw, metadata
}

/// `metadataHeaders=` values for hydration, in wire order.
public let gmailMetadataHeaders = [
    "From", "To", "Cc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References",
]
