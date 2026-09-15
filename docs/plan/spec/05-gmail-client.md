# 05-gmail-client — `GmailClient` actor, error taxonomy, limiter, retries, batching

Module id: `05-gmail-client`. Depends on: `03-mailcore-gmail-model` (DTOs, `BatchCodec`, `GmailFormat`, `gmailMetadataHeaders`), `04-auth` (`TokenProvider`, `AuthError`), and `01-project-setup` transitively (`Log`, `AppEnvironment`). Consumed by: `07-sync-outbox` (`SyncEngine`, `Outbox`), `08-html-rendering` (`InlineImageStore` → `getAttachment`/`getMessage`), `10-thread-view` (`AttachmentOpener` → `getAttachment`/`getMessage`), `04-auth` (`getProfile` after sign-in through the injected closure), `13-settings-theme-signature` (`RequestLog.snapshot()` in Settings → Advanced, DEBUG), `14-qa` (`StubURLProtocol` conventions).

Source of truth: architecture §2.1 (rules), §2.4 (signatures — copied verbatim below), §4.4 (metadata request shape), §5.3 (401 handling), §6 (networking, error taxonomy, batching, rate limiting, logging), §12.2 (launch order), §13.3 (`GmailClientTests`), §14 #6/#7/#13; research `[gmail-api]` for every wire fact. Every fact that the research marks UNVERIFIED stays marked here (§10).

Conventions used in this document: `⏎` = CRLF; "host-relative path" = a path beginning with `/gmail/v1/…` as required inside a batch part `[gmail-api §12]`; "endpoint" = the path relative to the base URL without query (`profile`, `messages/18f2…`, `history`, `threads/18f2…/modify`), the string handed to `GmailError.map(status:body:headers:endpoint:)`.

---

## 1. Purpose & scope

### 1.1 What this module delivers

1. `actor GmailClient` — one method per Gmail endpoint that stage 1 uses (`getProfile`, `listLabels`, `getLabels`, `listMessages`, `getMessage`, `getMessages`, `getThread`, `listHistory`, `modifyThreads`, `send`, `getAttachment`, `listSendAs`), built on a single private `request(...)` core with: Bearer token from `TokenProvider`, HTTP 401 → invalidate + retry once, the retry table of architecture §6.2, `Retry-After` handling, `Task` cancellation checks, `prettyPrint=false` and `fields=` masks, repeated query keys, logging.
2. The HTTP batch runner (architecture §6.3): chunks of 25, chunks sent sequentially, `Content-ID` matching (never order), per-part status mapping, per-part retry rounds (max 3) for `.rateLimited`/`.server`, one token refresh + one re-send of the chunk for a 401 part, `.batchMalformed` handling.
3. `enum GmailError` — the error taxonomy of architecture §6.2 with the two `map` functions, `isTransient`, `countsAsAttempt`.
4. `actor RequestLimiter` — a FIFO semaphore capping in-flight HTTP requests at 2.
5. `final class RequestLog` — DEBUG ring buffer of the last 100 `(method, path, status, ms)` for Settings → Advanced.
6. `URLSession.minimail(protocolClasses:)` — the one session configuration of architecture §6.1.
7. `StubURLProtocol` (test support) and `GmailClientTests` (+ `GmailErrorTests`, `RequestLimiterTests`, `RequestLogTests`).
8. The `[05]` insertion in `AppEnvironment.init` (construction of `RequestLog`, `RequestLimiter`, `GmailClient`; no I/O).

### 1.2 Explicitly out of scope

- Any database access, GRDB import, or knowledge of records (architecture §2.1 rule 2: "`Gmail/` never imports GRDB"; module 06).
- Sync decisions: what to fetch, `HydrationPolicy`, history reduction, "third consecutive `.rateLimited` aborts the run" (architecture §6.4 — that counter lives in `SyncEngine`, module 07), label-count throttling (07).
- Send idempotency (`rfc822msgid:` check, `transmitState`), send attempt counting, the > 20 MB refusal, attachment re-resolution loops (module 07 §7.6–§7.7; modules 08/10 for downloads). `GmailClient.send` performs exactly one POST and never retries transient errors.
- Calling `AuthStore.markNeedsReauth()` on `.unauthorized` — the caller (07/08/10) does that; the client has no reference to `AuthStore`.
- `Backoff` (MailCore `Sync/Backoff.swift`, module 07). This module uses a private formula with the same constants (§4.4, deviation D4).
- `messages.modify`, `messages.batchModify`, `threads.list`, `labels.create`, media-upload send (`[gmail-api §8, §14]`) — never used in stage 1.
- Token refresh itself (`AppAuthTokenProvider`, module 04); this module only calls `accessToken()` / `invalidateAccessToken()`.
- Network reachability monitoring (`NWPathMonitor`) — decision D11: `.offline` comes from `URLError` only.

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 04 | `GmailClient.getProfile()` through the closure `AppEnvironment` injects into `AuthStore` (§3.7, §10 A1); `GmailError.offline`/`.network` thrown by the token provider's transport failures (04 produces them, 05 defines them) |
| 07 | every `GmailClient` method except `getAttachment` in `InlineImageStore` paths; `ThreadModifyCall`; `GmailError` cases and `isTransient`/`countsAsAttempt`/`retryAfter`/`userMessage`; `RequestLimiter` (constructed once by `AppEnvironment`) |
| 08 | `GmailClient.getAttachment(messageId:attachmentId:)`, `GmailClient.getMessage(id:format:fields:)`, `GmailError.notFound` |
| 10 | same as 08 (`AttachmentOpener`) |
| 13 | `RequestLog.snapshot()` (DEBUG "Recent requests") |
| 14 | `StubURLProtocol` (route tables), `AppEnvironment.testURLProtocolClasses`, `OfflineURLProtocol` |

---

## 2. Files

| Path | Kind | Purpose |
|---|---|---|
| `minimail/Gmail/GmailError.swift` | new | `GmailError` enum, `map(status:body:headers:endpoint:now:)`, `map(_ urlError:)`, `isTransient`, `countsAsAttempt`, `retryAfter`, `userMessage`, `description`, private `RetryAfterParser` |
| `minimail/Gmail/RequestLimiter.swift` | new | `actor RequestLimiter` (FIFO semaphore, default 2) |
| `minimail/Gmail/RequestLog.swift` | new | `final class RequestLog: Sendable` ring buffer (100) + `Entry` |
| `minimail/Gmail/GmailClient.swift` | new | `ThreadModifyCall`, `actor GmailClient` (endpoints, `request` core, batch runner), private `RetryPolicy`, private `QueryEncoding`, `extension URLSession { static func minimail(protocolClasses:) }`, `OfflineURLProtocol` |
| `minimail/App/AppEnvironment.swift` | modify | `[05]` insertion: `requestLog`, `limiter`, `gmail` properties + construction; `testURLProtocolClasses` hook; profile closure injection into `AuthStore` |
| `minimailTests/Support/StubURLProtocol.swift` | new | scripted `URLProtocol`: handler/route table, recorded requests, in-flight counter, body reading |
| `minimailTests/Gmail/GmailClientTests.swift` | new | URL shapes, 401 flow, retry table, batch runner, endpoints, limiter integration (§7) |
| `minimailTests/Gmail/GmailErrorTests.swift` | new | status/URLError → `GmailError` mapping table, `Retry-After` parsing, flags (§7) |
| `minimailTests/Gmail/RequestLimiterTests.swift` | new | concurrency cap, release on throw, FIFO (§7) |
| `minimailTests/Gmail/RequestLogTests.swift` | new | ring buffer size, line format (§7) |

No fixture files are created: the tests reuse the JSON/`.txt` fixtures of module 03 (`Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/*`), which `project.yml` copies into the `minimailTests` bundle as the folder `Fixtures` (spec 01 §5.1). No Info.plist key is added (HTTPS to `googleapis.com` is allowed by default ATS). `make lint` rule (spec 01 §5.3): no `import GRDB`, `import AppAuth`, `import WebKit`, `import SwiftUI` in `minimail/Gmail/*` — the four files import only `Foundation`, `os`, `MailCore`.

Files listed in architecture §1.3 that this module does NOT create: everything else. The three extra test files (`GmailErrorTests`, `RequestLimiterTests`, `RequestLogTests`) are an additive deviation (D7), following spec 01's precedent.

---

## 3. Public interface

All declarations are `internal` (app target). Every type in `minimail/Gmail/` is written with an explicit `nonisolated` (or is an `actor`) because the app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`[tooling §3.3]`, `[ios-platform §5.6]`); without the annotation a plain `enum`/`struct` would be inferred `@MainActor` and become unusable inside the actors. Same rule as spec 01 §3.4 (`nonisolated enum Log`).

### 3.1 `Gmail/GmailError.swift`

Verbatim from architecture §2.4 with additions marked.

```swift
import Foundation

/// Every failure a Gmail call can produce. Sendable + Equatable so `Result<T, GmailError>` values cross actors and tests compare them.
nonisolated enum GmailError: Error, Sendable, Equatable {
    case offline                                  // URLError notConnectedToInternet / networkConnectionLost / dataNotAllowed / internationalRoamingOff
    case network(code: Int)                       // other URLError (timeouts, resets); `code` = URLError.Code.rawValue
    case unauthorized                             // 401 after one refresh, or invalid_grant (AuthError from the token provider)
    case forbidden(reason: String?)               // 403 non-quota (admin_policy_enforced, insufficientPermissions, dailyLimitExceeded)
    case rateLimited(retryAfter: TimeInterval?)   // 429, or 403 with rateLimitExceeded / userRateLimitExceeded / quotaExceeded / concurrentLimitExceeded
    case notFound                                 // 404 on message/thread/attachment/label
    case historyExpired                           // 404 on history.list, or 400 failedPrecondition / message mentioning historyId on history.list
    case badRequest(reason: String?, message: String?)
    case server(status: Int)                      // 5xx
    case decoding(String)                         // JSON decode failure, non-HTTP response, attachment without data
    case batchMalformed                           // outer batch body unparsable (twice), or a part id missing from the response
    case cancelled                                // Task cancelled, or URLError.cancelled

    /// offline, network, rateLimited, server, batchMalformed
    var isTransient: Bool { get }
    /// everything except offline, cancelled, unauthorized (architecture §4.8: those never consume an outbox attempt)
    var countsAsAttempt: Bool { get }
    /// ADDITION (D3): `.rateLimited(retryAfter: r)` → `r`; every other case → nil.
    var retryAfter: TimeInterval? { get }
    /// ADDITION (D3): short user-visible text for `SyncStatus.lastError` / outbox rows (§4.1.3 table).
    var userMessage: String { get }

    /// Maps a non-2xx HTTP response (architecture §6.2). `endpoint` = path relative to the base URL without query.
    /// `now` (ADDITION D2, default `Date()`) anchors HTTP-date `Retry-After` values.
    static func map(status: Int, body: Data, headers: [AnyHashable: Any], endpoint: String, now: Date = Date()) -> GmailError
    /// Maps a transport error (architecture §6.2).
    static func map(_ urlError: URLError) -> GmailError
}

/// ADDITION (D3): log-friendly text, e.g. "rateLimited(retryAfter: 7.0)", "server(503)", "badRequest(failedPrecondition: Invalid startHistoryId: 1)".
extension GmailError: CustomStringConvertible { var description: String { get } }
```

Preconditions: none. `map(status:…)` never throws and never crashes on arbitrary bytes (HTML error pages, empty bodies).

### 3.2 `Gmail/RequestLimiter.swift`

Verbatim from architecture §2.4.

```swift
import Foundation

/// FIFO counting semaphore for in-flight HTTP requests (architecture §6.4: no token bucket, `max = 2`).
actor RequestLimiter {
    /// `max` ≥ 1 (precondition).
    init(max: Int = 2)
    /// Waits for a permit (FIFO), runs `op`, releases the permit whether `op` returns or throws.
    /// Waiting is not cancellable; `op` is responsible for `Task.isCancelled` checks (GmailClient does this before every attempt).
    func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T
    /// ADDITION (tests only): number of permits currently held (0…max).
    var inUse: Int { get }
}
```

### 3.3 `Gmail/RequestLog.swift`

Architecture §2.4 signature plus an `Entry` type and `entries()` (ADDITION D9, used by tests and by Settings → Advanced to format rows).

```swift
import Foundation
import os

/// Ring buffer of the last 100 requests (architecture §6.5). Thread-safe via `OSAllocatedUnfairLock`; never stores tokens, headers or bodies.
nonisolated final class RequestLog: Sendable {
    struct Entry: Sendable, Equatable {
        var date: Date        // when the response (or transport error) arrived
        var method: String    // "GET" | "POST"
        var path: String      // endpoint + query, e.g. "messages/18f2…?format=full&prettyPrint=false"; batch: "batch/gmail/v1?parts=25"
        var status: Int       // HTTP status; -1 for a transport error
        var ms: Int           // wall-clock milliseconds of that single attempt
    }
    static let capacity = 100
    init()
    /// Appends; drops the oldest entry beyond `capacity`.
    func record(method: String, path: String, status: Int, ms: Int)
    /// Oldest → newest, formatted "HH:mm:ss.SSS METHOD path status msms", e.g. "10:00:01.234 GET profile?prettyPrint=false 200 87ms" (time in the device time zone, en_US_POSIX).
    func snapshot() -> [String]
    /// Oldest → newest raw entries.
    func entries() -> [Entry]
}
```

### 3.4 `Gmail/GmailClient.swift`

Verbatim from architecture §2.4; additions marked.

```swift
import Foundation
import os
import MailCore

/// One `threads.modify` part of an outbox batch (architecture §4.8). `add`/`remove` are label ids; empty arrays are omitted from the JSON.
nonisolated struct ThreadModifyCall: Sendable, Equatable {
    var opId: Int64
    var threadId: String
    var add: [String]
    var remove: [String]
    init(opId: Int64, threadId: String, add: [String], remove: [String])
}

/// The Gmail REST client. Owns no state beyond its dependencies; every method is reentrant.
/// Never touches the database (architecture §2.1). Never calls `AuthStore` — callers react to `.unauthorized`.
actor GmailClient {
    static let batchChunkSize = 25
    /// Base of every non-batch request `[gmail-api Common facts]`.
    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    /// Documented batch endpoint `[gmail-api §12]`.
    static let batchURL = URL(string: "https://www.googleapis.com/batch/gmail/v1")!
    /// A `Retry-After` above this (seconds) is not waited for inside a request; the error is thrown at once (D5).
    static let maxInRequestRetryAfter: TimeInterval = 30
    /// Max re-send rounds for transient batch parts (architecture §6.3).
    static let maxBatchRounds = 3

    /// - tokens: module 04's provider (`AppAuthTokenProvider` in the app, a stub in tests).
    /// - session: `URLSession.minimail(protocolClasses:)`.
    /// - limiter: shared `RequestLimiter(max: 2)`.
    /// - log: DEBUG ring buffer or nil.
    /// - sleep: injected so tests record delays instead of waiting. A thrown `CancellationError` becomes `GmailError.cancelled`.
    /// - random: ADDITION (D1) jitter source in [0, 1); tests inject a constant.
    init(tokens: any TokenProvider,
         session: URLSession,
         limiter: RequestLimiter,
         log: RequestLog?,
         sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         random: @Sendable () -> Double = { Double.random(in: 0..<1) })

    /// GET profile `[gmail-api §1]`. 1 quota unit (UNVERIFIED table).
    func getProfile() async throws -> GmailProfile
    /// GET labels `[gmail-api §10]`; `labels` absent → `[]`.
    func listLabels() async throws -> [GmailLabel]
    /// Batched GET labels/{id} `[gmail-api §11]`; one entry per distinct id.
    func getLabels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>]
    /// GET messages `[gmail-api §4]`. `labelIds` are repeated keys (AND); `q` and `pageToken` omitted when nil; `maxResults` 1…500 (precondition).
    func listMessages(labelIds: [String], q: String?, maxResults: Int, pageToken: String?) async throws -> GmailListMessagesResponse
    /// GET messages/{id} `[gmail-api §5]`. `.metadata` adds every `gmailMetadataHeaders` entry; `fields` (when non-nil) is sent verbatim.
    func getMessage(id: String, format: GmailFormat, fields: String?) async throws -> GmailMessage
    /// Batched GET messages/{id}; `.metadata` adds `metadataHeaders` + the architecture §4.4 `fields` mask; `.full` sends no mask. One entry per distinct id.
    func getMessages(ids: [String], format: GmailFormat) async throws -> [String: Result<GmailMessage, GmailError>]
    /// GET threads/{id} `[gmail-api §3]`. `.metadata` adds `metadataHeaders`; `.raw` is a precondition failure (threads have no raw format).
    func getThread(id: String, format: GmailFormat) async throws -> GmailThread
    /// GET history `[gmail-api §13]`: `maxResults=500`, all four `historyTypes`, no `labelId`, the §6.1 `fields` mask. 404/400-history → `.historyExpired`.
    func listHistory(startHistoryId: UInt64, pageToken: String?) async throws -> GmailListHistoryResponse
    /// Batched POST threads/{id}/modify parts `[gmail-api §9]`, keyed by `opId` (precondition: opIds distinct). Lenient `GmailThread` decode.
    func modifyThreads(_ calls: [ThreadModifyCall]) async throws -> [Int64: Result<GmailThread, GmailError>]
    /// POST messages/send (JSON `raw` path) `[gmail-api §14]`. Exactly one POST; 0 automatic retries for transient errors; 401 still refreshes once.
    func send(raw: Data, threadId: String?) async throws -> GmailMessage
    /// GET messages/{messageId}/attachments/{attachmentId} `[gmail-api §6]`; returns the base64url-decoded bytes.
    func getAttachment(messageId: String, attachmentId: String) async throws -> Data
    /// GET settings/sendAs `[gmail-api §15]`; `sendAs` absent → `[]`.
    func listSendAs() async throws -> [GmailSendAs]
}

extension URLSession {
    /// The single app session (architecture §6.1). `protocolClasses` non-nil only in tests (`StubURLProtocol`) or the test host (`OfflineURLProtocol`).
    nonisolated static func minimail(protocolClasses: [AnyClass]? = nil) -> URLSession
}

/// Fails every request with `URLError(.notConnectedToInternet)`. Installed by `AppEnvironment` when `isTesting` and no stub was registered,
/// so a test-host launch can never reach the network.
nonisolated final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool          // true
    override class func canonicalRequest(for request: URLRequest) -> URLRequest   // identity
    override func startLoading()                                            // client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    override func stopLoading()                                             // no-op
}
```

Errors thrown by every endpoint method: only `GmailError` (any other error is converted; see §4.2 step 5). Precondition failures (`maxResults` out of range, `.raw` for threads, duplicate `opId`) are `precondition` calls, not thrown errors.

### 3.5 Private types inside `GmailClient.swift` (documented so tests and later modules can reason about them)

```swift
/// Retry counts per error class (architecture §6.2 table). `attempt` = retries already performed (0 on the first try).
nonisolated private struct RetryPolicy: Sendable {
    var rateLimited: Int; var server: Int; var network: Int
    static let reads = RetryPolicy(rateLimited: 4, server: 3, network: 2)
    static let send  = RetryPolicy(rateLimited: 0, server: 0, network: 0)
    func allows(_ error: GmailError, attempt: Int) -> Bool   // rateLimited → attempt < rateLimited; server → attempt < server; network → attempt < network; else false
}
/// Percent-encoding for query values and path segments (§4.3).
nonisolated private enum QueryEncoding {
    static let queryValueAllowed: CharacterSet   // ASCII alphanumerics + "-._~" + ",/:()"
    static let pathSegmentAllowed: CharacterSet  // ASCII alphanumerics + "-._~"
    static func query(_ items: [(String, String)]) -> String        // "k=v&k=v" with both sides encoded via queryValueAllowed
    static func segment(_ s: String) -> String
}
/// One pending part of a batch chunk.
nonisolated private struct BatchPart<Key: Hashable & Sendable>: Sendable { var key: Key; var call: BatchCall; var endpoint: String }
```

### 3.6 Test support — `minimailTests/Support/StubURLProtocol.swift`

```swift
import Foundation
import os

/// Scripted `URLProtocol`. Installed per `URLSession` via `URLSession.minimail(protocolClasses: [StubURLProtocol.self])`.
/// All static state is behind one `OSAllocatedUnfairLock`; `reset()` in every test's `setUp`.
nonisolated final class StubURLProtocol: URLProtocol {
    struct Request: Sendable, Equatable {
        var method: String
        var url: URL
        var path: String                  // url.path, e.g. "/gmail/v1/users/me/profile" or "/batch/gmail/v1"
        var query: String?                // url.query (percent-encoded, as sent)
        var headers: [String: String]     // allHTTPHeaderFields (includes the session's additional headers as URLSession merges them)
        var body: Data?                   // httpBody, or the fully read httpBodyStream
    }
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]     // e.g. ["Content-Type": "application/json; charset=UTF-8", "Retry-After": "3"]
        var body: Data
        var transportError: URLError?     // when non-nil the request fails with this error and no response is delivered
        var delay: TimeInterval           // seconds to hold the request open before answering (default 0); used by the concurrency test
        static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> Response   // adds Content-Type application/json
        static func batch(_ body: Data, boundary: String) -> Response                                // 200, Content-Type multipart/mixed; boundary=…
        static func error(_ code: URLError.Code) -> Response
        static let empty204: Response
    }
    typealias Handler = @Sendable (Request) -> Response

    /// Installs the handler that answers every request. Replaces any previous handler.
    static func install(_ handler: @escaping Handler)
    /// Route-table convenience: `(method, path)` → queue of responses; the last response repeats; an unmatched request answers
    /// 404 with body `{"error":{"code":404,"message":"stub: no route","errors":[{"reason":"notFound"}],"status":"NOT_FOUND"}}` and is still recorded.
    static func routes(_ table: [(method: String, path: String, responses: [Response])])
    /// Every request seen since `reset()`, in arrival order.
    static var recorded: [Request] { get }
    /// Highest number of simultaneously open requests since `reset()`.
    static var maxConcurrent: Int { get }
    static func reset()

    override class func canInit(with request: URLRequest) -> Bool          // true for every request
    override class func canonicalRequest(for request: URLRequest) -> URLRequest
    override func startLoading()
    override func stopLoading()
}
```

Behaviour of `startLoading`: read the body (`httpBody` else drain `httpBodyStream` synchronously, 64 KiB reads), build `Request`, append to `recorded`, increment the in-flight counter (update `maxConcurrent`), compute `Response` through the installed handler, then — after `delay` via `DispatchQueue.global().asyncAfter` (0 → immediate) — either `client?.urlProtocol(self, didFailWithError: transportError)` or `didReceive(HTTPURLResponse(url:statusCode:httpVersion:"HTTP/1.1":headerFields:))` + `didLoad(body)` + `urlProtocolDidFinishLoading`, then decrement the in-flight counter. `stopLoading` marks the instance stopped so a late callback is skipped.

---

## 4. Behaviour

### 4.1 `GmailError`

#### 4.1.1 `map(status:body:headers:endpoint:now:)` (architecture §6.2)

```
env      = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body)      // nil for HTML/empty bodies
reason   = env?.primaryReason                                                  // error.errors[0].reason
message  = env?.error.message
isHistory = endpoint == "history" || endpoint.hasSuffix("/history")
retryAfter = RetryAfterParser.seconds(headers, now)                            // §4.1.2
switch status:
  400: if isHistory && (reason == "failedPrecondition" || (message ?? "").lowercased().contains("historyid")) → .historyExpired
       else → .badRequest(reason: reason, message: message)
  401: .unauthorized
  403: if reason ∈ {"rateLimitExceeded","userRateLimitExceeded","quotaExceeded","concurrentLimitExceeded"} → .rateLimited(retryAfter: retryAfter)
       else → .forbidden(reason: reason)                                       // dailyLimitExceeded, insufficientPermissions, admin_policy_enforced, nil
  404: isHistory ? .historyExpired : .notFound
  429: .rateLimited(retryAfter: retryAfter)                                    // regardless of reason
  500…599: .server(status: status)
  402, 405…428, 430…499: .badRequest(reason: reason, message: message)
  anything else (< 200, 300…399): .badRequest(reason: nil, message: "unexpected status \(status)")
```
`endpoint` values passed by the client: `profile`, `labels`, `labels/{id}`, `messages`, `messages/{id}`, `messages/{id}/attachments/{aid}`, `messages/send`, `threads/{id}`, `threads/{id}/modify`, `history`, `settings/sendAs`, `batch` (outer batch response). Only `history` can yield `.historyExpired`. The 400 code Google uses for a malformed `startHistoryId` is UNVERIFIED (`[gmail-api §13 item 5]`, architecture §14 #6) — both the `failedPrecondition` reason and the substring rule are applied so either wording maps.

#### 4.1.2 `Retry-After` parsing (`RetryAfterParser.seconds(headers, now)`)

1. Find the first key of `headers` whose `String` form lowercased equals `retry-after` (header dictionaries from `HTTPURLResponse.allHeaderFields` preserve the server's casing); value → `String`, trimmed. None → nil.
2. If `Double(value)` parses → `max(0, value)`.
3. Else parse as an HTTP-date with `DateFormatter` (`locale = en_US_POSIX`, `timeZone = GMT`, `dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"`) → `max(0, date.timeIntervalSince(now))`. Also try `"EEE, dd MMM yyyy HH:mm:ss 'GMT'"` if the first fails.
4. Unparsable → nil.

#### 4.1.3 `map(_ urlError:)`

| `URLError.Code` | result |
|---|---|
| `.notConnectedToInternet`, `.networkConnectionLost`, `.dataNotAllowed`, `.internationalRoamingOff` | `.offline` |
| `.cancelled` | `.cancelled` |
| every other code | `.network(code: code.rawValue)` (e.g. `.timedOut` → `-1001`) |

Flags and text:

| case | `isTransient` | `countsAsAttempt` | `retryAfter` | `userMessage` |
|---|---|---|---|---|
| `.offline` | true | false | nil | `Offline` |
| `.network(code)` | true | true | nil | `Network error` |
| `.unauthorized` | false | false | nil | `Sign in again` |
| `.forbidden(reason)` | false | true | nil | `Access denied` (reason `dailyLimitExceeded` → `Daily quota exceeded`) |
| `.rateLimited(r)` | true | true | r | `Rate limited — try again later` |
| `.notFound` | false | true | nil | `Not found` |
| `.historyExpired` | false | true | nil | `Resyncing` |
| `.badRequest(reason, message)` | false | true | nil | `Request rejected` |
| `.server(status)` | true | true | nil | `Gmail server error` |
| `.decoding(_)` | false | true | nil | `Unexpected response` |
| `.batchMalformed` | true | true | nil | `Unexpected response` |
| `.cancelled` | false | false | nil | `Cancelled` |

`description`: `offline`, `network(-1001)`, `unauthorized`, `forbidden(insufficientPermissions)` / `forbidden(nil)`, `rateLimited(retryAfter: 7.0)` / `rateLimited(retryAfter: nil)`, `notFound`, `historyExpired`, `badRequest(failedPrecondition: Invalid startHistoryId: 1)` (nil parts rendered as `nil`), `server(503)`, `decoding(<text>)`, `batchMalformed`, `cancelled`.

### 4.2 The request core (`GmailClient.request`)

Internal signature (architecture §6.1's snippet returns `Data`; this returns the response too because the batch runner needs the outer `Content-Type` — D6):

```swift
private func request(_ method: String, url: URL, body: Data?, contentType: String?, policy: RetryPolicy, endpoint: String, logPath: String)
    async throws -> (Data, HTTPURLResponse)
```

Algorithm (one call = one permit held for the whole attempt loop, as in architecture §6.1):

```
try await limiter.withPermit {
    var attempt = 0          // retries performed
    var didRefresh = false   // one 401 refresh per request() call
    while true {
        // 1. cancellation
        if Task.isCancelled { throw GmailError.cancelled }
        // 2. token
        let token: String
        do { token = try await tokens.accessToken() }
        catch is AuthError { throw GmailError.unauthorized }                 // signedOut / needsReauth / missingRefreshToken / keychain — AuthStore was told by onNeedsReauth
        catch let g as GmailError {                                          // transport failure during refresh (module 04 maps to .offline/.network)
            if policy.allows(g, attempt: attempt) { try await pause(delay(attempt: attempt, retryAfter: nil)); attempt += 1; continue }
            throw g }
        catch is CancellationError { throw GmailError.cancelled }
        catch { throw GmailError.network(code: -1) }
        // 3. request
        var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let started = ContinuousClock.now
        let data: Data; let http: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            guard let h = r as? HTTPURLResponse else { throw GmailError.decoding("non-HTTP response") }
            data = d; http = h
        } catch let e as URLError {
            let g = GmailError.map(e)
            record(method, logPath, status: -1, since: started); Log.net.error("\(method) \(logPath) transport \(g)")
            if g == .cancelled { throw g }
            if policy.allows(g, attempt: attempt) { Log.net.notice("retry \(attempt + 1) after \(g)"); try await pause(delay(attempt: attempt, retryAfter: nil)); attempt += 1; continue }
            throw g
        } catch let g as GmailError { throw g }
          catch is CancellationError { throw GmailError.cancelled }
          catch { throw GmailError.network(code: -1) }
        record(method, logPath, status: http.statusCode, since: started)   // RequestLog + Log.net.debug("GET profile 200 87ms")
        // 4. status
        switch http.statusCode {
        case 200...299: return (data, http)
        case 401 where !didRefresh:
            didRefresh = true; await tokens.invalidateAccessToken(); Log.net.notice("401 → token refresh"); continue      // no sleep, attempt unchanged
        case 401: throw GmailError.unauthorized
        default:
            let g = GmailError.map(status: http.statusCode, body: data, headers: http.allHeaderFields, endpoint: endpoint)
            if policy.allows(g, attempt: attempt) {
                if let ra = g.retryAfter, ra > Self.maxInRequestRetryAfter { Log.net.notice("Retry-After \(ra)s too long"); throw g }   // D5
                Log.net.notice("retry \(attempt + 1) after \(g)"); try await pause(delay(attempt: attempt, retryAfter: g.retryAfter)); attempt += 1; continue }
            Log.net.error("\(method) \(logPath) \(g)"); throw g
        }
    }
}
```

Helpers:
- `pause(_ seconds)`: `do { try await sleep(seconds) } catch { throw GmailError.cancelled }`.
- `delay(attempt:retryAfter:)`: `if let retryAfter { return retryAfter }`; else `raw = min(16, pow(2, Double(attempt)))` (1, 2, 4, 8, 16 s), `return raw * (0.75 + 0.5 * random())` (± 25 % jitter; `random()` ∈ [0, 1)). Same constants as `Backoff.transient` (architecture §2.2: base 1 s, factor 2, cap 16 s, jitter 25 %) — D4.
- `record(method, logPath, status, since)`: `ms = Int((ContinuousClock.now - started) / .milliseconds(1))`; `log?.record(method:path:status:ms:)`; `Log.net.debug("\(method, privacy: .public) \(logPath, privacy: .public) \(status, privacy: .public) \(ms, privacy: .public)ms")`. `logPath` = endpoint + `?` + query (§4.3) — never the token, never headers, never bodies.
- Thrown-error guarantee: every error leaving `request` is a `GmailError`.

Retry table realised by `RetryPolicy` (architecture §6.2):

| Error | reads (`RetryPolicy.reads`) | `send` (`RetryPolicy.send`) | Delay |
|---|---|---|---|
| `.rateLimited` | 4 | 0 | `Retry-After` (≤ 30 s) else 1, 2, 4, 8 s ± 25 % |
| `.server` | 3 | 0 | 1, 2, 4 s ± 25 % |
| `.network` | 2 | 0 | 1, 2 s ± 25 % |
| `.offline` | 0 | 0 | fail fast |
| `.unauthorized` | 1 refresh (both) | 1 refresh | none |
| everything else | 0 | 0 | — |

The `.batchMalformed` row of the architecture table (1 retry, 1 s) is implemented by the batch runner (§4.5), not by `request`. Maximum wall time of one read request with all retries and no `Retry-After`: 30 s × 5 attempts + 15 s ± 25 % sleeps.

### 4.3 URL construction

- Non-batch URL: `Self.baseURL.absoluteString + endpoint + "?" + QueryEncoding.query(items)` where `items` is the ordered list of `(key, value)` pairs of the endpoint table (§5.1), always ending with `("prettyPrint", "false")`. Repeated keys are emitted as repeated pairs (`[gmail-api gotcha 22]`). The string is turned into `URL(string:)` (never `URLComponents.queryItems`, which leaves `+` unencoded and would corrupt `rfc822msgid:` queries).
- `QueryEncoding.query`: each key and value → `addingPercentEncoding(withAllowedCharacters: queryValueAllowed)` where `queryValueAllowed` = ASCII letters/digits + `-._~` + `,/:()`. Consequences: `fields=id,threadId,payload/mimeType` and `history(id,messagesAdded(...))` stay readable; `q=rfc822msgid:<a+b@x.de>` → `q=rfc822msgid:%3Ca%2Bb%40x.de%3E`; a space → `%20`; `&`, `=`, `+`, `#`, `%` are always encoded.
- Path segments (message ids, thread ids, label ids, attachment ids): `QueryEncoding.segment` = percent-encode everything outside ASCII alphanumerics + `-._~` (attachment ids contain `-`/`_`; `=` becomes `%3D`).
- Batch part paths: `"/gmail/v1/users/me/" + endpoint + "?" + query` (host-relative, `[gmail-api §12]`).

### 4.4 Endpoint methods

Each method: build the URL (§5.1), call `request` with `policy: .reads` (`.send` for `send`), decode with `JSONDecoder()` (default keys/dates; DTOs from module 03), map decode failures to `GmailError.decoding("<Type>: <error description>")`.

1. `getProfile()`: GET `profile` → `GmailProfile`.
2. `listLabels()`: GET `labels` → `GmailListLabelsResponse` → `labels ?? []`.
3. `getLabels(ids:)`: `runBatch(keys: distinct(ids), call: { id in GET /gmail/v1/users/me/labels/{id}?prettyPrint=false }, decode: GmailLabel)`. Empty `ids` → `[:]` with no request.
4. `listMessages(labelIds:q:maxResults:pageToken:)`: `precondition(1...500 ~= maxResults)`. Query order: `labelIds` (one pair per id, in the given order), `q` (if non-nil), `maxResults`, `pageToken` (if non-nil), `prettyPrint`. → `GmailListMessagesResponse` (`messages` absent on the last empty page — decoder keeps nil; callers use `?? []`).
5. `getMessage(id:format:fields:)`: query: `format`, then for `.metadata` one `metadataHeaders` pair per `gmailMetadataHeaders` entry in order, then `fields` if non-nil, then `prettyPrint`. → `GmailMessage`.
6. `getMessages(ids:format:)`: `runBatch` over `distinct(ids)` with part path = `getMessage` path/query where for `.metadata` `fields` = `Self.metadataFieldsMask` (`id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers`, architecture §4.4) and for `.full`/`.minimal`/`.raw` no `fields`. Decode `GmailMessage`.
7. `getThread(id:format:)`: `precondition(format != .raw)`. Query: `format`, `metadataHeaders`×9 for `.metadata`, `prettyPrint`. → `GmailThread`.
8. `listHistory(startHistoryId:pageToken:)`: query order: `startHistoryId` (decimal), `maxResults=500`, `historyTypes=messageAdded`, `historyTypes=messageDeleted`, `historyTypes=labelAdded`, `historyTypes=labelRemoved`, `pageToken` (if non-nil), `fields=<historyFieldsMask>`, `prettyPrint`. Endpoint `history` → 404 and history-400 map to `.historyExpired`. → `GmailListHistoryResponse`.
9. `modifyThreads(_:)`: `precondition(Set(calls.map(\.opId)).count == calls.count)`. `runBatch(keys: calls.map(\.opId), call: { c in POST /gmail/v1/users/me/threads/{c.threadId}/modify?prettyPrint=false, jsonBody: encode(GmailModifyRequest(addLabelIds: c.add.isEmpty ? nil : c.add, removeLabelIds: c.remove.isEmpty ? nil : c.remove)) }, decode: GmailThread)`. JSON encoder: `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]` (spec 03 §5.1). Empty `calls` → `[:]`, no request.
10. `send(raw:threadId:)`: body = `GmailSendRequest(raw: Base64URL.encode(raw), threadId: threadId)` encoded as above (`Base64URL.encode` emits padding; Gmail accepts padded base64url, `[mime-rfc §1.2]`); POST `messages/send?prettyPrint=false`, `Content-Type: application/json`, `policy: .send`. → `GmailMessage`. No size guard (module 07 refuses > 20 MB before building). One POST: a `.rateLimited`/`.server`/`.network` throws immediately; the 401 refresh-once path still applies (the request has not been accepted by Gmail when it answers 401).
11. `getAttachment(messageId:attachmentId:)`: GET `messages/{messageId}/attachments/{attachmentId}?prettyPrint=false` → `GmailPartBody`; `guard let s = body.data, let bytes = Base64URL.decode(s) else throw .decoding("attachment: no data")` → bytes. 404 → `.notFound` (callers re-resolve the id once, architecture §14 #13).
12. `listSendAs()`: GET `settings/sendAs` → `GmailListSendAsResponse` → `sendAs ?? []`.

`distinct(ids)`: first occurrence wins, order preserved.

### 4.5 Batch runner (`runBatch`) — architecture §6.3

```swift
private func runBatch<Key: Hashable & Sendable, T: Decodable & Sendable>(
    keys: [Key], makeCall: (Key, String /*partId*/) -> (call: BatchCall, endpoint: String), decode: @Sendable (Data) throws -> T
) async throws -> [Key: Result<T, GmailError>]
```

```
guard !keys.isEmpty else return [:]
var results: [Key: Result<T, GmailError>] = [:]
for chunk in keys.chunked(Self.batchChunkSize):                              // 25; chunks strictly sequential
    parts = chunk.enumerated().map { (n, key) in BatchPart(key: key, call: makeCall(key, "p\(n)").call, endpoint: …) }   // Content-ID "p0"…"p24"
    results.merge(await runChunk(parts, decode)) { _, new in new }
return results
```

```
runChunk(parts, decode) -> [Key: Result]:
    var out = [:]; var pending = parts; var round = 0; var refreshed = false; var malformedRetried = false
    while true:
        boundary = "batch_minimail_" + 16 lowercase hex chars (from UUID().uuidString without dashes, first 16)   // RFC 2046 ≤ 70 chars, module 03 precondition
        body = BatchCodec.encode(pending.map(\.call), boundary: boundary)
        let data, http
        do { (data, http) = try await request("POST", url: Self.batchURL, body: body, contentType: "multipart/mixed; boundary=\(boundary)",
                                              policy: .reads, endpoint: "batch", logPath: "batch/gmail/v1?parts=\(pending.count)") }
        catch let g as GmailError { for p in pending { out[p.key] = .failure(g) }; return out }      // outer non-2xx/transport after request()'s own retries: every pending part fails alike
        // outer 2xx: split
        ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let decoded: [BatchPartResponse]
        if let b = BatchCodec.boundary(fromContentType: ct), let d = try? BatchCodec.decode(body: data, boundary: b) { decoded = d }
        else {
            if !malformedRetried { malformedRetried = true; Log.net.notice("batch malformed → retry once"); try await pause(1); continue }   // architecture §6.3: once, 1 s; same pending parts
            for p in pending { out[p.key] = .failure(.batchMalformed) }; return out
        }
        byId = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var transient: [BatchPart] = []; var unauthorizedParts: [BatchPart] = []
        for p in pending:
            guard let r = byId[p.call.id] else { out[p.key] = .failure(.batchMalformed); continue }       // id missing from the response: no retry
            switch r.status:
            case 200...299: out[p.key] = Result { try decode(r.body) }.mapError { .decoding("\(T.self): \($0)") }
            case 401: unauthorizedParts.append(p)
            default:
                let g = GmailError.map(status: r.status, body: r.body, headers: [:], endpoint: p.endpoint)   // per-part Retry-After not available (spec 03 A10)
                switch g { case .rateLimited, .server: transient.append(p)          // collected for the next round
                           default: out[p.key] = .failure(g) }                       // notFound, badRequest, forbidden, historyExpired(never for batched endpoints)
        // 401 parts
        if !unauthorizedParts.isEmpty:
            if !refreshed:
                refreshed = true; await tokens.invalidateAccessToken(); Log.net.notice("batch part 401 → refresh, re-send \(unauthorizedParts.count + transient.count) parts")
                pending = unauthorizedParts + transient; continue                      // immediate re-send, does not count as a round, no sleep
            else: for p in unauthorizedParts { out[p.key] = .failure(.unauthorized) }
        // transient parts
        if transient.isEmpty { return out }
        if round >= Self.maxBatchRounds { for p in transient { out[p.key] = .failure(map result of that part) }; return out }   // keep the concrete .rateLimited/.server error
        Log.net.notice("batch round \(round + 1): re-sending \(transient.count) parts")
        try await pause(delay(attempt: round, retryAfter: nil)); round += 1; pending = transient
```
Notes:
- `pause` throwing (cancellation) propagates as `GmailError.cancelled` out of the endpoint method (the whole `runBatch` throws — partial results are dropped; the caller's next run re-fetches).
- The outer `request` call already retried outer 429/5xx/transport per `RetryPolicy.reads` and refreshed once on an outer 401; an outer 401 *after* the refresh throws `.unauthorized`, which fails every pending part with `.unauthorized`.
- The per-part error kept after `maxBatchRounds` rounds is the last mapped error for that part (`.rateLimited(retryAfter: nil)` or `.server(status)`), so `Outbox` and `SyncEngine` see `isTransient == true`.
- Rounds use the transient delay sequence 1, 2, 4 s ± 25 % (`delay(attempt: round, …)` with `round` 0, 1, 2).
- Concurrency: the batch chunk loop runs on the `GmailClient` actor between requests; each POST holds one limiter permit; sleeps between rounds hold no permit.

### 4.6 `RequestLimiter`

State: `max`, `available = max`, `waiters: [CheckedContinuation<Void, Never>]`.
- `withPermit(op)`: `await acquire()`; `defer { release() }`; `return try await op()`.
- `acquire()`: if `available > 0` → `available -= 1`, return; else `await withCheckedContinuation { waiters.append($0) }` (the resumer transfers the permit: `available` is not incremented on release when a waiter exists).
- `release()`: if `!waiters.isEmpty` → `waiters.removeFirst().resume()`; else `available += 1`.
- `inUse` = `max - available`.
Because the actor serialises `acquire`/`release`, at most `max` bodies run concurrently; FIFO order among waiters.

### 4.7 `RequestLog`

`OSAllocatedUnfairLock<[Entry]>`; `record` appends and, when `count > capacity`, `removeFirst(count - capacity)`. `snapshot` formats with a cached `DateFormatter` (`en_US_POSIX`, `dateFormat = "HH:mm:ss.SSS"`, `timeZone = .current`) → `"\(time) \(method) \(path) \(status) \(ms)ms"`. Cost of `record`: one lock + array append (< 5 µs); called once per HTTP attempt.

### 4.8 `URLSession.minimail(protocolClasses:)` (architecture §6.1)

```swift
let c = URLSessionConfiguration.default
c.timeoutIntervalForRequest = 30
c.timeoutIntervalForResource = 120
c.waitsForConnectivity = false                 // fail fast into .offline; the next trigger retries (D11)
c.httpMaximumConnectionsPerHost = 2
c.urlCache = nil
c.requestCachePolicy = .reloadIgnoringLocalCacheData
c.httpAdditionalHeaders = ["Accept": "application/json"]
c.allowsExpensiveNetworkAccess = true
c.allowsConstrainedNetworkAccess = true
c.httpShouldSetCookies = false                 // ADDITION: Gmail REST needs no cookies; avoids the cookie store
if let protocolClasses { c.protocolClasses = protocolClasses }
return URLSession(configuration: c)
```
A new `URLSession` per call (the app calls it once in `AppEnvironment.init`; tests once per test). Never a background session (`[ios-platform §3.5]`).

### 4.9 `AppEnvironment` insertion (`[05]`)

Spec 01 §3.10 leaves the comment `// [05][07][08] GmailClient / …`. This module replaces the `[05]` part with, in `init(testing:)` after the `[04]` block (`tokens`, `auth`) and `theme`:

```swift
#if DEBUG
requestLog = RequestLog()
#else
requestLog = nil
#endif
limiter = RequestLimiter(max: 2)
gmail = GmailClient(tokens: tokens,
                    session: .minimail(protocolClasses: testing ? AppEnvironment.testURLProtocolClasses : nil),
                    limiter: limiter, log: requestLog)
auth.fetchProfile = { [gmail] in try await gmail.getProfile() }     // the closure module 04's AuthStore calls after adopt() (§10 A1 for the property name)
```
Stored properties added: `let requestLog: RequestLog?`, `let limiter: RequestLimiter`, `let gmail: GmailClient`, and `nonisolated(unsafe) static var testURLProtocolClasses: [AnyClass] = [OfflineURLProtocol.self]` (tests assign `[StubURLProtocol.self]` before constructing an environment; module 14 documents this). Construction only — no I/O, no `Task`, keeps the < 15 ms launch budget (actor init is allocation only). `startDeferredWork()` is not touched by this module.

### 4.10 Isolation and concurrency summary

- `GmailClient`, `RequestLimiter`: actors. All endpoint methods are `async throws`; results are `Sendable` DTOs.
- `GmailError`, `ThreadModifyCall`, `RequestLog`, `RetryPolicy`, `QueryEncoding`, `OfflineURLProtocol`, `StubURLProtocol`: `nonisolated`.
- `TokenProvider` is `any TokenProvider` (Sendable protocol from module 04); the client never retains `OIDAuthState`.
- `sleep`/`random` closures are `@Sendable`, stored as `let`s in the actor.
- Reentrancy: while one `request` awaits the network, another `getX` call may enter the actor; the limiter (not the actor) bounds concurrency. No shared mutable state exists in the actor besides the immutable dependencies, so reentrancy is harmless.
- Cancellation: `Task.isCancelled` before each attempt; `CancellationError` from `sleep` or `session.data` → `.cancelled`; BG refresh (module 07) relies on this between calls.

### 4.11 Performance constraints

- URL/body construction per request: < 0.2 ms (string concatenation only; the metadata `fields`/`metadataHeaders` query is a precomputed constant `Self.metadataQuery`).
- Decoding a 25-part `format=full` batch (≈ 5 MB): `BatchCodec.decode` (< 50 ms, spec 03 §4.7) + 25 `JSONDecoder` runs; total < 300 ms on an iPhone 12-class device, off the main thread (actor). No test gate; measured via the `hydrateBatch` signpost in module 07.
- Steady memory: at most 2 response bodies in flight (limiter) — a full-format batch body ≤ ~6 MB each.
- Quota (pessimistic, UNVERIFIED `[gmail-api "Quotas"]`): sequential 25-part chunks with `RequestLimiter(2)` keep any minute under ~2,600 units during initial sync (architecture §6.4); the client adds no speculative request.

---

## 5. Data

### 5.1 Exact request shapes

Base `B` = `https://gmail.googleapis.com/gmail/v1/users/me/`; `MH` = `metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=In-Reply-To&metadataHeaders=References`; `MF` = `fields=id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers`; `HF` = `fields=history(id,messagesAdded(message(id,threadId,labelIds)),messagesDeleted(message(id,threadId)),labelsAdded(message(id,threadId,labelIds),labelIds),labelsRemoved(message(id,threadId,labelIds),labelIds)),nextPageToken,historyId`.

| Method | HTTP | URL / part line | Body |
|---|---|---|---|
| `getProfile()` | GET | `B profile?prettyPrint=false` | — |
| `listLabels()` | GET | `B labels?prettyPrint=false` | — |
| `getLabels(ids: ["INBOX","Label_12"])` | POST batch | parts `GET /gmail/v1/users/me/labels/INBOX?prettyPrint=false`, `GET /gmail/v1/users/me/labels/Label_12?prettyPrint=false` | multipart (§5.2) |
| `listMessages(labelIds: ["INBOX"], q: nil, maxResults: 100, pageToken: nil)` | GET | `B messages?labelIds=INBOX&maxResults=100&prettyPrint=false` | — |
| `listMessages(labelIds: ["INBOX","UNREAD"], q: nil, maxResults: 50, pageToken: "p2")` | GET | `B messages?labelIds=INBOX&labelIds=UNREAD&maxResults=50&pageToken=p2&prettyPrint=false` | — |
| `listMessages(labelIds: [], q: "rfc822msgid:<a+b@x.de>", maxResults: 1, pageToken: nil)` | GET | `B messages?q=rfc822msgid:%3Ca%2Bb%40x.de%3E&maxResults=1&prettyPrint=false` | — |
| `getMessage(id: "m1", format: .full, fields: nil)` | GET | `B messages/m1?format=full&prettyPrint=false` | — |
| `getMessage(id: "m1", format: .metadata, fields: nil)` | GET | `B messages/m1?format=metadata&MH&prettyPrint=false` | — |
| `getMessage(id: "m1", format: .minimal, fields: "id,labelIds")` | GET | `B messages/m1?format=minimal&fields=id,labelIds&prettyPrint=false` | — |
| `getMessages(ids: ["m1"], format: .metadata)` | POST batch | part `GET /gmail/v1/users/me/messages/m1?format=metadata&MH&MF&prettyPrint=false` | multipart |
| `getMessages(ids: ["m1"], format: .full)` | POST batch | part `GET /gmail/v1/users/me/messages/m1?format=full&prettyPrint=false` | multipart |
| `getThread(id: "t1", format: .full)` | GET | `B threads/t1?format=full&prettyPrint=false` | — |
| `getThread(id: "t1", format: .metadata)` | GET | `B threads/t1?format=metadata&MH&prettyPrint=false` | — |
| `listHistory(startHistoryId: 1234501, pageToken: nil)` | GET | `B history?startHistoryId=1234501&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted&historyTypes=labelAdded&historyTypes=labelRemoved&HF&prettyPrint=false` | — |
| `listHistory(startHistoryId: 1234501, pageToken: "n1")` | GET | `…&historyTypes=labelRemoved&pageToken=n1&HF&prettyPrint=false` | — |
| `modifyThreads([ThreadModifyCall(opId: 7, threadId: "t1", add: [], remove: ["INBOX"])])` | POST batch | part `POST /gmail/v1/users/me/threads/t1/modify?prettyPrint=false` | part body `{"removeLabelIds":["INBOX"]}` |
| `modifyThreads([… add: ["UNREAD"], remove: ["INBOX"]])` | POST batch | same | `{"addLabelIds":["UNREAD"],"removeLabelIds":["INBOX"]}` |
| `send(raw: bytes, threadId: "t1")` | POST | `B messages/send?prettyPrint=false`, `Content-Type: application/json` | `{"raw":"<Base64URL.encode(bytes)>","threadId":"t1"}` |
| `send(raw: bytes, threadId: nil)` | POST | same | `{"raw":"<…>"}` |
| `getAttachment(messageId: "m1", attachmentId: "ANGjdJ8w-_x=")` | GET | `B messages/m1/attachments/ANGjdJ8w-_x%3D?prettyPrint=false` | — |
| `listSendAs()` | GET | `B settings/sendAs?prettyPrint=false` | — |

Headers on every request: `Authorization: Bearer <token>` (per attempt, fresh from `tokens.accessToken()`), `Accept: application/json` (session), `Content-Type` only with a body. No `User-Agent` override, no `quotaUser`, no `access_token` query parameter (`[gmail-api Common facts]`).

### 5.2 Batch request bytes (`modifyThreads`, one part)

```
POST https://www.googleapis.com/batch/gmail/v1
Authorization: Bearer ya29…
Content-Type: multipart/mixed; boundary=batch_minimail_0123456789abcdef

--batch_minimail_0123456789abcdef⏎
Content-Type: application/http⏎
Content-ID: <p0>⏎
⏎
POST /gmail/v1/users/me/threads/t1/modify?prettyPrint=false⏎
Content-Type: application/json⏎
⏎
{"removeLabelIds":["INBOX"]}⏎
⏎
--batch_minimail_0123456789abcdef--⏎
```
(Exact byte layout is `BatchCodec.encode`, spec 03 §4.5.) A response part is matched by `Content-ID: <response-p0>` → id `p0` → `keys[0]`.

### 5.3 Batch response handling matrix (per part, inner status → result)

| inner status | result for that key | next action |
|---|---|---|
| 200–299, body decodes | `.success(T)` | final |
| 200–299, body does not decode | `.failure(.decoding(…))` | final |
| 401 (first time in this chunk) | — | `invalidateAccessToken()`; re-send all non-final parts immediately |
| 401 (after the refresh) | `.failure(.unauthorized)` | final |
| 403 quota reasons / 429 | `.failure(.rateLimited)` after 3 rounds | re-sent in rounds 1–3 with 1, 2, 4 s ± 25 % |
| 5xx | `.failure(.server(status))` after 3 rounds | same |
| 403 other | `.failure(.forbidden(reason))` | final |
| 404 | `.failure(.notFound)` | final |
| 400 / other 4xx | `.failure(.badRequest(reason, message))` | final |
| id absent from the response | `.failure(.batchMalformed)` | final (no retry for that id) |
| outer body unparsable | all pending `.failure(.batchMalformed)` after one 1 s retry | — |
| outer request threw `GmailError` g | all pending `.failure(g)` | — |

### 5.4 Constants

| Name | Value |
|---|---|
| `GmailClient.batchChunkSize` | 25 |
| `GmailClient.maxBatchRounds` | 3 |
| `GmailClient.maxInRequestRetryAfter` | 30 s |
| `GmailClient.metadataFieldsMask` | `id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers` |
| `GmailClient.historyFieldsMask` | `history(id,messagesAdded(message(id,threadId,labelIds)),messagesDeleted(message(id,threadId)),labelsAdded(message(id,threadId,labelIds),labelIds),labelsRemoved(message(id,threadId,labelIds),labelIds)),nextPageToken,historyId` |
| history `maxResults` | 500 |
| boundary | `batch_minimail_` + 16 lowercase hex (31 chars) |
| batch Content-ID | `p0` … `p24` |
| transient delays | `min(16, 2^attempt) × (0.75 + 0.5·random)` seconds |
| `RequestLog.capacity` | 100 |
| `RequestLimiter` default `max` | 2 |
| session timeouts | request 30 s, resource 120 s |

### 5.5 `RequestLog.snapshot()` line examples

```
10:00:01.234 GET profile?prettyPrint=false 200 87ms
10:00:01.900 GET messages?labelIds=INBOX&maxResults=100&prettyPrint=false 200 140ms
10:00:02.410 POST batch/gmail/v1?parts=25 200 612ms
10:00:09.001 GET history?startHistoryId=1234501&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted&historyTypes=labelAdded&historyTypes=labelRemoved&fields=history(id,…),nextPageToken,historyId&prettyPrint=false 404 95ms
10:00:12.500 POST messages/send?prettyPrint=false -1 30001ms
```

### 5.6 Fixtures consumed (module 03, copied into the `minimailTests` bundle)

`profile.json`, `labels.list.json`, `labels.get.inbox.json`, `labels.get.user.json`, `messages.list.inbox.1.json`, `messages.list.inbox.2.json`, `messages.get.metadata.plain.json`, `messages.get.full.a.json`, `threads.get.full.json`, `attachments.get.png.json`, `history.empty.json`, `history.404.json`, `error.401.json`, `error.403-rate.json`, `error.403-admin.json`, `error.429.json`, `error.500.json`, `error.400-invalid-history.json`, `threads.modify.response.json`, `send.response.json`, `sendas.list.json`, `batch.response.sample.txt`, `batch.response.mixed.txt`, `batch.response.all-fail.txt`.

Loader (private in each test file, the module 14 `FixtureLoader` may replace it later):
```swift
func fixture(_ name: String) throws -> Data {   // "profile.json"
    let b = Bundle(for: GmailClientTests.self)
    let (stem, ext) = split at last "."
    let url = b.url(forResource: stem, withExtension: ext, subdirectory: "Fixtures/gmail") ?? b.url(forResource: stem, withExtension: ext)   // folder reference, or flattened fallback (spec 01 §5.1 project.yml fallback)
    guard let url else { throw XCTSkip("fixture \(name) missing from the test bundle") }
    return try Data(contentsOf: url)
}
func crlf(_ d: Data) -> Data   // same rule as spec 03 §5.8
```
Batch response fixtures are built for the stub with the boundary named inside the fixture (`batch.response.sample.txt` uses `batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN`; the test passes that boundary to `Response.batch(_:boundary:)`). Tests that need part ids `p0…` synthesise bodies with a private `batchBody(boundary:parts: [(id, status, json)])` helper instead of the fixtures.

---

## 6. UI

None. This module has no screen. The only user-visible artefacts are `GmailError.userMessage` strings (§4.1.3), rendered by modules 07/09, and `RequestLog.snapshot()` lines rendered by module 13 (DEBUG).

---

## 7. Tests

All tests below run via `xcodebuild` on the simulator (`make test-app`, or `make test-one T=minimailTests/<Class>`). None run under `swift test` (the app target is not a package). Every `GmailClient` under test is built by a private helper:

```swift
@MainActor final class GmailClientTests: XCTestCase {
    var tokens: StubTokenProvider!; var sleeps: SleepRecorder!; var log: RequestLog!
    override func setUp() { StubURLProtocol.reset(); tokens = StubTokenProvider(tokens: ["tok1", "tok2", "tok3"]); sleeps = SleepRecorder(); log = RequestLog() }
    func makeClient(random: Double = 0.5, limiter: RequestLimiter = RequestLimiter(max: 2)) -> GmailClient {
        GmailClient(tokens: tokens, session: .minimail(protocolClasses: [StubURLProtocol.self]), limiter: limiter, log: log,
                    sleep: { [sleeps] in await sleeps!.add($0) }, random: { random })
    }
}
/// Token provider stub: returns tokens in order (last repeats); counts invalidations; optional error to throw.
actor StubTokenProvider: TokenProvider { init(tokens: [String], error: (any Error)? = nil); var invalidations: Int; var issued: Int; func accessToken() async throws -> String; func invalidateAccessToken() async }
actor SleepRecorder { private(set) var durations: [TimeInterval]; func add(_ d: TimeInterval) }
```
With `random = 0.5` the jitter factor is exactly 1.0, so transient delays are 1, 2, 4, 8 s. Helpers `ok(_ fixtureName)` = `Response.json(200, fixture)`, `err(_ status, _ fixtureName, headers:)`, `part(id, status, body)` and `batchBody(boundary:parts:)` are private to the test file. "Request n" below means `StubURLProtocol.recorded[n]`.

| Test file | Test | Setup | Assertions |
|---|---|---|---|
| `minimailTests/Gmail/GmailErrorTests.swift` | `testURLErrorOffline` | the four offline codes | each `GmailError.map(URLError(code)) == .offline` |
| same | `testURLErrorCancelled` | `.cancelled` | `== .cancelled` |
| same | `testURLErrorOther` | `.timedOut`, `.cannotConnectToHost` | `== .network(code: -1001)`, `== .network(code: -1004)` |
| same | `testMap400HistoryFailedPrecondition` | `error.400-invalid-history.json`, endpoint `history` | `== .historyExpired` |
| same | `testMap400HistoryMessageMentionsHistoryId` | body `{"error":{"code":400,"message":"Invalid historyId","errors":[{"reason":"invalidArgument"}]}}`, endpoint `history` | `== .historyExpired` |
| same | `testMap400OtherEndpoint` | same fixture, endpoint `messages/m1` | `== .badRequest(reason: "failedPrecondition", message: "Invalid startHistoryId: 1")` |
| same | `testMap400HistoryUnrelated` | body reason `invalidArgument`, message `Invalid pageToken`, endpoint `history` | `== .badRequest(reason: "invalidArgument", message: "Invalid pageToken")` |
| same | `testMap401` | `error.401.json` | `== .unauthorized` |
| same | `testMap403RateWithRetryAfter` | `error.403-rate.json`, headers `["Retry-After": "7"]` | `== .rateLimited(retryAfter: 7)` |
| same | `testMap403QuotaReasons` | bodies with reasons `rateLimitExceeded`, `quotaExceeded`, `concurrentLimitExceeded`, no header | each `== .rateLimited(retryAfter: nil)` |
| same | `testMap403Admin` | `error.403-admin.json` | `== .forbidden(reason: "insufficientPermissions")` |
| same | `testMap403DailyLimit` | reason `dailyLimitExceeded` | `== .forbidden(reason: "dailyLimitExceeded")`; `.userMessage == "Daily quota exceeded"` |
| same | `testMap403NoBody` | empty body | `== .forbidden(reason: nil)` |
| same | `testMap404History` | `history.404.json`, endpoint `history` | `== .historyExpired` |
| same | `testMap404Message` | same body, endpoint `messages/m1` | `== .notFound` |
| same | `testMap429Seconds` | `error.429.json`, `["retry-after": "3"]` (lowercase key) | `== .rateLimited(retryAfter: 3)` |
| same | `testMap429HTTPDate` | header `Fri, 11 Sep 2026 10:00:10 GMT`, `now` = 2026-09-11T10:00:00Z | `== .rateLimited(retryAfter: 10)` |
| same | `testMap429PastHTTPDate` | header date 10 s before `now` | `== .rateLimited(retryAfter: 0)` |
| same | `testMap429Garbage` | header `soon` | `== .rateLimited(retryAfter: nil)` |
| same | `testMap5xx` | `error.500.json` status 500; empty body status 503 | `== .server(status: 500)`, `== .server(status: 503)` |
| same | `testMapHTMLBody` | `<html>…` bytes, status 400 and 502 | `.badRequest(reason: nil, message: nil)`, `.server(status: 502)` |
| same | `testMapOther4xx` | 409 with reason `aborted` | `== .badRequest(reason: "aborted", message: …)` |
| same | `testMap3xx` | 302 | `== .badRequest(reason: nil, message: "unexpected status 302")` |
| same | `testFlags` | every case | `isTransient` true exactly for offline/network/rateLimited/server/batchMalformed; `countsAsAttempt` false exactly for offline/cancelled/unauthorized; `retryAfter` non-nil only for `.rateLimited(retryAfter: 5)` |
| same | `testDescription` | `.rateLimited(retryAfter: 7)`, `.badRequest(reason: "x", message: nil)` | `"rateLimited(retryAfter: 7.0)"`, `"badRequest(x: nil)"` |
| `minimailTests/Gmail/RequestLimiterTests.swift` | `testCapsAtMax` | `RequestLimiter(max: 2)`; 6 tasks each `withPermit { counter.enter(); try await Task.sleep(50 ms); counter.leave() }` | `counter.maxSeen == 2`; all 6 complete |
| same | `testReleasesOnThrow` | one op throws; then `inUse` | `await limiter.inUse == 0`; a following op runs |
| same | `testFIFO` | max 1; three ops started in order with a gate | completion order `[0, 1, 2]` |
| `minimailTests/Gmail/RequestLogTests.swift` | `testRingBufferCapacity` | record 105 entries with paths `"p0"…"p104"` | `entries().count == 100`; `entries().first?.path == "p5"`; `entries().last?.path == "p104"` |
| same | `testSnapshotFormat` | one entry `GET profile?prettyPrint=false 200 87` | `snapshot()[0].hasSuffix(" GET profile?prettyPrint=false 200 87ms")`; prefix matches `^\d{2}:\d{2}:\d{2}\.\d{3} ` |
| `minimailTests/Gmail/GmailClientTests.swift` | `testGetProfileURLAndHeaders` | route GET `/gmail/v1/users/me/profile` → `ok("profile.json")` | result `.emailAddress == "user@example.com"`; request 0 `url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile?prettyPrint=false"`; `headers["Authorization"] == "Bearer tok1"`; `headers["Accept"] == "application/json"`; `body == nil` |
| same | `testListMessagesRepeatedParamsAndEncoding` | `listMessages(labelIds: ["INBOX","UNREAD"], q: "rfc822msgid:<a+b@x.de>", maxResults: 50, pageToken: "p2")` → `ok("messages.list.inbox.1.json")` | `query == "labelIds=INBOX&labelIds=UNREAD&q=rfc822msgid:%3Ca%2Bb%40x.de%3E&maxResults=50&pageToken=p2&prettyPrint=false"`; result `.nextPageToken` equals the fixture's |
| same | `testListMessagesOmitsNil` | `labelIds: [], q: nil, pageToken: nil, maxResults: 1` | `query == "maxResults=1&prettyPrint=false"` |
| same | `testGetMessageMetadataURL` | `getMessage(id: "m1", format: .metadata, fields: nil)` → `ok("messages.get.metadata.plain.json")` | `query == "format=metadata&" + MH + "&prettyPrint=false"` (MH from §5.1) |
| same | `testGetMessageFullWithFields` | `.full`, `fields: "id,labelIds"` | `query == "format=full&fields=id,labelIds&prettyPrint=false"`; `path == "/gmail/v1/users/me/messages/m1"` |
| same | `testGetThreadURL` | `getThread(id: "t1", format: .full)` → `ok("threads.get.full.json")` | `path == "/gmail/v1/users/me/threads/t1"`; `query == "format=full&prettyPrint=false"`; `result.messages?.count == 2` |
| same | `testListHistoryURL` | `listHistory(startHistoryId: 1234501, pageToken: "n1")` → `ok("history.empty.json")` | `query == "startHistoryId=1234501&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted&historyTypes=labelAdded&historyTypes=labelRemoved&pageToken=n1&" + HF + "&prettyPrint=false"` |
| same | `testListHistory404IsHistoryExpired` | route → `err(404, "history.404.json")` | thrown `== .historyExpired`; `recorded.count == 1` (no retry) |
| same | `testGetMessage404IsNotFound` | GET messages/m1 → 404 same body | thrown `== .notFound` |
| same | `testGetAttachmentDecodes` | `getAttachment(messageId: "m1", attachmentId: "ANGjdJ8w-_x=")` → `ok("attachments.get.png.json")` | `path == "/gmail/v1/users/me/messages/m1/attachments/ANGjdJ8w-_x%3D"`; bytes `== Base64URL.decode(fixture.data)`; `bytes.prefix(4) == [0x89, 0x50, 0x4E, 0x47]` |
| same | `testGetAttachmentWithoutData` | body `{"size":3}` | thrown `== .decoding("attachment: no data")` |
| same | `testListLabelsAndSendAs` | `ok("labels.list.json")`, `ok("sendas.list.json")` | `listLabels().count == 5`; `listSendAs().first?.isPrimary == true`; `path == "/gmail/v1/users/me/settings/sendAs"` |
| same | `testEmptyListsDecodeToEmptyArrays` | bodies `{}` | `listLabels() == []`; `listSendAs() == []`; `listMessages(...).messages == nil` |
| same | `testDecodingErrorOnGarbage` | 200 body `not json` | thrown case is `.decoding` (pattern match); `recorded.count == 1` |
| same | `testSendBodyAndNoRetry` | `send(raw: Data("From: a\r\n".utf8), threadId: "t1")` → `err(500, "error.500.json")` | thrown `== .server(status: 500)`; `recorded.count == 1`; request 0 `method == "POST"`, `headers["Content-Type"] == "application/json"`, `body == Data(#"{"raw":"RnJvbTogYQ0K","threadId":"t1"}"#.utf8)`; `sleeps.durations == []` |
| same | `testSendNeverRetries429` | → `err(429, "error.429.json")` | thrown `== .rateLimited(retryAfter: nil)`; `recorded.count == 1` |
| same | `testSendOmitsThreadIdAndSucceeds` | `threadId: nil` → `ok("send.response.json")` | `body == {"raw":"RnJvbTogYQ0K"}`; `result.labelIds == ["SENT"]` |
| same | `testSendRefreshesOnce401` | responses 401 then `send.response.json` | success; `recorded.count == 2`; request 1 `Authorization == "Bearer tok2"`; `tokens.invalidations == 1` |
| same | `test401RefreshOnceThenSuccess` | GET profile: `err(401, "error.401.json")`, then `ok("profile.json")` | success; `recorded.count == 2`; request 0 token `tok1`, request 1 token `tok2`; `invalidations == 1`; `sleeps.durations == []` |
| same | `test401TwiceIsUnauthorized` | 401, 401 | thrown `== .unauthorized`; `recorded.count == 2`; `invalidations == 1` |
| same | `testAuthErrorFromTokensIsUnauthorized` | `StubTokenProvider(error: AuthError.needsReauth)` | thrown `== .unauthorized`; `recorded.count == 0` |
| same | `testTransportErrorFromTokensRetried` | provider throws `GmailError.network(code: -1001)` on first call, then returns tokens | success; `sleeps.durations == [1]`; `recorded.count == 1` |
| same | `testRateLimitedRetriedFourTimes` | 429×4 then `ok("profile.json")` | success; `recorded.count == 5`; `sleeps.durations == [1, 2, 4, 8]` |
| same | `testRateLimitedExhausted` | 429×5 | thrown `== .rateLimited(retryAfter: nil)`; `recorded.count == 5`; `sleeps.durations == [1, 2, 4, 8]` |
| same | `testRetryAfterHonoured` | 429 with `Retry-After: 3`, then 200 | `sleeps.durations == [3]`; `recorded.count == 2` |
| same | `testRetryAfterTooLongThrows` | 429 with `Retry-After: 120` | thrown `== .rateLimited(retryAfter: 120)`; `recorded.count == 1`; `sleeps.durations == []` |
| same | `testJitterUsesRandom` | `makeClient(random: 0.0)` 429 then 200; then `random: 0.999` | first `sleeps.durations == [0.75]`; second `≈ 1.2495` (`accuracy: 0.001`) |
| same | `testServerRetriedThreeTimes` | 500×3 then 200; separately 500×4 | success with `recorded.count == 4`, `sleeps == [1, 2, 4]`; failure `.server(status: 500)` with `recorded.count == 4` |
| same | `testNetworkRetriedTwice` | `Response.error(.timedOut)`×2 then 200; separately ×3 | success `recorded.count == 3`, `sleeps == [1, 2]`; failure `.network(code: -1001)` with `recorded.count == 3`; `log.entries()` has status `-1` entries |
| same | `testOfflineFailsFast` | `Response.error(.notConnectedToInternet)` | thrown `== .offline`; `recorded.count == 1`; `sleeps == []` |
| same | `testForbiddenNotRetried` | `err(403, "error.403-admin.json")` | thrown `== .forbidden(reason: "insufficientPermissions")`; `recorded.count == 1` |
| same | `testCancelledTask` | `Task { try await client.getProfile() }` cancelled before the stub answers (stub `delay: 0.5`); also a pre-cancelled task | thrown `== .cancelled` in both |
| same | `testRequestLogRecords` | `getProfile` 200 | `log.entries().count == 1`; entry `method == "GET"`, `path == "profile?prettyPrint=false"`, `status == 200`, `ms >= 0` |
| same | `testBatchChunkingAt25` | `getMessages(ids: 60 ids, format: .metadata)`; handler answers each POST with 200 parts for every `Content-ID` found in the request body (parsed by the test with `BatchCodec.decode`-style split), body `messages.get.metadata.plain.json` with the id substituted | 3 POSTs to `https://www.googleapis.com/batch/gmail/v1`; part counts 25, 25, 10 (count `Content-ID: <p` occurrences); result count 60, all `.success`; `headers["Content-Type"]` hasPrefix `multipart/mixed; boundary=batch_minimail_` and boundary length 31; request bodies start with `--batch_minimail_` |
| same | `testBatchPartPathShape` | `getMessages(ids: ["m1"], format: .metadata)` | body contains `"GET /gmail/v1/users/me/messages/m1?format=metadata&" + MH + "&" + MF + "&prettyPrint=false\r\n"`; `.full` variant contains `"GET /gmail/v1/users/me/messages/m1?format=full&prettyPrint=false\r\n"` |
| same | `testBatchDedupesIds` | `ids: ["m1","m1","m2"]` | one POST with 2 parts; result keys `["m1","m2"]` |
| same | `testEmptyBatchNoRequest` | `getMessages(ids: [])`, `modifyThreads([])`, `getLabels(ids: [])` | all `== [:]`; `recorded.count == 0` |
| same | `testBatchPerPartMapping` | 4 ids; response parts: p0 200, p1 404, p2 400 (`error.400-invalid-history.json`), p3 403 admin | `m0 .success`; `m1 .failure(.notFound)`; `m2 .failure(.badRequest(reason: "failedPrecondition", …))`; `m3 .failure(.forbidden(reason: "insufficientPermissions"))`; `recorded.count == 1` |
| same | `testBatchPerPartRetryRound` | 2 ids; POST 1: p0 200, p1 429; POST 2: p1 200 | both `.success`; `recorded.count == 2`; POST 2 body contains exactly one `Content-ID: <p1>` and no `<p0>`; `sleeps == [1]` |
| same | `testBatchRoundsExhausted` | 1 id; 500 part four times | `.failure(.server(status: 500))`; `recorded.count == 4`; `sleeps == [1, 2, 4]` |
| same | `testBatchPart401RefreshResendsOnce` | 2 ids; POST 1: p0 200, p1 401; POST 2: p1 200 | both `.success`; `invalidations == 1`; POST 2 `Authorization == "Bearer tok2"` and contains only `<p1>`; `sleeps == []` |
| same | `testBatchPart401TwiceUnauthorized` | p1 401 in POST 1 and POST 2 | `m1 == .failure(.unauthorized)`; `recorded.count == 2`; `invalidations == 1` |
| same | `testBatchMissingPartIsMalformed` | 2 ids; response has only p0 | `m1 == .failure(.batchMalformed)`; `recorded.count == 1` |
| same | `testBatchMalformedOuterRetriedOnce` | body `garbage` with `multipart/mixed` type, twice | all `.failure(.batchMalformed)`; `recorded.count == 2`; `sleeps == [1]` |
| same | `testBatchWrongContentTypeThenOK` | POST 1: 200 `application/json` body; POST 2: valid parts | all `.success`; `recorded.count == 2` |
| same | `testBatchOuterErrorFailsAll` | outer `err(403, "error.403-admin.json")`; separately outer `Response.error(.notConnectedToInternet)` | every result `.failure(.forbidden(reason: "insufficientPermissions"))` / `.failure(.offline)`; `recorded.count == 1` each |
| same | `testBatchOuter429RetriedByRequestCore` | outer 429 then valid parts | success; `recorded.count == 2`; `sleeps == [1]` |
| same | `testBatchFixtureSampleDecodes` | `getMessages(ids: ["m1","m2"], format: .full)`; POST 1 answered with `crlf(fixture("batch.response.sample.txt"))` after replacing `<response-m1>`/`<response-m2>` with `<response-p0>`/`<response-p1>` (its parts are a 200 and a 401, `[gmail-api §12]`); POST 2 answers `p1` with 200 | `m1` `.success`; `m2` `.success`; `recorded.count == 2`; `invalidations == 1`; POST 2 body contains only `<p1>` |
| same | `testModifyThreadsBodyAndKeys` | `[ThreadModifyCall(opId: 7, threadId: "t1", add: [], remove: ["INBOX"]), ThreadModifyCall(opId: 9, threadId: "t2", add: ["UNREAD"], remove: ["INBOX"])]`; parts answered with `threads.modify.response.json` | body contains `"POST /gmail/v1/users/me/threads/t1/modify?prettyPrint=false\r\nContent-Type: application/json\r\n\r\n{\"removeLabelIds\":[\"INBOX\"]}\r\n"` and `"{\"addLabelIds\":[\"UNREAD\"],\"removeLabelIds\":[\"INBOX\"]}"`; result keys `[7, 9]`; `result[7]` `.success(thread)` with `thread.messages?.first?.labelIds` equal to the fixture's |
| same | `testGetLabelsBatch` | `getLabels(ids: ["INBOX","Label_12"])`; parts from `labels.get.inbox.json` / `labels.get.user.json` | one POST; body contains `GET /gmail/v1/users/me/labels/INBOX?prettyPrint=false` and `…/labels/Label_12?prettyPrint=false`; `result["Label_12"]` success with `color?.backgroundColor == "#4a86e8"` |
| same | `testLimiterCapsConcurrencyAtTwo` | stub `delay: 0.3` for every response; 6 concurrent `getProfile()` in a `TaskGroup` | all succeed; `StubURLProtocol.maxConcurrent == 2` |
| same | `testLimiterSharedAcrossBatchAndSingle` | `getMessages(ids: 30 ids)` concurrently with 3 `getProfile()`; delay 0.1 | `maxConcurrent == 2`; all succeed |
| same | `testOfflineURLProtocol` | `GmailClient(session: .minimail(protocolClasses: [OfflineURLProtocol.self]))` | `getProfile()` throws `.offline` |
| same | `testAppEnvironmentWiring` | `AppEnvironment.testURLProtocolClasses = [StubURLProtocol.self]`; `AppEnvironment(testing: true)` | `env.gmail` is non-nil (constructible); `env.limiter` `inUse == 0`; `#if DEBUG env.requestLog != nil #endif`; `recorded.count == 0` (no I/O in init) |

Total: 25 + 3 + 2 + 54 = 84 tests.

---

## 8. Tasks

- [ ] **T05.1 `GmailError`** — files: `minimail/Gmail/GmailError.swift`, `minimailTests/Gmail/GmailErrorTests.swift`. Done when the enum, both `map` functions, `RetryAfterParser`, flags, `userMessage`, `description` exist and all 25 `GmailErrorTests` pass. Verify (macOS): `make test-one T=minimailTests/GmailErrorTests`.
- [ ] **T05.2 `RequestLimiter` + `RequestLog`** — files: `minimail/Gmail/RequestLimiter.swift`, `minimail/Gmail/RequestLog.swift`, `minimailTests/Gmail/RequestLimiterTests.swift`, `minimailTests/Gmail/RequestLogTests.swift`. Done when the 5 tests pass. Verify: `make test-one T=minimailTests/RequestLimiterTests && make test-one T=minimailTests/RequestLogTests`.
- [ ] **T05.3 Session, stub and request core** — files: `minimail/Gmail/GmailClient.swift` (`URLSession.minimail`, `OfflineURLProtocol`, `ThreadModifyCall`, `QueryEncoding`, `RetryPolicy`, `request`, `delay`, `pause`, `record`, `getProfile` only), `minimailTests/Support/StubURLProtocol.swift`, `minimailTests/Gmail/GmailClientTests.swift` (helpers + tests `testGetProfileURLAndHeaders`, `test401RefreshOnceThenSuccess`, `test401TwiceIsUnauthorized`, `testAuthErrorFromTokensIsUnauthorized`, `testTransportErrorFromTokensRetried`, `testRateLimitedRetriedFourTimes`, `testRateLimitedExhausted`, `testRetryAfterHonoured`, `testRetryAfterTooLongThrows`, `testJitterUsesRandom`, `testServerRetriedThreeTimes`, `testNetworkRetriedTwice`, `testOfflineFailsFast`, `testForbiddenNotRetried`, `testCancelledTask`, `testRequestLogRecords`, `testDecodingErrorOnGarbage`, `testOfflineURLProtocol`, `testLimiterCapsConcurrencyAtTwo`). Done when these 19 tests pass and `make lint` passes (no forbidden imports in `minimail/Gmail`). Verify: `make test-one T=minimailTests/GmailClientTests && make lint`.
- [ ] **T05.4 Single-request endpoints** — file: `minimail/Gmail/GmailClient.swift` (`listLabels`, `listMessages`, `getMessage`, `getThread`, `listHistory`, `send`, `getAttachment`, `listSendAs`, the `metadataFieldsMask`/`historyFieldsMask` constants), tests `testListMessagesRepeatedParamsAndEncoding`, `testListMessagesOmitsNil`, `testGetMessageMetadataURL`, `testGetMessageFullWithFields`, `testGetThreadURL`, `testListHistoryURL`, `testListHistory404IsHistoryExpired`, `testGetMessage404IsNotFound`, `testGetAttachmentDecodes`, `testGetAttachmentWithoutData`, `testListLabelsAndSendAs`, `testEmptyListsDecodeToEmptyArrays`, `testSendBodyAndNoRetry`, `testSendNeverRetries429`, `testSendOmitsThreadIdAndSucceeds`, `testSendRefreshesOnce401`. Done when the URL strings of §5.1 are produced byte for byte and the 16 tests pass. Verify: `make test-one T=minimailTests/GmailClientTests`.
- [ ] **T05.5 Batch runner + batched endpoints** — file: `minimail/Gmail/GmailClient.swift` (`BatchPart`, `runBatch`, `runChunk`, `getMessages`, `getLabels`, `modifyThreads`), tests `testBatchChunkingAt25` … `testGetLabelsBatch` and `testLimiterSharedAcrossBatchAndSingle` (18 tests). Done when the §5.3 matrix holds for every row. Verify: `make test-one T=minimailTests/GmailClientTests`.
- [ ] **T05.6 `AppEnvironment` wiring** — file: `minimail/App/AppEnvironment.swift` (`requestLog`, `limiter`, `gmail`, `testURLProtocolClasses`, profile closure into `AuthStore`), test `testAppEnvironmentWiring`. Done when `AppEnvironment(testing: true)` constructs without I/O and `make build` succeeds in Debug and Release (`xcodebuild build … -configuration Release` once, to compile the `#else` branch of the `RequestLog` guard). Verify: `make build && make test-app` → `failedTests: 0`.

Each task is 100–350 lines of code; T05.3 and T05.5 are the largest.

---

## 9. Acceptance criteria

1. `make lint` passes: `grep -rE "^import (UIKit|SwiftUI|GRDB|AppAuth|WebKit|Security)" minimail/Gmail` prints nothing. Verify: `make lint`.
2. `make test-app` reports `failedTests: 0` with all 84 tests of §7 present (`xcrun xcresulttool get test-results tests --path .build/results/unit.xcresult | grep -c "GmailClientTests/test"` ≥ 54).
3. `getProfile()` against the stub sends exactly `GET https://gmail.googleapis.com/gmail/v1/users/me/profile?prettyPrint=false` with `Authorization: Bearer <token>` and `Accept: application/json`; never a query `access_token`. (`testGetProfileURLAndHeaders`.)
4. Metadata hydration request lines equal architecture §4.4 byte for byte (`testBatchPartPathShape`), history requests equal §6.1's mask (`testListHistoryURL`).
5. 401 handling: one `invalidateAccessToken()` + one retry with the new token; a second 401 throws `.unauthorized`; a batch part 401 re-sends the chunk once (`test401*`, `testBatchPart401*`).
6. Retry counts per error class match architecture §6.2 exactly (4/3/2/0), with delays 1, 2, 4, 8 s at zero jitter and `Retry-After` precedence (`testRateLimited*`, `testServer*`, `testNetwork*`, `testRetryAfter*`).
7. `send` performs exactly one POST for any transient error (`testSendBodyAndNoRetry`, `testSendNeverRetries429`).
8. Batches are chunked at 25, sent sequentially, matched by `Content-ID`, retried per part for at most 3 rounds, and a missing part id yields `.batchMalformed` for that id only (`testBatch*`).
9. No more than 2 HTTP requests are ever in flight for one `GmailClient` (`testLimiterCapsConcurrencyAtTwo`, `testLimiterSharedAcrossBatchAndSingle`).
10. `AppEnvironment(testing: true)` constructs `GmailClient` with no network access; a test-host launch without stubs answers `.offline` for every request (`testOfflineURLProtocol`, `testAppEnvironmentWiring`).
11. Manual device step (module 14 checklist, after 04 and 07 land): with a signed-in account, Settings → Advanced → Recent requests shows lines of the §5.5 form, none containing `ya29` (no token leakage). Verify: `log stream --predicate 'subsystem == "com.minimail" AND category == "net"'` while pulling to refresh shows `GET history?startHistoryId=… 200 <ms>ms`.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | `random:` parameter on `GmailClient.init` | DEVIATION (additive, default argument) | Needed for deterministic jitter in tests; production uses `Double.random(in: 0..<1)`. Architecture callers (`AppEnvironment`) compile unchanged. |
| D2 | `now:` parameter on `GmailError.map(status:body:headers:endpoint:now:)` | DEVIATION (additive, default `Date()`) | HTTP-date `Retry-After` needs a reference instant for tests. |
| D3 | `GmailError.retryAfter`, `userMessage`, `CustomStringConvertible` | DEVIATION (additive) | `retryAfter` is used by architecture §6.1's own snippet (`g.retryAfter`) without being declared; `userMessage` supplies the §4.8/§6.4 status strings ("Rate limited — try again later") from one place. |
| D4 | Backoff computed privately instead of `Backoff.transient` (MailCore `Sync/Backoff.swift`, module 07) | DEVIATION (dependency order) | Module 05 precedes 07 in Appendix A; identical constants (1 s base, ×2, 16 s cap, ±25 %). Module 07 may replace the private `delay` with `Backoff.transient.delay(attempt:retryAfter:random:)` in one line; `testRateLimitedRetriedFourTimes` and `testJitterUsesRandom` pin the numbers so the swap is verifiable. |
| D5 | `Retry-After` > 30 s throws immediately instead of sleeping | DEVIATION (bounded wait) | Architecture says "`Retry-After` else `Backoff.transient`"; honouring a multi-minute header while holding a limiter permit would stall every other request. The error keeps `retryAfter`, so `Outbox.retryLater` (07) still honours it via `Backoff.outbox`. |
| D6 | `request` returns `(Data, HTTPURLResponse)` | internal detail | The batch runner needs the outer `Content-Type` boundary. Not visible outside the actor. |
| D7 | Three extra test files | DEVIATION (additive, precedent spec 01 D3) | `GmailErrorTests`, `RequestLimiterTests`, `RequestLogTests` keep `GmailClientTests` focused on the client. |
| D8 | `OfflineURLProtocol` + `AppEnvironment.testURLProtocolClasses` | DEVIATION (additive) | Architecture §13.1 says `AppEnvironment(testing: true)` "uses `StubURLProtocol`", but the app target cannot reference a test-bundle class. The static hook lets module 14 inject the stub; the default blocks the network in the test host. |
| D9 | `RequestLog.Entry`, `entries()`, `capacity`; class compiled in Release (instance only created in DEBUG) | DEVIATION (additive) | Keeps `#if DEBUG` in one place (`AppEnvironment`). |
| D10 | `URLSessionConfiguration.httpShouldSetCookies = false` | DEVIATION (additive) | Not in architecture §6.1's list; harmless for a bearer-token REST API. Remove if a Google endpoint ever needs cookies (none does). |
| D11 | Batch `Content-ID` values are synthetic `p<n>` | design choice | Keys (message ids, label ids, `opId`) are mapped through an index, so no assumption about the key charset is needed (`BatchCall.id` precondition: no `<`, `>`, whitespace). |
| A1 | Name of the injected profile closure on `AuthStore` | ASSUMPTION (spec 04 not yet written) | This spec uses `auth.fetchProfile: (@Sendable () async throws -> GmailProfile)?`. Whichever of specs 04/05 is implemented second adopts the other's name; only the one line in §4.9 changes. |
| A2 | `TokenProvider.accessToken()` throws `AuthError` for auth failures and `GmailError.offline/.network` for transport failures during refresh | ASSUMPTION per architecture §5.3 | Any other thrown type is mapped to `.network(code: -1)`; `CancellationError` → `.cancelled`. |
| A3 | Google error `reason` strings for quota (`rateLimitExceeded`, `userRateLimitExceeded`, `quotaExceeded`, `concurrentLimitExceeded`, `dailyLimitExceeded`) | UNVERIFIED (`[gmail-api Common facts]`, quota page snippets) | 429 is always `.rateLimited` regardless of reason; 403 uses the reason set above. If a real 403 shows another quota reason, add it to the set (one line) and a row to `testMap403QuotaReasons`. |
| A4 | HTTP status for a malformed/expired `startHistoryId` (404 documented, 400 UNVERIFIED) | UNVERIFIED (`[gmail-api §13 item 5]`, architecture §14 #6) | Both mapped to `.historyExpired` on the history endpoint (reason `failedPrecondition` or message containing `historyid`). |
| A5 | Per-mailbox concurrent-request cap (~50) and 2026 quota units | UNVERIFIED (`[gmail-api gotcha 24, "Quotas"]`) | Limiter 2 + sequential 25-part chunks are far below either figure; module 14's device checklist fetches the quota page (architecture §14 #7). Constants may only be relaxed upward there. |
| A6 | `threads.modify` response depth (`messages[].labelIds` present?) | UNVERIFIED (`[gmail-api §9]`) | Decoded leniently as `GmailThread` (all optional); `Outbox` (07) treats absent `messages` as "apply the delta locally". |
| A7 | Gmail accepts padded base64url in `raw` | `[mime-rfc §1.2]` (module 02 encodes with `=`) | `send` passes `Base64URL.encode` output unchanged; if a real send returns 400 `invalidArgument` mentioning `raw`, strip `=` in `send` (one line) — device checklist item for module 14. |
| A8 | `Retry-After` on batch parts | not surfaced by `BatchPartResponse` (spec 03 A10) | Part rounds always use the transient delays; only the outer response's header is honoured. |
| A9 | `URLSession.data(for:)` under a custom `URLProtocol` delivers `HTTPURLResponse` with the stub's header casing | Foundation behaviour on the simulator | `RetryAfterParser` matches keys case-insensitively so both `Retry-After` and `retry-after` work (`testMap429Seconds`). |
| A10 | `nonisolated` on `URLProtocol` subclasses compiles under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | compile-time fact (architecture §14 #2) | If the compiler rejects overriding nonisolated methods in a `nonisolated` class, drop the keyword on the class and mark each override `nonisolated`; if still blocked, `@preconcurrency` on the override. Decided on the first `make build` of T05.3. |
| A11 | `ContinuousClock` arithmetic for ms (`Duration / .milliseconds(1)`) | Swift 5.7+ API | Fallback: `DispatchTime.now().uptimeNanoseconds / 1_000_000`. |
| A12 | The `Fixtures` folder reference lands at `Fixtures/gmail/<file>` in the test bundle | spec 01 §5.1 (`type: folder`) with the documented fallback | The loader tries the subdirectory first, then the bundle root; a missing fixture skips the test (`XCTSkip`) rather than failing, so a project.yml fallback does not mask real regressions elsewhere. |
