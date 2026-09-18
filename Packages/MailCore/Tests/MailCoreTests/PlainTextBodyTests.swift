import XCTest

@testable import MailCore

final class PlainTextBodyTests: XCTestCase {

    func testKeepsLinkTextAndURL() {
        let body = PlainTextBody.make(html: "<p>See <a href=\"https://example.com/x\">the docs</a> today.</p>")
        XCTAssertEqual(body.plain, "See the docs today.")
        XCTAssertEqual(
            body.runs,
            [.text("See "), .link(text: "the docs", url: "https://example.com/x"), .text(" today.")])
    }

    /// The whole point of the runs: "click here" with an invisible destination is the shape of a phishing link.
    func testLinkURLSurvivesWhenTextIsMisleading() {
        let body = PlainTextBody.make(html: "<a href=\"https://evil.example/pay\">click here</a>")
        XCTAssertEqual(body.runs, [.link(text: "click here", url: "https://evil.example/pay")])
    }

    func testBlockTagsBecomeLines() {
        XCTAssertEqual(PlainTextBody.make(html: "<p>one</p><p>two</p>").plain, "one\ntwo")
        XCTAssertEqual(PlainTextBody.make(html: "a<br>b").plain, "a\nb")
        XCTAssertEqual(PlainTextBody.make(html: "<ul><li>x</li><li>y</li></ul>").plain, "- x\n- y")
    }

    func testDropsHiddenElementsAndDecodesEntities() {
        XCTAssertEqual(PlainTextBody.make(html: "<style>p{}</style>a &amp; b<script>1</script>").plain, "a & b")
        XCTAssertEqual(PlainTextBody.make(html: "a&#39;b&nbsp;c&#x41;").plain, "a'b cA")
    }

    func testEntitiesInHrefAreDecoded() {
        let body = PlainTextBody.make(html: "<a href=\"https://e.com/?a=1&amp;b=2\">go</a>")
        XCTAssertEqual(body.runs, [.link(text: "go", url: "https://e.com/?a=1&b=2")])
    }

    /// An image button has no text to show, so it leaves no run behind — `Show Original` is the way to it.
    func testAnchorWithoutTextIsDropped() {
        let body = PlainTextBody.make(html: "<p>before</p><a href=\"https://e.com\"><img src=\"b.png\"></a>")
        XCTAssertEqual(body.plain, "before")
        XCTAssertEqual(body.runs, [.text("before")])
    }

    func testLinkTextIsCollapsedToOneLine() {
        let body = PlainTextBody.make(html: "<a href=\"https://e.com\">two<br>words</a>")
        XCTAssertEqual(body.runs, [.link(text: "two words", url: "https://e.com")])
    }

    /// `data-href` must not be mistaken for `href`; an anchor with no usable href is not a link.
    func testIgnoresLookalikeAttribute() {
        let body = PlainTextBody.make(html: "<a data-href=\"https://e.com\">plain</a>")
        XCTAssertEqual(body.runs, [.text("plain")])
    }

    func testUnclosedAnchorStillEmitsItsText() {
        let body = PlainTextBody.make(html: "<a href=\"https://e.com\">tail")
        XCTAssertEqual(body.runs, [.link(text: "tail", url: "https://e.com")])
    }

    /// Blank runs collapse and the ends are trimmed, and a link either side of that survives in order.
    func testTidyingDoesNotDisturbRunOrder() {
        let body = PlainTextBody.make(
            html: "<p>  </p><p>a</p><p></p><p></p><a href=\"https://e.com\">b</a><p>c</p><p>  </p>")
        XCTAssertEqual(body.plain, "a\n\nb\nc")
        XCTAssertEqual(body.runs, [.text("a\n\n"), .link(text: "b", url: "https://e.com"), .text("\nc")])
    }

    func testPlainTextInputIsTidiedNotEscaped() {
        let body = PlainTextBody.make(text: "line one\r\n\r\n\r\nline two  \r\n")
        XCTAssertEqual(body.plain, "line one\n\nline two")
        XCTAssertEqual(body.runs, [.text("line one\n\nline two")])
    }

    func testEmptyBody() {
        XCTAssertTrue(PlainTextBody.make(html: "").isEmpty)
        XCTAssertTrue(PlainTextBody.make(html: "<p></p>").isEmpty)
    }

    /// `Quoting` delegates to the same walker, so the text/plain alternative cannot drift from the read view.
    func testQuotingUsesTheSameWalker() {
        let html = "<div>Max<br><a href=\"https://www.example.com\">www.example.com</a></div>"
        XCTAssertEqual(Quoting.textFromHTML(html), PlainTextBody.make(html: html).plain)
    }
}
