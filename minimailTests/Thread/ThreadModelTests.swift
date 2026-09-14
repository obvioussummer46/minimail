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
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        model?.stop()
        model = nil
        env = nil
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

    @MainActor
    func testBodyArrivalRebuildsAndBumpsRevision() async throws {
        try seed([message("m1", offset: 1_000)])
        model = ThreadModel(env: env, threadId: "t1")
        XCTAssertEqual(model.revision, 1)
        XCTAssertTrue(model.document.contains("Loading…"))

        try storeBody("m1", html: "<p>Hello</p>")

        await waitUntil { self.model.revision == 2 }
        XCTAssertTrue(model.document.contains("Hello"))
        XCTAssertFalse(model.document.contains("Loading…"))
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

        XCTAssertTrue(model.document.contains("src=\"https://x/m1.png\""))
        XCTAssertFalse(model.document.contains("src=\"https://x/m2.png\""))
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
}
