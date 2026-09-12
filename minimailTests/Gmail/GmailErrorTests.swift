import Foundation
import XCTest

@testable import minimail

nonisolated final class GmailErrorTests: XCTestCase {

    private func body(reason: String?, message: String?, code: Int) -> Data {
        var items = ""
        if let reason { items = #"[{"reason":"\#(reason)"}]"# }
        let msg = message.map { #""message":"\#($0)","# } ?? ""
        return Data(#"{"error":{"code":\#(code),\#(msg)"errors":\#(items.isEmpty ? "[]" : items)}}"#.utf8)
    }

    private func map(
        _ status: Int, _ body: Data, _ headers: [String: String] = [:], endpoint: String, now: Date = Date()
    )
        -> GmailError
    {
        GmailError.map(status: status, body: body, headers: headers, endpoint: endpoint, now: now)
    }

    func testURLErrorOffline() {
        for code in [
            URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        ] {
            XCTAssertEqual(GmailError.map(URLError(code)), .offline)
        }
    }

    func testURLErrorCancelled() {
        XCTAssertEqual(GmailError.map(URLError(.cancelled)), .cancelled)
    }

    func testURLErrorOther() {
        XCTAssertEqual(GmailError.map(URLError(.timedOut)), .network(code: -1001))
        XCTAssertEqual(GmailError.map(URLError(.cannotConnectToHost)), .network(code: -1004))
    }

    func testMap400HistoryFailedPrecondition() {
        let b = body(reason: "failedPrecondition", message: "Invalid startHistoryId: 1", code: 400)
        XCTAssertEqual(map(400, b, endpoint: "history"), .historyExpired)
    }

    func testMap400HistoryMessageMentionsHistoryId() {
        let b = body(reason: "invalidArgument", message: "Invalid historyId", code: 400)
        XCTAssertEqual(map(400, b, endpoint: "history"), .historyExpired)
    }

    func testMap400OtherEndpoint() {
        let b = body(reason: "failedPrecondition", message: "Invalid startHistoryId: 1", code: 400)
        XCTAssertEqual(
            map(400, b, endpoint: "messages/m1"),
            .badRequest(reason: "failedPrecondition", message: "Invalid startHistoryId: 1")
        )
    }

    func testMap400HistoryUnrelated() {
        let b = body(reason: "invalidArgument", message: "Invalid pageToken", code: 400)
        XCTAssertEqual(
            map(400, b, endpoint: "history"), .badRequest(reason: "invalidArgument", message: "Invalid pageToken"))
    }

    func testMap401() {
        XCTAssertEqual(map(401, body(reason: nil, message: nil, code: 401), endpoint: "profile"), .unauthorized)
    }

    func testMap403RateWithRetryAfter() {
        let b = body(reason: "rateLimitExceeded", message: nil, code: 403)
        XCTAssertEqual(map(403, b, ["Retry-After": "7"], endpoint: "messages"), .rateLimited(retryAfter: 7))
    }

    func testMap403QuotaReasons() {
        for reason in ["rateLimitExceeded", "quotaExceeded", "concurrentLimitExceeded"] {
            XCTAssertEqual(
                map(403, body(reason: reason, message: nil, code: 403), endpoint: "messages"),
                .rateLimited(retryAfter: nil))
        }
    }

    func testMap403Admin() {
        let b = body(reason: "insufficientPermissions", message: nil, code: 403)
        XCTAssertEqual(map(403, b, endpoint: "messages"), .forbidden(reason: "insufficientPermissions"))
    }

    func testMap403DailyLimit() {
        let b = body(reason: "dailyLimitExceeded", message: nil, code: 403)
        let e = map(403, b, endpoint: "messages")
        XCTAssertEqual(e, .forbidden(reason: "dailyLimitExceeded"))
        XCTAssertEqual(e.userMessage, "Daily quota exceeded")
    }

    func testMap403NoBody() {
        XCTAssertEqual(map(403, Data(), endpoint: "messages"), .forbidden(reason: nil))
    }

    func testMap404History() {
        XCTAssertEqual(
            map(404, body(reason: "notFound", message: nil, code: 404), endpoint: "history"), .historyExpired)
    }

    func testMap404Message() {
        XCTAssertEqual(map(404, body(reason: "notFound", message: nil, code: 404), endpoint: "messages/m1"), .notFound)
    }

    func testMap429Seconds() {
        XCTAssertEqual(map(429, Data(), ["retry-after": "3"], endpoint: "messages"), .rateLimited(retryAfter: 3))
    }

    func testMap429HTTPDate() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 11
        comps.hour = 10
        comps.minute = 0
        comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let now = cal.date(from: comps)!
        let e = map(429, Data(), ["Retry-After": "Fri, 11 Sep 2026 10:00:10 GMT"], endpoint: "messages", now: now)
        XCTAssertEqual(e, .rateLimited(retryAfter: 10))
    }

    func testMap429PastHTTPDate() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 11
        comps.hour = 10
        comps.minute = 0
        comps.second = 10
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let now = cal.date(from: comps)!
        let e = map(429, Data(), ["Retry-After": "Fri, 11 Sep 2026 10:00:00 GMT"], endpoint: "messages", now: now)
        XCTAssertEqual(e, .rateLimited(retryAfter: 0))
    }

    func testMap429Garbage() {
        XCTAssertEqual(map(429, Data(), ["Retry-After": "soon"], endpoint: "messages"), .rateLimited(retryAfter: nil))
    }

    func testMap5xx() {
        XCTAssertEqual(map(500, body(reason: nil, message: nil, code: 500), endpoint: "messages"), .server(status: 500))
        XCTAssertEqual(map(503, Data(), endpoint: "messages"), .server(status: 503))
    }

    func testMapHTMLBody() {
        let html = Data("<html><body>error</body></html>".utf8)
        XCTAssertEqual(map(400, html, endpoint: "messages"), .badRequest(reason: nil, message: nil))
        XCTAssertEqual(map(502, html, endpoint: "messages"), .server(status: 502))
    }

    func testMapOther4xx() {
        let b = body(reason: "aborted", message: "Conflict", code: 409)
        XCTAssertEqual(map(409, b, endpoint: "messages"), .badRequest(reason: "aborted", message: "Conflict"))
    }

    func testMap3xx() {
        XCTAssertEqual(
            map(302, Data(), endpoint: "messages"), .badRequest(reason: nil, message: "unexpected status 302"))
    }

    func testFlags() {
        let transient: [GmailError] = [
            .offline, .network(code: -1), .rateLimited(retryAfter: nil), .server(status: 500), .batchMalformed,
        ]
        for e in transient { XCTAssertTrue(e.isTransient, "\(e)") }
        for e in [
            GmailError.unauthorized, .notFound, .historyExpired, .badRequest(reason: nil, message: nil), .decoding("x"),
            .cancelled, .forbidden(reason: nil),
        ] {
            XCTAssertFalse(e.isTransient, "\(e)")
        }
        for e in [GmailError.offline, .cancelled, .unauthorized] { XCTAssertFalse(e.countsAsAttempt, "\(e)") }
        for e in [
            GmailError.network(code: -1), .rateLimited(retryAfter: nil), .server(status: 500), .notFound,
            .badRequest(reason: nil, message: nil), .decoding("x"), .batchMalformed, .historyExpired,
            .forbidden(reason: nil),
        ] {
            XCTAssertTrue(e.countsAsAttempt, "\(e)")
        }
        XCTAssertEqual(GmailError.rateLimited(retryAfter: 5).retryAfter, 5)
        XCTAssertNil(GmailError.server(status: 500).retryAfter)
    }

    func testDescription() {
        XCTAssertEqual(GmailError.rateLimited(retryAfter: 7).description, "rateLimited(retryAfter: 7.0)")
        XCTAssertEqual(GmailError.badRequest(reason: "x", message: nil).description, "badRequest(x: nil)")
    }
}
