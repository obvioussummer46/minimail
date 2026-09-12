import SwiftUI

/// The screen for `auth.state == .signedOut` (architecture §8.1–§8.2). Owns no state beyond what `AuthStore`
/// publishes.
struct SignInScreen: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens

    private var message: SignInMessage {
        SignInMessage.select(
            config: env.oauthConfig,
            lastAuthError: env.auth.lastAuthError,
            lastError: env.auth.lastError
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "envelope")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(themeTokens.accent)
                .accessibilityHidden(true)
            Text("minimail")
                .font(.largeTitle.bold())
                .foregroundStyle(themeTokens.text)
            Text("Gmail for newtelco.de")
                .font(.subheadline)
                .foregroundStyle(themeTokens.secondaryText)
            Spacer()
            Button {
                Task { try? await env.auth.signIn() }
            } label: {
                HStack(spacing: 8) {
                    if env.auth.isSigningIn { ProgressView().controlSize(.small) }
                    Text(env.auth.isSigningIn ? "Signing in…" : "Sign in with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(env.auth.isSigningIn || env.oauthConfig.isPlaceholder)
            .accessibilityLabel("Sign in with Google")
            .accessibilityHint("Opens Google in a browser sheet")
            .accessibilityIdentifier("signin.button")

            if let text = message.text {
                Label {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(themeTokens.secondaryText)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(themeTokens.accent)
                }
                .accessibilityIdentifier("signin.message")
            }
            Spacer().frame(height: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeTokens.background.ignoresSafeArea())
    }
}

/// What the text block under the button shows. Pure so it is testable without hosting the view.
enum SignInMessage: Equatable {
    case none
    case configMissing
    case adminPolicy(clientID: String)
    case error(String)

    /// Precedence: `configMissing` > `adminPolicy` > `error` > `none`. `userCancelled` → `.none`.
    static func select(config: OAuthConfig, lastAuthError: AuthError?, lastError: String?) -> SignInMessage {
        if config.isPlaceholder { return .configMissing }
        if lastAuthError?.isAdminPolicyEnforced == true { return .adminPolicy(clientID: config.clientID) }
        if let lastError { return .error(lastError) }
        return .none
    }

    var text: String? {
        switch self {
        case .none:
            return nil
        case .configMissing:
            return "Google client ID is not configured. Set GOOGLE_CLIENT_ID in Config/Google.xcconfig and rebuild."
        case .adminPolicy(let clientID):
            return
                "Your Google Workspace administrator has not allowed minimail yet. In the Admin console open "
                + "Security → Access and data control → API controls → Manage Third-Party App Access and mark "
                + "this client ID as Trusted, or enable \"Trust internal, domain-owned apps\".\n\(clientID)"
        case .error(let text):
            return text
        }
    }
}
