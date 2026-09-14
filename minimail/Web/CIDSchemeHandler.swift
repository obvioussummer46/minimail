import Foundation
import WebKit

/// Serves `minimail-cid://<messageId>/<percent-encoded contentId>` from `InlineImageStore`. WebKit calls
/// start/stop on the main thread; the class is main-actor isolated, so `active`/`tasks` need no lock.
/// A task that was stopped never receives `didReceive`/`didFinish`/`didFailWithError`.
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "minimail-cid"

    let store: InlineImageStore

    private var active: Set<ObjectIdentifier> = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(store: InlineImageStore) {
        self.store = store
        super.init()
    }

    /// `(host, percent-decoded path without the leading "/")`; nil when host or path is empty or decoding fails.
    static func parse(_ url: URL) -> (messageId: String, contentId: String)? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !path.isEmpty, let contentId = path.removingPercentEncoding, !contentId.isEmpty else { return nil }
        return (host, contentId)
    }

    /// Number of tasks currently in flight (tests).
    var activeCount: Int { active.count }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let (messageId, contentId) = Self.parse(url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        active.insert(id)
        tasks[id] = Task { [store] in
            let result: Result<(Data, String), any Error>
            do {
                result = .success(try await store.bytes(messageId: messageId, contentId: contentId))
            } catch {
                result = .failure(error)
            }
            guard active.contains(id) else { return }  // stopped meanwhile: deliver nothing
            active.remove(id)
            tasks[id] = nil
            switch result {
            case .success(let (data, mime)):
                urlSchemeTask.didReceive(
                    URLResponse(
                        url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error):
                Log.web.debug(
                    "web.cid.failed \(messageId, privacy: .public) \(String(describing: error), privacy: .public)")
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        active.remove(id)
        tasks[id]?.cancel()
        tasks[id] = nil
    }
}
