import BackgroundTasks
import Foundation
import os

nonisolated enum BackgroundRefresh {
    static let taskID = "com.minimail.refresh"

    /// Submits a `BGAppRefreshTaskRequest` for +15 min from a detached task (`[ios-platform §3.3]`: not from the
    /// main thread). No-op in the test host. DEVIATION: the iOS 27 async `submitTaskRequest` branch is omitted for
    /// SDK compatibility; `submit(_:)` is used on all versions.
    static func schedule() {
        guard ProcessInfo.processInfo.environment["MINIMAIL_TESTING"] != "1" else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        Task.detached {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                Log.bg.notice("schedule failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Architecture §4.10: reschedule → signed-in guard → delta → drain → badge.
    @MainActor static func run(_ env: AppEnvironment) async {
        schedule()
        guard case .signedIn = env.auth.state else {
            Log.bg.notice("bg skipped: not signed in")
            return
        }
        await env.sync.run(.background)
        guard !Task.isCancelled else { return }
        await env.outbox.drain()
        guard !Task.isCancelled else { return }
        await env.sync.updateBadge()
        Log.bg.notice("bg refresh done")
    }
}
