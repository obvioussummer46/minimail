import XCTest

@testable import MailCore

final class ThreadDocumentTests: XCTestCase {
    private let lightTokens = ThemeCSSTokens(
        background: "#ffffff", surface: "#f2f2f7", text: "#000000", secondaryText: "#3c3c43", accent: "#007aff",
        separator: "#c6c6c8", link: "#007aff", cardBackground: "#ffffff")
    private let darkTokens = ThemeCSSTokens(
        background: "#000000", surface: "#1c1c1e", text: "#ffffff", secondaryText: "#ebebf5", accent: "#0a84ff",
        separator: "#38383a", link: "#0a84ff", cardBackground: "#ffffff")

    private func msg(
        _ id: String, expanded: Bool = true, body: String? = "hi", state: Int = 1, remote: Bool = false,
        allowed: Bool = false, unread: Bool = false, dark: String = "plain", fromName: String = "Alice",
        toLine: String = "Bob <bob@example.com>", ccLine: String? = nil, snippet: String = "hi",
        attachments: [ThreadDocumentAttachment] = []
    ) -> ThreadDocumentMessage {
        ThreadDocumentMessage(
            id: id, fromName: fromName, fromAddr: "alice@example.com", toLine: toLine, ccLine: ccLine,
            dateLabel: "14:32", dateFull: "11 Sep 2026 14:32", snippet: snippet, isUnread: unread, expanded: expanded,
            bodyHTML: body, bodyState: state, darkStrategy: dark, hasRemoteImages: remote, imagesAllowed: allowed,
            attachments: attachments)
    }

    private func render(
        _ subject: String, _ messages: [ThreadDocumentMessage], forced: String? = nil, images: Bool = false
    )
        -> String
    {
        ThreadDocument.render(
            subject: subject, messages: messages, light: lightTokens, dark: darkTokens, forcedScheme: forced,
            imagesAllowed: images)
    }

    func testCSPImagesOff() {
        let html = render("S", [msg("a")])
        let csp =
            "default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
        XCTAssertTrue(html.contains("content=\"\(csp)\""), html)
        XCTAssertEqual(ThreadDocument.csp(imagesAllowed: false), csp)
    }

    func testCSPImagesOn() {
        let html = render("S", [msg("a")], images: true)
        XCTAssertTrue(html.contains("img-src data: minimail-cid: https:;"), html)
    }

    func testForcedSchemeAttribute() {
        XCTAssertTrue(
            render("S", [msg("a")], forced: "dark").hasPrefix("<!doctype html><html data-theme=\"dark\"><head>"))
        XCTAssertTrue(
            render("S", [msg("a")], forced: "light").hasPrefix("<!doctype html><html data-theme=\"light\"><head>"))
        XCTAssertTrue(render("S", [msg("a")], forced: nil).hasPrefix("<!doctype html><html><head>"))
        XCTAssertTrue(render("S", [msg("a")], forced: "blue").hasPrefix("<!doctype html><html><head>"))
    }

    func testCSSVariablesFromTokens() {
        let html = render("S", [msg("a")])
        XCTAssertTrue(html.contains(":root{color-scheme:light dark;--mm-bg:#ffffff;"))
        XCTAssertTrue(html.contains("@media (prefers-color-scheme:dark){:root{--mm-bg:#000000;"))
        XCTAssertTrue(html.contains("html[data-theme=dark]{--mm-bg:#000000;"))
        XCTAssertTrue(html.contains("html[data-theme=light]{--mm-bg:#ffffff;"))
    }

    func testSectionClasses() {
        let html = render(
            "S",
            [
                msg("a", expanded: true, unread: true, dark: "card"),
                msg("b", expanded: false, unread: false, dark: "native"),
                msg("c", expanded: false, unread: false, dark: "weird"),
            ])
        XCTAssertTrue(html.contains("<section class=\"mm-msg mm-unread mm-expanded mm-card\" data-id=\"a\">"))
        XCTAssertTrue(html.contains("<section class=\"mm-msg mm-collapsed mm-native\" data-id=\"b\">"))
        XCTAssertTrue(html.contains("<section class=\"mm-msg mm-collapsed mm-plain\" data-id=\"c\">"))
    }

    func testHeaderFieldsEscaped() {
        let html = render(
            "<b>&\"x\"",
            [msg("a", fromName: "A<B", toLine: "\"Bob\" <bob@x>", snippet: "1<2")])
        XCTAssertTrue(html.contains("<h1 class=\"mm-subject\">&lt;b&gt;&amp;&quot;x&quot;</h1>"))
        XCTAssertTrue(html.contains(">A&lt;B</span>"))
        XCTAssertTrue(html.contains("To: &quot;Bob&quot; &lt;bob@x&gt;"))
        XCTAssertTrue(html.contains("<div class=\"mm-snippet\">1&lt;2</div>"))
    }

    func testEmptySubjectPlaceholder() {
        XCTAssertTrue(render("", [msg("a")]).contains("<h1 class=\"mm-subject\">(No subject)</h1>"))
    }

    func testCcLine() {
        XCTAssertTrue(render("S", [msg("a", ccLine: "c@x")]).contains("<br>Cc: c@x</div>"))
        XCTAssertFalse(render("S", [msg("a", ccLine: nil)]).contains("Cc:"))
    }

    func testBodyStates() {
        let html = render(
            "S",
            [
                msg("a", body: nil, state: 0),
                msg("b", body: "<p>B</p>", state: 1),
                msg("c", body: nil, state: 2),
                msg("d", body: nil, state: 1),
            ])
        XCTAssertTrue(html.contains("<div class=\"mm-body\"><span class=\"mm-skeleton\">Loading…</span></div>"))
        XCTAssertTrue(html.contains("<div class=\"mm-body\"><p>B</p></div>"))
        XCTAssertTrue(html.contains("Couldn't load this message · <a data-action=\"retry\" href=\"#\">Retry</a>"))
    }

    func testDataSrcRestoredOnlyForAllowedMessage() {
        let bodyHTML = "<img data-src=\"https://x/1.png\" src=\"\(ThreadDocument.placeholderGIF)\" class=\"mm-remote\">"
        let html = render(
            "S",
            [
                msg("a", body: bodyHTML, remote: true, allowed: true),
                msg("b", body: bodyHTML, remote: true, allowed: false),
            ], images: true)
        XCTAssertTrue(html.contains("<img src=\"https://x/1.png\" class=\"mm-remote\">"), html)
        XCTAssertTrue(html.contains("data-src=\"https://x/1.png\" src=\"\(ThreadDocument.placeholderGIF)\""))
        // Section b keeps the Load-images row; section a does not.
        XCTAssertEqual(html.components(separatedBy: "Load images").count - 1, 1)
    }

    func testLoadImagesRowOnlyWhenRemoteAndNotAllowed() {
        XCTAssertFalse(render("S", [msg("a", remote: false)]).contains("Load images"))
        XCTAssertFalse(render("S", [msg("a", remote: true, allowed: true)], images: true).contains("Load images"))
        let row = "<div class=\"mm-images\"><a data-action=\"images\" href=\"#\">Load images</a></div>"
        XCTAssertTrue(render("S", [msg("a", remote: true, allowed: false)]).contains(row))
    }

    func testAttachmentsRow() {
        let html = render(
            "S",
            [
                msg(
                    "a",
                    attachments: [
                        ThreadDocumentAttachment(partId: "1", filename: "a.pdf", sizeLabel: "12 KB"),
                        ThreadDocumentAttachment(partId: "2", filename: "b<c.png", sizeLabel: "3 KB"),
                    ])
            ])
        XCTAssertTrue(html.contains("<a data-action=\"att\" data-part=\"1\" href=\"#\">"))
        XCTAssertTrue(html.contains(" a.pdf · 12 KB</a>"))
        XCTAssertTrue(html.contains("data-part=\"2\" href=\"#\">"))
        XCTAssertTrue(html.contains("b&lt;c.png · 3 KB</a>"))
        XCTAssertFalse(render("S", [msg("a")]).contains("<div class=\"mm-att\">"))
    }

    func testPerBodyCap() {
        let body = "<p>" + String(repeating: "é", count: 800_000) + "</p>"
        let html = render("S", [msg("a", body: body)])
        XCTAssertTrue(html.contains("<p class=\"mm-skeleton\">Message truncated</p></div>"))
        XCTAssertLessThan(html.utf8.count, ThreadDocument.maxBodyBytes + 10_000)
        XCTAssertEqual(String(decoding: Array(html.utf8), as: UTF8.self), html)
    }

    func testDocumentCapStripsOldestCollapsed() {
        let big = String(repeating: "a", count: 1_400_000)
        let messages = (0..<6).map { i in
            msg("m\(i)", expanded: i >= 4, body: big, state: 1)
        }
        XCTAssertEqual(ThreadDocument.strippedIds(messages: messages), ["m0", "m1"])
        let html = render("S", messages)
        XCTAssertTrue(html.contains("<section class=\"mm-msg mm-collapsed mm-plain mm-stripped\" data-id=\"m0\">"))
        XCTAssertTrue(html.contains("Tap to load this message"))
        XCTAssertFalse(
            html.contains("<section class=\"mm-msg mm-expanded mm-plain mm-stripped\" data-id=\"m4\">"))
    }

    func testDocumentCapNeverStripsExpanded() {
        let big = String(repeating: "a", count: 1_400_000)
        let messages = (0..<6).map { msg("m\($0)", expanded: true, body: big, state: 1) }
        XCTAssertTrue(ThreadDocument.strippedIds(messages: messages).isEmpty)
    }

    func testToggleScript() {
        let expected =
            "(function(){var s=document.querySelector('section.mm-msg[data-id=\"18fx\"]');if(!s){return false;}s.classList.toggle('mm-collapsed');s.classList.toggle('mm-expanded');return true;})();"
        XCTAssertEqual(ThreadDocument.toggleScript(messageId: "18f\"x;"), expected)
    }

    func testSectionsMatchRenderedDocument() {
        let messages = [msg("a"), msg("b", expanded: false)]
        let built = ThreadDocument.sections(messages: messages)
        XCTAssertEqual(built.map(\.id), ["a", "b"])
        let assembled = ThreadDocument.render(
            subject: "S", sections: built.map(\.html), light: lightTokens, dark: darkTokens, forcedScheme: nil,
            imagesAllowed: false)
        XCTAssertEqual(assembled, render("S", messages))
    }

    func testSectionsSharesOneStrippingDecision() {
        let big = String(repeating: "a", count: 1_400_000)
        let messages = (0..<6).map { msg("m\($0)", expanded: $0 == 0, body: big, state: 1) }
        let built = ThreadDocument.sections(messages: messages)
        let stripped = ThreadDocument.strippedIds(messages: messages)
        XCTAssertFalse(stripped.isEmpty)
        for rendered in built {
            XCTAssertEqual(rendered.html.contains("mm-stripped"), stripped.contains(rendered.id), rendered.id)
        }
    }

    func testPatchSectionScriptCarriesSection() {
        let html = ThreadDocument.sections(messages: [msg("a")])[0].html
        let script = ThreadDocument.patchSectionScript(messageId: "a", sectionHTML: html)
        XCTAssertTrue(script.contains("section.mm-msg[data-id=\"a\"]"), script)
        XCTAssertTrue(script.contains("s.outerHTML="), script)
        XCTAssertTrue(script.contains("if(!s){return false;}"), script)
    }

    func testPatchSectionScriptFiltersMessageId() {
        let script = ThreadDocument.patchSectionScript(messageId: "18f\"x;", sectionHTML: "<i>x</i>")
        XCTAssertTrue(script.contains("section.mm-msg[data-id=\"18fx\"]"), script)
    }

    /// A body that closes the literal, starts an escape or carries a line terminator must not be able to end
    /// the injected statement.
    func testJSStringLiteralEscapesBreakingCharacters() {
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\r\nb"), "\"a\\r\\nb\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\u{2028}b"), "\"a\\u2028b\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\u{2029}b"), "\"a\\u2029b\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\u{0}b"), "\"a\\u0000b\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\u{1F}b"), "\"a\\u001Fb\"")
        XCTAssertEqual(ThreadDocument.jsStringLiteral("a\u{7F}b"), "\"a\\u007Fb\"")
    }

    func testJSStringLiteralKeepsOrdinaryText() {
        XCTAssertEqual(ThreadDocument.jsStringLiteral("<p>hé · 🙂</p>"), "\"<p>hé · 🙂</p>\"")
    }

    func testEmptyDocument() {
        let empty = ThreadDocument.empty(light: lightTokens, dark: darkTokens)
        let rendered = render("", [])
        let withoutH1 = rendered.replacingOccurrences(
            of: "<h1 class=\"mm-subject\">(No subject)</h1>\n", with: "")
        XCTAssertEqual(empty, withoutH1)
        XCTAssertTrue(empty.contains("</head><body>\n</body></html>"))
        XCTAssertFalse(empty.contains("<section"))
    }

    func testRestoringRemoteImagesIsAnchoredToPlaceholder() {
        let input = "<img data-src=\"https://a\" src=\"data:image/gif;base64,OTHER\">"
        XCTAssertEqual(ThreadDocument.restoringRemoteImages(input), input)
    }
}
