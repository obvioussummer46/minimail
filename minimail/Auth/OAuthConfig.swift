@preconcurrency import AppAuth
import Foundation

/// OAuth client facts (architecture §2.4, §5.1 step 1). Value type; safe to hand to actors.
nonisolated struct OAuthConfig: Sendable {
    let clientID: String
    let redirectURL: URL
    let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    let scopes = ["https://www.googleapis.com/auth/gmail.modify"]

    /// Optional `hd` authorization parameter. `nil` — any Google account may sign in (no domain restriction).
    let hostedDomain: String? = nil
    /// Info.plist key read by `fromInfoPlist()` (`GoogleClientID: $(GOOGLE_CLIENT_ID)`).
    static let infoPlistKey = "GoogleClientID"
    /// Keychain account of the archived `OIDAuthState`.
    static let keychainAccount = "oauth.authState"
    static let testingKeychainAccount = "oauth.authState.testing"

    /// Builds the redirect URL from the client id: `com.googleusercontent.apps.<prefix>:/oauth2redirect` where
    /// `<prefix>` is `clientID` with the `.apps.googleusercontent.com` suffix removed (single slash).
    init(clientID: String) {
        self.clientID = clientID
        let suffix = ".apps.googleusercontent.com"
        let prefix = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        if let url = URL(string: "com.googleusercontent.apps.\(prefix):/oauth2redirect") {
            self.redirectURL = url
        } else {
            Log.auth.error("client id is not a valid URL scheme")
            self.redirectURL = URL(string: "com.googleusercontent.apps.invalid:/oauth2redirect")!
        }
    }

    static func fromInfoPlist() -> OAuthConfig { fromInfoPlist(bundle: .main) }

    /// `fromInfoPlist()` with an explicit bundle (tests). Missing or non-string key → placeholder config + log.
    static func fromInfoPlist(bundle: Bundle) -> OAuthConfig {
        guard let id = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String, !id.isEmpty else {
            Log.auth.error("Info.plist \(infoPlistKey, privacy: .public) missing")
            return OAuthConfig(clientID: "REPLACE.apps.googleusercontent.com")
        }
        return OAuthConfig(clientID: id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `true` when the client id still carries the `Config/Google.xcconfig` placeholder or is empty.
    var isPlaceholder: Bool { clientID.isEmpty || clientID.hasPrefix("REPLACE") }

    /// Built per call (the ObjC object is not Sendable).
    var serviceConfiguration: OIDServiceConfiguration {
        OIDServiceConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint)
    }
}
