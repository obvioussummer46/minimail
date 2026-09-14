import MailCore
import SwiftUI

// Each struct carries the FINAL signature of the screen it stands in for. Module 10 deleted `ThreadScreen`,
// 11 deletes `ComposeScreen`, 12 deletes `LabelsScreen`, 13 deletes `SettingsScreen` and then the whole file.

/// Replaced by module 11 (`minimail/Features/Compose/ComposeScreen.swift`).
struct ComposeScreen: View {
    let input: ComposeInput
    @Environment(\.dismiss) private var dismiss
    init(input: ComposeInput) { self.input = input }
    var body: some View {
        NavigationStack {
            Text("Compose (module 11)")
                .navigationTitle("Compose")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

/// Replaced by module 12 (`minimail/Features/Labels/LabelsScreen.swift`).
/// Contract for 12: call `onSelect(scope)` exactly once per selection and do NOT dismiss the sheet.
struct LabelsScreen: View {
    let onSelect: (InboxScope) -> Void
    init(onSelect: @escaping (InboxScope) -> Void) { self.onSelect = onSelect }
    var body: some View {
        NavigationStack {
            List {
                Section("Mailboxes") {
                    Button {
                        onSelect(.inbox)
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    Button {
                        onSelect(.today)
                    } label: {
                        Label("Today", systemImage: "sun.max")
                    }
                }
            }
            .navigationTitle("Labels")
        }
    }
}

/// Replaced by module 13 (`minimail/Features/Settings/SettingsScreen.swift`).
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    init() {}
    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    Text(env.auth.state.email ?? "—")
                    Button("Sign out", role: .destructive) {
                        // Dismiss the sheet first so the switch to SignInScreen is clean, and forget the remembered
                        // address so the next sign-in shows Google's account chooser (lets you pick another account).
                        dismiss()
                        env.settings.update { $0.lastSignedInEmail = nil }
                        Task { await env.auth.signOut() }
                    }
                    .accessibilityIdentifier("placeholder.signout")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
