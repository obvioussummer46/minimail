import MailCore
import SwiftUI

/// One message as the plain-text reading mode sees it. Built by `ThreadModel.plainMessages`.
nonisolated struct ThreadPlainMessage: Identifiable, Equatable, Sendable {
    var id: String
    var fromName: String
    var fromAddr: String
    var toLine: String
    var ccLine: String?
    var dateLabel: String
    var snippet: String
    var isUnread: Bool
    var expanded: Bool
    /// 0 loading · 1 loaded · 2 failed — the same states `ThreadDocument` branches on.
    var bodyState: Int
    /// nil while collapsed or until the body arrives.
    var body: PlainTextBody?
    var attachments: [ThreadDocumentAttachment]

    var displayName: String { fromName.isEmpty ? fromAddr : fromName }
}

/// The thread as native text: no `WKWebView`, so no document load, no rule lists and no remote content.
struct ThreadPlainView: View {
    @Bindable var model: ThreadModel
    let tokens: ThemeTokens

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.plainMessages) { message in
                    ThreadPlainMessageView(message: message, model: model, tokens: tokens)
                    Divider().overlay(tokens.separator)
                }
            }
            .padding(.bottom, 24)
        }
        .background(tokens.background)
        .textSelection(.enabled)
        .accessibilityIdentifier("thread.plain")
    }

    /// Only `http`, `https`, `mailto` and `tel` become tappable — the same set `LinkPolicy` opens from the
    /// rendered document, so a `javascript:` or custom-scheme href cannot become a tap target here either.
    static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Body runs as one `AttributedString`, so links stay tappable and inspectable (long-press shows the URL)
    /// and Dynamic Type applies without the web view having to emulate it.
    static func attributed(_ body: PlainTextBody) -> AttributedString {
        var out = AttributedString()
        for run in body.runs {
            switch run {
            case .text(let value):
                out += AttributedString(value)
            case .link(let text, let url):
                var piece = AttributedString(text)
                if let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                    openableSchemes.contains(scheme)
                {
                    piece.link = parsed
                    piece.underlineStyle = .single
                }
                out += piece
            }
        }
        return out
    }
}

private struct ThreadPlainMessageView: View {
    let message: ThreadPlainMessage
    @Bindable var model: ThreadModel
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if message.expanded {
                expandedBody
                if !message.attachments.isEmpty { attachmentRows }
                showOriginalButton
            } else {
                Text(message.snippet)
                    .font(.footnote)
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { if !message.expanded { model.toggle(messageId: message.id) } }
        .accessibilityIdentifier("thread.plain.message.\(message.id)")
    }

    private var header: some View {
        Button {
            model.toggle(messageId: message.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.displayName)
                        .font(.headline)
                        .fontWeight(message.isUnread ? .semibold : .regular)
                        .foregroundStyle(tokens.text)
                    Spacer(minLength: 8)
                    Text(message.dateLabel)
                        .font(.subheadline)
                        .foregroundStyle(tokens.secondaryText)
                }
                if message.expanded {
                    Text("To: " + message.toLine)
                        .font(.caption)
                        .foregroundStyle(tokens.secondaryText)
                    if let cc = message.ccLine {
                        Text("Cc: " + cc)
                            .font(.caption)
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread.plain.header.\(message.id)")
    }

    @ViewBuilder private var expandedBody: some View {
        if let body = message.body, !body.isEmpty {
            Text(ThreadPlainView.attributed(body))
                .font(.body)
                .foregroundStyle(tokens.text)
                .tint(tokens.link)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.bodyState == 2 {
            HStack(spacing: 10) {
                Text("Couldn't load this message.")
                    .font(.footnote)
                    .foregroundStyle(tokens.secondaryText)
                Button("Retry") { model.retry(messageId: message.id) }
                    .font(.footnote)
                    .accessibilityIdentifier("thread.plain.retry.\(message.id)")
            }
        } else if message.bodyState == 0 || message.body == nil {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…")
                    .font(.footnote)
                    .foregroundStyle(tokens.secondaryText)
            }
        } else {
            Text("This message has no text.")
                .font(.footnote)
                .foregroundStyle(tokens.secondaryText)
        }
    }

    private var attachmentRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.attachments, id: \.partId) { attachment in
                Button {
                    model.openAttachment(messageId: message.id, partId: attachment.partId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text(attachment.filename).lineLimit(1)
                        Text(attachment.sizeLabel).foregroundStyle(tokens.secondaryText)
                    }
                    .font(.footnote)
                }
                .accessibilityIdentifier("thread.plain.attachment.\(attachment.partId)")
            }
        }
    }

    private var showOriginalButton: some View {
        Button("Show Original") { model.showOriginal() }
            .font(.footnote)
            .accessibilityIdentifier("thread.plain.showOriginal.\(message.id)")
    }
}
