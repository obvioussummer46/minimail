@preconcurrency import AppAuth
import XCTest

@testable import minimail

nonisolated final class AuthStoreTests: XCTestCase {

    private func account(_ fn: String = #function) -> String { "test.\(fn)" }
    private func clean(_ accounts: String...) { for a in accounts { try? Keychain.delete(account: a) } }

    override func setUp() {
        super.setUp()
        AuthStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AuthStub.self]
        OIDURLSessionProvider.setSession(URLSession(configuration: cfg))
    }

    override func tearDown() {
        OIDURLSessionProvider.setSession(URLSession.shared)
        AuthStub.reset()
        super.tearDown()
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AuthStub.self]
        return URLSession(configuration: cfg)
    }

    private func realConfig() -> OAuthConfig { OAuthConfig(clientID: "123.apps.googleusercontent.com") }

    @MainActor
    private func makeStore(
        hasKeychainItem: Bool,
        cachedEmail: String?,
        account: String
    ) -> (AuthStore, AppAuthTokenProvider, HookLog) {
        let relay = NeedsReauthRelay()
        let provider = AppAuthTokenProvider(
            keychainAccount: account,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
            session: stubSession(),
            onNeedsReauth: { relay.fire() }
        )
        let store = AuthStore(
            tokens: provider,
            config: realConfig(),
            hasKeychainItem: hasKeychainItem,
            cachedEmail: cachedEmail
        )
        relay.auth = store
        let log = HookLog()
        store.hooks.prepareSignOut = { log.append("prepareSignOut") }
        store.hooks.wipeAccountData = { log.append("wipeAccountData") }
        return (store, provider, log)
    }

    private func makeAuthState() -> OIDAuthState {
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
        let params: [String: NSCopying & NSObjectProtocol] = [
            "access_token": "at-1" as NSString,
            "token_type": "Bearer" as NSString,
            "expires_in": NSNumber(value: 30),
            "refresh_token": "rt-1" as NSString,
        ]
        let tokenResp = OIDTokenResponse(request: tokenReq, parameters: params)
        return OIDAuthState(authorizationResponse: authResp, tokenResponse: tokenResp)
    }

    // MARK: Routing & helpers

    @MainActor
    func testRoutingTable() {
        let a = account()
        clean(a)
        defer { clean(a) }
        XCTAssertEqual(
            makeStore(hasKeychainItem: true, cachedEmail: "a@x", account: a).0.state, .signedIn(email: "a@x"))
        XCTAssertEqual(makeStore(hasKeychainItem: true, cachedEmail: nil, account: a).0.state, .signedIn(email: nil))
        XCTAssertEqual(
            makeStore(hasKeychainItem: false, cachedEmail: "a@x", account: a).0.state,
            .needsReauth(email: "a@x")
        )
        let (store, _, _) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testStateEmailHelper() {
        XCTAssertNil(AuthStore.State.signedOut.email)
        XCTAssertEqual(AuthStore.State.signedIn(email: "a").email, "a")
        XCTAssertEqual(AuthStore.State.needsReauth(email: "b").email, "b")
        XCTAssertTrue(AuthStore.State.signedOut.isSignedOut)
        XCTAssertFalse(AuthStore.State.signedIn(email: nil).isSignedOut)
        XCTAssertFalse(AuthStore.State.needsReauth(email: nil).isSignedOut)
    }

    @MainActor
    func testMarkNeedsReauth() {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, _) = makeStore(hasKeychainItem: true, cachedEmail: "a@x", account: a)
        store.markNeedsReauth()
        XCTAssertEqual(store.state, .needsReauth(email: "a@x"))
        XCTAssertEqual(store.lastAuthError, .needsReauth)
        XCTAssertEqual(store.lastError, AuthError.needsReauth.errorDescription)
        store.markNeedsReauth()
        XCTAssertEqual(store.state, .needsReauth(email: "a@x"))

        let (out, _, _) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        out.markNeedsReauth()
        XCTAssertEqual(out.state, .signedOut)
        XCTAssertNil(out.lastError)
    }

    @MainActor
    func testHandleTokenLoad() {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, _) = makeStore(hasKeychainItem: true, cachedEmail: nil, account: a)
        store.handleTokenLoad(succeeded: true)
        XCTAssertEqual(store.state, .signedIn(email: nil))
        store.handleTokenLoad(succeeded: false)
        XCTAssertEqual(store.state, .needsReauth(email: nil))

        let (out, _, _) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        out.handleTokenLoad(succeeded: false)
        XCTAssertEqual(out.state, .signedOut)
    }

    // MARK: resume(url:)

    @MainActor
    func testResumeWithoutFlowIsFalse() {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, _) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        XCTAssertFalse(store.resume(url: URL(string: "com.googleusercontent.apps.test:/oauth2redirect?code=x")!))
    }

    @MainActor
    func testResumeWrongSchemeIsFalse() {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, _) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        let dummy = DummyFlow()
        store.currentFlow = dummy
        XCTAssertFalse(store.resume(url: URL(string: "https://example.com/")!))
        XCTAssertEqual(dummy.resumeCalls, 0)
        XCTAssertNotNil(store.currentFlow)
    }

    @MainActor
    func testResumeMatchingSchemeForwards() {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, _) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        let dummy = DummyFlow()
        store.currentFlow = dummy
        let url = store.config.redirectURL.appending(queryItems: [.init(name: "code", value: "x")])
        XCTAssertTrue(store.resume(url: url))
        XCTAssertEqual(dummy.resumeCalls, 1)
        XCTAssertNil(store.currentFlow)
    }

    // MARK: sign-in / sign-out

    @MainActor
    func testSignInWithPlaceholderConfigFails() async {
        let a = account()
        clean(a)
        defer { clean(a) }
        let provider = AppAuthTokenProvider(keychainAccount: a, session: stubSession())
        let store = AuthStore(
            tokens: provider,
            config: OAuthConfig(clientID: "REPLACE.apps.googleusercontent.com"),
            hasKeychainItem: false,
            cachedEmail: nil
        )
        do {
            try await store.signIn()
            XCTFail("expected flowFailed")
        } catch {
            guard case AuthError.flowFailed = error else { return XCTFail("expected flowFailed, got \(error)") }
        }
        XCTAssertEqual(store.lastError?.contains("GoogleClientID"), true)
        XCTAssertFalse(store.isSigningIn)
        XCTAssertEqual(store.state, .signedOut)
    }

    @MainActor
    func testSignOutOrderAndEffects() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, provider, log) = makeStore(hasKeychainItem: true, cachedEmail: "a@x", account: a)
        try await provider.adopt(makeAuthState())
        let settings = SettingsStore(defaults: isolatedDefaults(a))
        settings.update { $0.lastSignedInEmail = "a@x" }
        store.hooks.rememberEmail = { email in settings.update { $0.lastSignedInEmail = email } }
        AuthStub.reset()

        await store.signOut()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.cachedEmail)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(Keychain.exists(account: a))
        XCTAssertEqual(log.calls, ["prepareSignOut", "wipeAccountData"])
        XCTAssertEqual(AuthStub.requests.filter { $0.url.path == "/revoke" && $0.method == "POST" }.count, 1)
        XCTAssertEqual(settings.settings.lastSignedInEmail, "a@x")
    }

    @MainActor
    func testSignOutIsIdempotent() async {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, log) = makeStore(hasKeychainItem: false, cachedEmail: nil, account: a)
        AuthStub.reset()
        await store.signOut()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertTrue(AuthStub.requests.isEmpty)
    }

    @MainActor
    func testHandleAccountMismatch() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, provider, log) = makeStore(hasKeychainItem: true, cachedEmail: "a@x", account: a)
        try await provider.adopt(makeAuthState())
        AuthStub.reset()

        await store.handleAccountMismatch(expected: "a@x", got: "b@x")

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(store.lastAuthError, .accountMismatch(expected: "a@x", got: "b@x"))
        XCTAssertEqual(store.lastError?.contains("a@x"), true)
        XCTAssertEqual(store.lastError?.contains("b@x"), true)
        XCTAssertEqual(log.calls, ["prepareSignOut", "wipeAccountData"])
        XCTAssertFalse(Keychain.exists(account: a))
    }

    // MARK: pure classifiers

    @MainActor
    func testClassifyFlowErrorTable() {
        XCTAssertEqual(AuthStore.classifyFlowError(nil), .flowFailed("authorization returned neither state nor error"))

        let cancelled = NSError(
            domain: OIDGeneralErrorDomain, code: OIDErrorCode.userCanceledAuthorizationFlow.rawValue)
        XCTAssertEqual(AuthStore.classifyFlowError(cancelled), .userCancelled)

        let programCancelled = NSError(
            domain: OIDGeneralErrorDomain,
            code: OIDErrorCode.programCanceledAuthorizationFlow.rawValue
        )
        XCTAssertEqual(AuthStore.classifyFlowError(programCancelled), .userCancelled)

        let admin = NSError(
            domain: OIDOAuthAuthorizationErrorDomain,
            code: -1,
            userInfo: [
                OIDOAuthErrorResponseErrorKey: ["error": "admin_policy_enforced", "error_description": "blocked"]
            ]
        )
        let classified = AuthStore.classifyFlowError(admin)
        guard case .flowFailed(let t) = classified else { return XCTFail("expected flowFailed") }
        XCTAssertTrue(t.contains("admin_policy_enforced"))
        XCTAssertTrue(t.contains("blocked"))
        XCTAssertTrue(classified.isAdminPolicyEnforced)

        let other = NSError(domain: "X", code: 3)
        guard case .flowFailed(let t2) = AuthStore.classifyFlowError(other) else {
            return XCTFail("expected flowFailed")
        }
        XCTAssertTrue(t2.hasPrefix("X#3: "))
    }

    @MainActor
    func testShouldRetryWithoutOptionalParameters() {
        XCTAssertFalse(AuthStore.shouldRetryWithoutOptionalParameters(.flowFailed("... admin_policy_enforced")))
        XCTAssertFalse(AuthStore.shouldRetryWithoutOptionalParameters(.flowFailed("access_denied")))
        XCTAssertFalse(AuthStore.shouldRetryWithoutOptionalParameters(.flowFailed("invalid_client")))
        XCTAssertFalse(AuthStore.shouldRetryWithoutOptionalParameters(.flowFailed("redirect_uri_mismatch")))
        XCTAssertTrue(AuthStore.shouldRetryWithoutOptionalParameters(.flowFailed("invalid_request: hd")))
        XCTAssertFalse(AuthStore.shouldRetryWithoutOptionalParameters(.userCancelled))
        XCTAssertFalse(AuthStore.shouldRetryWithoutOptionalParameters(.missingRefreshToken))
    }

    @MainActor
    func testAuthErrorDescriptions() {
        XCTAssertEqual(AuthError.signedOut.errorDescription, "Not signed in.")
        XCTAssertEqual(AuthError.needsReauth.errorDescription, "Your Google session has expired. Sign in again.")
        XCTAssertEqual(AuthError.userCancelled.errorDescription, "Sign-in was cancelled.")
        XCTAssertEqual(AuthError.flowFailed("boom").errorDescription, "Sign-in failed: boom")
        XCTAssertEqual(
            AuthError.missingRefreshToken.errorDescription,
            "Google did not return a refresh token. Sign in again and approve access."
        )
        let mismatch = AuthError.accountMismatch(expected: "a", got: "b").errorDescription ?? ""
        XCTAssertTrue(mismatch.contains("a"))
        XCTAssertTrue(mismatch.contains("b"))
        XCTAssertEqual(AuthError.keychain(-25300).errorDescription, "Keychain error -25300.")
    }

    @MainActor
    func testSignInMessageSelection() {
        let placeholder = OAuthConfig(clientID: "REPLACE.apps.googleusercontent.com")
        let real = realConfig()
        let admin = AuthError.flowFailed("X#-1: admin_policy_enforced — blocked")

        XCTAssertEqual(SignInMessage.select(config: placeholder, lastAuthError: admin, lastError: nil), .configMissing)

        let selectedAdmin = SignInMessage.select(config: real, lastAuthError: admin, lastError: admin.errorDescription)
        XCTAssertEqual(selectedAdmin, .adminPolicy(clientID: "123.apps.googleusercontent.com"))
        XCTAssertEqual(selectedAdmin.text?.contains("Trust internal, domain-owned apps"), true)
        XCTAssertEqual(selectedAdmin.text?.hasSuffix("123.apps.googleusercontent.com"), true)

        let err = AuthError.flowFailed("x")
        XCTAssertEqual(
            SignInMessage.select(config: real, lastAuthError: err, lastError: err.errorDescription),
            .error("Sign-in failed: x")
        )
        XCTAssertEqual(SignInMessage.select(config: real, lastAuthError: .userCancelled, lastError: nil), .none)
        XCTAssertEqual(SignInMessage.select(config: real, lastAuthError: nil, lastError: nil), .none)
    }

    // MARK: relay & provider signalling

    @MainActor
    func testNeedsReauthRelay() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let (store, _, _) = makeStore(hasKeychainItem: true, cachedEmail: "a@x", account: a)
        let relay = NeedsReauthRelay()
        relay.auth = store
        DispatchQueue.global().async { relay.fire() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.state, .needsReauth(email: "a@x"))

        let empty = NeedsReauthRelay()
        empty.fire()  // must not crash with a nil auth
    }

    @MainActor
    func testProviderSignalsStore() async throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        AuthStub.reply = .init(status: 400, json: #"{"error":"invalid_grant"}"#)
        let (store, provider, _) = makeStore(hasKeychainItem: true, cachedEmail: "a@x", account: a)
        try await provider.adopt(makeAuthState())
        do {
            _ = try await provider.accessToken()
            XCTFail("expected throw")
        } catch {}
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.state, .needsReauth(email: "a@x"))
    }

    // MARK: helpers

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.settings.\(name)")!
        suite.removePersistentDomain(forName: "test.settings.\(name)")
        return suite
    }
}

/// Records hook invocation order.
@MainActor private final class HookLog {
    private(set) var calls: [String] = []
    func append(_ s: String) { calls.append(s) }
}

/// A stand-in `OIDExternalUserAgentSession` that records `resume` calls.
nonisolated private final class DummyFlow: NSObject, OIDExternalUserAgentSession, @unchecked Sendable {
    nonisolated(unsafe) var resumeCalls = 0
    func cancel() {}
    func cancel(completion: (() -> Void)?) { completion?() }
    func resumeExternalUserAgentFlow(with url: URL) -> Bool {
        resumeCalls += 1
        return true
    }
    func resumeExternalUserAgentFlow(_ url: URL) throws {
        resumeCalls += 1
    }
    func failExternalUserAgentFlowWithError(_ error: any Error) {}
}

/// `URLProtocol` answering `oauth2.googleapis.com` (token + revoke) for AuthStore tests.
nonisolated private final class AuthStub: URLProtocol {
    struct Reply {
        var status: Int
        var json: String
    }
    struct Recorded {
        var url: URL
        var method: String
    }
    nonisolated(unsafe) static var reply = Reply(status: 200, json: "{}")
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
        reply = Reply(status: 200, json: "{}")
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "oauth2.googleapis.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(Recorded(url: request.url!, method: request.httpMethod ?? ""))
        let reply = Self.reply
        Self.lock.unlock()
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
}
