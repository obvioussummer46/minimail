import WebKit
import XCTest

@testable import minimail

nonisolated final class WebBridgeTests: XCTestCase {

    // MARK: - WebBridge.parse(_:)

    @MainActor
    func testParseMatrix() {
        XCTAssertEqual(WebBridge.parse(["action": "toggle", "id": "m1"]), .toggle(messageId: "m1"))
        XCTAssertEqual(WebBridge.parse(["action": "images", "id": "m1"]), .loadImages(messageId: "m1"))
        XCTAssertEqual(WebBridge.parse(["action": "retry", "id": "m1"]), .retry(messageId: "m1"))
        XCTAssertEqual(
            WebBridge.parse(["action": "att", "id": "m1", "part": "2"]),
            .attachment(messageId: "m1", partId: "2"))
        XCTAssertNil(WebBridge.parse(["action": "att", "id": "m1"]))
        XCTAssertNil(WebBridge.parse(["action": "toggle", "id": ""]))
        XCTAssertNil(WebBridge.parse(["action": "link"]))
        XCTAssertNil(WebBridge.parse("string"))
    }

    @MainActor
    func testParseActionURL() {
        XCTAssertEqual(
            WebBridge.parse(actionURL: URL(string: "minimail-action://att/m1/2")!),
            .attachment(messageId: "m1", partId: "2"))
        XCTAssertEqual(
            WebBridge.parse(actionURL: URL(string: "minimail-action://toggle/m1")!), .toggle(messageId: "m1"))
        XCTAssertEqual(
            WebBridge.parse(actionURL: URL(string: "minimail-action://images/m1")!),
            .loadImages(messageId: "m1"))
        XCTAssertNil(WebBridge.parse(actionURL: URL(string: "minimail-action://toggle/")!))
        XCTAssertNil(WebBridge.parse(actionURL: URL(string: "https://x/toggle/m1")!))
    }

    @MainActor
    func testClickScriptShape() {
        let js = WebBridge.clickDelegateJS
        XCTAssertTrue(js.contains("messageHandlers.mm.postMessage"))
        XCTAssertTrue(js.contains("data-action"))
        XCTAssertTrue(js.contains("preventDefault"))
        XCTAssertTrue(js.contains("closest('section.mm-msg')"))
    }

    // MARK: - LinkPolicy

    @MainActor
    func testLinkPolicyDecisionMatrix() {
        for text in ["https://example.com/x", "http://example.com/x", "mailto:a@b.c", "tel:+49123"] {
            let url = URL(string: text)!
            let decision = LinkPolicy.decision(for: url, type: .linkActivated)
            XCTAssertEqual(decision.policy, .cancel, text)
            XCTAssertEqual(decision.open, url, text)
            XCTAssertNil(decision.action, text)
        }

        let js = LinkPolicy.decision(for: URL(string: "javascript:alert(1)")!, type: .linkActivated)
        XCTAssertEqual(js.policy, .cancel)
        XCTAssertNil(js.open)
        XCTAssertNil(js.action)

        let action = LinkPolicy.decision(for: URL(string: "minimail-action://images/m1")!, type: .linkActivated)
        XCTAssertEqual(action.policy, .cancel)
        XCTAssertNil(action.open)
        XCTAssertEqual(action.action, .loadImages(messageId: "m1"))

        let blank = LinkPolicy.decision(for: URL(string: "about:blank")!, type: .other)
        XCTAssertEqual(blank.policy, .allow)
        XCTAssertNil(blank.open)
        XCTAssertNil(blank.action)

        XCTAssertEqual(LinkPolicy.decision(for: URL(string: "https://x")!, type: .other).policy, .cancel)
        XCTAssertEqual(LinkPolicy.decision(for: URL(string: "about:blank")!, type: .reload).policy, .cancel)
        XCTAssertEqual(LinkPolicy.decision(for: nil, type: .linkActivated).policy, .cancel)
        XCTAssertEqual(LinkPolicy.decision(for: nil, type: .other).policy, .cancel)
    }

    // MARK: - CIDSchemeHandler.parse

    @MainActor
    func testCIDParse() {
        let parsed = CIDSchemeHandler.parse(URL(string: "minimail-cid://m1/ii_logo%40x")!)
        XCTAssertEqual(parsed?.messageId, "m1")
        XCTAssertEqual(parsed?.contentId, "ii_logo@x")
        XCTAssertNil(CIDSchemeHandler.parse(URL(string: "minimail-cid://m1/")!))
        XCTAssertNil(CIDSchemeHandler.parse(URL(string: "minimail-cid:///x")!))
    }
}
