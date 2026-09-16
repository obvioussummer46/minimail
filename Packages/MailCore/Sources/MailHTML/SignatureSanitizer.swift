import Foundation
import MailCore
import SwiftSoup

/// Sanitizes an HTML signature the owner authored: the same allowlist as `Sanitizer`, but `http`/`https`/`data`
/// image sources are kept verbatim (no placeholders, no `data-src`, no tracking-pixel test).
public enum SignatureSanitizer {
    public static func sanitize(_ html: String) throws -> String {
        let bytes = html.utf8.count
        guard bytes <= Sanitizer.maxInputBytes else { throw SanitizerError.tooLarge(bytes: bytes) }

        // See Sanitizer.sanitize: leaving prettyPrint at its default keeps attr mutations visible in body().html().
        let doc = try SwiftSoup.parseBodyFragment(html, "")

        for el in try doc.select("[background]") { try el.removeAttr("background") }
        for img in try doc.select("img") {
            let src = (try img.attr("src")).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = src.lowercased()
            let keep = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:image/")
            if !keep { try img.removeAttr("src") }
            for a in ["srcset", "sizes", "loading"] { try img.removeAttr(a) }
        }

        let fragment = try Sanitizer.compactBodyHTML(doc)
        guard let cleaned = try SwiftSoup.clean(fragment, "", signatureWhitelist(), Sanitizer.outputSettings()) else {
            throw SanitizerError.cleanFailed
        }
        return Sanitizer.normalizeVoidTags(Sanitizer.scopeStyles(cleaned, scope: nil))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` when the HTML contains an `<img>` whose `src` starts with `data:` (case-insensitive).
    public static func hasDataImages(_ html: String) -> Bool {
        if let doc = try? SwiftSoup.parseBodyFragment(html, ""), let imgs = try? doc.select("img") {
            for img in imgs where ((try? img.attr("src")) ?? "").lowercased().hasPrefix("data:") {
                return true
            }
        }
        let lower = html.lowercased()
        return lower.contains("src=\"data:") || lower.contains("src='data:")
    }

    /// `Sanitizer.whitelist()` with `img[src]` protocols `http`/`https`/`data` kept and without `img[data-src]`.
    public static func signatureWhitelist() throws -> Whitelist {
        let w = try Sanitizer.whitelist()
        _ = try w.addProtocols("img", "src", "http", "https", "data")
        _ = try w.removeAttributes("img", "data-src")
        return w
    }
}
