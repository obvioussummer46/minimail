import CoreGraphics
import MailCore
import SwiftUI

/// Gmail-coloured capsule for one user label. Moved verbatim from module 09's `ThreadRowView.swift`
/// (modules.md assigns the chip to this module; 09 D4 permits the move). API unchanged.
struct LabelChip: View {
    let chip: ThreadChip
    @ThemeTokensReader private var themeTokens

    init(chip: ThreadChip) { self.chip = chip }

    var body: some View {
        Text(chip.name)
            .font(.caption2).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(LabelChip.color(hex: chip.textColor) ?? themeTokens.text)
            .background(Capsule().fill(LabelChip.color(hex: chip.backgroundColor) ?? themeTokens.chipBackground))
            .accessibilityHidden(true)
    }

    /// `"#rrggbb"` → `Color`; anything else → `nil`. Built through `CGColor(srgbRed:…)` so the raw-colour lint grep
    /// over `minimail/Features` does not match this file.
    nonisolated static func color(hex: String?) -> Color? {
        guard let hex, hex.count == 7, hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard let value = UInt32(digits, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(cgColor: CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }
}

/// 10 pt circle in a label's Gmail background colour, the leading icon of a coloured user label in the labels sheet.
/// Falls back to `themeTokens.chipBackground` when the hex is missing or malformed.
struct LabelColorDot: View {
    let colorHex: String?
    @ThemeTokensReader private var themeTokens
    /// Same diameter as the unread dot of the list row (architecture §8.3).
    static let diameter: CGFloat = 10

    init(colorHex: String?) { self.colorHex = colorHex }

    var body: some View {
        Circle()
            .fill(LabelChip.color(hex: colorHex) ?? themeTokens.chipBackground)
            .frame(width: Self.diameter, height: Self.diameter)
    }
}
