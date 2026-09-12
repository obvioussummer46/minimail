import Foundation

/// Renders a plain-text body as the HTML the thread document shows, with bare URLs made clickable.
public enum PlainTextHTML {

    private static let linkTrailing: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\"", "'",
    ]
    private static let linkLeading: Set<Character> = ["(", "<", "[", "\"", "'"]

    public static func convert(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let rendered = lines.map { line -> String in
            let stripped = line.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
            if stripped.isEmpty { return "<div><br></div>" }
            return "<div>" + linkify(line) + "</div>"
        }
        return "<div class=\"mm-plaintext\">" + rendered.joined() + "</div>"
    }

    /// Splits on runs of space and tab, keeping the separators, and linkifies each word.
    private static func linkify(_ line: String) -> String {
        var out = ""
        var word = ""
        for character in line {
            if character == " " || character == "\t" {
                if !word.isEmpty {
                    out += renderWord(word)
                    word = ""
                }
                out += OutgoingBodies.escape(String(character))
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { out += renderWord(word) }
        return out
    }

    private static func renderWord(_ word: String) -> String {
        var lead = ""
        var core = Substring(word)
        while let first = core.first, linkLeading.contains(first) {
            lead.append(first)
            core = core.dropFirst()
        }

        let lowered = core.lowercased()
        let scheme: String?
        if lowered.hasPrefix("https://") {
            scheme = "https://"
        } else if lowered.hasPrefix("http://") {
            scheme = "http://"
        } else if lowered.hasPrefix("www.") {
            scheme = "www."
        } else {
            scheme = nil
        }
        guard let scheme else { return OutgoingBodies.escape(word) }

        var trail = ""
        while let last = core.last, linkTrailing.contains(last) {
            trail = String(last) + trail
            core = core.dropLast()
        }
        guard core.count > scheme.count else { return OutgoingBodies.escape(word) }

        let target = String(core)
        let href = target.lowercased().hasPrefix("www.") ? "http://" + target : target
        return OutgoingBodies.escape(lead)
            + "<a href=\"\(OutgoingBodies.escape(href))\">\(OutgoingBodies.escape(target))</a>"
            + OutgoingBodies.escape(trail)
    }
}
