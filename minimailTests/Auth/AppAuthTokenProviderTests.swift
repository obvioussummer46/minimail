@preconcurrency import AppAuth
import XCTest

@testable import minimail

nonisolated final class AppAuthTokenProviderTests: XCTestCase {

    private func account(_ fn: String = #function) -> String { "test.\(fn)" }
    private func clean(_ accounts: String...) { for a in accounts { try? Keychain.delete(account: a) } }

    override func setUp() {
        super.setUp()
        TokenEndpointStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TokenEndpointStub.self]
        OIDURLSessionProvider.setSession(URLSession(configuration: cfg))
    }

    override func tearDown() {
        OIDURLSessionProvider.setSession(URLSession.shared)
        TokenEndpointStub.reset()
        super.tearDown()
    }

    /// A `URLSession` whose only protocol is the stub — handed to the provider for its revoke POST.
    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TokenEndpointStub.self]
        return URLSession(configuration: cfg)
    }

    /// Builds an in-memory `OIDAuthState` without any network.
    private func makeAuthState(
        accessToken: String = "at-1",
        expiresIn: TimeInterval = 3600,
        refreshToken: String? = "rt-1"
    ) -> OIDAuthState {
        let cfg = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
        let req = OIDAuthorizationRequest(
            configuration: cfg,
            clientId: "test.apps.googleusercontent.com",
            clientSecret: nil,
            scopes: ["https://www.googleapis.com/auth/gmail.modify"],
            redirectURL: URL(string: "com.googleusercontent.apps.test:/oauth2redirect")!,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )
        let authResp = OIDAuthorizationResponse(
            request: req,
            parameters: ["code": "c" as NSString, "state": (req.state ?? "s") as NSString]
        )
        let tokenReq = OIDTokenRequest(
            configuration: cfg,
            grantType: OIDGrantTypeAuthorizationCode,
            authorizationCode: "c",
            redirectURL: req.redirectURL,
            clientID: req.clientID,
            clientSecret: nil,
            scope: nil,
            refreshToken: nil,
            codeVerifier: req.codeVerifier,
            additionalParameters: nil
        )
        var params: [String: NSCopying & NSObjectProtocol] = [
            "access_token": accessToken as NSString,
            "token_type": "Bearer" as NSString,
            "expires_in": NSNumber(value: expiresIn),
        ]
        if let refreshToken { params["refresh_token"] = refreshToken as NSString }
        let tokenResp = OIDTokenResponse(request: tokenReq, parameters: params)
        return OIDAuthState(authorizationResponse: authResp, tokenResponse: tokenResp)
    }

    // MARK: Tests

    @MainActor
    func testLoadWithoutItemIsFalse() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        let loaded = await provider.load()
        XCTAssertFalse(loaded)
        let isLoaded = await provider.isLoaded
        XCTAssertFalse(isLoaded)
        do {
            _ = try await provider.accessToken()
            XCTFail("expected signedOut")
        } catch { XCTAssertEqual(error as? AuthError, .signedOut) }
    }

    @MainActor
    func testAdoptPersistsAndLoadsAgain() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState())
        XCTAssertTrue(Keychain.exists(account: a))

        let second = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        let loaded = await second.load()
        XCTAssertTrue(loaded)
        let rt = await second.refreshToken
        XCTAssertEqual(rt, "rt-1")
        let token = try await second.accessToken()
        XCTAssertEqual(token, "at-1")
        XCTAssertTrue(TokenEndpointStub.requests.isEmpty)
    }

    @MainActor
    func testFreshTokenNeedsNoNetwork() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState(expiresIn: 3600))
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "at-1")
        XCTAssertTrue(TokenEndpointStub.requests.isEmpty)
    }

    @MainActor
    func testExpiredTokenRefreshes() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(
            status: 200, json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#)
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState(expiresIn: 30))
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "at-2")
        XCTAssertEqual(TokenEndpointStub.requests.count, 1)
        let body = TokenEndpointStub.requests.first?.body ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-1"))
    }

    @MainActor
    func testInvalidateForcesRefresh() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(
            status: 200, json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#)
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState(expiresIn: 3600))
        await provider.invalidateAccessToken()
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "at-2")
        XCTAssertEqual(TokenEndpointStub.requests.count, 1)
    }

    @MainActor
    func testSingleFlightRefresh() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(
            status: 200,
            json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#,
            delay: 0.3
        )
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState(expiresIn: 30))
        async let t1 = provider.accessToken()
        async let t2 = provider.accessToken()
        async let t3 = provider.accessToken()
        async let t4 = provider.accessToken()
        async let t5 = provider.accessToken()
        let results = try await [t1, t2, t3, t4, t5]
        XCTAssertEqual(results, Array(repeating: "at-2", count: 5))
        XCTAssertEqual(TokenEndpointStub.requests.count, 1)
    }

    @MainActor
    func testInvalidGrantLatchesAndSignals() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(
            status: 400, json: #"{"error":"invalid_grant","error_description":"Bad Request"}"#)
        let counter = Counter()
        let provider = AppAuthTokenProvider(
            keychainAccount: a,
            session: stubSession(),
            onNeedsReauth: { counter.increment() }
        )
        try await provider.adopt(makeAuthState(expiresIn: 30))
        do {
            _ = try await provider.accessToken()
            XCTFail("expected needsReauth")
        } catch { XCTAssertEqual(error as? AuthError, .needsReauth) }
        let latched = await provider.needsReauthLatched
        XCTAssertTrue(latched)
        let before = TokenEndpointStub.requests.count
        do {
            _ = try await provider.accessToken()
            XCTFail("expected needsReauth")
        } catch { XCTAssertEqual(error as? AuthError, .needsReauth) }
        XCTAssertEqual(TokenEndpointStub.requests.count, before, "latched call must not hit the network")
        XCTAssertEqual(counter.value, 1)
    }

    @MainActor
    func testAdoptClearsLatch() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(status: 400, json: #"{"error":"invalid_grant"}"#)
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState(expiresIn: 30))
        _ = try? await provider.accessToken()
        var latched = await provider.needsReauthLatched
        XCTAssertTrue(latched)

        try await provider.adopt(makeAuthState())
        latched = await provider.needsReauthLatched
        XCTAssertFalse(latched)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "at-1")
    }

    @MainActor
    func testTransportErrorIsURLError() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(status: 0, json: "", fail: .notConnectedToInternet)
        let counter = Counter()
        let provider = AppAuthTokenProvider(
            keychainAccount: a,
            session: stubSession(),
            onNeedsReauth: { counter.increment() }
        )
        try await provider.adopt(makeAuthState(expiresIn: 30))
        do {
            _ = try await provider.accessToken()
            XCTFail("expected URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let latched = await provider.needsReauthLatched
        XCTAssertFalse(latched)
        XCTAssertEqual(counter.value, 0)
    }

    @MainActor
    func testRefreshResultIsReArchived() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        TokenEndpointStub.reply = .init(
            status: 200, json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#)
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        try await provider.adopt(makeAuthState(expiresIn: 30))
        let before = try Keychain.get(account: a)
        _ = try await provider.accessToken()
        // The change delegate re-archives on a hop; give it a moment.
        try await Task.sleep(for: .milliseconds(500))
        let after = try Keychain.get(account: a)
        XCTAssertNotEqual(after, before)

        let second = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        let reloaded = await second.load()
        XCTAssertTrue(reloaded)
        let token = try await second.accessToken()
        XCTAssertEqual(token, "at-2")
    }

    @MainActor
    func testRevokeAndClearPostsAndDeletes() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let provider = AppAuthTokenProvider(
            keychainAccount: a,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
            session: stubSession()
        )
        try await provider.adopt(makeAuthState())
        TokenEndpointStub.reset()
        await provider.revokeAndClear()
        let revoke = TokenEndpointStub.requests.first(where: { $0.url.path == "/revoke" })
        XCTAssertNotNil(revoke)
        XCTAssertEqual(revoke?.method, "POST")
        XCTAssertEqual(revoke?.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(revoke?.body, "token=rt-1")
        XCTAssertFalse(Keychain.exists(account: a))
        let isLoaded = await provider.isLoaded
        XCTAssertFalse(isLoaded)
        let rt = await provider.refreshToken
        XCTAssertNil(rt)
        do {
            _ = try await provider.accessToken()
            XCTFail("expected signedOut")
        } catch { XCTAssertEqual(error as? AuthError, .signedOut) }
    }

    @MainActor
    func testRevokeWithoutStateStillDeletesItem() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        try Keychain.set(Data("junk".utf8), account: a)
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        TokenEndpointStub.reset()
        await provider.revokeAndClear()
        XCTAssertFalse(Keychain.exists(account: a))
        XCTAssertTrue(TokenEndpointStub.requests.isEmpty)
    }

    @MainActor
    func testRevokeSurvivesNetworkFailure() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let provider = AppAuthTokenProvider(
            keychainAccount: a,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
            session: stubSession()
        )
        try await provider.adopt(makeAuthState())
        TokenEndpointStub.reply = .init(status: 0, json: "", fail: .timedOut)
        await provider.revokeAndClear()
        XCTAssertFalse(Keychain.exists(account: a))
    }

    @MainActor
    func testLoadDeletesCorruptItem() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        try Keychain.set(Data("garbage".utf8), account: a)
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        let loaded = await provider.load()
        XCTAssertFalse(loaded)
        XCTAssertFalse(Keychain.exists(account: a))
    }

    @MainActor
    func testMapTokenErrorTable() {
        let map = AppAuthTokenProvider.mapTokenError

        let invalidGrantByCode = NSError(
            domain: OIDOAuthTokenErrorDomain,
            code: OIDErrorCodeOAuth.invalidGrant.rawValue
        )
        XCTAssertEqual(map(invalidGrantByCode) as? AuthError, .needsReauth)

        let invalidGrantByField = NSError(
            domain: OIDOAuthTokenErrorDomain,
            code: -1,
            userInfo: [OIDOAuthErrorResponseErrorKey: ["error": "invalid_grant"]]
        )
        XCTAssertEqual(map(invalidGrantByField) as? AuthError, .needsReauth)

        let invalidClient = NSError(
            domain: OIDOAuthTokenErrorDomain,
            code: -1,
            userInfo: [OIDOAuthErrorResponseErrorKey: ["error": "invalid_client"]]
        )
        if case .flowFailed(let t)? = map(invalidClient) as? AuthError {
            XCTAssertTrue(t.contains("invalid_client"))
        } else {
            XCTFail("expected flowFailed")
        }

        XCTAssertEqual((map(URLError(.timedOut)) as? URLError)?.code, .timedOut)

        let wrappedNetwork = NSError(
            domain: OIDGeneralErrorDomain,
            code: OIDErrorCode.networkError.rawValue,
            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
        )
        XCTAssertEqual((map(wrappedNetwork) as? URLError)?.code, .networkConnectionLost)

        let refreshError = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.tokenRefreshError.rawValue)
        XCTAssertEqual(map(refreshError) as? AuthError, .needsReauth)

        let other = NSError(domain: "Other", code: 7)
        if case .flowFailed(let t)? = map(other) as? AuthError {
            XCTAssertTrue(t.contains("Other#7"))
        } else {
            XCTFail("expected flowFailed")
        }

        if case .flowFailed? = map(nil) as? AuthError {} else { XCTFail("expected flowFailed for nil") }
    }
}

/// Thread-safe counter for `onNeedsReauth` callbacks.
nonisolated private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() {
        lock.lock()
        n += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

/// `URLProtocol` answering `oauth2.googleapis.com` (token + revoke). Installed via `OIDURLSessionProvider.setSession`
/// for token requests and the provider's injected `session` for revoke.
nonisolated private final class TokenEndpointStub: URLProtocol {
    struct Reply {
        var status: Int
        var json: String
        var delay: TimeInterval = 0
        var fail: URLError.Code?
    }
    struct Recorded {
        var url: URL
        var method: String
        var body: String
        var contentType: String?
    }

    nonisolated(unsafe) static var reply = Reply(
        status: 200,
        json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#
    )
    nonisolated(unsafe) static var storedRequests: [Recorded] = []
    static let lock = NSLock()

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock()
        storedRequests = []
        reply = Reply(status: 200, json: #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "oauth2.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            url: request.url!,
            method: request.httpMethod ?? "",
            body: Self.bodyString(request),
            contentType: request.value(forHTTPHeaderField: "Content-Type")
        )
        Self.lock.lock()
        Self.storedRequests.append(recorded)
        let reply = Self.reply
        Self.lock.unlock()

        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }

        if let fail = reply.fail {
            client?.urlProtocol(self, didFailWithError: URLError(fail))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyString(_ request: URLRequest) -> String {
        if let b = request.httpBody { return String(decoding: b, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
