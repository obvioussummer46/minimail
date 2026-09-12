import Foundation

/// A parsed `type/subtype; name=value; …` header value.
public struct ContentTypeValue: Sendable, Equatable {
    /// Lowercased and trimmed, e.g. `text/html`. Empty when the header carried no type.
    public var type: String
    /// Parameter names as written, values unquoted and unescaped, in source order.
    public var params: [(String, String)]

    public init(type: String, params: [(String, String)]) {
        self.type = type
        self.params = params
    }

    /// First parameter whose name matches case-insensitively.
    public func param(_ name: String) -> String? {
        let target = name.lowercased()
        return params.first(where: { $0.0.lowercased() == target })?.1
    }

    /// A tuple array cannot synthesise `Equatable`, so equality is spelled out. Call sites are unaffected.
    public static func == (lhs: ContentTypeValue, rhs: ContentTypeValue) -> Bool {
        guard lhs.type == rhs.type, lhs.params.count == rhs.params.count else { return false }
        for (left, right) in zip(lhs.params, rhs.params) where left.0 != right.0 || left.1 != right.1 {
            return false
        }
        return true
    }
}

public enum ContentTypeParams {

    /// Tokenizer rather than a regex: comments and whitespace outside quotes are ignored, a parameter without
    /// `=` is skipped, and a quoted value keeps its quoted pairs unescaped. Never throws.
    public static func parse(_ headerValue: String) -> ContentTypeValue {
        let unfolded = HeaderFolding.unfold(headerValue)
        let stripped = removingComments(unfolded)
        let segments = splitOutsideQuotes(stripped, separator: ";")

        let type = (segments.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var params: [(String, String)] = []

        for segment in segments.dropFirst() {
            guard let equalsIndex = indexOfFirstEqualsOutsideQuotes(segment) else { continue }
            let name = String(segment[segment.startIndex..<equalsIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let rawValue = String(segment[segment.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            params.append((name, unquote(rawValue)))
        }
        return ContentTypeValue(type: type, params: params)
    }

    /// A quoted value runs to its closing quote with `\x` unescaped; a bare token stops at whitespace.
    private static func unquote(_ raw: String) -> String {
        guard raw.hasPrefix("\"") else {
            return String(raw.prefix(while: { $0 != " " && $0 != "\t" }))
        }
        var out = ""
        var escaped = false
        for character in raw.dropFirst() {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return out
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func removingComments(_ value: String) -> String {
        var out = ""
        var depth = 0
        var inQuote = false
        var escaped = false
        for character in value {
            if escaped {
                if depth == 0 { out.append(character) }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                if depth == 0 { out.append(character) }
                continue
            }
            if inQuote {
                if character == "\"" { inQuote = false }
                out.append(character)
                continue
            }
            switch character {
            case "\"":
                inQuote = true
                out.append(character)
            case "(":
                depth += 1
            case ")":
                if depth > 0 { depth -= 1 }
            default:
                if depth == 0 { out.append(character) }
            }
        }
        return out
    }

    private static func splitOutsideQuotes(_ value: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inQuote.toggle()
                current.append(character)
                continue
            }
            if character == separator && !inQuote {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    private static func indexOfFirstEqualsOutsideQuotes(_ value: String) -> String.Index? {
        var inQuote = false
        var escaped = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuote.toggle()
            } else if character == "=" && !inQuote {
                return index
            }
            index = value.index(after: index)
        }
        return nil
    }
}
