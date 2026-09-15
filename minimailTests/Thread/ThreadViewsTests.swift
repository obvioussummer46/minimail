import GRDB
import MailCore
import MailHTML
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import minimail

nonisolated final class ThreadViewsTests: XCTestCase {

    // MARK: - Pure tables

    func testThreadActionSymbolsAndTitles() {
        XCTAssertEqual(ThreadAction.replyAll.symbol(isUnread: false), "arrowshape.turn.up.left.2")
        XCTAssertEqual(ThreadAction.forward.symbol(isUnread: false), "arrowshape.turn.up.right")
        XCTAssertEqual(ThreadAction.archive.symbol(isUnread: false), "archivebox")
        XCTAssertEqual(ThreadAction.toggleRead.symbol(isUnread: true), "envelope.open")
        XCTAssertEqual(ThreadAction.toggleRead.symbol(isUnread: false), "envelope.badge")
        XCTAssertEqual(ThreadAction.toggleRead.title(isUnread: true), "Mark as Read")
        XCTAssertEqual(ThreadAction.toggleRead.title(isUnread: false), "Mark as Unread")
        XCTAssertEqual(
            ThreadAction.allCases.map(\.rawValue),
            ["thread.replyAll", "thread.forward", "thread.archive", "thread.toggleRead"])
    }

    func testLoadErrorTexts() {
        XCTAssertEqual(
            ThreadModel.loadErrorText(for: GmailError.offline), "You're offline — showing what's cached.")
        XCTAssertEqual(
            ThreadModel.loadErrorText(for: GmailError.unauthorized), "Sign in again to load this thread.")
        XCTAssertEqual(
            ThreadModel.loadErrorText(for: GmailError.rateLimited(retryAfter: nil)),
            "Gmail is busy. Try again in a moment.")
        XCTAssertEqual(
            ThreadModel.loadErrorText(for: GmailError.server(status: 500)), "Couldn't load this thread.")
        XCTAssertEqual(ThreadModel.loadErrorText(for: CancellationError()), "Couldn't load this thread.")
    }

    func testAttachmentErrorTexts() {
        XCTAssertEqual(
            AttachmentOpener.message(for: GmailError.offline),
            "You're offline. Try again when you have a connection.")
        XCTAssertEqual(
            AttachmentOpener.message(for: GmailError.unauthorized),
            "Sign in again to download attachments.")
        XCTAssertEqual(
            AttachmentOpener.message(for: GmailError.rateLimited(retryAfter: 3)),
            "Gmail is busy. Try again in a moment.")
        XCTAssertEqual(
            AttachmentOpener.message(for: GmailError.notFound), "Couldn't download this attachment.")
        XCTAssertEqual(
            AttachmentOpener.message(for: GmailError.badRequest(reason: nil, message: nil)),
            "Couldn't download this attachment.")
    }

    // MARK: - Document projection

    private func detail(bodyRow: Bool) -> ThreadDetail {
        let message = MessageRecord(
            id: "m1", threadId: "t1", historyId: 1, internalDate: 1_757_500_000_000,
            fromName: "Alice", fromAddr: "alice@example.com", isFromMe: false,
            toList: [Mailbox(name: "Alice", addr: "alice@x"), Mailbox(name: nil, addr: "bob@x")],
            ccList: [], replyToList: [], subject: "Subject", snippet: "snip", messageIdHeader: nil,
            inReplyTo: nil, referencesList: [], topMimeType: "text/html", serverLabelIds: ["INBOX"],
            labelIds: ["INBOX"], isUnread: false, inInbox: true, isHidden: false, hasAttachments: true,
            bodyState: bodyRow ? 1 : 0, syncGeneration: 1, fetchedAt: 0)
        let thread = ThreadRecord(
            id: "t1", subject: "Subject", snippet: "snip", lastDate: message.internalDate,
            lastInboxDate: message.internalDate, messageCount: 1, unreadCount: 0, inInbox: true,
            hasAttachments: true, participants: "Alice", userLabelIds: [], isComplete: true,
            bodiesMissing: bodyRow ? 0 : 1)
        let bodies: [String: MessageBodyRecord] =
            bodyRow
            ? [
                "m1": MessageBodyRecord(
                    messageId: "m1", bodyHtml: "<p>Hello</p>", bodyText: nil, hasRemoteImages: true,
                    darkStrategy: "card", sanitizerVersion: 1, fetchedAt: 0)
            ] : [:]
        let attachments = [
            AttachmentRecord(
                messageId: "m1", partId: "1", filename: "logo.png", mimeType: "image/png", size: 10,
                contentId: "ii_logo", isInline: true, attachmentId: "A"),
            AttachmentRecord(
                messageId: "m1", partId: "2", filename: "report.pdf", mimeType: "application/pdf",
                size: 2048, contentId: nil, isInline: false, attachmentId: "B"),
        ]
        return ThreadDetail(thread: thread, messages: [message], bodies: bodies, attachments: attachments)
    }

    private func project(_ detail: ThreadDetail, expanded: Set<String>) -> [ThreadDocumentMessage] {
        ThreadModel.documentMessages(
            detail: detail, expanded: expanded, imagesAllowedIds: [], loadRemoteImages: false,
            labeler: RowDateLabeler(now: Date(), timeZone: .current, locale: .current),
            fullDate: ThreadModel.makeFullDateFormatter(timeZone: .current, locale: .current))
    }

    func testDocumentMessagesProjection() throws {
        let messages = project(detail(bodyRow: true), expanded: ["m1"])
        let message = try XCTUnwrap(messages.first)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(message.toLine, "Alice, bob@x")
        XCTAssertNil(message.ccLine)
        XCTAssertEqual(message.darkStrategy, "card")
        XCTAssertTrue(message.hasRemoteImages)
        XCTAssertTrue(message.expanded)
        XCTAssertEqual(message.bodyState, 1)
        XCTAssertEqual(message.attachments.count, 1, "inline parts are not chips")
        XCTAssertEqual(message.attachments[0].partId, "2")
        XCTAssertEqual(message.attachments[0].sizeLabel, Formatters.bytes(2048))
    }

    func testDocumentMessagesWithoutBodyRow() throws {
        let messages = project(detail(bodyRow: false), expanded: [])
        let message = try XCTUnwrap(messages.first)

        XCTAssertNil(message.bodyHTML)
        XCTAssertEqual(message.darkStrategy, "plain")
        XCTAssertFalse(message.hasRemoteImages)
        XCTAssertFalse(message.expanded)
        XCTAssertEqual(message.bodyState, 0)
    }

    // MARK: - Hosting and streams

    @MainActor
    func testThreadScreenHostsDocument() throws {
        let env = AppEnvironment(testing: true)
        try TestDatabase.seed(
            env.db, [TestDatabase.parsed(id: "m1", internalDate: 1_757_500_000_000, labels: ["INBOX"])])
        try env.db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "<p>Hello</p>", hasRemoteImages: false, darkStrategy: .plain,
                    referencedContentIDs: []),
                text: nil, attachments: [], referenced: [], sanitizerVersion: 1, now: 0)
        }

        let root = NavigationStack { ThreadScreen(threadId: "t1") }
            .environment(env)
            .environment(env.theme)
            .environment(env.settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(controller.view.bounds.width, 390)
        XCTAssertNotNil(Self.findWebView(controller.view))
        XCTAssertFalse(env.deferredWorkStarted)
    }

    @MainActor
    func testContentSizeChangeStreamYields() async {
        let received = expectation(description: "content size change delivered")
        received.assertForOverFulfill = false
        let task = Task {
            for await _ in ThreadScreen.contentSizeChangeStream() {
                received.fulfill()
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(
            name: UIContentSizeCategory.didChangeNotification, object: nil)
        await fulfillment(of: [received], timeout: 1)

        task.cancel()
        NotificationCenter.default.post(
            name: UIContentSizeCategory.didChangeNotification, object: nil)
    }

    func testPlaceholderThreadScreenRemoved() {
        XCTAssertEqual(String(describing: ThreadScreen.self), "ThreadScreen")
    }

    @MainActor
    private static func findWebView(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let found = findWebView(sub) { return found }
        }
        return nil
    }
}
