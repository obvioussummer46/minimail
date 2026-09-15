import MailCore
import XCTest

@testable import MailHTML

final class QuoteExtractorTests: XCTestCase {
    func testRestoresDataSrc() {
        let input =
            "<p><img data-src=\"https://a/b.png\" src=\"\(ThreadDocument.placeholderGIF)\" class=\"mm-remote x\" alt=\"i\"></p>"
        XCTAssertEqual(
            QuoteExtractor.quotable(input), "<p><img src=\"https://a/b.png\" class=\"x\" alt=\"i\"></p>")
    }

    func testRemovesCidImages() {
        let input = "<p>Logo <img src=\"minimail-cid://m1/ii_logo\" alt=\"logo\"> end</p>"
        XCTAssertEqual(QuoteExtractor.quotable(input), "<p>Logo  end</p>")
    }

    func testRemovesMMClasses() {
        let input = "<div class=\"mm-plaintext\"><div class=\"mm-a keep\">x</div></div>"
        XCTAssertEqual(QuoteExtractor.quotable(input), "<div><div class=\"keep\">x</div></div>")
    }

    func testRoundTripFromSanitizer() throws {
        let sanitized = try Sanitizer.sanitize(html: HTMLFixtures.load("plain-mail"), messageId: "m1").html
        let quoted = QuoteExtractor.quotable(sanitized)
        XCTAssertTrue(quoted.contains("href=\"https://example.com/x\""), quoted)
        XCTAssertFalse(quoted.contains("mm-"))
    }

    func testNeverThrows() {
        _ = QuoteExtractor.quotable("<<<>>>\u{0}")
    }
}
