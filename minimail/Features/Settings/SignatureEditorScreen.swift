import MailCore
import SwiftUI
import UIKit
import WebKit

/// Raw-HTML signature editor with a live preview (spec 13 §6.10; architecture §7.5, §8.2).
///
/// Pushed from `SettingsScreen`, so it never carries a `NavigationStack` of its own. Every decision lives in
/// `SignatureEditorModel`; this file is presentation plus the throwaway web view that renders the preview.
struct SignatureEditorScreen: View {
    @State private var model: SignatureEditorModel?
    @Environment(AppEnvironment.self) private var env
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @ThemeTokensReader private var themeTokens

    init() {}

    var body: some View {
        content
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .onAppear { ensureModel() }
            .task(id: model?.html) { await debouncedRefresh() }
    }

    @ViewBuilder private var content: some View {
        if let model {
            SignatureEditorForm(
                model: model, host: env.webHost, interfaceStyle: theme.interfaceStyle, tokens: themeTokens)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("signature.loading")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
                .disabled(!(model?.canSave ?? false))
                .accessibilityIdentifier("signature.save")
        }
    }

    /// The tokens are captured once: the preview document is rebuilt per keystroke, not per theme change, and a
    /// theme change closes the editor's stack anyway (the whole app re-themes).
    private func ensureModel() {
        guard model == nil else { return }
        let resolved = theme.resolved(for: theme.preferredColorScheme ?? .light)
        let created = SignatureEditorModel(
            env: env,
            light: resolved.cssTokens(for: .light),
            dark: resolved.cssTokens(for: .dark),
            forcedScheme: theme.forcedDocumentTheme)
        created.load()
        model = created
    }

    /// `.task(id:)` is the debounce: SwiftUI cancels this task on every keystroke, so the sleep throws and no
    /// sanitize starts until typing stops for `previewDebounceMs`.
    private func debouncedRefresh() async {
        guard let model else { return }
        try? await Task.sleep(for: .milliseconds(SignatureEditorModel.previewDebounceMs))
        guard !Task.isCancelled else { return }
        await model.refreshPreview()
    }

    private func save() {
        guard let model else { return }
        Task {
            if await model.save() { dismiss() }
        }
    }
}

/// The form itself. Split out so the editor's bindings, dialog and footers stay inside the type checker's budget
/// (module 10 and 11 hit that wall with a single expression).
private struct SignatureEditorForm: View {
    @Bindable var model: SignatureEditorModel
    let host: WebViewHost
    let interfaceStyle: UIUserInterfaceStyle
    let tokens: ThemeTokens

    var body: some View {
        Form {
            // `Section(_:content:footer:)` does not exist; the header/footer pair is the initializer that does.
            Section {
                TextEditor(text: $model.html)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("signature.editor")
                    .accessibilityLabel("Signature HTML")
            } header: {
                Text("HTML")
            } footer: {
                statusFooter
            }

            Section {
                SignaturePreviewView(
                    host: host,
                    document: model.previewDocument,
                    interfaceStyle: interfaceStyle,
                    backgroundColor: UIColor(tokens.surface)
                )
                .frame(height: 180)
                .accessibilityIdentifier("signature.preview")
                .accessibilityLabel("Signature preview")
            } header: {
                Text("Preview")
            } footer: {
                Text(SettingsStrings.previewFooter)
            }

            Section {
                Button(action: importTapped) {
                    Label("Import from Gmail", systemImage: "arrow.down.doc")
                }
                .disabled(model.importState == .loading)
                .accessibilityIdentifier("signature.import")
            } header: {
                Text("Gmail")
            } footer: {
                importFooter
            }
        }
        .confirmationDialog(
            SettingsStrings.importOverwriteTitle,
            isPresented: $model.showsImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace") { Task { await model.importFromGmail() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsStrings.importOverwriteDetail)
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if let error = model.error {
            Label(error, systemImage: "xmark.octagon")
                .font(.footnote)
                .foregroundStyle(tokens.text)
                .accessibilityIdentifier("signature.error")
        } else if let warning = model.warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(tokens.secondaryText)
                .accessibilityIdentifier("signature.warning")
        } else {
            Text(SettingsStrings.signatureFooter)
        }
    }

    @ViewBuilder private var importFooter: some View {
        switch model.importState {
        case .idle:
            EmptyView()
        case .loading:
            Text("Loading…").font(.footnote).accessibilityIdentifier("signature.importState")
        case .unavailable:
            Text(SettingsStrings.importUnavailable).font(.footnote).accessibilityIdentifier("signature.importState")
        case .imported:
            Text(SettingsStrings.importDone).font(.footnote).accessibilityIdentifier("signature.importState")
        }
    }

    /// Overwriting something the owner typed asks first; replacing an empty editor does not.
    private func importTapped() {
        if model.isDirty || !model.html.isEmpty {
            model.showsImportConfirmation = true
        } else {
            Task { await model.importFromGmail() }
        }
    }
}

/// Hosts one throwaway `WKWebView` (08 §4.10: no cid handler, no message handler, no user script, block-all rule
/// list, JavaScript off, non-persistent data store). It lives exactly as long as this representable, so the
/// pooled instance behind the sheet keeps its document and scroll position.
private struct SignaturePreviewView: UIViewRepresentable {
    let host: WebViewHost
    let document: String
    let interfaceStyle: UIUserInterfaceStyle
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> WKWebView {
        let webView = host.makeThrowawayWebView()
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.appliedStyle != interfaceStyle {
            webView.overrideUserInterfaceStyle = interfaceStyle
            context.coordinator.appliedStyle = interfaceStyle
        }
        webView.backgroundColor = backgroundColor
        webView.underPageBackgroundColor = backgroundColor
        guard context.coordinator.appliedDocument != document else { return }
        webView.loadHTMLString(document, baseURL: nil)
        context.coordinator.appliedDocument = document
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // SwiftUI delivers this on the main thread; the requirement itself is not isolated (see `MailWebView`).
        MainActor.assumeIsolated {
            webView.stopLoading()
            // Drop the DOM before the instance is released.
            webView.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedDocument = ""
        var appliedStyle: UIUserInterfaceStyle = .unspecified
    }
}
