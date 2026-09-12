import Foundation

/// Decoded RFC 5322 headers of one message. Encoded-words are already resolved.
public struct ParsedHeaders: Sendable, Equatable {
    public var from: Mailbox?
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var replyTo: [Mailbox]
    /// Decoded, unfolded, whitespace runs collapsed, trimmed. Empty when the header is absent.
    public var subject: String
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]

    public init(
        from: Mailbox?,
        to: [Mailbox],
        cc: [Mailbox],
        replyTo: [Mailbox],
        subject: String,
        messageID: String?,
        inReplyTo: String?,
        references: [String]
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.subject = subject
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// One fetchable part: an attachment, an inline image, or a text body that Gmail only offers by id.
public struct ParsedAttachment: Sendable, Equatable {
    public var partId: String
    /// Empty only for deferred text parts.
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Content-ID with the angle brackets removed, when the part carries one.
    public var contentId: String?
    /// Transient id for `attachments.get`. Nil when the bytes arrived inline.
    public var attachmentId: String?
    public var inlineData: Data?
    /// Charset parameter for text parts, lowercased.
    public var charset: String?

    public init(
        partId: String,
        filename: String,
        mimeType: String,
        size: Int,
        contentId: String?,
        attachmentId: String?,
        inlineData: Data?,
        charset: String? = nil
    ) {
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
        self.attachmentId = attachmentId
        self.inlineData = inlineData
        self.charset = charset
    }
}

/// The bodies the tree walk chose, charset-decoded with newline line endings.
public struct ParsedBody: Sendable, Equatable {
    public var html: String?
    public var text: String?
    /// Text parts Gmail delivered by id rather than inline. Rare, and fetched on demand.
    public var deferredTextParts: [ParsedAttachment]

    public init(html: String?, text: String?, deferredTextParts: [ParsedAttachment]) {
        self.html = html
        self.text = text
        self.deferredTextParts = deferredTextParts
    }
}

public struct ParsedMessage: Sendable, Equatable {
    public var id: String
    /// Falls back to `id`: a thread's first message has the same value for both.
    public var threadId: String
    public var historyId: UInt64
    /// Epoch milliseconds. Zero when absent.
    public var internalDate: Int64
    public var labelIds: [String]
    /// Entity-decoded and trimmed.
    public var snippet: String
    public var headers: ParsedHeaders
    public var topMimeType: String?
    /// Nil for metadata and minimal formats.
    public var body: ParsedBody?
    /// Every fetchable part in tree order, inline images included.
    public var attachments: [ParsedAttachment]

    public init(
        id: String,
        threadId: String,
        historyId: UInt64,
        internalDate: Int64,
        labelIds: [String],
        snippet: String,
        headers: ParsedHeaders,
        topMimeType: String?,
        body: ParsedBody?,
        attachments: [ParsedAttachment]
    ) {
        self.id = id
        self.threadId = threadId
        self.historyId = historyId
        self.internalDate = internalDate
        self.labelIds = labelIds
        self.snippet = snippet
        self.headers = headers
        self.topMimeType = topMimeType
        self.body = body
        self.attachments = attachments
    }
}

/// Turns a Gmail message into something the app can store and render. Never throws: malformed input degrades
/// to empty fields rather than losing the message.
public enum MessageParser {

    private struct Context {
        var html: String?
        var text: String?
        var deferred: [ParsedAttachment] = []
        var attachments: [ParsedAttachment] = []
    }

    public static func parse(_ message: GmailMessage) -> ParsedMessage {
        let payload = message.payload

        let headers = ParsedHeaders(
            from: payload?.header("From").flatMap(AddressParser.parseFirst),
            to: payload?.header("To").map(AddressParser.parseList) ?? [],
            cc: payload?.header("Cc").map(AddressParser.parseList) ?? [],
            replyTo: payload?.header("Reply-To").map(AddressParser.parseList) ?? [],
            subject: collapseWhitespace(RFC2047.decode(payload?.header("Subject") ?? "")),
            messageID: payload?.header("Message-ID").flatMap(MessageIDs.normalize),
            inReplyTo: payload?.header("In-Reply-To")
                .flatMap { MessageIDs.split($0).first }
                .flatMap(MessageIDs.normalize),
            references: payload?.header("References").map(MessageIDs.split) ?? []
        )

        var parsed = ParsedMessage(
            id: message.id,
            threadId: message.threadId ?? message.id,
            historyId: message.historyId?.value ?? 0,
            internalDate: message.internalDate?.value ?? 0,
            labelIds: message.labelIds ?? [],
            snippet: SnippetEntities.decode(message.snippet ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            headers: headers,
            topMimeType: payload?.mimeType?.lowercased(),
            body: nil,
            attachments: []
        )

        // Metadata and minimal formats carry no fetchable bytes anywhere, and neither does an empty message.
        let isMetadataOnly =
            payload == nil
            || (payload?.parts == nil && payload?.body?.data == nil && payload?.body?.attachmentId == nil)
        if isMetadataOnly { return parsed }

        var context = Context()
        collect(payload!, into: &context)
        parsed.body = ParsedBody(
            html: context.html,
            text: context.text,
            deferredTextParts: context.deferred
        )
        parsed.attachments = context.attachments
        return parsed
    }

    /// Base64url bytes plus the part's charset, with line endings normalised.
    public static func decodeText(_ part: GmailPart) -> String? {
        guard let data = part.body?.data, let bytes = Base64URL.decode(data) else { return nil }
        let charset = ContentTypeParams.parse(part.header("Content-Type") ?? "").param("charset")
        return decodeText(bytes: bytes, charset: charset)
    }

    /// The same decode for bytes that arrived separately, from `attachments.get`.
    public static func decodeText(bytes: Data, charset: String?) -> String {
        let decoded = Charsets.decode(bytes, charset: charset)
        return decoded.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Tree walk

    private static func collect(_ part: GmailPart, into context: inout Context) {
        let mimeType = (part.mimeType ?? "application/octet-stream").lowercased()
        let contentType = ContentTypeParams.parse(part.header("Content-Type") ?? "")
        let charset = mimeType.hasPrefix("text/") ? contentType.param("charset")?.lowercased() : nil
        let contentID = part.header("Content-ID")
            .map(stripAngleBrackets)
            .flatMap { $0.isEmpty ? nil : $0 }
        let disposition = part.header("Content-Disposition").map(ContentTypeParams.parse)
        let filename = fallbackFilename(part, contentType: contentType, disposition: disposition)
        let hasData = part.body?.data?.isEmpty == false
        let attachmentId = part.body?.attachmentId.flatMap { $0.isEmpty ? nil : $0 }

        // A part Gmail will only hand over separately. Never recursed into.
        if let attachmentId {
            var attachment = ParsedAttachment(
                partId: part.partId ?? "",
                filename: filename,
                mimeType: mimeType,
                size: part.body?.size ?? 0,
                contentId: contentID,
                attachmentId: attachmentId,
                inlineData: nil,
                charset: charset
            )
            let looksLikeBodyText =
                mimeType.hasPrefix("text/") && (part.filename ?? "").isEmpty && contentID == nil
            if looksLikeBodyText {
                attachment.filename = ""
                context.deferred.append(attachment)
            } else {
                context.attachments.append(attachment)
            }
            return
        }

        if mimeType.hasPrefix("multipart/") {
            for child in part.parts ?? [] { collect(child, into: &context) }
            return
        }

        // First HTML and first plain part win, in tree order. This matches Gmail's own client.
        if mimeType == "text/html", context.html == nil, (part.filename ?? "").isEmpty {
            context.html = decodeText(part)
            return
        }
        if mimeType == "text/plain", context.text == nil, (part.filename ?? "").isEmpty {
            context.text = decodeText(part)
            return
        }

        // A small attachment or inline image whose bytes came along with the message.
        if hasData, !(part.filename ?? "").isEmpty || contentID != nil {
            let bytes = part.body?.data.flatMap(Base64URL.decode) ?? Data()
            context.attachments.append(
                ParsedAttachment(
                    partId: part.partId ?? "",
                    filename: filename,
                    mimeType: mimeType,
                    size: part.body?.size ?? bytes.count,
                    contentId: contentID,
                    attachmentId: nil,
                    inlineData: bytes,
                    charset: charset
                )
            )
            return
        }

        // Anything else is not shown and not offered: delivery-status text, a second HTML alternative,
        // an expanded message/rfc822 without an id.
    }

    private static func stripAngleBrackets(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func fallbackFilename(
        _ part: GmailPart,
        contentType: ContentTypeValue,
        disposition: ContentTypeValue?
    ) -> String {
        if let name = part.filename, !name.isEmpty {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = RFC2231.parameter(named: "filename", in: disposition?.params ?? []) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = RFC2231.parameter(named: "name", in: contentType.params) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "attachment-\(part.partId ?? "")"
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Gmail snippets arrive HTML-escaped. One left-to-right pass, so `&amp;lt;` decodes once and stays `&lt;`.
enum SnippetEntities {

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }

        var out = ""
        var index = s.startIndex
        while index < s.endIndex {
            guard s[index] == "&" else {
                out.append(s[index])
                index = s.index(after: index)
                continue
            }
            let afterAmp = s.index(after: index)
            let limit = s.index(afterAmp, offsetBy: 32, limitedBy: s.endIndex) ?? s.endIndex
            guard let semi = s[afterAmp..<limit].firstIndex(of: ";") else {
                out.append(s[index])
                index = afterAmp
                continue
            }
            let name = String(s[afterAmp..<semi])
            if let replacement = replacement(for: name) {
                out += replacement
                index = s.index(after: semi)
            } else {
                out.append(s[index])
                index = afterAmp
            }
        }
        return out
    }

    private static func replacement(for name: String) -> String? {
        if let known = named[name] { return known }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        return value.flatMap(Unicode.Scalar.init).map(String.init)
    }
}
