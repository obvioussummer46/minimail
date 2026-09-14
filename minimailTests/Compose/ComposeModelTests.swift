import GRDB
import MailCore
import MailHTML
import XCTest

@testable import minimail

nonisolated final class ComposeModelTests: XCTestCase {
    private var env: AppEnvironment!
    private var model: ComposeModel!
    private let seedNow: Int64 = 1_757_500_000_000
    private let fixedUUID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
        try await env.db.write { db in
            try SyncStateRepository.set(db, .accountEmail, "max.mustermann@example.com")
            try SyncStateRepository.set(db, .displayName, "Max Mustermann")
            try SyncStateRepository.set(
                db, .selfAddresses, #"["m.mustermann@example.com","max.mustermann@example.com"]"#)
        }
    }

    @MainActor override func tearDown() async throws {
        model?.stop()
        model = nil
        env = nil
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

    // MARK: - Fixtures

    private static let alice = Mailbox(name: "Alice", addr: "alice@example.com")
    private static let bob = Mailbox(name: "Bob", addr: "bob@example.com")
    private static let carol = Mailbox(name: nil, addr: "carol@partner.example")
    private static let max = Mailbox(name: "Max", addr: "max.mustermann@example.com")

    private static let quoteHTML =
        "<div class=\"mm-plaintext\"><div>Hallo Max,</div></div>"
        + "<img data-src=\"https://t.example/p.gif\" src=\"\(ThreadDocument.placeholderGIF)\" class=\"mm-remote\">"
        + "<img src=\"minimail-cid://m1/ii_logo\">"
    private static let quoteText = "Hallo Max,\n\nist das Angebot noch aktuell?"

    @MainActor
    private func seedMessage(
        subject: String = "Angebot", snippet: String = "Kurzfassung", from: Mailbox = ComposeModelTests.alice,
        to: [Mailbox] = [ComposeModelTests.max, ComposeModelTests.bob],
        cc: [Mailbox] = [ComposeModelTests.carol]
    ) throws {
        try TestDatabase.seed(
            env.db,
            [
                TestDatabase.parsed(
                    id: "m1", threadId: "t1", internalDate: seedNow, labels: ["INBOX"], from: from, to: to, cc: cc,
                    subject: subject, snippet: snippet, messageID: "<CAF=abc123@mail.gmail.com>",
                    inReplyTo: "<CAF=root@mail.gmail.com>", references: ["<CAF=root@mail.gmail.com>"])
            ],
            selfAddresses: ["max.mustermann@example.com", "m.mustermann@example.com"])
    }

    @MainActor
    private func storeOriginalBody(
        html: String = ComposeModelTests.quoteHTML, text: String? = ComposeModelTests.quoteText,
        attachments: [ParsedAttachment] = ComposeModelTests.parts, referenced: Set<String> = ["ii_logo"]
    ) throws {
        try env.db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: html, hasRemoteImages: true, darkStrategy: .plain, referencedContentIDs: referenced),
                text: text, attachments: attachments, referenced: referenced, sanitizerVersion: 1, now: seedNow)
            try ThreadRepository.recomputeAggregates(
                db, threadIds: ["t1"], selfAddresses: try SyncStateRepository.selfAddresses(db))
        }
    }

    private static let parts: [ParsedAttachment] = [
        ParsedAttachment(
            partId: "2", filename: "Angebot.pdf", mimeType: "application/pdf", size: 184_213, contentId: nil,
            attachmentId: "att2", inlineData: nil),
        ParsedAttachment(
            partId: "3", filename: "logo.png", mimeType: "image/png", size: 4096, contentId: "ii_logo",
            attachmentId: "att3", inlineData: nil),
    ]

    @MainActor
    private func seedOriginal() throws {
        try seedMessage()
        try storeOriginalBody()
    }

    @MainActor
    private func makeModel(_ mode: ComposeMode = .replyAll, messageId: String = "m1", threadId: String = "t1") async {
        model = ComposeModel(
            env: env, input: .fromMessage(mode: mode, threadId: threadId, messageId: messageId),
            uuid: { [fixedUUID] in fixedUUID })
        await model.makeDraft()
    }

    // MARK: - Prefill

    @MainActor
    func testReplyAllPrefill() async throws {
        try seedOriginal()
        await makeModel()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.toText, "Alice <alice@example.com>, Bob <bob@example.com>")
        XCTAssertEqual(model.ccText, "carol@partner.example")
        XCTAssertEqual(model.subject, "Re: Angebot")
        XCTAssertEqual(model.title, "Reply All")
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertTrue(model.quoteReady)
        XCTAssertTrue(model.canSend)
    }

    @MainActor
    func testReplyAllThreadingHeaders() async throws {
        try seedOriginal()
        await makeModel()
        let job = try XCTUnwrap(model.makeJob())
        XCTAssertEqual(job.inReplyTo, "<CAF=abc123@mail.gmail.com>")
        XCTAssertEqual(job.references, ["<CAF=root@mail.gmail.com>", "<CAF=abc123@mail.gmail.com>"])
        XCTAssertEqual(job.threadId, "t1")
        XCTAssertEqual(job.originalMessageId, "m1")
    }

    @MainActor
    func testMessageIDIsFrozenAndUsesAccountDomain() async throws {
        try seedOriginal()
        await makeModel()
        let first = try XCTUnwrap(model.makeJob()).messageID
        XCTAssertEqual(first, "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>")
        model.body = "x"
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).messageID, first)
    }

    @MainActor
    func testSelfReplyKeepsOriginalRecipients() async throws {
        try seedMessage(from: ComposeModelTests.max, to: [ComposeModelTests.alice, ComposeModelTests.bob])
        try storeOriginalBody()
        await makeModel()
        XCTAssertEqual(model.toText, "Alice <alice@example.com>, Bob <bob@example.com>")
        XCTAssertEqual(model.ccText, "carol@partner.example")
    }

    @MainActor
    func testSubjectPrefixNotDoubled() async throws {
        try seedMessage(subject: "Re: Angebot")
        try storeOriginalBody()
        await makeModel()
        XCTAssertEqual(model.subject, "Re: Angebot")
        model.stop()
        await makeModel(.forward)
        XCTAssertEqual(model.subject, "Fwd: Re: Angebot")
    }

    @MainActor
    func testForwardPrefill() async throws {
        try seedOriginal()
        await makeModel(.forward)
        XCTAssertEqual(model.toText, "")
        XCTAssertEqual(model.ccText, "")
        XCTAssertEqual(model.subject, "Fwd: Angebot")
        XCTAssertEqual(model.title, "Forward")
        XCTAssertEqual(model.attachments.map(\.id), ["2", "3"])
        XCTAssertTrue(model.attachments[0].included)
        XCTAssertTrue(model.attachments[1].isInline)
        XCTAssertFalse(model.attachments[1].included)
        XCTAssertNil(model.makeJob())
        XCTAssertEqual(model.validation, "Add at least one recipient.")
    }

    @MainActor
    func testForwardKeepsThreadingHeaders() async throws {
        try seedOriginal()
        await makeModel(.forward)
        model.toText = "bob@example.com"
        let job = try XCTUnwrap(model.makeJob())
        XCTAssertEqual(job.inReplyTo, "<CAF=abc123@mail.gmail.com>")
        XCTAssertEqual(job.references, ["<CAF=root@mail.gmail.com>", "<CAF=abc123@mail.gmail.com>"])
        XCTAssertEqual(job.threadId, "t1")
    }

    // MARK: - Quote snapshot

    @MainActor
    func testQuoteSnapshotStripsRemoteAndCIDImages() async throws {
        try seedOriginal()
        await makeModel()
        let quote = try XCTUnwrap(model.makeJob()).quoteSource
        let html = try XCTUnwrap(quote.html)
        XCTAssertTrue(html.contains("https://t.example/p.gif"))
        XCTAssertFalse(html.contains("minimail-cid:"))
        XCTAssertFalse(html.contains("mm-plaintext"))
        XCTAssertFalse(html.contains("mm-remote"))
        XCTAssertEqual(quote.text, ComposeModelTests.quoteText)
        XCTAssertEqual(quote.subject, "Angebot")
        XCTAssertEqual(quote.author, ComposeModelTests.alice)
        XCTAssertEqual(quote.date, Date(timeIntervalSince1970: Double(seedNow) / 1000))
    }

    @MainActor
    func testQuotePreviewIsQuoteText() async throws {
        try seedOriginal()
        await makeModel()
        XCTAssertEqual(model.quotePreview, ComposeModelTests.quoteText)
    }

    @MainActor
    func testQuoteWaitsForBodyThenEnables() async throws {
        try seedMessage()
        await makeModel()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.quoteReady)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.quotePreview, "")

        try storeOriginalBody(html: "<div>Hallo Max,</div>", text: "Hallo Max,", attachments: [], referenced: [])

        await waitUntil { self.model.quoteReady }
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).quoteSource.text, "Hallo Max,")
    }

    @MainActor
    func testForwardAttachmentsAppearWithLateBody() async throws {
        try seedMessage()
        await makeModel(.forward)
        model.toText = "bob@example.com"
        XCTAssertTrue(model.attachments.isEmpty)

        try storeOriginalBody()

        await waitUntil { self.model.attachments.count == 2 }
        XCTAssertTrue(model.attachments[0].included)
        XCTAssertTrue(model.attachments[1].isInline)
    }

    @MainActor
    func testBodyUnavailableUsesSnippet() async throws {
        try seedMessage()
        try await env.db.write { try BodyRepository.markUnavailable($0, messageId: "m1") }
        await makeModel()
        XCTAssertTrue(model.quoteReady)
        let quote = try XCTUnwrap(model.makeJob()).quoteSource
        XCTAssertNil(quote.html)
        XCTAssertEqual(quote.text, "Kurzfassung")
        XCTAssertTrue(model.canSend)
    }

    @MainActor
    func testSnapshotFrozenAfterReady() async throws {
        try seedOriginal()
        await makeModel()
        let html = try XCTUnwrap(model.makeJob()).quoteSource.html

        try storeOriginalBody(html: "<div>Ganz anderer Text</div>", text: "Anders", attachments: [], referenced: [])

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).quoteSource.html, html)
    }

    @MainActor
    func testStopCancelsBodyObservation() async throws {
        try seedMessage()
        await makeModel()
        model.stop()

        try storeOriginalBody(html: "<div>Hallo</div>", text: "Hallo", attachments: [], referenced: [])

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.quoteReady)
    }

    // MARK: - Unavailable / idempotence

    @MainActor
    func testUnknownMessageIsUnavailable() async throws {
        try seedOriginal()
        await makeModel(.replyAll, messageId: "nope")
        XCTAssertEqual(model.phase, .unavailable("This message is no longer available."))
        XCTAssertFalse(model.canSend)
        XCTAssertNil(model.makeJob())
        XCTAssertFalse(model.hasContent)
    }

    @MainActor
    func testUnknownThreadIsUnavailable() async throws {
        await makeModel(.replyAll, threadId: "tX")
        XCTAssertEqual(model.phase, .unavailable("This message is no longer available."))
        XCTAssertFalse(model.canSend)
        XCTAssertNil(model.makeJob())
        XCTAssertFalse(model.hasContent)
    }

    @MainActor
    func testMakeDraftIsIdempotent() async throws {
        try seedOriginal()
        await makeModel()
        model.toText = "x@y.de"
        await model.makeDraft()
        XCTAssertEqual(model.toText, "x@y.de")
    }

    // MARK: - Validation and attachments

    @MainActor
    func testValidationMatrix() async throws {
        try seedOriginal()
        await makeModel()
        model.toText = ""
        XCTAssertEqual(model.validation, "Add at least one recipient.")
        XCTAssertFalse(model.canSend)
        model.toText = "not-an-address"
        XCTAssertEqual(model.validation, "Not a valid address: not-an-address")
        model.toText = "a@b.de"
        XCTAssertNil(model.validation)
        XCTAssertTrue(model.canSend)
        model.ccText = "x@"
        XCTAssertEqual(model.validation, "Not a valid address: x@")
        XCTAssertFalse(model.canSend)
        model.ccText = ""
        XCTAssertNil(model.validation)
    }

    @MainActor
    func testAttachmentBudgetBlocksSend() async throws {
        try seedMessage()
        try storeOriginalBody(
            attachments: [
                ParsedAttachment(
                    partId: "2", filename: "big.bin", mimeType: "application/octet-stream", size: 12_000_000,
                    contentId: nil, attachmentId: "att2", inlineData: nil),
                ParsedAttachment(
                    partId: "3", filename: "bigger.bin", mimeType: "application/octet-stream", size: 9_000_000,
                    contentId: nil, attachmentId: "att3", inlineData: nil),
            ], referenced: [])
        await makeModel(.forward)
        model.toText = "bob@example.com"
        XCTAssertEqual(model.attachmentBytes, 21_000_000)
        XCTAssertFalse(model.canSend)
        let used = Formatters.bytes(21_000_000)
        let limit = Formatters.bytes(ComposeModel.maxAttachmentBytes)
        let expected = "Attachments are \(used) — the limit is \(limit). Turn some off to send."
        XCTAssertEqual(model.attachmentFooter, expected)
        model.setAttachment(partId: "3", included: false)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.attachmentFooter, "1 attachment · \(Formatters.bytes(12_000_000))")
    }

    @MainActor
    func testAttachmentTogglesReachTheJob() async throws {
        try seedOriginal()
        await makeModel(.forward)
        model.toText = "bob@example.com"
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).attachments.map(\.partId), ["2"])
        model.setAttachment(partId: "3", included: true)
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).attachments.map(\.partId), ["2", "3"])
        model.setAttachment(partId: "2", included: false)
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).attachments.map(\.partId), ["3"])
        model.setAttachment(partId: "99", included: true)
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).attachments.map(\.partId), ["3"])
    }

    @MainActor
    func testIncludeSignatureFollowsSettings() async throws {
        try seedOriginal()
        env.settings.update { $0.signatureEnabled = false }
        await makeModel()
        XCTAssertFalse(model.includeSignature)
        XCTAssertEqual(try XCTUnwrap(model.makeJob()).includeSignature, false)
        model.stop()
        env.settings.update { $0.signatureEnabled = true }
        await makeModel()
        XCTAssertTrue(model.includeSignature)
    }

    @MainActor
    func testHasContentRules() async throws {
        try seedOriginal()
        await makeModel()
        XCTAssertFalse(model.hasContent)
        model.body = "  \n "
        XCTAssertFalse(model.hasContent)
        model.body = "Hi"
        XCTAssertTrue(model.hasContent)
        model.body = ""
        model.subject = "Anderes"
        XCTAssertTrue(model.hasContent)
        model.subject = "Re: Angebot"
        model.toText += ", dave@example.com"
        XCTAssertTrue(model.hasContent)
    }

    // MARK: - Send

    @MainActor
    func testSendEnqueuesOneOutboxRow() async throws {
        try seedOriginal()
        await makeModel()
        model.body = "Ja, passt."
        let expected = try XCTUnwrap(model.makeJob())

        XCTAssertTrue(model.send())
        XCTAssertEqual(model.sendFeedbackId, 1)
        XCTAssertTrue(model.isSending)

        await waitUntil { (try? self.env.db.read { try Queries.outboxCounts($0).pending }) == 1 }
        // `XCTUnwrap` takes an autoclosure, which cannot be async: the read has to be awaited first.
        let fetched = try await env.db.read { try OutboxRecord.fetchAll($0).first }
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.kind, .send)
        XCTAssertEqual(row.transmitState, .notSent)
        XCTAssertEqual(row.rfc822MessageId, "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>")
        XCTAssertEqual(row.sendJob, expected)
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor
    func testSendRejectedWhenInvalid() async throws {
        try seedOriginal()
        await makeModel()
        model.toText = ""
        XCTAssertFalse(model.send())
        XCTAssertEqual(model.sendFeedbackId, 0)
        try await Task.sleep(for: .milliseconds(300))
        let pending = try await env.db.read { try Queries.outboxCounts($0).pending }
        XCTAssertEqual(pending, 0)
    }

    @MainActor
    func testSecondSendIsIgnored() async throws {
        try seedOriginal()
        await makeModel()
        model.body = "Ja, passt."
        XCTAssertTrue(model.send())
        XCTAssertFalse(model.send())
        await waitUntil { (try? self.env.db.read { try Queries.outboxCounts($0).pending }) == 1 }
        try await Task.sleep(for: .milliseconds(200))
        let rows = try await env.db.read { try OutboxRecord.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Failed-send reopen

    private func failedJob() -> SendJob {
        SendJob(
            mode: .replyAll, originalMessageId: "m1", threadId: "t1",
            messageID: "<3F2504E0-4F89-41D3-9A0C-0305E82C3301@example.com>",
            to: [ComposeModelTests.bob], cc: [], subject: "Re: Angebot", typedText: "Erste Fassung",
            inReplyTo: "<CAF=abc123@mail.gmail.com>", references: ["<CAF=root@mail.gmail.com>"],
            quoteSource: QuoteSource(
                author: ComposeModelTests.alice, date: Date(timeIntervalSince1970: Double(seedNow) / 1000),
                subject: "Angebot", to: [], cc: [], html: "<div>Hallo</div>", text: "Hallo"),
            attachments: [
                ForwardAttachmentRef(
                    partId: "2", filename: "Angebot.pdf", mimeType: "application/pdf", size: 184_213,
                    attachmentId: "att2")
            ],
            includeSignature: false)
    }

    @MainActor
    private func seedFailedSend(_ job: SendJob) async throws -> Int64 {
        // `now` is copied out first: the write closure is `@Sendable` and `XCTestCase` is not `Sendable`.
        let now = seedNow
        return try await env.db.write { db -> Int64 in
            let id = try OutboxRepository.enqueueSend(db, job: job, now: now)
            try OutboxRepository.fail(db, opId: id, error: "Invalid recipient")
            return id
        }
    }

    @MainActor
    func testFailedSendPrefillFromJob() async throws {
        let job = failedJob()
        let id = try await seedFailedSend(job)
        model = ComposeModel(env: env, input: .failedSend(outboxId: id, job: job))

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.toText, "Bob <bob@example.com>")
        XCTAssertEqual(model.subject, "Re: Angebot")
        XCTAssertEqual(model.body, "Erste Fassung")
        XCTAssertTrue(model.quoteReady)
        XCTAssertEqual(model.quotePreview, "Hallo")
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertTrue(model.attachments[0].included)
        XCTAssertFalse(model.includeSignature)
        XCTAssertTrue(model.hasContent)
        XCTAssertTrue(model.canSend)

        await model.makeDraft()
        XCTAssertEqual(model.toText, "Bob <bob@example.com>")
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    func testFailedSendResendKeepsIdentityAndDeletesOldRow() async throws {
        let job = failedJob()
        let id = try await seedFailedSend(job)
        model = ComposeModel(env: env, input: .failedSend(outboxId: id, job: job))
        model.body = "Zweite Fassung"
        model.toText = "bob@example.com, carol@partner.example"

        XCTAssertTrue(model.send())

        await waitUntil { (try? self.env.db.read { try OutboxRecord.fetchOne($0, key: id) }) == nil }
        let rows = try await env.db.read { try OutboxRecord.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        let stored = try XCTUnwrap(rows.first?.sendJob)
        XCTAssertEqual(stored.messageID, job.messageID)
        XCTAssertEqual(stored.inReplyTo, job.inReplyTo)
        XCTAssertEqual(stored.references, job.references)
        XCTAssertEqual(stored.quoteSource, job.quoteSource)
        XCTAssertEqual(stored.typedText, "Zweite Fassung")
        XCTAssertEqual(stored.to.count, 2)
        try InvariantChecks.assertAll(env.db)
    }
}
