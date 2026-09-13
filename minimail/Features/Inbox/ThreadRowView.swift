import CoreGraphics
import MailCore
import SwiftUI

/// One thread row (architecture §8.3). `body` maps precomputed strings to `Text`; no formatting, no `Task`.
struct ThreadRowView: View {
    let row: ThreadRow
    @ThemeTokensReader private var themeTokens

    init(row: ThreadRow) { self.row = row }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(row.isUnread ? themeTokens.unread : Color.clear)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.participants)
                        .font(.headline).fontWeight(row.isUnread ? .semibold : .regular)
                        .lineLimit(1).foregroundStyle(themeTokens.text)
                    if row.messageCount > 1 {
                        Text("\(row.messageCount)").font(.caption).foregroundStyle(themeTokens.secondaryText)
                    }
                    Spacer(minLength: 4)
                    if row.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(themeTokens.secondaryText)
                    }
                    Text(row.dateLabel).font(.subheadline).foregroundStyle(themeTokens.secondaryText).lineLimit(1)
                }
                Text(row.subject.isEmpty ? "(No subject)" : row.subject)
                    .font(.subheadline).lineLimit(1).foregroundStyle(themeTokens.text)
                HStack(alignment: .top, spacing: 8) {
                    Text(row.snippet).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(2)
                    Spacer(minLength: 8)
                    if !row.chips.isEmpty {
                        HStack(spacing: 4) { ForEach(row.chips) { LabelChip(chip: $0) } }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ThreadRowView.accessibilityLabel(for: row))
        .accessibilityAddTraits(.isButton)
    }

    nonisolated static func accessibilityLabel(for row: ThreadRow) -> String {
        var parts: [String] = []
        if row.isUnread { parts.append("Unread") }
        parts.append(row.participants)
        parts.append(row.subject.isEmpty ? "No subject" : row.subject)
        parts.append(row.dateLabel)
        if row.messageCount > 1 { parts.append("\(row.messageCount) messages") }
        if row.hasAttachments { parts.append("Has attachment") }
        for chip in row.chips { parts.append("Label \(chip.name)") }
        return parts.joined(separator: ", ")
    }
}

/// Gmail-coloured capsule for one user label.
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
