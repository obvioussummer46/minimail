import Foundation

/// Message identifiers and the reply chain that threads a conversation.
public enum MessageIDs {

    /// Every `<…>` token in reading order. Text outside the brackets and empty `<>` are dropped, and the
    /// tokens need no whitespace between them.
    public static func split(_ referencesValue: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(referencesValue)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[rest.index(after: open)...].firstIndex(of: ">") else { break }
            let inner = rest[rest.index(after: open)..<close]
            if !inner.isEmpty { ids.append("<" + String(inner) + ">") }
            rest = rest[rest.index(after: close)...]
        }
        return ids
    }

    /// Trims, adds the missing angle brackets, and rejects an empty or whitespace-bearing identifier. An `@`
    /// is not required: Gmail synthesises ids without one.
    public static func normalize(_ id: String) -> String? {
        var trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { trimmed.removeFirst() }
        if trimmed.hasSuffix(">") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        else { return nil }
        return "<" + trimmed + ">"
    }

    public static func generate(domain: String, uuid: UUID = UUID()) -> String {
        "<\(uuid.uuidString)@\(domain.isEmpty ? "localhost" : domain)>"
    }

    /// RFC 5322 §3.6.4. The parent's References wins; failing that a single In-Reply-To; then the parent's own
    /// Message-ID is appended. Duplicates are removed, keeping the first occurrence.
    public static func referencesChain(
        parentReferences: [String],
        parentInReplyTo: String?,
        parentMessageID: String?
    ) -> [String] {
        var base = parentReferences.compactMap(normalize)
        if base.isEmpty, let inReplyTo = parentInReplyTo {
            let ids = split(inReplyTo).compactMap(normalize)
            if ids.count == 1 { base = ids }
        }
        if let messageID = parentMessageID.flatMap(normalize) { base.append(messageID) }

        var seen = Set<String>()
        return base.filter { seen.insert($0).inserted }
    }
}
