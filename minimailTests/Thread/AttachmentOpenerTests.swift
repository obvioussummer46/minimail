import GRDB
import MailCore
import MailHTML
import XCTest

@testable import minimail

nonisolated final class AttachmentOpenerTests: XCTestCase {

    private var db: DatabaseQueue!
    private var gmail: GmailClient!
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        db = try TestDatabase.make()
        try TestDatabase.seed(db, [TestDatabase.parsed(id: "m1", internalDate: 1_757_500_000_000, labels: ["INBOX"])])
        gmail = GmailClient(
            tokens: FixedTokenProvider(), session: .minimail(protocolClasses: [StubURLProtocol.self]),
            limiter: RequestLimiter(max: 2), log: nil, sleep: { _ in }, random: { 0.5 })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        StubURLProtocol.reset()
        try super.tearDownWithError()
    }

    @MainActor
    private func makeOpener() -> AttachmentOpener {
        AttachmentOpener(gmail: gmail, db: db, directory: dir)
    }

    private func seedAttachment(
        partId: String = "2", filename: String = "report.pdf", mime: String = "application/pdf",
        size: Int = 5, attachmentId: String? = "A"
    ) throws {
        try db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "<p>x</p>", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []),
                text: nil,
                attachments: [
                    ParsedAttachment(
                        partId: partId, filename: filename, mimeType: mime, size: size, contentId: nil,
                        attachmentId: attachmentId, inlineData: nil, charset: nil)
                ],
                referenced: [], sanitizerVersion: 1, now: 0)
        }
    }

    /// `messages.get?format=full` answer carrying one attachment part.
    private static func fullMessage(
        partId: String = "2", filename: String = "report.pdf", mime: String = "application/pdf",
        size: Int = 5, attachmentId: String?, inlineBase64: String? = nil
    ) -> Data {
        let body: String
        if let inlineBase64 {
            body = #"{"size":\#(size),"data":"\#(inlineBase64)"}"#
        } else {
            body = #"{"size":\#(size),"attachmentId":"\#(attachmentId ?? "")"}"#
        }
        return Data(
            """
            {"id":"m1","threadId":"m1","labelIds":["INBOX"],"snippet":"snip","internalDate":"1757500000000",\
            "historyId":"1","payload":{"mimeType":"multipart/mixed",\
            "headers":[{"name":"From","value":"alice@example.com"}],"parts":[\
            {"partId":"\(partId)","mimeType":"\(mime)","filename":"\(filename)","headers":[],"body":\(body)}]}}
            """.utf8)
    }

    private static let fiveBytes = Data([1, 2, 3, 4, 5])

    /// `base64URLString()` lives fileprivate in SyncTestSupport, so the encoding is inlined here.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static var attachmentJSON: Data { JSONFixtures.attachment(bytes: fiveBytes) }
    private static let notFound = JSONFixtures.errorEnvelope(code: 404, reason: "notFound", message: "Not Found")

    // MARK: - Download

    @MainActor
    func testDownloadWritesFileAndSetsPreview() async throws {
        try seedAttachment()
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/A", [.json(200, Self.attachmentJSON)])
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertEqual(opener.previewURL?.lastPathComponent, "report.pdf")
        let url = try XCTUnwrap(opener.previewURL)
        XCTAssertEqual(try Data(contentsOf: url), Self.fiveBytes)
        XCTAssertEqual(opener.state, .idle)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    @MainActor
    func testCacheHitSkipsNetwork() async throws {
        try seedAttachment()
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/A", [.json(200, Self.attachmentJSON)])
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")
        let afterFirst = StubURLProtocol.recorded.count
        opener.previewURL = nil

        await opener.open(messageId: "m1", partId: "2")
        XCTAssertNotNil(opener.previewURL)
        XCTAssertEqual(StubURLProtocol.recorded.count, afterFirst)
    }

    @MainActor
    func testReResolveOn404() async throws {
        try seedAttachment(attachmentId: "STALE")
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/STALE", [.json(404, Self.notFound)]),
            ("GET", "/gmail/v1/users/me/messages/m1", [.json(200, Self.fullMessage(attachmentId: "FRESH"))]),
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/FRESH", [.json(200, Self.attachmentJSON)]),
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertNotNil(opener.previewURL)
        let stored = try await db.read { try BodyRepository.attachment($0, messageId: "m1", partId: "2") }
        XCTAssertEqual(stored?.attachmentId, "FRESH")
        XCTAssertEqual(
            StubURLProtocol.recorded.map(\.path),
            [
                "/gmail/v1/users/me/messages/m1/attachments/STALE",
                "/gmail/v1/users/me/messages/m1",
                "/gmail/v1/users/me/messages/m1/attachments/FRESH",
            ])
        let query = StubURLProtocol.recorded[1].query ?? ""
        XCTAssertTrue(query.contains("fields=payload"))
    }

    @MainActor
    func testSecondNotFoundIsUnavailable() async throws {
        try seedAttachment(attachmentId: "STALE")
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/STALE", [.json(404, Self.notFound)]),
            ("GET", "/gmail/v1/users/me/messages/m1", [.json(200, Self.fullMessage(attachmentId: "FRESH"))]),
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/FRESH", [.json(404, Self.notFound)]),
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertEqual(opener.state, .failed("This attachment is no longer available."))
        XCTAssertNil(opener.previewURL)
    }

    @MainActor
    func testMissingAttachmentIdResolvesFirst() async throws {
        try seedAttachment(attachmentId: nil)
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1", [.json(200, Self.fullMessage(attachmentId: "FRESH"))]),
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/FRESH", [.json(200, Self.attachmentJSON)]),
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertEqual(StubURLProtocol.recorded.first?.path, "/gmail/v1/users/me/messages/m1")
        XCTAssertEqual(
            StubURLProtocol.recorded.last?.path, "/gmail/v1/users/me/messages/m1/attachments/FRESH")
        XCTAssertNotNil(opener.previewURL)
    }

    @MainActor
    func testInlineDataFromReResolve() async throws {
        try seedAttachment(attachmentId: nil)
        let inline = Self.base64URL(Self.fiveBytes)
        StubURLProtocol.routes([
            (
                "GET", "/gmail/v1/users/me/messages/m1",
                [.json(200, Self.fullMessage(attachmentId: nil, inlineBase64: inline))]
            )
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        let url = try XCTUnwrap(opener.previewURL)
        XCTAssertEqual(try Data(contentsOf: url), Self.fiveBytes)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    @MainActor
    func testUnknownPartFails() async throws {
        try seedAttachment()
        StubURLProtocol.routes([])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "99")

        XCTAssertEqual(opener.state, .failed("This attachment is no longer available."))
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    @MainActor
    func testTooLargeRefusedBeforeNetwork() async throws {
        try seedAttachment(size: AttachmentOpener.maxBytes + 1)
        StubURLProtocol.routes([])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertEqual(
            opener.state,
            .failed(
                "This attachment is too large to open (\(Formatters.bytes(AttachmentOpener.maxBytes + 1)))."))
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    @MainActor
    func testOfflineMessage() async throws {
        try seedAttachment()
        StubURLProtocol.install { _ in .error(.notConnectedToInternet) }
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertEqual(opener.state, .failed("You're offline. Try again when you have a connection."))
    }

    @MainActor
    func testUnauthorizedMessage() async throws {
        try seedAttachment()
        let unauthorized = JSONFixtures.errorEnvelope(
            code: 401, reason: "authError", message: "Invalid Credentials")
        StubURLProtocol.routes([
            (
                "GET", "/gmail/v1/users/me/messages/m1/attachments/A",
                [.json(401, unauthorized), .json(401, unauthorized)]
            )
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        XCTAssertEqual(opener.state, .failed("Sign in again to download attachments."))
    }

    @MainActor
    func testSecondOpenWhileDownloadingIgnored() async throws {
        try await db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "<p>x</p>", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: []),
                text: nil,
                attachments: [
                    ParsedAttachment(
                        partId: "2", filename: "report.pdf", mimeType: "application/pdf", size: 5,
                        contentId: nil, attachmentId: "A", inlineData: nil, charset: nil),
                    ParsedAttachment(
                        partId: "3", filename: "other.pdf", mimeType: "application/pdf", size: 5,
                        contentId: nil, attachmentId: "B", inlineData: nil, charset: nil),
                ],
                referenced: [], sanitizerVersion: 1, now: 0)
        }
        StubURLProtocol.routes([
            (
                "GET", "/gmail/v1/users/me/messages/m1/attachments/A",
                [
                    StubURLProtocol.Response(
                        status: 200, headers: ["Content-Type": "application/json; charset=UTF-8"],
                        body: Self.attachmentJSON, transportError: nil, delay: 0.3)
                ]
            ),
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/B", [.json(200, Self.attachmentJSON)]),
        ])
        let opener = makeOpener()

        async let first: Void = opener.open(messageId: "m1", partId: "2")
        try await Task.sleep(for: .milliseconds(50))
        await opener.open(messageId: "m1", partId: "3")
        await first

        XCTAssertEqual(opener.previewURL?.lastPathComponent, "report.pdf")
        XCTAssertFalse(
            StubURLProtocol.recorded.map(\.path).contains("/gmail/v1/users/me/messages/m1/attachments/B"))
    }

    @MainActor
    func testSizeMismatchStillOpens() async throws {
        try seedAttachment(size: 10)
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/A", [.json(200, Self.attachmentJSON)])
        ])
        let opener = makeOpener()

        await opener.open(messageId: "m1", partId: "2")

        let url = try XCTUnwrap(opener.previewURL)
        XCTAssertEqual(try Data(contentsOf: url).count, 5)
    }

    // MARK: - Pure helpers

    func testSanitizedFilenames() {
        let sanitize = AttachmentOpener.sanitizedFilename
        XCTAssertEqual(sanitize("report.pdf", "2", "application/pdf"), "report.pdf")
        XCTAssertEqual(sanitize("a/b\\c.txt", "2", "text/plain"), "a_b_c.txt")
        XCTAssertEqual(sanitize("", "2", "application/pdf"), "attachment-2.pdf")
        XCTAssertEqual(sanitize("  ", "2", "image/png"), "attachment-2.png")
        XCTAssertEqual(sanitize("notes", "2", "text/plain"), "notes.txt")
        XCTAssertEqual(sanitize("notes", "2", "application/octet-stream"), "notes")
        XCTAssertEqual(sanitize(".ssh", "2", "text/plain"), "attachment-2.ssh")
        XCTAssertEqual(sanitize("report.pdf", "2", "application/pdf; name=x"), "report.pdf")

        let long = sanitize(String(repeating: "x", count: 300) + ".pdf", "2", "application/pdf")
        XCTAssertLessThanOrEqual(long.utf8.count, 124)
        XCTAssertTrue(long.hasSuffix(".pdf"))

        XCTAssertEqual(sanitize("no\u{0000}tes.txt", "2", "text/plain"), "notes.txt")
    }

    func testFileURLLayout() {
        let url = AttachmentOpener.fileURL(
            root: URL(fileURLWithPath: "/tmp/a"), messageId: "m 1", partId: "0.1", filename: "x.pdf")
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasSuffix("/0.1/x.pdf"))
        XCTAssertTrue(url.pathComponents.contains("m%201"))
        XCTAssertFalse(url.pathComponents.contains("m 1"))

        let again = AttachmentOpener.fileURL(
            root: URL(fileURLWithPath: "/tmp/a"), messageId: "m 1", partId: "0.1", filename: "x.pdf")
        XCTAssertEqual(url, again)
    }

    @MainActor
    func testPurgeRemovesDirectory() async throws {
        try seedAttachment()
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/A", [.json(200, Self.attachmentJSON)])
        ])
        let opener = makeOpener()
        await opener.open(messageId: "m1", partId: "2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        try AttachmentOpener.purge(directory: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
