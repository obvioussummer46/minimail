import GRDB
import MailCore
import XCTest

@testable import minimail

/// Module 07 §7.6. The send path had never been executed before these: `Outbox.performSend` shipped with
/// `OutboxTests` covering only the modify path.
nonisolated final class SendTests: XCTestCase {

    /// Held so `tearDown` can quiesce it: `afterSend()` starts an unstructured `sync.run(.afterSend)` that
    /// outlives the test, and `StubURLProtocol`'s recorded list is global, so a leaked run shows up as another
    /// test's traffic.
    @MainActor private var live: SyncHarness?

    override func setUp() { super.setUp(); StubURLProtocol.reset() }

    @MainActor override func tearDown() async throws {
        if let live {
            await live.sync.cancelAll()
            await live.outbox.cancelAll()
        }
        live = nil
        StubURLProtocol.reset()
    }

    // MARK: - Fixtures

    private static let sendPath = "/gmail/v1/users/me/messages/send"
    private static let att1Path = "/gmail/v1/users/me/messages/a1/attachments/att1"
    private static let att2Path = "/gmail/v1/users/me/messages/a1/attachments/att2"
    private static let messagePath = "/gmail/v1/users/me/messages/a1"
    private static let listPath = "/gmail/v1/users/me/messages"
    private static let historyPath = "/gmail/v1/users/me/history"

    private static let sendResponse = Data(#"{"id":"sent1","threadId":"a1","labelIds":["SENT"]}"#.utf8)

    private func job(
        mode: ComposeMode = .forward, attachments: [ForwardAttachmentRef] = [SendTests.ref()],
        includeSignature: Bool = false, typedText: String = "Bitte weiterleiten."
    ) -> SendJob {
        SendJob(
            mode: mode, originalMessageId: "a1", threadId: "a1", messageID: "<new@example.com>",
            to: [Mailbox(name: "Bob", addr: "bob@example.com")], cc: [],
            subject: mode == .forward ? "Fwd: Angebot" : "Re: Angebot",
            typedText: typedText, inReplyTo: "<orig@example.com>", references: ["<root@example.com>"],
            quoteSource: QuoteSource(
                author: Mailbox(name: "Alice", addr: "alice@example.com"),
                date: Date(timeIntervalSince1970: 1_757_500_000), subject: "Angebot",
                to: [Mailbox(name: nil, addr: "me@example.com")], cc: [],
                html: "<div>Original</div>", text: "Original"),
            attachments: attachments, includeSignature: includeSignature)
    }

    private static func ref(
        partId: String = "1", attachmentId: String? = "att1", size: Int = 5, filename: String = "invoice.pdf"
    ) -> ForwardAttachmentRef {
        ForwardAttachmentRef(
            partId: partId, filename: filename, mimeType: "application/pdf", size: size, attachmentId: attachmentId)
    }

    /// `fullMessage` in the shared fixtures builds only text parts; the re-resolve path needs an attachment part.
    private static func messageWithAttachment(attachmentId: String) -> Data {
        Data(
            """
            {"id":"a1","threadId":"a1","labelIds":["INBOX"],"snippet":"snip","internalDate":"1757500000000",\
            "historyId":"1","payload":{"mimeType":"multipart/mixed",\
            "headers":[{"name":"From","value":"alice@example.com"}],"parts":[\
            {"partId":"0","mimeType":"text/plain","body":{"size":3,"data":"aGk="}},\
            {"partId":"1","mimeType":"application/pdf","filename":"invoice.pdf",\
            "body":{"size":5,"attachmentId":"\(attachmentId)"}}]}}
            """.utf8)
    }

    @MainActor
    private func harness() throws -> SyncHarness {
        let harness = try SyncHarness()
        try harness.seedSyncState(historyId: 1000)
        live = harness
        return harness
    }

    @MainActor
    private func enqueue(_ harness: SyncHarness, _ job: SendJob) throws -> Int64 {
        let now = Int64(harness.now.timeIntervalSince1970 * 1000)
        return try harness.db.write { try OutboxRepository.enqueueSend($0, job: job, now: now) }
    }

    // MARK: - Database helpers
    //
    // All of these are non-async on purpose: inside an `async` test body `db.read`/`db.write` resolve to GRDB's
    // async overloads, which need `await` and a `@Sendable` closure.

    @MainActor
    private func row(_ harness: SyncHarness, _ id: Int64) throws -> OutboxRecord? {
        try harness.db.read { try OutboxRecord.fetchOne($0, key: id) }
    }

    @MainActor
    private func markMaybeSent(_ harness: SyncHarness, _ id: Int64) throws {
        try harness.db.write { try OutboxRepository.setTransmitState($0, opId: id, .maybeSent) }
    }

    @MainActor
    private func markFailed(_ harness: SyncHarness, _ id: Int64) throws {
        try harness.db.write { try OutboxRepository.fail($0, opId: id, error: "Gmail server error") }
    }

    @MainActor
    private func failedSendCount(_ harness: SyncHarness) throws -> Int {
        try harness.db.read { try Queries.failedSends($0).count }
    }

    @MainActor
    private func seedAttachmentRow(_ harness: SyncHarness) throws {
        try harness.seed([msg("a1")])
        try harness.db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "a1", body: nil, text: nil,
                attachments: [
                    ParsedAttachment(
                        partId: "1", filename: "invoice.pdf", mimeType: "application/pdf", size: 5, contentId: nil,
                        attachmentId: "att1", inlineData: nil)
                ], referenced: [], sanitizerVersion: 1, now: 0)
        }
    }

    /// `SyncHarness.setSettings` feeds the engine's own snapshot closure; the signature reaches the MIME builder
    /// through `OutboxIdentitySource`, which reads the separate store the harness gave it.
    @MainActor
    private func setSignature(_ harness: SyncHarness, _ html: String) {
        harness.identity.settings.update {
            $0.signatureHTML = html
            $0.signatureEnabled = true
        }
    }

    @MainActor
    private func storedAttachmentId(_ harness: SyncHarness) throws -> String? {
        try harness.db.read { try BodyRepository.attachment($0, messageId: "a1", partId: "1")?.attachmentId }
    }

    /// The `raw` field of the recorded `messages/send` POST, base64url-decoded back to MIME bytes.
    private func sentMIME(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let request = try XCTUnwrap(
            StubURLProtocol.recorded.last(where: { $0.path == SendTests.sendPath }), "no send request",
            file: file, line: line)
        let body = try XCTUnwrap(request.body, "send request had no body", file: file, line: line)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let raw = try XCTUnwrap(json["raw"] as? String, "no raw field", file: file, line: line)
        var padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: padded), "raw was not base64url", file: file, line: line)
        return String(decoding: data, as: UTF8.self)
    }

    /// Quoted-printable soft line breaks and `=XX` escapes, enough to read an HTML part back.
    private func decodedQuotedPrintable(_ mime: String) -> String {
        var out = mime.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        for (escape, character) in [("=3D", "="), ("=22", "\""), ("=20", " "), ("=E2=80=94", "—")] {
            out = out.replacingOccurrences(of: escape, with: character)
        }
        return out
    }

    private func paths() -> [String] { StubURLProtocol.recorded.map(\.path) }

    // MARK: - Happy path

    @MainActor
    func testSendHappyPath() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            ("POST", Self.sendPath, [.json(200, Self.sendResponse)]),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        // Only this send's own requests: `afterSend()` kicks a `.afterSend` sync run, and a run leaked from an
        // earlier test can still be firing into the same global recorder.
        let mine = paths().filter { $0 == Self.att1Path || $0 == Self.sendPath }
        XCTAssertEqual(mine, [Self.att1Path, Self.sendPath], "the attachment is fetched before the POST")
        let request = try XCTUnwrap(StubURLProtocol.recorded.first(where: { $0.path == Self.sendPath }))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(json["threadId"] as? String, "a1")
        XCTAssertTrue(try sentMIME().contains("Subject: Fwd:"))
        XCTAssertTrue(try harness.outboxRows().isEmpty)
        XCTAssertTrue(harness.sleeps.isEmpty, "a successful send never backs off")
        harness.assertInvariants()
    }

    @MainActor
    func testHeadersAndRecipients() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            ("POST", Self.sendPath, [.json(200, Self.sendResponse)]),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        let mime = try sentMIME()
        XCTAssertTrue(mime.contains("To: Bob <bob@example.com>"), mime.prefix(400).description)
        XCTAssertTrue(mime.contains("Message-ID: <new@example.com>"))
        XCTAssertTrue(mime.contains("In-Reply-To: <orig@example.com>"))
        XCTAssertTrue(mime.contains("References: <root@example.com>"))
        XCTAssertTrue(mime.contains("invoice.pdf"))
    }

    // MARK: - Duplicate protection

    @MainActor
    func testTransmitStateSetBeforePost() async throws {
        let harness = try harness()
        var delayed = StubURLProtocol.Response.json(200, Self.sendResponse)
        delayed.delay = 0.4
        StubURLProtocol.routes([
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            ("POST", Self.sendPath, [delayed]),
        ])
        let id = try enqueue(harness, job())

        let drain = Task { await harness.outbox.drain() }
        var sawMaybeSent = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(20))
            let current = try row(harness, id)
            if current?.transmitState == .maybeSent {
                sawMaybeSent = true
                break
            }
            if current == nil { break }
        }
        await drain.value
        XCTAssertTrue(sawMaybeSent, "transmitState must be maybeSent before the POST completes")
    }

    @MainActor
    func testMaybeSentFoundNoSecondPost() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.listPath, [.json(200, JSONFixtures.messageList(ids: ["sent1"]))]),
            ("POST", Self.sendPath, [.json(200, Self.sendResponse)]),
        ])
        let id = try enqueue(harness, job())
        try markMaybeSent(harness, id)

        await harness.outbox.drain()

        XCTAssertFalse(paths().contains(Self.sendPath), "a message already delivered must not be POSTed again")
        XCTAssertTrue(
            StubURLProtocol.recorded.contains { ($0.query ?? "").contains("rfc822msgid") },
            "the duplicate check must search by rfc822msgid")
        XCTAssertTrue(try harness.outboxRows().isEmpty)
    }

    @MainActor
    func testMaybeSentNotFoundResends() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.listPath, [.json(200, JSONFixtures.messageList(ids: []))]),
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            ("POST", Self.sendPath, [.json(200, Self.sendResponse)]),
        ])
        let id = try enqueue(harness, job())
        try markMaybeSent(harness, id)

        await harness.outbox.drain()

        XCTAssertEqual(paths().filter { $0 == Self.sendPath }.count, 1)
        XCTAssertTrue(try harness.outboxRows().isEmpty)
    }

    // MARK: - Failure handling

    @MainActor
    func testPermanent400Fails() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            (
                "POST", Self.sendPath,
                [.json(400, JSONFixtures.errorEnvelope(code: 400, reason: "invalidArgument", message: "bad"))]
            ),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        let row = try XCTUnwrap(try harness.outboxRows().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.lastError, "Request rejected")
        XCTAssertEqual(try failedSendCount(harness), 1)
    }

    @MainActor
    func testTransientSendRetriesAndKeepsMaybeSent() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            (
                "POST", Self.sendPath,
                [.json(500, JSONFixtures.errorEnvelope(code: 500, reason: "backendError", message: "boom"))]
            ),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        let row = try XCTUnwrap(try harness.outboxRows().first)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.attempts, 1)
        XCTAssertEqual(row.transmitState, .maybeSent, "a 500 may still have delivered")
    }

    @MainActor
    func testSendOfflineStopsUncounted() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            ("GET", Self.att1Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            ("POST", Self.sendPath, [.error(.notConnectedToInternet)]),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        let row = try XCTUnwrap(try harness.outboxRows().first)
        XCTAssertEqual(row.attempts, 0, "an offline failure is not the user's attempt")
        XCTAssertEqual(row.transmitState, .maybeSent)
        XCTAssertTrue(harness.status.isOffline)
    }

    // MARK: - Attachments

    @MainActor
    func testBudgetRefusedBeforeNetwork() async throws {
        let harness = try harness()
        StubURLProtocol.routes([("POST", Self.sendPath, [.json(200, Self.sendResponse)])])
        _ = try enqueue(harness, job(attachments: [Self.ref(size: 25_000_000)]))

        await harness.outbox.drain()

        XCTAssertFalse(paths().contains(Self.sendPath), "the budget is checked before any request")
        XCTAssertFalse(paths().contains(Self.att1Path), "an over-budget job must not fetch its attachments")
        let row = try XCTUnwrap(try harness.outboxRows().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.lastError, "Attachments too large to forward (25.0 MB)")
    }

    @MainActor
    func testAttachmentReresolvedOn404() async throws {
        let harness = try harness()
        try seedAttachmentRow(harness)
        StubURLProtocol.routes([
            (
                "GET", Self.att1Path,
                [.json(404, JSONFixtures.errorEnvelope(code: 404, reason: "notFound", message: "gone"))]
            ),
            ("GET", Self.messagePath, [.json(200, Self.messageWithAttachment(attachmentId: "att2"))]),
            ("GET", Self.att2Path, [.json(200, JSONFixtures.attachment(bytes: Data("hello".utf8)))]),
            ("POST", Self.sendPath, [.json(200, Self.sendResponse)]),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        // Only this send's own requests: `afterSend()` kicks a `.afterSend` delta sync (a `/history` call) that
        // can land before this assertion, so filter it out and check the re-resolve flow itself.
        let mine = paths().filter { $0 != Self.historyPath }
        XCTAssertEqual(mine, [Self.att1Path, Self.messagePath, Self.att2Path, Self.sendPath])
        let query = try XCTUnwrap(StubURLProtocol.recorded[1].query)
        XCTAssertTrue(query.contains("format=full"), query)
        XCTAssertEqual(try storedAttachmentId(harness), "att2")
    }

    @MainActor
    func testAttachmentGoneFailsJob() async throws {
        let harness = try harness()
        StubURLProtocol.routes([
            (
                "GET", Self.att1Path,
                [.json(404, JSONFixtures.errorEnvelope(code: 404, reason: "notFound", message: "gone"))]
            ),
            (
                "GET", Self.messagePath,
                [.json(404, JSONFixtures.errorEnvelope(code: 404, reason: "notFound", message: "gone"))]
            ),
            ("POST", Self.sendPath, [.json(200, Self.sendResponse)]),
        ])
        _ = try enqueue(harness, job())

        await harness.outbox.drain()

        XCTAssertFalse(paths().contains(Self.sendPath))
        let row = try XCTUnwrap(try harness.outboxRows().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.lastError, "Original message no longer available")
    }

    // MARK: - Body construction

    @MainActor
    private func drainNoAttachments(_ harness: SyncHarness, _ job: SendJob) async throws {
        StubURLProtocol.routes([("POST", Self.sendPath, [.json(200, Self.sendResponse)])])
        _ = try enqueue(harness, job)
        await harness.outbox.drain()
    }

    @MainActor
    func testQuoteFromSnapshotAfterWipe() async throws {
        let harness = try harness()
        // Nothing about `a1` is in the cache: the quote must come from the job's own snapshot.
        try await drainNoAttachments(harness, job(attachments: []))

        let mime = decodedQuotedPrintable(try sentMIME())
        XCTAssertTrue(mime.contains("---------- Forwarded message ---------"), mime)
        XCTAssertTrue(mime.contains("<div>Original</div>"))
        XCTAssertTrue(try harness.outboxRows().isEmpty)
    }

    @MainActor
    func testReplyAllUsesReplyQuoting() async throws {
        let harness = try harness()
        try await drainNoAttachments(harness, job(mode: .replyAll, attachments: []))

        let mime = decodedQuotedPrintable(try sentMIME())
        XCTAssertTrue(mime.contains("gmail_quote_container"), mime)
        XCTAssertTrue(mime.contains("wrote:"))
        XCTAssertFalse(mime.contains("---------- Forwarded message ---------"))
    }

    @MainActor
    func testSignatureIncludedWhenEnabled() async throws {
        let harness = try harness()
        setSignature(harness, "<b>Sig</b>")
        try await drainNoAttachments(harness, job(attachments: [], includeSignature: true))

        let mime = decodedQuotedPrintable(try sentMIME())
        XCTAssertTrue(mime.contains("gmail_signature"), mime)
        XCTAssertTrue(mime.contains("<b>Sig</b>"))
    }

    @MainActor
    func testSignatureOmittedWhenJobSaysNo() async throws {
        let harness = try harness()
        setSignature(harness, "<b>Sig</b>")
        try await drainNoAttachments(harness, job(attachments: [], includeSignature: false))

        let mime = decodedQuotedPrintable(try sentMIME())
        XCTAssertFalse(mime.contains("gmail_signature"))
        XCTAssertFalse(mime.contains("<b>Sig</b>"))
    }

    @MainActor
    func testDateStampedAtBuildTime() async throws {
        let harness = try harness()
        let enqueuedAt = harness.now
        StubURLProtocol.routes([("POST", Self.sendPath, [.json(200, Self.sendResponse)])])
        _ = try enqueue(harness, job(attachments: []))
        harness.advance(seconds: 3600)

        await harness.outbox.drain()

        let mime = try sentMIME()
        let dateLine = try XCTUnwrap(
            mime.split(separator: "\r\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix("Date: ") }), mime.prefix(300).description)
        let parsed = try XCTUnwrap(HeaderDate.parse(String(dateLine.dropFirst("Date: ".count))))
        let expected = enqueuedAt.addingTimeInterval(3600).timeIntervalSince1970
        XCTAssertEqual(parsed.timeIntervalSince1970, expected, accuracy: 1)
    }

    // MARK: - Retry and discard

    @MainActor
    func testRetrySendResets() async throws {
        let harness = try harness()
        StubURLProtocol.routes([("POST", Self.sendPath, [.json(200, Self.sendResponse)])])
        let id = try enqueue(harness, job(attachments: []))
        try markFailed(harness, id)

        await harness.outbox.retrySend(id: id)
        await harness.outbox.drain()

        XCTAssertTrue(paths().contains(Self.sendPath))
        XCTAssertTrue(try harness.outboxRows().isEmpty)
    }

    @MainActor
    func testDiscardSend() async throws {
        let harness = try harness()
        let id = try enqueue(harness, job(attachments: []))
        try markFailed(harness, id)

        await harness.outbox.discardSend(id: id)

        XCTAssertTrue(try harness.outboxRows().isEmpty)
        XCTAssertEqual(harness.status.failedSends, 0)
    }
}
