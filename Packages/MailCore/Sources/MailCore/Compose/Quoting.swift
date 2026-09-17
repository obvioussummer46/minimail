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
        out += "<div dir=\"ltr\" class=\"gmail_attr\">\(banner)<br>"

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

    /// Plain text of `html`, for the text/plain alternative when only HTML is available. Shares its walker
    /// with the plain-text reading mode, so a quote can never say something the read view did not show.
    public static func textFromHTML(_ html: String) -> String {
        HTMLText.plain(ofHTML: html)
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

}
