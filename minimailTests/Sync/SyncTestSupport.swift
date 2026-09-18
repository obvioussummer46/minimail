import Foundation
import GRDB
import MailCore
import XCTest
import os

@testable import minimail

// MARK: - Thread-safe test helpers

/// Mutable clock shared with actors (the injected `clock` closures are `@Sendable`).
nonisolated final class ClockBox: Sendable {
    private let box: OSAllocatedUnfairLock<Date>
    init(_ date: Date) { box = OSAllocatedUnfairLock(initialState: date) }
    var now: Date { box.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { box.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Lock-protected recorder for values produced inside actors.
nonisolated final class Recorder<T: Sendable>: Sendable {
    private let box = OSAllocatedUnfairLock<[T]>(initialState: [])
    func record(_ value: T) { box.withLock { $0.append(value) } }
    var values: [T] { box.withLock { $0 } }
}

/// Fixed-token provider for sync tests (no AppAuth).
nonisolated final class FixedTokenProvider: TokenProvider, Sendable {
    private let token: String
    private let count = OSAllocatedUnfairLock(initialState: 0)
    init(token: String = "tok") { self.token = token }
    func accessToken() async throws -> String { token }
    func invalidateAccessToken() async { count.withLock { $0 += 1 } }
    var invalidations: Int { count.withLock { $0 } }
}

// MARK: - JSON fixture builders

nonisolated enum JSONFixtures {
    static func profile(email: String, historyId: UInt64) -> Data {
        Data(#"{"emailAddress":"\#(email)","historyId":"\#(historyId)"}"#.utf8)
    }

    static func messageList(ids: [String], nextPageToken: String? = nil) -> Data {
        let messages = ids.map { #"{"id":"\#($0)","threadId":"\#($0)"}"# }.joined(separator: ",")
        let next = nextPageToken.map { #","nextPageToken":"\#($0)""# } ?? ""
        return Data(#"{"messages":[\#(messages)]\#(next)}"#.utf8)
    }

    static func metadataMessage(
        id: String, thread: String, labels: [String], date: Int64, from: String, subject: String,
        messageID: String? = nil
    ) -> Data {
        let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
        var headers = [#"{"name":"From","value":"\#(from)"}"#, #"{"name":"Subject","value":"\#(subject)"}"#]
        if let messageID { headers.append(#"{"name":"Message-ID","value":"\#(messageID)"}"#) }
        let headerJSON = headers.joined(separator: ",")
        return Data(
            """
            {"id":"\(id)","threadId":"\(thread)","labelIds":[\(labelJSON)],"snippet":"snip",\
            "internalDate":"\(date)","historyId":"1","payload":{"mimeType":"text/plain","headers":[\(headerJSON)]}}
            """.utf8)
    }

    static func fullMessage(
        id: String, thread: String, labels: [String], date: Int64, html: String?, text: String?
    ) -> Data {
        let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
        var parts: [String] = []
        if let text { parts.append(mimePart(mime: "text/plain", text: text)) }
        if let html { parts.append(mimePart(mime: "text/html", text: html)) }
        let payload: String
        if parts.isEmpty {
            payload = #"{"mimeType":"text/plain","headers":[{"name":"From","value":"alice@example.com"}]}"#
        } else {
            payload =
                #"{"mimeType":"multipart/alternative","headers":[{"name":"From","value":"alice@example.com"}],"parts":[\#(parts.joined(separator: ","))]}"#
        }
        return Data(
            """
            {"id":"\(id)","threadId":"\(thread)","labelIds":[\(labelJSON)],"snippet":"snip",\
            "internalDate":"\(date)","historyId":"1","payload":\(payload)}
            """.utf8)
    }

    private static func mimePart(mime: String, text: String) -> String {
        let b64 = Data(text.utf8).base64URLString()
        return #"{"mimeType":"\#(mime)","partId":"0","body":{"size":\#(text.utf8.count),"data":"\#(b64)"}}"#
    }

    static func thread(id: String, messages: [Data]) -> Data {
        let joined = messages.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",")
        return Data(#"{"id":"\#(id)","messages":[\#(joined)]}"#.utf8)
    }

    static func modifyResponse(threadId: String, messages: [(id: String, labels: [String])]) -> Data {
        let msgs = messages.map { (m) -> String in
            let labelJSON = m.labels.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"id":"\#(m.id)","threadId":"\#(threadId)","labelIds":[\#(labelJSON)]}"#
        }.joined(separator: ",")
        return Data(#"{"id":"\#(threadId)","messages":[\#(msgs)]}"#.utf8)
    }

    static func attachment(bytes: Data) -> Data {
        Data(#"{"size":\#(bytes.count),"data":"\#(bytes.base64URLString())"}"#.utf8)
    }

    static func errorEnvelope(code: Int, reason: String, message: String) -> Data {
        Data(
            #"{"error":{"code":\#(code),"message":"\#(message)","errors":[{"reason":"\#(reason)"}],"status":"ERROR"}}"#
                .utf8)
    }

    /// Builds a `history.list` response. Each record is a JSON dictionary already serialised inline.
    static func history(records: [String], historyId: UInt64, nextPageToken: String? = nil) -> Data {
        let recs = records.joined(separator: ",")
        let next = nextPageToken.map { #""nextPageToken":"\#($0)","# } ?? ""
        return Data(#"{"history":[\#(recs)],\#(next)"historyId":"\#(historyId)"}"#.utf8)
    }

    static func messagesAdded(id: String, thread: String, labels: [String]) -> String {
        let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
        return
            #"{"id":"1","messagesAdded":[{"message":{"id":"\#(id)","threadId":"\#(thread)","labelIds":[\#(labelJSON)]}}]}"#
    }

    static func messagesDeleted(id: String, thread: String) -> String {
        #"{"id":"1","messagesDeleted":[{"message":{"id":"\#(id)","threadId":"\#(thread)"}}]}"#
    }
}

extension Data {
    nonisolated fileprivate func base64URLString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Batch stub

/// Route table + batch responder in one handler. Non-batch requests answer from `routes`; a POST to
/// `/batch/gmail/v1` is split into parts (Content-ID + inner request line), each answered by `parts(method, path)`.
nonisolated enum BatchStub {
    typealias PartResponder = @Sendable (_ method: String, _ path: String) -> (status: Int, body: Data)
    private static let boundary = "batch_test"
    private static let counters = OSAllocatedUnfairLock(initialState: (batch: 0, parts: 0))

    static func install(
        routes: [(method: String, path: String, responses: [StubURLProtocol.Response])],
        parts: @escaping PartResponder
    ) {
        counters.withLock { $0 = (0, 0) }
        let table = OSAllocatedUnfairLock<[String: [StubURLProtocol.Response]]>(
            initialState: Dictionary(
                routes.map { ("\($0.method) \($0.path)", $0.responses) }, uniquingKeysWith: { a, _ in a }))
        StubURLProtocol.install { req in
            if req.method == "POST" && req.path == "/batch/gmail/v1" {
                let items = parseParts(req.body)
                counters.withLock {
                    $0.batch += 1; $0.parts += items.count
                }
                var s = ""
                for item in items {
                    let (status, body) = parts(item.method, item.path)
                    s +=
                        "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <response-\(item.partId)>\r\n\r\n"
                    s +=
                        "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n\r\n\(String(decoding: body, as: UTF8.self))\r\n"
                }
                s += "--\(boundary)--\r\n"
                return .batch(Data(s.utf8), boundary: boundary)
            }
            let key = "\(req.method) \(req.path)"
            return table.withLock { q in
                guard var responses = q[key], !responses.isEmpty else {
                    return .json(404, JSONFixtures.errorEnvelope(code: 404, reason: "notFound", message: "no route"))
                }
                let next = responses.count == 1 ? responses[0] : responses.removeFirst()
                q[key] = responses
                return next
            }
        }
    }

    /// Answers parts from JSON fixtures keyed by message/thread/label id in the path.
    static func responder(
        messages: [String: Data] = [:], modify: [String: (Int, Data)] = [:], labels: [String: Data] = [:]
    ) -> PartResponder {
        { method, path in
            let comps = URLComponents(string: "https://x" + path)
            let segments = comps?.path.split(separator: "/").map(String.init) ?? []
            // .../messages/{id}, .../threads/{id}/modify, .../labels/{id}
            if let i = segments.firstIndex(of: "messages"), i + 1 < segments.count {
                let id = segments[i + 1].removingPercentEncoding ?? segments[i + 1]
                if let data = messages[id] { return (200, data) }
            }
            if let i = segments.firstIndex(of: "threads"), i + 1 < segments.count {
                let id = segments[i + 1].removingPercentEncoding ?? segments[i + 1]
                if let (status, data) = modify[id] { return (status, data) }
            }
            if let i = segments.firstIndex(of: "labels"), i + 1 < segments.count {
                let id = segments[i + 1].removingPercentEncoding ?? segments[i + 1]
                if let data = labels[id] { return (200, data) }
            }
            return (404, JSONFixtures.errorEnvelope(code: 404, reason: "notFound", message: "unknown part"))
        }
    }

    static var batchCount: Int { counters.withLock { $0.batch } }
    static var partCount: Int { counters.withLock { $0.parts } }

    private static func parseParts(_ body: Data?) -> [(partId: String, method: String, path: String)] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [] }
        var out: [(String, String, String)] = []
        var currentId: String?
        for line in text.components(separatedBy: "\r\n") {
            if line.hasPrefix("Content-ID: <"), let lt = line.firstIndex(of: "<"), let gt = line.firstIndex(of: ">") {
                currentId = String(line[line.index(after: lt)..<gt])
            } else if let id = currentId {
                let parts = line.split(separator: " ")
                if parts.count >= 2, ["GET", "POST", "PUT", "DELETE"].contains(String(parts[0])) {
                    out.append((id, String(parts[0]), String(parts[1])))
                    currentId = nil
                }
            }
        }
        return out
    }
}

/// Builds a metadata `ParsedMessage` for seeding.
nonisolated func msg(
    _ id: String, thread: String? = nil, labels: [String] = ["INBOX", "UNREAD"], date: Int64? = nil,
    from: String = "alice@example.com", subject: String? = nil
) -> ParsedMessage {
    ParsedMessage(
        id: id, threadId: thread ?? id, historyId: 1, internalDate: date ?? 1_757_580_000_000, labelIds: labels,
        snippet: "snip",
        headers: ParsedHeaders(
            from: Mailbox(name: nil, addr: from), to: [], cc: [], replyTo: [], subject: subject ?? "Subject \(id)",
            messageID: nil, inReplyTo: nil, references: []),
        topMimeType: "text/plain", body: nil, attachments: [])
}

// MARK: - Harness

@MainActor final class SyncHarness {
    let db: DatabaseQueue
    let status: SyncStatus
    let auth: AuthStore
    var settings: Settings
    let gmail: GmailClient
    let outbox: Outbox
    let sync: SyncEngine
    let actions: MailActions
    let identity: OutboxIdentitySource

    private let clockBox: ClockBox
    let badgeRecorder = Recorder<Int>()
    let sleepRecorder = Recorder<TimeInterval>()
    let clientSleepRecorder = Recorder<TimeInterval>()
    private let settingsBox = OSAllocatedUnfairLock<Settings>(initialState: Settings())
    private let lowPowerBox = OSAllocatedUnfairLock<Bool>(initialState: false)

    var now: Date { clockBox.now }
    var badgeCalls: [Int] { badgeRecorder.values }
    var sleeps: [TimeInterval] { sleepRecorder.values }
    var clientSleeps: [TimeInterval] { clientSleepRecorder.values }

    init(settings: Settings = Settings()) throws {
        StubURLProtocol.reset()
        self.settings = settings
        settingsBox.withLock { $0 = settings }
        db = try AppDatabase.openInMemory()
        status = SyncStatus()
        clockBox = ClockBox(Date(timeIntervalSince1970: 1_757_584_800))  // 2026-09-11T10:00:00Z

        let tokens = AppAuthTokenProvider(keychainAccount: "test.sync", onNeedsReauth: {})
        auth = AuthStore(
            tokens: tokens, config: OAuthConfig.fromInfoPlist(), hasKeychainItem: true,
            cachedEmail: "me@example.com")

        let clientSleeps = clientSleepRecorder
        gmail = GmailClient(
            tokens: FixedTokenProvider(),
            session: .minimail(protocolClasses: [StubURLProtocol.self]),
            limiter: RequestLimiter(max: 2), log: nil,
            sleep: { clientSleeps.record($0) }, random: { 0.5 })

        identity = OutboxIdentitySource(
            db: db, settings: SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!))
        let clock = clockBox
        let sleeps = sleepRecorder
        let idn = identity
        outbox = Outbox(
            db: db, gmail: gmail, status: status,
            identity: { await idn.current() },
            clock: { clock.now }, random: { 0.5 },
            sleep: { sleeps.record($0) })
        let box = settingsBox
        let badge = badgeRecorder
        let lowPower = lowPowerBox
        sync = SyncEngine(
            db: db, gmail: gmail, outbox: outbox, status: status,
            settings: { box.withLock { $0 } }, auth: auth,
            clock: { clock.now }, badge: { badge.record($0) },
            lowPowerMode: { lowPower.withLock { $0 } })
        outbox.bind(sync: sync)
        actions = MailActions(db: db, outbox: outbox, sync: sync)
    }

    func setSettings(_ change: (inout Settings) -> Void) {
        change(&settings)
        let snapshot = settings
        settingsBox.withLock { $0 = snapshot }
    }

    func advance(seconds: TimeInterval) { clockBox.advance(seconds) }

    func setLowPower(_ on: Bool) { lowPowerBox.withLock { $0 = on } }

    func seed(_ messages: [ParsedMessage], selfAddresses: Set<String> = ["me@example.com"], complete: Bool = true)
        throws
    {
        try db.write { db in
            try SyncStateRepository.setSelfAddresses(db, selfAddresses)
            let gen = Int(try SyncStateRepository.get(db, .syncGeneration) ?? "1") ?? 1
            let threads = try MessageRepository.upsertMetadata(
                db, parsed: messages, selfAddresses: selfAddresses, generation: gen, now: nowMs())
            try ThreadRepository.recomputeAggregates(db, threadIds: threads, selfAddresses: selfAddresses)
            if complete {
                for t in threads { try ThreadRepository.markComplete(db, threadId: t, complete: true) }
            }
        }
    }

    func seedSyncState(historyId: UInt64) throws {
        try db.write { db in
            try SyncStateRepository.setHistoryId(db, historyId, allowDecrease: true)
            try SyncStateRepository.set(db, .syncGeneration, "1")
            try SyncStateRepository.set(db, .accountEmail, "me@example.com")
            try SyncStateRepository.setSelfAddresses(db, ["me@example.com"])
            try SyncStateRepository.set(db, .lastFullSyncAt, String(nowMs()))
            try SyncStateRepository.set(db, .lastDeltaSyncAt, String(nowMs()))
        }
    }

    func message(_ id: String) throws -> MessageRecord? { try db.read { try MessageRecord.fetchOne($0, key: id) } }
    func thread(_ id: String) throws -> ThreadRecord? { try db.read { try ThreadRecord.fetchOne($0, key: id) } }
    func outboxRows() throws -> [OutboxRecord] {
        try db.read { try OutboxRecord.fetchAll($0, sql: "SELECT * FROM outbox ORDER BY id") }
    }
    func syncStateValue(_ key: SyncKey) throws -> String? { try db.read { try SyncStateRepository.get($0, key) } }

    func assertInvariants(file: StaticString = #filePath, line: UInt = #line) {
        do { try InvariantChecks.assertAll(db, file: file, line: line) } catch {
            XCTFail("invariant check threw: \(error)", file: file, line: line)
        }
    }

    private func nowMs() -> Int64 { Int64(clockBox.now.timeIntervalSince1970 * 1000) }
}
