import XCTest

@testable import MailHTML

final class StyleScrubberTests: XCTestCase {
    func testEachPattern() {
        let cases: [(String, String)] = [
            ("a{@import url(x);b}", "a{b}"),
            ("@font-face{font-family:X;src:url(y)}Z", "Z"),
            ("x:url( 'https://a' )", "x:"),
            ("expression(", ""),
            ("behavior:", ""),
            ("-moz-binding:", ""),
            ("javascript:void", "void"),
            ("POSITION : FIXED", ""),
            ("position:absolute", ""),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(StyleScrubber.scrub(input), expected, "input: \(input)")
        }
    }

    func testDataURLKept() {
        let a = "background:url(data:image/png;base64,AAAA)"
        let b = "url( \"data:image/gif;base64,R0\" )"
        XCTAssertEqual(StyleScrubber.scrub(a), a)
        XCTAssertEqual(StyleScrubber.scrub(b), b)
    }

    func testIdempotent() {
        let input = "a{@import url(x);b}position:fixed;background:url(https://a/b.png)"
        let once = StyleScrubber.scrub(input)
        XCTAssertEqual(StyleScrubber.scrub(once), once)
    }

    func testEmpty() {
        XCTAssertEqual(StyleScrubber.scrub(""), "")
    }
}
