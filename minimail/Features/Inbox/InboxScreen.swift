import GRDB
import MailCore
import SwiftUI

/// Root screen of the signed-in app (architecture §8.1).
struct InboxScreen: View {
    private let initialScope: InboxScope
    @State private var model: InboxModel?
    @State private var path: [ThreadRoute] = []
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @ThemeTokensReader private var themeTokens

    init(scope: InboxScope) { self.initialScope = scope }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    InboxListView(model: model)
                } else {
                    themeTokens.background.ignoresSafeArea()
                }
            }
            .navigationDestination(for: ThreadRoute.self) { ThreadScreen(threadId: $0.threadId) }
        }
        .onAppear { if model == nil { model = InboxModel(env: env, scope: initialScope) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model?.dayChanged() } }
        .onChange(of: env.auth.state) { _, state in model?.authStateChanged(state) }
        .task {
            for await _ in InboxScreen.dayChangeStream() { model?.dayChanged() }
        }
    }

    /// Yields once per `NSCalendarDayChanged` / `NSSystemTimeZoneDidChange` (§4.9).
    nonisolated static func dayChangeStream() -> AsyncStream<Void> {
        AsyncStream<Void> { continuation in
            let names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemTimeZoneDidChange]
            let box = ObserverTokenBox(
                names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                        continuation.yield(())
                    }
                })
            continuation.onTermination = { _ in
                box.tokens.forEach { NotificationCenter.default.removeObserver($0) }
            }
        }
    }
}

/// Carries NotificationCenter observer tokens (not `Sendable`) into the `@Sendable` `onTermination` closure.
nonisolated private final class ObserverTokenBox: @unchecked Sendable {
    let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
}

/// Everything that needs `@Bindable var model`.
private struct InboxListView: View {
    @Bindable var model: InboxModel
    @Environment(AppEnvironment.self) private var env
    @ThemeTokensReader private var themeTokens

    var body: some View {
        List {
            if let banner = model.banner {
                Section { bannerRow(banner) }
            }
            if !model.failedSends.isEmpty {
                Section("Outbox") {
                    ForEach(model.failedSends) { rec in outboxRow(rec) }
                }
            }
            if let empty = model.emptyState {
                Section { InboxEmptyView(state: empty) }
            } else {
                Section {
                    ForEach(model.rows) { row in threadRow(row) }
                    if model.isLoadingOlder { loadingOlderFooter }
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("inbox.list")
        .refreshable { await model.refresh() }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarTitleMenu {
            Button {
                model.setScope(.inbox)
            } label: {
                Label("Inbox", systemImage: "tray")
            }
            Button {
                model.setScope(.today)
            } label: {
                Label("Today", systemImage: "sun.max")
            }
            Divider()
            Button {
                model.activeSheet = .labels
            } label: {
                Label("Labels…", systemImage: "tag")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Always-visible mailbox switcher: the title menu's affordance only appears once the large title
                // collapses on scroll, so an empty Today (nothing to scroll) would otherwise trap the user.
                // Its label is the app mark (`MailboxDots`); the active scope is the accessibility value.
                Menu {
                    Button {
                        model.setScope(.inbox)
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    Button {
                        model.setScope(.today)
                    } label: {
                        Label("Today", systemImage: "sun.max")
                    }
                    Divider()
                    Button {
                        model.activeSheet = .labels
                    } label: {
                        Label("Labels…", systemImage: "tag")
                    }
                } label: {
                    MailboxDots()
                }
                .accessibilityLabel("Mailboxes")
                .accessibilityValue(mailboxValue)
                .accessibilityIdentifier("inbox.mailboxMenu")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.toggleUnreadOnly()
                } label: {
                    Image(
                        systemName: model.unreadOnly
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Unread only")
                .accessibilityValue(unreadToggleValue)
                .accessibilityIdentifier("inbox.unreadToggle")

                Button {
                    model.activeSheet = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("inbox.settings")
            }
        }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .labels:
                LabelsScreen(onSelect: { scope in
                    model.setScope(scope)
                    model.activeSheet = nil
                })
            case .settings:
                SettingsScreen()
            case .compose(let input):
                ComposeScreen(input: input)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.lastActionId)
        .sensoryFeedback(.selection, trigger: model.filterChangeId)
        .background(themeTokens.background)
        .onAppear { env.markFirstListPaint() }
    }

    /// Spoken after "Mailboxes": the dots carry the active scope visually, so VoiceOver has to say it.
    private var mailboxValue: String {
        switch model.scope {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .label: return "Labels"
        }
    }

    private var unreadToggleValue: String {
        var value = model.unreadOnly ? "On" : "Off"
        if model.scope == .inbox { value += ", \(model.inboxUnreadCount) unread" }
        return value
    }

    @ViewBuilder private func bannerRow(_ banner: InboxBanner) -> some View {
        switch banner {
        case .reauth:
            StatusBanner(
                kind: .reauth, isBusy: env.auth.isSigningIn, detailOverride: env.auth.lastError,
                action: { Task { try? await env.auth.signIn() } },
                dismiss: { model.dismissReauthBanner() })
        case .offline:
            StatusBanner(kind: .offline, action: {})
        case .error(let text):
            StatusBanner(kind: .error(text), action: { Task { await model.refresh() } })
        }
    }

    @ViewBuilder private func threadRow(_ row: ThreadRow) -> some View {
        ZStack {
            NavigationLink(value: ThreadRoute(threadId: row.id)) { EmptyView() }
                .opacity(0)
                .accessibilityHidden(true)
            ThreadRowView(row: row, previewLines: env.settings.settings.previewLineCount)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.archiveAndMarkRead(threadId: row.id, isUnread: row.isUnread)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(themeTokens.swipeArchive)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                model.toggleRead(threadId: row.id, isUnread: row.isUnread)
            } label: {
                Label(
                    row.isUnread ? "Read" : "Unread",
                    systemImage: row.isUnread ? "envelope.open" : "envelope.badge")
            }
            .tint(themeTokens.swipeRead)
        }
        .onAppear { model.rowAppeared(row.id) }
        .accessibilityIdentifier("inbox.row.\(row.id)")
    }

    @ViewBuilder private func outboxRow(_ rec: OutboxRecord) -> some View {
        Button {
            model.openFailedSend(rec)
        } label: {
            FailedSendRow(record: rec)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.discardSend(rec.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                model.retrySend(rec.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(themeTokens.accent)
        }
        .accessibilityIdentifier("inbox.outbox.row.\(rec.id)")
    }

    private var loadingOlderFooter: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("inbox.loadingOlder")
            .accessibilityLabel("Loading older mail")
    }
}

/// One list row rendering an `InboxEmptyState`.
private struct InboxEmptyView: View {
    let state: InboxEmptyState

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 320)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("inbox.empty")
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .initialSync:
            ProgressView("Loading your inbox…").progressViewStyle(.circular)
        case .noMail:
            ContentUnavailableView(
                "No Mail", systemImage: "tray", description: Text("New mail you receive will appear here."))
        case .nothingToday:
            ContentUnavailableView(
                "Nothing today", systemImage: "sun.max", description: Text("No mail received today."))
        case .allCaughtUp:
            ContentUnavailableView(
                "All caught up", systemImage: "checkmark.circle", description: Text("No unread mail here."))
        case .noMessages:
            ContentUnavailableView(
                "No messages", systemImage: "tag", description: Text("No cached mail with this label."))
        }
    }
}
