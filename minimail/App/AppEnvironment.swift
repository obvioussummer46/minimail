import Foundation
import SwiftUI
import os

/// Composition root. Exactly one instance per process, created in `MinimailApp`.
///
/// Later modules add their objects at the marked insertion points, in the order given: the launch order is a
/// contract, and everything in `init` runs before the first frame.
@Observable final class AppEnvironment {

    /// True when `MINIMAIL_TESTING=1` is in the environment, which the scheme sets for every test host launch.
    @ObservationIgnored let isTesting: Bool
    /// `.standard`, or a testing suite wiped at init.
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let theme: ThemeStore

    /// Open interval for cold start, ended once by `markFirstListPaint()`.
    @ObservationIgnored private var coldStart: OSSignpostIntervalState?
    private(set) var deferredWorkStarted = false

    static let testingSuiteName = "de.newtelco.minimail.testing"

    static var isTestingProcess: Bool {
        ProcessInfo.processInfo.environment["MINIMAIL_TESTING"] == "1"
    }

    /// Launch step 1: synchronous, budget under 15 ms. The only I/O here is one `UserDefaults` read.
    ///
    /// Forbidden in this initializer: AppAuth, any network call, `WKWebView`, `UNUserNotificationCenter`,
    /// `BGTaskScheduler`, and NotificationCenter observers.
    init(testing: Bool = AppEnvironment.isTestingProcess) {
        isTesting = testing
        coldStart = Log.begin(.coldStartToList)

        if testing {
            // `UserDefaults(suiteName:)` returns nil only for the global domain, so this is safe.
            let suite = UserDefaults(suiteName: Self.testingSuiteName)!
            suite.removePersistentDomain(forName: Self.testingSuiteName)
            defaults = suite
        } else {
            defaults = .standard
        }

        settings = SettingsStore(defaults: defaults)
        // [06] db = Database.open(directory:) — openInMemory() when isTesting
        // [04] Keychain existence check, syncState.accountEmail read, AuthStore(...)
        theme = ThemeStore(settings: settings)
        // [05][07][08] GmailClient, SyncStatus, SyncEngine, Outbox, MailActions, WebViewHost — construction only

        Log.ui.debug("AppEnvironment ready testing=\(testing, privacy: .public)")
    }

    /// Launch step 3, called from `RootView.task`. Idempotent. Yields twice so the first frame is on screen
    /// before any of this runs.
    func startDeferredWork() async {
        guard !deferredWorkStarted else { return }
        deferredWorkStarted = true

        await Task.yield()
        await Task.yield()
        // [04] await tokens.load()
        // [07] release in-flight outbox rows, then await sync.run(.launch)

        if isTesting { return }

        try? await Task.sleep(for: .seconds(1))
        // [08] await webHost.prepare()

        try? await Task.sleep(for: .seconds(1))
        // [07] BackgroundRefresh.schedule(); await Maintenance.cleanup(db, now:); await sync.updateBadge()
    }

    /// Ends the cold-start interval the first time the list paints. Later calls do nothing.
    func markFirstListPaint() {
        if let state = coldStart {
            Log.end(.coldStartToList, state)
            coldStart = nil
        }
    }
}
