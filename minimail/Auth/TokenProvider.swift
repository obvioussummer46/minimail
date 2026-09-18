import Foundation

/// Verbatim architecture §2.4. Implemented by `AppAuthTokenProvider`; consumed by `GmailClient` (05).
/// `nonisolated` so actor conformers (the provider itself, test stubs) stay legal under default MainActor isolation.
nonisolated protocol TokenProvider: Sendable {
    /// A bearer access token that is valid now. Refreshes through the refresh token when expired (single-flight:
    /// N concurrent callers share one refresh). Throws `AuthError.signedOut` (no state loaded),
    /// `AuthError.needsReauth` (`invalid_grant`, latched until the next `adopt`), `URLError` (transport failure —
    /// retryable, caller maps it), `AuthError.flowFailed(String)` (anything else).
    func accessToken() async throws -> String
    /// After an HTTP 401: forces the next `accessToken()` to refresh (`OIDAuthState.setNeedsTokenRefresh()`).
    /// Never throws, never networks.
    func invalidateAccessToken() async
}
