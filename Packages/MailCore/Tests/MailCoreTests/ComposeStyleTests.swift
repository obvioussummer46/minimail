import XCTest

@testable import MailCore

final class ComposeStyleTests: XCTestCase {

    func testDefaults() {
        let style = ComposeStyle()
        XCTAssertEqual(style.family, .helvetica)
        XCTAssertEqual(style.sizePx, 14)
        XCTAssertEqual(style.colorHex, "#000000")
    }

    func testSizeClampsAboveAndBelow() {
        var style = ComposeStyle()
        style.sizePx = 40
        XCTAssertEqual(style.sizePx, 18)
        style.sizePx = 2
        XCTAssertEqual(style.sizePx, 12)
        style.sizePx = 15
        XCTAssertEqual(style.sizePx, 15)
    }

    func testColorHexLowercasesAndRejects() {
        var style = ComposeStyle()
        style.colorHex = "#ABCDEF"
        XCTAssertEqual(style.colorHex, "#abcdef")
        style.colorHex = "red"
        XCTAssertEqual(style.colorHex, "#000000")
        style.colorHex = "#12345"
        XCTAssertEqual(style.colorHex, "#000000")
        style.colorHex = "#gggggg"
        XCTAssertEqual(style.colorHex, "#000000")
    }

    func testIsValidHex() {
        XCTAssertTrue(ComposeStyle.isValidHex("#0a84ff"))
        XCTAssertFalse(ComposeStyle.isValidHex("#0A84FF"))
        XCTAssertFalse(ComposeStyle.isValidHex("0a84ff"))
        XCTAssertFalse(ComposeStyle.isValidHex("#0a84f"))
        XCTAssertFalse(ComposeStyle.isValidHex(""))
    }

    func testInlineCSSForDefaults() {
        XCTAssertEqual(
            ComposeStyle().inlineCSS,
            "font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000"
        )
    }

    func testEveryFamilyHasCSSAndDisplayName() {
        for family in ComposeStyle.Family.allCases {
            XCTAssertFalse(family.css.isEmpty)
            XCTAssertFalse(family.displayName.isEmpty)
        }
        XCTAssertEqual(ComposeStyle.Family.trebuchet.css, "'Trebuchet MS', Helvetica, sans-serif")
        XCTAssertEqual(ComposeStyle.Family.trebuchet.displayName, "Trebuchet MS")
    }

    func testDecodeTolerantOfUnknownFamilyAndOutOfRangeSize() throws {
        let json = #"{"family":"comic","sizePx":40,"colorHex":"#ABCDEF"}"#
        let style = try JSONDecoder().decode(ComposeStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.family, .helvetica)
        XCTAssertEqual(style.sizePx, 18)
        XCTAssertEqual(style.colorHex, "#abcdef")
    }

    func testDecodeEmptyObjectGivesDefaultsAndTypeMismatchThrows() throws {
        let empty = try JSONDecoder().decode(ComposeStyle.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ComposeStyle())
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComposeStyle.self, from: Data(#"{"sizePx":"big"}"#.utf8))
        )
    }

    func testRoundTrip() throws {
        var style = ComposeStyle()
        style.family = .georgia
        style.sizePx = 16
        style.colorHex = "#112233"
        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(ComposeStyle.self, from: data), style)
    }
}
