import XCTest

@testable import MailHTML

final class MailHTMLPackageSmokeTests: XCTestCase {

    func testTextContentStripsMarkup() throws {
        XCTAssertEqual(try MailHTMLPackage.textContent(ofHTML: "<p>Hi <b>there</b></p>"), "Hi there")
    }

    func testLinksMailCore() {
        XCTAssertEqual(
            MailHTMLPackage.defaultComposeCSS,
            "font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000"
        )
    }

    func testFixtureBundleLoads() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "smoke", withExtension: "html", subdirectory: "Fixtures/html")
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try MailHTMLPackage.textContent(ofHTML: html), "smoke fixture")
    }
}
