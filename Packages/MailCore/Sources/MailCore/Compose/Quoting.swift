import Foundation

public enum ComposeMode: String, Codable, Sendable {
    case replyAll, forward
}

/// A snapshot of the message being replied to or forwarded, taken when compose opens so a later sync cannot
/// change what the quote says.
public struct QuoteSource: Codable, Sendable, Equatable {
    public var author: Mailbox?
    public var date: Date
    public var subject: String
    public var to: [Mailbox]
    public var cc: [Mailbox]
    /// Quotable HTML: remote sources restored, inline images removed, renderer classes stripped.
    public var html: String?
    public var text: String?

    public init(
        author: Mailbox?,
        date: Date,
        subject: String,
        to: [Mailbox],
        cc: [Mailbox],
        html: String?,
        text: String?
    ) {
        self.author = author
        self.date = date
        self.subject = subject
        self.to = to
        self.cc = cc
        self.html = html
        self.text = text
    }
}

/// Builds the quoted original, in the shape Gmail uses so replies thread and collapse correctly elsewhere.
public enum Quoting {

    private static let banner = "---------- Forwarded message ---------"

    public static func attributionLine(author: Mailbox?, date: Date, timeZone: TimeZone) -> String {
        let stamp = HeaderDate.attribution(date, timeZone: timeZone)
        guard let author else { return "On \(stamp) wrote:" }
        return "On \(stamp) \(author.displayName) <\(author.addr)> wrote:"
    }

    public static func replyHTML(_ q: QuoteSource, timeZone: TimeZone) -> String {
        let stamp = OutgoingBodies.escape(HeaderDate.attribution(q.date, timeZone: timeZone))
        let author = q.author.map { " " + mailboxHTML($0) } ?? ""
        return "<div class=\"gmail_quote gmail_quote_container\">"
            + "<div dir=\"ltr\" class=\"gmail_attr\">On \(stamp)\(author) wrote:<br></div>"
            + "<blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;"
            + "border-left:1px solid rgb(204,204,204);padding-left:1ex\">"
            + bodyHTML(q)
            + "</blockquote></div>"
    }

    public static func replyText(_ q: QuoteSource, timeZone: TimeZone) -> String {
        let attribution = attributionLine(author: q.author, date: q.date, timeZone: timeZone)
        let source = sourceText(q)
        guard !source.isEmpty else { return attribution }
        let quoted = source.components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        return attribution + "\n" + quoted
    }

    public static func forwardHTML(_ q: QuoteSource, timeZone: TimeZone) -> String {
        let stamp = OutgoingBodies.escape(HeaderDate.attribution(q.date, timeZone: timeZone))
        var out = "<div class=\"gmail_quote gmail_quote_container\">"
            + "<div dir=\"ltr\" class=\"gmail_attr\">\(banner)<br>"

        if let author = q.author {
            let name = OutgoingBodies.escape(
                (author.name?.isEmpty ?? true) ? author.addr : author.name!
            )
            out += "From: <strong class=\"gmail_sendername\" dir=\"auto\">\(name)</strong> "
            out += "<span dir=\"auto\">\(angledLinkHTML(author.addr))</span><br>"
        }
        out += "Date: \(stamp)<br>"
        out += "Subject: \(OutgoingBodies.escape(q.subject))<br>"
        out += "To: \(q.to.map(mailboxHTML).joined(separator: ", "))<br>"
        if !q.cc.isEmpty {
            out += "Cc: \(q.cc.map(mailboxHTML).joined(separator: ", "))<br>"
        }
        out += "</div><br><br>" + bodyHTML(q) + "</div>"
        return out
    }

    public static func forwardText(_ q: QuoteSource, timeZone: TimeZone) -> String {
        var lines = [banner]
        if let author = q.author {
            lines.append("From: " + mailboxText(author))
        }
        lines.append("Date: " + HeaderDate.attribution(q.date, timeZone: timeZone))
        lines.append("Subject: " + q.subject)
        lines.append("To: " + q.to.map(mailboxText).joined(separator: ", "))
        if !q.cc.isEmpty {
            lines.append("Cc: " + q.cc.map(mailboxText).joined(separator: ", "))
        }

        let source = sourceText(q)
        guard !source.isEmpty else { return lines.joined(separator: "\n") }
        lines += ["", "", source]
        return lines.joined(separator: "\n")
    }

    /// A crude but predictable tag strip, used when only HTML is available and a plain-text quote is needed.
    public static func textFromHTML(_ html: String) -> String {
        let collapsed = collapseWhitespace(
            html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        )
        let withoutHidden = removingHiddenElements(collapsed)
        let stripped = strippingTags(withoutHidden)
        return tidy(decodeEntities(stripped))
    }

    // MARK: - Pieces

    private static func bodyHTML(_ q: QuoteSource) -> String {
        q.html ?? PlainTextHTML.convert(q.text ?? "")
    }

    private static func sourceText(_ q: QuoteSource) -> String {
        q.text ?? q.html.map(textFromHTML) ?? ""
    }

    private static func mailboxHTML(_ mailbox: Mailbox) -> String {
        guard let name = mailbox.name, !name.isEmpty else { return angledLinkHTML(mailbox.addr) }
        return OutgoingBodies.escape(name) + " " + angledLinkHTML(mailbox.addr)
    }

    private static func angledLinkHTML(_ addr: String) -> String {
        let escaped = OutgoingBodies.escape(addr)
        return "&lt;<a href=\"mailto:\(escaped)\">\(escaped)</a>&gt;"
    }

    private static func mailboxText(_ mailbox: Mailbox) -> String {
        guard let name = mailbox.name, !name.isEmpty else { return mailbox.addr }
        return "\(name) <\(mailbox.addr)>"
    }

    // MARK: - HTML to text

    private static func collapseWhitespace(_ html: String) -> String {
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

    private static func removingHiddenElements(_ html: String) -> String {
        var current = removingComments(html)
        for tag in ["script", "style", "head"] {
            current = removingElement(named: tag, in: current)
        }
        return current
    }

    private static func removingComments(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let start = rest.range(of: "<!--") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "-->") else { return out }
            rest = rest[end.upperBound...]
        }
        return out + rest
    }

    private static func removingElement(named tag: String, in html: String) -> String {
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

    private static let breakAfter: Set<String> = [
        "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table",
    ]

    private static func strippingTags(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: ">") else {
                return out
            }
            let tagBody = rest[rest.index(after: open)..<close]
            let isClosing = tagBody.first == "/"
            let nameSlice = isClosing ? tagBody.dropFirst() : tagBody
            let name = String(
                nameSlice.prefix(while: { $0.isLetter || $0.isNumber })
            ).lowercased()

            if name == "br" {
                out += "\n"
            } else if isClosing && breakAfter.contains(name) {
                out += "\n"
            } else if !isClosing && name == "li" {
                if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                out += "- "
            } else if !isClosing && breakAfter.contains(name) {
                if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    private static func decodeEntities(_ text: String) -> String {
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

    private static func numericEntity(_ digits: Substring) -> UInt32? {
        if digits.first == "x" || digits.first == "X" {
            return UInt32(digits.dropFirst(), radix: 16)
        }
        return UInt32(digits, radix: 10)
    }

    /// Trims each line, collapses runs of blank lines to one, and trims the ends.
    private static func tidy(_ text: String) -> String {
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
