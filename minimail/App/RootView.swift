import SwiftUI

/// Root of the window. Applies the theme modifiers and starts the deferred launch work.
///
/// Module 04 replaces the placeholder with a switch over the auth state.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens

    var body: some View {
        Group {
            switch env.auth.state {
            case .signedOut:
                SignInScreen()
            case .signedIn, .needsReauth:
                SignedInPlaceholderView()
            }
        }
        .preferredColorScheme(env.theme.preferredColorScheme)
        .tint(themeTokens.accent)
        .task { await env.startDeferredWork() }
    }
}

/// Interim signed-in surface so the auth flows can be exercised on a device before module 09 exists. Deleted by 09.
struct SignedInPlaceholderView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(themeTokens.accent)
                .accessibilityHidden(true)
            Text(env.auth.state.email.map { "Signed in as \($0)" } ?? "Loading your inbox…")
                .font(.headline)
                .foregroundStyle(themeTokens.text)
            if case .needsReauth = env.auth.state {
                Text("Sign in again to keep syncing.")
                    .font(.subheadline)
                    .foregroundStyle(themeTokens.secondaryText)
                Button("Sign in again") { Task { try? await env.auth.signIn() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(env.auth.isSigningIn)
            }
            if let text = env.auth.lastError {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(themeTokens.secondaryText)
            }
            Button("Sign out", role: .destructive) { Task { await env.auth.signOut() } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("placeholder.signout")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeTokens.background.ignoresSafeArea())
    }
}

/// Stage-1 placeholder, shown until the sign-in screen lands. Uses theme tokens only.
struct RootPlaceholderView: View {
    @ThemeTokensReader private var themeTokens

    var body: some View {
        ZStack {
            themeTokens.background
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(themeTokens.accent)
                    .accessibilityHidden(true)
                Text("minimail")
                    .font(.largeTitle.bold())
                    .foregroundStyle(themeTokens.text)
                Text("Inbox coming soon")
                    .font(.subheadline)
                    .foregroundStyle(themeTokens.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("minimail, inbox coming soon")
        }
    }
}
