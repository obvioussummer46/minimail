import MailCore
import QuickLook
import SwiftUI
import UIKit
import WebKit

/// The pushed thread screen (architecture §8.1, §8.4). Pure presentation: every decision lives in `ThreadModel`.
struct ThreadScreen: View {
    private let threadId: String
    @State private var model: ThreadModel?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @ThemeTokensReader private var themeTokens

    init(threadId: String) { self.threadId = threadId }

    var body: some View {
        chrome
            .onAppear { appear() }
            .task { await load() }
            .task { await observeContentSize() }
            .onDisappear { model?.detachWeb() }
            .onChange(of: colorScheme) { _, scheme in model?.systemSchemeChanged(scheme) }
            .onChange(of: env.theme.choice) { _, _ in model?.systemSchemeChanged(colorScheme) }
            .onChange(of: model?.shouldDismiss ?? false) { _, gone in if gone { dismiss() } }
            .sheet(item: composeBinding) { input in ComposeScreen(input: input) }
            .quickLookPreview(previewBinding)
            .sensoryFeedback(SensoryFeedback.impact(weight: .light), trigger: model?.lastActionId ?? 0)
    }

    /// The document plus the navigation chrome. Split from `body` because one chain of the content, the
    /// three navigation modifiers, the toolbar and the ten lifecycle modifiers exceeds the type checker's
    /// budget (it gives up with "unable to type-check this expression in reasonable time").
    private var chrome: some View {
        content
            .navigationTitle(model?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .bottomBar)
            .toolbar { toolbar }
    }

    @ViewBuilder private var content: some View {
        if let model {
            ThreadContentView(model: model, tokens: themeTokens)
        } else {
            themeTokens.background.ignoresSafeArea()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            ThreadActionButton(action: .replyAll, isUnread: isUnread) { model?.replyAll() }
                .disabled(!canCompose)
            Spacer()
            ThreadActionButton(action: .forward, isUnread: isUnread) { model?.forward() }
                .disabled(!canCompose)
            Spacer()
            ThreadActionButton(action: .archive, isUnread: isUnread) { archive() }
            Spacer()
            ThreadActionButton(action: .toggleRead, isUnread: isUnread) { toggleRead() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model?.loading == true {
                ProgressView()
                    .accessibilityLabel("Loading thread")
                    .accessibilityIdentifier("thread.loading")
            }
        }
    }

    private func appear() {
        ensureModel()
        model?.systemSchemeChanged(colorScheme)
        model?.attachWeb(openURL: { openURL($0) })
    }

    private func load() async {
        ensureModel()
        await model?.appeared()
    }

    private func observeContentSize() async {
        for await _ in ThreadScreen.contentSizeChangeStream() { model?.contentSizeChanged() }
    }

    /// Idempotent: `.onAppear` and `.task` both call it and their order is not guaranteed.
    private func ensureModel() {
        if model == nil { model = ThreadModel(env: env, threadId: threadId) }
    }

    private var isUnread: Bool { model?.isUnread ?? false }

    private var canCompose: Bool { model?.canCompose ?? false }

    private func archive() {
        guard let model else { return }
        Task { await model.archive() }
    }

    private func toggleRead() {
        guard let model else { return }
        Task { await model.toggleRead() }
    }

    /// `@Bindable` cannot be declared for a nested object inside `body`, so both presentations use plain bindings.
    private var composeBinding: Binding<ComposeInput?> {
        Binding(get: { model?.composeInput }, set: { model?.composeInput = $0 })
    }

    private var previewBinding: Binding<URL?> {
        Binding(get: { model?.attachments.previewURL }, set: { model?.attachments.previewURL = $0 })
    }

    /// Yields once per `UIContentSizeCategory.didChangeNotification` (architecture §14 #26).
    nonisolated static func contentSizeChangeStream() -> AsyncStream<Void> {
        AsyncStream<Void> { continuation in
            let box = ThreadObserverTokenBox([
                NotificationCenter.default.addObserver(
                    forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
                ) { _ in
                    continuation.yield(())
                }
            ])
            continuation.onTermination = { _ in
                box.tokens.forEach { NotificationCenter.default.removeObserver($0) }
            }
        }
    }
}

/// One bottom-bar button. Its own type so the toolbar group stays inside the type checker's budget:
/// four inline `Button { } label: { }` expressions with optional chaining time out (spec §6.2 builds them
/// inline; that is not compilable here).
private struct ThreadActionButton: View {
    let action: ThreadAction
    let isUnread: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.symbol(isUnread: isUnread))
        }
        .accessibilityLabel(action.title(isUnread: isUnread))
        .accessibilityIdentifier(action.rawValue)
    }
}

/// Carries NotificationCenter observer tokens (not `Sendable`) into the `@Sendable` `onTermination` closure.
nonisolated private final class ThreadObserverTokenBox: @unchecked Sendable {
    let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
}

/// The web view plus its overlays; split out so `@Bindable var model` is available.
private struct ThreadContentView: View {
    @Bindable var model: ThreadModel
    let tokens: ThemeTokens
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            MailWebView(
                host: env.webHost,
                document: model.document,
                revision: model.revision,
                interfaceStyle: env.theme.interfaceStyle,
                imagesAllowed: model.documentImagesAllowed,
                backgroundColor: UIColor(tokens.background)
            )
            .accessibilityIdentifier("thread.web")
            .ignoresSafeArea(edges: .bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0) { noticeRow }
        .overlay(alignment: .center) { downloadingOverlay }
    }

    /// A failed attachment is the more recent, more explicit action, so it wins over a thread-load error.
    @ViewBuilder private var noticeRow: some View {
        if case .failed(let text) = model.attachments.state {
            ThreadNotice(
                text: text, actionTitle: nil, action: nil, tokens: tokens,
                dismiss: { model.attachments.dismissError() })
        } else if let text = model.errorText ?? model.observationError {
            ThreadNotice(
                text: text, actionTitle: "Retry", action: { Task { await model.retryLoad() } },
                tokens: tokens, dismiss: nil)
        }
    }

    /// Non-modal: the document stays scrollable, and QuickLook opens by itself once `previewURL` is set.
    @ViewBuilder private var downloadingOverlay: some View {
        if case .downloading = model.attachments.state {
            VStack(spacing: 8) {
                ProgressView()
                Text("Downloading…")
                    .font(.footnote)
                    .foregroundStyle(tokens.secondaryText)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("thread.downloading")
        }
    }
}

/// One-line, non-blocking notice above the document (load failure, attachment failure). Never an alert.
private struct ThreadNotice: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?
    let tokens: ThemeTokens
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(tokens.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.footnote.weight(.semibold))
            }
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(tokens.background)
        .accessibilityIdentifier("thread.notice")
    }
}
