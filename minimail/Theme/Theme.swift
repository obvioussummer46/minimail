import MailCore
import SwiftUI
import UIKit

/// Every colour a screen may use. Views read these through `@ThemeTokensReader`; `make lint` rejects raw
/// colours under `minimail/Features` and `minimail/Web`.
struct ThemeTokens: Equatable, Sendable {
    var background: Color
    var groupedBackground: Color
    var surface: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var unread: Color
    var separator: Color
    var link: Color
    var chipBackground: Color
    var swipeArchive: Color
    var swipeRead: Color
}

/// A theme is a name, a colour scheme and a token set. Adding one later is a new struct plus one registry entry.
protocol Theme: Sendable {
    /// Stable and persisted, e.g. `light`.
    var id: String { get }
    var name: String { get }
    /// What SwiftUI and WebKit render as when this theme is forced.
    var colorScheme: ColorScheme { get }
    var tokens: ThemeTokens { get }
    /// Hex tokens for the thread document, resolved for `scheme`.
    func cssTokens(for scheme: ColorScheme) -> ThemeCSSTokens
}

struct LightTheme: Theme {
    let id = "light"
    let name = "Light"
    let colorScheme = ColorScheme.light
    let tokens = ThemeTokens.system

    func cssTokens(for scheme: ColorScheme) -> ThemeCSSTokens { SystemPalette.cssTokens(for: scheme) }
}

struct DarkTheme: Theme {
    let id = "dark"
    let name = "Dark"
    let colorScheme = ColorScheme.dark
    let tokens = ThemeTokens.system

    func cssTokens(for scheme: ColorScheme) -> ThemeCSSTokens { SystemPalette.cssTokens(for: scheme) }
}

extension ThemeTokens {
    /// Stock themes use system semantic colours, so they adapt to Increase Contrast and Smart Invert for free.
    static let system = ThemeTokens(
        background: Color(.systemBackground),
        groupedBackground: Color(.systemGroupedBackground),
        surface: Color(.secondarySystemBackground),
        text: Color(.label),
        secondaryText: Color(.secondaryLabel),
        accent: Color(.tintColor),
        unread: Color(.systemBlue),
        separator: Color(.separator),
        link: Color(.link),
        chipBackground: Color(.tertiarySystemFill),
        swipeArchive: Color(.systemIndigo),
        swipeRead: Color(.systemBlue)
    )
}

/// Persisted user choice. `nonisolated` because it is a field of the `Sendable` `Settings` struct that actors copy.
nonisolated enum ThemeChoice: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Resolves UIKit semantic colours to CSS hex per scheme. Hex is used only by the web template.
enum SystemPalette {

    /// `#rrggbb`, lowercase, of `color` resolved for `scheme`. Colours with alpha below 1 are composited over
    /// `background` resolved for the same scheme. Components are clamped to 0...1 and rounded to the nearest byte.
    static func hex(_ color: UIColor, scheme: ColorScheme, over background: UIColor = .systemBackground) -> String {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let (fr, fg, fb, fa) = components(of: color.resolvedColor(with: traits))
        let (br, bg, bb, _) = components(of: background.resolvedColor(with: traits))
        let r = fa < 1 ? fa * fr + (1 - fa) * br : fr
        let g = fa < 1 ? fa * fg + (1 - fa) * bg : fg
        let b = fa < 1 ? fa * fb + (1 - fa) * bb : fb
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// The eight document tokens. `cardBackground` is always the light-mode background: the card strategy
    /// renders sender HTML on white even in dark mode.
    static func cssTokens(for scheme: ColorScheme) -> ThemeCSSTokens {
        let accent = UIColor(named: "AccentColor", in: .main, compatibleWith: nil) ?? .systemBlue
        return ThemeCSSTokens(
            background: hex(.systemBackground, scheme: scheme),
            surface: hex(.secondarySystemBackground, scheme: scheme),
            text: hex(.label, scheme: scheme),
            secondaryText: hex(.secondaryLabel, scheme: scheme),
            accent: hex(accent, scheme: scheme),
            separator: hex(.separator, scheme: scheme),
            link: hex(.link, scheme: scheme),
            cardBackground: hex(.systemBackground, scheme: .light)
        )
    }

    private static func components(of color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) { return (r, g, b, a) }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &a) { return (white, white, white, a) }
        return (0, 0, 0, 1)
    }

    private static func byte(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}

/// Yields the tokens of the theme resolved for the current system scheme. Requires `ThemeStore` in the
/// environment, which `MinimailApp` injects; a view rendered without it traps, so tests must inject it too.
@propertyWrapper
struct ThemeTokensReader: DynamicProperty {
    @Environment(ThemeStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var wrappedValue: ThemeTokens { store.resolved(for: colorScheme).tokens }

    init() {}
}
