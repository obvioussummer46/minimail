import XCTest

@testable import MailHTML

final class SignatureSanitizerTests: XCTestCase {
    func testKeepsHttpsImageDropsScript() throws {
        let html = try SignatureSanitizer.sanitize(HTMLFixtures.load("signature"))
        XCTAssertTrue(html.contains("src=\"https://cdn.example.com/logo.png\""), html)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,iVBORw0KGgo=\""), html)
        XCTAssertTrue(html.contains("style=\"color:#0b5394\""), html)
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.lowercased().contains("javascript:"))
        XCTAssertFalse(html.contains("data-src"))
        XCTAssertFalse(html.contains(Sanitizer.placeholderGIF))
    }

    func testCidLosesSrc() throws {
        let html = try SignatureSanitizer.sanitize("<img src=\"cid:x\" alt=\"a\">")
        XCTAssertEqual(html, "<img alt=\"a\">")
    }

    func testTooLarge() {
        let big = String(repeating: "a", count: Sanitizer.maxInputBytes + 1)
        XCTAssertThrowsError(try SignatureSanitizer.sanitize(big)) { error in
            XCTAssertEqual(error as? SanitizerError, .tooLarge(bytes: Sanitizer.maxInputBytes + 1))
        }
    }

    func testHasDataImages() {
        XCTAssertTrue(SignatureSanitizer.hasDataImages(HTMLFixtures.load("signature")))
        XCTAssertFalse(SignatureSanitizer.hasDataImages("<p>x</p>"))
        XCTAssertTrue(SignatureSanitizer.hasDataImages("<img src='DATA:image/png;base64,AA'>"))
        XCTAssertTrue(SignatureSanitizer.hasDataImages("<img src=\"data:"))
    }
}
