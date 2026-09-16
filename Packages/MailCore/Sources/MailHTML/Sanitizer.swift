import Foundation
import MailCore
import SwiftSoup

/// Thrown by `Sanitizer.sanitize` and `SignatureSanitizer.sanitize`. SwiftSoup's own errors propagate unchanged.
public enum SanitizerError: Error, Equatable, Sendable {
    /// `html.utf8.count > Sanitizer.maxInputBytes`. The caller (07) falls back to `fromPlainText`.
    case tooLarge(bytes: Int)
    /// `SwiftSoup.clean` returned nil (no body). The caller treats it like any SwiftSoup error.
    case cleanFailed
}

/// The allowlist sanitizer pipeline of architecture §9.1. Pure; no I/O; no logging; safe from any actor.
public enum Sanitizer {
    /// Bump when the pipeline output changes; 07 re-fetches bodies whose `sanitizerVersion < version` on open.
    public static let version: Int = 2
    /// 2 MiB; larger input throws `.tooLarge` before parsing.
    public static let maxInputBytes = 2_097_152
    /// 1×1 transparent GIF data URI; the single definition lives in `MailCore`.
    public static let placeholderGIF: String = ThreadDocument.placeholderGIF

    /// `/`, `%` and `@` inside a Content-ID are always encoded so the handler's `url.path` decodes to one segment.
    /// DEVIATION: the spec's formula subtracts only `/%`, but `urlPathAllowed` keeps `@`, and the tests expect an
    /// `@` in a Content-ID to encode as `%40` (`testCidRewriteAndReferencedSet`); `@` is subtracted too.
    private static let cidPathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%@"))

    public static func sanitize(html: String, messageId: String) throws -> SanitizedBody {
        let bytes = html.utf8.count
        guard bytes <= maxInputBytes else { throw SanitizerError.tooLarge(bytes: bytes) }

        // NOTE: do not set `prettyPrint(false)` on this working doc. In this SwiftSoup version, serialising a doc
        // with `prettyPrint == false` patches the original source buffer per dirty node, and `attr`/`removeAttr`
        // mutations are not marked dirty — so those edits would be lost from `body().html()`. The default
        // (prettyPrint true) re-serialises the full tree. `clean()` below still emits compact output.
        let doc = try SwiftSoup.parseBodyFragment(html, "")

        var hasRemote = false
        var referenced = Set<String>()

        // The renderer's `mm-*` classes are its own; a message must not be able to borrow them (a body dressed
        // up as a header or an attachment chip). `mm-remote` is re-added below where it belongs.
        for el in try doc.select("[class]") {
            let kept = (try el.attr("class"))
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .filter { !$0.lowercased().hasPrefix("mm-") }
            if kept.isEmpty {
                try el.removeAttr("class")
            } else {
                try el.attr("class", kept.joined(separator: " "))
            }
        }

        let backgroundEls = try doc.select("[background]")
        let sawBackground = !backgroundEls.isEmpty()
        for el in backgroundEls { try el.removeAttr("background") }

        for img in try doc.select("img") {
            let src = (try img.attr("src")).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = src.lowercased()
            if TrackingPixel.isTracking(img, src: src) {
                try img.remove()
                continue
            }
            if lower.hasPrefix("cid:") {
                var raw = String(src.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                raw = raw.removingPercentEncoding ?? raw
                let cid = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if cid.isEmpty {
                    try img.removeAttr("src")
                } else {
                    referenced.insert(cid)
                    let encoded = cid.addingPercentEncoding(withAllowedCharacters: cidPathAllowed) ?? cid
                    try img.removeAttr("src")
                    try img.attr("src", "minimail-cid://\(messageId)/\(encoded)")
                }
            } else if lower.hasPrefix("data:image/") {
                // keep verbatim
            } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                try img.removeAttr("data-src")
                try img.removeAttr("src")
                try img.attr("data-src", src)
                try img.attr("src", placeholderGIF)
                try img.addClass("mm-remote")
                hasRemote = true
            } else {
                try img.removeAttr("src")
            }
            for a in ["srcset", "sizes", "loading"] { try img.removeAttr(a) }
        }

        let strategy = DarkStrategyClassifier.classify(doc, sawBackgroundAttribute: sawBackground)
        let fragment = try compactBodyHTML(doc)
        guard let cleaned = try SwiftSoup.clean(fragment, "", whitelist(), outputSettings()) else {
            throw SanitizerError.cleanFailed
        }
        let scoped = scopeStyles(cleaned, scope: StyleScoper.scope(forMessageId: messageId))
        let scrubbed = normalizeVoidTags(scoped)
        return SanitizedBody(
            html: scrubbed.trimmingCharacters(in: .whitespacesAndNewlines),
            hasRemoteImages: hasRemote, darkStrategy: strategy, referencedContentIDs: referenced)
    }

    public static func fromPlainText(_ text: String) -> SanitizedBody {
        SanitizedBody(
            html: PlainTextHTML.convert(text), hasRemoteImages: false, darkStrategy: .plain,
            referencedContentIDs: [])
    }

    /// The allowed inline-CSS property names (shared with `SignatureSanitizer`).
    public static let allowedCSSProperties: [String] = [
        "color", "background", "background-color", "font", "font-family", "font-size", "font-weight", "font-style",
        "text-decoration", "text-align", "line-height", "letter-spacing", "vertical-align", "white-space",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
        "border", "border-top", "border-right", "border-bottom", "border-left", "border-collapse", "border-spacing",
        "border-radius", "border-color", "border-width", "border-style",
        "width", "min-width", "max-width", "height", "max-height", "display", "float", "clear", "overflow",
        "word-break", "word-wrap", "overflow-wrap", "table-layout",
        "list-style", "list-style-type", "text-transform", "text-indent", "direction", "unicode-bidi", "mso-hide",
    ]

    public static func whitelist() throws -> Whitelist {
        let w = try Whitelist.relaxed()
            .addTags("center", "font", "hr", "s", "del", "ins", "abbr", "address", "style", "wbr")
            .addAttributes(
                ":all", "style", "class", "dir", "lang", "align", "valign", "width", "height", "bgcolor", "border",
                "cellpadding", "cellspacing"
            )
            .addAttributes("img", "data-src")
            .addAttributes("font", "face", "size", "color")
            .addAttributes("a", "href", "title")
            .addAttributes("blockquote", "type")
            .addProtocols("a", "href", "http", "https", "mailto", "tel")
            .removeProtocols("a", "href", "ftp")
            .addProtocols("img", "src", "data", "minimail-cid")
            .removeProtocols("img", "src", "http", "https")
            .preserveRelativeLinks(true)
        for property in allowedCSSProperties {
            _ = try w.addCSSProperties(":all", property)
        }
        _ = try w.addEnforcedAttribute("a", "target", "_self")
        return w
    }

    /// Scrubs CSS where it lives — `<style>` blocks and `style` attributes — and, given a `scope`, confines every
    /// `<style>` rule to it (`StyleScoper`). Prose is never touched, so a sentence containing "url(" or
    /// "javascript:" survives intact. Runs on the cleaned fragment, whose attribute values are entity-escaped
    /// and double-quoted.
    static func scopeStyles(_ html: String, scope: String?) -> String {
        var out = replacingGroup(styleBlockRegex, in: html) { css in
            let scrubbed = StyleScrubber.scrub(css)
            return scope.map { StyleScoper.scope(scrubbed, scope: $0) } ?? scrubbed
        }
        out = replacingGroup(styleAttributeRegex, in: out) { StyleScrubber.scrub($0) }
        return out
    }

    private static let styleBlockRegex: NSRegularExpression = compile(#"(?is)<style\b[^>]*>(.*?)</style>"#)
    private static let styleAttributeRegex: NSRegularExpression = compile(#"(?i)\sstyle="([^"]*)""#)

    private static func compile(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            preconditionFailure("Sanitizer pattern failed to compile: \(pattern)")
        }
        return regex
    }

    /// Replaces capture group 1 of every match with `transform(group)`; everything else is copied verbatim.
    private static func replacingGroup(
        _ regex: NSRegularExpression, in html: String, _ transform: (String) -> String
    ) -> String {
        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for match in matches {
            let group = match.range(at: 1)
            guard group.location != NSNotFound else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: group.location - cursor))
            out += transform(ns.substring(with: group))
            cursor = group.location + group.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// `prettyPrint(pretty: false)` so no whitespace is inserted.
    static func outputSettings() -> OutputSettings {
        OutputSettings().prettyPrint(pretty: false)
    }

    /// SwiftSoup serialises void tags XHTML-style (`<img … />`) even in HTML syntax; the app emits HTML5 (`<img …>`).
    static func normalizeVoidTags(_ html: String) -> String {
        html.replacingOccurrences(of: " />", with: ">")
    }

    /// Serialises a mutated document's body compactly. A parsed doc tracks source ranges and, with
    /// `prettyPrint == false`, serialises from the original source buffer patched per dirty node — but `attr`/
    /// `removeAttr` do not mark nodes dirty, so those edits are lost. A `copy()` has no source buffer, so it
    /// serialises the full (mutated) tree without inserting the pretty-print whitespace the default would add.
    static func compactBodyHTML(_ doc: Document) throws -> String {
        guard let clone = doc.copy() as? Document else { return try doc.body()?.html() ?? "" }
        clone.outputSettings().prettyPrint(pretty: false)
        return try clone.body()?.html() ?? ""
    }
}
