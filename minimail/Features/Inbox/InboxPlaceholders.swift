import MailCore
import SwiftUI

// Each struct carries the FINAL signature of the screen it stands in for. Module 10 deleted `ThreadScreen`
// and 11 deleted `ComposeScreen`; 12 deletes `LabelsScreen`, 13 deletes `SettingsScreen` and then the file.

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
