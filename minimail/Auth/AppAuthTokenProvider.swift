@preconcurrency import AppAuth
import Foundation

/// Owns the `OIDAuthState` (architecture §2.4, §5.3). One instance per process, created in `AppEnvironment.init`
/// (construction only — no I/O).
actor AppAuthTokenProvider: TokenProvider {
    nonisolated let keychainAccount: String
    /// invalid_grant → `AuthStore.markNeedsReauth` on main (via `NeedsReauthRelay`).
    nonisolated let onNeedsReauth: @Sendable () -> Void

    private let revocationEndpoint: URL
    private let session: URLSession

    private var state: OIDAuthState?
    private var delegate: StateDelegate?
    private var refreshTask: Task<String, any Error>?
    private var latched = false

    init(
        keychainAccount: String = OAuthConfig.keychainAccount,
        revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
        session: URLSession = URLSession(configuration: .ephemeral),
        onNeedsReauth: @escaping @Sendable () -> Void = {}
    ) {
        self.keychainAccount = keychainAccount
        self.revocationEndpoint = revocationEndpoint
        self.session = session
        self.onNeedsReauth = onNeedsReauth
    }

    /// `state != nil`.
    var isLoaded: Bool { state != nil }
    /// `true` after an `invalid_grant` until the next `adopt`.
    var needsReauthLatched: Bool { latched }
    /// `state?.refreshToken`.
    var refreshToken: String? { state?.refreshToken }

    // MARK: Loading & persistence

    /// Unarchives the `OIDAuthState` from the Keychain (runs on the actor, off main). `true` iff an item existed,
    /// unarchived, and `state.isAuthorized`. Never throws; a corrupt archive is deleted and logged.
    func load() async -> Bool {
        let data: Data?
        do {
            data = try Keychain.get(account: keychainAccount)
        } catch let AuthError.keychain(status) {
            Log.auth.error("load keychain status=\(status, privacy: .public)")
            return false
        } catch {
            Log.auth.error("load keychain failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard let data else {
            Log.auth.debug("load: no item")
            return false
        }
        let loaded: OIDAuthState?
        do {
            loaded = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        } catch {
            loaded = nil
        }
        guard let loaded else {
            Log.auth.error("load: unarchive failed; deleting item")
            try? Keychain.delete(account: keychainAccount)
            return false
        }
        install(loaded)
        Log.auth.notice("load: authorized=\(loaded.isAuthorized, privacy: .public)")
        return loaded.isAuthorized
    }

    /// Installs `state` after an interactive sign-in: sets delegates, clears the reauth latch, archives to the
    /// Keychain. Throws `AuthError.keychain(status)` when the Keychain write fails (the state is then NOT kept).
    func adopt(_ state: sending OIDAuthState) async throws {
        install(state)
        let data: Data
        do {
            data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        } catch {
            self.state = nil
            self.delegate = nil
            throw AuthError.flowFailed("archive: \(error.localizedDescription)")
        }
        do {
            try Keychain.set(data, account: keychainAccount)
        } catch {
            self.state = nil
            self.delegate = nil
            throw error
        }
        Log.auth.notice("adopt: persisted \(data.count, privacy: .public) bytes")
    }

    /// Re-archives the current state to the Keychain; called by the AppAuth change delegate. Logged, never thrown.
    func persistCurrentState() {
        guard let state else { return }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
            try Keychain.set(data, account: keychainAccount)
        } catch {
            Log.auth.error("persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func install(_ newState: OIDAuthState) {
        state = newState
        let delegate = StateDelegate(owner: self)
        self.delegate = delegate
        newState.stateChangeDelegate = delegate
        newState.errorDelegate = delegate
        latched = false
        refreshTask = nil
    }

    // MARK: Access token

    func accessToken() async throws -> String {
        guard let state else { throw AuthError.signedOut }
        if latched { throw AuthError.needsReauth }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { [state] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
                state.performAction(freshTokens: { token, _, error in
                    // AppAuth hands back the *stale* access token alongside a transient (network) error, so the
                    // error must win: otherwise a failed refresh would silently return an expired token.
                    if let error {
                        cont.resume(throwing: Self.mapTokenError(error))
                    } else if let token {
                        cont.resume(returning: token)
                    } else {
                        cont.resume(throwing: Self.mapTokenError(nil))
                    }
                })
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch let e as AuthError where e == .needsReauth {
            latched = true
            Log.auth.error("refresh: invalid_grant → needsReauth")
            onNeedsReauth()
            throw e
        }
    }

    func invalidateAccessToken() async {
        state?.setNeedsTokenRefresh()
        Log.auth.debug("access token invalidated")
    }

    /// Pure mapping of the error handed to `performAction(freshTokens:)`'s callback.
    nonisolated static func mapTokenError(_ error: (any Error)?) -> any Error {
        guard let error else { return AuthError.flowFailed("token refresh returned neither token nor error") }
        let ns = error as NSError
        if ns.domain == OIDOAuthTokenErrorDomain {
            let response = ns.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any]
            let field = response?[OIDOAuthErrorFieldError] as? String
            if ns.code == OIDErrorCodeOAuth.invalidGrant.rawValue || field == "invalid_grant" {
                return AuthError.needsReauth
            }
            let description = response?[OIDOAuthErrorFieldErrorDescription] as? String ?? ns.localizedDescription
            return AuthError.flowFailed("token: \(field ?? "") \(description)".trimmingCharacters(in: .whitespaces))
        }
        if let u = error as? URLError { return u }
        if ns.domain == OIDGeneralErrorDomain, ns.code == OIDErrorCode.networkError.rawValue {
            if let u = ns.userInfo[NSUnderlyingErrorKey] as? URLError { return u }
            if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSURLErrorDomain {
                return URLError(URLError.Code(rawValue: under.code))
            }
            return URLError(.unknown)
        }
        if ns.domain == OIDGeneralErrorDomain, ns.code == OIDErrorCode.tokenRefreshError.rawValue {
            return AuthError.needsReauth
        }
        return AuthError.flowFailed("\(ns.domain)#\(ns.code): \(ns.localizedDescription)")
    }

    // MARK: Revocation

    /// `POST revocationEndpoint` with `token=<refresh token>` (best effort, 3 s timeout) → drop state → delete item.
    func revokeAndClear() async {
        let token = state?.refreshToken ?? state?.lastTokenResponse?.accessToken
        if let token {
            var req = URLRequest(url: revocationEndpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 3
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // Percent-encode for form bodies but keep RFC 3986 unreserved chars (real refresh tokens contain `-`, `_`, `.`, `~`).
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = token.addingPercentEncoding(withAllowedCharacters: unreserved) ?? token
            req.httpBody = Data("token=\(encoded)".utf8)
            do {
                let (_, r) = try await session.data(for: req)
                Log.auth.notice("revoke status=\((r as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
            } catch {
                Log.auth.notice("revoke failed: \(String(describing: error), privacy: .public)")
            }
        }
        state?.stateChangeDelegate = nil
        state?.errorDelegate = nil
        state = nil
        delegate = nil
        refreshTask = nil
        latched = false
        do {
            try Keychain.delete(account: keychainAccount)
        } catch {
            Log.auth.error("keychain delete failed")
        }
    }
}

/// AppAuth calls its delegates on arbitrary threads; this object hops to the actor. `nonisolated` so the ObjC
/// callbacks carry no MainActor assumption.
nonisolated private final class StateDelegate: NSObject, OIDAuthStateChangeDelegate, OIDAuthStateErrorDelegate,
    Sendable
{
    private nonisolated(unsafe) weak var owner: AppAuthTokenProvider?

    init(owner: AppAuthTokenProvider) {
        self.owner = owner
    }

    func didChange(_ state: OIDAuthState) {
        Task { await owner?.persistCurrentState() }
    }

    func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: any Error) {
        Log.auth.error("authState error: \(String(describing: error), privacy: .public)")
    }
}
