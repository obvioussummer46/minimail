import GRDB
import MailCore
import MailHTML
import SwiftUI
import XCTest

@testable import minimail

nonisolated final class ThreadModelTests: XCTestCase {
    var env: AppEnvironment!
    var model: ThreadModel!
    let seedNow: Int64 = 1_757_500_000_000

    @MainActor override func setUp() async throws {
        StubURLProtocol.reset()
        // Two defaults have to be replaced for a request to reach the stub: the test host has no keychain item,
        // so the real provider fails every request with `.unauthorized`, and `testURLProtocolClasses` defaults to
        // `OfflineURLProtocol`, which fails every request with `.notConnectedToInternet`.
        AppEnvironment.testTokenProvider = FixedTokenProvider()
        AppEnvironment.testURLProtocolClasses = [StubURLProtocol.self]
        // Default: offline, matching what `OfflineURLProtocol` used to do for tests that script no routes.
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        model?.stop()
        model = nil
        env = nil
        AppEnvironment.testTokenProvider = nil
        AppEnvironment.testURLProtocolClasses = [OfflineURLProtocol.self]
        StubURLProtocol.reset()
    }

    @MainActor func waitUntil(_ timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Seeding helpers

    @MainActor
    private func seed(_ messages: [ParsedMessage]) throws { try TestDatabase.seed(env.db, messages) }

    @MainActor
    private func message(
        _ id: String, thread: String = "t1", offset: Int64, unread: Bool = false, subject: String = "Subject"
    ) -> ParsedMessage {
        TestDatabase.parsed(
            id: id, threadId: thread, internalDate: seedNow + offset,
            labels: unread ? ["INBOX", "UNREAD"] : ["INBOX"], subject: subject)
    }

    @MainActor
    private func storeBody(
        _ messageId: String, html: String, hasRemoteImages: Bool = false, contentIds: Set<String> = []
    ) throws {
        try env.db.write { db in
            try BodyRepository.storeBody(
                db, messageId: messageId,
                body: SanitizedBody(
                    html: html, hasRemoteImages: hasRemoteImages, darkStrategy: .plain,
                    referencedContentIDs: contentIds),
                text: nil, attachments: [], referenced: [], sanitizerVersion: 1, now: 0)
        }
    }

    // MARK: - First document

    @MainActor
    func testFirstDocumentIsBuiltSynchronously() throws {
        try seed([message("m1", offset: 1_000), message("m2", offset: 2_000)])
        try storeBody("m1", html: "<p>One</p>")
        try storeBody("m2", html: "<p>Two</p>")

        model = ThreadModel(env: env, threadId: "t1")

        XCTAssertEqual(model.revision, 1)
        XCTAssertTrue(model.document.hasPrefix("<!doctype html><html"))
        XCTAssertTrue(model.document.contains("<section class=\"mm-msg"))
        XCTAssertTrue(model.document.contains("data-id=\"m1\""))
        XCTAssertTrue(model.document.contains("data-id=\"m2\""))
        XCTAssertEqual(model.detail?.messages.map(\.id), ["m1", "m2"])
    }

    @MainActor
    func testInitialExpandedUnreadAndNewest() throws {
        // Case A: only the newest is unread.
        try seed([
            message("m1", offset: 1_000), message("m2", offset: 2_000), message("m3", offset: 3_000, unread: true),
        ])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.expanded, ["m3"])
        XCTAssertEqual(model.expanded, ThreadModel.initialExpanded(model.detail!))

        // Case B: a middle message is unread — it and the newest are expanded.
        model.stop()
        env = AppEnvironment(testing: true)
        try seed([
            message("m1", offset: 1_000), message("m2", offset: 2_000, unread: true), message("m3", offset: 3_000),
        ])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.expanded, ["m2", "m3"])

        // Case C: none unread.
        model.stop()
        env = AppEnvironment(testing: true)
        try seed([message("m1", offset: 1_000), message("m2", offset: 2_000), message("m3", offset: 3_000)])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.expanded, ["m3"])

        // Case D: all unread.
        model.stop()
        env = AppEnvironment(testing: true)
        try seed([
            message("m1", offset: 1_000, unread: true), message("m2", offset: 2_000, unread: true),
            message("m3", offset: 3_000, unread: true),
        ])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.expanded, ["m1", "m2", "m3"])
        XCTAssertEqual(model.expanded, ThreadModel.initialExpanded(model.detail!))
    }

    @MainActor
    func testExpandedClassesInDocument() throws {
        try seed([message("m1", offset: 1_000), message("m2", offset: 2_000)])
        try storeBody("m1", html: "<p>One</p>")
        try storeBody("m2", html: "<p>Two</p>")
        model = ThreadModel(env: env, threadId: "t1")

        let sections = model.document.components(separatedBy: "<section class=\"mm-msg")
        let first = try XCTUnwrap(sections.first { $0.contains("data-id=\"m1\"") })
        let newest = try XCTUnwrap(sections.first { $0.contains("data-id=\"m2\"") })
        XCTAssertTrue(first.hasPrefix(" mm-collapsed") || first.contains("mm-collapsed"))
        XCTAssertTrue(newest.contains("mm-expanded"))
    }

    @MainActor
    func testTitleStripsPrefixes() throws {
        try seed([message("m1", offset: 1_000, subject: "Re: Fwd: Angebot")])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.title, "Angebot")
        XCTAssertTrue(model.document.contains("<h1 class=\"mm-subject\">Angebot</h1>"))

        model.stop()
        env = AppEnvironment(testing: true)
        try seed([message("m1", offset: 1_000, subject: "")])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.title, "(No subject)")
        XCTAssertTrue(model.document.contains("(No subject)"))
    }

    @MainActor
    func testMissingThreadDismissesImmediately() {
        model = ThreadModel(env: env, threadId: "nope")
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.shouldDismiss)
        XCTAssertFalse(model.document.isEmpty)
    }

    @MainActor
    func testThreadDeletedLaterDismisses() async throws {
        try seed([message("m1", offset: 1_000)])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertNotNil(model.detail)

        try await env.db.write { db in
            _ = try MessageRepository.delete(db, ids: ["m1"])
            try ThreadRepository.recomputeAggregates(db, threadIds: ["t1"], selfAddresses: [])
        }

        await waitUntil { self.model.shouldDismiss }
        XCTAssertNil(model.detail)
    }

    /// No web view has ever been created here, so there is no loaded document to patch and the arrival falls
    /// back to a reload. The patched path is `testBodyArrivalPatchesLoadedDocument`.
    @MainActor
    func testBodyArrivalRebuildsAndBumpsRevision() async throws {
        try seed([message("m1", offset: 1_000)])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertNil(env.webHost.webViewIfCreated)
        XCTAssertEqual(model.revision, 1)
        XCTAssertTrue(model.document.contains("Loading…"))

        try storeBody("m1", html: "<p>Hello</p>")

        await waitUntil { self.model.revision == 2 }
        XCTAssertTrue(model.document.contains("Hello"))
        XCTAssertFalse(model.document.contains("Loading…"))
    }

    /// The production path: the document is on screen when the body lands, so the section is swapped in place
    /// and `revision` does not move — no `loadHTMLString`, no lost scroll position.
    @MainActor
    func testBodyArrivalPatchesLoadedDocument() async throws {
        try seed([message("m1", offset: 1_000)])
        model = ThreadModel(env: env, threadId: "t1")
        try await loadIntoWebView()
        XCTAssertEqual(model.revision, 1)

        try storeBody("m1", html: "<p>Hello</p>")

        await waitUntil { self.model.document.contains("Hello") }
        XCTAssertEqual(model.revision, 1, "a body landing must patch, not reload")
        await waitUntil { await self.webViewHTML().contains("Hello") }
        let html = await webViewHTML()
        XCTAssertFalse(html.contains("Loading…"), html)
    }

    /// A theme change rewrites the head, which no section patch can express.
    @MainActor
    func testThemeChangeStillReloads() async throws {
        try seed([message("m1", offset: 1_000)])
        try storeBody("m1", html: "<p>Hello</p>")
        model = ThreadModel(env: env, threadId: "t1")
        try await loadIntoWebView()
        XCTAssertEqual(model.revision, 1)

        env.theme.choice = .dark
        model.systemSchemeChanged(.dark)

        XCTAssertEqual(model.revision, 2)
    }

    @MainActor
    func testUnrelatedTickDoesNotRebuild() async throws {
        try seed([message("m1", offset: 1_000)])
        try storeBody("m1", html: "<p>Hello</p>")
        model = ThreadModel(env: env, threadId: "t1")
        let before = model.document

        try await env.db.write { db in
            try ThreadRepository.markComplete(db, threadId: "t1", complete: true)
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(model.revision, 1)
        XCTAssertEqual(model.document, before)
    }

    // MARK: - Toggle, images, retry

    @MainActor
    func testToggleKeepsRevision() async throws {
        try seed([message("m1", offset: 1_000), message("m2", offset: 2_000)])
        try storeBody("m1", html: "<p>One</p>")
        try storeBody("m2", html: "<p>Two</p>")
        model = ThreadModel(env: env, threadId: "t1")
        let wasExpanded = model.expanded.contains("m1")

        model.toggle(messageId: "m1")

        XCTAssertNotEqual(model.expanded.contains("m1"), wasExpanded)
        XCTAssertEqual(model.revision, 1)

        try await env.db.write { db in
            try ThreadRepository.markComplete(db, threadId: "t1", complete: true)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.revision, 1)
    }

    @MainActor
    func testToggleOfStrippedSectionRebuilds() throws {
        let big = "<p>" + String(repeating: "x", count: 1_200_000) + "</p>"
        try seed((1...6).map { message("m\($0)", offset: Int64($0) * 1_000) })
        for index in 1...6 { try storeBody("m\(index)", html: big) }
        model = ThreadModel(env: env, threadId: "t1")

        let messages = ThreadModel.documentMessages(
            detail: model.detail!, expanded: model.expanded, imagesAllowedIds: [],
            loadRemoteImages: false,
            labeler: RowDateLabeler(now: Date(), timeZone: .current, locale: .current),
            fullDate: ThreadModel.makeFullDateFormatter(timeZone: .current, locale: .current))
        let stripped = ThreadDocument.strippedIds(messages: messages)
        XCTAssertFalse(stripped.isEmpty)

        let target = try XCTUnwrap(stripped.first)
        model.toggle(messageId: target)

        XCTAssertEqual(model.revision, 2)
    }

    @MainActor
    func testLoadImagesRebuildsAndOpensCSP() throws {
        try seed([message("m1", offset: 1_000)])
        try storeBody(
            "m1",
            html: "<img class=\"mm-remote\" data-src=\"https://x/y.png\" src=\"\(ThreadDocument.placeholderGIF)\">",
            hasRemoteImages: true)
        model = ThreadModel(env: env, threadId: "t1")

        XCTAssertFalse(model.documentImagesAllowed)
        XCTAssertTrue(model.document.contains("img-src data: minimail-cid:;"))
        XCTAssertTrue(model.document.contains("Load images"))

        model.loadImages(messageId: "m1")

        XCTAssertEqual(model.revision, 2)
        XCTAssertTrue(model.documentImagesAllowed)
        XCTAssertTrue(model.document.contains("img-src data: minimail-cid: https:"))
        XCTAssertTrue(model.document.contains("src=\"https://x/y.png\""))
        XCTAssertFalse(model.document.contains("Load images"))
        XCTAssertEqual(model.lastActionId, 1)
    }

    @MainActor
    func testLoadImagesIsPerMessage() throws {
        try seed([message("m1", offset: 1_000), message("m2", offset: 2_000)])
        for id in ["m1", "m2"] {
            try storeBody(
                id,
                html:
                    "<img class=\"mm-remote\" data-src=\"https://x/\(id).png\" src=\"\(ThreadDocument.placeholderGIF)\">",
                hasRemoteImages: true)
        }
        model = ThreadModel(env: env, threadId: "t1")

        model.loadImages(messageId: "m1")

        // `data-src="…"` ends in `src="…"`, so both halves have to be matched whole.
        let placeholder = ThreadDocument.placeholderGIF
        XCTAssertTrue(model.document.contains("<img class=\"mm-remote\" src=\"https://x/m1.png\""))
        XCTAssertFalse(model.document.contains("data-src=\"https://x/m1.png\""))
        XCTAssertTrue(model.document.contains("data-src=\"https://x/m2.png\" src=\"\(placeholder)\""))
        XCTAssertTrue(model.document.contains("Load images"))
    }

    @MainActor
    func testGlobalSettingAllowsImages() throws {
        env.settings.update { $0.loadRemoteImages = true }
        try seed([message("m1", offset: 1_000)])
        try storeBody(
            "m1",
            html: "<img class=\"mm-remote\" data-src=\"https://x/y.png\" src=\"\(ThreadDocument.placeholderGIF)\">",
            hasRemoteImages: true)
        model = ThreadModel(env: env, threadId: "t1")

        XCTAssertTrue(model.documentImagesAllowed)
        XCTAssertTrue(model.document.contains("img-src data: minimail-cid: https:"))
        XCTAssertFalse(model.document.contains("Load images"))
    }

    @MainActor
    func testRetryResetsBodyStateAndReloads() async throws {
        try seed([message("m1", offset: 1_000)])
        try await env.db.write { db in try BodyRepository.markUnavailable(db, messageId: "m1") }
        model = ThreadModel(env: env, threadId: "t1")
        await waitUntil { self.model.document.contains("Couldn't load this message") }

        model.retry(messageId: "m1")

        let db = env.db
        await waitUntil(4) {
            let state = try? db.read { try MessageRecord.fetchOne($0, key: "m1")?.bodyState }
            return state == 0
        }
        try InvariantChecks.assertAll(db)
    }

    // MARK: - Mark read, load, toolbar

    @MainActor
    func testMarkReadOnOpen() async throws {
        try seed([message("m1", offset: 1_000, unread: true)])
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.appeared()

        XCTAssertTrue(model.didMarkRead)
        await waitUntil { self.model.isUnread == false }
        let ops = try await env.db.read { try OutboxRepository.activeModifies($0) }
        XCTAssertEqual(ops.count, 1)
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor
    func testMarkReadOnOpenDisabled() async throws {
        env.settings.update { $0.markReadOnOpen = false }
        try seed([message("m1", offset: 1_000, unread: true)])
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.appeared()

        XCTAssertFalse(model.didMarkRead)
        XCTAssertTrue(model.isUnread)
        let ops = try await env.db.read { try OutboxRepository.activeModifies($0) }
        XCTAssertTrue(ops.isEmpty)
    }

    @MainActor
    func testMarkReadSkippedWhenAlreadyRead() async throws {
        try seed([message("m1", offset: 1_000)])
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.appeared()

        XCTAssertFalse(model.didMarkRead)
        let ops = try await env.db.read { try OutboxRepository.activeModifies($0) }
        XCTAssertTrue(ops.isEmpty)
    }

    @MainActor
    func testAppearedIsIdempotent() async throws {
        try seed([message("m1", offset: 1_000, unread: true)])
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.appeared()
        await model.appeared()

        let ops = try await env.db.read { try OutboxRepository.activeModifies($0) }
        XCTAssertEqual(ops.count, 1)
    }

    @MainActor
    func testEnsureThreadLoadedErrorShowsNotice() async throws {
        try seed([message("m1", offset: 1_000)])
        try await env.db.write { try ThreadRepository.markComplete($0, threadId: "t1", complete: false) }
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.appeared()

        XCTAssertEqual(model.errorText, "You're offline — showing what's cached.")
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.document.contains("data-id=\"m1\""))
    }

    @MainActor
    func testRetryLoadClearsError() async throws {
        try seed([message("m1", offset: 1_000)])
        try await env.db.write { try ThreadRepository.markComplete($0, threadId: "t1", complete: false) }
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")
        await model.appeared()
        XCTAssertNotNil(model.errorText)

        StubURLProtocol.reset()
        StubURLProtocol.routes([
            (
                "GET", "/gmail/v1/users/me/threads/t1",
                [
                    .json(
                        200,
                        JSONFixtures.thread(
                            id: "t1",
                            messages: [
                                JSONFixtures.fullMessage(
                                    id: "m1", thread: "t1", labels: ["INBOX"], date: seedNow + 1_000,
                                    html: "<p>Body</p>", text: nil)
                            ]))
                ]
            )
        ])

        await model.retryLoad()

        XCTAssertNil(model.errorText)
        await waitUntil(4) { self.model.document.contains("Body") }
    }

    @MainActor
    func testArchiveEnqueuesAndDismisses() async throws {
        try seed([message("m1", offset: 1_000)])
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.archive()

        XCTAssertTrue(model.shouldDismiss)
        XCTAssertEqual(model.lastActionId, 1)
        let inInbox = try await env.db.read { try ThreadRecord.fetchOne($0, key: "t1")?.inInbox }
        XCTAssertEqual(inInbox, false)
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor
    func testToggleReadMarksUnreadThenRead() async throws {
        try seed([message("m1", offset: 1_000)])
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        model = ThreadModel(env: env, threadId: "t1")

        await model.toggleRead()
        await waitUntil { self.model.isUnread }
        await model.toggleRead()
        await waitUntil { !self.model.isUnread }

        XCTAssertEqual(model.lastActionId, 2)
        XCTAssertFalse(model.shouldDismiss)
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor
    func testComposeInputs() throws {
        try seed([message("m1", offset: 1_000), message("m2", offset: 2_000)])
        model = ThreadModel(env: env, threadId: "t1")

        XCTAssertTrue(model.canCompose)
        model.replyAll()
        XCTAssertEqual(model.composeInput, .fromMessage(mode: .replyAll, threadId: "t1", messageId: "m2"))
        model.forward()
        XCTAssertEqual(model.composeInput, .fromMessage(mode: .forward, threadId: "t1", messageId: "m2"))

        model.stop()
        env = AppEnvironment(testing: true)
        model = ThreadModel(env: env, threadId: "gone")
        XCTAssertFalse(model.canCompose)
        model.replyAll()
        model.forward()
        XCTAssertNil(model.composeInput)
    }

    @MainActor
    func testHandleRoutesEveryWebMessage() async throws {
        try seed([message("m1", offset: 1_000)])
        try storeBody("m1", html: "<p>Hello</p>")
        model = ThreadModel(env: env, threadId: "t1")
        let captured = URLBox()
        model.attachWeb(openURL: { captured.url = $0 })
        defer { model.detachWeb() }

        let wasExpanded = model.expanded.contains("m1")
        model.handle(.toggle(messageId: "m1"))
        XCTAssertNotEqual(model.expanded.contains("m1"), wasExpanded)

        model.handle(.loadImages(messageId: "m1"))
        XCTAssertTrue(model.imagesAllowedIds.contains("m1"))

        model.handle(.link(URL(string: "https://x")!))
        XCTAssertEqual(captured.url?.absoluteString, "https://x")

        model.handle(.retry(messageId: "m1"))
    }

    @MainActor
    func testThemeChangeRebuilds() throws {
        try seed([message("m1", offset: 1_000)])
        try storeBody("m1", html: "<p>Hello</p>")
        model = ThreadModel(env: env, threadId: "t1")

        // Both schemes are always emitted, so following the system changes nothing.
        model.systemSchemeChanged(.dark)
        XCTAssertEqual(model.revision, 1)

        env.theme.choice = .dark
        model.systemSchemeChanged(.dark)
        XCTAssertEqual(model.revision, 2)
        XCTAssertTrue(model.document.hasPrefix("<!doctype html><html data-theme=\"dark\">"))
    }

    @MainActor
    func testContentSizeChangeForcesReload() throws {
        try seed([message("m1", offset: 1_000)])
        try storeBody("m1", html: "<p>Hello</p>")
        model = ThreadModel(env: env, threadId: "t1")
        let before = model.document

        model.contentSizeChanged()

        XCTAssertEqual(model.revision, 2)
        XCTAssertEqual(model.document, before)
    }

    @MainActor
    func testDetachWebOnlyByOwner() throws {
        try seed([message("m1", offset: 1_000)])
        let first = ThreadModel(env: env, threadId: "t1")
        let second = ThreadModel(env: env, threadId: "t1")
        defer {
            first.stop()
            second.stop()
        }

        first.attachWeb(openURL: { _ in })
        second.attachWeb(openURL: { _ in })
        first.detachWeb()  // no longer the owner: must leave the newer screen's handlers alone

        let wasExpanded = second.expanded.contains("m1")
        env.webBridge.onMessage(.toggle(messageId: "m1"))
        XCTAssertNotEqual(second.expanded.contains("m1"), wasExpanded)

        second.detachWeb()
        let afterDetach = second.expanded.contains("m1")
        env.webBridge.onMessage(.toggle(messageId: "m1"))
        XCTAssertEqual(second.expanded.contains("m1"), afterDetach)
    }

    @MainActor
    func testStopCancelsObservation() async throws {
        try seed([message("m1", offset: 1_000)])
        model = ThreadModel(env: env, threadId: "t1")

        model.stop()
        try storeBody("m1", html: "<p>Hello</p>")
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(model.revision, 1)
    }
}

/// Captures the URL handed to `openURL` from a closure the model owns.
@MainActor private final class URLBox {
    var url: URL?

    // MARK: - Web view helpers (patch path)

    /// Puts the model's current document into the pooled web view and waits for the load, so
    /// `webHost.loadedRevision == model.revision` and patches are possible.
    @MainActor
    private func loadIntoWebView() async throws {
        let finished = expectation(description: "document loaded")
        finished.assertForOverFulfill = false
        env.webHost.onDocumentLoaded = { finished.fulfill() }
        env.webHost.load(document: model.document, revision: model.revision)
        await fulfillment(of: [finished], timeout: 5)
        env.webHost.onDocumentLoaded = nil
    }

    @MainActor
    private func webViewHTML() async -> String {
        let result = try? await env.webHost.webView.evaluateJavaScript("document.body.innerHTML")
        return result as? String ?? ""
    }

}
