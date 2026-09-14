import GRDB
import MailCore
import MailHTML
import XCTest

@testable import minimail

nonisolated final class InlineImageStoreTests: XCTestCase {

    private var db: DatabaseQueue!
    private var gmail: GmailClient!
    private var temp: URL!
    private var clock: ClockBox!

    /// 12 bytes, base64url as Gmail returns them.
    private static var pngBytes: Data { Data(base64Encoded: "iVBORw0KGgpGQUtF")! }
    private static let attachmentJSON = Data(#"{"size":12,"data":"iVBORw0KGgpGQUtF"}"#.utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        clock = ClockBox(Date(timeIntervalSince1970: 1_757_584_800))
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("cid-\(UUID().uuidString)")
        db = try TestDatabase.make()
        try TestDatabase.seed(db, [TestDatabase.parsed(id: "m1", internalDate: 1_757_500_000_000, labels: ["INBOX"])])
        try db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "<img src=\"minimail-cid://m1/ii_logo\">", hasRemoteImages: false,
                    darkStrategy: .plain, referencedContentIDs: ["ii_logo"]),
                text: nil,
                attachments: [
                    ParsedAttachment(
                        partId: "1", filename: "logo.png", mimeType: "image/png", size: 12,
                        contentId: "ii_logo", attachmentId: "att1", inlineData: nil, charset: nil)
                ],
                referenced: ["ii_logo"], sanitizerVersion: 1, now: 0)
        }
        gmail = GmailClient(
            tokens: FixedTokenProvider(),
            session: .minimail(protocolClasses: [StubURLProtocol.self]),
            limiter: RequestLimiter(max: 2), log: nil,
            sleep: { _ in }, random: { 0.5 })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
        StubURLProtocol.reset()
        try super.tearDownWithError()
    }

    private func makeStore() -> InlineImageStore {
        let box = clock!
        return InlineImageStore(gmail: gmail, db: db, cacheDirectory: temp, clock: { box.now })
    }

    private func seedInline(_ entries: [(contentId: String, attachmentId: String)]) throws {
        try db.write { db in
            try BodyRepository.storeBody(
                db, messageId: "m1",
                body: SanitizedBody(
                    html: "", hasRemoteImages: false, darkStrategy: .plain,
                    referencedContentIDs: Set(entries.map(\.contentId))),
                text: nil,
                attachments: entries.enumerated().map { index, entry in
                    ParsedAttachment(
                        partId: String(index + 1), filename: "i\(index).png", mimeType: "image/png", size: 12,
                        contentId: entry.contentId, attachmentId: entry.attachmentId, inlineData: nil, charset: nil)
                },
                referenced: Set(entries.map(\.contentId)), sanitizerVersion: 1, now: 0)
        }
    }

    /// `messages.get` answer whose part `1` carries `attachmentId` `att2`.
    private static func reresolvedMessageJSON(attachmentId: String) -> Data {
        Data(
            """
            {"id":"m1","payload":{"mimeType":"multipart/related","headers":[],"parts":[
            {"partId":"1","mimeType":"image/png","filename":"logo.png",
            "headers":[{"name":"Content-ID","value":"<ii_logo>"}],
            "body":{"size":12,"attachmentId":"\(attachmentId)"}}]}}
            """.utf8)
    }

    func testFetchesAndCaches() async throws {
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att1", [.json(200, Self.attachmentJSON)])
        ])
        let store = makeStore()

        let (data, mime) = try await store.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(data, Self.pngBytes)
        XCTAssertEqual(mime, "image/png")

        let file = InlineImageStore.cacheFileURL(root: temp, messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(try Data(contentsOf: file), Self.pngBytes)
        let mimeFile = file.deletingPathExtension().appendingPathExtension("mime")
        XCTAssertEqual(try String(contentsOf: mimeFile, encoding: .utf8), "image/png")

        let again = try await store.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(again.0, Self.pngBytes)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testDiskCacheSurvivesNewStore() async throws {
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att1", [.json(200, Self.attachmentJSON)])
        ])
        _ = try await makeStore().bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)

        StubURLProtocol.reset()
        StubURLProtocol.routes([])
        let fresh = makeStore()
        let (data, mime) = try await fresh.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(data, Self.pngBytes)
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    func testReresolveOn404() async throws {
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att1", [.json(404, Self.notFoundJSON)]),
            ("GET", "/gmail/v1/users/me/messages/m1", [.json(200, Self.reresolvedMessageJSON(attachmentId: "att2"))]),
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att2", [.json(200, Self.attachmentJSON)]),
        ])
        let store = makeStore()

        let (data, _) = try await store.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(data, Self.pngBytes)

        let paths = StubURLProtocol.recorded.map(\.path)
        XCTAssertEqual(
            paths,
            [
                "/gmail/v1/users/me/messages/m1/attachments/att1",
                "/gmail/v1/users/me/messages/m1",
                "/gmail/v1/users/me/messages/m1/attachments/att2",
            ])
        let query = StubURLProtocol.recorded[1].query ?? ""
        XCTAssertTrue(query.contains("format=full"))
        XCTAssertTrue(query.contains("fields=id,payload") || query.contains("fields=id%2Cpayload"))

        let stored = try await db.read { try BodyRepository.attachment($0, messageId: "m1", partId: "1") }
        XCTAssertEqual(stored?.attachmentId, "att2")
        try InvariantChecks.assertAll(db)
    }

    func testSecond404Fails() async throws {
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att1", [.json(404, Self.notFoundJSON)]),
            ("GET", "/gmail/v1/users/me/messages/m1", [.json(200, Self.reresolvedMessageJSON(attachmentId: "att2"))]),
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att2", [.json(404, Self.notFoundJSON)]),
        ])
        let store = makeStore()

        do {
            _ = try await store.bytes(messageId: "m1", contentId: "ii_logo")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? GmailError, .notFound)
        }
        let count = await store.failureCount
        XCTAssertEqual(count, 1)
    }

    func testUnknownContentId() async throws {
        StubURLProtocol.routes([])
        let store = makeStore()

        do {
            _ = try await store.bytes(messageId: "m1", contentId: "nope")
            XCTFail("expected unknownContentId")
        } catch {
            XCTAssertEqual(error as? InlineImageError, .unknownContentId)
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        let count = await store.failureCount
        XCTAssertEqual(count, 1)
    }

    func testCaseInsensitiveContentId() async throws {
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att1", [.json(200, Self.attachmentJSON)])
        ])
        let store = makeStore()
        let (data, _) = try await store.bytes(messageId: "m1", contentId: "II_LOGO")
        XCTAssertEqual(data, Self.pngBytes)
    }

    func testFailureCachedFor60s() async throws {
        StubURLProtocol.routes([
            ("GET", "/gmail/v1/users/me/messages/m1/attachments/att1", [.json(500, Self.serverJSON)])
        ])
        let store = makeStore()

        do {
            _ = try await store.bytes(messageId: "m1", contentId: "ii_logo")
            XCTFail("expected server error")
        } catch {
            XCTAssertEqual(error as? GmailError, .server(status: 500))
        }
        let afterFirst = StubURLProtocol.recorded.count
        XCTAssertGreaterThan(afterFirst, 0)

        do {
            _ = try await store.bytes(messageId: "m1", contentId: "ii_logo")
            XCTFail("expected recentlyFailed")
        } catch {
            XCTAssertEqual(error as? InlineImageError, .recentlyFailed)
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, afterFirst)

        clock.advance(61)
        _ = try? await store.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertGreaterThan(StubURLProtocol.recorded.count, afterFirst)
    }

    func testInFlightCap() async throws {
        try seedInline([("ii_1", "a1"), ("ii_2", "a2"), ("ii_3", "a3"), ("ii_4", "a4")])
        StubURLProtocol.routes(
            (1...4).map { index in
                (
                    "GET", "/gmail/v1/users/me/messages/m1/attachments/a\(index)",
                    [
                        StubURLProtocol.Response(
                            status: 200,
                            headers: ["Content-Type": "application/json; charset=UTF-8"],
                            body: Self.attachmentJSON, transportError: nil, delay: 0.3)
                    ]
                )
            })
        let store = makeStore()

        async let one = store.bytes(messageId: "m1", contentId: "ii_1")
        async let two = store.bytes(messageId: "m1", contentId: "ii_2")
        async let three = store.bytes(messageId: "m1", contentId: "ii_3")
        async let four = store.bytes(messageId: "m1", contentId: "ii_4")
        let all = try await [one, two, three, four]

        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(all.allSatisfy { $0.0 == Self.pngBytes })
        XCTAssertLessThanOrEqual(StubURLProtocol.maxConcurrent, 2)
    }

    func testConcurrentSameKeyDedupes() async throws {
        StubURLProtocol.routes([
            (
                "GET", "/gmail/v1/users/me/messages/m1/attachments/att1",
                [
                    StubURLProtocol.Response(
                        status: 200, headers: ["Content-Type": "application/json; charset=UTF-8"],
                        body: Self.attachmentJSON, transportError: nil, delay: 0.2)
                ]
            )
        ])
        let store = makeStore()

        async let one = store.bytes(messageId: "m1", contentId: "ii_logo")
        async let two = store.bytes(messageId: "m1", contentId: "ii_logo")
        let (first, second) = try await (one, two)

        XCTAssertEqual(first.0, Self.pngBytes)
        XCTAssertEqual(second.0, Self.pngBytes)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testPurge() async throws {
        StubURLProtocol.routes([
            (
                "GET", "/gmail/v1/users/me/messages/m1/attachments/att1",
                [.json(200, Self.attachmentJSON), .json(200, Self.attachmentJSON)]
            )
        ])
        let store = makeStore()
        _ = try await store.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))

        await store.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        let count = await store.failureCount
        XCTAssertEqual(count, 0)

        _ = try await store.bytes(messageId: "m1", contentId: "ii_logo")
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
    }

    private static let notFoundJSON = Data(
        #"{"error":{"code":404,"message":"Not Found","errors":[{"reason":"notFound"}],"status":"NOT_FOUND"}}"#.utf8)
    private static let serverJSON = Data(
        #"{"error":{"code":500,"message":"Backend Error","status":"INTERNAL"}}"#.utf8)
}
