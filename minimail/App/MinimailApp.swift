import SwiftUI

@main
struct MinimailApp: App {
    /// Created when the app value is first built. This is launch step 1; nothing else happens here.
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.theme)
                .environment(env.settings)
                .onOpenURL { url in _ = env.auth.resume(url: url) }
            // Module 07 adds .backgroundTask(.appRefresh(...)) and .onChange(of: scenePhase)
        }
    }
}
