import SwiftUI

@main
struct MinimailApp: App {
    /// Created when the app value is first built. This is launch step 1; nothing else happens here.
    @State private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.theme)
                .environment(env.settings)
                .onOpenURL { url in _ = env.auth.resume(url: url) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await env.outbox.setForeground(true) }
                        // The launch path already runs `.launch`; only re-sync on later foregrounds.
                        if env.deferredWorkStarted { Task { await env.sync.run(.foreground) } }
                    case .background:
                        BackgroundRefresh.schedule()
                        Task { await env.outbox.setForeground(false) }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run(env)
        }
    }
}
