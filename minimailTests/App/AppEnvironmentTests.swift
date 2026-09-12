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
        let controller = UIHostingController(rootView: root)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.view.subviews.isEmpty)
    }

    @MainActor
    func testInitTiming() {
        measure { _ = AppEnvironment(testing: true) }
    }
}
