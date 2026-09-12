import MailCore
import SwiftUI
import UIKit
import XCTest

@testable import minimail

nonisolated final class ThemeStoreTests: XCTestCase {

    @MainActor
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "minimailTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeStore(_ name: String = #function, seededWith json: String? = nil) -> ThemeStore {
        let defaults = freshDefaults(name)
        if let json {
            defaults.set(Data(json.utf8), forKey: SettingsStore.key)
        }
        return ThemeStore(settings: SettingsStore(defaults: defaults))
    }

    @MainActor
    func testInitialChoiceFromSettings() {
        XCTAssertEqual(makeStore(seededWith: #"{"themeChoice":"light"}"#).choice, .light)
    }

    @MainActor
    func testChoicePersists() {
        let defaults = freshDefaults()
        let theme = ThemeStore(settings: SettingsStore(defaults: defaults))
        theme.choice = .dark
        XCTAssertEqual(theme.settings.settings.themeChoice, .dark)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.themeChoice, .dark)
    }

    @MainActor
    func testResolvedSystem() {
        let theme = makeStore()
        theme.choice = .system
        XCTAssertEqual(theme.resolved(for: .light).id, "light")
        XCTAssertEqual(theme.resolved(for: .dark).id, "dark")
    }

    @MainActor
    func testResolvedForced() {
        let theme = makeStore()
        theme.choice = .light
        XCTAssertEqual(theme.resolved(for: .dark).id, "light")
        theme.choice = .dark
        XCTAssertEqual(theme.resolved(for: .light).id, "dark")
    }

    @MainActor
    func testPreferredColorSchemeAndDocumentTheme() {
        let theme = makeStore()
        theme.choice = .system
        XCTAssertNil(theme.preferredColorScheme)
        XCTAssertNil(theme.forcedDocumentTheme)
        theme.choice = .light
        XCTAssertEqual(theme.preferredColorScheme, .light)
        XCTAssertEqual(theme.forcedDocumentTheme, "light")
        theme.choice = .dark
        XCTAssertEqual(theme.preferredColorScheme, .dark)
        XCTAssertEqual(theme.forcedDocumentTheme, "dark")
    }

    @MainActor
    func testInterfaceStyle() {
        let theme = makeStore()
        theme.choice = .system
        XCTAssertEqual(theme.interfaceStyle, .unspecified)
        theme.choice = .light
        XCTAssertEqual(theme.interfaceStyle, .light)
        theme.choice = .dark
        XCTAssertEqual(theme.interfaceStyle, .dark)
    }

    @MainActor
    func testRegistry() {
        XCTAssertEqual(ThemeStore.registry.keys.sorted(), ["dark", "light"])
        XCTAssertEqual(ThemeStore.registry["light"]?.colorScheme, .light)
        XCTAssertEqual(ThemeStore.registry["dark"]?.name, "Dark")
    }

    @MainActor
    func testCSSTokensHexFormat() {
        let themes: [any Theme] = [LightTheme(), DarkTheme()]
        for theme in themes {
            for scheme in [ColorScheme.light, .dark] {
                let tokens = theme.cssTokens(for: scheme)
                let all = [
                    tokens.background, tokens.surface, tokens.text, tokens.secondaryText,
                    tokens.accent, tokens.separator, tokens.link, tokens.cardBackground,
                ]
                for value in all {
                    XCTAssertTrue(ComposeStyle.isValidHex(value), "\(value) is not #rrggbb lowercase")
                }
            }
        }
    }

    @MainActor
    func testCSSTokensKnownValues() {
        let light = SystemPalette.cssTokens(for: .light)
        XCTAssertEqual(light.background, "#ffffff")
        XCTAssertEqual(light.text, "#000000")
        XCTAssertEqual(light.accent, "#007aff")
        XCTAssertEqual(light.cardBackground, "#ffffff")

        let dark = SystemPalette.cssTokens(for: .dark)
        XCTAssertEqual(dark.background, "#000000")
        XCTAssertEqual(dark.text, "#ffffff")
        XCTAssertEqual(dark.accent, "#0a84ff")
        XCTAssertEqual(dark.cardBackground, "#ffffff")
    }

    @MainActor
    func testHexCompositesAlpha() {
        let half = UIColor(white: 0, alpha: 0.5)
        XCTAssertEqual(SystemPalette.hex(half, scheme: .light, over: .white), "#808080")
    }

    @MainActor
    func testHexGrayscaleColor() {
        XCTAssertEqual(SystemPalette.hex(.white, scheme: .light), "#ffffff")
        XCTAssertEqual(SystemPalette.hex(.black, scheme: .light), "#000000")
    }
}
