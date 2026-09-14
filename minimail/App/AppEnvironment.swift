import Foundation
import GRDB
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
    /// DEBUG ring buffer of recent HTTP requests (nil in Release).
    @ObservationIgnored let requestLog: RequestLog?
    /// Shared in-flight cap for every Gmail request (max 2).
    @ObservationIgnored let limiter: RequestLimiter
    /// The Gmail REST client. Construction only in `init`; no network until a call is made.
    @ObservationIgnored let gmail: GmailClient
    /// The one `DatabasePool` of the process (WAL). Opened in launch step 2; never replaced (`reset` wipes in place).
    @ObservationIgnored let db: DatabasePool
    /// The directory holding the database file (temporary when testing).
    @ObservationIgnored let databaseDirectory: URL

    // [07] Sync + outbox. Constructed in `init` (no I/O).
    @ObservationIgnored let syncStatus: SyncStatus
    @ObservationIgnored let outbox: Outbox
    @ObservationIgnored let sync: SyncEngine
    @ObservationIgnored let actions: MailActions
    @ObservationIgnored let identitySource: OutboxIdentitySource

    // [08] Web rendering. Constructed in `init`; no `WKWebView` until `webHost.prepare()` (or a thread opens).
    @ObservationIgnored let inlineImages: InlineImageStore
    @ObservationIgnored let webBridge: WebBridge
    @ObservationIgnored let webHost: WebViewHost

    /// Injected by tests (module 14) before constructing an environment: `[StubURLProtocol.self]`. The default blocks
    /// the network in the test host so a launch can never reach Gmail.
    nonisolated(unsafe) static var testURLProtocolClasses: [AnyClass] = [OfflineURLProtocol.self]

    /// Injected by tests that need the Gmail client to reach `StubURLProtocol`: the real `AppAuthTokenProvider`
    /// has no keychain item in the test host, so every request would fail with `.unauthorized` before it is sent.
    /// Only consulted when `testing` is true.
    nonisolated(unsafe) static var testTokenProvider: (any TokenProvider)?

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
    convenience init(testing: Bool = AppEnvironment.isTestingProcess) {
        self.init(testing: testing, databaseDirectory: nil)
    }

    /// Designated initializer. `databaseDirectory` (tests only): open that directory instead of a fresh temporary
    /// one, so a test can pre-seed `syncState` and check launch routing.
    init(testing: Bool, databaseDirectory providedDirectory: URL?) {
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

        // Launch step 2: open the WAL pool (migrate on first launch). Corrupt file → rebuild once.
        let dir: URL
        let pool: DatabasePool
        if let providedDirectory {
            dir = providedDirectory
            pool = try! AppDatabase.open(directory: providedDirectory)
        } else if testing {
            pool = try! AppDatabase.openTemporary()
            dir = URL(fileURLWithPath: pool.path).deletingLastPathComponent()
        } else {
            dir = try! AppDatabase.defaultDirectory()
            do {
                pool = try AppDatabase.open(directory: dir)
            } catch {
                Log.db.error("open failed: \(String(describing: error), privacy: .public) — destroying and recreating")
                try? AppDatabase.destroy(directory: dir)
                pool = try! AppDatabase.open(directory: dir)
            }
        }
        db = pool
        databaseDirectory = dir

        let keychainAccount = testing ? OAuthConfig.testingKeychainAccount : OAuthConfig.keychainAccount
        let hasItem = Keychain.exists(account: keychainAccount)
        let cachedEmail: String? = try? pool.read { try SyncStateRepository.get($0, .accountEmail) }
        let relay = NeedsReauthRelay()
        let tokens = AppAuthTokenProvider(keychainAccount: keychainAccount, onNeedsReauth: { relay.fire() })
        let oauthConfig = OAuthConfig.fromInfoPlist()
        let auth = AuthStore(tokens: tokens, config: oauthConfig, hasKeychainItem: hasItem, cachedEmail: cachedEmail)
        relay.auth = auth
        self.tokens = tokens
        self.oauthConfig = oauthConfig
        self.auth = auth
        theme = ThemeStore(settings: settings)

        #if DEBUG
            requestLog = RequestLog()
        #else
            requestLog = nil
        #endif
        let limiter = RequestLimiter(max: 2)
        var clientTokens: any TokenProvider = tokens
        if testing, let injected = AppEnvironment.testTokenProvider { clientTokens = injected }
        let gmail = GmailClient(
            tokens: clientTokens,
            session: .minimail(protocolClasses: testing ? AppEnvironment.testURLProtocolClasses : nil),
            limiter: limiter,
            log: requestLog
        )
        self.limiter = limiter
        self.gmail = gmail
        // [07] SyncStatus, Outbox, SyncEngine, MailActions — construction only (no I/O).
        let syncStatus = SyncStatus()
        let identitySource = OutboxIdentitySource(db: db, settings: settings)
        let outbox = Outbox(
            db: db, gmail: gmail, status: syncStatus,
            identity: { [identitySource] in await identitySource.current() },
            random: { Double.random(in: 0..<1) })
        let sync = SyncEngine(
            db: db, gmail: gmail, outbox: outbox, status: syncStatus,
            settings: { [settings] in await settings.snapshot }, auth: auth)
        outbox.bind(sync: sync)
        self.syncStatus = syncStatus
        self.identitySource = identitySource
        self.outbox = outbox
        self.sync = sync
        self.actions = MailActions(db: db, outbox: outbox, sync: sync)
        // [08] Inline images + the pooled web view — construction only (no WKWebView yet).
        let inlineImages = InlineImageStore(
            gmail: gmail, db: db, cacheDirectory: AppEnvironment.cidCacheDirectory(testing: testing))
        let webBridge = WebBridge()
        let webHost = WebViewHost(cid: CIDSchemeHandler(store: inlineImages), bridge: webBridge)
        self.inlineImages = inlineImages
        self.webBridge = webBridge
        self.webHost = webHost

        // Hooks owned by 01's objects (06/07/08 add theirs at the marked points).
        auth.hooks.loginHint = { [settings] in settings.settings.lastSignedInEmail }
        auth.hooks.rememberEmail = { [settings] email in settings.update { $0.lastSignedInEmail = email } }
        auth.hooks.fetchProfileEmail = { [gmail] in try await gmail.getProfile().emailAddress }
        auth.hooks.wipeAccountData = { [db, inlineImages, webHost] in
            await Task.detached {
                do { try AppDatabase.reset(db) } catch {
                    Log.db.error("reset failed: \(String(describing: error), privacy: .public)")
                }
            }.value
            // [08] wipe tail: the inline-image cache and the rendered document.
            await inlineImages.purge()
            webHost.recycle()
            // [10] wipe tail: downloaded attachments.
            try? AttachmentOpener.purge(directory: AppEnvironment.attachmentsCacheDirectory(testing: testing))
        }
        // [07] cancel the running sync/drain on sign-out; kick a launch sync after sign-in.
        // No wipe tail: `db` is one stable pool reset in place (spec §10 O1), so `replaceDatabase` is unnecessary.
        auth.hooks.prepareSignOut = { [sync, outbox] in
            await sync.cancelAll()
            await outbox.cancelAll()
        }
        auth.hooks.didSignIn = { [sync] in Task { await sync.run(.launch) } }

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
        // [07] step b: a kill mid-request left rows inFlight → back to pending; then the launch sync.
        try? await db.write { try OutboxRepository.releaseInFlight($0) }
        await sync.run(.launch)
        // The launch sync is what fills `syncState.sendAsSignature`, so this has to follow it.
        await SignatureImport.adoptGmailSignatureIfUnset(db: db, settings: settings)

        if isTesting { return }

        try? await Task.sleep(for: .seconds(1))
        await webHost.prepare()

        try? await Task.sleep(for: .seconds(1))
        // [07] step d
        BackgroundRefresh.schedule()
        await Maintenance.cleanup(db, now: Date())
        await sync.updateBadge()
    }

    /// `Caches/cid`, or a fresh temporary directory when testing so no test can see another's bytes.
    static func cidCacheDirectory(testing: Bool) -> URL {
        if testing {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("minimail-cid-\(UUID().uuidString)", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("cid", isDirectory: true)
    }

    /// `<Caches>/attachments` (purged by `Maintenance.purgeFiles`); when testing, a fresh temporary directory.
    static func attachmentsCacheDirectory(testing: Bool) -> URL {
        if testing {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("minimail-att-\(UUID().uuidString)", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("attachments", isDirectory: true)
    }

    /// Ends the cold-start interval the first time the list paints. Later calls do nothing.
    func markFirstListPaint() {
        if let state = coldStart {
            Log.end(.coldStartToList, state)
            coldStart = nil
        }
    }
}
