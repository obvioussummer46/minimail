import MailCore
import SwiftSoup
import XCTest

@testable import MailHTML

final class DarkStrategyClassifierTests: XCTestCase {
    private func classify(_ html: String, sawBackground: Bool = false) throws -> DarkStrategy {
        let doc = try SwiftSoup.parseBodyFragment(html, "")
        return DarkStrategyClassifier.classify(doc, sawBackgroundAttribute: sawBackground)
    }

    func testMatrix() throws {
        XCTAssertEqual(try classify("<p>hi</p>"), .plain)
        XCTAssertEqual(try classify("<div style=\"background-color:#fff\">x</div>"), .card)
        XCTAssertEqual(try classify("<div style=\"background:transparent\">x</div>"), .plain)
        XCTAssertEqual(try classify("<table><tr><td bgcolor=\"#eee\">x</td></tr></table>"), .card)
        XCTAssertEqual(try classify("<table></table><table></table><img><img><img>"), .card)
        XCTAssertEqual(try classify("<table></table><img><img><img>"), .plain)
        XCTAssertEqual(try classify("<style>@media (prefers-color-scheme:dark){}</style>"), .native)
        XCTAssertEqual(try classify("<style>/* supported-color-schemes */</style>"), .native)
        XCTAssertEqual(try classify("<p>hi</p>", sawBackground: true), .card)
    }
}
