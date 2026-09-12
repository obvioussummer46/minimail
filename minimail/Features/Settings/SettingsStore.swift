import Foundation
import MailCore

/// Reads and writes `Settings` as one JSON blob in `UserDefaults`.
@Observable final class SettingsStore {
    static let key = "de.newtelco.minimail.settings"

    private(set) var settings: Settings

    /// The defaults instance this store writes to. Tests read it back.
    @ObservationIgnored let defaults: UserDefaults

    /// One `data(forKey:)` plus one JSON decode. A missing key or a decode failure yields defaults; the
    /// failure is logged with the payload length only, never its content.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do {
                settings = try JSONDecoder().decode(Settings.self, from: data)
            } catch {
                Log.ui.error(
                    """
                    settings decode failed (\(data.count, privacy: .public) bytes): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                settings = Settings()
            }
        } else {
            settings = Settings()
        }
    }

    /// Applies `change` to a copy, normalises it, publishes one observation change and writes synchronously.
    /// An encoding failure is logged; the in-memory value is still updated.
    func update(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        copy = copy.normalized()
        settings = copy
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            defaults.set(try encoder.encode(copy), forKey: Self.key)
        } catch {
            Log.ui.error("settings encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sendable copy for actors.
    var snapshot: Settings { settings }
}
