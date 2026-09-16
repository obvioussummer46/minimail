import Foundation

/// Shared HTML-to-text machinery. Used by `Quoting` for the text/plain alternative of outgoing mail and by
/// `PlainTextBody` for the plain-text reading mode; one implementation so the two can never drift.
///
/// Deliberately string-based rather than SwiftSoup: `MailCore` has no dependencies and its tests run on Linux.
enum HTMLText {

    /// `html` as plain text: hidden elements dropped, block tags turned into line breaks, entities decoded.
    static func plain(ofHTML html: String) -> String {
        PlainTextBody.make(html: html).plain
    }

    /// Normalises line endings and runs of whitespace, then drops comments, `script`, `style` and `head`.
    static func readable(_ html: String) -> String {
        let collapsed = collapseWhitespace(
            html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        )
        return removingHiddenElements(collapsed)
    }

    // MARK: - HTML to text

    static func collapseWhitespace(_ html: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in html {
            if character == " " || character == "\t" || character == "\n" {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        if pendingSpace { out.append(" ") }
        return out
    }

    static func removingHiddenElements(_ html: String) -> String {
        var current = removingComments(html)
        for tag in ["script", "style", "head"] {
            current = removingElement(named: tag, in: current)
        }
        return current
    }

    static func removingComments(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let start = rest.range(of: "<!--") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "-->") else { return out }
            rest = rest[end.upperBound...]
        }
        return out + rest
    }

    static func removingElement(named tag: String, in html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let start = rest.range(of: "<\(tag)", options: .caseInsensitive) {
            let afterName = rest[start.upperBound...].first
            if let afterName, afterName.isLetter || afterName.isNumber {
                out += rest[..<start.upperBound]
                rest = rest[start.upperBound...]
                continue
            }
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "</\(tag)>", options: .caseInsensitive)
            else { return out }
            rest = rest[end.upperBound...]
        }
        return out + rest
    }

    static let breakAfter: Set<String> = [
        "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table",
    ]

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    static func decodeEntities(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = after
                continue
            }
            let body = String(after[..<semi])
            if let named = namedEntities[body.lowercased()] {
                out += named
            } else if body.hasPrefix("#"),
                let scalar = numericEntity(body.dropFirst()),
                let unicode = Unicode.Scalar(scalar)
            {
                out.unicodeScalars.append(unicode)
            } else {
                out += "&" + body + ";"
            }
            rest = after[after.index(after: semi)...]
        }
        return out + rest
    }

    static func numericEntity(_ digits: Substring) -> UInt32? {
        if digits.first == "x" || digits.first == "X" {
            return UInt32(digits.dropFirst(), radix: 16)
        }
        return UInt32(digits, radix: 10)
    }

    /// Trims each line, collapses runs of blank lines to one, and trims the ends.
    static func tidy(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }

        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            out.append(line)
        }
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
