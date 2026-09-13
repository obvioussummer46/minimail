import SwiftUI

/// Root of the window. Applies the theme modifiers and starts the deferred launch work.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens

    var body: some View {
        Group {
            switch env.auth.state {
            case .signedOut:
                SignInScreen()
            case .signedIn, .needsReauth:
                InboxScreen(scope: .inbox)
            }
        }
        .preferredColorScheme(env.theme.preferredColorScheme)
        .tint(themeTokens.accent)
        .task { await env.startDeferredWork() }
    }
}
