import MailCore
import SwiftUI

/// Non-blocking status row (architecture §8.2). Never a blocking alert.
struct StatusBanner: View {
    let kind: InboxBanner
    let isBusy: Bool
    let action: () -> Void
    let dismiss: (() -> Void)?
    let detailOverride: String?
    @ThemeTokensReader private var themeTokens

    init(
        kind: InboxBanner, isBusy: Bool = false, detailOverride: String? = nil,
        action: @escaping () -> Void, dismiss: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.isBusy = isBusy
        self.detailOverride = detailOverride
        self.action = action
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: StatusBanner.symbol(for: kind))
                .foregroundStyle(themeTokens.secondaryText).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(StatusBanner.title(for: kind)).font(.subheadline).foregroundStyle(themeTokens.text)
                if let d = detailOverride ?? StatusBanner.detail(for: kind) {
                    Text(d).font(.caption).foregroundStyle(themeTokens.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let t = StatusBanner.actionTitle(for: kind) {
                Button(t, action: action)
                    .buttonStyle(.bordered).controlSize(.small).disabled(isBusy)
                    .accessibilityIdentifier("inbox.banner.action")
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(themeTokens.secondaryText)
                    .accessibilityLabel("Dismiss").accessibilityIdentifier("inbox.banner.dismiss")
            }
        }
        .listRowBackground(themeTokens.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.banner")
    }

    nonisolated static func title(for kind: InboxBanner) -> String {
        switch kind {
        case .reauth: return "Sign in again to keep syncing"
        case .offline: return "Offline — changes will sync"
        case .error: return "Couldn’t refresh"
        }
    }

    nonisolated static func detail(for kind: InboxBanner) -> String? {
        switch kind {
        case .reauth, .offline: return nil
        case .error(let text): return text
        }
    }

    nonisolated static func symbol(for kind: InboxBanner) -> String {
        switch kind {
        case .reauth: return "person.crop.circle.badge.exclamationmark"
        case .offline: return "wifi.slash"
        case .error: return "exclamationmark.triangle"
        }
    }

    nonisolated static func actionTitle(for kind: InboxBanner) -> String? {
        switch kind {
        case .reauth: return "Sign in"
        case .offline: return nil
        case .error: return "Retry"
        }
    }
}

/// One row of the "Outbox" section (architecture §4.8 failure UX).
struct FailedSendRow: View {
    let record: OutboxRecord
    @ThemeTokensReader private var themeTokens

    init(record: OutboxRecord) { self.record = record }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "paperplane").foregroundStyle(themeTokens.secondaryText)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(FailedSendRow.subject(for: record)).font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1).foregroundStyle(themeTokens.text)
                Text(FailedSendRow.recipients(for: record)).font(.footnote)
                    .lineLimit(1).foregroundStyle(themeTokens.secondaryText)
                Text(FailedSendRow.errorLine(for: record)).font(.footnote)
                    .lineLimit(1).foregroundStyle(themeTokens.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    nonisolated static func subject(for record: OutboxRecord) -> String {
        let trimmed = record.sendJob?.subject.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(No subject)" : trimmed
    }

    nonisolated static func recipients(for record: OutboxRecord) -> String {
        guard let job = record.sendJob else { return "To: —" }
        let names = (job.to + job.cc).map(\.displayName)
        return names.isEmpty ? "To: —" : "To: " + names.joined(separator: ", ")
    }

    nonisolated static func errorLine(for record: OutboxRecord) -> String {
        "Not sent — " + (record.lastError ?? "Unknown error")
    }
}
