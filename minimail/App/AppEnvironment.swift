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
    /// Read once from `Info.plist` in `init` (a dictionary lookup; no I/O beyond the already-loaded bundle plist).
    @ObservationIgnored let oauthConfig: OAuthConfig
    /// Constructed in `init` (no I/O). `load()` runs in `startDeferredWork()`.
    @ObservationIgnored let tokens: AppAuthTokenProvider
    /// Routing state computed in `init` from `Keychain.exists` + `cachedEmail`.
    @ObservationIgnored let auth: AuthStore

    /// `OAuthConfig.testingKeychainAccount` when `isTesting`, else `OAuthConfig.keychainAccount` — so the test host
    /// never sees a developer's real item.
    var keychainAccount: String { tokens.keychainAccount }

    /// Open interval for cold start, ended once by `markFirstListPaint()`.
    @ObservationIgnored private var coldStart: OSSignpostIntervalState?
    private(set) var deferredWorkStarted = false

    static let testingSuiteName = "com.minimail.testing"

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
        let keychainAccount = testing ? OAuthConfig.testingKeychainAccount : OAuthConfig.keychainAccount
        let hasItem = Keychain.exists(account: keychainAccount)
        let cachedEmail: String? = nil  // [06] replaces with: try? db.read { try SyncStateRepository.get($0, .accountEmail) }
        let relay = NeedsReauthRelay()
        let tokens = AppAuthTokenProvider(keychainAccount: keychainAccount, onNeedsReauth: { relay.fire() })
        let oauthConfig = OAuthConfig.fromInfoPlist()
        let auth = AuthStore(tokens: tokens, config: oauthConfig, hasKeychainItem: hasItem, cachedEmail: cachedEmail)
        relay.auth = auth
        self.tokens = tokens
        self.oauthConfig = oauthConfig
        self.auth = auth
        theme = ThemeStore(settings: settings)
        // [05][07][08] GmailClient, SyncStatus, SyncEngine, Outbox, MailActions, WebViewHost — construction only

        // Hooks owned by 01's objects (05/06/07/08 add theirs at the marked points).
        auth.hooks.loginHint = { [settings] in settings.settings.lastSignedInEmail }
        auth.hooks.rememberEmail = { [settings] email in settings.update { $0.lastSignedInEmail = email } }
        // [05] auth.hooks.fetchProfileEmail = { [gmail] in try await gmail.getProfile().emailAddress }
        // [06][08] auth.hooks.wipeAccountData = { … close pool, Database.destroy, reopen, purge caches, webHost.recycle() … }
        // [07] auth.hooks.prepareSignOut = { … cancel + await sync/drain … } ; auth.hooks.didSignIn = { Task { await sync.run(.launch) } }

        Log.ui.debug("AppEnvironment ready testing=\(testing, privacy: .public)")
    }

    /// Launch step 3, called from `RootView.task`. Idempotent. Yields twice so the first frame is on screen
    /// before any of this runs.
    func startDeferredWork() async {
        guard !deferredWorkStarted else { return }
        deferredWorkStarted = true

        await Task.yield()
        await Task.yield()
        let loaded = await tokens.load()
        auth.handleTokenLoad(succeeded: loaded)
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
