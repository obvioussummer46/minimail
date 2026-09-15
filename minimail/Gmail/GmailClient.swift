import Foundation
import MailCore
import os

/// One `threads.modify` part of an outbox batch. `add`/`remove` are label ids; empty arrays are omitted from JSON.
nonisolated struct ThreadModifyCall: Sendable, Equatable {
    var opId: Int64
    var threadId: String
    var add: [String]
    var remove: [String]
    init(opId: Int64, threadId: String, add: [String], remove: [String]) {
        self.opId = opId
        self.threadId = threadId
        self.add = add
        self.remove = remove
    }
}

/// The Gmail REST client. Owns no state beyond its immutable dependencies; every method is reentrant.
/// Never touches the database. Never calls `AuthStore` — callers react to `.unauthorized`.
actor GmailClient {
    static let batchChunkSize = 25
    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    static let batchURL = URL(string: "https://www.googleapis.com/batch/gmail/v1")!
    static let maxInRequestRetryAfter: TimeInterval = 30
    static let maxBatchRounds = 3
    static let metadataFieldsMask =
        "id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers"
    static let historyFieldsMask =
        "history(id,messagesAdded(message(id,threadId,labelIds)),messagesDeleted(message(id,threadId)),"
        + "labelsAdded(message(id,threadId,labelIds),labelIds),labelsRemoved(message(id,threadId,labelIds),labelIds)),"
        + "nextPageToken,historyId"

    private let tokens: any TokenProvider
    private let session: URLSession
    private let limiter: RequestLimiter
    private let log: RequestLog?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let random: @Sendable () -> Double

    init(
        tokens: any TokenProvider,
        session: URLSession,
        limiter: RequestLimiter,
        log: RequestLog?,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.tokens = tokens
        self.session = session
        self.limiter = limiter
        self.log = log
        self.sleep = sleep
        self.random = random
    }

    // MARK: Single-request endpoints

    func getProfile() async throws -> GmailProfile {
        try await getJSON(GmailProfile.self, endpoint: "profile", pairs: [prettyPrint])
    }

    func listLabels() async throws -> [GmailLabel] {
        try await getJSON(GmailListLabelsResponse.self, endpoint: "labels", pairs: [prettyPrint]).labels ?? []
    }

    func listMessages(labelIds: [String], q: String?, maxResults: Int, pageToken: String?) async throws
        -> GmailListMessagesResponse
    {
        precondition(1...500 ~= maxResults, "maxResults out of range")
        var pairs = labelIds.map { ("labelIds", $0) }
        if let q { pairs.append(("q", q)) }
        pairs.append(("maxResults", String(maxResults)))
        if let pageToken { pairs.append(("pageToken", pageToken)) }
        pairs.append(prettyPrint)
        return try await getJSON(GmailListMessagesResponse.self, endpoint: "messages", pairs: pairs)
    }

    func getMessage(id: String, format: GmailFormat, fields: String?) async throws -> GmailMessage {
        var pairs = [("format", format.rawValue)]
        if format == .metadata { pairs += metadataHeaderPairs }
        if let fields { pairs.append(("fields", fields)) }
        pairs.append(prettyPrint)
        return try await getJSON(GmailMessage.self, endpoint: "messages/" + QueryEncoding.segment(id), pairs: pairs)
    }

    func getThread(id: String, format: GmailFormat) async throws -> GmailThread {
        precondition(format != .raw, "threads have no raw format")
        var pairs = [("format", format.rawValue)]
        if format == .metadata { pairs += metadataHeaderPairs }
        pairs.append(prettyPrint)
        return try await getJSON(GmailThread.self, endpoint: "threads/" + QueryEncoding.segment(id), pairs: pairs)
    }

    func listHistory(startHistoryId: UInt64, pageToken: String?) async throws -> GmailListHistoryResponse {
        var pairs = [
            ("startHistoryId", String(startHistoryId)),
            ("maxResults", "500"),
            ("historyTypes", "messageAdded"),
            ("historyTypes", "messageDeleted"),
            ("historyTypes", "labelAdded"),
            ("historyTypes", "labelRemoved"),
        ]
        if let pageToken { pairs.append(("pageToken", pageToken)) }
        pairs.append(("fields", Self.historyFieldsMask))
        pairs.append(prettyPrint)
        return try await getJSON(GmailListHistoryResponse.self, endpoint: "history", pairs: pairs)
    }

    func send(raw: Data, threadId: String?) async throws -> GmailMessage {
        let body = try encodeJSON(GmailSendRequest(raw: Base64URL.encode(raw), threadId: threadId))
        let url = URL(string: Self.baseURL.absoluteString + "messages/send?prettyPrint=false")!
        let (data, _) = try await request(
            "POST", url: url, body: body, contentType: "application/json",
            policy: .send, endpoint: "messages/send", logPath: "messages/send?prettyPrint=false"
        )
        return try decode(GmailMessage.self, data)
    }

    func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let endpoint =
            "messages/" + QueryEncoding.segment(messageId) + "/attachments/" + QueryEncoding.segment(attachmentId)
        let part = try await getJSON(GmailPartBody.self, endpoint: endpoint, pairs: [prettyPrint])
        guard let s = part.data, let bytes = Base64URL.decode(s) else {
            throw GmailError.decoding("attachment: no data")
        }
        return bytes
    }

    func listSendAs() async throws -> [GmailSendAs] {
        try await getJSON(GmailListSendAsResponse.self, endpoint: "settings/sendAs", pairs: [prettyPrint]).sendAs ?? []
    }

    // MARK: Batched endpoints

    func getLabels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>] {
        try await runBatch(
            keys: distinct(ids),
            makeCall: { id, pid in
                (
                    BatchCall(
                        id: pid, method: "GET",
                        path: "/gmail/v1/users/me/labels/" + QueryEncoding.segment(id) + "?prettyPrint=false"),
                    "labels/\(id)"
                )
            },
            decode: { try JSONDecoder().decode(GmailLabel.self, from: $0) }
        )
    }

    func getMessages(ids: [String], format: GmailFormat) async throws -> [String: Result<GmailMessage, GmailError>] {
        try await runBatch(
            keys: distinct(ids),
            makeCall: { [self] id, pid in
                var pairs = [("format", format.rawValue)]
                if format == .metadata {
                    pairs += metadataHeaderPairs
                    pairs.append(("fields", Self.metadataFieldsMask))
                }
                pairs.append(prettyPrint)
                let path = "/gmail/v1/users/me/messages/" + QueryEncoding.segment(id) + "?" + QueryEncoding.query(pairs)
                return (BatchCall(id: pid, method: "GET", path: path), "messages/\(id)")
            },
            decode: { try JSONDecoder().decode(GmailMessage.self, from: $0) }
        )
    }

    func modifyThreads(_ calls: [ThreadModifyCall]) async throws -> [Int64: Result<GmailThread, GmailError>] {
        precondition(Set(calls.map(\.opId)).count == calls.count, "opIds must be distinct")
        let byOpId = Dictionary(uniqueKeysWithValues: calls.map { ($0.opId, $0) })
        return try await runBatch(
            keys: calls.map(\.opId),
            makeCall: { [self] opId, pid in
                let c = byOpId[opId]!
                let modify = GmailModifyRequest(
                    addLabelIds: c.add.isEmpty ? nil : c.add,
                    removeLabelIds: c.remove.isEmpty ? nil : c.remove
                )
                let body = (try? encodeJSON(modify)) ?? Data()
                let path =
                    "/gmail/v1/users/me/threads/" + QueryEncoding.segment(c.threadId) + "/modify?prettyPrint=false"
                return (BatchCall(id: pid, method: "POST", path: path, jsonBody: body), "threads/\(c.threadId)/modify")
            },
            decode: { try JSONDecoder().decode(GmailThread.self, from: $0) }
        )
    }

    // MARK: Query helpers

    private nonisolated var prettyPrint: (String, String) { ("prettyPrint", "false") }
    private nonisolated var metadataHeaderPairs: [(String, String)] {
        gmailMetadataHeaders.map { ("metadataHeaders", $0) }
    }

    private nonisolated func distinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    private nonisolated func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) } catch { throw GmailError.decoding("encode: \(error)") }
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw GmailError.decoding("\(type): \(error)")
        }
    }

    private func getJSON<T: Decodable>(_ type: T.Type, endpoint: String, pairs: [(String, String)]) async throws -> T {
        let query = QueryEncoding.query(pairs)
        let url = URL(string: Self.baseURL.absoluteString + endpoint + "?" + query)!
        let (data, _) = try await request(
            "GET", url: url, body: nil, contentType: nil,
            policy: .reads, endpoint: endpoint, logPath: endpoint + "?" + query
        )
        return try decode(type, data)
    }

    // MARK: Request core

    private nonisolated func request(
        _ method: String, url: URL, body: Data?, contentType: String?,
        policy: RetryPolicy, endpoint: String, logPath: String
    ) async throws -> (Data, HTTPURLResponse) {
        try await limiter.withPermit {
            var attempt = 0
            var didRefresh = false
            while true {
                if Task.isCancelled { throw GmailError.cancelled }

                let token: String
                do {
                    token = try await self.tokens.accessToken()
                } catch is AuthError {
                    throw GmailError.unauthorized
                } catch let g as GmailError {
                    if policy.allows(g, attempt: attempt) {
                        try await self.pause(self.delay(attempt: attempt, retryAfter: nil))
                        attempt += 1
                        continue
                    }
                    throw g
                } catch is CancellationError {
                    throw GmailError.cancelled
                } catch {
                    throw GmailError.network(code: -1)
                }

                var req = URLRequest(url: url)
                req.httpMethod = method
                req.httpBody = body
                if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let started = ContinuousClock.now
                let data: Data
                let http: HTTPURLResponse
                do {
                    let (d, r) = try await self.session.data(for: req)
                    guard let h = r as? HTTPURLResponse else { throw GmailError.decoding("non-HTTP response") }
                    data = d
                    http = h
                } catch let e as URLError {
                    let g = GmailError.map(e)
                    self.record(method, logPath, status: -1, since: started)
                    Log.net.error("\(method, privacy: .public) \(logPath, privacy: .public) transport \(g)")
                    if g == .cancelled { throw g }
                    if policy.allows(g, attempt: attempt) {
                        Log.net.notice("retry \(attempt + 1, privacy: .public) after \(g)")
                        try await self.pause(self.delay(attempt: attempt, retryAfter: nil))
                        attempt += 1
                        continue
                    }
                    throw g
                } catch let g as GmailError {
                    throw g
                } catch is CancellationError {
                    throw GmailError.cancelled
                } catch {
                    throw GmailError.network(code: -1)
                }

                self.record(method, logPath, status: http.statusCode, since: started)
                switch http.statusCode {
                case 200...299:
                    return (data, http)
                case 401 where !didRefresh:
                    didRefresh = true
                    await self.tokens.invalidateAccessToken()
                    Log.net.notice("401 → token refresh")
                    continue
                case 401:
                    throw GmailError.unauthorized
                default:
                    let g = GmailError.map(
                        status: http.statusCode, body: data, headers: http.allHeaderFields, endpoint: endpoint)
                    if policy.allows(g, attempt: attempt) {
                        if let ra = g.retryAfter, ra > Self.maxInRequestRetryAfter {
                            Log.net.notice("Retry-After \(ra, privacy: .public)s too long")
                            throw g
                        }
                        Log.net.notice("retry \(attempt + 1, privacy: .public) after \(g)")
                        try await self.pause(self.delay(attempt: attempt, retryAfter: g.retryAfter))
                        attempt += 1
                        continue
                    }
                    Log.net.error("\(method, privacy: .public) \(logPath, privacy: .public) \(g)")
                    throw g
                }
            }
        }
    }

    private nonisolated func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return retryAfter }
        let raw = min(16, pow(2, Double(attempt)))
        return raw * (0.75 + 0.5 * random())
    }

    private nonisolated func pause(_ seconds: TimeInterval) async throws {
        do { try await sleep(seconds) } catch { throw GmailError.cancelled }
    }

    private nonisolated func record(
        _ method: String, _ logPath: String, status: Int, since started: ContinuousClock.Instant
    ) {
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        log?.record(method: method, path: logPath, status: status, ms: ms)
        Log.net.debug(
            "\(method, privacy: .public) \(logPath, privacy: .public) \(status, privacy: .public) \(ms, privacy: .public)ms"
        )
    }

    // MARK: Batch runner

    private nonisolated func runBatch<Key: Hashable & Sendable, T: Decodable & Sendable>(
        keys: [Key],
        makeCall: (Key, String) -> (call: BatchCall, endpoint: String),
        decode: @escaping @Sendable (Data) throws -> T
    ) async throws -> [Key: Result<T, GmailError>] {
        guard !keys.isEmpty else { return [:] }
        var results: [Key: Result<T, GmailError>] = [:]
        var index = 0
        while index < keys.count {
            let chunk = Array(keys[index..<Swift.min(index + Self.batchChunkSize, keys.count)])
            index += Self.batchChunkSize
            let parts = chunk.enumerated().map { (n, key) -> BatchPart<Key> in
                let made = makeCall(key, "p\(n)")
                return BatchPart(key: key, call: made.call, endpoint: made.endpoint)
            }
            let chunkResults = try await runChunk(parts, decode: decode)
            results.merge(chunkResults) { _, new in new }
        }
        return results
    }

    private nonisolated func runChunk<Key: Hashable & Sendable, T: Decodable & Sendable>(
        _ parts: [BatchPart<Key>],
        decode: @escaping @Sendable (Data) throws -> T
    ) async throws -> [Key: Result<T, GmailError>] {
        var out: [Key: Result<T, GmailError>] = [:]
        var pending = parts
        var round = 0
        var refreshed = false
        var malformedRetried = false

        while true {
            let boundary =
                "batch_minimail_"
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                .prefix(16)
            let body = BatchCodec.encode(pending.map(\.call), boundary: String(boundary))
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await request(
                    "POST", url: Self.batchURL, body: body,
                    contentType: "multipart/mixed; boundary=\(boundary)",
                    policy: .reads, endpoint: "batch", logPath: "batch/gmail/v1?parts=\(pending.count)"
                )
            } catch let g as GmailError {
                for p in pending { out[p.key] = .failure(g) }
                return out
            }

            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let decoded: [BatchPartResponse]
            if let b = BatchCodec.boundary(fromContentType: ct), let d = try? BatchCodec.decode(body: data, boundary: b)
            {
                decoded = d
            } else {
                if !malformedRetried {
                    malformedRetried = true
                    Log.net.notice("batch malformed → retry once")
                    try await pause(1)
                    continue
                }
                for p in pending { out[p.key] = .failure(.batchMalformed) }
                return out
            }

            let byId = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var transient: [BatchPart<Key>] = []
            var unauthorizedParts: [BatchPart<Key>] = []
            for p in pending {
                guard let r = byId[p.call.id] else {
                    out[p.key] = .failure(.batchMalformed)
                    continue
                }
                switch r.status {
                case 200...299:
                    out[p.key] = Result { try decode(r.body) }.mapError { GmailError.decoding("\(T.self): \($0)") }
                case 401:
                    unauthorizedParts.append(p)
                default:
                    let g = GmailError.map(status: r.status, body: r.body, headers: [:], endpoint: p.endpoint)
                    switch g {
                    case .rateLimited, .server: transient.append(p)
                    default: out[p.key] = .failure(g)
                    }
                }
            }

            if !unauthorizedParts.isEmpty {
                if !refreshed {
                    refreshed = true
                    await tokens.invalidateAccessToken()
                    Log.net.notice(
                        "batch part 401 → refresh, re-send \(unauthorizedParts.count + transient.count) parts")
                    pending = unauthorizedParts + transient
                    continue
                } else {
                    for p in unauthorizedParts { out[p.key] = .failure(.unauthorized) }
                }
            }

            if transient.isEmpty { return out }
            if round >= Self.maxBatchRounds {
                for p in transient {
                    let r = byId[p.call.id]!
                    out[p.key] = .failure(
                        GmailError.map(status: r.status, body: r.body, headers: [:], endpoint: p.endpoint))
                }
                return out
            }
            Log.net.notice("batch round \(round + 1, privacy: .public): re-sending \(transient.count) parts")
            try await pause(delay(attempt: round, retryAfter: nil))
            round += 1
            pending = transient
        }
    }
}

/// Retry counts per error class. `attempt` = retries already performed (0 on the first try).
nonisolated private struct RetryPolicy: Sendable {
    var rateLimited: Int
    var server: Int
    var network: Int
    static let reads = RetryPolicy(rateLimited: 4, server: 3, network: 2)
    static let send = RetryPolicy(rateLimited: 0, server: 0, network: 0)
    func allows(_ error: GmailError, attempt: Int) -> Bool {
        switch error {
        case .rateLimited: return attempt < rateLimited
        case .server: return attempt < server
        case .network: return attempt < network
        default: return false
        }
    }
}

/// Percent-encoding for query values and path segments.
nonisolated private enum QueryEncoding {
    private static let asciiAlnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    static let queryValueAllowed = CharacterSet(charactersIn: asciiAlnum + "-._~,/:()")
    static let pathSegmentAllowed = CharacterSet(charactersIn: asciiAlnum + "-._~")

    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
    static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? s
    }
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? s
    }
}

/// One pending part of a batch chunk.
nonisolated private struct BatchPart<Key: Hashable & Sendable>: Sendable {
    var key: Key
    var call: BatchCall
    var endpoint: String
}

extension URLSession {
    /// The single app session (architecture §6.1). `protocolClasses` non-nil only in tests or the test host.
    nonisolated static func minimail(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 2
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["Accept": "application/json"]
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.httpShouldSetCookies = false
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return URLSession(configuration: c)
    }
}

/// Fails every request with `URLError(.notConnectedToInternet)`. Installed by `AppEnvironment` when `isTesting`
/// and no stub was registered, so a test-host launch can never reach the network.
nonisolated final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
