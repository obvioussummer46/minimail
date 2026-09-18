import GRDB
import MailCore
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import minimail

/// Spec 14 §3.4 / §4.4. Architecture §13.1's hosting smoke layer: every screen instantiated in a `UIHostingController`
/// against a seeded in-memory database, asserting observable model state and that hosting performs no network.
nonisolated final class SmokeTests: XCTestCase {

    private var env: AppEnvironment!
    private var seed: TestDatabase.SmokeSeed!
    private var models: [AnyObject] = []
    private var windows: [UIWindow] = []

    @MainActor
    override func setUp() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.routes([])
        AppEnvironment.testURLProtocolClasses = [StubURLProtocol.self]
        env = AppEnvironment(testing: true)
        seed = try TestDatabase.seedSmoke(env.db)
    }

    @MainActor
    override func tearDown() async throws {
        for m in models {
            (m as? InboxModel)?.stop()
            (m as? ThreadModel)?.stop()
            (m as? LabelsModel)?.stop()
        }
        models = []
        for w in windows { w.isHidden = true }
        windows = []
        await env.sync.cancelAll()
        await env.outbox.cancelAll()
        env = nil
        seed = nil
        AppEnvironment.testURLProtocolClasses = [OfflineURLProtocol.self]
        StubURLProtocol.reset()
    }

    @MainActor private func clock() -> Date { Date(timeIntervalSince1970: Double(seed.now) / 1000) }

    @MainActor
    private func host(_ view: some View, settle: TimeInterval = 0.3) -> UIHostingController<AnyView> {
        let vc = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        windows.append(window)  // retained so SwiftUI keeps the backing hierarchy alive
        vc.view.layoutIfNeeded()
        if settle > 0 { RunLoop.main.run(until: Date() + settle) }
        return vc
    }

    @MainActor
    private func firstDescendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = firstDescendant(type, in: sub) { return found }
        }
        return nil
    }

    @MainActor
    private func withEnv(_ view: some View) -> some View {
        view.environment(env).environment(env.theme).environment(env.settings)
    }

    // MARK: - hosting

    @MainActor
    func testRootViewHosts() async throws {
        let vc = host(withEnv(RootView()))
        // RootView (signed out → SignInScreen, a plain VStack) renders as one SwiftUI layer with no UIKit child
        // views, so assert it laid out in the window rather than counting subviews.
        XCTAssertNotEqual(vc.view.bounds.size, .zero)
    }

    @MainActor
    func testInboxScreenHostsSeededRows() async throws {
        let vc = host(withEnv(InboxScreen(scope: .inbox)))
        XCTAssertTrue(
            firstDescendant(UICollectionView.self, in: vc.view) != nil
                || firstDescendant(UITableView.self, in: vc.view) != nil)
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    @MainActor
    func testThreadScreenHostsWebView() async throws {
        let vc = host(withEnv(NavigationStack { ThreadScreen(threadId: seed.openThreadId) }), settle: 0.3)
        XCTAssertNotNil(firstDescendant(WKWebView.self, in: vc.view))
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    @MainActor
    func testComposeScreenHosts() async throws {
        let vc = host(
            withEnv(
                ComposeScreen(
                    input: .fromMessage(mode: .replyAll, threadId: seed.openThreadId, messageId: seed.newestMessageId)))
        )
        XCTAssertFalse(vc.view.subviews.isEmpty)
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    @MainActor
    func testLabelsScreenHosts() async throws {
        let vc = host(withEnv(LabelsScreen(onSelect: { _ in })))
        XCTAssertTrue(
            firstDescendant(UICollectionView.self, in: vc.view) != nil
                || firstDescendant(UITableView.self, in: vc.view) != nil)
    }

    @MainActor
    func testSettingsScreenHosts() async throws {
        let vc = host(withEnv(NavigationStack { SettingsScreen() }))
        XCTAssertFalse(vc.view.subviews.isEmpty)
    }

    // MARK: - observable model state

    @MainActor
    func testInboxModelRowCount() async throws {
        let m = InboxModel(env: env, scope: .inbox, clock: clock)
        models.append(m)
        XCTAssertEqual(m.rows.count, 3)
        XCTAssertEqual(m.rows.map(\.id), seed.threadIds)
        XCTAssertEqual(m.rows[0].subject, seed.subject)
        XCTAssertTrue(m.rows[0].isUnread)
        XCTAssertEqual(m.rows[0].messageCount, 2)
        XCTAssertTrue(m.rows[0].hasAttachments)
        XCTAssertEqual(m.rows[0].chips.map(\.id), ["Label_12"])
        XCTAssertEqual(m.inboxUnreadCount, 2)
        XCTAssertNil(m.emptyState)
        XCTAssertNil(m.banner)
    }

    @MainActor
    func testThreadDocumentContainsSeededSubject() async throws {
        let m = ThreadModel(env: env, threadId: seed.openThreadId, clock: clock)
        models.append(m)
        XCTAssertEqual(m.detail?.messages.count, 2)
        XCTAssertGreaterThanOrEqual(m.revision, 1)
        XCTAssertTrue(m.document.contains(seed.subject))
        XCTAssertTrue(m.document.contains(seed.bodyMarker))
        XCTAssertTrue(m.document.contains("data-id=\"\(seed.newestMessageId)\""))
        XCTAssertTrue(m.document.contains("report.pdf"))
        XCTAssertEqual(m.title, seed.subject)
        XCTAssertTrue(m.isUnread)
        XCTAssertEqual(m.newestMessageId, seed.newestMessageId)
        XCTAssertTrue(m.document.hasPrefix("<!doctype html>"))
    }

    @MainActor
    func testComposeReplyAllPrefillsRecipients() async throws {
        let m = ComposeModel(
            env: env,
            input: .fromMessage(mode: .replyAll, threadId: seed.openThreadId, messageId: seed.newestMessageId))
        models.append(m)
        await m.makeDraft()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertTrue(m.toText.contains(seed.sender.addr))
        XCTAssertTrue(m.ccText.contains(seed.ccRecipient.addr))
        XCTAssertFalse(m.toText.contains(seed.selfAddress))
        XCTAssertFalse(m.ccText.contains(seed.selfAddress))
        XCTAssertEqual(m.subject, "Re: Quarterly report")
        XCTAssertTrue(m.quoteReady)
        XCTAssertTrue(m.quotePreview.contains(seed.bodyMarker))
        XCTAssertTrue(m.canSend)
        XCTAssertTrue(m.attachments.isEmpty)
    }

    @MainActor
    func testComposeForwardPrefillsAttachment() async throws {
        let m = ComposeModel(
            env: env,
            input: .fromMessage(mode: .forward, threadId: seed.openThreadId, messageId: seed.newestMessageId))
        models.append(m)
        await m.makeDraft()
        XCTAssertEqual(m.subject, "Fwd: Re: Quarterly report")
        XCTAssertTrue(m.toText.isEmpty)
        XCTAssertTrue(m.ccText.isEmpty)
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.attachments[0].ref.filename, "report.pdf")
        XCTAssertTrue(m.attachments[0].included)
        XCTAssertFalse(m.canSend)
        XCTAssertEqual(m.attachmentBytes, 125)
    }

    // MARK: - discipline

    @MainActor
    func testHostingPerformsNoNetwork() async throws {
        _ = host(withEnv(InboxScreen(scope: .inbox)))
        _ = host(withEnv(NavigationStack { ThreadScreen(threadId: seed.openThreadId) }))
        _ = host(
            withEnv(
                ComposeScreen(
                    input: .fromMessage(mode: .replyAll, threadId: seed.openThreadId, messageId: seed.newestMessageId)))
        )
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    @MainActor
    func testInvariantsHoldOnSmokeSeed() async throws {
        try InvariantChecks.assertAll(env.db)
        let unread = try await env.db.read { try Queries.inboxUnreadThreadCount($0) }
        XCTAssertEqual(unread, 2)
        let counts = try await env.db.read { try Queries.outboxCounts($0) }
        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(counts.failed, 0)
    }
}
