import Foundation
import MailCore

/// Every user preference, in one Codable struct stored in `UserDefaults`.
///
/// `nonisolated` and `Sendable`: actors receive copies through `SettingsStore.snapshot`.
nonisolated struct Settings: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var themeChoice: ThemeChoice = .system
    var composeStyle: ComposeStyle = ComposeStyle()
    /// Sanitized before it is saved.
    var signatureHTML: String = ""
    var signatureEnabled: Bool = true
    /// Remote images stay off until the reader asks for them, per message.
    var loadRemoteImages: Bool = false
    var markReadOnOpen: Bool = true
    /// Flipped to true only after badge authorization succeeds.
    var showBadge: Bool = false
    var inboxPageSize: Int = 100
    /// Used as an OAuth `login_hint` only. The signed-in identity lives in the sync state table.
    var lastSignedInEmail: String?

    static let inboxPageSizeRange: ClosedRange<Int> = 50...200

    init() {}

    /// Tolerant decoding. Every key is optional, an unknown `themeChoice` falls back to `.system`, and a
    /// malformed nested `composeStyle` falls back to its default rather than failing the whole decode.
    /// A type mismatch on a scalar field still throws, so `SettingsStore` can fall back to defaults and log.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) { schemaVersion = value }
        if let raw = try container.decodeIfPresent(String.self, forKey: .themeChoice),
            let parsed = ThemeChoice(rawValue: raw)
        {
            themeChoice = parsed
        }
        if let value = try? container.decodeIfPresent(ComposeStyle.self, forKey: .composeStyle) {
            composeStyle = value
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .signatureHTML) { signatureHTML = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .signatureEnabled) {
            signatureEnabled = value
        }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .loadRemoteImages) {
            loadRemoteImages = value
        }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .markReadOnOpen) { markReadOnOpen = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .showBadge) { showBadge = value }
        if let value = try container.decodeIfPresent(Int.self, forKey: .inboxPageSize) { inboxPageSize = value }
        if let value = try container.decodeIfPresent(String.self, forKey: .lastSignedInEmail) {
            lastSignedInEmail = value
        }
        self = normalized()
    }

    /// Enforces the invariants that decoding and memberwise mutation can violate.
    func normalized() -> Settings {
        var copy = self
        copy.schemaVersion = 1
        copy.inboxPageSize = min(
            max(copy.inboxPageSize, Self.inboxPageSizeRange.lowerBound),
            Self.inboxPageSizeRange.upperBound
        )
        // Re-assigning runs ComposeStyle's property observers for values that arrived by memberwise mutation.
        copy.composeStyle.sizePx = copy.composeStyle.sizePx
        copy.composeStyle.colorHex = copy.composeStyle.colorHex
        let trimmed = copy.lastSignedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.lastSignedInEmail = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return copy
    }
}
