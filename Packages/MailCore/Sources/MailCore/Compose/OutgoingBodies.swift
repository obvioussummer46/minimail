import Foundation

/// Assembles the two bodies of an outgoing message: the HTML people read and the plain-text alternative.
public enum OutgoingBodies {

    /// The four replacements an HTML text node needs, ampersand first.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The typed text wrapped in the default style, then the signature, then the quote. The quote sits outside
    /// the styled wrapper so the original keeps its own formatting.
    public static func html(
        typed: String,
        style: ComposeStyle,
        signatureHTML: String?,
        quoteHTML: String?
    ) -> String {
        let normalized = typed.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { line -> String in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                ? "<div><br></div>" : "<div>\(escape(line))</div>"
        }

        let opening = "<div dir=\"ltr\" class=\"minimail_default\" style=\"\(style.inlineCSS)\">"
        var out = opening + lines.joined() + "</div>"

        if let signatureHTML, !signatureHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "<div><br></div><span class=\"gmail_signature_prefix\">-- </span><br>"
            out += "<div dir=\"ltr\" class=\"gmail_signature\" data-smartmail=\"gmail_signature\">"
            out += "<div style=\"\(style.inlineCSS)\">\(signatureHTML)</div></div>"
        }

        if let quoteHTML {
            out += "<br>" + quoteHTML
        }
        return out
    }

    /// The minimal document wrapper. No colour-scheme meta: the sender's mail client decides how to render it.
    public static func document(bodyFragment: String) -> String {
        "<html><head><meta charset=\"utf-8\"></head><body>" + bodyFragment + "</body></html>"
    }

    /// Typed text, then the `-- ` signature separator, then the quote, each separated by a blank line.
    public static func text(typed: String, signatureText: String?, quoteText: String?) -> String {
        var body = typed.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }

        var parts = [body]
        if let signatureText {
            var signature = signatureText
            while signature.hasSuffix("\n") { signature.removeLast() }
            if !signature.isEmpty {
                parts += ["", "-- ", signature]
            }
        }
        if let quoteText, !quoteText.isEmpty {
            parts += ["", quoteText]
        }
        return parts.joined(separator: "\n")
    }
}
