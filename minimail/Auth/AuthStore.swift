@preconcurrency import AppAuth
import Foundation
import Observation
import UIKit
import UserNotifications

/// Verbatim architecture §2.4. `nonisolated` so actors (provider, 05, 07) can throw and compare it.
nonisolated enum AuthError: Error, Sendable, Equatable {
    case signedOut, needsReauth, userCancelled, flowFailed(String), missingRefreshToken,
        accountMismatch(expected: String, got: String), keychain(Int32)
}

extension AuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .signedOut:
            return "Not signed in."
        case .needsReauth:
            return "Your Google session has expired. Sign in again."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .flowFailed(let text):
            return "Sign-in failed: \(text)"
        case .missingRefreshToken:
            return "Google did not return a refresh token. Sign in again and approve access."
        case .accountMismatch(let expected, let got):
            return
                "Google signed in \(got), but the mail on this device belongs to \(expected). "
                + "The local copy was cleared — sign in again."
        case .keychain(let status):
            return "Keychain error \(status)."
        }
    }

    /// `flowFailed(text)` whose `text` contains `admin_policy_enforced`.
    var isAdminPolicyEnforced: Bool {
        if case .flowFailed(let text) = self { return text.contains("admin_policy_enforced") }
        return false
    }
}

/// Auth state machine + interactive sign-in. `@MainActor` (implicit). One instance, owned by `AppEnvironment`.
@Observable final class AuthStore {
    enum State: Equatable { case signedOut, signedIn(email: String?), needsReauth(email: String?) }

    private(set) var state: State
    private(set) var lastError: String?
    var currentFlow: OIDExternalUserAgentSession?

    let config: OAuthConfig
    let tokens: AppAuthTokenProvider
    private(set) var isSigningIn: Bool
    private(set) var lastAuthError: AuthError?
    private(set) var cachedEmail: String?
    var hooks: Hooks

    /// Synchronous routing decision (architecture §5.2 truth table). No I/O.
    init(tokens: AppAuthTokenProvider, config: OAuthConfig, hasKeychainItem: Bool, cachedEmail: String?) {
        self.tokens = tokens
        self.config = config
        self.cachedEmail = cachedEmail
        self.hooks = Hooks()
        self.isSigningIn = false
        self.lastError = nil
        self.lastAuthError = nil
        switch (hasKeychainItem, cachedEmail) {
        case (true, let email):
            state = .signedIn(email: email)
        case (false, .some(let email)):
            state = .needsReauth(email: email)
        case (false, nil):
            state = .signedOut
        }
        let routing =
            "routing: keychain=\(hasKeychainItem) cachedEmail=\(cachedEmail != nil) "
            + "→ \(String(describing: state))"
        Log.auth.notice("\(routing, privacy: .public)")
    }

    // MARK: Sign-in

    /// AppAuth flow → adopt → profile → mismatch wipe → `.signedIn`. Throws `AuthError`; `lastError` is set
    /// before rethrowing. Re-entrancy: returns immediately (no throw) while `isSigningIn`.
    func signIn() async throws {
        guard !isSigningIn else { return }
        guard !config.isPlaceholder else { try fail(.flowFailed("GoogleClientID is not configured")) }
        isSigningIn = true
        lastError = nil
        lastAuthError = nil
        defer {
            isSigningIn = false
            currentFlow = nil
        }

        var params: [String: String] = [:]
        if let hint = hooks.loginHint(), !hint.isEmpty { params["login_hint"] = hint }
        if let hd = config.hostedDomain { params["hd"] = hd }
        var strippedOptional = false
        var requestedConsent = false
        var authState: OIDAuthState

        loop: while true {
            do {
                authState = try await presentFlow(additionalParameters: params)
            } catch let e as AuthError {
                if !strippedOptional, params["hd"] != nil, Self.shouldRetryWithoutOptionalParameters(e) {
                    params["hd"] = nil
                    strippedOptional = true
                    Log.auth.notice("sign-in: retrying without hd")
                    continue loop
                }
                try fail(e)
            }
            if authState.refreshToken == nil, !requestedConsent {
                params["prompt"] = "consent"
                requestedConsent = true
                Log.auth.notice("sign-in: no refresh token, retrying with prompt=consent")
                continue loop
            }
            guard authState.refreshToken != nil else { try fail(.missingRefreshToken) }
            break loop
        }

        do {
            try await tokens.adopt(authState)
        } catch let e as AuthError {
            try fail(e)
        }

        var email: String? = state.email ?? cachedEmail
        if let fetch = hooks.fetchProfileEmail {
            var fetched: String?
            do {
                fetched = try await fetch()
            } catch {
                // A real auth rejection means the just-adopted token is useless: revoke and bounce. A transient
                // failure (offline, network, rate-limit, server) must not throw away a valid session — the launch
                // sync re-fetches the profile and does the identity check with proper retry.
                if Self.profileFailureIsFatal(error) {
                    await tokens.revokeAndClear()
                    try fail(.flowFailed("profile: \(Self.profileErrorMessage(error))"))
                }
                Log.auth.notice(
                    "sign-in: profile fetch failed transiently, keeping session: \(String(describing: error), privacy: .public)"
                )
            }
            if let fetched {
                email = fetched
                if let cached = cachedEmail, cached.caseInsensitiveCompare(fetched) != .orderedSame {
                    Log.auth.notice(
                        "sign-in: account changed \(cached, privacy: .private) → \(fetched, privacy: .private); wiping"
                    )
                    await hooks.prepareSignOut()
                    await hooks.wipeAccountData()
                    cachedEmail = nil
                }
            }
        }

        if let email {
            hooks.rememberEmail(email)
            cachedEmail = email
        }
        state = .signedIn(email: email)
        Log.auth.notice("signed in")
        hooks.didSignIn()
    }

    /// Sets `lastAuthError`/`lastError` and throws. `userCancelled` leaves `lastError` nil (nothing to explain).
    private func fail(_ e: AuthError) throws -> Never {
        lastAuthError = e
        lastError = (e == .userCancelled) ? nil : e.errorDescription
        throw e
    }

    private func presentFlow(additionalParameters params: [String: String]) async throws -> OIDAuthState {
        guard let vc = Self.presentingViewController() else {
            throw AuthError.flowFailed("no key window to present sign-in")
        }
        let request = OIDAuthorizationRequest(
            configuration: config.serviceConfiguration,
            clientId: config.clientID,
            clientSecret: nil,
            scopes: config.scopes,
            redirectURL: config.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: params.isEmpty ? nil : params
        )
        guard let agent = OIDExternalUserAgentIOS(presenting: vc, prefersEphemeralSession: false) else {
            throw AuthError.flowFailed("cannot create external user agent")
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OIDAuthState, any Error>) in
            currentFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
                Task { @MainActor in
                    self.currentFlow = nil
                    if let state {
                        cont.resume(returning: state)
                    } else {
                        cont.resume(throwing: Self.classifyFlowError(error))
                    }
                }
            }
        }
    }

    @MainActor
    private static func presentingViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    // MARK: Sign-out

    /// Architecture §5.4. Idempotent: no-op when already `.signedOut`.
    func signOut() async {
        guard state != .signedOut else { return }
        await currentFlow?.cancel()
        currentFlow = nil
        await hooks.prepareSignOut()
        await tokens.revokeAndClear()
        await hooks.wipeAccountData()
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        cachedEmail = nil
        lastError = nil
        lastAuthError = nil
        state = .signedOut
        Log.auth.notice("signed out")
    }

    // MARK: External events

    /// `.onOpenURL` fallback: hands `url` to `currentFlow` when its scheme matches `config.redirectURL.scheme`.
    func resume(url: URL) -> Bool {
        guard let flow = currentFlow else { return false }
        guard url.scheme?.lowercased() == config.redirectURL.scheme?.lowercased() else { return false }
        do {
            try flow.resumeExternalUserAgentFlow(url)
            currentFlow = nil
            Log.auth.debug("resumed flow via onOpenURL")
            return true
        } catch {
            Log.auth.notice("resume rejected: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `.signedIn(e)` → `.needsReauth(e)`; other states unchanged.
    func markNeedsReauth() {
        switch state {
        case .signedIn(let email):
            state = .needsReauth(email: email)
            lastAuthError = .needsReauth
            lastError = AuthError.needsReauth.errorDescription
            Log.auth.notice("needsReauth")
        case .needsReauth, .signedOut:
            break
        }
    }

    /// Deferred launch step a: `succeeded == false` while `.signedIn(e)` → `.needsReauth(e)`; else no-op.
    func handleTokenLoad(succeeded: Bool) {
        if !succeeded, case .signedIn = state {
            Log.auth.notice("token load failed → needsReauth")
            markNeedsReauth()
        }
    }

    /// Called by `SyncEngine.fullSync` (07) when the profile e-mail differs from the cached account.
    func handleAccountMismatch(expected: String, got: String) async {
        let e = AuthError.accountMismatch(expected: expected, got: got)
        Log.auth.error("account mismatch")
        await signOut()
        lastAuthError = e
        lastError = e.errorDescription
    }

    // MARK: Pure classifiers

    /// AppAuth flow callback error → `AuthError`.
    nonisolated static func classifyFlowError(_ error: (any Error)?) -> AuthError {
        guard let error else { return .flowFailed("authorization returned neither state nor error") }
        let ns = error as NSError
        if ns.domain == OIDGeneralErrorDomain,
            ns.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
                || ns.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue
        {
            return .userCancelled
        }
        let response = ns.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any]
        var parts: [String] = []
        if let f = response?[OIDOAuthErrorFieldError] as? String { parts.append(f) }
        if let d = response?[OIDOAuthErrorFieldErrorDescription] as? String { parts.append(d) }
        if !parts.contains(ns.localizedDescription) { parts.append(ns.localizedDescription) }
        return .flowFailed("\(ns.domain)#\(ns.code): " + parts.joined(separator: " — "))
    }

    /// Whether a sign-in profile-fetch failure should discard the freshly adopted token. Only a genuine auth
    /// rejection is fatal; transient errors keep the session so the launch sync can validate identity and retry.
    nonisolated static func profileFailureIsFatal(_ error: any Error) -> Bool {
        switch error {
        case let g as GmailError:
            switch g {
            case .unauthorized, .forbidden: return true
            default: return false
            }
        case let a as AuthError:
            switch a {
            case .needsReauth, .signedOut, .missingRefreshToken: return true
            default: return false
            }
        default:
            return false
        }
    }

    /// The sentence shown for a profile-fetch failure. `GmailError` only conforms to `Error`, so its
    /// `.localizedDescription` is the useless "(minimail.GmailError error N.)"; use `userMessage` instead.
    nonisolated static func profileErrorMessage(_ error: any Error) -> String {
        switch error {
        case let g as GmailError: return g.userMessage
        case let a as AuthError: return a.errorDescription ?? "\(a)"
        default: return (error as NSError).localizedDescription
        }
    }

    /// Whether a first-attempt failure warrants one retry without the optional `hd` parameter.
    nonisolated static func shouldRetryWithoutOptionalParameters(_ e: AuthError) -> Bool {
        guard case .flowFailed(let text) = e else { return false }
        let t = text.lowercased()
        return !t.contains("admin_policy_enforced") && !t.contains("access_denied")
            && !t.contains("invalid_client") && !t.contains("redirect_uri_mismatch")
    }
}

extension AuthStore.State {
    /// `nil` for `.signedOut`, the associated value otherwise.
    var email: String? {
        switch self {
        case .signedOut: return nil
        case .signedIn(let email), .needsReauth(let email): return email
        }
    }

    var isSignedOut: Bool {
        if case .signedOut = self { return true }
        return false
    }
}

extension AuthStore {
    /// Injection points for modules 01, 05, 06, 07, 08. All closures run on main; async ones are awaited.
    struct Hooks {
        /// `login_hint` for the authorization request. Default `{ nil }`.
        var loginHint: @MainActor () -> String? = { nil }
        /// Called with the authenticated address before `state` flips to `.signedIn`. Default no-op.
        var rememberEmail: @MainActor (String) -> Void = { _ in }
        /// Returns the account e-mail using the freshly adopted tokens. `nil` (default) skips the profile step.
        var fetchProfileEmail: (@Sendable () async throws -> String)?
        /// Cancels the running sync and outbox drain and awaits them (07). Default no-op.
        var prepareSignOut: @MainActor () async -> Void = {}
        /// Erases every per-account artefact except tokens and Settings (06, 08). Default no-op.
        var wipeAccountData: @MainActor () async -> Void = {}
        /// Called after `state` became `.signedIn` (07). Must not block. Default no-op.
        var didSignIn: @MainActor () -> Void = {}
        init() {}
    }
}

/// Breaks the construction cycle provider → store → provider: the provider's `onNeedsReauth` closure captures the
/// relay, `AppEnvironment` points the relay at the store once it exists. `@MainActor` (implicit) ⇒ `Sendable`.
final class NeedsReauthRelay {
    weak var auth: AuthStore?
    init() {}
    /// Safe from any thread.
    nonisolated func fire() {
        Task { @MainActor in self.auth?.markNeedsReauth() }
    }
}
