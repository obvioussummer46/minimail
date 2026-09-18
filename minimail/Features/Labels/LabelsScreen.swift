import SwiftUI

/// The labels sheet (architecture §8.1). Contract with module 09: call `onSelect(scope)` exactly once per selection
/// and do not dismiss the sheet — the presenter clears `activeSheet`. "Done" is the only self-dismissal.
struct LabelsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @ThemeTokensReader private var themeTokens
    @State private var model: LabelsModel?

    private let onSelect: (InboxScope) -> Void

    init(onSelect: @escaping (InboxScope) -> Void) { self.onSelect = onSelect }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    LabelsListView(model: model, onSelect: onSelect)
                } else {
                    themeTokens.background.ignoresSafeArea()
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("labels.done")
                }
            }
        }
        .onAppear { if model == nil { model = LabelsModel(env: env) } }
        .task {
            if model == nil { model = LabelsModel(env: env) }
            await model?.appeared()
        }
        .onDisappear { model?.stop() }
    }
}

/// Everything that needs the model — the `List`, its two sections, the footer, pull-to-refresh.
private struct LabelsListView: View {
    let model: LabelsModel
    let onSelect: (InboxScope) -> Void
    @ThemeTokensReader private var themeTokens

    var body: some View {
        List {
            Section("Mailboxes") {
                ForEach(model.mailboxRows) { row in rowButton(row) }
            }
            if let empty = model.emptyState {
                Section("Labels") { LabelsEmptyView(state: empty) }
            } else {
                Section {
                    ForEach(model.labelRows) { row in rowButton(row) }
                } header: {
                    Text("Labels")
                } footer: {
                    Text(model.footerText).accessibilityIdentifier("labels.footer")
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("labels.list")
        .refreshable { await model.refresh() }
        .background(themeTokens.background)
    }

    @ViewBuilder private func rowButton(_ row: LabelRow) -> some View {
        Button {
            model.select(row.scope)
            onSelect(row.scope)
        } label: {
            LabelRowView(row: row)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("labels.row.\(row.id)")
    }
}

/// One row: leading icon or colour dot, title, trailing count.
private struct LabelRowView: View {
    let row: LabelRow
    @ThemeTokensReader private var themeTokens

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let symbol = row.symbol {
                    Image(systemName: symbol).foregroundStyle(themeTokens.secondaryText)
                } else {
                    LabelColorDot(colorHex: row.colorHex)
                }
            }
            .frame(width: 20, height: 20)

            Text(row.title).font(.body).foregroundStyle(themeTokens.text).lineLimit(1).truncationMode(.middle)

            Spacer(minLength: 8)

            if let count = row.countText {
                Text(count).font(.subheadline).monospacedDigit().foregroundStyle(themeTokens.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// `ContentUnavailableView` / `ProgressView` for the three empty states (§6.5).
private struct LabelsEmptyView: View {
    let state: LabelsEmptyState

    var body: some View {
        switch state {
        case .initialSync:
            ProgressView("Loading labels…")
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, alignment: .center)
        case .noLabels:
            ContentUnavailableView(
                "No labels", systemImage: "tag", description: Text("Labels appear after the first sync.")
            )
            .accessibilityIdentifier("labels.empty")
        case .unavailable:
            ContentUnavailableView(
                "Labels unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Pull down to try again.")
            )
            .accessibilityIdentifier("labels.empty")
        }
    }
}
