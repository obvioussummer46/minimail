import Foundation
import MailCore
import XCTest

@testable import minimail

nonisolated final class GmailClientTests: XCTestCase {
    var tokens: StubTokenProvider!
    var sleeps: SleepRecorder!
    var log: RequestLog!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokens = StubTokenProvider(tokens: ["tok1", "tok2", "tok3"])
        sleeps = SleepRecorder()
        log = RequestLog()
    }

    func makeClient(random: Double = 0.5, limiter: RequestLimiter = RequestLimiter(max: 2)) -> GmailClient {
        GmailClient(
            tokens: tokens,
            session: .minimail(protocolClasses: [StubURLProtocol.self]),
            limiter: limiter,
            log: log,
            sleep: { [sleeps] in await sleeps!.add($0) },
            random: { random }
        )
    }

    // MARK: fixtures (inline)

    private let profileJSON = Data(#"{"emailAddress":"user@example.com","messagesTotal":1,"historyId":"1"}"#.utf8)
    private func ok(_ body: Data) -> StubURLProtocol.Response { .json(200, body) }
    private func err(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> StubURLProtocol.Response {
        .json(status, body, headers: headers)
    }
    private let errorEnvelope = Data(#"{"error":{"code":0,"message":"x","errors":[{"reason":"x"}]}}"#.utf8)

    private func route(_ method: String, _ path: String, _ responses: [StubURLProtocol.Response]) {
        StubURLProtocol.routes([(method: method, path: path, responses: responses)])
    }

    // MARK: request core & headers

    func testGetProfileURLAndHeaders() async throws {
        route("GET", "/gmail/v1/users/me/profile", [ok(profileJSON)])
        let profile = try await makeClient().getProfile()
        XCTAssertEqual(profile.emailAddress, "user@example.com")
        let r = StubURLProtocol.recorded[0]
        XCTAssertEqual(
            r.url.absoluteString, "https://gmail.googleapis.com/gmail/v1/users/me/profile?prettyPrint=false")
        XCTAssertEqual(r.headers["Authorization"], "Bearer tok1")
        XCTAssertEqual(r.headers["Accept"], "application/json")
        XCTAssertNil(r.body)
    }

    func test401RefreshOnceThenSuccess() async throws {
        route("GET", "/gmail/v1/users/me/profile", [err(401, errorEnvelope), ok(profileJSON)])
        _ = try await makeClient().getProfile()
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertEqual(StubURLProtocol.recorded[0].headers["Authorization"], "Bearer tok1")
        XCTAssertEqual(StubURLProtocol.recorded[1].headers["Authorization"], "Bearer tok2")
        let inv = await tokens.invalidations
        XCTAssertEqual(inv, 1)
        let d = await sleeps.durations
        XCTAssertEqual(d, [])
    }

    func test401TwiceIsUnauthorized() async {
        route("GET", "/gmail/v1/users/me/profile", [err(401, errorEnvelope), err(401, errorEnvelope)])
        await assertThrows(.unauthorized) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        let inv = await tokens.invalidations
        XCTAssertEqual(inv, 1)
    }

    func testAuthErrorFromTokensIsUnauthorized() async {
        tokens = StubTokenProvider(tokens: ["x"], error: AuthError.needsReauth)
        route("GET", "/gmail/v1/users/me/profile", [ok(profileJSON)])
        await assertThrows(.unauthorized) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    func testTransportErrorFromTokensRetried() async throws {
        tokens = StubTokenProvider(tokens: ["tok1", "tok2"], throwFirst: GmailError.network(code: -1001))
        route("GET", "/gmail/v1/users/me/profile", [ok(profileJSON)])
        _ = try await makeClient().getProfile()
        let d = await sleeps.durations
        XCTAssertEqual(d, [1])
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testRateLimitedRetriedFourTimes() async throws {
        route(
            "GET", "/gmail/v1/users/me/profile",
            [
                err(429, errorEnvelope), err(429, errorEnvelope), err(429, errorEnvelope), err(429, errorEnvelope),
                ok(profileJSON),
            ])
        _ = try await makeClient().getProfile()
        XCTAssertEqual(StubURLProtocol.recorded.count, 5)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1, 2, 4, 8])
    }

    func testRateLimitedExhausted() async {
        route("GET", "/gmail/v1/users/me/profile", Array(repeating: err(429, errorEnvelope), count: 5))
        await assertThrows(.rateLimited(retryAfter: nil)) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 5)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1, 2, 4, 8])
    }

    func testRetryAfterHonoured() async throws {
        route(
            "GET", "/gmail/v1/users/me/profile",
            [err(429, errorEnvelope, headers: ["Retry-After": "3"]), ok(profileJSON)])
        _ = try await makeClient().getProfile()
        let d = await sleeps.durations
        XCTAssertEqual(d, [3])
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
    }

    func testRetryAfterTooLongThrows() async {
        route("GET", "/gmail/v1/users/me/profile", [err(429, errorEnvelope, headers: ["Retry-After": "120"])])
        await assertThrows(.rateLimited(retryAfter: 120)) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        let d = await sleeps.durations
        XCTAssertEqual(d, [])
    }

    func testJitterUsesRandom() async throws {
        route("GET", "/gmail/v1/users/me/profile", [err(429, errorEnvelope), ok(profileJSON)])
        _ = try await makeClient(random: 0.0).getProfile()
        let d1 = await sleeps.durations
        XCTAssertEqual(d1.first ?? -1, 0.75, accuracy: 0.001)

        StubURLProtocol.reset()
        tokens = StubTokenProvider(tokens: ["tok1"])
        sleeps = SleepRecorder()
        route("GET", "/gmail/v1/users/me/profile", [err(429, errorEnvelope), ok(profileJSON)])
        _ = try await makeClient(random: 0.999).getProfile()
        let d2 = await sleeps.durations
        XCTAssertEqual(d2.first ?? -1, 1.2495, accuracy: 0.001)
    }

    func testServerRetriedThreeTimes() async throws {
        route(
            "GET", "/gmail/v1/users/me/profile",
            [err(500, errorEnvelope), err(500, errorEnvelope), err(500, errorEnvelope), ok(profileJSON)])
        _ = try await makeClient().getProfile()
        XCTAssertEqual(StubURLProtocol.recorded.count, 4)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1, 2, 4])

        StubURLProtocol.reset()
        sleeps = SleepRecorder()
        tokens = StubTokenProvider(tokens: ["tok1"])
        route("GET", "/gmail/v1/users/me/profile", Array(repeating: err(500, errorEnvelope), count: 4))
        await assertThrows(.server(status: 500)) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 4)
    }

    func testNetworkRetriedTwice() async throws {
        route("GET", "/gmail/v1/users/me/profile", [.error(.timedOut), .error(.timedOut), ok(profileJSON)])
        _ = try await makeClient().getProfile()
        XCTAssertEqual(StubURLProtocol.recorded.count, 3)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1, 2])
        XCTAssertTrue(log.entries().contains { $0.status == -1 })
    }

    func testOfflineFailsFast() async {
        route("GET", "/gmail/v1/users/me/profile", [.error(.notConnectedToInternet)])
        await assertThrows(.offline) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        let d = await sleeps.durations
        XCTAssertEqual(d, [])
    }

    func testForbiddenNotRetried() async {
        let admin = Data(#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"#.utf8)
        route("GET", "/gmail/v1/users/me/profile", [err(403, admin)])
        await assertThrows(.forbidden(reason: "insufficientPermissions")) { try await self.makeClient().getProfile() }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testCancelledTask() async {
        StubURLProtocol.install { _ in
            var r = StubURLProtocol.Response.json(200, stubProfileJSON)
            r.delay = 0.5
            return r
        }
        let client = makeClient()
        let task = Task { try await client.getProfile() }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? GmailError, .cancelled)
        }
    }

    func testRequestLogRecords() async throws {
        route("GET", "/gmail/v1/users/me/profile", [ok(profileJSON)])
        _ = try await makeClient().getProfile()
        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].method, "GET")
        XCTAssertEqual(entries[0].path, "profile?prettyPrint=false")
        XCTAssertEqual(entries[0].status, 200)
        XCTAssertGreaterThanOrEqual(entries[0].ms, 0)
    }

    func testDecodingErrorOnGarbage() async {
        route("GET", "/gmail/v1/users/me/profile", [ok(Data("not json".utf8))])
        do {
            _ = try await makeClient().getProfile()
            XCTFail("expected decoding")
        } catch {
            guard case GmailError.decoding = error else { return XCTFail("expected decoding, got \(error)") }
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testOfflineURLProtocol() async {
        let client = GmailClient(
            tokens: tokens, session: .minimail(protocolClasses: [OfflineURLProtocol.self]),
            limiter: RequestLimiter(max: 2), log: log)
        await assertThrows(.offline) { try await client.getProfile() }
    }

    // MARK: single endpoints

    func testListMessagesRepeatedParamsAndEncoding() async throws {
        let body = Data(#"{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":"NPT"}"#.utf8)
        route("GET", "/gmail/v1/users/me/messages", [ok(body)])
        let res = try await makeClient().listMessages(
            labelIds: ["INBOX", "UNREAD"], q: "rfc822msgid:<a+b@x.de>", maxResults: 50, pageToken: "p2")
        XCTAssertEqual(res.nextPageToken, "NPT")
        XCTAssertEqual(
            StubURLProtocol.recorded[0].query,
            "labelIds=INBOX&labelIds=UNREAD&q=rfc822msgid:%3Ca%2Bb%40x.de%3E&maxResults=50&pageToken=p2&prettyPrint=false"
        )
    }

    func testListMessagesOmitsNil() async throws {
        route("GET", "/gmail/v1/users/me/messages", [ok(Data("{}".utf8))])
        _ = try await makeClient().listMessages(labelIds: [], q: nil, maxResults: 1, pageToken: nil)
        XCTAssertEqual(StubURLProtocol.recorded[0].query, "maxResults=1&prettyPrint=false")
    }

    func testGetMessageMetadataURL() async throws {
        let mh = gmailMetadataHeaders.map { "metadataHeaders=\($0)" }.joined(separator: "&")
        let body = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)
        route("GET", "/gmail/v1/users/me/messages/m1", [ok(body)])
        _ = try await makeClient().getMessage(id: "m1", format: .metadata, fields: nil)
        XCTAssertEqual(StubURLProtocol.recorded[0].query, "format=metadata&\(mh)&prettyPrint=false")
    }

    func testGetMessageFullWithFields() async throws {
        route("GET", "/gmail/v1/users/me/messages/m1", [ok(Data(#"{"id":"m1","threadId":"t1"}"#.utf8))])
        _ = try await makeClient().getMessage(id: "m1", format: .full, fields: "id,labelIds")
        XCTAssertEqual(StubURLProtocol.recorded[0].query, "format=full&fields=id,labelIds&prettyPrint=false")
        XCTAssertEqual(StubURLProtocol.recorded[0].path, "/gmail/v1/users/me/messages/m1")
    }

    func testGetThreadURL() async throws {
        let body = Data(#"{"id":"t1","messages":[{"id":"m1","threadId":"t1"},{"id":"m2","threadId":"t1"}]}"#.utf8)
        route("GET", "/gmail/v1/users/me/threads/t1", [ok(body)])
        let thread = try await makeClient().getThread(id: "t1", format: .full)
        XCTAssertEqual(StubURLProtocol.recorded[0].path, "/gmail/v1/users/me/threads/t1")
        XCTAssertEqual(StubURLProtocol.recorded[0].query, "format=full&prettyPrint=false")
        XCTAssertEqual(thread.messages?.count, 2)
    }

    func testListHistoryURL() async throws {
        let hf = GmailClient.historyFieldsMask
        route("GET", "/gmail/v1/users/me/history", [ok(Data(#"{"historyId":"1"}"#.utf8))])
        _ = try await makeClient().listHistory(startHistoryId: 1234501, pageToken: "n1")
        XCTAssertEqual(
            StubURLProtocol.recorded[0].query,
            "startHistoryId=1234501&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted"
                + "&historyTypes=labelAdded&historyTypes=labelRemoved&pageToken=n1&fields=\(stubEncodeFields(hf))&prettyPrint=false"
        )
    }

    func testListHistory404IsHistoryExpired() async {
        route("GET", "/gmail/v1/users/me/history", [err(404, errorEnvelope)])
        await assertThrows(.historyExpired) {
            try await self.makeClient().listHistory(startHistoryId: 1, pageToken: nil)
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testGetMessage404IsNotFound() async {
        route("GET", "/gmail/v1/users/me/messages/m1", [err(404, errorEnvelope)])
        await assertThrows(.notFound) { try await self.makeClient().getMessage(id: "m1", format: .full, fields: nil) }
    }

    func testGetAttachmentDecodes() async throws {
        // PNG magic bytes 0x89 0x50 0x4E 0x47 → base64url "iVBORw=="
        route(
            "GET", "/gmail/v1/users/me/messages/m1/attachments/ANGjdJ8w-_x=",
            [ok(Data(#"{"size":4,"data":"iVBORw=="}"#.utf8))])
        let bytes = try await makeClient().getAttachment(messageId: "m1", attachmentId: "ANGjdJ8w-_x=")
        // URL.path decodes %-escapes, so check the raw URL for the encoded `=`.
        XCTAssertTrue(
            StubURLProtocol.recorded[0].url.absoluteString.contains("messages/m1/attachments/ANGjdJ8w-_x%3D"),
            StubURLProtocol.recorded[0].url.absoluteString)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testGetAttachmentWithoutData() async {
        route("GET", "/gmail/v1/users/me/messages/m1/attachments/a", [ok(Data(#"{"size":3}"#.utf8))])
        await assertThrows(.decoding("attachment: no data")) {
            try await self.makeClient().getAttachment(messageId: "m1", attachmentId: "a")
        }
    }

    func testListLabelsAndSendAs() async throws {
        let labels = Data(
            #"{"labels":[{"id":"INBOX","name":"INBOX"},{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"},{"id":"d","name":"d"}]}"#
                .utf8)
        route("GET", "/gmail/v1/users/me/labels", [ok(labels)])
        let count = try await makeClient().listLabels().count
        XCTAssertEqual(count, 5)

        StubURLProtocol.reset()
        tokens = StubTokenProvider(tokens: ["tok1"])
        route(
            "GET", "/gmail/v1/users/me/settings/sendAs",
            [ok(Data(#"{"sendAs":[{"sendAsEmail":"user@example.com","isPrimary":true}]}"#.utf8))])
        let sendAs = try await makeClient().listSendAs()
        XCTAssertEqual(sendAs.first?.isPrimary, true)
        XCTAssertEqual(StubURLProtocol.recorded[0].path, "/gmail/v1/users/me/settings/sendAs")
    }

    func testEmptyListsDecodeToEmptyArrays() async throws {
        StubURLProtocol.install { _ in .json(200, Data("{}".utf8)) }
        let client = makeClient()
        let labels = try await client.listLabels()
        XCTAssertEqual(labels, [])
        let sendAs = try await client.listSendAs()
        XCTAssertEqual(sendAs, [])
        let msgs = try await client.listMessages(labelIds: [], q: nil, maxResults: 1, pageToken: nil)
        XCTAssertNil(msgs.messages)
    }

    func testSendBodyAndNoRetry() async {
        route("POST", "/gmail/v1/users/me/messages/send", [err(500, errorEnvelope)])
        await assertThrows(.server(status: 500)) {
            try await self.makeClient().send(raw: Data("From: a\r\n".utf8), threadId: "t1")
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        let r = StubURLProtocol.recorded[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertEqual(r.body, Data(#"{"raw":"RnJvbTogYQ0K","threadId":"t1"}"#.utf8))
        let d = await sleeps.durations
        XCTAssertEqual(d, [])
    }

    func testSendNeverRetries429() async {
        route("POST", "/gmail/v1/users/me/messages/send", [err(429, errorEnvelope)])
        await assertThrows(.rateLimited(retryAfter: nil)) {
            try await self.makeClient().send(raw: Data("From: a\r\n".utf8), threadId: "t1")
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testSendOmitsThreadIdAndSucceeds() async throws {
        route(
            "POST", "/gmail/v1/users/me/messages/send",
            [ok(Data(#"{"id":"s1","threadId":"t1","labelIds":["SENT"]}"#.utf8))])
        let msg = try await makeClient().send(raw: Data("From: a\r\n".utf8), threadId: nil)
        XCTAssertEqual(StubURLProtocol.recorded[0].body, Data(#"{"raw":"RnJvbTogYQ0K"}"#.utf8))
        XCTAssertEqual(msg.labelIds, ["SENT"])
    }

    func testSendRefreshesOnce401() async throws {
        route(
            "POST", "/gmail/v1/users/me/messages/send",
            [err(401, errorEnvelope), ok(Data(#"{"id":"s1","labelIds":["SENT"]}"#.utf8))])
        _ = try await makeClient().send(raw: Data("From: a\r\n".utf8), threadId: nil)
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertEqual(StubURLProtocol.recorded[1].headers["Authorization"], "Bearer tok2")
        let inv = await tokens.invalidations
        XCTAssertEqual(inv, 1)
    }

    // MARK: batch

    private let respBoundary = "resp_bnd_0123456789abcdef"

    func testBatchChunkingAt25() async throws {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            let parts = ids.map { ($0, 200, #"{"id":"x","threadId":"t"}"#) }
            return .batch(stubBatchBody(boundary: boundary, parts: parts), boundary: boundary)
        }
        let ids = (0..<60).map { "m\($0)" }
        let result = try await makeClient().getMessages(ids: ids, format: .metadata)
        XCTAssertEqual(StubURLProtocol.recorded.count, 3)
        XCTAssertEqual(result.count, 60)
        XCTAssertTrue(result.values.allSatisfy { if case .success = $0 { return true } else { return false } })
        let counts = StubURLProtocol.recorded.map { stubPartIds($0.body).count }
        XCTAssertEqual(counts, [25, 25, 10])
    }

    func testBatchPartPathShape() async throws {
        let mh = gmailMetadataHeaders.map { "metadataHeaders=\($0)" }.joined(separator: "&")
        let mf = "fields=" + stubEncodeFields(GmailClient.metadataFieldsMask)
        installEchoBatch()
        _ = try await makeClient().getMessages(ids: ["m1"], format: .metadata)
        let body = String(data: StubURLProtocol.recorded[0].body!, encoding: .utf8)!
        XCTAssertTrue(
            body.contains("GET /gmail/v1/users/me/messages/m1?format=metadata&\(mh)&\(mf)&prettyPrint=false\r\n"), body)

        StubURLProtocol.reset()
        tokens = StubTokenProvider(tokens: ["tok1"])
        installEchoBatch()
        _ = try await makeClient().getMessages(ids: ["m1"], format: .full)
        let body2 = String(data: StubURLProtocol.recorded[0].body!, encoding: .utf8)!
        XCTAssertTrue(body2.contains("GET /gmail/v1/users/me/messages/m1?format=full&prettyPrint=false\r\n"), body2)
    }

    func testBatchDedupesIds() async throws {
        installEchoBatch()
        let result = try await makeClient().getMessages(ids: ["m1", "m1", "m2"], format: .full)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertEqual(Set(result.keys), ["m1", "m2"])
        XCTAssertEqual(stubPartIds(StubURLProtocol.recorded[0].body).count, 2)
    }

    func testEmptyBatchNoRequest() async throws {
        let client = makeClient()
        let m = try await client.getMessages(ids: [], format: .full)
        let l = try await client.getLabels(ids: [])
        let t = try await client.modifyThreads([])
        XCTAssertTrue(m.isEmpty)
        XCTAssertTrue(l.isEmpty)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    func testBatchPerPartMapping() async throws {
        let admin = #"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"#
        let badHistory =
            #"{"error":{"code":400,"message":"Invalid startHistoryId: 1","errors":[{"reason":"failedPrecondition"}]}}"#
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            var parts: [(String, Int, String)] = []
            for (i, id) in ids.enumerated() {
                switch i {
                case 0: parts.append((id, 200, #"{"id":"x","threadId":"t"}"#))
                case 1: parts.append((id, 404, #"{"error":{"code":404}}"#))
                case 2: parts.append((id, 400, badHistory))
                default: parts.append((id, 403, admin))
                }
            }
            return .batch(stubBatchBody(boundary: boundary, parts: parts), boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0", "m1", "m2", "m3"], format: .full)
        assertSuccess(result["m0"])
        assertFailure(result["m1"], .notFound)
        assertFailure(result["m2"], .badRequest(reason: "failedPrecondition", message: "Invalid startHistoryId: 1"))
        assertFailure(result["m3"], .forbidden(reason: "insufficientPermissions"))
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testBatchPerPartRetryRound() async throws {
        let boundary = respBoundary
        let post = AtomicInt()
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            if post.fetchAndIncrement() == 0 {
                let parts = ids.enumerated().map { (i, id) in
                    (id, i == 0 ? 200 : 429, i == 0 ? #"{"id":"x"}"# : #"{"error":{"code":429}}"#)
                }
                return .batch(stubBatchBody(boundary: boundary, parts: parts), boundary: boundary)
            }
            return .batch(
                stubBatchBody(boundary: boundary, parts: ids.map { ($0, 200, #"{"id":"x"}"#) }), boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0", "m1"], format: .full)
        assertSuccess(result["m0"])
        assertSuccess(result["m1"])
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        let body2 = String(data: StubURLProtocol.recorded[1].body!, encoding: .utf8)!
        XCTAssertEqual(body2.components(separatedBy: "Content-ID: <p").count - 1, 1)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1])
    }

    func testBatchRoundsExhausted() async throws {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            return .batch(
                stubBatchBody(boundary: boundary, parts: ids.map { ($0, 500, #"{"error":{"code":500}}"#) }),
                boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0"], format: .full)
        assertFailure(result["m0"], .server(status: 500))
        XCTAssertEqual(StubURLProtocol.recorded.count, 4)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1, 2, 4])
    }

    func testBatchPart401RefreshResendsOnce() async throws {
        let boundary = respBoundary
        let post = AtomicInt()
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            if post.fetchAndIncrement() == 0 {
                let parts = ids.enumerated().map { (i, id) in (id, i == 0 ? 200 : 401, #"{"id":"x"}"#) }
                return .batch(stubBatchBody(boundary: boundary, parts: parts), boundary: boundary)
            }
            return .batch(
                stubBatchBody(boundary: boundary, parts: ids.map { ($0, 200, #"{"id":"x"}"#) }), boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0", "m1"], format: .full)
        assertSuccess(result["m0"])
        assertSuccess(result["m1"])
        let inv = await tokens.invalidations
        XCTAssertEqual(inv, 1)
        XCTAssertEqual(StubURLProtocol.recorded[1].headers["Authorization"], "Bearer tok2")
        let d = await sleeps.durations
        XCTAssertEqual(d, [])
    }

    func testBatchPart401TwiceUnauthorized() async throws {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            // Key on the Content-ID (stable across re-sends), not position: p1 always answers 401.
            let parts = ids.map { id in (id, id == "p1" ? 401 : 200, #"{"id":"x"}"#) }
            return .batch(stubBatchBody(boundary: boundary, parts: parts), boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0", "m1"], format: .full)
        assertFailure(result["m1"], .unauthorized)
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        let inv = await tokens.invalidations
        XCTAssertEqual(inv, 1)
    }

    func testBatchMissingPartIsMalformed() async throws {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            let parts = ids.prefix(1).map { ($0, 200, #"{"id":"x"}"#) }
            return .batch(stubBatchBody(boundary: boundary, parts: Array(parts)), boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0", "m1"], format: .full)
        assertSuccess(result["m0"])
        assertFailure(result["m1"], .batchMalformed)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testBatchMalformedOuterRetriedOnce() async throws {
        StubURLProtocol.install { _ in .batch(Data("garbage".utf8), boundary: "resp_bnd_0123456789abcdef") }
        let result = try await makeClient().getMessages(ids: ["m0"], format: .full)
        assertFailure(result["m0"], .batchMalformed)
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1])
    }

    func testBatchOuterErrorFailsAll() async throws {
        let admin = Data(#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"#.utf8)
        route("POST", "/batch/gmail/v1", [err(403, admin)])
        let result = try await makeClient().getMessages(ids: ["m0", "m1"], format: .full)
        assertFailure(result["m0"], .forbidden(reason: "insufficientPermissions"))
        assertFailure(result["m1"], .forbidden(reason: "insufficientPermissions"))
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testBatchOuter429RetriedByRequestCore() async throws {
        let boundary = respBoundary
        let post = AtomicInt()
        StubURLProtocol.install { req in
            if post.fetchAndIncrement() == 0 { return .json(429, stubErrorEnvelope) }
            let ids = stubPartIds(req.body)
            return .batch(
                stubBatchBody(boundary: boundary, parts: ids.map { ($0, 200, #"{"id":"x"}"#) }), boundary: boundary)
        }
        let result = try await makeClient().getMessages(ids: ["m0"], format: .full)
        assertSuccess(result["m0"])
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        let d = await sleeps.durations
        XCTAssertEqual(d, [1])
    }

    func testModifyThreadsBodyAndKeys() async throws {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            return .batch(
                stubBatchBody(
                    boundary: boundary,
                    parts: ids.map {
                        ($0, 200, #"{"id":"t1","messages":[{"id":"m1","threadId":"t1","labelIds":["UNREAD"]}]}"#)
                    }),
                boundary: boundary)
        }
        let calls = [
            ThreadModifyCall(opId: 7, threadId: "t1", add: [], remove: ["INBOX"]),
            ThreadModifyCall(opId: 9, threadId: "t2", add: ["UNREAD"], remove: ["INBOX"]),
        ]
        let result = try await makeClient().modifyThreads(calls)
        let body = String(data: StubURLProtocol.recorded[0].body!, encoding: .utf8)!
        XCTAssertTrue(
            body.contains(
                "POST /gmail/v1/users/me/threads/t1/modify?prettyPrint=false\r\nContent-Type: application/json\r\n\r\n{\"removeLabelIds\":[\"INBOX\"]}\r\n"
            ), body)
        XCTAssertTrue(body.contains("{\"addLabelIds\":[\"UNREAD\"],\"removeLabelIds\":[\"INBOX\"]}"), body)
        XCTAssertEqual(Set(result.keys), [7, 9])
        assertSuccess(result[7])
    }

    func testGetLabelsBatch() async throws {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            let bodies = [
                ##"{"id":"INBOX","name":"INBOX"}"##,
                ##"{"id":"Label_12","name":"Work","color":{"backgroundColor":"#4a86e8","textColor":"#ffffff"}}"##,
            ]
            let parts = ids.enumerated().map { (i, id) in (id, 200, bodies[i]) }
            return .batch(stubBatchBody(boundary: boundary, parts: parts), boundary: boundary)
        }
        let result = try await makeClient().getLabels(ids: ["INBOX", "Label_12"])
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        let body = String(data: StubURLProtocol.recorded[0].body!, encoding: .utf8)!
        XCTAssertTrue(body.contains("GET /gmail/v1/users/me/labels/INBOX?prettyPrint=false"), body)
        XCTAssertTrue(body.contains("GET /gmail/v1/users/me/labels/Label_12?prettyPrint=false"), body)
        if case .success(let label)? = result["Label_12"] {
            XCTAssertEqual(label.color?.backgroundColor, "#4a86e8")
        } else {
            XCTFail("expected Label_12 success")
        }
    }

    // MARK: limiter integration

    func testLimiterCapsConcurrencyAtTwo() async throws {
        StubURLProtocol.install { _ in
            var r = StubURLProtocol.Response.json(200, stubProfileJSON)
            r.delay = 0.3
            return r
        }
        let client = makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await client.getProfile() } }
            try await group.waitForAll()
        }
        XCTAssertEqual(StubURLProtocol.maxConcurrent, 2)
    }

    @MainActor
    func testAppEnvironmentWiring() async {
        AppEnvironment.testURLProtocolClasses = [StubURLProtocol.self]
        defer { AppEnvironment.testURLProtocolClasses = [OfflineURLProtocol.self] }
        let env = AppEnvironment(testing: true)
        let inUse = await env.limiter.inUse
        XCTAssertEqual(inUse, 0)
        #if DEBUG
            XCTAssertNotNil(env.requestLog)
        #endif
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    // MARK: helpers

    private func installEchoBatch() {
        let boundary = respBoundary
        StubURLProtocol.install { req in
            let ids = stubPartIds(req.body)
            return .batch(
                stubBatchBody(boundary: boundary, parts: ids.map { ($0, 200, #"{"id":"x","threadId":"t"}"#) }),
                boundary: boundary)
        }
    }

    private func assertThrows(
        _ expected: GmailError, _ block: @escaping () async throws -> Any, file: StaticString = #file,
        line: UInt = #line
    ) async {
        do {
            _ = try await block()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GmailError, expected, file: file, line: line)
        }
    }

    private func assertSuccess<T>(_ result: Result<T, GmailError>?, file: StaticString = #file, line: UInt = #line) {
        guard case .success? = result else {
            return XCTFail("expected success, got \(String(describing: result))", file: file, line: line)
        }
    }

    private func assertFailure<T>(
        _ result: Result<T, GmailError>?, _ expected: GmailError, file: StaticString = #file, line: UInt = #line
    ) {
        guard case .failure(let e)? = result else {
            return XCTFail("expected failure, got \(String(describing: result))", file: file, line: line)
        }
        XCTAssertEqual(e, expected, file: file, line: line)
    }
}

// MARK: - File-scope test helpers (free functions so @Sendable handler closures capture no `self`)

nonisolated let stubProfileJSON = Data(#"{"emailAddress":"user@example.com","messagesTotal":1,"historyId":"1"}"#.utf8)
nonisolated let stubErrorEnvelope = Data(#"{"error":{"code":0,"message":"x","errors":[{"reason":"x"}]}}"#.utf8)

nonisolated func stubPartIds(_ body: Data?) -> [String] {
    guard let body, let s = String(data: body, encoding: .utf8) else { return [] }
    var ids: [String] = []
    for line in s.components(separatedBy: "\r\n") where line.hasPrefix("Content-ID: <") {
        if let lt = line.firstIndex(of: "<"), let gt = line.firstIndex(of: ">") {
            ids.append(String(line[line.index(after: lt)..<gt]))
        }
    }
    return ids
}

nonisolated func stubBatchBody(boundary: String, parts: [(id: String, status: Int, json: String)]) -> Data {
    var s = ""
    for p in parts {
        s += "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <response-\(p.id)>\r\n\r\n"
        s += "HTTP/1.1 \(p.status) X\r\nContent-Type: application/json\r\n\r\n\(p.json)\r\n"
    }
    s += "--\(boundary)--\r\n"
    return Data(s.utf8)
}

nonisolated func stubEncodeFields(_ s: String) -> String {
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,/:()")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// Thread-safe counter so `@Sendable` stub handlers can track which request round they are on.
nonisolated final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func fetchAndIncrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = n
        n += 1
        return current
    }
}

/// Token provider stub: returns tokens in order (last repeats); counts invalidations; optional error to throw.
actor StubTokenProvider: TokenProvider {
    private let tokens: [String]
    private let error: (any Error)?
    private let throwFirst: (any Error)?
    private(set) var invalidations = 0
    private(set) var issued = 0

    init(tokens: [String], error: (any Error)? = nil, throwFirst: (any Error)? = nil) {
        self.tokens = tokens
        self.error = error
        self.throwFirst = throwFirst
    }

    func accessToken() async throws -> String {
        if issued == 0, let throwFirst {
            issued += 1
            throw throwFirst
        }
        if let error { throw error }
        let idx = Swift.min(issued, tokens.count - 1)
        issued += 1
        return tokens[idx]
    }

    func invalidateAccessToken() async { invalidations += 1 }
}

actor SleepRecorder {
    private(set) var durations: [TimeInterval] = []
    func add(_ d: TimeInterval) { durations.append(d) }
}
