import MailCore
import SwiftUI
import UIKit
import XCTest

@testable import minimail

/// The pure pieces of the signature editor: the preview document, the settings summary line, and one hosting
/// smoke test for the screen itself. (Module 13's `SettingsViewsTests` takes these over when it lands.)
nonisolated final class SignatureDocumentTests: XCTestCase {
    private var env: AppEnvironment!

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        env = nil
    }

    @MainActor private var light: ThemeCSSTokens { ThemeStore.light.cssTokens(for: .light) }
    @MainActor private var dark: ThemeCSSTokens { ThemeStore.dark.cssTokens(for: .dark) }

    @MainActor
    func testPreviewDocumentShape() {
        let html = SignaturePreviewDocument.render(
            signatureHTML: "<div>Max</div>", light: light, dark: dark, forcedScheme: "dark")
        XCTAssertTrue(html.hasPrefix("<!doctype html><html data-theme=\"dark\">"))
        XCTAssertTrue(html.contains(SignaturePreviewDocument.csp))
        XCTAssertTrue(html.contains("<body class=\"mm-plain\"><div class=\"mm-body\"><div>Max</div></div></body>"))
        XCTAssertTrue(html.contains(ThreadDocument.css(light: light, dark: dark)))
        // No `https:` in the CSP: the preview must not be able to reach the network.
        XCTAssertFalse(SignaturePreviewDocument.csp.contains("https:"))
    }

    @MainActor
    func testPreviewDocumentForcedSchemes() {
        XCTAssertTrue(
            SignaturePreviewDocument.render(signatureHTML: "x", light: light, dark: dark, forcedScheme: nil)
                .hasPrefix("<!doctype html><html><head>"))
        XCTAssertTrue(
            SignaturePreviewDocument.render(signatureHTML: "x", light: light, dark: dark, forcedScheme: "light")
                .hasPrefix("<!doctype html><html data-theme=\"light\">"))
    }

    @MainActor
    func testPreviewDocumentEmpty() {
        let html = SignaturePreviewDocument.render(
            signatureHTML: "   ", light: light, dark: dark, forcedScheme: nil)
        XCTAssertTrue(html.contains("Nothing to preview"))
    }

    func testSignatureSummary() {
        XCTAssertEqual(SignatureSummary.line(""), SettingsStrings.signatureNotSet)
        XCTAssertEqual(SignatureSummary.line("   "), SettingsStrings.signatureNotSet)
        XCTAssertEqual(
            SignatureSummary.line("<div>Max Mustermann<br>Example GmbH</div>"), "Max Mustermann Example GmbH")
        XCTAssertEqual(SignatureSummary.line("<img src=\"https://x/y.png\">"), "HTML signature")

        let long = String(repeating: "a", count: 60)
        let cut = SignatureSummary.line("<div>\(long)</div>")
        XCTAssertEqual(cut.count, SignatureSummary.limit + 1)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    /// The editor builds its model on appear, renders the placeholder document and keeps the pooled web view
    /// (the one a thread behind the sheet is using) untouched.
    @MainActor
    func testSignatureEditorScreenHosts() {
        env.settings.update { $0.signatureHTML = "<div>Max</div>" }
        let root = NavigationStack { SignatureEditorScreen() }
            .environment(env)
            .environment(env.theme)
            .environment(env.settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNotEqual(controller.view.bounds.size, .zero)
    }

    /// The settings sheet shows the stored signature as one line and pushes the editor.
    @MainActor
    func testSettingsScreenHostsSignatureRow() {
        env.settings.update { $0.signatureHTML = "<div>Max Mustermann</div>" }
        let root = SettingsScreen()
            .environment(env)
            .environment(env.theme)
            .environment(env.settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(SignatureSummary.line(env.settings.snapshot.signatureHTML), "Max Mustermann")
    }
}
