import Foundation
import MailCore
import SwiftSoup

/// Turns a sanitized `message_body.bodyHtml` fragment back into quotable outgoing HTML (architecture §7.2):
/// restores neutralised remote images, drops `cid:` images, and removes the renderer's `mm-*` classes.
public enum QuoteExtractor {
    public static func quotable(_ sanitizedHTML: String) -> String {
        do {
            // Default prettyPrint (see Sanitizer.sanitize) so attr/class mutations survive serialisation.
            let doc = try SwiftSoup.parseBodyFragment(sanitizedHTML, "")

            for img in try doc.select("img") {
                if img.hasAttr("data-src") {
                    let dataSrc = try img.attr("data-src")
                    try img.attr("src", dataSrc)
                    try img.removeAttr("data-src")
                } else if (try img.attr("src")).lowercased().hasPrefix("minimail-cid:") {
                    try img.remove()
                }
            }

            for el in try doc.select("[class]") {
                let tokens = (try el.attr("class")).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                let kept = tokens.filter { !$0.hasPrefix("mm-") }
                if kept.isEmpty {
                    try el.removeAttr("class")
                } else {
                    try el.attr("class", kept.joined(separator: " "))
                }
            }

            let html = try Sanitizer.compactBodyHTML(doc)
            return unscope(Sanitizer.normalizeVoidTags(html)).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return unscope(sanitizedHTML)
        }
    }

    /// Undoes `StyleScoper`: the per-message prefix `Sanitizer` put on every `<style>` selector is removed, and
    /// a rule that collapsed to the bare scope (`body{…}`) becomes a `body` rule again.
    static func unscope(_ html: String) -> String {
        guard html.contains(".mm-msg[data-id=") else { return html }
        var out = html
        for (regex, template) in [(scopePrefixRegex, ""), (bareScopeRegex, "body")] {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: template)
        }
        return out
    }

    private static let scopePrefixRegex = compile(#"\.mm-msg\[data-id="[^"]*"\] \.mm-body "#)
    private static let bareScopeRegex = compile(#"\.mm-msg\[data-id="[^"]*"\] \.mm-body"#)

    private static func compile(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            preconditionFailure("QuoteExtractor pattern failed to compile: \(pattern)")
        }
        return regex
    }
}
