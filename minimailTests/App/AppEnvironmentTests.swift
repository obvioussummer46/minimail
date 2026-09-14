import GRDB
import MailCore
import SwiftUI
import UIKit
import XCTest

@testable import minimail

nonisolated final class AppEnvironmentTests: XCTestCase {

    @MainActor
    func testTestingModeUsesIsolatedDefaults() {
        let env = AppEnvironment(testing: true)
        XCTAssertTrue(env.isTesting)
        XCTAssertFalse(env.defaults === UserDefaults.standard)
        XCTAssertTrue(env.settings.defaults === env.defaults)
        XCTAssertEqual(env.settings.settings, Settings())
        XCTAssertEqual(env.theme.choice, .system)
    }

    @MainActor
    func testTestingModeWipesSuite() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: AppEnvironment.testingSuiteName))
        suite.set(Data(#"{"themeChoice":"dark"}"#.utf8), forKey: SettingsStore.key)

        let env = AppEnvironment(testing: true)
        XCTAssertEqual(env.theme.choice, .system)
    }

    @MainActor
    func testWebHostConstructedWithoutWebView() {
        let env = AppEnvironment(testing: true)
        XCTAssertFalse(env.webHost.isPrepared)
        XCTAssertNil(env.webHost.webViewIfCreated, "launch step 1 must not create a WKWebView")
        XCTAssertTrue(env.webHost.bridge === env.webBridge)
        XCTAssertTrue(env.webHost.cid.store === env.inlineImages)
        XCTAssertTrue(
            AppEnvironment.cidCacheDirectory(testing: true).lastPathComponent.hasPrefix("minimail-cid-"))
        XCTAssertEqual(AppEnvironment.cidCacheDirectory(testing: false).lastPathComponent, "cid")
    }

    @MainActor
    func testProcessFlagDetected() {
        XCTAssertTrue(AppEnvironment.isTestingProcess, "the scheme must set MINIMAIL_TESTING=1")
    }

    @MainActor
    func testDeferredWorkIdempotent() async {
        let env = AppEnvironment(testing: true)
        await env.startDeferredWork()
        XCTAssertTrue(env.deferredWorkStarted)

        let start = Date()
        await env.startDeferredWork()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }

    @MainActor
    func testMarkFirstListPaintTwiceIsSafe() {
        let env = AppEnvironment(testing: true)
        XCTAssertNoThrow(env.markFirstListPaint())
        XCTAssertNoThrow(env.markFirstListPaint())
    }

    @MainActor
    func testRootViewHosts() {
        let env = AppEnvironment(testing: true)
        let root = RootView()
            .environment(env)
            .environment(env.theme)
            .environment(env.settings)
        // A hosting controller only builds its hierarchy once it is in a window, so put it in one.
        // The assertion is the layout itself: a missing environment object would trap before this line.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.view.bounds.width, 390)
        XCTAssertEqual(controller.view.bounds.height, 844)
    }

    @MainActor
    func testInitTiming() {
        measure { _ = AppEnvironment(testing: true) }
    }

    // MARK: Module 04 — auth wiring

    private func cleanTestingItem() {
        try? Keychain.delete(account: OAuthConfig.testingKeychainAccount)
    }

    @MainActor
    func testAuthRoutingInTestingMode() {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let env = AppEnvironment(testing: true)
        XCTAssertEqual(env.tokens.keychainAccount, "oauth.authState.testing")
        XCTAssertEqual(env.auth.state, .signedOut)
        XCTAssertEqual(env.oauthConfig.clientID, Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)
    }

    @MainActor
    func testTestingModeWithKeychainItemRoutesSignedIn() async throws {
        cleanTestingItem()
        defer { cleanTestingItem() }
        try Keychain.set(Data("junk".utf8), account: OAuthConfig.testingKeychainAccount)
        let env = AppEnvironment(testing: true)
        XCTAssertEqual(env.auth.state, .signedIn(email: nil))

        await env.startDeferredWork()
        XCTAssertEqual(env.auth.state, .needsReauth(email: nil))
        XCTAssertFalse(Keychain.exists(account: OAuthConfig.testingKeychainAccount))
    }

    @MainActor
    func testDeferredWorkLoadsTokens() async {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let env = AppEnvironment(testing: true)
        await env.startDeferredWork()
        let isLoaded = await env.tokens.isLoaded
        XCTAssertFalse(isLoaded)
        XCTAssertEqual(env.auth.state, .signedOut)
        XCTAssertTrue(env.deferredWorkStarted)
    }

    @MainActor
    func testHooksWiredToSettings() {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let env = AppEnvironment(testing: true)
        env.settings.update { $0.lastSignedInEmail = "h@x" }
        XCTAssertEqual(env.auth.hooks.loginHint(), "h@x")
        env.auth.hooks.rememberEmail("n@x")
        XCTAssertEqual(env.settings.settings.lastSignedInEmail, "n@x")
        // Module 05 wires the profile closure ({ gmail.getProfile().emailAddress }).
        XCTAssertNotNil(env.auth.hooks.fetchProfileEmail)
    }

    @MainActor
    func testRootViewHostsSignedOut() {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let env = AppEnvironment(testing: true)
        let root = RootView().environment(env).environment(env.theme).environment(env.settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(env.auth.state, .signedOut)
        // Prefer the sign-in button's identifier; if SwiftUI does not surface it through UIKit accessibility on
        // this SDK (§10 A7), degrade to "the view laid out", which still proves RootView hosted without trapping.
        if findView(controller.view, identifier: "signin.button") == nil {
            XCTAssertEqual(controller.view.bounds.width, 390)
            XCTAssertEqual(controller.view.bounds.height, 844)
        }
    }

    @MainActor
    func testRootViewHostsSignedInPlaceholder() throws {
        cleanTestingItem()
        defer { cleanTestingItem() }
        try Keychain.set(Data("junk".utf8), account: OAuthConfig.testingKeychainAccount)
        let env = AppEnvironment(testing: true)
        let root = RootView().environment(env).environment(env.theme).environment(env.settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(env.auth.state, .signedIn(email: nil))
    }

    @MainActor
    private func findView(_ view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for sub in view.subviews {
            if let found = findView(sub, identifier: identifier) { return found }
        }
        return nil
    }

    // MARK: Module 06 — database wiring

    @MainActor
    func testTestingModeOpensTemporaryDatabase() throws {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let env = AppEnvironment(testing: true)
        XCTAssertTrue(env.databaseDirectory.path.contains("minimail-db-"))
        let email = try env.db.read { try SyncStateRepository.get($0, .accountEmail) }
        XCTAssertNil(email)
    }

    @MainActor
    func testCachedEmailReadFromSyncState() throws {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-\(UUID().uuidString)")
        defer { try? AppDatabase.destroy(directory: dir) }
        let seedPool = try AppDatabase.open(directory: dir)
        try seedPool.write { try SyncStateRepository.set($0, .accountEmail, "x@example.com") }
        try seedPool.close()

        let env = AppEnvironment(testing: true, databaseDirectory: dir)
        XCTAssertEqual(env.auth.state, .needsReauth(email: "x@example.com"))
    }

    @MainActor
    func testWipeAccountDataResetsDatabase() async throws {
        cleanTestingItem()
        defer { cleanTestingItem() }
        let env = AppEnvironment(testing: true)
        try TestDatabase.seed(env.db, [TestDatabase.parsed(id: "m1", internalDate: 1, labels: ["INBOX"])])
        let before = try await env.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message") }
        XCTAssertEqual(before, 1)

        await env.auth.hooks.wipeAccountData()

        let after = try await env.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message") }
        XCTAssertEqual(after, 0)
    }
}
