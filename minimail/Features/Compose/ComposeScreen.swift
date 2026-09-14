import MailCore
import SwiftUI

/// Which field owns the keyboard when the sheet appears (§6.7).
private enum ComposeField: Hashable { case to, cc, subject, body }

/// Reply-all / forward sheet (architecture §8.1, §8.5). Pure presentation: every decision lives in `ComposeModel`.
///
/// `body` is deliberately shallow and every section is its own view: module 10 proved that one `Form` plus a
/// toolbar plus the lifecycle modifiers in a single expression exceeds the type checker's budget.
struct ComposeScreen: View {
    private let input: ComposeInput
    @State private var model: ComposeModel?
    @State private var showsDiscard = false
    @FocusState private var focus: ComposeField?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @ThemeTokensReader private var themeTokens

    init(input: ComposeInput) { self.input = input }

    var body: some View {
        NavigationStack { chrome }
            .onAppear { ensureModel() }
            .task { await load() }
            .onDisappear { model?.stop() }
            .interactiveDismissDisabled(model?.hasContent ?? false)
    }

    private var chrome: some View {
        content
            .background(themeTokens.groupedBackground)
            .navigationTitle(model?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .confirmationDialog("Discard this draft?", isPresented: $showsDiscard, titleVisibility: .visible) {
                Button("Discard Draft", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .sensoryFeedback(SensoryFeedback.success, trigger: model?.sendFeedbackId ?? 0)
    }

    @ViewBuilder private var content: some View {
        if let model {
            switch model.phase {
            case .loading:
                loadingView
            case .unavailable(let text):
                ComposeUnavailableView(text: text)
            case .ready:
                ComposeForm(model: model, focus: $focus, tokens: themeTokens)
            }
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("compose.loading")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { cancel() }
                .accessibilityIdentifier("compose.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: performSend) { Image(systemName: "paperplane.fill") }
                .disabled(!(model?.canSend ?? false))
                .accessibilityLabel("Send")
                .accessibilityIdentifier("compose.send")
        }
    }

    /// Idempotent: `.onAppear` and `.task` both call it and their order is not guaranteed.
    private func ensureModel() {
        if model == nil { model = ComposeModel(env: env, input: input) }
    }

    private func load() async {
        ensureModel()
        await model?.makeDraft()
        focus = ComposeScreen.initialFocus(for: model)
    }

    private func cancel() {
        if model?.hasContent == true { showsDiscard = true } else { dismiss() }
    }

    private func performSend() {
        if model?.send() == true { dismiss() }
    }

    /// A forward has no recipients yet, so it starts in To; everything else is prefilled (§6.7).
    /// `nil` when the draft never became editable.
    private static func initialFocus(for model: ComposeModel?) -> ComposeField? {
        guard let model, model.phase == .ready else { return nil }
        return model.mode == .forward ? .to : .body
    }
}

/// The editable draft. Split out so `@Bindable var model` is available and so each section type-checks alone.
private struct ComposeForm: View {
    @Bindable var model: ComposeModel
    var focus: FocusState<ComposeField?>.Binding
    let tokens: ThemeTokens

    var body: some View {
        Form {
            ComposeFieldsSection(model: model, focus: focus, tokens: tokens)
            Section {
                TextEditor(text: $model.body)
                    .frame(minHeight: 200)
                    .focused(focus, equals: .body)
                    .accessibilityIdentifier("compose.body")
                    .accessibilityLabel("Message body")
            }
            if !model.attachments.isEmpty {
                ComposeAttachmentsSection(model: model, tokens: tokens)
            }
            ComposeQuoteSection(model: model, tokens: tokens)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// To / Cc / Subject plus the validation footer.
private struct ComposeFieldsSection: View {
    @Bindable var model: ComposeModel
    var focus: FocusState<ComposeField?>.Binding
    let tokens: ThemeTokens

    var body: some View {
        Section {
            TextField("To", text: $model.toText, axis: .vertical)
                .modifier(AddressFieldStyle())
                .focused(focus, equals: .to)
                .accessibilityIdentifier("compose.to")
                .accessibilityLabel("To")
            TextField("Cc", text: $model.ccText, axis: .vertical)
                .modifier(AddressFieldStyle())
                .focused(focus, equals: .cc)
                .accessibilityIdentifier("compose.cc")
                .accessibilityLabel("Cc")
            TextField("Subject", text: $model.subject)
                .focused(focus, equals: .subject)
                .accessibilityIdentifier("compose.subject")
                .accessibilityLabel("Subject")
        } footer: {
            footer
        }
    }

    /// `ThemeTokens` has no error colour and adding one belongs to module 01; the disabled Send button is the
    /// primary affordance (§10 A8).
    @ViewBuilder private var footer: some View {
        if let validation = model.validation {
            Text(validation)
                .font(.footnote)
                .foregroundStyle(tokens.secondaryText)
                .accessibilityIdentifier("compose.validation")
        }
    }
}

/// The four keyboard modifiers shared by To and Cc, as one modifier so each `TextField` stays a short expression.
private struct AddressFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

/// Forward attachments with their toggles and the budget footer.
private struct ComposeAttachmentsSection: View {
    let model: ComposeModel
    let tokens: ThemeTokens

    var body: some View {
        // `Section(_ titleKey:content:footer:)` does not exist — a titled section with a footer has to spell the
        // header out (spec §6.4 writes the non-existent form).
        Section {
            ForEach(model.attachments) { item in
                ComposeAttachmentRow(item: item, tokens: tokens) { included in
                    model.setAttachment(partId: item.id, included: included)
                }
            }
        } header: {
            Text("Attachments")
        } footer: {
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        if let text = model.attachmentFooter {
            Text(text)
                .font(.footnote)
                .foregroundStyle(tokens.secondaryText)
                .accessibilityIdentifier("compose.attachmentFooter")
        }
    }
}

/// One attachment toggle. Its own type so the `ForEach` body stays inside the type checker's budget.
private struct ComposeAttachmentRow: View {
    let item: ComposeAttachmentItem
    let tokens: ThemeTokens
    let setIncluded: (Bool) -> Void

    private var filename: String { item.ref.filename.isEmpty ? "Attachment" : item.ref.filename }

    private var label: String {
        "\(filename), \(item.sizeLabel)\(item.isInline ? ", inline image" : "")"
    }

    var body: some View {
        Toggle(isOn: Binding(get: { item.included }, set: { setIncluded($0) })) {
            HStack(spacing: 8) {
                Image(systemName: item.isInline ? "photo" : "paperclip")
                    .foregroundStyle(tokens.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(tokens.text)
                    Text(item.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(tokens.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("compose.attachment.\(item.id)")
        .accessibilityLabel(label)
    }
}

/// Read-only quoted original — `Text`, never a web view (architecture D12). The full quote is always sent, no
/// matter how many lines the preview shows.
private struct ComposeQuoteSection: View {
    let model: ComposeModel
    let tokens: ThemeTokens

    var body: some View {
        Section("Quoted") {
            if model.quoteReady {
                Text(model.quotePreview.isEmpty ? "(No quoted text)" : model.quotePreview)
                    .font(.footnote)
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("compose.quote")
                    .accessibilityLabel("Quoted original")
            } else {
                loading
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading original…")
                .font(.footnote)
                .foregroundStyle(tokens.secondaryText)
        }
        .accessibilityIdentifier("compose.quoteLoading")
    }
}

/// `phase == .unavailable(text)` state (§6.4).
private struct ComposeUnavailableView: View {
    let text: String

    var body: some View {
        ContentUnavailableView(
            "Message unavailable", systemImage: "exclamationmark.triangle", description: Text(text)
        )
        .accessibilityIdentifier("compose.unavailable")
    }
}
