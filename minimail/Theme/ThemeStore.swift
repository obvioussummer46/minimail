import SwiftUI
import UIKit

/// Holds the active theme choice and resolves it against the system colour scheme.
///
/// DEVIATION from spec 01 §3.7: `choice` is a computed property over `SettingsStore` rather than a stored
/// property with a `didSet` observer. The `@Observable` macro rewrites stored properties into computed ones,
/// which does not compose with property observers. Reading `choice` therefore tracks `SettingsStore.settings`,
/// so SwiftUI still updates on change, and writing it still persists exactly once. Behaviour is unchanged;
/// there is simply no duplicated state to keep in sync.
@Observable final class ThemeStore {
    static let light: any Theme = LightTheme()
    static let dark: any Theme = DarkTheme()
    /// Adding a theme later means one new struct and one entry here.
    static let registry: [String: any Theme] = ["light": light, "dark": dark]

    @ObservationIgnored let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Persisted through `SettingsStore` on every write.
    var choice: ThemeChoice {
        get { settings.settings.themeChoice }
        set { settings.update { $0.themeChoice = newValue } }
    }

    /// `.system` follows `systemScheme`; `.light` and `.dark` ignore it.
    func resolved(for systemScheme: ColorScheme) -> any Theme {
        switch choice {
        case .system: return systemScheme == .dark ? Self.dark : Self.light
        case .light: return Self.light
        case .dark: return Self.dark
        }
    }

    /// `nil` lets the device decide; otherwise the forced scheme.
    var preferredColorScheme: ColorScheme? {
        choice == .system ? nil : resolved(for: .light).colorScheme
    }

    /// Value for the document's `html[data-theme]` attribute, or `nil` when the document should follow the device.
    var forcedDocumentTheme: String? {
        preferredColorScheme.map { $0 == .dark ? "dark" : "light" }
    }

    /// For `overrideUserInterfaceStyle` and window chrome.
    var interfaceStyle: UIUserInterfaceStyle {
        switch choice {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}
