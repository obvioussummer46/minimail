import XCTest

@testable import MailCore

final class PackageSmokeTests: XCTestCase {

    func testThemeCSSTokensEquality() {
        let tokens = ThemeCSSTokens(
            background: "#ffffff",
            surface: "#ffffff",
            text: "#000000",
            secondaryText: "#3c3c43",
            accent: "#007aff",
            separator: "#c6c6c8",
            link: "#007aff",
            cardBackground: "#ffffff"
        )
        var other = tokens
        XCTAssertEqual(tokens, other)
        other.accent = "#0a84ff"
        XCTAssertNotEqual(tokens, other)
    }

    func testFixtureBundleLoads() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "smoke", withExtension: "json", subdirectory: "Fixtures/vectors")
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Bool]
        XCTAssertEqual(object?["ok"], true)
    }
}
