import XCTest

@testable import MailCore

final class ComposeStyleTests: XCTestCase {

    func testDefaults() {
        let style = ComposeStyle()
        XCTAssertEqual(style.family, .helvetica)
        XCTAssertEqual(style.sizePx, 14)
        XCTAssertEqual(style.colorHex, "#000000")
        XCTAssertEqual(style.inlineCSS, "font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000")
    }

    func testFamilyCSSTable() {
        let expected: [ComposeStyle.Family: (css: String, displayName: String)] = [
            .helvetica: ("Helvetica, Arial, sans-serif", "Helvetica"),
            .arial: ("Arial, Helvetica, sans-serif", "Arial"),
            .verdana: ("Verdana, Geneva, sans-serif", "Verdana"),
            .tahoma: ("Tahoma, Geneva, sans-serif", "Tahoma"),
            .trebuchet: ("'Trebuchet MS', Helvetica, sans-serif", "Trebuchet MS"),
            .georgia: ("Georgia, 'Times New Roman', serif", "Georgia"),
            .times: ("'Times New Roman', Times, serif", "Times New Roman"),
            .courier: ("'Courier New', Courier, monospace", "Courier New"),
        ]
        XCTAssertEqual(ComposeStyle.Family.allCases.count, 8)
        for family in ComposeStyle.Family.allCases {
            guard let entry = expected[family] else {
                XCTFail("no expectation for \(family)")
                continue
            }
            XCTAssertEqual(family.css, entry.css)
            XCTAssertEqual(family.displayName, entry.displayName)
        }
    }

    func testSizeClampOnSet() {
        var style = ComposeStyle()
        style.sizePx = 40
        XCTAssertEqual(style.sizePx, 18)
        style.sizePx = 3
        XCTAssertEqual(style.sizePx, 12)
        style.sizePx = 16
        XCTAssertEqual(style.sizePx, 16)
    }

    func testColorHexNormalisation() {
        var style = ComposeStyle()
        style.colorHex = "#ABCDEF"
        XCTAssertEqual(style.colorHex, "#abcdef")
        style.colorHex = "red"
        XCTAssertEqual(style.colorHex, "#000000")
        style.colorHex = "#12345"
        XCTAssertEqual(style.colorHex, "#000000")
        style.colorHex = "#123456"
        XCTAssertEqual(style.colorHex, "#123456")
    }

    func testIsValidHex() {
        XCTAssertTrue(ComposeStyle.isValidHex("#000000"))
        XCTAssertFalse(ComposeStyle.isValidHex("#ABCDEF"))
        XCTAssertFalse(ComposeStyle.isValidHex("000000"))
        XCTAssertFalse(ComposeStyle.isValidHex("#00000"))
        XCTAssertFalse(ComposeStyle.isValidHex("#0000000"))
        XCTAssertFalse(ComposeStyle.isValidHex("#00000g"))
    }

    func testDecodeTolerant() throws {
        let json = ##"{"family":"comic","sizePx":40,"colorHex":"#ABCDEF"}"##
        let style = try JSONDecoder().decode(ComposeStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.family, .helvetica)
        XCTAssertEqual(style.sizePx, 18)
        XCTAssertEqual(style.colorHex, "#abcdef")
    }

    func testDecodeEmptyObject() throws {
        XCTAssertEqual(try JSONDecoder().decode(ComposeStyle.self, from: Data("{}".utf8)), ComposeStyle())
    }

    func testDecodeTypeMismatchThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComposeStyle.self, from: Data(#"{"sizePx":"big"}"#.utf8))
        )
    }

    func testEncodeSortedKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ComposeStyle())
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            ##"{"colorHex":"#000000","family":"helvetica","sizePx":14}"##
        )
    }

    func testRoundTrip() throws {
        for family in ComposeStyle.Family.allCases {
            for size in [12, 18] {
                var style = ComposeStyle()
                style.family = family
                style.sizePx = size
                style.colorHex = "#0a84ff"
                let data = try JSONEncoder().encode(style)
                XCTAssertEqual(try JSONDecoder().decode(ComposeStyle.self, from: data), style)
            }
        }
    }
}
