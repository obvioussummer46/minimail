import Foundation

public struct OutgoingAttachment: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// Everything the builder needs to produce one RFC 5322 message.
public struct OutgoingMessage: Sendable, Equatable {
    public var from: Mailbox
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var subject: String
    public var date: Date
    public var timeZone: TimeZone
    public var messageID: String
    public var inReplyTo: String?
    public var references: [String]
    /// Line breaks in any convention; the builder normalises them.
    public var textBody: String
    /// A full document in production, though any fragment is accepted.
    public var htmlBody: String
    public var attachments: [OutgoingAttachment]

    public init(
        from: Mailbox,
        to: [Mailbox],
        cc: [Mailbox],
        subject: String,
        date: Date,
        timeZone: TimeZone,
        messageID: String,
        inReplyTo: String?,
        references: [String],
        textBody: String,
        htmlBody: String,
        attachments: [OutgoingAttachment]
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.timeZone = timeZone
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
    }
}

/// Supplies MIME boundaries. Random in production, fixed in tests so output is byte-comparable.
public struct BoundaryGenerator: Sendable {
    private let make: @Sendable (String) -> String

    private init(make: @escaping @Sendable (String) -> String) {
        self.make = make
    }

    public static let random = BoundaryGenerator { kind in
        var generator = SystemRandomNumberGenerator()
        let value = UInt64.random(in: 0...UInt64.max, using: &generator)
        let hex = String(value, radix: 16)
        return "=_minimail_\(kind)_" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    public static func fixed(alt: String, mixed: String) -> BoundaryGenerator {
        BoundaryGenerator { kind in
            switch kind {
            case "alt": return alt
            case "mixed": return mixed
            default: return "=_minimail_\(kind)_0000000000000000"
            }
        }
    }

    public func boundary(kind: String) -> String { make(kind) }
}
