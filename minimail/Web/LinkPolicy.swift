import Foundation
import UIKit
import WebKit

/// Navigation delegate of the pooled instance (and, with `openURL = { _ in }`, of throwaway instances).
/// Cancels every navigation except the `about:blank` load of `loadHTMLString`; `.linkActivated` with scheme
/// http/https/mailto/tel goes to `openURL`; `minimail-action:` links go to `onAction`.
final class LinkPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Set by the thread screen (10) to `openURL(url)` of `@Environment(\.openURL)`.
    var openURL: (URL) -> Void = { _ in }
    /// Receives `WebBridge.parse(actionURL:)` results (the user-script fallback path).
    var onAction: ((WebMessage) -> Void)?
    /// Called from `webView(_:didFinish:)`; `WebViewHost` uses it to end the `documentLoad` signpost.
    var onDidFinish: (() -> Void)?

    private static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    override init() {
        super.init()
    }

    /// Pure decision table (spec §4.8), unit-tested without a `WKNavigationAction`.
    static func decision(
        for url: URL?, type: WKNavigationType
    ) -> (policy: WKNavigationActionPolicy, open: URL?, action: WebMessage?) {
        switch type {
        case .linkActivated:
            guard let url, let scheme = url.scheme?.lowercased() else { return (.cancel, nil, nil) }
            if openableSchemes.contains(scheme) { return (.cancel, url, nil) }
            if scheme == "minimail-action" { return (.cancel, nil, WebBridge.parse(actionURL: url)) }
            return (.cancel, nil, nil)
        case .other:
            guard let url, isBlank(url) else { return (.cancel, nil, nil) }
            return (.allow, nil, nil)
        default:
            return (.cancel, nil, nil)
        }
    }

    /// `about:blank`, with or without an empty fragment.
    private static func isBlank(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text == "about:blank" || text == "about:blank#"
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let decision = Self.decision(for: navigationAction.request.url, type: navigationAction.navigationType)
        if let url = decision.open { openURL(url) }
        if let action = decision.action { onAction?(action) }
        return decision.policy
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onDidFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.web.error("web.navigation.failed \(error.localizedDescription, privacy: .public)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        Log.web.error("web.navigation.failed \(error.localizedDescription, privacy: .public)")
    }

    /// New-window requests (`target=_blank`, `window.open`) open nothing; an http(s) URL is handed to `openURL`.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            openURL(url)
        }
        return nil
    }
}
