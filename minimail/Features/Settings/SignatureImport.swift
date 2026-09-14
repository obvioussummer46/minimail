import Foundation
import GRDB
import MailCore
import MailHTML
import os

/// Adopting the Gmail send-as signature into `Settings.signatureHTML`.
///
/// `SyncEngine.fullSync` already stores the preferred send-as signature in `syncState.sendAsSignature` on every
/// full sync, and `OutboxIdentitySource.current()` already feeds `Settings.signatureHTML` to `OutgoingBodies` at
/// drain time — but nothing ever moved the one into the other, so outgoing mail carried no signature until the
/// owner typed one.
///
/// This adopts it once, on the first full sync that produces one, and never again: after that the stored
/// signature is the owner's to edit. Module 13's `SignatureEditorModel.importFromGmail` re-imports on demand
/// from the same sync-state key and supersedes the automatic path for every later change.
nonisolated enum SignatureImport {

    /// Marks that the automatic adoption has run, so editing the signature back to empty is not undone by the
    /// next sync. Stored next to the signature itself rather than in `syncState`: it is a settings decision, and
    /// a sign-out wipe of the database must not make the app re-adopt over the owner's edit.
    static let adoptedDefaultsKey = "com.minimail.signature.adopted"

    /// Reads `syncState.sendAsSignature`, sanitizes it off the main actor and writes it into `Settings`.
    ///
    /// Does nothing when the adoption already ran, when Gmail has no signature for the preferred send-as
    /// identity, or when the owner has already put something in `Settings.signatureHTML`. Never throws: a
    /// signature that will not sanitize is logged and skipped, because it must not be able to fail a launch.
    @MainActor
    static func adoptGmailSignatureIfUnset(db: any DatabaseReader, settings: SettingsStore) async {
        // The store's own defaults, so a test suite with its own suite is isolated without passing one in.
        let defaults = settings.defaults
        guard !defaults.bool(forKey: adoptedDefaultsKey) else { return }
        guard settings.snapshot.signatureHTML.isEmpty else { return }

        let stored = try? await db.read { try SyncStateRepository.get($0, .sendAsSignature) }
        guard let raw = stored.flatMap({ $0 }), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard let cleaned = await sanitize(raw) else { return }
        // An all-whitespace signature is Gmail's way of saying "none"; adopting "" would still count as adopted.
        defaults.set(true, forKey: adoptedDefaultsKey)
        guard !cleaned.isEmpty else { return }
        settings.update { $0.signatureHTML = cleaned }
        Log.ui.notice("signature.adopted bytes=\(cleaned.utf8.count, privacy: .public)")
    }

    /// SwiftSoup parsing is not cheap and this runs during launch, so it stays off the main actor.
    static func sanitize(_ html: String) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                return try SignatureSanitizer.sanitize(html)
            } catch {
                Log.ui.error("signature.sanitize.failed \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }
}
