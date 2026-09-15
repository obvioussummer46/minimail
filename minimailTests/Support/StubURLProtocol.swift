import Foundation
import os

/// Scripted `URLProtocol`. Installed per `URLSession` via `URLSession.minimail(protocolClasses: [StubURLProtocol.self])`.
/// All static state is behind one lock; call `reset()` in every test's `setUp`.
nonisolated final class StubURLProtocol: URLProtocol {
    struct Request: Sendable, Equatable {
        var method: String
        var url: URL
        var path: String
        var query: String?
        var headers: [String: String]
        var body: Data?
    }
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        var transportError: URLError?
        var delay: TimeInterval

        static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> Response {
            var h = headers
            h["Content-Type"] = "application/json; charset=UTF-8"
            return Response(status: status, headers: h, body: body, transportError: nil, delay: 0)
        }
        static func batch(_ body: Data, boundary: String) -> Response {
            Response(
                status: 200,
                headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"],
                body: body, transportError: nil, delay: 0)
        }
        static func error(_ code: URLError.Code) -> Response {
            Response(status: -1, headers: [:], body: Data(), transportError: URLError(code), delay: 0)
        }
        static let empty204 = Response(status: 204, headers: [:], body: Data(), transportError: nil, delay: 0)
    }
    typealias Handler = @Sendable (Request) -> Response

    private struct State {
        var handler: Handler?
        var recorded: [Request] = []
        var inFlight = 0
        var maxConcurrent = 0
    }
    private static let state = OSAllocatedUnfairLock<State>(initialState: State())

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    static func routes(_ table: [(method: String, path: String, responses: [Response])]) {
        let queues = OSAllocatedUnfairLock<[String: [Response]]>(
            initialState: Dictionary(
                table.map { ("\($0.method) \($0.path)", $0.responses) }, uniquingKeysWith: { a, _ in a }))
        install { req in
            let key = "\(req.method) \(req.path)"
            return queues.withLock { q -> Response in
                guard var responses = q[key], !responses.isEmpty else {
                    let body = Data(
                        #"{"error":{"code":404,"message":"stub: no route","errors":[{"reason":"notFound"}],"status":"NOT_FOUND"}}"#
                            .utf8)
                    return .json(404, body)
                }
                let next = responses.count == 1 ? responses[0] : responses.removeFirst()
                q[key] = responses
                return next
            }
        }
    }

    static var recorded: [Request] { state.withLock { $0.recorded } }
    static var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false

    override func startLoading() {
        let recordedRequest = Request(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            path: request.url!.path,
            query: request.url!.query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request)
        )
        let response: StubURLProtocol.Response = Self.state.withLock { s in
            s.recorded.append(recordedRequest)
            s.inFlight += 1
            s.maxConcurrent = Swift.max(s.maxConcurrent, s.inFlight)
            return s.handler?(recordedRequest)
                ?? .json(500, Data(#"{"error":{"code":500,"message":"no handler"}}"#.utf8))
        }

        let deliver = { [weak self] in
            guard let self, !self.stopped else {
                Self.state.withLock { $0.inFlight -= 1 }
                return
            }
            if let transportError = response.transportError {
                self.client?.urlProtocol(self, didFailWithError: transportError)
            } else {
                let http = HTTPURLResponse(
                    url: self.request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                    headerFields: response.headers)!
                self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: response.body)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            Self.state.withLock { $0.inFlight -= 1 }
        }

        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { stopped = true }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
