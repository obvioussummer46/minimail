import GRDB
import MailCore
import MailHTML
import SwiftUI
import UIKit
import XCTest

@testable import minimail

nonisolated final class ComposeViewsTests: XCTestCase {

    private static let fixedUUID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    private static let seedNow: Int64 = 1_757_500_000_000

    // MARK: - ComposeAddressField

    func testAddressFieldDisplay() {
        let display = ComposeAddressField.display
        XCTAssertEqual(display(Mailbox(name: nil, addr: "a@b.de")), "a@b.de")
        XCTAssertEqual(display(Mailbox(name: "  ", addr: "a@b.de")), "a@b.de")
        XCTAssertEqual(display(Mailbox(name: "Alice", addr: "a@b.de")), "Alice <a@b.de>")
        // No RFC 2047 encoding here, unlike `Mailbox.serialized()`: this text is read back by `AddressParser`.
        XCTAssertEqual(display(Mailbox(name: "Müller", addr: "a@b.de")), "Müller <a@b.de>")
        XCTAssertEqual(display(Mailbox(name: "Müller, Alice", addr: "a@b.de")), "\"Müller, Alice\" <a@b.de>")
        XCTAssertEqual(display(Mailbox(name: "He said \"hi\"", addr: "a@b.de")), "\"He said \\\"hi\\\"\" <a@b.de>")
    }

    func testAddressFieldRoundTrip() {
        let list = [
            Mailbox(name: "Müller, Alice", addr: "a@b.de"),
            Mailbox(name: nil, addr: "c@d.de"),
            Mailbox(name: "Bob", addr: "e@f.de"),
        ]
        let parsed = ComposeAddressField.parse(ComposeAddressField.text(for: list))
        XCTAssertEqual(parsed.mailboxes.map(\.addr), ["a@b.de", "c@d.de", "e@f.de"])
        XCTAssertEqual(parsed.mailboxes[0].name, "Müller, Alice")
        XCTAssertTrue(parsed.invalid.isEmpty)
    }

    func testAddressValidationMatrix() {
        for addr in ["a@b.de", "a.b+c@sub.example.co.uk", "user@localhost"] {
            XCTAssertTrue(ComposeAddressField.isValidAddrSpec(addr), addr)
        }
        let bad = ["", "a", "@b.de", "a@", "a@@b.de", "a b@c.de", "a@b..de", "a@.de", "a@de.", "<a@b.de>", "a,b@c.de"]
        for addr in bad {
            XCTAssertFalse(ComposeAddressField.isValidAddrSpec(addr), addr)
        }
    }

    func testParseSplitsAndFlags() {
        let parsed = ComposeAddressField.parse("Alice <a@b.de>, junk, c@d.de")
        XCTAssertEqual(parsed.mailboxes.map(\.addr), ["a@b.de", "c@d.de"])
        XCTAssertEqual(parsed.invalid, ["junk"])
        let blank = ComposeAddressField.parse("   ")
        XCTAssertTrue(blank.mailboxes.isEmpty)
        XCTAssertTrue(blank.invalid.isEmpty)
    }

    func testAttachmentItemSizeLabel() {
        XCTAssertEqual(Self.item(size: 184_213).sizeLabel, Formatters.bytes(184_213))
        XCTAssertEqual(Self.item(size: 0).sizeLabel, Formatters.bytes(0))
    }

    private static func item(size: Int) -> ComposeAttachmentItem {
        ComposeAttachmentItem(
            ref: ForwardAttachmentRef(
                partId: "2", filename: "Angebot.pdf", mimeType: "application/pdf", size: size, attachmentId: "att2"),
            isInline: false, included: true)
    }

    // MARK: - ComposeDraftBuilder

    private static let identity = SelfIdentity(
        primary: Mailbox(name: "Max Mustermann", addr: "max.mustermann@example.com"),
        allAddresses: ["max.mustermann@example.com", "m.mustermann@example.com"])

    private static func record(bodyState: Int = 0) -> MessageRecord {
        MessageRecord(
            id: "m1", threadId: "t1", historyId: 1, internalDate: seedNow,
            fromName: "Alice", fromAddr: "alice@example.com", isFromMe: false,
            toList: [
                Mailbox(name: "Max", addr: "max.mustermann@example.com"), Mailbox(name: "Bob", addr: "bob@example.com"),
            ],
            ccList: [Mailbox(name: nil, addr: "carol@partner.example")], replyToList: [],
            subject: "Angebot", snippet: "Hallo Max,",
            messageIdHeader: "<CAF=abc123@mail.gmail.com>", inReplyTo: "<CAF=root@mail.gmail.com>",
            referencesList: ["<CAF=root@mail.gmail.com>"], topMimeType: "text/html",
            serverLabelIds: ["INBOX"], labelIds: ["INBOX"], isUnread: false, inInbox: true, isHidden: false,
            hasAttachments: false, bodyState: bodyState, syncGeneration: 1, fetchedAt: seedNow)
    }

    func testDraftBuilderReplyAll() {
        let draft = ComposeDraftBuilder.make(
            mode: .replyAll, original: Self.record(), body: nil, attachments: [], identity: Self.identity,
            uuid: Self.fixedUUID)
        XCTAssertEqual(draft.to.map(\.addr), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(draft.cc.map(\.addr), ["carol@partner.example"])
        XCTAssertEqual(draft.subject, "Re: Angebot")
        XCTAssertEqual(draft.messageID, "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>")
        XCTAssertTrue(draft.attachments.isEmpty)
        XCTAssertFalse(draft.quoteReady)
    }

    func testDraftBuilderForwardAttachments() {
        let body = MessageBodyRecord(
            messageId: "m1", bodyHtml: "<div>Hallo</div>", bodyText: "Hallo", hasRemoteImages: false,
            darkStrategy: "plain", sanitizerVersion: 1, fetchedAt: Self.seedNow)
        let records = [
            Self.attachment(partId: "1", filename: "a.pdf", isInline: false),
            Self.attachment(partId: "2", filename: "b.pdf", isInline: false),
            Self.attachment(partId: "3", filename: "logo.png", isInline: true),
        ]
        let draft = ComposeDraftBuilder.make(
            mode: .forward, original: Self.record(bodyState: 1), body: body, attachments: records,
            identity: Self.identity, uuid: Self.fixedUUID)
        XCTAssertTrue(draft.to.isEmpty)
        XCTAssertEqual(draft.subject, "Fwd: Angebot")
        XCTAssertEqual(draft.attachments.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(draft.attachments.map(\.included), [true, true, false])
        XCTAssertTrue(draft.quoteReady)
    }

    private static func attachment(partId: String, filename: String, isInline: Bool) -> AttachmentRecord {
        AttachmentRecord(
            messageId: "m1", partId: partId, filename: filename, mimeType: "application/pdf", size: 100,
            contentId: isInline ? "ii_logo" : nil, isInline: isInline, attachmentId: "att\(partId)")
    }

    func testDraftBuilderDomain() {
        XCTAssertEqual(ComposeDraftBuilder.domain(ofEmail: "max.mustermann@example.com"), "example.com")
        XCTAssertEqual(ComposeDraftBuilder.domain(ofEmail: "Max@example.com"), "example.com")
        XCTAssertEqual(ComposeDraftBuilder.domain(ofEmail: "broken"), "")
        XCTAssertTrue(MessageIDs.generate(domain: "", uuid: Self.fixedUUID).hasSuffix("@localhost>"))
    }

    // MARK: - Hosting smoke tests

    @MainActor
    func testComposeScreenHostsReplyAll() throws {
        let env = AppEnvironment(testing: true)
        try TestDatabase.seed(
            env.db,
            [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: Self.seedNow, labels: ["INBOX"])])
        try env.db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "<div>Hallo</div>", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []),
                text: "Hallo", attachments: [], referenced: [], sanitizerVersion: 1, now: Self.seedNow)
        }
        let (controller, window) = Self.host(
            ComposeScreen(input: .fromMessage(mode: .replyAll, threadId: "t1", messageId: "m1")), env: env)
        XCTAssertEqual(window.bounds.width, 390)
        XCTAssertFalse(controller.view.subviews.isEmpty)
        XCTAssertFalse(env.deferredWorkStarted)
    }

    @MainActor
    func testComposeScreenHostsFailedSend() {
        let env = AppEnvironment(testing: true)
        let job = SendJob(
            mode: .replyAll, originalMessageId: "m1", threadId: "t1", messageID: "<x@example.com>",
            to: [Mailbox(name: "Bob", addr: "bob@example.com")], cc: [], subject: "Re: Angebot",
            typedText: "Erste Fassung", inReplyTo: nil, references: [],
            quoteSource: QuoteSource(
                author: nil, date: Date(timeIntervalSince1970: 0), subject: "Angebot", to: [], cc: [], html: nil,
                text: "Hallo"),
            attachments: [], includeSignature: false)
        let (controller, window) = Self.host(ComposeScreen(input: .failedSend(outboxId: 1, job: job)), env: env)
        XCTAssertEqual(window.bounds.width, 390)
        XCTAssertFalse(controller.view.subviews.isEmpty)
    }

    @MainActor
    func testComposeScreenHostsUnavailable() {
        let env = AppEnvironment(testing: true)
        let (controller, window) = Self.host(
            ComposeScreen(input: .fromMessage(mode: .forward, threadId: "tX", messageId: "mX")), env: env)
        XCTAssertEqual(window.bounds.width, 390)
        XCTAssertFalse(controller.view.subviews.isEmpty)
    }

    /// The placeholder `struct ComposeScreen` is gone: this call resolves to `Features/Compose/ComposeScreen.swift`,
    /// which takes no `dismiss` of its own and renders a `NavigationStack` around a `Form`.
    @MainActor
    func testPlaceholderStructRemoved() {
        _ = ComposeScreen(input: .fromMessage(mode: .replyAll, threadId: "t", messageId: "m"))
    }

    /// Same shape as `ThreadViewsTests.testThreadScreenHostsDocument`: a real key window, then one run-loop turn
    /// so `.task` gets to run. The window is returned so the caller keeps it alive for the assertions.
    @MainActor
    private static func host(_ screen: ComposeScreen, env: AppEnvironment) -> (UIViewController, UIWindow) {
        let root =
            screen
            .environment(env)
            .environment(env.theme)
            .environment(env.settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (controller, window)
    }
}
