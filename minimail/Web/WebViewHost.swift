import Foundation
import MailCore
import UIKit
import WebKit
import os

/// Compiled content rule lists (`[html-rendering §2.2]`). Main-actor static state; `prepare()` is idempotent.
/// Bump the identifier suffix whenever the JSON changes — the store keys by identifier.
enum RuleLists {
    static let blockAllIdentifier = "minimail.block-all.v1"
    static let imagesOnlyIdentifier = "minimail.images-only.v1"

    static let blockAllJSON = """
        [
          { "trigger": { "url-filter": "^https?://" }, "action": { "type": "block" } },
          { "trigger": { "url-filter": "^wss?://" },   "action": { "type": "block" } },
          { "trigger": { "url-filter": "^ftp://" },    "action": { "type": "block" } },
          { "trigger": { "url-filter": "^file://" },   "action": { "type": "block" } }
        ]
        """

    static let imagesOnlyJSON = """
        [
          { "trigger": { "url-filter": "^https?://" }, "action": { "type": "block" } },
          { "trigger": { "url-filter": "^https://", "resource-type": ["image"] }, "action": { "type": "ignore-previous-rules" } },
          { "trigger": { "url-filter": "^wss?://" },   "action": { "type": "block" } },
          { "trigger": { "url-filter": "^ftp://" },    "action": { "type": "block" } },
          { "trigger": { "url-filter": "^file://" },   "action": { "type": "block" } }
        ]
        """

    static var blockAll: WKContentRuleList?
    static var imagesOnly: WKContentRuleList?

    /// Test hook: compile into a temporary store when `WKContentRuleListStore.default()` is unavailable.
    static var storeOverride: WKContentRuleListStore?

    /// Looks each list up by identifier, else compiles it. Failures are logged and leave the var nil.
    static func prepare() async {
        guard blockAll == nil || imagesOnly == nil else { return }
        guard let store = storeOverride ?? WKContentRuleListStore.default() else {
            Log.web.error("web.rulelist.nostore")
            return
        }
        if blockAll == nil {
            blockAll = await load(store, blockAllIdentifier, blockAllJSON)
        }
        if imagesOnly == nil {
            imagesOnly = await load(store, imagesOnlyIdentifier, imagesOnlyJSON)
        }
    }

    /// Tests.
    static func reset() {
        blockAll = nil
        imagesOnly = nil
    }

    private static func load(
        _ store: WKContentRuleListStore, _ identifier: String, _ json: String
    ) async -> WKContentRuleList? {
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) { return existing }
        do {
            return try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json)
        } catch {
            Log.web.error(
                "web.rulelist.failed \(identifier, privacy: .public) \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Owner of the ONE pooled `WKWebView` (architecture decision 9). The instance is created lazily on first
/// access to `webView` or in `prepare()` — never during launch step 1.
final class WebViewHost {
    static let recycleDelay: TimeInterval = 60

    let cid: CIDSchemeHandler
    let bridge: WebBridge
    /// Navigation and UI delegate of the pooled instance, held strongly (WKWebView holds its delegates weakly).
    let linkPolicy = LinkPolicy()

    private(set) var isPrepared = false
    private(set) var imagesAllowed = false
    private(set) var isAttached = false
    private(set) var loadedRevision = -1

    /// Tests: the instance is nil until something asks for it.
    private(set) var webViewIfCreated: WKWebView?

    /// Tests: shortens the `didLeaveThread()` delay.
    var recycleDelayOverride: TimeInterval?

    /// DEVIATION: the host owns `linkPolicy.onDidFinish` (set once, when the instance is created) and
    /// republishes it here, so a caller — 10, or a test — can observe loads without stomping the
    /// `documentLoad` signpost the spec ends from the same callback.
    var onDocumentLoaded: (() -> Void)?

    private let throwawayPolicy = LinkPolicy()
    private var recycleTask: Task<Void, Never>?
    private var memoryObserver: (any NSObjectProtocol)?
    private var documentLoadState: OSSignpostIntervalState?

    init(cid: CIDSchemeHandler, bridge: WebBridge) {
        self.cid = cid
        self.bridge = bridge
    }

    deinit {
        recycleTask?.cancel()
    }

    var webView: WKWebView {
        if let existing = webViewIfCreated { return existing }
        let created = WKWebView(frame: .zero, configuration: Self.makeConfiguration(cid: cid, bridge: bridge))
        apply(instanceSettings: created, policy: linkPolicy)
        linkPolicy.onDidFinish = { [weak self] in self?.handleDidFinish() }
        webViewIfCreated = created
        return created
    }

    /// Compiles the rule lists, creates the instance, observes memory warnings and warms up with the empty
    /// document. Idempotent; called ~1 s after the first frame.
    func prepare() async {
        guard !isPrepared else { return }
        let existedBefore = webViewIfCreated != nil
        await RuleLists.prepare()
        let view = webView
        if existedBefore, let list = RuleLists.blockAll {
            view.configuration.userContentController.add(list)
        }
        isPrepared = true
        if memoryObserver == nil {
            memoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAttached else { return }
                    self.recycle()
                }
            }
        }
        view.loadHTMLString(Self.emptyDocument(), baseURL: nil)
    }

    /// Swaps the attached rule list. Must be called BEFORE the load that needs it.
    func setImagesAllowed(_ allowed: Bool) {
        guard allowed != imagesAllowed else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let list = allowed ? RuleLists.imagesOnly : RuleLists.blockAll {
            controller.add(list)
        }
        imagesAllowed = allowed
    }

    func load(document: String, revision: Int) {
        cancelScheduledRecycle()
        documentLoadState = Log.begin(.documentLoad)
        webView.loadHTMLString(document, baseURL: nil)
        loadedRevision = revision
    }

    /// Drops the DOM, keeps the WebContent process.
    func recycle() {
        cancelScheduledRecycle()
        guard let view = webViewIfCreated else { return }
        setImagesAllowed(false)
        view.loadHTMLString(Self.emptyDocument(), baseURL: nil)
        loadedRevision = -1
        Log.web.debug("web.recycle")
    }

    /// Recycles `recycleDelay` seconds from now unless a load or attach happens first.
    func didLeaveThread() {
        cancelScheduledRecycle()
        let delay = recycleDelayOverride ?? Self.recycleDelay
        recycleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isAttached else { return }
            self.recycle()
        }
    }

    func didAttach() {
        isAttached = true
        cancelScheduledRecycle()
    }

    func didDetach() {
        isAttached = false
    }

    /// Architecture §9.3 verbatim.
    static func makeConfiguration(cid: CIDSchemeHandler, bridge: WebBridge) -> WKWebViewConfiguration {
        let configuration = baseConfiguration()
        configuration.setURLSchemeHandler(cid, forURLScheme: CIDSchemeHandler.scheme)
        if let list = RuleLists.blockAll { configuration.userContentController.add(list) }
        configuration.userContentController.add(bridge, name: WebBridge.handlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebBridge.clickDelegateJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return configuration
    }

    /// Signature preview only (13): same flags and the block-all list, but no cid handler, no message
    /// handler and no user script. The caller owns the returned view.
    func makeThrowawayWebView() -> WKWebView {
        let configuration = Self.baseConfiguration()
        if let list = RuleLists.blockAll { configuration.userContentController.add(list) }
        let view = WKWebView(frame: .zero, configuration: configuration)
        apply(instanceSettings: view, policy: throwawayPolicy)
        return view
    }

    private static func baseConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.websiteDataStore = .nonPersistent()
        configuration.dataDetectorTypes = []
        configuration.suppressesIncrementalRendering = true
        configuration.allowsInlineMediaPlayback = false
        return configuration
    }

    private func apply(instanceSettings view: WKWebView, policy: LinkPolicy) {
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = UIColor.systemBackground
        view.underPageBackgroundColor = UIColor.systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        view.navigationDelegate = policy
        view.uiDelegate = policy
        #if DEBUG
            view.isInspectable = true
        #endif
    }

    /// The stock palette's tokens; the document itself carries both schemes.
    private static func emptyDocument() -> String {
        ThreadDocument.empty(
            light: SystemPalette.cssTokens(for: .light), dark: SystemPalette.cssTokens(for: .dark))
    }

    private func handleDidFinish() {
        if let state = documentLoadState {
            documentLoadState = nil
            Log.end(.documentLoad, state)
        }
        onDocumentLoaded?()
    }

    private func cancelScheduledRecycle() {
        recycleTask?.cancel()
        recycleTask = nil
    }
}
