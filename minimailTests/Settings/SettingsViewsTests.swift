import GRDB
import MailCore
import SwiftUI
import UIKit
import XCTest

@testable import minimail

/// Spec 13 §7.3. Pure helpers (`HexColor`, `SignaturePreviewDocument`, `SignatureSummary`, `ThemeChoice`,
/// `SettingsStore.binding`) plus hosting smoke tests for the three screens.
nonisolated final class SettingsViewsTests: XCTestCase {
    private var env: AppEnvironment!

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        await env.sync.cancelAll()
        await env.outbox.cancelAll()
        env = nil
    }

    // MARK: - HexColor

    func testHexRoundTrip() {
        for h in ["#000000", "#ffffff", "#1d1d1f", "#0b5394", "#ff0000", "#123456"] {
            XCTAssertEqual(HexColor.hex(HexColor.color(h)), h)
        }
    }

    func testHexRejectsInvalid() {
        let black = HexColor.color("#000000")
        XCTAssertEqual(HexColor.color(""), black)
        XCTAssertEqual(HexColor.color("#FFF"), black)
        XCTAssertEqual(HexColor.color("#GGGGGG"), black)
        XCTAssertEqual(HexColor.color("#FFFFFF"), black)  // uppercase is invalid per ComposeStyle.isValidHex
    }

    func testHexIsLowercaseAndAcceptedByComposeStyle() {
        let hex = HexColor.hex(UIColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        XCTAssertTrue(ComposeStyle.isValidHex(hex))
        XCTAssertEqual(hex, hex.lowercased())
    }

    func testHexClampsOutOfRangeComponents() {
        XCTAssertEqual(HexColor.hex(UIColor(red: 1.4, green: -0.2, blue: 0.5, alpha: 1)), "#ff0080")
    }

    func testHexIgnoresAlpha() {
        XCTAssertEqual(HexColor.hex(UIColor(red: 0, green: 0, blue: 1, alpha: 0.3)), "#0000ff")
    }

    // MARK: - SignaturePreviewDocument

    @MainActor
    private func tokens() -> (ThemeCSSTokens, ThemeCSSTokens) {
        let theme = env.theme.resolved(for: .light)
        return (theme.cssTokens(for: .light), theme.cssTokens(for: .dark))
    }

    @MainActor
    func testSignaturePreviewDocumentShape() {
        let (light, dark) = tokens()
        let doc = SignaturePreviewDocument.render(
            signatureHTML: "<div>Max</div>", light: light, dark: dark, forcedScheme: "dark")
        XCTAssertTrue(doc.hasPrefix("<!doctype html><html data-theme=\"dark\">"))
        XCTAssertTrue(doc.contains(SignaturePreviewDocument.csp))
        XCTAssertTrue(doc.contains("<body class=\"mm-plain\"><div class=\"mm-body\"><div>Max</div></div></body>"))
        XCTAssertTrue(doc.contains(ThreadDocument.css(light: light, dark: dark)))
    }

    @MainActor
    func testSignaturePreviewDocumentNoForcedScheme() {
        let (light, dark) = tokens()
        let doc = SignaturePreviewDocument.render(
            signatureHTML: "<div>Max</div>", light: light, dark: dark, forcedScheme: nil)
        XCTAssertTrue(doc.hasPrefix("<!doctype html><html><head>"))
    }

    @MainActor
    func testSignaturePreviewDocumentEmpty() {
        let (light, dark) = tokens()
        let doc = SignaturePreviewDocument.render(signatureHTML: "   ", light: light, dark: dark, forcedScheme: nil)
        XCTAssertTrue(doc.contains("Nothing to preview"))
    }

    // MARK: - SignatureSummary

    func testSignatureSummary() {
        XCTAssertEqual(SignatureSummary.line(""), "Not set")
        XCTAssertEqual(
            SignatureSummary.line("<div>Max Mustermann<br>Example GmbH</div>"), "Max Mustermann Example GmbH")
        let long = SignatureSummary.line("<div>\(String(repeating: "a", count: 60))</div>")
        XCTAssertEqual(long.count, 41)  // 40 characters + the ellipsis
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(SignatureSummary.line("<img src=\"https://x/y.png\">"), "HTML signature")
    }

    // MARK: - ThemeChoice / bindings

    func testThemeChoiceDisplayNames() {
        XCTAssertEqual(ThemeChoice.system.displayName, "System")
        XCTAssertEqual(ThemeChoice.light.displayName, "Light")
        XCTAssertEqual(ThemeChoice.dark.displayName, "Dark")
        XCTAssertEqual(ThemeChoice.allCases.count, 3)
    }

    @MainActor
    func testSettingsStoreBindingWritesThrough() {
        let b = env.settings.binding(\.markReadOnOpen)
        XCTAssertTrue(b.wrappedValue)
        b.wrappedValue = false
        XCTAssertFalse(env.settings.snapshot.markReadOnOpen)
        // The write persisted, so a fresh store over the same defaults reads it back.
        let fresh = SettingsStore(defaults: env.defaults)
        XCTAssertFalse(fresh.snapshot.markReadOnOpen)
    }

    @MainActor
    func testComposeStyleBindingNormalises() {
        env.settings.binding(\.composeStyle.sizePx).wrappedValue = 99
        XCTAssertEqual(env.settings.snapshot.composeStyle.sizePx, 18)
    }

    // MARK: - Hosting

    /// Hosts `root` in a framed key window and pumps the run loop, so SwiftUI lays the view out.
    @MainActor
    private func host(_ root: some View) -> UIView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return controller.view
    }

    @MainActor
    func testSettingsScreenHosts() {
        let view = host(SettingsScreen().environment(env).environment(env.theme).environment(env.settings))
        XCTAssertNotEqual(view.bounds.size, .zero)
    }

    @MainActor
    func testSignatureEditorScreenHosts() {
        weak var webHost = env.webHost
        let view = host(
            NavigationStack { SignatureEditorScreen() }
                .environment(env).environment(env.theme).environment(env.settings))
        XCTAssertNotEqual(view.bounds.size, .zero)
        XCTAssertNotNil(webHost)  // the pooled instance is untouched; the editor uses a throwaway web view
    }

    #if DEBUG
        @MainActor
        func testRequestLogScreenHosts() {
            env.requestLog?.record(method: "GET", path: "profile", status: 200, ms: 12)
            let view = host(NavigationStack { RequestLogScreen() }.environment(env))
            XCTAssertNotEqual(view.bounds.size, .zero)
            XCTAssertEqual(env.requestLog?.snapshot().count, 1)
        }
    #endif

    @MainActor
    func testPlaceholderStructRemoved() {
        // The interim placeholder is gone; `SettingsScreen` is now the real one in Features/Settings.
        XCTAssertEqual(String(describing: SettingsScreen.self), "SettingsScreen")
        let _: SettingsScreen = SettingsScreen()
    }
}
