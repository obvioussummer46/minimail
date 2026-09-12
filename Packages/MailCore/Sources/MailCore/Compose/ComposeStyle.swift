import Foundation

/// Default font family, size and colour applied to outgoing mail. Stored inside `Settings.composeStyle`.
///
/// Invariants, enforced on every mutation and on decode:
/// - `sizePx` lies in `sizeRange`
/// - `colorHex` matches `^#[0-9a-f]{6}$`
public struct ComposeStyle: Codable, Equatable, Sendable {

    /// Web-safe font stacks. `-apple-system` and `system-ui` are deliberately excluded: they do not
    /// resolve in Outlook or Gmail on the web, where the recipient reads the mail.
    public enum Family: String, Codable, CaseIterable, Sendable {
        case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier

        /// CSS `font-family` value, e.g. `Helvetica, Arial, sans-serif`.
        public var css: String {
            switch self {
            case .helvetica: return "Helvetica, Arial, sans-serif"
            case .arial: return "Arial, Helvetica, sans-serif"
            case .verdana: return "Verdana, Geneva, sans-serif"
            case .tahoma: return "Tahoma, Geneva, sans-serif"
            case .trebuchet: return "'Trebuchet MS', Helvetica, sans-serif"
            case .georgia: return "Georgia, 'Times New Roman', serif"
            case .times: return "'Times New Roman', Times, serif"
            case .courier: return "'Courier New', Courier, monospace"
            }
        }

        /// Human name for pickers, e.g. `Helvetica`.
        public var displayName: String {
            switch self {
            case .helvetica: return "Helvetica"
            case .arial: return "Arial"
            case .verdana: return "Verdana"
            case .tahoma: return "Tahoma"
            case .trebuchet: return "Trebuchet MS"
            case .georgia: return "Georgia"
            case .times: return "Times New Roman"
            case .courier: return "Courier New"
            }
        }
    }

    /// Inclusive size bounds in CSS px.
    public static let sizeRange: ClosedRange<Int> = 12...18
    public static let minSizePx = 12
    public static let maxSizePx = 18
    public static let defaultColorHex = "#000000"

    /// Sizes offered by the Settings picker.
    public static let sizeChoices: [Int] = [12, 13, 14, 15, 16, 18]

    public var family: Family = .helvetica

    /// Clamped into `sizeRange` by a property observer; decoding also clamps.
    public var sizePx: Int = 14 {
        didSet {
            if !Self.sizeRange.contains(sizePx) {
                sizePx = Self.clampedSize(sizePx)
            }
        }
    }

    /// Lowercased on set; a value not matching `^#[0-9a-f]{6}$` is replaced by `#000000`.
    public var colorHex: String = "#000000" {
        didSet {
            let lowered = colorHex.lowercased()
            colorHex = Self.isValidHex(lowered) ? lowered : "#000000"
        }
    }

    /// `font-family:{family.css};font-size:{sizePx}px;color:{colorHex}` — no trailing semicolon, no spaces
    /// around the separators.
    public var inlineCSS: String {
        "font-family:\(family.css);font-size:\(sizePx)px;color:\(colorHex)"
    }

    /// True iff `s` is 7 characters, starts with `#`, and the remaining 6 are in `[0-9a-f]` (lowercase only).
    public static func isValidHex(_ s: String) -> Bool {
        guard s.utf8.count == 7, s.first == "#" else { return false }
        let digits = "0123456789abcdef"
        return s.dropFirst().allSatisfy { digits.contains($0) }
    }

    /// Alias of `isValidHex`, kept because module 02's compose code names it this way.
    public static func isValidColorHex(_ hex: String) -> Bool { isValidHex(hex) }

    /// Lowercases, then validates. Returns nil when the result is not `#rrggbb`.
    public static func normalizedColorHex(_ hex: String) -> String? {
        let lowered = hex.lowercased()
        return isValidHex(lowered) ? lowered : nil
    }

    public init() {}

    /// Clamps the size and normalises the colour, so a caller cannot construct an invalid style.
    /// Assignments inside an initializer bypass the property observers, so this clamps explicitly too.
    public init(family: Family, sizePx: Int, colorHex: String) {
        self.init()
        self.family = family
        self.sizePx = Self.clampedSize(sizePx)
        self.colorHex = Self.normalizedColorHex(colorHex) ?? Self.defaultColorHex
    }

    static func clampedSize(_ value: Int) -> Int {
        min(max(value, sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// Tolerant decoding: every key optional, an unknown `family` raw value falls back to `.helvetica`,
    /// the size is clamped and the colour normalised. A type mismatch still throws, so that
    /// `Settings.init(from:)` can isolate the failure and substitute a default `ComposeStyle`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let raw = try container.decodeIfPresent(String.self, forKey: .family),
            let parsed = Family(rawValue: raw)
        {
            family = parsed
        }
        // Property observers do not run for assignments made inside an initializer, so the clamping and
        // normalisation have to be explicit here.
        if let size = try container.decodeIfPresent(Int.self, forKey: .sizePx) {
            sizePx = Self.clampedSize(size)
        }
        if let hex = try container.decodeIfPresent(String.self, forKey: .colorHex) {
            colorHex = Self.normalizedColorHex(hex) ?? Self.defaultColorHex
        }
    }
}
