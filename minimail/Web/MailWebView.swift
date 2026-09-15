import SwiftUI
import UIKit
import WebKit

/// Hosts the pooled instance inside a container view (the instance is re-parented on every appear).
/// `imagesAllowed` and `backgroundColor` are part of the value so the rule-list swap and the themed
/// background are applied before the load, inside one `updateUIView`.
struct MailWebView: UIViewRepresentable {
    let host: WebViewHost
    let document: String
    /// Increments force a reload (a theme change changes the document text, so it bumps this too).
    let revision: Int
    let interfaceStyle: UIUserInterfaceStyle
    let imagesAllowed: Bool
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> MailWebContainerView {
        let container = MailWebContainerView()
        container.webViewHost = host
        container.host(host.webView)
        host.didAttach()
        return container
    }

    func updateUIView(_ container: MailWebContainerView, context: Context) {
        container.host(host.webView)
        let view = host.webView
        if context.coordinator.appliedStyle != interfaceStyle {
            view.overrideUserInterfaceStyle = interfaceStyle
            context.coordinator.appliedStyle = interfaceStyle
        }
        view.backgroundColor = backgroundColor
        view.underPageBackgroundColor = backgroundColor
        guard context.coordinator.appliedRevision != revision else { return }
        host.setImagesAllowed(imagesAllowed)
        host.load(document: document, revision: revision)
        context.coordinator.appliedRevision = revision
    }

    static func dismantleUIView(_ container: MailWebContainerView, coordinator: Coordinator) {
        // SwiftUI delivers this on the main thread; the requirement itself is not isolated.
        MainActor.assumeIsolated {
            container.webViewHost?.didDetach()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedRevision: Int = -1
        var appliedStyle: UIUserInterfaceStyle = .unspecified
    }
}

/// Plain `UIView` whose single subview (the pooled web view) is pinned to its bounds.
final class MailWebContainerView: UIView {
    /// Set by `MailWebView` so `dismantleUIView` can reach the host without capturing it.
    weak var webViewHost: WebViewHost?

    private weak var hosted: WKWebView?

    func host(_ webView: WKWebView) {
        guard hosted !== webView || webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        addSubview(webView)
        hosted = webView
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}
