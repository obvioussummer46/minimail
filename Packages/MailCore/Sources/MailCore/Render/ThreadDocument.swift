import Foundation

/// One attachment chip in a rendered message section. DEVIATION D1: a named struct (not the architecture's tuple)
/// so `ThreadDocumentMessage` can synthesize `Equatable`/`Sendable`.
public struct ThreadDocumentAttachment: Sendable, Equatable {
    public var partId: String
    public var filename: String
    public var sizeLabel: String
    public init(partId: String, filename: String, sizeLabel: String) {
        self.partId = partId
        self.filename = filename
        self.sizeLabel = sizeLabel
    }
}

/// One message section of a thread document.
public struct ThreadDocumentMessage: Sendable, Equatable {
    public var id: String
    public var fromName: String
    public var fromAddr: String
    public var toLine: String
    public var ccLine: String?
    public var dateLabel: String
    public var dateFull: String
    public var snippet: String
    public var isUnread: Bool
    public var expanded: Bool
    public var bodyHTML: String?
    public var bodyState: Int
    public var darkStrategy: String
    public var hasRemoteImages: Bool
    public var imagesAllowed: Bool
    public var attachments: [ThreadDocumentAttachment]
    public init(
        id: String, fromName: String, fromAddr: String, toLine: String, ccLine: String?, dateLabel: String,
        dateFull: String, snippet: String, isUnread: Bool, expanded: Bool, bodyHTML: String?, bodyState: Int,
        darkStrategy: String, hasRemoteImages: Bool, imagesAllowed: Bool, attachments: [ThreadDocumentAttachment]
    ) {
        self.id = id
        self.fromName = fromName
        self.fromAddr = fromAddr
        self.toLine = toLine
        self.ccLine = ccLine
        self.dateLabel = dateLabel
        self.dateFull = dateFull
        self.snippet = snippet
        self.isUnread = isUnread
        self.expanded = expanded
        self.bodyHTML = bodyHTML
        self.bodyState = bodyState
        self.darkStrategy = darkStrategy
        self.hasRemoteImages = hasRemoteImages
        self.imagesAllowed = imagesAllowed
        self.attachments = attachments
    }
}

/// One rendered message section, paired with the id it belongs to. A named type rather than a tuple so callers
/// can key-path over it and compare sections for equality.
public struct RenderedSection: Sendable, Equatable {
    public var id: String
    public var html: String
    public init(id: String, html: String) {
        self.id = id
        self.html = html
    }
}

/// Pure string builder for one thread's self-contained HTML document (architecture §9.2). Never throws.
public enum ThreadDocument {
    public static let maxBodyBytes = 1_500_000
    public static let maxDocumentBytes = 6_000_000
    public static let placeholderGIF =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    private static let skeletonLoading = #"<span class="mm-skeleton">Loading…</span>"#
    private static let skeletonRetry =
        ##"<span class="mm-skeleton">Couldn't load this message · <a data-action="retry" href="#">Retry</a></span>"##
    private static let skeletonTap = #"<span class="mm-skeleton">Tap to load this message</span>"#
    private static let imagesRow =
        ##"<div class="mm-images"><a data-action="images" href="#">Load images</a></div>"##
    private static let paperclip =
        #"<svg class="mm-clip" width="12" height="12" viewBox="0 0 24 24" aria-hidden="true"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>"#

    public static func csp(imagesAllowed: Bool) -> String {
        let img = imagesAllowed ? "img-src data: minimail-cid: https:" : "img-src data: minimail-cid:"
        return "default-src 'none'; \(img); style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    }

    private static func vars(_ t: ThemeCSSTokens) -> String {
        "--mm-bg:\(t.background);--mm-surface:\(t.surface);--mm-text:\(t.text);--mm-secondary:\(t.secondaryText)"
            + ";--mm-accent:\(t.accent);--mm-sep:\(t.separator);--mm-link:\(t.link);--mm-card:\(t.cardBackground)"
    }

    public static func css(light: ThemeCSSTokens, dark: ThemeCSSTokens) -> String {
        [
            ":root{color-scheme:light dark;\(vars(light))}",
            "@media (prefers-color-scheme:dark){:root{\(vars(dark))}}",
            "html[data-theme=dark]{\(vars(dark))}",
            "html[data-theme=light]{\(vars(light))}",
            "html{-webkit-text-size-adjust:100%}",
            #"body{margin:0;background:transparent;color:var(--mm-text);font:-apple-system-body;font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;overflow-wrap:break-word;-webkit-touch-callout:none}"#,
            "h1.mm-subject{font:600 22px/1.2 -apple-system;margin:12px 16px 4px}",
            ".mm-msg{border-top:1px solid var(--mm-sep)}",
            ".mm-hdr{padding:10px 16px;display:flex;gap:8px;align-items:baseline}",
            ".mm-from{font-weight:600;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}",
            #".mm-msg.mm-unread .mm-from::before{content:"";display:inline-block;width:8px;height:8px;border-radius:4px;background:var(--mm-accent);margin-right:6px}"#,
            ".mm-date{color:var(--mm-secondary);font-size:13px;white-space:nowrap}",
            ".mm-to{color:var(--mm-secondary);font-size:13px;padding:0 16px 8px}",
            ".mm-body{padding:8px 16px 16px}",
            ".mm-collapsed .mm-body,.mm-collapsed .mm-to,.mm-collapsed .mm-att,.mm-collapsed .mm-images{display:none}",
            ".mm-snippet{display:none}",
            ".mm-collapsed .mm-snippet{display:block;color:var(--mm-secondary);padding:0 16px 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
            ".mm-att{display:flex;gap:8px;padding:0 16px 12px;flex-wrap:wrap}",
            ".mm-att a{border:1px solid var(--mm-sep);border-radius:8px;padding:6px 10px;color:var(--mm-accent);text-decoration:none;font-size:13px}",
            ".mm-clip{vertical-align:-1px}",
            ".mm-images{margin:0 16px 8px;font-size:13px}",
            ".mm-images a{color:var(--mm-accent)}",
            ".mm-skeleton{color:var(--mm-secondary);font-style:italic}",
            ".mm-body a{color:var(--mm-link)}",
            "img{max-width:100% !important;height:auto}",
            "table{max-width:100% !important}",
            "pre{white-space:pre-wrap}",
            "blockquote[type=cite]{margin:0 0 0 .8ex;border-left:2px solid var(--mm-sep);padding-left:1ex}",
            ".mm-remote{min-width:1px;min-height:1px}",
            ".mm-plaintext{white-space:pre-wrap}",
            #"@media (prefers-color-scheme:dark){html:not([data-theme=light]) .mm-plain .mm-body{color:#E5E5EA}html:not([data-theme=light]) .mm-plain .mm-body a{color:var(--mm-link)}html:not([data-theme=light]) .mm-plain .mm-body [style*="color"]{color:inherit !important}html:not([data-theme=light]) .mm-plain .mm-body font[color]{color:inherit !important}html:not([data-theme=light]) .mm-plain .mm-body blockquote[type=cite]{border-left-color:var(--mm-sep)}html:not([data-theme=light]) .mm-card .mm-body{background:var(--mm-card);color:#000;color-scheme:light;border-radius:12px;margin:0 12px 12px;padding:12px;overflow:hidden}}"#,
            #"html[data-theme=dark] .mm-plain .mm-body{color:#E5E5EA}html[data-theme=dark] .mm-plain .mm-body a{color:var(--mm-link)}html[data-theme=dark] .mm-plain .mm-body [style*="color"]{color:inherit !important}html[data-theme=dark] .mm-plain .mm-body font[color]{color:inherit !important}html[data-theme=dark] .mm-plain .mm-body blockquote[type=cite]{border-left-color:var(--mm-sep)}html[data-theme=dark] .mm-card .mm-body{background:var(--mm-card);color:#000;color-scheme:light;border-radius:12px;margin:0 12px 12px;padding:12px;overflow:hidden}"#,
        ].joined(separator: "\n")
    }

    private static func head(light: ThemeCSSTokens, dark: ThemeCSSTokens, forcedScheme: String?, imagesAllowed: Bool)
        -> String
    {
        let attr =
            forcedScheme == "dark" ? " data-theme=\"dark\"" : forcedScheme == "light" ? " data-theme=\"light\"" : ""
        return "<!doctype html><html\(attr)><head>\n"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp(imagesAllowed: imagesAllowed))\">\n"
            + "<meta charset=\"utf-8\">\n"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n"
            + "<meta name=\"color-scheme\" content=\"light dark\">\n"
            + "<style>\(css(light: light, dark: dark))</style></head><body>\n"
    }

    public static func render(
        subject: String, messages: [ThreadDocumentMessage], light: ThemeCSSTokens, dark: ThemeCSSTokens,
        forcedScheme: String?, imagesAllowed: Bool
    ) -> String {
        render(
            subject: subject, sections: sections(messages: messages).map(\.html), light: light, dark: dark,
            forcedScheme: forcedScheme, imagesAllowed: imagesAllowed)
    }

    /// Same document from sections already built by `sections(messages:)`, so a caller that needs both the
    /// document and the per-message HTML (10, to patch only what changed) builds each section once.
    public static func render(
        subject: String, sections: [String], light: ThemeCSSTokens, dark: ThemeCSSTokens,
        forcedScheme: String?, imagesAllowed: Bool
    ) -> String {
        let heading = "<h1 class=\"mm-subject\">\(esc(subject.isEmpty ? "(No subject)" : subject))</h1>\n"
        return head(light: light, dark: dark, forcedScheme: forcedScheme, imagesAllowed: imagesAllowed)
            + heading + sections.joined() + "</body></html>"
    }

    /// Every message's `<section>` in document order, under the one `strippedIds` decision the whole document
    /// shares. The unit both `render` and `patchSectionScript` work in.
    public static func sections(messages: [ThreadDocumentMessage]) -> [RenderedSection] {
        let stripped = strippedIds(messages: messages)
        return messages.map {
            RenderedSection(id: $0.id, html: section($0, stripped: stripped.contains($0.id)))
        }
    }

    public static func empty(light: ThemeCSSTokens, dark: ThemeCSSTokens) -> String {
        head(light: light, dark: dark, forcedScheme: nil, imagesAllowed: false) + "</body></html>"
    }

    private static func section(_ m: ThreadDocumentMessage, stripped: Bool) -> String {
        let strategy = ["plain", "card", "native"].contains(m.darkStrategy) ? m.darkStrategy : "plain"
        let classes =
            "mm-msg" + (m.isUnread ? " mm-unread" : "") + (m.expanded ? " mm-expanded" : " mm-collapsed")
            + " mm-\(strategy)" + (stripped ? " mm-stripped" : "")

        let body: String
        if stripped {
            body = skeletonTap
        } else if m.bodyState == 2 {
            body = skeletonRetry
        } else if m.bodyState == 0 || m.bodyHTML == nil {
            body = skeletonLoading
        } else {
            body = cappedBody(m.imagesAllowed ? restoringRemoteImages(m.bodyHTML!) : m.bodyHTML!)
        }

        let imagesPart = (m.hasRemoteImages && !m.imagesAllowed && !stripped) ? imagesRow + "\n" : ""
        let attPart =
            m.attachments.isEmpty
            ? ""
            : "<div class=\"mm-att\">" + m.attachments.map(attRow).joined() + "</div>\n"
        let ccPart = m.ccLine.map { "<br>Cc: " + esc($0) } ?? ""

        return "<section class=\"\(classes)\" data-id=\"\(esc(m.id))\">\n"
            + "<div class=\"mm-hdr\" data-action=\"toggle\"><span class=\"mm-from\" title=\"\(esc(m.fromAddr))\">"
            + "\(esc(m.fromName.isEmpty ? m.fromAddr : m.fromName))</span>"
            + "<span class=\"mm-date\" title=\"\(esc(m.dateFull))\">\(esc(m.dateLabel))</span></div>\n"
            + "<div class=\"mm-snippet\">\(esc(m.snippet))</div>\n"
            + "<div class=\"mm-to\">To: \(esc(m.toLine))\(ccPart)</div>\n"
            + imagesPart
            + "<div class=\"mm-body\">\(body)</div>\n"
            + attPart
            + "</section>\n"
    }

    private static func attRow(_ a: ThreadDocumentAttachment) -> String {
        "<a data-action=\"att\" data-part=\"\(esc(a.partId))\" href=\"#\">\(paperclip) \(esc(a.filename)) · \(esc(a.sizeLabel))</a>"
    }

    private static func cappedBody(_ html: String) -> String {
        guard html.utf8.count > maxBodyBytes else { return html }
        let bytes = Array(html.utf8.prefix(maxBodyBytes))
        var end = bytes.count
        while end > 0 {
            if let s = String(bytes: bytes[0..<end], encoding: .utf8) {
                return s + #"<p class="mm-skeleton">Message truncated</p>"#
            }
            end -= 1
        }
        return #"<p class="mm-skeleton">Message truncated</p>"#
    }

    /// Body with `data-src` restored to `src`. Anchored to the exact placeholder GIF so only neutralised remote
    /// images (canonical attribute order from `Sanitizer`) are restored.
    public static func restoringRemoteImages(_ bodyHTML: String) -> String {
        let pattern = "data-src=\"([^\"]*)\" src=\"" + NSRegularExpression.escapedPattern(for: placeholderGIF) + "\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return bodyHTML }
        let range = NSRange(bodyHTML.startIndex..<bodyHTML.endIndex, in: bodyHTML)
        return regex.stringByReplacingMatches(in: bodyHTML, options: [], range: range, withTemplate: "src=\"$1\"")
    }

    public static func strippedIds(messages: [ThreadDocumentMessage]) -> Set<String> {
        let sizes = messages.map { m -> Int in
            (m.bodyState == 1 && m.bodyHTML != nil) ? min(m.bodyHTML!.utf8.count, maxBodyBytes + 40) : 0
        }
        var total = sizes.reduce(0, +)
        var stripped = Set<String>()
        for (i, m) in messages.enumerated() where total > maxDocumentBytes {
            if !m.expanded && sizes[i] > 0 {
                stripped.insert(m.id)
                total -= sizes[i]
            }
        }
        return stripped
    }

    public static func toggleScript(messageId: String) -> String {
        let id = String(messageId.unicodeScalars.filter { isIdentifierScalar($0) })
        return
            "(function(){var s=document.querySelector('section.mm-msg[data-id=\"\(id)\"]');if(!s){return false;}s.classList.toggle('mm-collapsed');s.classList.toggle('mm-expanded');return true;})();"
    }

    /// Replaces one message's whole `<section>` in the loaded document, so a body that lands after the screen
    /// is already up paints in place instead of costing a `loadHTMLString` (which resets the scroll position).
    /// The section — not just its body — is the unit: the same fetch that produces the body also decides the
    /// dark-strategy class, the attachment chips and the "Load images" row.
    ///
    /// Answers `false` when the section is not in the DOM, which tells the caller the loaded document is stale
    /// and a real reload is needed. Head-level changes (theme, forced scheme, the CSP that follows
    /// `imagesAllowed`) are NOT patchable and must never come through here.
    public static func patchSectionScript(messageId: String, sectionHTML: String) -> String {
        let id = String(messageId.unicodeScalars.filter { isIdentifierScalar($0) })
        return "(function(){var s=document.querySelector('section.mm-msg[data-id=\"\(id)\"]');"
            + "if(!s){return false;}s.outerHTML=\(jsStringLiteral(sectionHTML));return true;})();"
    }

    /// `s` as a double-quoted JavaScript string literal. Escapes the two characters that would end the literal
    /// or start an escape, every C0 control character and DEL, and U+2028/U+2029 — legal inside a string only
    /// since ES2019, and the classic way a message body breaks an injected script.
    public static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 16)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
        default: return false
        }
    }

    private static func esc(_ s: String) -> String { OutgoingBodies.escape(s) }
}
