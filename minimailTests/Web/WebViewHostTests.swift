import GRDB
import MailCore
import UIKit
import WebKit
import XCTest

@testable import minimail

nonisolated final class WebViewHostTests: XCTestCase {

    private var db: DatabaseQueue!
    private var temp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("cid-\(UUID().uuidString)")
        db = try TestDatabase.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeHost() -> WebViewHost {
        let gmail = GmailClient(
            tokens: FixedTokenProvider(), session: .minimail(protocolClasses: [StubURLProtocol.self]),
            limiter: RequestLimiter(max: 2), log: nil)
        let store = InlineImageStore(gmail: gmail, db: db, cacheDirectory: temp)
        return WebViewHost(cid: CIDSchemeHandler(store: store), bridge: WebBridge())
    }

    @MainActor
    func testConfigurationFlags() {
        let gmail = GmailClient(
            tokens: FixedTokenProvider(), session: .minimail(protocolClasses: [StubURLProtocol.self]),
            limiter: RequestLimiter(max: 2), log: nil)
        let store = InlineImageStore(gmail: gmail, db: db, cacheDirectory: temp)
        let configuration = WebViewHost.makeConfiguration(cid: CIDSchemeHandler(store: store), bridge: WebBridge())

        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(configuration.defaultWebpagePreferences.preferredContentMode, .mobile)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(configuration.dataDetectorTypes, [])
        XCTAssertTrue(configuration.suppressesIncrementalRendering)
        XCTAssertNotNil(configuration.urlSchemeHandler(forURLScheme: "minimail-cid"))

        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0].injectionTime, .atDocumentEnd)
        XCTAssertTrue(scripts[0].isForMainFrameOnly)
        XCTAssertEqual(scripts[0].source, WebBridge.clickDelegateJS)
    }

    @MainActor
    func testRuleListsCompile() async {
        RuleLists.reset()
        await RuleLists.prepare()
        XCTAssertNotNil(RuleLists.blockAll)
        XCTAssertNotNil(RuleLists.imagesOnly)

        let firstBlockAll = RuleLists.blockAll
        let firstImagesOnly = RuleLists.imagesOnly
        await RuleLists.prepare()
        XCTAssertTrue(firstBlockAll === RuleLists.blockAll)
        XCTAssertTrue(firstImagesOnly === RuleLists.imagesOnly)
    }

    @MainActor
    func testRuleListJSONIsValid() throws {
        let blockAll = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RuleLists.blockAllJSON.utf8)) as? [[String: Any]])
        let imagesOnly = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RuleLists.imagesOnlyJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(blockAll.count, 4)
        XCTAssertEqual(imagesOnly.count, 5)

        for rule in blockAll + imagesOnly {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertNotNil(trigger["url-filter"] as? String)
        }

        let second = imagesOnly[1]
        let trigger = try XCTUnwrap(second["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["resource-type"] as? [String], ["image"])
        let action = try XCTUnwrap(second["action"] as? [String: Any])
        XCTAssertEqual(action["type"] as? String, "ignore-previous-rules")
    }

    @MainActor
    func testInstanceSettings() {
        let host = makeHost()
        let view = host.webView
        XCTAssertFalse(view.allowsLinkPreview)
        XCTAssertFalse(view.isOpaque)
        XCTAssertTrue(view.navigationDelegate === host.linkPolicy)
        XCTAssertTrue(view.uiDelegate === host.linkPolicy)
        XCTAssertEqual(view.scrollView.contentInsetAdjustmentBehavior, .automatic)
    }

    @MainActor
    func testSetImagesAllowedTracksState() async {
        await RuleLists.prepare()
        let host = makeHost()
        XCTAssertFalse(host.imagesAllowed)
        host.setImagesAllowed(true)
        XCTAssertTrue(host.imagesAllowed)
        host.setImagesAllowed(true)
        XCTAssertTrue(host.imagesAllowed)
        host.setImagesAllowed(false)
        XCTAssertFalse(host.imagesAllowed)
    }

    @MainActor
    func testPrepareWarmsUp() async {
        let host = makeHost()
        XCTAssertNil(host.webViewIfCreated)

        let finished = expectation(description: "warm-up load finished")
        finished.assertForOverFulfill = false
        host.onDocumentLoaded = { finished.fulfill() }

        await host.prepare()
        XCTAssertTrue(host.isPrepared)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(host.webView.url?.absoluteString, "about:blank")
    }

    @MainActor
    func testLoadAndRecycle() async throws {
        let host = makeHost()
        try await prepareAndWait(host)

        try await load(host, document: Self.document(subject: "Seeded subject"), revision: 1)
        let heading = try await host.webView.evaluateJavaScript("document.querySelector('h1').textContent")
        XCTAssertEqual(heading as? String, "Seeded subject")
        XCTAssertEqual(host.loadedRevision, 1)

        let recycled = expectation(description: "recycle finished")
        recycled.assertForOverFulfill = false
        host.onDocumentLoaded = { recycled.fulfill() }
        host.recycle()
        await fulfillment(of: [recycled], timeout: 5)

        let sections = try await host.webView.evaluateJavaScript("document.querySelectorAll('section').length")
        XCTAssertEqual((sections as? NSNumber)?.intValue, 0)
        XCTAssertEqual(host.loadedRevision, -1)
    }

    @MainActor
    func testThrowawayHasNoHandlers() {
        let host = makeHost()
        let view = host.makeThrowawayWebView()
        XCTAssertNil(view.configuration.urlSchemeHandler(forURLScheme: "minimail-cid"))
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(view.allowsLinkPreview)
        XCTAssertFalse(view.navigationDelegate === host.linkPolicy)
    }

    @MainActor
    func testDidLeaveThreadSchedulesRecycle() async throws {
        let host = makeHost()
        try await prepareAndWait(host)
        host.recycleDelayOverride = 0.05

        try await load(host, document: Self.document(subject: "Leaving"), revision: 3)
        XCTAssertEqual(host.loadedRevision, 3)

        host.didDetach()
        host.didLeaveThread()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(host.loadedRevision, -1)
    }

    // MARK: - Helpers

    /// `prepare()` warms up with an asynchronous `about:blank` load; wait for it so a later expectation
    /// cannot be fulfilled by the warm-up instead of the load under test.
    @MainActor
    private func prepareAndWait(_ host: WebViewHost) async throws {
        let warmed = expectation(description: "warm-up finished")
        warmed.assertForOverFulfill = false
        host.onDocumentLoaded = { warmed.fulfill() }
        await host.prepare()
        await fulfillment(of: [warmed], timeout: 5)
        host.onDocumentLoaded = nil
    }

    @MainActor
    private func load(_ host: WebViewHost, document: String, revision: Int) async throws {
        let finished = expectation(description: "load \(revision) finished")
        finished.assertForOverFulfill = false
        host.onDocumentLoaded = { finished.fulfill() }
        host.load(document: document, revision: revision)
        await fulfillment(of: [finished], timeout: 5)
    }

    @MainActor
    private static func document(subject: String) -> String {
        ThreadDocument.render(
            subject: subject,
            messages: [
                ThreadDocumentMessage(
                    id: "m1", fromName: "Alice", fromAddr: "alice@example.com", toLine: "Me", ccLine: nil,
                    dateLabel: "14:32", dateFull: "11 Sep 2026 at 14:32", snippet: "hello", isUnread: false,
                    expanded: true, bodyHTML: "<p>hello</p>", bodyState: 1, darkStrategy: "plain",
                    hasRemoteImages: false, imagesAllowed: false, attachments: [])
            ],
            light: SystemPalette.cssTokens(for: .light), dark: SystemPalette.cssTokens(for: .dark),
            forcedScheme: nil, imagesAllowed: false)
    }
}
