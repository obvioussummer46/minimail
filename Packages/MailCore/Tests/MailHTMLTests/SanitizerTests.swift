import MailCore
import XCTest

@testable import MailHTML

final class SanitizerTests: XCTestCase {
    private func sanitize(_ name: String) throws -> SanitizedBody {
        try Sanitizer.sanitize(html: HTMLFixtures.load(name), messageId: "m1")
    }

    func testScriptIframeFormMetaRemoved() throws {
        let html = try sanitize("xss-samples").html
        for needle in [
            "<script", "<iframe", "<form", "<input", "<button", "<meta", "<object", "<base", "<link", "<svg",
        ] {
            XCTAssertFalse(html.contains(needle), "should not contain \(needle)")
        }
        XCTAssertTrue(html.contains(">e<"), "svg text kept")
        XCTAssertTrue(html.contains(">go<"), "button text kept")
    }

    func testEventHandlersAndJavascriptURLsRemoved() throws {
        let html = try sanitize("xss-samples").html.lowercased()
        XCTAssertFalse(html.contains("onerror"))
        XCTAssertFalse(html.contains("onclick"))
        XCTAssertFalse(html.contains("onmouseover"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertFalse(html.contains("href=\"javascript"))
    }

    func testTargetEnforcedSelf() throws {
        let html = try sanitize("xss-samples").html
        XCTAssertTrue(html.contains("href=\"https://ok.example\""))
        XCTAssertTrue(html.contains("target=\"_self\""))
        XCTAssertFalse(html.contains("target=\"_blank\""))
    }

    func testSrcsetAndProtocolRelativeDropped() throws {
        let html = try sanitize("xss-samples").html
        XCTAssertFalse(html.contains("srcset"))
        XCTAssertTrue(html.contains("data-src=\"https://ok.example/y.png\""))
        XCTAssertTrue(html.contains("alt=\"pr\""))
        XCTAssertFalse(html.contains("//host"), "protocol-relative src dropped")
        XCTAssertFalse(html.contains("background="), "background attribute dropped")
    }

    func testRemoteImageNeutralised() throws {
        let body = try sanitize("plain-mail")
        XCTAssertTrue(
            body.html.contains("data-src=\"https://a/b.png\" src=\"\(Sanitizer.placeholderGIF)\""),
            body.html)
        XCTAssertTrue(body.html.contains("class=\"mm-remote\""))
        XCTAssertTrue(body.hasRemoteImages)
    }

    func testDataImageKept() throws {
        let html = try sanitize("inline-cid").html
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,iVBORw0KGgo=\""), html)
    }

    func testCidRewriteAndReferencedSet() throws {
        let body = try sanitize("inline-cid")
        XCTAssertTrue(body.html.contains("src=\"minimail-cid://m1/ii_logo%40example.com\""), body.html)
        XCTAssertTrue(body.html.contains("src=\"minimail-cid://m1/ii_2\""), body.html)
        XCTAssertTrue(body.html.contains("src=\"minimail-cid://m1/a%40b\""), body.html)
        XCTAssertEqual(body.referencedContentIDs, ["ii_logo@example.com", "ii_2", "a@b"])
    }

    func testCidRewriteSurvivesClean() throws {
        let body = try Sanitizer.sanitize(html: "<img src=\"cid:x\">", messageId: "m9")
        XCTAssertEqual(body.html, "<img src=\"minimail-cid://m9/x\">")
    }

    func testTrackingPixelRemovedBeforeRemoteFlag() throws {
        let body = try Sanitizer.sanitize(
            html: "<p>a</p><img src=\"https://t/o.gif\" width=\"1\" height=\"1\">", messageId: "m1")
        XCTAssertFalse(body.html.contains("<img"))
        XCTAssertFalse(body.hasRemoteImages)
    }

    func testStyleBlockScrubbed() throws {
        let html = try sanitize("newsletter").html
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertFalse(html.contains("@import"))
        XCTAssertFalse(html.contains("@font-face"))
        XCTAssertFalse(html.contains("url(https://img.example/bg.png)"))
        XCTAssertTrue(html.contains(".mm-msg[data-id=\"m1\"] .mm-body .dark{background-color:#000}"), html)
    }

    func testStyleBlockScopedToMessage() throws {
        let css = "body{color:red} html, .a > b{margin:0} @media (max-width:600px){.c{display:none}} "
            + "@keyframes k{from{opacity:0}} @font-face{font-family:X} p{x:y}"
        let body = try Sanitizer.sanitize(html: "<style>\(css)</style><p class=\"c\">x</p>", messageId: "m1")
        let scope = ".mm-msg[data-id=\"m1\"] .mm-body"
        XCTAssertTrue(body.html.contains("\(scope){color:red}"), body.html)
        XCTAssertTrue(body.html.contains("\(scope),\(scope) .a > b{margin:0}"), body.html)
        XCTAssertTrue(body.html.contains("@media (max-width:600px){\(scope) .c{display:none}}"), body.html)
        XCTAssertTrue(body.html.contains("\(scope) p{x:y}"), body.html)
        XCTAssertFalse(body.html.contains("@keyframes"))
        XCTAssertFalse(body.html.contains("@font-face"))
    }

    func testRendererClassesStripped() throws {
        let body = try Sanitizer.sanitize(
            html: "<div class=\"mm-hdr keep MM-att\">x</div><span class=\"mm-skeleton\">y</span>", messageId: "m1")
        XCTAssertTrue(body.html.contains("class=\"keep\""), body.html)
        XCTAssertFalse(body.html.contains("mm-hdr"))
        XCTAssertFalse(body.html.contains("mm-skeleton"))
        XCTAssertFalse(body.html.lowercased().contains("mm-att"))
    }

    func testProseIsNotScrubbed() throws {
        let body = try Sanitizer.sanitize(
            html: "<p>his behavior: fine, see url(x) and expression (y)</p>", messageId: "m1")
        XCTAssertTrue(body.html.contains("his behavior: fine, see url(x) and expression (y)"), body.html)
    }

    func testStyleAttributeScrubbed() throws {
        let body = try Sanitizer.sanitize(
            html: "<div style=\"color:red;background:url(https://x/y.png)\">x</div>", messageId: "m1")
        XCTAssertTrue(body.html.contains("color:red"), body.html)
        XCTAssertFalse(body.html.contains("https://x"), body.html)
    }

    func testNewsletterIsCard() throws {
        let body = try sanitize("newsletter")
        XCTAssertEqual(body.darkStrategy, .card)
        XCTAssertTrue(body.hasRemoteImages)
        XCTAssertFalse(body.html.contains("<script"))
    }

    func testPlainMailIsPlain() throws {
        let body = try sanitize("plain-mail")
        XCTAssertEqual(body.darkStrategy, .plain)
        XCTAssertTrue(body.html.contains("style=\"color:#444444\""), body.html)
        XCTAssertTrue(body.html.contains("href=\"https://example.com/x\""))
    }

    func testDarkNativeIsNative() throws {
        let body = try sanitize("dark-native")
        XCTAssertEqual(body.darkStrategy, .native)
        XCTAssertTrue(body.html.contains("prefers-color-scheme"))
    }

    func testMalformedDoesNotThrow() throws {
        let body = try sanitize("malformed")
        XCTAssertTrue(body.html.contains("unclosed cell"))
        XCTAssertTrue(body.html.contains("mis"))
        XCTAssertFalse(body.html.contains("<!--"))
    }

    func testTooLargeThrows() {
        let big = String(repeating: "a", count: Sanitizer.maxInputBytes + 1)
        XCTAssertThrowsError(try Sanitizer.sanitize(html: big, messageId: "m1")) { error in
            XCTAssertEqual(error as? SanitizerError, .tooLarge(bytes: Sanitizer.maxInputBytes + 1))
        }
    }

    func testExactlyMaxBytesAccepted() throws {
        let html = "<p>" + String(repeating: "a", count: Sanitizer.maxInputBytes - 7) + "</p>"
        XCTAssertEqual(html.utf8.count, Sanitizer.maxInputBytes)
        XCTAssertNoThrow(try Sanitizer.sanitize(html: html, messageId: "m1"))
    }

    func testEmptyInput() throws {
        let body = try Sanitizer.sanitize(html: "", messageId: "m1")
        XCTAssertEqual(
            body,
            SanitizedBody(html: "", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []))
    }

    func testUnknownCSSPropertyDropped() throws {
        let body = try Sanitizer.sanitize(
            html: "<div style=\"color:red;position:absolute;z-index:9\">x</div>", messageId: "m1")
        XCTAssertTrue(body.html.contains("color:red"), body.html)
        XCTAssertFalse(body.html.contains("position"))
        XCTAssertFalse(body.html.contains("z-index"))
    }

    func testIdAttributeDropped() throws {
        let body = try Sanitizer.sanitize(
            html: "<div id=\"a\" class=\"b\" dir=\"rtl\">x</div>", messageId: "m1")
        XCTAssertTrue(body.html.contains("class=\"b\""))
        XCTAssertTrue(body.html.contains("dir=\"rtl\""))
        XCTAssertFalse(body.html.contains("id="))
    }

    func testFromPlainText() {
        let body = Sanitizer.fromPlainText("a < b\n\nc")
        XCTAssertEqual(body.html, PlainTextHTML.convert("a < b\n\nc"))
        XCTAssertEqual(body.darkStrategy, .plain)
        XCTAssertFalse(body.hasRemoteImages)
        XCTAssertTrue(body.referencedContentIDs.isEmpty)
    }

    func testPlaceholderMatchesThreadDocument() {
        XCTAssertEqual(Sanitizer.placeholderGIF, ThreadDocument.placeholderGIF)
    }

    func testNewsletter500KBUnder150ms() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILCORE_PERF"] == "1")
        var html = HTMLFixtures.load("newsletter")
        let unit = html
        while html.utf8.count < 500_000 { html += unit }
        _ = try Sanitizer.sanitize(html: html, messageId: "m1")  // warm up
        let start = Date()
        _ = try Sanitizer.sanitize(html: html, messageId: "m1")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.150)
    }
}
