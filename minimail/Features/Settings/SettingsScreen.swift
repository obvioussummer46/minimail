import MailCore
import SwiftUI
import UIKit

/// Route pushed from the Compose section. A value-based link keeps `SignatureEditorScreen` (and its `WKWebView`)
/// out of the row body until the row is tapped.
private enum SettingsRoute: Hashable { case signature }

/// The Settings sheet (architecture §8.1, §11). Presented by 09 for `ActiveSheet.settings`; inherits
/// `AppEnvironment`, `ThemeStore` and `SettingsStore` from the window.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: SettingsModel?

    init() {}

    var body: some View {
        NavigationStack {
            Form {
                if let model {
                    SettingsAccountSection(model: model)
                    SettingsAppearanceSection()
                    SettingsComposeSection()
                    SettingsReadingSection()
                    SettingsNotificationsSection(model: model)
                    SettingsAdvancedSection(model: model)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
            .navigationDestination(for: SettingsRoute.self) { _ in SignatureEditorScreen() }
        }
        .onAppear { if model == nil { model = SettingsModel(env: env) } }
        .task {
            await model?.verifyBadgeAuthorization()
            await model?.load()
        }
    }
}

// MARK: - Sections

private struct SettingsAccountSection: View {
    let model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            LabeledContent("Email", value: model.accountEmailLine)
                .accessibilityIdentifier("settings.account.email")
                .accessibilityLabel("Account email, \(model.accountEmailLine)")
            if let name = model.info.displayName, !name.isEmpty {
                LabeledContent("Name", value: name).accessibilityIdentifier("settings.account.name")
            }
            Button(SettingsStrings.signOutTitle, role: .destructive) { model.showsSignOutConfirmation = true }
                .disabled(model.isSigningOut)
                .accessibilityIdentifier("settings.signOut")
        } header: {
            Text("Account")
        } footer: {
            Text(SettingsStrings.accountFooter)
        }
        .confirmationDialog(
            SettingsStrings.signOutConfirmTitle, isPresented: bindableModel.showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(SettingsStrings.signOutTitle, role: .destructive) {
                dismiss()
                Task { await model.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsStrings.signOutConfirmDetail)
        }
    }

    private var bindableModel: Bindable<SettingsModel> { Bindable(model) }
}

private struct SettingsAppearanceSection: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        @Bindable var theme = theme
        Section("Appearance") {
            Picker("Theme", selection: $theme.choice) {
                ForEach(ThemeChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.theme")
        }
    }
}

private struct SettingsComposeSection: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Section {
            Picker("Font", selection: settings.binding(\.composeStyle.family)) {
                ForEach(ComposeStyle.Family.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu).accessibilityIdentifier("settings.font")

            Picker("Size", selection: settings.binding(\.composeStyle.sizePx)) {
                ForEach(ComposeStyle.sizeChoices, id: \.self) { Text("\($0) px").tag($0) }
            }
            .pickerStyle(.menu).accessibilityIdentifier("settings.fontSize")

            ColorPicker("Text Color", selection: composeColorBinding, supportsOpacity: false)
                .accessibilityIdentifier("settings.color")

            NavigationLink(value: SettingsRoute.signature) {
                LabeledContent("Signature", value: SignatureSummary.line(settings.settings.signatureHTML))
            }
            .accessibilityIdentifier("settings.signature")

            Toggle("Use Signature", isOn: settings.binding(\.signatureEnabled))
                .accessibilityIdentifier("settings.signatureEnabled")
        } header: {
            Text("Compose")
        } footer: {
            Text(SettingsStrings.composeFooter)
        }
    }

    private var composeColorBinding: Binding<Color> {
        Binding(
            get: { HexColor.color(settings.settings.composeStyle.colorHex) },
            set: { newColor in settings.update { $0.composeStyle.colorHex = HexColor.hex(newColor) } })
    }
}

private struct SettingsReadingSection: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Section {
            Toggle("Load Remote Images Automatically", isOn: settings.binding(\.loadRemoteImages))
                .accessibilityIdentifier("settings.loadImages")
            Toggle("Mark as Read When Opened", isOn: settings.binding(\.markReadOnOpen))
                .accessibilityIdentifier("settings.markRead")
        } header: {
            Text("Reading")
        } footer: {
            Text(SettingsStrings.readingFooter)
        }
    }
}

private struct SettingsNotificationsSection: View {
    let model: SettingsModel
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("Show Unread Count on Icon", isOn: badgeBinding)
                .disabled(model.badgeState == .requesting)
                .accessibilityIdentifier("settings.badge")
            if model.badgeState == .denied {
                Button(SettingsStrings.badgeOpenSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("settings.badgeHelp")
            }
        } header: {
            Text("Notifications")
        } footer: {
            if model.badgeState == .denied { Text(SettingsStrings.badgeDeniedFooter) }
        }
    }

    private var badgeBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.showBadge },
            set: { on in Task { await model.setBadgeEnabled(on) } })
    }
}

private struct SettingsAdvancedSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            LabeledContent("Status", value: model.statusLine).accessibilityIdentifier("settings.advanced.status")
            LabeledContent("Last Sync", value: model.lastSyncLine)
                .accessibilityIdentifier("settings.advanced.lastSync")
            LabeledContent("History ID", value: model.info.historyId ?? "—")
                .accessibilityIdentifier("settings.advanced.historyId")
            LabeledContent("Pending Operations", value: "\(model.info.pendingOps)")
                .accessibilityIdentifier("settings.advanced.pending")
            LabeledContent("Failed Sends", value: "\(model.info.failedSends)")
                .accessibilityIdentifier("settings.advanced.failed")

            Button { model.showsResyncConfirmation = true } label: {
                HStack {
                    Label(SettingsStrings.resyncTitle, systemImage: "arrow.clockwise")
                    Spacer()
                    if model.isResyncing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.isResyncing)
            .accessibilityIdentifier("settings.resync")

            #if DEBUG
                NavigationLink {
                    RequestLogScreen()
                } label: {
                    Label("Recent Requests", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("settings.requestLog")
            #endif

            LabeledContent("Version", value: model.versionLine).accessibilityIdentifier("settings.version")
        } header: {
            Text("Advanced")
        } footer: {
            Text(SettingsStrings.advancedFooter)
        }
        .confirmationDialog(
            SettingsStrings.resyncConfirmTitle, isPresented: bindableModel.showsResyncConfirmation,
            titleVisibility: .visible
        ) {
            Button(SettingsStrings.resyncTitle) { Task { await model.fullResync() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsStrings.resyncConfirmDetail)
        }
    }

    private var bindableModel: Bindable<SettingsModel> { Bindable(model) }
}

// MARK: - Request log (DEBUG)

#if DEBUG
    /// The last `RequestLog.capacity` requests, newest first (architecture §11, §6.5). Never shows tokens or bodies.
    struct RequestLogScreen: View {
        @Environment(AppEnvironment.self) private var env
        @State private var lines: [String] = []

        var body: some View {
            List {
                if lines.isEmpty {
                    ContentUnavailableView("No requests yet", systemImage: "list.bullet.rectangle")
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("requestLog.list")
            .navigationTitle("Recent Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { reload() }.accessibilityIdentifier("requestLog.refresh")
                }
            }
            .onAppear { reload() }
        }

        private func reload() { lines = (env.requestLog?.snapshot() ?? []).reversed() }
    }
#endif

// MARK: - Bindings and labels

extension SettingsStore {
    /// Two-way binding to one field of `Settings`, writing through `update` (which normalises and persists).
    /// ADDITION (D5).
    func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}
