import MailCore
import XCTest

@testable import MailHTML

final class MailHTMLPackageSmokeTests: XCTestCase {

    func testSwiftSoupLinked() throws {
        XCTAssertEqual(try MailHTMLPackage.textContent(ofHTML: "<p>Hi <b>there</b></p>"), "Hi there")
    }

    func testFixtureBundleLoads() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "smoke", withExtension: "html", subdirectory: "Fixtures/html")
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("smoke"))
    }

    func testMailCoreReachable() {
        XCTAssertEqual(ComposeStyle().sizePx, 14)
    }
}
