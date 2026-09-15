import XCTest

@testable import MailCore

final class ReplyAllTests: XCTestCase {

    private let me = SelfIdentity(
        primary: Mailbox(name: "Max Mustermann", addr: "max.mustermann@example.com"),
        allAddresses: ["m.mustermann@example.com"]
    )

    private func alice(_ name: String? = "Alice") -> Mailbox { Mailbox(name: name, addr: "alice@example.com") }
    private func bob() -> Mailbox { Mailbox(name: "Bob", addr: "bob@example.com") }
    private func carol() -> Mailbox { Mailbox(name: "Carol", addr: "carol@partner.example") }

    func testIdentityAlwaysContainsPrimary() {
        XCTAssertTrue(me.allAddresses.contains("max.mustermann@example.com"))
        XCTAssertTrue(me.allAddresses.contains("m.mustermann@example.com"))
    }

    func testSenderGoesToToAndMyselfIsRemoved() {
        let result = ReplyAll.recipients(
            from: alice(),
            replyTo: [],
            to: [me.primary, bob()],
            cc: [carol()],
            me: me
        )
        XCTAssertEqual(result.to.map(\.addr), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(result.cc.map(\.addr), ["carol@partner.example"])
    }

    func testReplyToWinsOverFrom() {
        let result = ReplyAll.recipients(
            from: alice(),
            replyTo: [carol()],
            to: [bob()],
            cc: [],
            me: me
        )
        XCTAssertEqual(result.to.map(\.addr), ["carol@partner.example", "bob@example.com"])
    }

    func testAliasIsRemovedToo() {
        let alias = Mailbox(name: nil, addr: "M.Mustermann@example.com")
        let result = ReplyAll.recipients(from: alice(), replyTo: [], to: [alias, bob()], cc: [], me: me)
        XCTAssertEqual(result.to.map(\.addr), ["alice@example.com", "bob@example.com"])
    }

    func testToWinsOverCcForDuplicates() {
        let result = ReplyAll.recipients(from: alice(), replyTo: [], to: [bob()], cc: [bob(), carol()], me: me)
        XCTAssertEqual(result.to.map(\.addr), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(result.cc.map(\.addr), ["carol@partner.example"])
    }

    func testFirstSeenDisplayNameWins() {
        let named = Mailbox(name: "Alice Müller", addr: "alice@example.com")
        let bare = Mailbox(name: nil, addr: "ALICE@example.com")
        let result = ReplyAll.recipients(from: named, replyTo: [], to: [bare], cc: [], me: me)
        XCTAssertEqual(result.to.count, 1)
        XCTAssertEqual(result.to.first?.name, "Alice Müller")
    }

    func testSelfReplyKeepsOriginalRecipients() {
        let result = ReplyAll.recipients(
            from: me.primary,
            replyTo: [],
            to: [alice(), bob()],
            cc: [carol()],
            me: me
        )
        XCTAssertEqual(result.to.map(\.addr), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(result.cc.map(\.addr), ["carol@partner.example"])
    }

    func testCcPromotedWhenToWouldBeEmpty() {
        let result = ReplyAll.recipients(from: me.primary, replyTo: [], to: [me.primary], cc: [bob()], me: me)
        XCTAssertEqual(result.to.map(\.addr), ["bob@example.com"])
        XCTAssertTrue(result.cc.isEmpty)
    }

    func testNoteToSelfNeverHasEmptyTo() {
        let result = ReplyAll.recipients(from: me.primary, replyTo: [], to: [me.primary], cc: [], me: me)
        XCTAssertEqual(result.to.map(\.addr), ["max.mustermann@example.com"])
        XCTAssertTrue(result.cc.isEmpty)
    }

    func testMissingSenderAndEmptyEverything() {
        let result = ReplyAll.recipients(from: nil, replyTo: [], to: [], cc: [], me: me)
        XCTAssertTrue(result.to.isEmpty)
        XCTAssertTrue(result.cc.isEmpty)
    }
}

final class SubjectPrefixTests: XCTestCase {

    func testReply() {
        XCTAssertEqual(SubjectPrefix.reply("Angebot"), "Re: Angebot")
        XCTAssertEqual(SubjectPrefix.reply("  Angebot  "), "Re: Angebot")
        XCTAssertEqual(SubjectPrefix.reply("Re: Angebot"), "Re: Angebot")
        XCTAssertEqual(SubjectPrefix.reply("re: Angebot"), "re: Angebot")
        XCTAssertEqual(SubjectPrefix.reply(""), "Re: ")
    }

    func testForward() {
        XCTAssertEqual(SubjectPrefix.forward("Angebot"), "Fwd: Angebot")
        XCTAssertEqual(SubjectPrefix.forward("Fwd: Angebot"), "Fwd: Angebot")
        XCTAssertEqual(SubjectPrefix.forward("FW: x"), "Fwd: FW: x")
    }

    func testStripForDisplay() {
        XCTAssertEqual(SubjectPrefix.stripForDisplay("Re: Fwd: AW: Angebot"), "Angebot")
        XCTAssertEqual(SubjectPrefix.stripForDisplay("Re[2]: x"), "x")
        XCTAssertEqual(SubjectPrefix.stripForDisplay("Rewards: x"), "Rewards: x")
        XCTAssertEqual(SubjectPrefix.stripForDisplay("Re: "), "")
        XCTAssertEqual(SubjectPrefix.stripForDisplay("Fwd:Angebot"), "Angebot")
        XCTAssertEqual(SubjectPrefix.stripForDisplay("Angebot"), "Angebot")
    }
}

final class OutgoingBodiesTests: XCTestCase {

    func testEscape() {
        XCTAssertEqual(OutgoingBodies.escape("a & b < c > d \" e"), "a &amp; b &lt; c &gt; d &quot; e")
        XCTAssertEqual(OutgoingBodies.escape("&amp;"), "&amp;amp;")
    }

    func testHTMLWrapsEachLine() {
        XCTAssertEqual(
            OutgoingBodies.html(typed: "Hi <Bob>\n\nBye", style: ComposeStyle(), signatureHTML: nil, quoteHTML: nil),
            "<div dir=\"ltr\" class=\"minimail_default\" "
                + "style=\"font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000\">"
                + "<div>Hi &lt;Bob&gt;</div><div><br></div><div>Bye</div></div>"
        )
    }

    func testHTMLAppendsSignatureAndQuote() {
        let html = OutgoingBodies.html(
            typed: "Hi",
            style: ComposeStyle(),
            signatureHTML: "<b>Max</b>",
            quoteHTML: "<div class=\"gmail_quote\">q</div>"
        )
        XCTAssertTrue(html.contains("gmail_signature_prefix"))
        XCTAssertTrue(html.contains("<b>Max</b>"))
        XCTAssertTrue(html.hasSuffix("<br><div class=\"gmail_quote\">q</div>"))
    }

    func testBlankSignatureIsSkipped() {
        let html = OutgoingBodies.html(typed: "Hi", style: ComposeStyle(), signatureHTML: "  ", quoteHTML: nil)
        XCTAssertFalse(html.contains("gmail_signature"))
    }

    func testDocument() {
        XCTAssertEqual(
            OutgoingBodies.document(bodyFragment: "<p>x</p>"),
            "<html><head><meta charset=\"utf-8\"></head><body><p>x</p></body></html>"
        )
    }

    func testText() {
        XCTAssertEqual(
            OutgoingBodies.text(
                typed: "Hallo Alice,\n\nja.\n\nViele Grüße\nMax",
                signatureText: "Max Mustermann\nExample GmbH",
                quoteText: "On … wrote:\n> Hallo"
            ),
            "Hallo Alice,\n\nja.\n\nViele Grüße\nMax\n\n-- \nMax Mustermann\nExample GmbH\n\nOn … wrote:\n> Hallo"
        )
        XCTAssertEqual(
            OutgoingBodies.text(typed: "Hi\n\n", signatureText: nil, quoteText: nil),
            "Hi"
        )
    }
}

final class PlainTextHTMLTests: XCTestCase {

    func testLinkifiesURLAndTrimsTrailingPunctuation() {
        XCTAssertEqual(
            PlainTextHTML.convert("see https://x.com/a?b=1&c=2."),
            "<div class=\"mm-plaintext\"><div>see "
                + "<a href=\"https://x.com/a?b=1&amp;c=2\">https://x.com/a?b=1&amp;c=2</a>.</div></div>"
        )
    }

    func testBareWWWGetsScheme() {
        XCTAssertEqual(
            PlainTextHTML.convert("(www.example.com)"),
            "<div class=\"mm-plaintext\"><div>("
                + "<a href=\"http://www.example.com\">www.example.com</a>)</div></div>"
        )
    }

    func testEscapesAndBlankLines() {
        XCTAssertEqual(
            PlainTextHTML.convert("a < b\n\nc"),
            "<div class=\"mm-plaintext\"><div>a &lt; b</div><div><br></div><div>c</div></div>"
        )
        XCTAssertEqual(
            PlainTextHTML.convert(""),
            "<div class=\"mm-plaintext\"><div><br></div></div>"
        )
    }

    func testSchemeAloneIsNotALink() {
        XCTAssertFalse(PlainTextHTML.convert("https://").contains("<a href"))
    }
}

final class QuotingTests: XCTestCase {

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func source(html: String? = "<p>Hallo</p>", text: String? = nil) -> QuoteSource {
        QuoteSource(
            author: Mailbox(name: "Alice Müller", addr: "alice@example.com"),
            date: Date(timeIntervalSince1970: 1_789_024_353),
            subject: "Angebot",
            to: [Mailbox(name: "Max", addr: "max.mustermann@example.com")],
            cc: [],
            html: html,
            text: text
        )
    }

    func testAttributionLine() {
        XCTAssertEqual(
            Quoting.attributionLine(
                author: Mailbox(name: "Alice", addr: "alice@example.com"),
                date: Date(timeIntervalSince1970: 1_789_024_353),
                timeZone: berlin
            ),
            "On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice <alice@example.com> wrote:"
        )
        XCTAssertEqual(
            Quoting.attributionLine(
                author: nil,
                date: Date(timeIntervalSince1970: 1_789_024_353),
                timeZone: berlin
            ),
            "On Thu, Sep 10, 2026 at 9:12\u{202F}AM wrote:"
        )
    }

    func testReplyHTMLShape() {
        let html = Quoting.replyHTML(source(), timeZone: berlin)
        XCTAssertTrue(html.hasPrefix("<div class=\"gmail_quote gmail_quote_container\">"))
        XCTAssertTrue(html.contains("<div dir=\"ltr\" class=\"gmail_attr\">On Thu, Sep 10, 2026"))
        XCTAssertTrue(html.contains("&lt;<a href=\"mailto:alice@example.com\">alice@example.com</a>&gt;"))
        XCTAssertTrue(html.contains("<blockquote class=\"gmail_quote\""))
        XCTAssertTrue(html.hasSuffix("<p>Hallo</p></blockquote></div>"))
    }

    func testReplyTextQuotesEveryLine() {
        let quote = Quoting.replyText(source(html: nil, text: "Hallo\n\nMax"), timeZone: berlin)
        XCTAssertTrue(quote.hasPrefix("On Thu, Sep 10, 2026"))
        XCTAssertTrue(quote.hasSuffix("\n> Hallo\n>\n> Max"))
    }

    func testForwardHTMLHasBannerAndHeaders() {
        let html = Quoting.forwardHTML(source(), timeZone: berlin)
        XCTAssertTrue(html.contains("---------- Forwarded message ---------<br>"))
        XCTAssertTrue(html.contains("From: <strong class=\"gmail_sendername\" dir=\"auto\">Alice Müller</strong>"))
        XCTAssertTrue(html.contains("Subject: Angebot<br>"))
        XCTAssertTrue(html.contains("To: Max &lt;<a href=\"mailto:max.mustermann@example.com\">"))
        XCTAssertFalse(html.contains("Cc:"))
    }

    func testForwardTextLayout() {
        let text = Quoting.forwardText(source(html: nil, text: "Hallo"), timeZone: berlin)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "---------- Forwarded message ---------")
        XCTAssertEqual(lines[1], "From: Alice Müller <alice@example.com>")
        XCTAssertTrue(text.hasSuffix("\n\n\nHallo"), "exactly two blank lines before the body")
    }

    func testTextFromHTML() {
        XCTAssertEqual(
            Quoting.textFromHTML("<div>Hallo Max,<div><br></div><div>ist das Angebot?</div></div>"),
            "Hallo Max,\n\nist das Angebot?"
        )
        XCTAssertEqual(Quoting.textFromHTML("<p>a &amp; b</p><p>c</p>"), "a & b\nc")
        XCTAssertEqual(Quoting.textFromHTML("<style>p{}</style>x<script>1</script>"), "x")
        XCTAssertEqual(
            Quoting.textFromHTML(
                "<div style=\"x\">Max Mustermann<br>Example GmbH<br>"
                    + "<a href=\"https://www.example.com\">www.example.com</a></div>"
            ),
            "Max Mustermann\nExample GmbH\nwww.example.com"
        )
    }

    func testTextFromHTMLDecodesNumericEntities() {
        XCTAssertEqual(Quoting.textFromHTML("a&#39;b&nbsp;c&#x41;"), "a'b cA")
    }
}
