import Foundation
import GRDB
import MailCore
import MailHTML
import Observation
import os

/// Result of the last "Import from Gmail" tap (`[gmail-api §15]`).
nonisolated enum SignatureImportState: Equatable, Sendable {
    case idle
    case loading
    /// `syncState.sendAsSignature` is missing or blank.
    case unavailable
    case imported
}

/// State machine of `SignatureEditorScreen` (spec 13 §3.3, §4.9–§4.11; architecture §7.5).
///
/// The editor holds the raw HTML the owner types; `Settings.signatureHTML` only ever holds sanitized HTML.
/// Sanitizing runs on every debounced keystroke (to build the preview) and once more on save when the text has
/// changed since that pass, so what is stored is always the sanitized form of what the editor shows.
@Observable final class SignatureEditorModel {
    /// Editor hard cap. Larger input is neither previewed nor saved (`Sanitizer.maxInputBytes` is 2 MiB — far
    /// above anything a signature needs, and SwiftSoup on a 2 MiB string would stall the editor).
    nonisolated static let maxBytes = 65_536
    /// Debounce between the last keystroke and the preview rebuild, in milliseconds.
    nonisolated static let previewDebounceMs = 400

    /// The raw HTML in the `TextEditor`.
    var html: String = ""
    /// The document handed to the preview web view. Never empty.
    private(set) var previewDocument: String = ""
    /// The last successful `SignatureSanitizer.sanitize(html)` result; `nil` until the first successful pass.
    private(set) var sanitized: String?
    /// `SettingsStrings.dataImageWarning` when the sanitized HTML contains a `data:` image; else nil.
    private(set) var warning: String?
    /// Sanitizer / size error text; blocks Save while non-nil.
    private(set) var error: String?
    private(set) var importState: SignatureImportState = .idle
    private(set) var isSaving = false
    /// Bound to the import confirmation dialog.
    var showsImportConfirmation = false

    /// What `Settings.signatureHTML` held at `load()` / after the last save; the baseline for `isDirty`.
    private var savedHTML = ""
    /// The exact `html` that produced `sanitized` / `error`. Save re-sanitizes when it no longer matches, so a
    /// keystroke inside the debounce window can never be saved as the previous text.
    private var sanitizedSource: String?

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let light: ThemeCSSTokens
    @ObservationIgnored private let dark: ThemeCSSTokens
    @ObservationIgnored private let forcedScheme: String?

    /// - Parameters:
    ///   - env: for `SettingsStore` and the one `syncState` read.
    ///   - light/dark/forcedScheme: CSS tokens and the `html[data-theme]` value, captured once from `ThemeStore`.
    init(env: AppEnvironment, light: ThemeCSSTokens, dark: ThemeCSSTokens, forcedScheme: String?) {
        self.env = env
        self.light = light
        self.dark = dark
        self.forcedScheme = forcedScheme
        previewDocument = SignaturePreviewDocument.render(
            signatureHTML: "", light: light, dark: dark, forcedScheme: forcedScheme)
    }

    /// Copies `Settings.signatureHTML` into the editor and resets the derived state. Idempotent.
    func load() {
        html = env.settings.snapshot.signatureHTML
        savedHTML = html
        sanitized = nil
        sanitizedSource = nil
        warning = nil
        error = nil
        importState = .idle
        previewDocument = SignaturePreviewDocument.render(
            signatureHTML: "", light: light, dark: dark, forcedScheme: forcedScheme)
    }

    /// Sanitizes `html` off the main actor and refreshes `sanitized`, `warning`, `error` and `previewDocument`.
    ///
    /// Cancellation-safe and stale-safe: a result is dropped when the surrounding task was cancelled or when a
    /// newer keystroke changed `html` while SwiftSoup was parsing.
    func refreshPreview() async {
        let source = html
        guard source.utf8.count <= Self.maxBytes else {
            error = SettingsStrings.signatureTooLarge
            warning = nil
            sanitized = nil
            sanitizedSource = source
            return
        }
        // The sanitizer runs detached: SwiftSoup parsing is CPU work and must not stutter typing. Only `String`
        // and the `Sendable` outcome cross the boundary.
        let outcome = await Task.detached(priority: .userInitiated) {
            SignatureSanitizeOutcome(sanitizing: source)
        }.value
        guard !Task.isCancelled, html == source else { return }
        sanitizedSource = source
        switch outcome {
        case .clean(let clean):
            sanitized = clean
            error = nil
            warning = SignatureSanitizer.hasDataImages(clean) ? SettingsStrings.dataImageWarning : nil
            previewDocument = SignaturePreviewDocument.render(
                signatureHTML: clean, light: light, dark: dark, forcedScheme: forcedScheme)
        case .failed(let message, let detail):
            sanitized = nil
            warning = nil
            error = message
            Log.ui.notice("signature.sanitize.failed \(detail, privacy: .public)")
        }
    }

    /// Replaces the editor text with the raw Gmail signature stored by the last full sync. Never hits the network.
    func importFromGmail() async {
        importState = .loading
        let stored = try? await env.db.read { try SyncStateRepository.get($0, .sendAsSignature) }
        let value = (stored.flatMap { $0 } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            importState = .unavailable
            return
        }
        html = value
        importState = .imported
    }

    /// Writes the sanitized HTML into `Settings.signatureHTML`. `true` when the write happened.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        // Save inside the debounce window: what is in the editor has not been sanitized yet.
        if sanitizedSource != html { await refreshPreview() }
        guard error == nil, let clean = sanitized else { return false }
        env.settings.update { $0.signatureHTML = clean }
        // The editor now shows exactly what will be sent, so a second Save is disabled.
        html = clean
        savedHTML = clean
        sanitizedSource = clean
        Log.ui.notice("signature.saved bytes=\(clean.utf8.count, privacy: .public)")
        return true
    }

    /// `html` differs from the persisted `Settings.signatureHTML`.
    var isDirty: Bool { html != savedHTML }

    var canSave: Bool { isDirty && error == nil && !isSaving && html.utf8.count <= Self.maxBytes }
}

/// What one detached sanitize pass produced. `any Error` is not `Sendable`, so the failure is mapped to its
/// user-visible sentence inside the detached task and only strings cross back.
nonisolated enum SignatureSanitizeOutcome: Sendable, Equatable {
    case clean(String)
    case failed(message: String, detail: String)

    init(sanitizing html: String) {
        do {
            self = .clean(try SignatureSanitizer.sanitize(html))
        } catch {
            self = .failed(message: Self.message(for: error), detail: String(describing: error))
        }
    }

    /// Sanitizer failures the owner can act on get their own sentence; anything else is generic.
    static func message(for error: any Error) -> String {
        guard let sanitizerError = error as? SanitizerError else { return SettingsStrings.signatureUnknownError }
        switch sanitizerError {
        case .tooLarge: return SettingsStrings.signatureTooLarge
        case .cleanFailed: return SettingsStrings.signatureCleanFailed
        }
    }
}

/// The preview document (08 §10 A9, adapted). Pure string building; never throws.
nonisolated enum SignaturePreviewDocument {
    /// No `https:` in `img-src`: the preview must not reach the network even if the block-all rule list has not
    /// compiled yet, so a remote logo shows as a broken image here and the footer says so.
    static let csp =
        "default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    static let placeholder = #"<span class="mm-skeleton">Nothing to preview</span>"#

    /// `signatureHTML` is inserted **unescaped**: it is `SignatureSanitizer` output, never raw editor text.
    static func render(
        signatureHTML: String, light: ThemeCSSTokens, dark: ThemeCSSTokens, forcedScheme: String?
    ) -> String {
        let themeAttribute: String
        switch forcedScheme {
        case "dark": themeAttribute = " data-theme=\"dark\""
        case "light": themeAttribute = " data-theme=\"light\""
        default: themeAttribute = ""
        }
        let content =
            signatureHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? placeholder : signatureHTML
        return "<!doctype html><html\(themeAttribute)><head>"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<meta name=\"color-scheme\" content=\"light dark\">"
            + "<style>\(ThreadDocument.css(light: light, dark: dark))</style></head>"
            + "<body class=\"mm-plain\"><div class=\"mm-body\">\(content)</div></body></html>"
    }
}

/// The value shown next to "Signature" in the settings list.
nonisolated enum SignatureSummary {
    static let limit = 40

    static func line(_ html: String) -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SettingsStrings.signatureNotSet
        }
        let text = Quoting.textFromHTML(html)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Markup with no words of its own (a bare logo image) still has to read as something.
        guard !text.isEmpty else { return "HTML signature" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// User-visible strings of the settings feature, in one place so tests assert against what the view renders.
///
/// Only the signature-related strings exist so far: the rest of module 13 (badge, Advanced, sign-out) adds its
/// own when `SettingsModel.swift` lands.
nonisolated enum SettingsStrings {
    static let signatureNotSet = "Not set"
    static let previewFooter = "Remote images aren't loaded in this preview."
    static let dataImageWarning = "Gmail does not render data: images. Use a hosted https: image instead."
    static let signatureTooLarge = "The signature is too large. The limit is 64 KB."
    static let signatureCleanFailed = "This HTML couldn't be cleaned. Check for unbalanced tags."
    static let signatureUnknownError = "Couldn't process this HTML."
    static let importUnavailable = "No Gmail signature found for this account."
    static let importDone = "Imported from Gmail."
    static let importOverwriteTitle = "Replace the current signature?"
    static let importOverwriteDetail = "The text in the editor is replaced by the signature stored in Gmail."
    static let signatureFooter = "Added to the bottom of every message you send, when Use Signature is on."
}
