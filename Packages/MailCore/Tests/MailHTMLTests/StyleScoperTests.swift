import XCTest

@testable import MailHTML

final class StyleScoperTests: XCTestCase {
    private let scope = ".mm-msg[data-id=\"m1\"] .mm-body"

    func testScopeForMessageIdKeepsOnlyIdentifierCharacters() {
        XCTAssertEqual(StyleScoper.scope(forMessageId: "18a\"]x{}"), ".mm-msg[data-id=\"18ax\"] .mm-body")
    }

    func testSimpleSelectorsPrefixed() {
        XCTAssertEqual(StyleScoper.scope(".a{x:y}", scope: scope), "\(scope) .a{x:y}")
        XCTAssertEqual(StyleScoper.scope("p , td.x{x:y}", scope: scope), "\(scope) p,\(scope) td.x{x:y}")
    }

    func testRootSelectorsCollapseToScope() {
        XCTAssertEqual(StyleScoper.scope("body{x:y}", scope: scope), "\(scope){x:y}")
        XCTAssertEqual(StyleScoper.scope("HTML{x:y}", scope: scope), "\(scope){x:y}")
        XCTAssertEqual(StyleScoper.scope("html body{x:y}", scope: scope), "\(scope){x:y}")
        XCTAssertEqual(StyleScoper.scope("*{x:y}", scope: scope), "\(scope){x:y}")
        XCTAssertEqual(StyleScoper.scope("body > div{x:y}", scope: scope), "\(scope) > div{x:y}")
        XCTAssertEqual(StyleScoper.scope("body td{x:y}", scope: scope), "\(scope) td{x:y}")
    }

    func testConditionalAtRulesRecurse() {
        let css = "@media (prefers-color-scheme: dark){body{a:b}.x{c:d}}@supports (display:grid){.g{e:f}}"
        let expected =
            "@media (prefers-color-scheme: dark){\(scope){a:b}\(scope) .x{c:d}}"
            + "@supports (display:grid){\(scope) .g{e:f}}"
        XCTAssertEqual(StyleScoper.scope(css, scope: scope), expected)
    }

    func testOtherAtRulesDropped() {
        let css = "@import url(x);@charset \"utf-8\";@font-face{font-family:X}@keyframes k{from{a:b}to{a:c}}.a{x:y}"
        XCTAssertEqual(StyleScoper.scope(css, scope: scope), "\(scope) .a{x:y}")
    }

    func testCommentsAndStringsHandled() {
        let css = "/* {not a rule} */ .a{content:\"}{\";x:y} .b{content:'a,b'}"
        XCTAssertEqual(
            StyleScoper.scope(css, scope: scope), "\(scope) .a{content:\"}{\";x:y}\(scope) .b{content:'a,b'}")
    }

    func testCommaInsideFunctionNotSplit() {
        XCTAssertEqual(
            StyleScoper.scope(":is(.a, .b){x:y}", scope: scope), "\(scope) :is(.a, .b){x:y}")
    }

    func testDeeplyNestedAtRulesDoNotOverflowStack() {
        // Untrusted email could nest conditional at-rules thousands deep to blow the stack; recursion is capped
        // and anything past the cap is dropped, so this returns without crashing.
        let css =
            String(repeating: "@media all{", count: 50_000) + ".x{a:b}"
            + String(repeating: "}", count: 50_000)
        let out = StyleScoper.scope(css, scope: scope)
        XCTAssertTrue(out.hasPrefix("@media all{"))
        XCTAssertFalse(out.contains("\(scope) .x{a:b}"), "content past the nesting cap is dropped")
    }

    func testUnbalancedInputTruncated() {
        XCTAssertEqual(StyleScoper.scope(".a{x:y", scope: scope), "")
        XCTAssertEqual(StyleScoper.scope("}}.a{x:y}", scope: scope), "\(scope) .a{x:y}")
        XCTAssertEqual(StyleScoper.scope("", scope: scope), "")
    }
}
