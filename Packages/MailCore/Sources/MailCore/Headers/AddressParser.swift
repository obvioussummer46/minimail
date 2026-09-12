import Foundation

/// RFC 5322 §3.4 address lists. A tokenizer rather than a regex, because quotes, comments, angle brackets and
/// groups all nest.
public enum AddressParser {

    /// Never throws. Garbage yields an empty list, or a best-effort mailbox holding the raw text.
    public static func parseList(_ headerValue: String) -> [Mailbox] {
        splitItems(HeaderFolding.unfold(headerValue)).compactMap(parseMailbox)
    }

    public static func parseFirst(_ headerValue: String) -> Mailbox? {
        parseList(headerValue).first
    }

    /// Splits on top-level commas. Group display names are dropped and their members kept.
    private static func splitItems(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuote = false
        var commentDepth = 0
        var inAngle = false
        var inGroup = false

        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]

            if inQuote {
                if scalar == "\\", index + 1 < scalars.count {
                    current.unicodeScalars.append(scalar)
                    current.unicodeScalars.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == "\"" { inQuote = false }
                current.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            if commentDepth > 0 {
                if scalar == "\\", index + 1 < scalars.count {
                    current.unicodeScalars.append(scalar)
                    current.unicodeScalars.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == "(" { commentDepth += 1 }
                if scalar == ")" { commentDepth -= 1 }
                current.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            switch scalar {
            case "\"":
                inQuote = true
                current.unicodeScalars.append(scalar)
            case "(":
                commentDepth = 1
                current.unicodeScalars.append(scalar)
            case "<":
                inAngle = true
                current.unicodeScalars.append(scalar)
            case ">":
                inAngle = false
                current.unicodeScalars.append(scalar)
            case ",":
                if inAngle {
                    current.unicodeScalars.append(scalar)
                } else {
                    items.append(current)
                    current = ""
                }
            case ":":
                if inAngle || inGroup {
                    current.unicodeScalars.append(scalar)
                } else {
                    inGroup = true
                    current = ""
                }
            case ";":
                if inAngle {
                    current.unicodeScalars.append(scalar)
                } else if inGroup {
                    items.append(current)
                    current = ""
                    inGroup = false
                } else {
                    current.unicodeScalars.append(scalar)
                }
            default:
                current.unicodeScalars.append(scalar)
            }
            index += 1
        }
        items.append(current)
        return items
    }

    private static func parseMailbox(_ item: String) -> Mailbox? {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if let angle = angleRange(trimmed) {
            var addrRaw = String(trimmed[trimmed.index(after: angle.open)..<angle.close])
            // obs-route: <@relay.example:user@host> keeps only the part after the last colon.
            if addrRaw.hasPrefix("@"), let colon = addrRaw.lastIndex(of: ":") {
                addrRaw = String(addrRaw[addrRaw.index(after: colon)...])
            }
            let addr = compactAddress(removingComments(addrRaw))
            guard !addr.isEmpty else { return nil }
            return Mailbox(name: decodePhrase(String(trimmed[trimmed.startIndex..<angle.open])), addr: addr)
        }

        let comments = topLevelComments(trimmed)
        let addr = compactAddress(removingComments(trimmed).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !addr.isEmpty else { return nil }
        let name = comments.last
            .map { RFC2047.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Mailbox(name: name, addr: addr)
    }

    /// The last top-level `<` and the first `>` after it.
    private static func angleRange(_ value: String) -> (open: String.Index, close: String.Index)? {
        var inQuote = false
        var depth = 0
        var lastOpen: String.Index?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if inQuote {
                if character == "\\" {
                    index = value.index(after: index)
                    if index < value.endIndex { index = value.index(after: index) }
                    continue
                }
                if character == "\"" { inQuote = false }
            } else if depth > 0 {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
            } else if character == "\"" {
                inQuote = true
            } else if character == "(" {
                depth = 1
            } else if character == "<" {
                lastOpen = index
            }
            index = value.index(after: index)
        }

        guard let open = lastOpen else { return nil }
        var scan = value.index(after: open)
        while scan < value.endIndex {
            if value[scan] == ">" { return (open, scan) }
            scan = value.index(after: scan)
        }
        return nil
    }

    private static func removingComments(_ value: String) -> String {
        var out = ""
        var depth = 0
        var inQuote = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "\\", index < value.index(before: value.endIndex) {
                let next = value.index(after: index)
                if depth == 0 {
                    out.append(character)
                    out.append(value[next])
                }
                index = value.index(after: next)
                continue
            }
            if inQuote {
                if character == "\"" { inQuote = false }
                out.append(character)
            } else if character == "\"" {
                inQuote = true
                out.append(character)
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                out.append(character)
            }
            index = value.index(after: index)
        }
        return out
    }

    /// Inner text of each top-level comment, in order, with quoted pairs unescaped.
    private static func topLevelComments(_ value: String) -> [String] {
        var comments: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "\\", index < value.index(before: value.endIndex) {
                let next = value.index(after: index)
                if depth > 0 { current.append(value[next]) }
                index = value.index(after: next)
                continue
            }
            if inQuote {
                if character == "\"" { inQuote = false }
            } else if character == "\"" && depth == 0 {
                inQuote = true
            } else if character == "(" {
                depth += 1
                if depth == 1 {
                    current = ""
                    index = value.index(after: index)
                    continue
                }
            } else if character == ")" {
                if depth == 1 {
                    comments.append(current)
                    current = ""
                    depth = 0
                    index = value.index(after: index)
                    continue
                }
                if depth > 0 { depth -= 1 }
            }
            if depth > 0 { current.append(character) }
            index = value.index(after: index)
        }
        return comments
    }

    /// Drops whitespace outside quotes; an address never legitimately contains it.
    private static func compactAddress(_ value: String) -> String {
        var out = ""
        var inQuote = false
        for character in value {
            if character == "\"" {
                inQuote.toggle()
                out.append(character)
                continue
            }
            if !inQuote && (character == " " || character == "\t") { continue }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A display phrase: comments dropped, quoted strings unescaped, whitespace collapsed, encoded-words decoded.
    private static func decodePhrase(_ phrase: String) -> String? {
        let withoutComments = removingComments(phrase)
        var unquoted = ""
        var inQuote = false
        var index = withoutComments.startIndex
        while index < withoutComments.endIndex {
            let character = withoutComments[index]
            if character == "\\", inQuote, index < withoutComments.index(before: withoutComments.endIndex) {
                let next = withoutComments.index(after: index)
                unquoted.append(withoutComments[next])
                index = withoutComments.index(after: next)
                continue
            }
            if character == "\"" {
                inQuote.toggle()
                index = withoutComments.index(after: index)
                continue
            }
            unquoted.append(character)
            index = withoutComments.index(after: index)
        }

        let collapsed = unquoted
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        let decoded = RFC2047.decode(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}
