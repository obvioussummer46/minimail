import Foundation

/// A message body as readable text, with its links kept.
///
/// The plain-text reading mode renders this instead of handing HTML to a `WKWebView`. Stripping tags the way
/// `Quoting` does would throw away every `href`, which is both a usability loss and a safety one: "click here"
/// with no visible destination is exactly the shape a phishing link wants. So the walker emits *runs*, and the
/// app turns each `.link` into a tappable, inspectable one.
///
/// String-based, no SwiftSoup: `MailCore` has no dependencies and its tests run on Linux.
public struct PlainTextBody: Sendable, Equatable {

    /// A stretch of body text, or one link. `runs` concatenated by their text equals `plain`.
    public enum Run: Sendable, Equatable {
        case text(String)
        case link(text: String, url: String)

        public var text: String {
            switch self {
            case .text(let value): return value
            case .link(let value, _): return value
            }
        }
    }

    public var runs: [Run]
    /// Every run flattened. Used for accessibility, snippets, and `Quoting`'s text/plain alternative.
    public var plain: String

    public var isEmpty: Bool { plain.isEmpty }

    public init(runs: [Run]) {
        self.runs = runs
        self.plain = runs.map(\.text).joined()
    }

    /// Body text of `html`: hidden elements dropped, block tags broken into lines, entities decoded, anchors
    /// kept as `.link` runs.
    public static func make(html: String) -> PlainTextBody {
        PlainTextBody(runs: normalized(walk(HTMLText.readable(html))))
    }

    /// A body that was already `text/plain`. Bare URLs still become links.
    public static func make(text: String) -> PlainTextBody {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return PlainTextBody(runs: normalized([.text(HTMLText.tidy(unified))]))
    }

    // MARK: - Walking

    /// Placeholder standing in for a link while the text around it is tidied. U+FFFC survives `tidy`, which
    /// only touches spaces, tabs and blank lines.
    private static let linkMarker: Character = "\u{FFFC}"

    private static func walk(_ html: String) -> [Run] {
        var runs: [Run] = []
        var out = ""
        /// Non-nil while inside an anchor: the pending href, and the text collected so far.
        var anchor: (url: String, text: String)?
        /// Tracked rather than read off `out`, which a link flush empties.
        var atLineStart = true

        func flushText() {
            guard !out.isEmpty else { return }
            runs.append(.text(out))
            out = ""
        }

        func append(_ piece: String) {
            guard let last = piece.last else { return }
            if anchor != nil { anchor?.text += piece } else { out += piece }
            atLineStart = last == "\n"
        }

        func emitLink(_ open: (url: String, text: String)) {
            let text = collapseLines(HTMLText.decodeEntities(open.text))
            // An anchor with no text is an image button; in text mode there is nothing to show.
            guard !text.isEmpty else { return }
            flushText()
            runs.append(.link(text: text, url: open.url))
            atLineStart = false
        }

        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            append(String(rest[..<open]))
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tagBody = rest[rest.index(after: open)..<close]
            let isClosing = tagBody.first == "/"
            let nameSlice = isClosing ? tagBody.dropFirst() : tagBody
            let name = String(nameSlice.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()

            if name == "a" {
                if isClosing {
                    if let open = anchor {
                        anchor = nil
                        emitLink(open)
                    }
                } else if anchor == nil, let href = attribute("href", in: tagBody), !href.isEmpty {
                    anchor = (url: HTMLText.decodeEntities(href), text: "")
                }
            } else if name == "br" {
                append("\n")
            } else if isClosing && HTMLText.breakAfter.contains(name) {
                append("\n")
            } else if !isClosing && name == "li" {
                if !atLineStart { append("\n") }
                append("- ")
            } else if !isClosing && HTMLText.breakAfter.contains(name) {
                if !atLineStart { append("\n") }
            }
            rest = rest[rest.index(after: close)...]
        }
        append(String(rest))
        // An unclosed anchor still has text worth showing.
        if let open = anchor {
            anchor = nil
            emitLink(open)
        }
        flushText()
        return runs.map { run in
            if case .text(let value) = run { return .text(HTMLText.decodeEntities(value)) }
            return run
        }
    }

    /// Link text is shown on one line: a wrapped anchor in the source should not break the sentence.
    private static func collapseLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func attribute(_ name: String, in tagBody: Substring) -> String? {
        guard let start = tagBody.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        // The character before the name must be a separator, or `data-href=` would match `href=`.
        if start.lowerBound > tagBody.startIndex {
            let before = tagBody[tagBody.index(before: start.lowerBound)]
            guard before == " " || before == "\t" || before == "\n" else { return nil }
        }
        let after = tagBody[start.upperBound...]
        guard let first = after.first else { return nil }
        if first == "\"" || first == "'" {
            let body = after.dropFirst()
            guard let end = body.firstIndex(of: first) else { return String(body) }
            return String(body[..<end])
        }
        return String(after.prefix(while: { $0 != " " && $0 != "\t" && $0 != "\n" }))
    }

    // MARK: - Normalising

    /// Tidies the whole body without disturbing the runs: links ride through `tidy` as placeholders and are
    /// put back in order afterwards.
    private static func normalized(_ runs: [Run]) -> [Run] {
        var links: [Run] = []
        var scratch = ""
        for run in runs {
            switch run {
            case .text(let value): scratch += value
            case .link:
                links.append(run)
                scratch.append(linkMarker)
            }
        }
        let tidied = HTMLText.tidy(scratch)

        var out: [Run] = []
        var buffer = ""
        var next = 0
        for character in tidied {
            if character == linkMarker, next < links.count {
                if !buffer.isEmpty {
                    out.append(.text(buffer))
                    buffer = ""
                }
                out.append(links[next])
                next += 1
            } else if character != linkMarker {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { out.append(.text(buffer)) }
        return out
    }
}
