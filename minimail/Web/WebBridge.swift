import Foundation
import WebKit

/// Taps inside the document, delivered by the click-delegate user script. `.link` is never produced by
/// `WebBridge` (links navigate and reach `LinkPolicy.openURL`); the case exists so `ThreadModel` (10) can
/// funnel `openURL` into the same switch.
enum WebMessage: Equatable, Sendable {
    case toggle(messageId: String)
    case loadImages(messageId: String)
    case attachment(messageId: String, partId: String)
    case link(URL)
    case retry(messageId: String)
}

/// The `mm` script-message handler (architecture §8.4). WebKit delivers messages on the main thread.
final class WebBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "mm"

    /// Delegated click listener, injected `.atDocumentEnd`, `forMainFrameOnly: true` by
    /// `WebViewHost.makeConfiguration`. It posts only for elements carrying `data-action`, calls
    /// `preventDefault()` so `href="#"` never navigates, and never toggles classes itself — the app's
    /// `expanded` set stays the single source of truth.
    static let clickDelegateJS = """
        (function(){
        if(window.__mmClickInstalled){return;}
        window.__mmClickInstalled=true;
        document.addEventListener('click',function(e){
        var el=e.target;
        while(el&&el!==document.documentElement&&!(el.getAttribute&&el.getAttribute('data-action'))){el=el.parentNode;}
        if(!el||!el.getAttribute){return;}
        var action=el.getAttribute('data-action');
        if(!action){return;}
        e.preventDefault();e.stopPropagation();
        var sec=el.closest?el.closest('section.mm-msg'):null;
        var payload={action:action,id:sec?(sec.getAttribute('data-id')||''):'',part:el.getAttribute('data-part')||''};
        if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.mm){window.webkit.messageHandlers.mm.postMessage(payload);}
        },true);
        })();
        """

    /// Set by the thread screen (10). Called on the main actor.
    var onMessage: (WebMessage) -> Void = { _ in }

    override init() {
        super.init()
    }

    /// `{action, id, part}` dictionary → `WebMessage`; nil for anything else.
    static func parse(_ body: Any) -> WebMessage? {
        guard let dict = body as? [String: Any], let action = dict["action"] as? String else { return nil }
        let id = (dict["id"] as? String) ?? ""
        let part = (dict["part"] as? String) ?? ""
        return message(action: action, id: id, part: part)
    }

    /// `minimail-action://<action>/<id>[/<part>]` → `WebMessage` (fallback path when user scripts do not run).
    static func parse(actionURL url: URL) -> WebMessage? {
        guard url.scheme?.lowercased() == "minimail-action", let action = url.host, !action.isEmpty else {
            return nil
        }
        let components =
            url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        let id = components.first ?? ""
        let part = components.count > 1 ? components[1] : ""
        return message(action: action.lowercased(), id: id, part: part)
    }

    private static func message(action: String, id: String, part: String) -> WebMessage? {
        switch action {
        case "toggle": return id.isEmpty ? nil : .toggle(messageId: id)
        case "images": return id.isEmpty ? nil : .loadImages(messageId: id)
        case "retry": return id.isEmpty ? nil : .retry(messageId: id)
        case "att": return (id.isEmpty || part.isEmpty) ? nil : .attachment(messageId: id, partId: part)
        default: return nil
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, let parsed = Self.parse(message.body) else {
            Log.web.debug("web.bridge.ignored")
            return
        }
        onMessage(parsed)
    }
}
