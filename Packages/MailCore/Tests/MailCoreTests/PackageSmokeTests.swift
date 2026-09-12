import XCTest

@testable import MailCore

final class PackageSmokeTests: XCTestCase {

    private func makeTokens(link: String = "#007aff") -> ThemeCSSTokens {
        ThemeCSSTokens(
            background: "#ffffff",
            surface: "#f2f2f7",
            text: "#000000",
            secondaryText: "#3c3c43",
            accent: "#007aff",
            separator: "#c6c6c8",
            link: link,
            cardBackground: "#ffffff"
        )
    }

    func testThemeCSSTokensEquatable() {
        XCTAssertEqual(makeTokens(), makeTokens())
        XCTAssertNotEqual(makeTokens(), makeTokens(link: "#0a84ff"))
    }

    func testFixtureBundleLoads() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "smoke", withExtension: "json", subdirectory: "Fixtures/vectors")
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Bool]
        XCTAssertEqual(object?["ok"], true)
    }
}
