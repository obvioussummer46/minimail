import MailCore
import SwiftUI

/// One thread row (architecture §8.3). `body` maps precomputed strings to `Text`; no formatting, no `Task`.
struct ThreadRowView: View {
    let row: ThreadRow
    let previewLines: Int
    @ThemeTokensReader private var themeTokens

    init(row: ThreadRow, previewLines: Int = 2) {
        self.row = row
        self.previewLines = previewLines
    }

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
                    Text(row.snippet).font(.footnote).foregroundStyle(themeTokens.secondaryText).lineLimit(previewLines)
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
