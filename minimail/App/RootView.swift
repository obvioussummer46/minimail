import SwiftUI

/// Root of the window. Applies the theme modifiers and starts the deferred launch work.
///
/// Module 04 replaces the placeholder with a switch over the auth state.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens

    var body: some View {
        RootPlaceholderView()
            .preferredColorScheme(env.theme.preferredColorScheme)
            .tint(themeTokens.accent)
            .task { await env.startDeferredWork() }
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
