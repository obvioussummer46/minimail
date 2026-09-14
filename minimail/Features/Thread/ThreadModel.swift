import Foundation
import GRDB
import MailCore
import MailHTML
import Observation
import SwiftUI
import UIKit

/// The four bottom-toolbar actions (architecture §8.3). Raw values double as accessibility identifiers.
nonisolated enum ThreadAction: String, CaseIterable, Sendable {
    case replyAll = "thread.replyAll"
    case forward = "thread.forward"
    case archive = "thread.archive"
    case toggleRead = "thread.toggleRead"

    /// SF Symbol (spec §5.3). `isUnread` only matters for `.toggleRead`.
    func symbol(isUnread: Bool) -> String {
        switch self {
        case .replyAll: return "arrowshape.turn.up.left.2"
        case .forward: return "arrowshape.turn.up.right"
        case .archive: return "archivebox"
        case .toggleRead: return isUnread ? "envelope.open" : "envelope.badge"
        }
    }

    /// Accessibility label / VoiceOver text (spec §5.2).
    func title(isUnread: Bool) -> String {
        switch self {
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .archive: return "Archive"
        case .toggleRead: return isUnread ? "Mark as Read" : "Mark as Unread"
        }
    }
}

/// Main-actor model of one thread screen (architecture §8.2). One instance per pushed screen; `stop()` cancels the
/// observation when the screen is popped.
@Observable final class ThreadModel {

    /// Owner of the attachment download and the QuickLook URL.
    @ObservationIgnored let attachments: AttachmentOpener

    // MARK: identity

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored let threadId: String

    // MARK: observed state

    /// `Queries.threadDetail`, through a `.immediate` observation; nil once the thread row is gone.
    private(set) var detail: ThreadDetail?
    /// Message ids rendered expanded: every unread message plus the newest one (architecture §8.2).
    private(set) var expanded: Set<String> = []
    /// Ids the user tapped "Load images" for, in this screen only (architecture §9.4).
    private(set) var imagesAllowedIds: Set<String> = []
    /// The rendered document handed to `MailWebView`.
    private(set) var document: String = ""
    /// Increments on every document change and on every forced reload.
    private(set) var revision: Int = 0
    /// True while `SyncEngine.ensureThreadLoaded` runs.
    private(set) var loading = false
    /// Thread-level load failure text (§5.2); nil when the last attempt succeeded or none ran.
    private(set) var errorText: String?
    /// GRDB error text of a failed observation.
    private(set) var observationError: String?
    /// Set when the thread row disappears; the screen calls `dismiss()`.
    private(set) var shouldDismiss = false
    /// Haptic trigger for `.sensoryFeedback`.
    private(set) var lastActionId = 0
    /// True once mark-read-on-open ran for this screen.
    private(set) var didMarkRead = false
    /// Bound by the screen with `.sheet(item:)`; 11's `ComposeScreen(input:)` consumes it.
    var composeInput: ComposeInput?

    // MARK: derived

    var title: String {
        let stripped = SubjectPrefix.stripForDisplay(detail?.thread.subject ?? "")
        return stripped.isEmpty ? "(No subject)" : stripped
    }

    /// Whole-thread read state (architecture decision 13).
    var isUnread: Bool { (detail?.thread.unreadCount ?? 0) > 0 }

    /// Newest visible message: the compose origin, and the test for "is there anything to reply to".
    var newestMessageId: String? { detail?.messages.last?.id }

    var canCompose: Bool { newestMessageId != nil }

    /// Document-level image policy; drives both the CSP and the rule-list swap.
    var documentImagesAllowed: Bool {
        env.settings.settings.loadRemoteImages || !imagesAllowedIds.isEmpty
    }

    // MARK: private state

    /// Everything `ThreadDocument.render` consumes; equality decides whether a reload is needed.
    private struct RenderKey: Equatable {
        var subject: String
        var messages: [ThreadDocumentMessage]
        var light: ThemeCSSTokens
        var dark: ThemeCSSTokens
        var forcedScheme: String?
        var imagesAllowed: Bool
    }

    /// The model that currently owns `WebBridge.onMessage` / `LinkPolicy`. Weak, so a popped screen cannot
    /// keep itself alive.
    @ObservationIgnored private static weak var webOwner: ThreadModel?

    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var renderKey: RenderKey?
    @ObservationIgnored private var knownMessageIds: Set<String> = []
    @ObservationIgnored private var didAppear = false
    @ObservationIgnored private var openURLAction: ((URL) -> Void)?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var labeler: RowDateLabeler
    @ObservationIgnored private let fullDate: DateFormatter
    @ObservationIgnored private var lightTokens: ThemeCSSTokens
    @ObservationIgnored private var darkTokens: ThemeCSSTokens
    @ObservationIgnored private var forcedScheme: String?

    // MARK: init

    /// Starts the observation synchronously, seeds `expanded`, builds the first document and sets `revision = 1`
    /// before returning, so the first `MailWebView` update already carries the cached thread (architecture §12.1).
    /// No network, no `Task`, no sync call.
    init(
        env: AppEnvironment, threadId: String,
        clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current, locale: Locale = .current
    ) {
        self.env = env
        self.threadId = threadId
        self.clock = clock
        self.timeZone = timeZone
        self.locale = locale
        self.labeler = RowDateLabeler(now: clock(), timeZone: timeZone, locale: locale)
        self.fullDate = ThreadModel.makeFullDateFormatter(timeZone: timeZone, locale: locale)
        self.attachments = AttachmentOpener(
            gmail: env.gmail, db: env.db,
            directory: AppEnvironment.attachmentsCacheDirectory(testing: env.isTesting))

        let theme = env.theme.resolved(for: env.theme.preferredColorScheme ?? .light)
        self.lightTokens = theme.cssTokens(for: .light)
        self.darkTokens = theme.cssTokens(for: .dark)
        self.forcedScheme = env.theme.forcedDocumentTheme

        startObservation()
    }

    // MARK: observation

    private func startObservation() {
        cancellable?.cancel()
        cancellable =
            ValueObservation
            .trackingConstantRegion { [threadId] db in try Queries.threadDetail(db, threadId: threadId) }
            .removeDuplicates()
            .start(
                in: env.db, scheduling: .immediate,
                onError: { [weak self] error in MainActor.assumeIsolated { self?.observationFailed(error) } },
                onChange: { [weak self] detail in MainActor.assumeIsolated { self?.apply(detail) } })
    }

    private func apply(_ detail: ThreadDetail?) {
        guard let detail else {
            self.detail = nil
            shouldDismiss = true
            Log.ui.debug("thread.gone \(self.threadId, privacy: .public)")
            return
        }
        self.detail = detail
        mergeExpanded(for: detail)
        rebuild(force: false)
    }

    private func mergeExpanded(for detail: ThreadDetail) {
        let ids = Set(detail.messages.map(\.id))
        if knownMessageIds.isEmpty {
            expanded = ThreadModel.initialExpanded(detail)
        } else {
            let newest = detail.messages.last?.id
            for message in detail.messages where !knownMessageIds.contains(message.id) {
                // A reply that arrived while the screen is open.
                if message.isUnread || message.id == newest { expanded.insert(message.id) }
            }
        }
        expanded.formIntersection(ids)
        knownMessageIds = ids
    }

    private func observationFailed(_ error: any Error) {
        observationError = "Couldn't read the local database."
        Log.db.error("thread.observation.failed \(String(describing: error), privacy: .public)")
    }

    // MARK: document

    private func makeRenderKey() -> RenderKey {
        RenderKey(
            subject: SubjectPrefix.stripForDisplay(detail?.thread.subject ?? ""),
            messages: detail.map {
                ThreadModel.documentMessages(
                    detail: $0, expanded: expanded, imagesAllowedIds: imagesAllowedIds,
                    loadRemoteImages: env.settings.settings.loadRemoteImages,
                    labeler: labeler, fullDate: fullDate)
            } ?? [],
            light: lightTokens, dark: darkTokens, forcedScheme: forcedScheme,
            imagesAllowed: documentImagesAllowed)
    }

    /// Rebuilds only when the projection actually changed, so an unrelated observation tick never reloads the
    /// document (architecture §8.4). `force` is for Dynamic Type and for expanding a stripped section.
    private func rebuild(force: Bool) {
        let key = makeRenderKey()
        guard force || key != renderKey else { return }
        renderKey = key
        document = ThreadDocument.render(
            subject: key.subject, messages: key.messages, light: key.light, dark: key.dark,
            forcedScheme: key.forcedScheme, imagesAllowed: key.imagesAllowed)
        revision &+= 1
        Log.ui.debug(
            "thread.document.rebuilt \(self.threadId, privacy: .public) rev=\(self.revision) "
                + "bytes=\(self.document.utf8.count)")
    }


    // MARK: lifecycle

    /// Called once from `ThreadScreen.task`. Marks the thread read when the setting allows it (one local
    /// transaction, never waiting for bodies), then awaits `ensureThreadLoaded`. Idempotent.
    func appeared() async {
        guard !didAppear else { return }
        didAppear = true
        if env.settings.settings.markReadOnOpen, (detail?.thread.unreadCount ?? 0) > 0 {
            didMarkRead = true
            await env.actions.markRead(threadId: threadId)
        }
        await loadThread()
    }

    private func loadThread() async {
        guard !loading else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            try await env.sync.ensureThreadLoaded(threadId: threadId)
        } catch is CancellationError {
            // The screen is gone.
        } catch {
            errorText = ThreadModel.loadErrorText(for: error)
            Log.ui.error(
                "thread.load.failed \(self.threadId, privacy: .public) "
                    + "\(String(describing: error), privacy: .public)")
        }
    }

    /// Notice row "Retry": clears the errors, restarts a cancelled observation and re-runs the load.
    func retryLoad() async {
        if observationError != nil {
            observationError = nil
            startObservation()
        }
        await loadThread()
    }

    // MARK: web plumbing (08)

    /// Installs this model as the owner of the one shared bridge and link policy.
    func attachWeb(openURL: @escaping (URL) -> Void) {
        ThreadModel.webOwner = self
        openURLAction = openURL
        env.webBridge.onMessage = { [weak self] message in self?.handle(message) }
        env.webHost.linkPolicy.onAction = { [weak self] message in self?.handle(message) }
        env.webHost.linkPolicy.openURL = { [weak self] url in self?.handle(.link(url)) }
    }

    /// Reverse of `attachWeb`, but only while this model is still the owner: SwiftUI can run the new
    /// screen's `onAppear` before the old screen's `onDisappear`.
    func detachWeb() {
        guard ThreadModel.webOwner === self else { return }
        ThreadModel.webOwner = nil
        openURLAction = nil
        env.webBridge.onMessage = { _ in }
        env.webHost.linkPolicy.onAction = nil
        env.webHost.linkPolicy.openURL = { _ in }
        env.webHost.didLeaveThread()
    }

    /// Single entry point for every in-document interaction, for both the script bridge and the
    /// `minimail-action:` link fallback.
    func handle(_ message: WebMessage) {
        switch message {
        case .toggle(let id): toggle(messageId: id)
        case .loadImages(let id): loadImages(messageId: id)
        case .attachment(let messageId, let partId):
            openAttachment(messageId: messageId, partId: partId)
        case .retry(let id): retry(messageId: id)
        case .link(let url): openURLAction?(url)
        }
    }

    // MARK: in-document effects

    /// Expand/collapse through `evaluateJavaScript` when the loaded document is current; otherwise a rebuild.
    func toggle(messageId: String) {
        guard var key = renderKey, let index = key.messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        let willExpand = !expanded.contains(messageId)
        if willExpand {
            expanded.insert(messageId)
        } else {
            expanded.remove(messageId)
        }
        // The body was replaced by "Tap to load this message" under the 6 MB document cap.
        if willExpand, ThreadDocument.strippedIds(messages: key.messages).contains(messageId) {
            rebuild(force: true)
            return
        }
        guard env.webHost.loadedRevision == revision else {
            rebuild(force: true)
            return
        }
        key.messages[index].expanded = willExpand
        renderKey = key  // keep the key in sync so the next observation tick does not reload
        evaluate(
            ThreadDocument.toggleScript(messageId: messageId),
            onFalse: { [weak self] in self?.rebuild(force: true) })
    }

    /// "Load images" for one message. The scope is this screen only — no per-sender memory in stage 1.
    func loadImages(messageId: String) {
        guard imagesAllowedIds.insert(messageId).inserted else { return }
        lastActionId += 1
        rebuild(force: false)
        Log.ui.debug("thread.images.loaded \(self.threadId, privacy: .public)")
    }

    /// "Retry" inside an unavailable message: the only write this module performs directly.
    func retry(messageId: String) {
        let db = env.db
        let threadId = self.threadId
        Task { [weak self] in
            do {
                try await db.write { db in
                    try BodyRepository.resetUnavailable(db, messageId: messageId)
                    try ThreadRepository.recomputeAggregates(
                        db, threadIds: [threadId],
                        selfAddresses: try SyncStateRepository.selfAddresses(db))
                }
            } catch {
                Log.ui.error(
                    "thread.retry.failed \(messageId, privacy: .public) "
                        + "\(String(describing: error), privacy: .public)")
            }
            await self?.loadThread()
        }
    }

    func openAttachment(messageId: String, partId: String) {
        Task { [attachments] in await attachments.open(messageId: messageId, partId: partId) }
    }

    private func evaluate(_ script: String, onFalse: @escaping () -> Void) {
        let webView = env.webHost.webView
        Task { @MainActor in
            let result = try? await webView.evaluateJavaScript(script)
            // The section is not in the DOM: the loaded document is out of date.
            if (result as? Bool) == false { onFalse() }
        }
    }

    // MARK: toolbar

    func replyAll() {
        guard let id = newestMessageId else { return }
        lastActionId += 1
        composeInput = .fromMessage(mode: .replyAll, threadId: threadId, messageId: id)
    }

    func forward() {
        guard let id = newestMessageId else { return }
        lastActionId += 1
        composeInput = .fromMessage(mode: .forward, threadId: threadId, messageId: id)
    }

    func archive() async {
        lastActionId += 1
        await env.actions.archive(threadId: threadId)
        shouldDismiss = true
    }

    /// The screen stays open; the toolbar icon flips on the next observation tick.
    func toggleRead() async {
        lastActionId += 1
        if isUnread {
            await env.actions.markRead(threadId: threadId)
        } else {
            await env.actions.markUnread(threadId: threadId)
        }
    }

    // MARK: environment changes

    /// `.onAppear` and theme/scheme changes: recompute the tokens and rebuild when anything differs.
    func systemSchemeChanged(_ scheme: ColorScheme) {
        let theme = env.theme.resolved(for: scheme)
        lightTokens = theme.cssTokens(for: .light)
        darkTokens = theme.cssTokens(for: .dark)
        forcedScheme = env.theme.forcedDocumentTheme
        rebuild(force: false)
    }

    /// Dynamic Type changed: the document text may be identical, so the reload is forced.
    func contentSizeChanged() {
        rebuild(force: true)
    }

    /// Cancels the observation (the cancellable's own deinit does the same when the model goes away).
    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    // MARK: pure helpers

    /// Projection of one `ThreadDetail` into 08's document input. `labeler`/`fullDate` are passed in because
    /// neither is `Sendable`.
    nonisolated static func documentMessages(
        detail: ThreadDetail, expanded: Set<String>, imagesAllowedIds: Set<String>, loadRemoteImages: Bool,
        labeler: RowDateLabeler, fullDate: DateFormatter
    ) -> [ThreadDocumentMessage] {
        detail.messages.map { message in
            let body = detail.bodies[message.id]
            let chips =
                detail.attachments
                .filter { $0.messageId == message.id && !$0.isInline }
                .map {
                    ThreadDocumentAttachment(
                        partId: $0.partId, filename: $0.filename, sizeLabel: Formatters.bytes($0.size))
                }
            return ThreadDocumentMessage(
                id: message.id,
                fromName: message.fromName ?? "",
                fromAddr: message.fromAddr,
                toLine: message.toList.map(\.displayName).joined(separator: ", "),
                ccLine: message.ccList.isEmpty
                    ? nil : message.ccList.map(\.displayName).joined(separator: ", "),
                dateLabel: labeler.label(epochMs: message.internalDate),
                dateFull: fullDate.string(from: Date(timeIntervalSince1970: Double(message.internalDate) / 1000)),
                snippet: message.snippet,
                isUnread: message.isUnread,
                expanded: expanded.contains(message.id),
                bodyHTML: body?.bodyHtml,
                bodyState: message.bodyState,
                darkStrategy: body?.darkStrategy ?? "plain",
                hasRemoteImages: body?.hasRemoteImages ?? false,
                imagesAllowed: loadRemoteImages || imagesAllowedIds.contains(message.id),
                attachments: chips)
        }
    }

    /// Every unread message plus the newest one (architecture §8.2).
    nonisolated static func initialExpanded(_ detail: ThreadDetail) -> Set<String> {
        var ids = Set(detail.messages.filter(\.isUnread).map(\.id))
        if let newest = detail.messages.last?.id { ids.insert(newest) }
        return ids
    }

    /// User-facing text for a thread-load failure (§5.2).
    nonisolated static func loadErrorText(for error: any Error) -> String {
        switch error {
        case GmailError.offline: return "You're offline — showing what's cached."
        case GmailError.unauthorized: return "Sign in again to load this thread."
        case GmailError.rateLimited: return "Gmail is busy. Try again in a moment."
        default: return "Couldn't load this thread."
        }
    }

    /// `.full` date + `.short` time, used for the `title` attribute of the date span.
    nonisolated static func makeFullDateFormatter(timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }
}
